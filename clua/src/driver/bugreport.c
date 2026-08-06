/*
** bugreport.c -- `clua bug-report` collector.
**
** Gathers the small set of facts a maintainer needs to reproduce or triage
** a CLua issue and writes them into a self-contained Markdown file:
**
**   - clua version string (single source of truth: common/version.h)
**   - target triple (fixed for this compiler; see LcBugreport_TargetTriple)
**   - every CLUA_* environment variable
**   - Windows version (major.minor.build) and current working directory
**   - last N lines of a .cluarc if one lives beside the CWD
**   - short git SHA if git is on PATH and CWD is inside a repository
**
** No network, no telemetry: the file lands where the user runs the tool
** (or at --out=<path> if given). Non-fatal probes silently omit their
** section rather than fail the whole report -- a report with fewer facts
** is still more useful than a failed collection run.
*/
#include "bugreport.h"

#include "common/version.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <direct.h>     /* _getcwd                                    */
#include <process.h>    /* _popen / _pclose on some MinGW builds      */
#include <windows.h>    /* GetVersionExA, GetEnvironmentStringsA      */

/* Fixed target triple. We only compile for one target: x86_64 MSVC-flavoured
** COFF/PE on Windows. The value matches what clang would print for a build
** targeting native Windows x64. */
const char *LcBugreport_TargetTriple( void ) {
    return "x86_64-pc-windows-msvc";
}

/* Try to open <path>-<pid>-<timestamp>-friendly output. Callers pass NULL
** for the auto-derived default. Returns the FILE* (which the caller closes)
** and copies the actual path used into `out_path` (size = out_path_size). */
static FILE *OpenOutput( const char *user_path, char *out_path,
                         size_t out_path_size ) {
    time_t     now = time( NULL );
    struct tm *tm  = localtime( &now );
    FILE      *f;

    if ( user_path != NULL && user_path[ 0 ] != '\0' ) {
        if ( out_path && out_path_size > 0 ) {
            snprintf( out_path, out_path_size, "%s", user_path );
        }
        f = fopen( user_path, "wb" );
        return f;
    }

    if ( tm != NULL ) {
        snprintf( out_path, out_path_size,
                  "clua-bug-report-%04d%02d%02d-%02d%02d%02d.md",
                  tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
                  tm->tm_hour, tm->tm_min, tm->tm_sec );
    } else {
        snprintf( out_path, out_path_size, "clua-bug-report.md" );
    }
    f = fopen( out_path, "wb" );
    return f;
}

/* Enumerate every environment variable and print the CLUA_-prefixed ones
** as a Markdown table. We use GetEnvironmentStringsA (not the C `environ`
** array) so a fresh snapshot is guaranteed even after the process has
** touched setenv. */
static void PrintCluaEnv( FILE *f ) {
    LPCH block = GetEnvironmentStringsA( );
    LPCH p;
    int  count = 0;

    fputs( "\n## Environment (CLUA_*)\n\n", f );
    if ( block == NULL ) {
        fputs( "(unavailable)\n", f );
        return;
    }
    for ( p = block; *p; ) {
        size_t len = strlen( p );
        if ( strncmp( p, "CLUA_", 5 ) == 0 ) {
            const char *eq = strchr( p, '=' );
            if ( eq != NULL ) {
                fprintf( f, "- `%.*s` = `%s`\n",
                         ( int )( eq - p ), p, eq + 1 );
                count++;
            }
        }
        p += len + 1;
    }
    FreeEnvironmentStringsA( block );
    if ( count == 0 ) fputs( "(none set)\n", f );
}

/* Windows version -- 10.0.NNNNN is the standard shape on Win10/11.
** Uses RtlGetVersion via GetProcAddress rather than GetVersionExA -- the
** latter is deprecated AND version-shims to 6.2 on unmanifested processes,
** which turns "on Windows 11" into "on Windows 8". A diagnostic report
** wants the real number. Falls back to a plain "Windows" line if the ntdll
** entry is unavailable. */
typedef LONG ( WINAPI *pfn_RtlGetVersion_t )( PRTL_OSVERSIONINFOW );
static void PrintWindowsVersion( FILE *f ) {
    HMODULE nt = GetModuleHandleA( "ntdll.dll" );
    pfn_RtlGetVersion_t p = NULL;
    if ( nt ) {
        p = ( pfn_RtlGetVersion_t )( void ( * )( void ) )
            GetProcAddress( nt, "RtlGetVersion" );
    }
    if ( p ) {
        RTL_OSVERSIONINFOW v;
        memset( &v, 0, sizeof( v ) );
        v.dwOSVersionInfoSize = sizeof( v );
        if ( p( &v ) == 0 /* STATUS_SUCCESS */ ) {
            fprintf( f, "- OS: Windows %lu.%lu build %lu\n",
                     ( unsigned long )v.dwMajorVersion,
                     ( unsigned long )v.dwMinorVersion,
                     ( unsigned long )v.dwBuildNumber );
            return;
        }
    }
    fputs( "- OS: Windows (version query unavailable)\n", f );
}

