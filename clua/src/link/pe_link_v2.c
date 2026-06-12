/*
** pe_link_v2.c — native link glue for the CLua AOT driver.
**
** See pe_link_v2.h. ONE MinGW gcc invocation links:
**   userObj (luac_fn_<i> bodies + .rdata$L ProtoInit blob/fn-table)
**   + aot_entry.o            (main(), AOT dispatch hook, closed-world stubs;
**                             precompiled at toolchain build time — compiled
**                             from source only as a cold-tree fallback)
**   + runtime-aot.a          (Rt_* helpers, dispatch cache, coroutines, FFI,
**                             protoinit_rt.o — NO JIT compiler)
**   + liblua54-embedded.a    (the Lua core; the parser/lexer/dump members are
**                             never extracted thanks to aot_entry's stubs)
** into a stripped console PE.
**
** The link recipe descends from the proven Task-2/12 spike: our own main()
** lives in aot_entry.o, so ld does NOT pull the runtime archive's
** runtime_entry.o (and thus not runtime_init.o / the undefined g_LuaBlob /
** Runtime_GetPackages blob symbols).
*/
#include "link/pe_link_v2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include <windows.h>   /* GetModuleFileNameA */

static void set_errv( char *err, size_t errlen, const char *fmt, ... ) {
    if ( err == NULL || errlen == 0 ) return;
    va_list ap;
    va_start( ap, fmt );
    vsnprintf( err, errlen, fmt, ap );
    va_end( ap );
}

/* The compile flags used by the cold-tree aot_entry.c fallback. They match
** the base Makefile's archive objects where it matters: the include dirs +
** the Windows-x64 target define govern the Lua struct layouts. (NB: do NOT
** pass -DLUA_USE_WINDOWS — luaconf.h already defines it on a Windows target.) */
#define LUAC_DEFINES "-DCLUA_TARGET_WINDOWS_X64=1 -DLUA_COMPAT_5_3 -DLUAC_AOT_RUNTIME=1"

#define LC_PATH_MAX 1024

typedef struct {
    char runtime_a[ LC_PATH_MAX ];    /* runtime-aot.a                        */
    char lualib_a[ LC_PATH_MAX ];     /* liblua54-embedded.a                  */
    char aot_entry_o[ LC_PATH_MAX ];  /* precompiled entry ("" if not found)  */
    char lvm_nointerp_o[ LC_PATH_MAX ]; /* interpreter-free lvm ("" if absent)*/
    char inc_src[ LC_PATH_MAX ];      /* -I dir containing jit/, runtime/     */
    char inc_lua[ LC_PATH_MAX ];      /* -I dir containing lua.h              */
    char aot_entry_c[ LC_PATH_MAX ];  /* fallback source ("" if not found)    */
} LcToolchain;

static int FileExists( const char *path ) {
    FILE *f;
    if ( path == NULL || path[0] == '\0' ) return 0;
    f = fopen( path, "rb" );
    if ( f == NULL ) return 0;
    fclose( f );
    return 1;
}

/* Try one root layout. `lib` is the subdirectory holding the archives
** ("lib" for a dist tree, "" when the archives sit next to the root itself).
** Returns 1 and fills `tc` if both archives are present. */
static int TryRoot( LcToolchain *tc, const char *root, const char *lib,
                    const char *inc_src, const char *inc_lua,
                    const char *entry_c ) {
    char a[ LC_PATH_MAX ], b[ LC_PATH_MAX ];
    const char *sep = ( lib && lib[0] ) ? "\\" : "";
    if ( lib == NULL ) lib = "";

    snprintf( a, sizeof( a ), "%s\\%s%sruntime-aot.a", root, lib, sep );
    snprintf( b, sizeof( b ), "%s\\%s%sliblua54-embedded.a", root, lib, sep );
    if ( !FileExists( a ) || !FileExists( b ) ) return 0;

    snprintf( tc->runtime_a, sizeof( tc->runtime_a ), "%s", a );
    snprintf( tc->lualib_a,  sizeof( tc->lualib_a ),  "%s", b );
    snprintf( tc->aot_entry_o, sizeof( tc->aot_entry_o ),
              "%s\\%s%saot_entry.o", root, lib, sep );
    if ( !FileExists( tc->aot_entry_o ) ) tc->aot_entry_o[0] = '\0';
    snprintf( tc->lvm_nointerp_o, sizeof( tc->lvm_nointerp_o ),
              "%s\\%s%slvm_nointerp.o", root, lib, sep );
    if ( !FileExists( tc->lvm_nointerp_o ) ) tc->lvm_nointerp_o[0] = '\0';

    /* cold-tree fallback inputs (optional — only needed when aot_entry.o is
    ** absent): include dirs + the entry source, given relative to root. */
    tc->inc_src[0] = tc->inc_lua[0] = tc->aot_entry_c[0] = '\0';
    if ( inc_src ) snprintf( tc->inc_src, sizeof( tc->inc_src ), "%s\\%s", root, inc_src );
    if ( inc_lua ) snprintf( tc->inc_lua, sizeof( tc->inc_lua ), "%s\\%s", root, inc_lua );
    if ( entry_c ) {
        snprintf( tc->aot_entry_c, sizeof( tc->aot_entry_c ), "%s\\%s", root, entry_c );
        if ( !FileExists( tc->aot_entry_c ) ) tc->aot_entry_c[0] = '\0';
    }
    return 1;
}

