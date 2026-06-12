#include "compiler/paths.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>   /* GetModuleFileNameA: exe-relative discovery */
#endif

static int FileExists( const char *Path ) {
    FILE *F = fopen( Path, "rb" );
    if ( F == NULL ) { return 0; }
    fclose( F );
    return 1;
}

/* Root directory holding the builtin package sources. Discovery order
   mirrors the linker's toolchain discovery so dist installs work from any
   directory:
     1. CWD repo checkout      clua/src/runtime/packages
     2. exe-relative repo      <exedir>/../../clua/src/runtime/packages
     3. exe-relative dist      <exedir>/lib/packages
     4. %CLUA_HOME%            <home>/lib/packages, <home>/clua/src/runtime/packages
   Probes for the marker file <root>/json/init.lua. Cached after first call.
   Returns 0 when no root exists (builtin requires then fail loudly). */
int Paths_BuiltinPackagesRoot( char *Out, size_t OutSize ) {
    static char Cached[ 512 ];
    static int  State = 0;            /* 0 = unprobed, 1 = found, -1 = absent */
    char Probe[ 600 ];

    if ( State == 0 ) {
        const char *Home = getenv( "CLUA_HOME" );
        State = -1;
        if ( snprintf( Probe, sizeof( Probe ),
                       "clua/src/runtime/packages/json/init.lua" )
                 < ( int )sizeof( Probe ) && FileExists( Probe ) ) {
            snprintf( Cached, sizeof( Cached ), "clua/src/runtime/packages" );
            State = 1;
        }
#ifdef _WIN32
        if ( State < 0 ) {
            char Exe[ 512 ] = { 0 };
            if ( GetModuleFileNameA( NULL, Exe, sizeof( Exe ) ) > 0 ) {
                char *Slash = strrchr( Exe, '\\' );
                if ( Slash != NULL ) {
                    *Slash = '\0';
                    static const char *Rel[ 2 ] = {
                        "..\\..\\clua\\src\\runtime\\packages",
                        "lib\\packages",
                    };
                    for ( int I = 0; I < 2 && State < 0; I++ ) {
                        if ( snprintf( Probe, sizeof( Probe ),
                                       "%s\\%s\\json\\init.lua", Exe, Rel[ I ] )
                                 < ( int )sizeof( Probe ) &&
                             FileExists( Probe ) ) {
                            snprintf( Cached, sizeof( Cached ), "%s\\%s",
                                      Exe, Rel[ I ] );
                            State = 1;
                        }
                    }
                }
            }
        }
#endif
        if ( State < 0 && Home != NULL && Home[ 0 ] != '\0' ) {
            static const char *Rel[ 2 ] = {
                "lib\\packages",
                "clua\\src\\runtime\\packages",
            };
            for ( int I = 0; I < 2 && State < 0; I++ ) {
                if ( snprintf( Probe, sizeof( Probe ),
                               "%s\\%s\\json\\init.lua", Home, Rel[ I ] )
                         < ( int )sizeof( Probe ) && FileExists( Probe ) ) {
                    snprintf( Cached, sizeof( Cached ), "%s\\%s", Home, Rel[ I ] );
                    State = 1;
                }
            }
        }
    }
    if ( State < 0 || Out == NULL ) { return State > 0; }
    if ( snprintf( Out, OutSize, "%s", Cached ) >= ( int )OutSize ) { return 0; }
    return 1;
}

/* Build <Base>/<module-with-dots-as-slashes>/init.lua (package-directory
   convention) so installed packages laid out as <name>/init.lua resolve. */
static int FormatInitPath( const char *Base, const char *Module,
                           char *Out, size_t OutSize ) {
    static const char Tail[] = "/init.lua";
    size_t BaseLen = strlen( Base );
    size_t NameLen = strlen( Module );
    if ( BaseLen + 1 + NameLen + sizeof( Tail ) > OutSize ) { return 0; }
    memcpy( Out, Base, BaseLen );
    Out[ BaseLen ] = '/';
    for ( size_t I = 0; I < NameLen; I++ ) {
        char C = Module[ I ];
        Out[ BaseLen + 1 + I ] = ( C == '.' ) ? '/' : C;
    }
    memcpy( Out + BaseLen + 1 + NameLen, Tail, sizeof( Tail ) );
    return 1;
}

/* <Base>/<module-dots-to-slashes>/<version>/init.lua -- the versioned store
   layout written by `rover` for multi-version coexistence. */
