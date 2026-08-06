/*
** import_lib.c — emit .DEF module-definition files. See import_lib.h.
**
** Why .def rather than a native .lib archive?
** A Windows import library is a small `ar`-format archive that carries one
** IMPORT_OBJECT_HEADER (20 bytes) per exported symbol plus the standard `/`
** and `//` archive members and a synthesised `_import_directory` linker
** directive. Both MSVC's linker and MinGW's dlltool already know how to
** synthesise that archive FROM a .def file, so emitting the .def is a strictly
** smaller change with the same downstream reach:
**
**     MSVC:   lib /def:foo.def /machine:x64 /out:foo.lib
**     MinGW:  dlltool -d foo.def -D foo.dll -l foo.lib   (or -l libfoo.a)
**
** The .def is human-readable, deterministic, byte-identical between rebuilds
** with the same export set, and requires no linker toolchain to produce -- the
** compile step for the .def is `fprintf`. If a future release wants to ship a
** ready-to-consume .lib alongside, this is the layer to extend (add a
** LcEmit_ShortImportLib that walks the same exports[] and writes the archive
** members). The public shape of LcEmit_DefFile stays the same either way.
**
** Atomicity: write to a temp file in the destination directory, FlushFileBuffers,
** then MoveFileEx REPLACE_EXISTING+WRITE_THROUGH. Matches pe_link_v2.c's stage
** + publish discipline so a Ctrl+C during emit never leaves a truncated .def
** shadowing a prior good one.
*/
#include "link/import_lib.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include <windows.h>

static void set_errv( char *err, size_t errlen, const char *fmt, ... ) {
    if ( err == NULL || errlen == 0 ) return;
    va_list ap;
    va_start( ap, fmt );
    vsnprintf( err, errlen, fmt, ap );
    va_end( ap );
}

/* Return a pointer to the LAST path component of `p` (basename). Handles both
** '/' and '\\' as separators so callers don't have to normalise first. */
static const char *basename_of( const char *p ) {
    const char *b = p, *q;
    for ( q = p; *q; q++ ) {
        if ( *q == '/' || *q == '\\' ) b = q + 1;
    }
    return b;
}

int LcEmit_DeriveDefPath( const char *dll_path, char *out, size_t out_size ) {
    size_t n, keep;
    const char *dot;

    if ( dll_path == NULL || out == NULL || out_size == 0 ) return 0;
    n = strlen( dll_path );

    /* Trim a trailing ".dll" / ".DLL" (case-insensitive) if present so
    ** foo.dll -> foo.def and NOT foo.dll.def, but foo (no ext) -> foo.def. */
    dot = strrchr( dll_path, '.' );
    if ( dot != NULL && ( n - ( size_t )( dot - dll_path ) ) == 4
         && ( dot[1] == 'd' || dot[1] == 'D' )
         && ( dot[2] == 'l' || dot[2] == 'L' )
         && ( dot[3] == 'l' || dot[3] == 'L' ) ) {
        keep = ( size_t )( dot - dll_path );
    } else {
        keep = n;
    }
    if ( keep + 5 > out_size ) return 0;  /* +5 for ".def" + NUL */
    memcpy( out, dll_path, keep );
    memcpy( out + keep, ".def", 5 );
    return 1;
}

/* Split `def_path` into a directory (returned in `dir`, sized `dir_size`) so
** GetTempFileName can stage the .def on the same volume as the destination. */
static int split_dir( const char *def_path, char *dir, size_t dir_size ) {
    char full[ MAX_PATH ];
    DWORD n;
    char *slash;

    n = GetFullPathNameA( def_path, ( DWORD )sizeof( full ), full, NULL );
    if ( n == 0 || n >= sizeof( full ) ) return 0;
    slash = strrchr( full, '\\' );
    if ( slash == NULL ) slash = strrchr( full, '/' );
    if ( slash == NULL ) return 0;
    /* Preserve C:\ rather than turning the drive root into "C:". */
    if ( slash == full + 2 && full[1] == ':' ) slash[1] = '\0';
    else                                        *slash = '\0';
    if ( strlen( full ) + 1 > dir_size ) return 0;
    memcpy( dir, full, strlen( full ) + 1 );
    return 1;
}

int LcEmit_DefFile( const char *dll_path, const char *def_path,
                    const char *const *exports, size_t nexports,
                    char *err, size_t errlen ) {
    char  dir[ MAX_PATH ];
    char  staged[ MAX_PATH ];
    FILE *fp;
    size_t i;
    const char *libname;

    if ( err && errlen ) err[ 0 ] = '\0';
    if ( dll_path == NULL || def_path == NULL ) {
        set_errv( err, errlen, "LcEmit_DefFile: NULL path argument" );
        return 0;
    }
    if ( exports == NULL && nexports > 0 ) {
        set_errv( err, errlen, "LcEmit_DefFile: exports NULL with nexports=%zu",
                  nexports );
        return 0;
    }

    if ( !split_dir( def_path, dir, sizeof( dir ) ) ) {
        set_errv( err, errlen, "cannot resolve directory for '%s'", def_path );
        return 0;
    }
    if ( GetTempFileNameA( dir, "cdf", 0, staged ) == 0 ) {
        set_errv( err, errlen,
                  "cannot create staging .def beside '%s' (Win32 error %lu)",
                  def_path, ( unsigned long )GetLastError( ) );
        return 0;
    }

    fp = fopen( staged, "wb" );
    if ( fp == NULL ) {
        set_errv( err, errlen, "cannot open '%s' for write", staged );
        DeleteFileA( staged );
        return 0;
    }

    libname = basename_of( dll_path );
    /* LF-only line endings for byte-identical output across the same input; the
    ** MS linker and dlltool both accept LF. LIBRARY name is quoted so basenames
    ** with dots (foo.dll) or unusual characters parse unambiguously. */
    if ( fprintf( fp, "LIBRARY \"%s\"\n", libname ) < 0
         || fprintf( fp, "EXPORTS\n" ) < 0 ) {
        set_errv( err, errlen, "write error on '%s'", staged );
        fclose( fp );
        DeleteFileA( staged );
        return 0;
    }
    for ( i = 0; i < nexports; i++ ) {
        if ( exports[ i ] == NULL || exports[ i ][ 0 ] == '\0' ) continue;
        if ( fprintf( fp, "    %s\n", exports[ i ] ) < 0 ) {
            set_errv( err, errlen, "write error on '%s'", staged );
            fclose( fp );
            DeleteFileA( staged );
            return 0;
        }
    }

    if ( fflush( fp ) != 0 ) {
        set_errv( err, errlen, "fflush failed on '%s'", staged );
        fclose( fp );
        DeleteFileA( staged );
        return 0;
    }
    fclose( fp );

    /* Flush to disk before publishing, matching pe_link_v2.c's discipline. */
    {
        HANDLE h = CreateFileA( staged, GENERIC_WRITE,
                                FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL );
        if ( h != INVALID_HANDLE_VALUE ) {
            FlushFileBuffers( h );
            CloseHandle( h );
        }
    }

    if ( !MoveFileExA( staged, def_path,
                       MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH ) ) {
        set_errv( err, errlen,
                  "cannot publish '%s' (Win32 error %lu); prior .def preserved",
                  def_path, ( unsigned long )GetLastError( ) );
        DeleteFileA( staged );
        return 0;
    }
    return 1;
}
