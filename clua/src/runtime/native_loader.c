#include "runtime/native_loader.h"
#include "common/sha256_lite.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <shlobj.h>

/* Weak default. Per-build native_refs.o overrides this. */
__attribute__( ( weak ) )
const EMBEDDED_NATIVE_DLL_T *Native_GetEmbeddedDlls( size_t *OutCount ) {
    if ( OutCount != NULL ) { *OutCount = 0; }
    return NULL;
}

/* FNV-1a 32-bit over the running binary's full path. Stable across
   runs of the same binary -- different binaries get distinct dirs so
   parallel runs don't fight over file locks. */
static uint32_t HashExePath( void ) {
    char     Path[ MAX_PATH ] = { 0 };
    uint32_t H = 0x811c9dc5u;
    GetModuleFileNameA( NULL, Path, MAX_PATH );
    for ( const char *P = Path; *P; P++ ) {
        H = ( H ^ ( uint8_t )*P ) * 0x01000193u;
    }
    return H;
}

/* SHA-256 the file at Path. Returns 1 on success. */
static int HashFile( const char *Path, uint8_t Digest[ 32 ] ) {
    FILE *Fp = fopen( Path, "rb" );
    if ( Fp == NULL ) return 0;
    SHA256_LITE_CTX_T Ctx;
    Sha256Lite_Init( &Ctx );
    unsigned char Buf[ 4096 ];
    size_t        N;
    while ( ( N = fread( Buf, 1, sizeof( Buf ), Fp ) ) > 0 ) {
        Sha256Lite_Update( &Ctx, Buf, N );
    }
    fclose( Fp );
    Sha256Lite_Final( &Ctx, Digest );
    return 1;
}

/* Resolve the per-binary extraction directory. Prefers
   %LOCALAPPDATA%\clua-interp\<hash> (per-user-scoped, not world-writable)
   over %TEMP%. Returns the chosen path in Dir; returns 1 on success. */
static int ResolveExtractDir( char *Dir, size_t Cap ) {
    char Base[ MAX_PATH ] = { 0 };
    if ( SHGetFolderPathA( NULL, CSIDL_LOCAL_APPDATA, NULL, 0, Base ) != S_OK ) {
        /* Fall back to TEMP (per-user on modern Windows but world-
           writable on shared hosts). Document the trade-off. */
        if ( GetTempPathA( MAX_PATH, Base ) == 0 ) return 0;
        snprintf( Dir, Cap, "%sclua-%08x", Base, HashExePath( ) );
    } else {
        char Parent[ MAX_PATH ] = { 0 };
        snprintf( Parent, sizeof( Parent ), "%s\\clua-interp", Base );
        CreateDirectoryA( Parent, NULL );  /* inherits user-only ACL */
        snprintf( Dir, Cap, "%s\\%08x", Parent, HashExePath( ) );
    }
    return 1;
}

/* Constant-time digest compare (avoids leaking timing on early bytes). */
static int DigestEquals( const uint8_t *A, const uint8_t *B ) {
    uint8_t Diff = 0;
    for ( int I = 0; I < 32; I++ ) Diff |= A[ I ] ^ B[ I ];
    return Diff == 0;
}

/* Write the DLL bytes via CreateFileW with CREATE_ALWAYS (overwrite
   if anything's there). Returns 1 on success. */
static int WriteDllAtomic( const char *Path,
                           const unsigned char *Bytes, size_t Len ) {
    HANDLE H = CreateFileA(
        Path, GENERIC_WRITE, 0 /* no share -- exclusive */,
        NULL, CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, NULL );
    if ( H == INVALID_HANDLE_VALUE ) return 0;
    DWORD Written = 0;
    BOOL  Ok = WriteFile( H, Bytes, ( DWORD )Len, &Written, NULL );
    CloseHandle( H );
    return Ok && Written == ( DWORD )Len;
}

