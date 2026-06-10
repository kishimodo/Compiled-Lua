/*
** pe_link_v2.c — native link glue for the LuaC AOT driver (M0).
**
** See pe_link_v2.h. Three steps, each a MinGW gcc invocation via system():
**   1. compile the generated ProtoInit C  -> luac_protoinit_<pid>.o
**   2. compile src/runtime/aot_entry.c     -> luac_aotentry_<pid>.o
**   3. link userObj + (1) + (2) + runtime-embedded.a + liblua54-embedded.a
**      into the output PE (console subsystem).
**
** The link recipe matches the proven Task-2/12 spike (tests/unit/
** test_lc_coff_spike.c link_probe + coff_probe_main.c): our own main() lives in
** aot_entry.o, so ld does NOT pull the runtime archive's runtime_entry.o (and
** thus not runtime_init.o / the undefined g_LuaBlob / Runtime_GetPackages blob
** symbols). No -Wl,--strip-all (the AOT bodies are force-resolved by reference
** from ProtoInit's `extern int luac_fn_<i>(lua_State*)`).
*/
#include "link/pe_link_v2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static void set_errv( char *err, size_t errlen, const char *fmt, ... ) {
    if ( err == NULL || errlen == 0 ) return;
    va_list ap;
    va_start( ap, fmt );
    vsnprintf( err, errlen, fmt, ap );
    va_end( ap );
}

/* The compile flags that match the base Makefile's runtime-embedded objects
** (include dirs + the Windows-x64 target define). We deliberately do NOT pass
** the -Os/-g0 hardening flags here: the per-build ProtoInit + aot_entry objects
** only need to link correctly, and matching the include/target macros is what
** keeps the Lua struct layouts identical to the archives. */
#define LUAC_GCC          "x86_64-w64-mingw32-gcc"
#define LUAC_INCLUDES     "-I./src -I./lua-5.4/src -I./build/gen"
/* NB: do NOT pass -DLUA_USE_WINDOWS here — luaconf.h already defines it on a
** Windows target, and passing it again triggers a redefinition warning. The
** struct layouts that must match the archives are governed by the include dirs
** + the target macro, not LUA_USE_WINDOWS. */
#define LUAC_DEFINES      "-DLUAVM_TARGET_WINDOWS_X64=1 -DLUA_COMPAT_5_3"

#define LUAC_RUNTIME_A    "build/bin/runtime-embedded.a"
#define LUAC_LUALIB_A     "build/bin/liblua54-embedded.a"
#define LUAC_AOT_ENTRY_C  "src/runtime/aot_entry.c"

static int run_cmd( const char *cmd ) {
    /* system() returns the child's exit status (0 == success on success). */
    return system( cmd );
}

int LuacLink_LinkProgram( const char *userObj, const char *protoInitC,
                          const char *outExe, char *err, size_t errlen ) {
    char cmd[ 4096 ];
    char protoObj[ 1024 ];
    char entryObj[ 1024 ];
    int  rc;

    if ( err && errlen ) err[ 0 ] = '\0';
    if ( userObj == NULL || protoInitC == NULL || outExe == NULL ) {
        set_errv( err, errlen, "LuacLink: NULL argument" );
        return 0;
    }

    /* Derive sibling object paths from the ProtoInit C path (same tmp dir). */
    snprintf( protoObj, sizeof( protoObj ), "%s.o", protoInitC );
    {
        /* place the aot_entry obj next to the user obj */
        const char *dot = strrchr( userObj, '.' );
        size_t baselen = dot ? ( size_t )( dot - userObj ) : strlen( userObj );
        if ( baselen + 16 >= sizeof( entryObj ) ) baselen = sizeof( entryObj ) - 16;
        memcpy( entryObj, userObj, baselen );
        entryObj[ baselen ] = '\0';
        strncat( entryObj, "_entry.o", sizeof( entryObj ) - strlen( entryObj ) - 1 );
    }

    /* ---- 1. compile the generated ProtoInit C ---- */
    snprintf( cmd, sizeof( cmd ),
              LUAC_GCC " -std=c99 " LUAC_INCLUDES " " LUAC_DEFINES
              " -c \"%s\" -o \"%s\"",
              protoInitC, protoObj );
    rc = run_cmd( cmd );
    if ( rc != 0 ) {
        set_errv( err, errlen,
                  "compiling ProtoInit C failed (gcc rc=%d): %s", rc, cmd );
        return 0;
    }

    /* ---- 2. compile the AOT entry ---- */
    snprintf( cmd, sizeof( cmd ),
              LUAC_GCC " -std=c99 " LUAC_INCLUDES " " LUAC_DEFINES
              " -c \"" LUAC_AOT_ENTRY_C "\" -o \"%s\"",
              entryObj );
    rc = run_cmd( cmd );
    if ( rc != 0 ) {
        set_errv( err, errlen,
                  "compiling aot_entry.c failed (gcc rc=%d): %s", rc, cmd );
        return 0;
    }

    /* ---- 3. link the program ----
    ** Order: user bodies, ProtoInit (references luac_fn_<i>, keeping the bodies),
    ** aot_entry (supplies main + references LuacProgram_BuildEntry), then the
    ** runtime + lua archives, then the Win32 import libs the runtime needs. */
    snprintf( cmd, sizeof( cmd ),
              LUAC_GCC " -o \"%s\" \"%s\" \"%s\" \"%s\" "
              LUAC_RUNTIME_A " " LUAC_LUALIB_A " "
              "-Wl,--subsystem,console "
              "-lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi",
              outExe, userObj, protoObj, entryObj );
    rc = run_cmd( cmd );
    if ( rc != 0 ) {
        set_errv( err, errlen, "link failed (gcc rc=%d): %s", rc, cmd );
        return 0;
    }

    return 1;
}