static int FormatVersionedInitPath( const char *Base, const char *Module,
                                    const char *Version, char *Out, size_t OutSize ) {
    static const char Tail[] = "/init.lua";
    size_t BaseLen = strlen( Base );
    size_t NameLen = strlen( Module );
    size_t VerLen  = strlen( Version );
    size_t O       = { 0 };
    if ( BaseLen + 1 + NameLen + 1 + VerLen + sizeof( Tail ) > OutSize ) { return 0; }
    memcpy( Out, Base, BaseLen ); O = BaseLen;
    Out[ O++ ] = '/';
    for ( size_t I = 0; I < NameLen; I++ ) { char C = Module[ I ]; Out[ O++ ] = ( C == '.' ) ? '/' : C; }
    Out[ O++ ] = '/';
    memcpy( Out + O, Version, VerLen ); O += VerLen;
    memcpy( Out + O, Tail, sizeof( Tail ) );  /* includes the NUL */
    return 1;
}

/* Find <ModuleName>'s pinned version in <LockDir>/rover.lock (the project
   lockfile, next to the source being compiled). Scans the `rover`-generated
   `["<name>"] = { version = "X", ... }` format with a targeted string search
   (the lockfile is small and machine-written). Returns 1 + version on hit. */
static int Paths_LockedVersion( const char *LockDir, const char *ModuleName,
                                char *VerOut, size_t VerSize ) {
    char  LockPath[ 512 ];
    const char *Dir = ( LockDir != NULL && LockDir[ 0 ] != '\0' ) ? LockDir : ".";
    FILE *F;
    char  Buf[ 32768 ];
    char  Key[ 280 ];
    char *P, *V, *Q1, *Q2;
    size_t N, Len;

    if ( snprintf( LockPath, sizeof( LockPath ), "%s/rover.lock", Dir ) >= ( int )sizeof( LockPath ) ) { return 0; }
    F = fopen( LockPath, "rb" );
    if ( F == NULL ) { return 0; }
    N = fread( Buf, 1, sizeof( Buf ) - 1, F );
    fclose( F );
    Buf[ N ] = '\0';

    /* exact key token `["<name>"]` (the closing "] makes prefix names safe) */
    if ( snprintf( Key, sizeof( Key ), "[\"%s\"]", ModuleName ) >= ( int )sizeof( Key ) ) { return 0; }
    P = strstr( Buf, Key );
    if ( P == NULL ) { return 0; }
    V = strstr( P, "version" );
    if ( V == NULL ) { return 0; }
    Q1 = strchr( V, '"' );
    if ( Q1 == NULL ) { return 0; }
    Q1++;
    Q2 = strchr( Q1, '"' );
    if ( Q2 == NULL ) { return 0; }
    Len = ( size_t )( Q2 - Q1 );
    if ( Len == 0 || Len >= VerSize ) { return 0; }
    memcpy( VerOut, Q1, Len );
    VerOut[ Len ] = '\0';
    return 1;
}

/* Installed-package store: $CLUA_HOME/packages, else %LOCALAPPDATA%/clua/
   packages. Returns 1 with a forward-slash path in Out. Lets compiler.exe
   resolve `require "thirdparty"` against packages installed once, globally
   (the NuGet/Go "install once, require anywhere" model). */
static int Paths_StoreBase( char *Out, size_t OutSize ) {
    const char *Home = getenv( "CLUA_HOME" );
    char Tmp[ 400 ];
    if ( Home == NULL || Home[ 0 ] == '\0' ) {
        const char *Local = getenv( "LOCALAPPDATA" );
        if ( Local == NULL || Local[ 0 ] == '\0' ) { return 0; }
        if ( snprintf( Tmp, sizeof( Tmp ), "%s/clua", Local ) >= ( int )sizeof( Tmp ) ) { return 0; }
        Home = Tmp;
    }
    if ( snprintf( Out, OutSize, "%s/packages", Home ) >= ( int )OutSize ) { return 0; }
    for ( char *P = Out; *P != '\0'; P++ ) { if ( *P == '\\' ) { *P = '/'; } }
    return 1;
}

/* 1 if ModuleName resolves to a rover-installed package in the global store
   (flat layout: <store>/<name>/init.lua or <store>/<dotted->path>.lua). Used
   by the resolve walker to let an explicitly installed package SHADOW a
   same-named in-tree builtin: an install is direct user intent, and (unlike
   builtins) installed packages bundle into AOT exes today. */
int Paths_InstalledInStore( const char *ModuleName ) {
    char   Store[ 400 ];
    char   Slashed[ 256 ];
    char   Path[ 700 ];
    size_t I, NameLen;
    if ( ModuleName == NULL || ModuleName[ 0 ] == '\0' ) { return 0; }
    if ( !Paths_StoreBase( Store, sizeof( Store ) ) ) { return 0; }
    NameLen = strlen( ModuleName );
    if ( NameLen + 1 > sizeof( Slashed ) ) { return 0; }
    for ( I = 0; I < NameLen; I++ ) {
        char C = ModuleName[ I ];
        Slashed[ I ] = ( C == '.' ) ? '/' : C;
    }
    Slashed[ NameLen ] = '\0';
    /* <store>/<name>/init.lua  ("windows" -> windows/init.lua) */
    if ( snprintf( Path, sizeof( Path ), "%s/%s/init.lua", Store,
                   Slashed ) < ( int )sizeof( Path ) && FileExists( Path ) ) {
        return 1;
    }
    /* <store>/<dotted->path>.lua  ("windows.bcrypt" -> windows/bcrypt.lua) */
    if ( snprintf( Path, sizeof( Path ), "%s/%s.lua", Store,
                   Slashed ) < ( int )sizeof( Path ) && FileExists( Path ) ) {
        return 1;
    }
    return 0;
}