/* If `git` is on PATH and CWD is inside a repo, capture the short SHA of
** HEAD. Non-fatal: silent skip on any failure. */
static void PrintGitSha( FILE *f ) {
    FILE *pipe = _popen( "git rev-parse --short HEAD 2>NUL", "r" );
    char  line[ 128 ] = { 0 };
    if ( pipe == NULL ) return;
    if ( fgets( line, sizeof( line ), pipe ) != NULL ) {
        char *nl = strchr( line, '\n' );
        if ( nl ) *nl = '\0';
        nl = strchr( line, '\r' );
        if ( nl ) *nl = '\0';
        if ( line[ 0 ] != '\0' ) {
            fprintf( f, "- git commit: `%s`\n", line );
        }
    }
    _pclose( pipe );
}

/* Copy the last `n` lines of `path` into the report. Missing file = silent. */
static void PrintCluarcTail( FILE *f, int max_lines ) {
    FILE  *rc;
    char   buf[ 4096 ];
    /* Simple ring: keep the last max_lines lines. Bounded by 32 to keep
    ** stack usage predictable; a .cluarc is a short config file. */
    char   ring[ 32 ][ 4096 ];
    int    head = 0, count = 0, i;
    if ( max_lines > 32 ) max_lines = 32;
    if ( max_lines <= 0 ) return;

    rc = fopen( ".cluarc", "rb" );
    if ( rc == NULL ) return;
    fputs( "\n## .cluarc (last lines)\n\n```\n", f );
    while ( fgets( buf, sizeof( buf ), rc ) != NULL ) {
        snprintf( ring[ head ], sizeof( ring[ head ] ), "%s", buf );
        head = ( head + 1 ) % max_lines;
        if ( count < max_lines ) count++;
    }
    fclose( rc );
    for ( i = 0; i < count; i++ ) {
        int idx = ( head - count + i + max_lines ) % max_lines;
        fputs( ring[ idx ], f );
    }
    fputs( "\n```\n", f );
}

int LcBugreport_Write( const char *user_out, char *actual_out,
                       size_t actual_out_size, char *err, size_t errlen ) {
    char   used_path[ 512 ] = { 0 };
    char   cwd[ 1024 ] = { 0 };
    FILE  *f;

    if ( actual_out != NULL && actual_out_size > 0 ) actual_out[ 0 ] = '\0';
    if ( err != NULL && errlen > 0 ) err[ 0 ] = '\0';

    f = OpenOutput( user_out, used_path, sizeof( used_path ) );
    if ( f == NULL ) {
        if ( err && errlen ) {
            snprintf( err, errlen, "cannot open bug-report output '%s'",
                      used_path[ 0 ] ? used_path : "clua-bug-report.md" );
        }
        return 0;
    }
    if ( actual_out != NULL && actual_out_size > 0 ) {
        snprintf( actual_out, actual_out_size, "%s", used_path );
    }

    fputs( "# clua bug report\n", f );
    fprintf( f, "\nGenerated: `%s`\n\n", used_path );

    fputs( "## Toolchain\n\n", f );
    fprintf( f, "- clua version: `%s`\n", CLUA_VERSION_STRING );
    fprintf( f, "- target triple: `%s`\n", LcBugreport_TargetTriple( ) );
    PrintWindowsVersion( f );
    if ( _getcwd( cwd, ( int )sizeof( cwd ) ) != NULL ) {
        fprintf( f, "- cwd: `%s`\n", cwd );
    } else {
        fputs( "- cwd: (unavailable)\n", f );
    }
    PrintGitSha( f );

    PrintCluaEnv( f );

    PrintCluarcTail( f, 20 );

    fputs( "\n## What to include next\n\n"
           "- The exact command line you ran and its stderr.\n"
           "- A minimal Lua program that reproduces the issue, if possible.\n"
           "- The output of `clua --print-search-dirs` and "
           "`clua --print-runtime-path`.\n", f );

    fclose( f );
    return 1;
}