/* Resolve the toolchain resources. Order:
**   1. %CLUA_HOME%        (dist root: lib\*.a + lib\aot_entry.o)
**   2. <exedir>           (dist roots: <exedir>\lib, <exedir>\..\lib)
**   3. <exedir>           (repo: archives are SIBLINGS of the exe in build\bin)
**   4. CWD                (repo: build\bin\*.a — the historical behavior)
*/
static int ResolveToolchain( LcToolchain *tc, char *err, size_t errlen ) {
    char exedir[ LC_PATH_MAX ] = { 0 };
    char parent[ LC_PATH_MAX ] = { 0 };
    const char *home = getenv( "CLUA_HOME" );

    memset( tc, 0, sizeof( *tc ) );

    if ( home && home[0] ) {
        if ( TryRoot( tc, home, "lib", "include", "include", NULL ) ) return 1;
        /* a CLUA_HOME pointed at a repo checkout also works: */
        if ( TryRoot( tc, home, "build\\bin", "clua\\src", "lua-5.4\\src",
                      "clua\\src\\runtime\\aot_entry.c" ) ) return 1;
        /* CLUA_HOME also names the package-store root (rover installs under
        ** %CLUA_HOME%\packages), so a store-only CLUA_HOME with no toolchain
        ** under it is legitimate — fall through to exe-relative discovery
        ** rather than failing here. */
    }

    if ( GetModuleFileNameA( NULL, exedir, sizeof( exedir ) ) > 0 ) {
        char *slash = strrchr( exedir, '\\' );
        if ( slash ) {
            *slash = '\0';
            /* dist: <exedir>\lib\... (flat) */
            if ( TryRoot( tc, exedir, "lib", "include", "include", NULL ) ) return 1;
            /* repo: the archives sit next to the exe in build\bin; the repo
            ** root is two levels up. */
            if ( TryRoot( tc, exedir, "", "..\\..\\clua\\src", "..\\..\\lua-5.4\\src",
                          "..\\..\\clua\\src\\runtime\\aot_entry.c" ) ) return 1;
            /* dist: bin\clua.exe + ..\lib\... */
            snprintf( parent, sizeof( parent ), "%s\\..", exedir );
            if ( TryRoot( tc, parent, "lib", "include", "include", NULL ) ) return 1;
        }
    }

    /* CWD repo layout (running from a repo root with copied binaries) */
    if ( TryRoot( tc, ".", "build\\bin", "clua\\src", "lua-5.4\\src",
                  "clua\\src\\runtime\\aot_entry.c" ) ) return 1;

    set_errv( err, errlen,
              "cannot locate the CLua runtime libraries (runtime-aot.a + "
              "liblua54-embedded.a). Looked in %%CLUA_HOME%%\\lib, next to "
              "the executable, <exedir>\\lib, <exedir>\\..\\lib, and "
              ".\\build\\bin. Set CLUA_HOME to your CLua installation root." );
    return 0;
}

static int run_cmd( const char *cmd ) {
    /* system() returns the child's exit status (0 == success). */
    return system( cmd );
}

/* gcc command: %CLUA_GCC% override, else the MinGW triplet on PATH. */
static const char *GccCommand( void ) {
    const char *g = getenv( "CLUA_GCC" );
    return ( g && g[0] ) ? g : "x86_64-w64-mingw32-gcc";
}