void Native_Bootstrap( void ) {
    size_t                       Count = 0;
    const EMBEDDED_NATIVE_DLL_T *Dlls  = Native_GetEmbeddedDlls( &Count );
    if ( Count == 0 || Dlls == NULL ) { return; }

    char Dir[ MAX_PATH ] = { 0 };
    if ( !ResolveExtractDir( Dir, sizeof( Dir ) ) ) return;
    if ( !CreateDirectoryA( Dir, NULL ) ) {
        if ( GetLastError( ) != ERROR_ALREADY_EXISTS ) return;
    }

    /* Modern DLL search path management. Try AddDllDirectoryA first
       (Windows 8+ via kernel32) so LoadLibraryEx with
       LOAD_LIBRARY_SEARCH_USER_DIRS finds our dir, then fall back to
       SetDllDirectoryA for legacy ffi.load lookups. */
    typedef DLL_DIRECTORY_COOKIE ( WINAPI *PAddDllDirectoryA )( PCSTR );
    typedef BOOL ( WINAPI *PSetDefaultDllDirs )( DWORD );
    HMODULE K32 = GetModuleHandleA( "kernel32.dll" );
    PAddDllDirectoryA  AddDllDirA = NULL;
    PSetDefaultDllDirs SetDefDirs = NULL;
    if ( K32 != NULL ) {
        /* AddDllDirectory takes PCWSTR; use the W variant. */
        AddDllDirA = ( PAddDllDirectoryA )( void * )
            GetProcAddress( K32, "AddDllDirectory" );
        SetDefDirs = ( PSetDefaultDllDirs )( void * )
            GetProcAddress( K32, "SetDefaultDllDirectories" );
    }
    if ( AddDllDirA != NULL ) {
        wchar_t WDir[ MAX_PATH ] = { 0 };
        MultiByteToWideChar( CP_ACP, 0, Dir, -1, WDir, MAX_PATH );
        /* Cast: actual signature takes wide. */
        DLL_DIRECTORY_COOKIE ( WINAPI *AddW )( PCWSTR ) =
            ( DLL_DIRECTORY_COOKIE ( WINAPI * )( PCWSTR ) )( void * )AddDllDirA;
        ( void )AddW( WDir );
    }
    if ( SetDefDirs != NULL ) {
        /* 0x00000400 = LOAD_LIBRARY_SEARCH_USER_DIRS,
           0x00000800 = LOAD_LIBRARY_SEARCH_SYSTEM32. Lock down search
           to user-added dirs + system32 only -- no current dir, no
           %PATH%, no app dir. */
        SetDefDirs( 0x00000400 | 0x00000800 );
    }

    for ( size_t I = 0; I < Count; I++ ) {
        if ( Dlls[ I ].Name == NULL || Dlls[ I ].Bytes == NULL ||
             Dlls[ I ].LenPtr == NULL || Dlls[ I ].Digest == NULL ) {
            continue;
        }
        char Path[ MAX_PATH ] = { 0 };
        snprintf( Path, sizeof( Path ), "%s\\%s", Dir, Dlls[ I ].Name );

        /* Verify the on-disk file matches the embedded digest. If it
           does, skip extraction (idempotent reuse). If it doesn't --
           or doesn't exist -- write fresh. Closes the substitution
           window that the size-only check left open. */
        uint8_t OnDisk[ 32 ] = { 0 };
        int     NeedWrite   = 1;
        if ( HashFile( Path, OnDisk ) &&
             DigestEquals( OnDisk, Dlls[ I ].Digest ) ) {
            NeedWrite = 0;
        }
        if ( NeedWrite ) {
            if ( !WriteDllAtomic( Path, Dlls[ I ].Bytes,
                                  ( size_t )*Dlls[ I ].LenPtr ) ) {
                continue;
            }
            /* Verify what we just wrote (defense against TOCTOU
               between WriteFile completion and LoadLibrary). */
            if ( !HashFile( Path, OnDisk ) ||
                 !DigestEquals( OnDisk, Dlls[ I ].Digest ) ) {
                /* Best-effort delete + bail on this DLL. */
                DeleteFileA( Path );
                continue;
            }
        }

        /* Pre-load each DLL by full path BEFORE returning to the
           runtime. This closes the TOCTOU window between our digest
           verify and the later ffi.load("name") -- once the module
           is mapped into our address space, subsequent LoadLibrary
           calls with the bare name find the already-loaded module
           by name match rather than rescanning disk. */
        wchar_t WPath[ MAX_PATH ] = { 0 };
        MultiByteToWideChar( CP_ACP, 0, Path, -1, WPath, MAX_PATH );
        ( void )LoadLibraryExW( WPath, NULL,
            0x00000008 /* LOAD_WITH_ALTERED_SEARCH_PATH */ |
            0x00000200 /* LOAD_LIBRARY_SEARCH_DEFAULT_DIRS */ );
    }

    /* Legacy fallback for ffi.load() against DLLs not in our embed
       table but still living next to one we did embed. */
    wchar_t WDir[ MAX_PATH ] = { 0 };
    MultiByteToWideChar( CP_ACP, 0, Dir, -1, WDir, MAX_PATH );
    SetDllDirectoryW( WDir );
}