/* 1 if Path lies under the global package store (the rover install root).
   Lets the diagnostics pass skip linting third-party installed packages -- the
   user can't act on warnings in code they didn't write -- while still linting
   their own project source. Comparison is case-insensitive and slash-agnostic
   (Store is already '/'-normalized; a caller's path may use '\\'). */
int Paths_IsStorePath( const char *Path ) {
    char   Store[ 400 ];
    size_t I, SL;
    if ( Path == NULL || Path[ 0 ] == '\0' ) { return 0; }
    if ( !Paths_StoreBase( Store, sizeof( Store ) ) ) { return 0; }
    SL = strlen( Store );
    for ( I = 0; I < SL; I++ ) {
        char A = Path[ I ];
        char B = Store[ I ];
        if ( A == '\0' ) { return 0; }
        if ( A == '\\' ) { A = '/'; }
        if ( B == '\\' ) { B = '/'; }
        if ( A >= 'A' && A <= 'Z' ) { A = ( char )( A - 'A' + 'a' ); }
        if ( B >= 'A' && B <= 'Z' ) { B = ( char )( B - 'A' + 'a' ); }
        if ( A != B ) { return 0; }
    }
    return 1;
}

static int FormatPath( const char *Base,
                       const char *Module,
                       char       *Out,
                       size_t      OutSize ) {
    size_t BaseLen = strlen( Base );
    size_t NameLen = strlen( Module );
    size_t Total   = BaseLen + 1 + NameLen + 4 + 1;
    size_t I       = { 0 };

    if ( Total > OutSize ) { return 0; }
    memcpy( Out, Base, BaseLen );
    Out[ BaseLen ] = '/';
    for ( I = 0; I < NameLen; I++ ) {
        char C = Module[ I ];
        Out[ BaseLen + 1 + I ] = ( C == '.' ) ? '/' : C;
    }
    memcpy( Out + BaseLen + 1 + NameLen, ".lua", 4 );
    Out[ BaseLen + 1 + NameLen + 4 ] = '\0';
    return 1;
}

int Paths_ModuleNameToFilePath( const char    *ModuleName,
                                PPATHS_OPTS_T  Opts,
                                char          *OutBuf,
                                size_t         OutBufSize ) {
    int I = { 0 };

    if ( ModuleName == NULL || ModuleName[ 0 ] == '\0' ) { return 0; }
    if ( Opts == NULL || OutBuf == NULL )                 { return 0; }

    if ( Opts->IncludeDirs != NULL ) {
        for ( I = 0; Opts->IncludeDirs[ I ] != NULL; I++ ) {
            if ( !FormatPath( Opts->IncludeDirs[ I ], ModuleName, OutBuf, OutBufSize ) ) {
                continue;
            }
            if ( FileExists( OutBuf ) ) { return 1; }
        }
    }
    /* Installed third-party packages from the global store (rover
       install). Checked before the BasePath fallback (which returns even a
       non-existent path). Try the <name>/init.lua layout then a flat
       <name>.lua single-file package. */
    {
        char Store[ 400 ];
        if ( Paths_StoreBase( Store, sizeof( Store ) ) ) {
            /* Lock-pinned version first: a project's rover.lock maps this
               package to an exact version -> <store>/<name>/<version>/init.lua.
               Lets two projects depend on different versions of one package. */
            char Ver[ 64 ];
            if ( Paths_LockedVersion( Opts->BasePath, ModuleName, Ver, sizeof( Ver ) ) &&
                 FormatVersionedInitPath( Store, ModuleName, Ver, OutBuf, OutBufSize ) &&
                 FileExists( OutBuf ) ) {
                return 1;
            }
            /* Lock-less / latest: the flat <store>/<name>/init.lua. */
            if ( FormatInitPath( Store, ModuleName, OutBuf, OutBufSize ) && FileExists( OutBuf ) ) {
                return 1;
            }
            if ( FormatPath( Store, ModuleName, OutBuf, OutBufSize ) && FileExists( OutBuf ) ) {
                return 1;
            }
        }
    }
    if ( Opts->BasePath != NULL ) {
        if ( FormatPath( Opts->BasePath, ModuleName, OutBuf, OutBufSize ) ) {
            /* return the constructed path even if it doesn't exist so the caller
               reports a clear "file not found" later */
            return 1;
        }
    }
    return 0;
}