int LuacLink_LinkProgram( const char *userObj, const char *outExe,
                          int no_interp, int require_ffi,
                          char *err, size_t errlen ) {
    char        cmd[ 4096 ];
    char        entry_obj[ LC_PATH_MAX ];
    char        lvm_obj[ LC_PATH_MAX + 4 ];
    LcToolchain tc;
    int         rc;

    if ( err && errlen ) err[ 0 ] = '\0';
    if ( userObj == NULL || outExe == NULL ) {
        set_errv( err, errlen, "LuacLink: NULL argument" );
        return 0;
    }

    if ( !ResolveToolchain( &tc, err, errlen ) ) return 0;

    /* Precompiled aot_entry.o, or the cold-tree fallback: compile it next to
    ** the user object (one extra gcc step, dev-tree only). */
    if ( tc.aot_entry_o[0] ) {
        snprintf( entry_obj, sizeof( entry_obj ), "%s", tc.aot_entry_o );
    } else {
        const char *dot = strrchr( userObj, '.' );
        size_t baselen = dot ? ( size_t )( dot - userObj ) : strlen( userObj );
        if ( !tc.aot_entry_c[0] || !tc.inc_src[0] || !tc.inc_lua[0] ) {
            set_errv( err, errlen,
                      "no precompiled aot_entry.o and no aot_entry.c fallback "
                      "in the resolved toolchain ('%s') — rebuild with "
                      "build\\build-luac.bat", tc.runtime_a );
            return 0;
        }
        if ( baselen + 16 >= sizeof( entry_obj ) ) baselen = sizeof( entry_obj ) - 16;
        memcpy( entry_obj, userObj, baselen );
        entry_obj[ baselen ] = '\0';
        strncat( entry_obj, "_entry.o", sizeof( entry_obj ) - strlen( entry_obj ) - 1 );
        snprintf( cmd, sizeof( cmd ),
                  "%s -std=c99 -I\"%s\" -I\"%s\" " LUAC_DEFINES
                  " -c \"%s\" -o \"%s\"",
                  GccCommand( ), tc.inc_src, tc.inc_lua, tc.aot_entry_c,
                  entry_obj );
        rc = run_cmd( cmd );
        if ( rc != 0 ) {
            set_errv( err, errlen,
                      "compiling aot_entry.c failed (gcc rc=%d): %s", rc, cmd );
            return 0;
        }
    }

    /* Interpreter selection: a program whose closed-world scan proves it
    ** never references "debug" can never activate a debug hook, so the
    ** bytecode interpreter loop is unreachable — link lvm_nointerp.o (the
    ** CLUA_NO_INTERP build of lvm.c, defining every luaV_* helper but no
    ** clua_Interpret) BEFORE the Lua archive so its full lvm.o member is
    ** never extracted (~15 KB). Programs that mention debug keep the full
    ** interpreter: debug.sethook routes them through it, matching the
    ** oracle exactly. Falls back silently when the object isn't shipped. */
    lvm_obj[0] = '\0';
    if ( no_interp && tc.lvm_nointerp_o[0] ) {
        snprintf( lvm_obj, sizeof( lvm_obj ), "\"%s\" ", tc.lvm_nointerp_o );
    }

    /* ---- the single link ----
    ** Order: user bodies+blob, aot_entry (main + closed-world stubs, defined
    ** BEFORE the archives so the parser/lexer/dump members are never
    ** extracted), optional lvm_nointerp.o, runtime-aot.a (pulls
    ** protoinit_rt.o via LuacProgram_BuildEntry), the Lua core, then the
    ** Win32 import libs. -s strips symbols/debug info; --gc-sections drops
    ** unreferenced functions (both archives are -ffunction-sections; lib
    ** registration tables live in .rdata and keep every reachable lib
    ** function alive). */
    snprintf( cmd, sizeof( cmd ),
              "%s -o \"%s\" \"%s\" \"%s\" %s%s\"%s\" \"%s\" "
              "-Wl,--subsystem,console -Wl,--gc-sections -s "
              "-lm -lkernel32 -ladvapi32",
              GccCommand( ), outExe, userObj, entry_obj, lvm_obj,
              require_ffi ? "-Wl,--undefined=Clua_OpenFfi " : "",
              tc.runtime_a, tc.lualib_a );
    rc = run_cmd( cmd );
    if ( rc != 0 ) {
        set_errv( err, errlen,
                  "link failed (gcc rc=%d; is MinGW-w64 gcc on PATH, or set "
                  "CLUA_GCC): %s", rc, cmd );
        return 0;
    }

    return 1;
}
