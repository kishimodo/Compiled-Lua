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
** Opt-in alternative (--shared-rt): the same userObj + aot_entry.o, plus a
** loose protoinit_rt.o, link against libclua-rt.dll.a instead of the static
** archives — a ~30 KB exe that loads the shared clua-rt.dll at run time.
**
** The link recipe descends from the proven Task-2/12 spike: our own main()
** lives in aot_entry.o, so ld does NOT pull the runtime archive's
** runtime_entry.o (and thus not runtime_init.o / the undefined g_LuaBlob /
** Runtime_GetPackages blob symbols).
*/
#include "link/pe_link_v2.h"
#include "link/pe_emit.h"
#include "common/stdlib_libs.h"   /* LCLIB_* bits of the used-libs mask */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define CLUA_STDLIB_ANCHOR_MAX 7   /* string/table/math/io/os/utf8/debug */

/* Map a used-libs mask to the stdlib_anchors.c symbols the link must force-undef
   so each referenced library's luaopen_* survives gc-sections. Writes the names
   into out[] (sized >= CLUA_STDLIB_ANCHOR_MAX) and returns the count. */
static int StdlibAnchorUndefs( unsigned used_libs, const char *out[] ) {
    static const struct { unsigned bit; const char *sym; } kMap[] = {
        { LCLIB_STRING, "Clua_OpenStrlib"  },
        { LCLIB_TABLE,  "Clua_OpenTablib"  },
        { LCLIB_MATH,   "Clua_OpenMathlib" },
        { LCLIB_IO,     "Clua_OpenIolib"   },
        { LCLIB_OS,     "Clua_OpenOslib"   },
        { LCLIB_UTF8,   "Clua_OpenUtf8lib" },
        { LCLIB_DEBUG,  "Clua_OpenDbglib"  },
    };
    int n = 0, i;
    for ( i = 0; i < ( int )( sizeof( kMap ) / sizeof( kMap[0] ) ); i++ ) {
        if ( used_libs & kMap[ i ].bit ) out[ n++ ] = kMap[ i ].sym;
    }
    return n;
}

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
#define LUAC_DEFINES "-DCLUA_TARGET_WINDOWS_X64=1 -DLUA_COMPAT_5_3"

#define LC_PATH_MAX 1024

/* Link into a unique file beside the requested output, then replace the
** destination only after the linker has closed a complete PE. Keeping the
** staging file in the destination directory makes MoveFileEx an atomic,
** same-volume publication step and preserves an older good binary when a
** build is interrupted or the linker fails after opening its output. */
static int MakeStagedOutput( const char *out_path, char staged[ MAX_PATH ],
                             char *err, size_t errlen ) {
    char  full[ LC_PATH_MAX ];
    char *slash;
    DWORD n;

    n = GetFullPathNameA( out_path, ( DWORD )sizeof( full ), full, NULL );
    if ( n == 0 || n >= sizeof( full ) ) {
        set_errv( err, errlen,
                  "cannot resolve output directory for '%s' (Win32 error %lu)",
                  out_path, ( unsigned long )GetLastError( ) );
        return 0;
    }

    slash = strrchr( full, '\\' );
    if ( slash == NULL ) slash = strrchr( full, '/' );
    if ( slash == NULL ) {
        set_errv( err, errlen, "output path has no directory: %s", out_path );
        return 0;
    }
    /* Preserve C:\ rather than turning the volume root into drive-relative C:. */
    if ( slash == full + 2 && full[1] == ':' ) slash[1] = '\0';
    else                                        *slash = '\0';

    /* GetTempFileName appends "\\cluXXXX.tmp"; reserve that suffix and NUL,
    ** not merely the caller-provided directory itself. */
    if ( strlen( full ) >= MAX_PATH - 14 ) {
        set_errv( err, errlen,
                  "output directory is too long for the current Windows path "
                  "backend: %s", full );
        return 0;
    }
    if ( GetTempFileNameA( full, "clu", 0, staged ) == 0 ) {
        set_errv( err, errlen,
                  "cannot create staging file beside '%s' (Win32 error %lu)",
                  out_path, ( unsigned long )GetLastError( ) );
        return 0;
    }
    return 1;
}

static int PublishStagedOutput( const char *staged, const char *out_path,
                                char *err, size_t errlen ) {
    static const DWORD waits_ms[] = { 25, 75, 200, 500, 1000 };
    HANDLE h;
    DWORD  code = ERROR_SUCCESS;
    int    attempt;

    /* fclose() gets bytes out of the C runtime, but an explicit filesystem
    ** flush is needed before the atomic rename is considered durable. */
    h = CreateFileA( staged, GENERIC_WRITE,
                     FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                     FILE_ATTRIBUTE_NORMAL, NULL );
    if ( h == INVALID_HANDLE_VALUE ) {
        code = GetLastError( );
        set_errv( err, errlen,
                  "cannot flush completed output '%s' (Win32 error %lu); "
                  "the previous output was preserved",
                  out_path, ( unsigned long )code );
        DeleteFileA( staged );
        return 0;
    }
    if ( !FlushFileBuffers( h ) ) code = GetLastError( );
    CloseHandle( h );
    if ( code != ERROR_SUCCESS ) {
        set_errv( err, errlen,
                  "cannot flush completed output '%s' (Win32 error %lu); "
                  "the previous output was preserved",
                  out_path, ( unsigned long )code );
        DeleteFileA( staged );
        return 0;
    }

    /* Antivirus, indexers, and sync clients can hold very short-lived file
    ** handles. Retry only the errors that can plausibly be transient, with a
    ** small fixed budget so a real permission problem still fails promptly. */
    for ( attempt = 0; attempt <= ( int )( sizeof( waits_ms ) /
                                           sizeof( waits_ms[0] ) ); attempt++ ) {
        if ( MoveFileExA( staged, out_path,
                          MOVEFILE_REPLACE_EXISTING |
                          MOVEFILE_WRITE_THROUGH ) ) {
            return 1;
        }
        code = GetLastError( );
        if ( attempt == ( int )( sizeof( waits_ms ) / sizeof( waits_ms[0] ) )
             || ( code != ERROR_SHARING_VIOLATION
                  && code != ERROR_LOCK_VIOLATION
                  && code != ERROR_ACCESS_DENIED ) ) {
            break;
        }
        Sleep( waits_ms[ attempt ] );
    }
    set_errv( err, errlen,
              "cannot publish completed output '%s' (Win32 error %lu); "
              "the previous output was preserved",
              out_path, ( unsigned long )code );
    DeleteFileA( staged );
    return 0;
}

typedef struct {
    char runtime_a[ LC_PATH_MAX ];    /* runtime-aot.a                        */
    char lualib_a[ LC_PATH_MAX ];     /* liblua54-embedded.a                  */
    char aot_entry_o[ LC_PATH_MAX ];  /* precompiled entry ("" if not found)  */
    char lvm_nointerp_o[ LC_PATH_MAX ]; /* interpreter-free lvm ("" if absent)*/
    char rt_implib[ LC_PATH_MAX ];    /* libclua-rt.dll.a ("" if absent)      */
    char protoinit_o[ LC_PATH_MAX ];  /* loose protoinit_rt.o ("" if absent)  */
    char inc_src[ LC_PATH_MAX ];      /* -I dir containing jit/, runtime/     */
    char inc_lua[ LC_PATH_MAX ];      /* -I dir containing lua.h              */
    char aot_entry_c[ LC_PATH_MAX ];  /* fallback source ("" if not found)    */
    char sysroot[ LC_PATH_MAX ];      /* CRT sysroot dir ("" if not found)    */
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
    /* shared-runtime pieces (only required for --shared-rt links) */
    snprintf( tc->rt_implib, sizeof( tc->rt_implib ),
              "%s\\%s%slibclua-rt.dll.a", root, lib, sep );
    if ( !FileExists( tc->rt_implib ) ) tc->rt_implib[0] = '\0';
    snprintf( tc->protoinit_o, sizeof( tc->protoinit_o ),
              "%s\\%s%sprotoinit_rt.o", root, lib, sep );
    if ( !FileExists( tc->protoinit_o ) ) tc->protoinit_o[0] = '\0';

    /* CRT sysroot (internal-linker mode): <archives-dir>\sysroot, probed by a
    ** representative member (libkernel32.a). Empty if the snapshot isn't here. */
    {
        char probe[ LC_PATH_MAX ];
        snprintf( tc->sysroot, sizeof( tc->sysroot ),
                  "%s\\%s%ssysroot", root, lib, sep );
        snprintf( probe, sizeof( probe ), "%s\\libkernel32.a", tc->sysroot );
        if ( !FileExists( probe ) ) tc->sysroot[0] = '\0';
    }

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

/* Linker selection. Resolution order:
**   1. explicit --ld=internal / --ld=gcc flag (ld_internal == 1 / 0)
**   2. CLUA_LD=internal|lcpe / CLUA_LD=gcc env var
**   3. DEFAULT: internal when the CRT sysroot is discoverable, else gcc.
** Returns LD_INTERNAL, LD_GCC, or LD_DEFAULT (caller resolves the default
** against sysroot availability after ResolveToolchain). */
enum { LD_DEFAULT = 0, LD_INTERNAL, LD_GCC };

static int WantInternalLinker( int ld_internal ) {
    const char *e;
    if ( ld_internal == 1 ) return LD_INTERNAL;
    if ( ld_internal == 0 ) return LD_GCC;
    e = getenv( "CLUA_LD" );
    if ( e && ( strcmp( e, "internal" ) == 0 || strcmp( e, "lcpe" ) == 0 ) ) return LD_INTERNAL;
    if ( e && strcmp( e, "gcc" ) == 0 ) return LD_GCC;
    return LD_DEFAULT;
}

/* The full MinGW CRT archive set the internal linker links, in the order gcc's
** spec emits them (objects first so closed-world stubs shadow archive members;
** the lib group is order-insensitive thanks to the fixpoint pull). Names are
** resolved against the sysroot dir. */
static const char *kCrtArchives[] = {
    "libmingw32.a", "libgcc.a", "libmoldname.a", "libmingwex.a", "libmsvcrt.a",
    "libadvapi32.a", "libshell32.a", "libuser32.a", "libkernel32.a", "libucrt.a"
};
#define N_CRT_ARCHIVES ( (int)( sizeof(kCrtArchives)/sizeof(kCrtArchives[0]) ) )

/* Link the program with the built-in COFF->PE64 linker (no gcc). */
static int LinkInternal( const LcToolchain *tc, const char *userObj,
                         const char *outExe, const char *entry_obj,
                         int no_interp, int require_ffi, unsigned used_libs,
                         int no_gc_sections, char *err, size_t errlen ) {
    char  objbuf[ 6 ][ LC_PATH_MAX ];
    char  arcbuf[ N_CRT_ARCHIVES + 2 ][ LC_PATH_MAX ];
    const char *objs[ 6 ];
    const char *arcs[ N_CRT_ARCHIVES + 2 ];
    const char *undef[ 1 + CLUA_STDLIB_ANCHOR_MAX ];   /* Clua_OpenFfi + stdlib anchors */
    int   nobj = 0, narc = 0, nundef = 0, i;
    LcPeLinkInputs in;

    if ( tc->sysroot[0] == '\0' ) {
        set_errv( err, errlen,
                  "--ld=internal: CRT sysroot not found (expected a 'sysroot' "
                  "dir next to the runtime archives). Run `make -f "
                  "build/Makefile.luac sysroot` or install a dist with "
                  "lib\\sysroot." );
        return 0;
    }

    /* explicit objects, in link order: user, entry, optional nointerp lvm,
    ** then the CRT startup objects (crt2/crtbegin first, crtend last). */
    snprintf( objbuf[nobj], LC_PATH_MAX, "%s", userObj );   objs[nobj] = objbuf[nobj]; nobj++;
    snprintf( objbuf[nobj], LC_PATH_MAX, "%s", entry_obj ); objs[nobj] = objbuf[nobj]; nobj++;
    if ( no_interp && tc->lvm_nointerp_o[0] ) {
        snprintf( objbuf[nobj], LC_PATH_MAX, "%s", tc->lvm_nointerp_o ); objs[nobj] = objbuf[nobj]; nobj++;
    }
    snprintf( objbuf[nobj], LC_PATH_MAX, "%s\\crt2.o",     tc->sysroot ); objs[nobj] = objbuf[nobj]; nobj++;
    snprintf( objbuf[nobj], LC_PATH_MAX, "%s\\crtbegin.o", tc->sysroot ); objs[nobj] = objbuf[nobj]; nobj++;
    snprintf( objbuf[nobj], LC_PATH_MAX, "%s\\crtend.o",   tc->sysroot ); objs[nobj] = objbuf[nobj]; nobj++;

    /* archives: the CLua runtime + Lua core first (so aot_entry's stubs
    ** already shadowed the parser members), then the CRT archive set. */
    snprintf( arcbuf[narc], LC_PATH_MAX, "%s", tc->runtime_a ); arcs[narc] = arcbuf[narc]; narc++;
    snprintf( arcbuf[narc], LC_PATH_MAX, "%s", tc->lualib_a );  arcs[narc] = arcbuf[narc]; narc++;
    for ( i = 0; i < N_CRT_ARCHIVES; i++ ) {
        snprintf( arcbuf[narc], LC_PATH_MAX, "%s\\%s", tc->sysroot, kCrtArchives[i] );
        arcs[narc] = arcbuf[narc]; narc++;
    }

    if ( require_ffi ) undef[nundef++] = "Clua_OpenFfi";
    nundef += StdlibAnchorUndefs( used_libs, &undef[ nundef ] );

    memset( &in, 0, sizeof in );
    in.objects        = objs;  in.nobjects     = nobj;
    in.archives       = arcs;  in.narchives    = narc;
    in.force_undef    = undef; in.nforce_undef = nundef;
    in.entry          = "mainCRTStartup";
    in.out_path       = outExe;
    in.no_gc_sections = no_gc_sections;

    return LcPe_Link( &in, err, errlen );
}

int LuacLink_LinkProgram( const char *userObj, const char *outExe,
                          int no_interp, int require_ffi, unsigned used_libs,
                          int shared_rt, int ld_internal, int no_gc_sections,
                          char *err, size_t errlen ) {
    char        cmd[ 4096 ];
    char        staged_out[ MAX_PATH ];
    char        entry_obj[ LC_PATH_MAX ];
    char        lvm_obj[ LC_PATH_MAX + 4 ];
    char        libundef[ 512 ];   /* -Wl,--undefined= for each used stdlib anchor */
    const char *libnames[ CLUA_STDLIB_ANCHOR_MAX ];
    int         nlib, li;
    LcToolchain tc;
    int         rc;
    int         ld_choice = WantInternalLinker( ld_internal );
    int         use_internal;

    /* Build the gcc force-undef string for the optional stdlib anchors (the
       internal linker takes them as an array inside LinkInternal instead). */
    libundef[0] = '\0';
    nlib = StdlibAnchorUndefs( used_libs, libnames );
    for ( li = 0; li < nlib; li++ ) {
        size_t have = strlen( libundef );
        snprintf( libundef + have, sizeof( libundef ) - have,
                  "-Wl,--undefined=%s ", libnames[ li ] );
    }

    if ( err && errlen ) err[ 0 ] = '\0';
    if ( userObj == NULL || outExe == NULL ) {
        set_errv( err, errlen, "LuacLink: NULL argument" );
        return 0;
    }

    if ( !ResolveToolchain( &tc, err, errlen ) ) return 0;

    /* Resolve the linker now that the sysroot is known. The DEFAULT is the
    ** built-in linker (no gcc needed) whenever the CRT sysroot ships next to
    ** the runtime archives; if the sysroot is absent (a bare repo that hasn't
    ** run `make sysroot`, or a dist without lib\sysroot) fall back to gcc with
    ** a one-line note. An explicit --ld=internal still errors loudly below if
    ** the sysroot is missing — only the implicit default falls back silently. */
    if ( ld_choice == LD_INTERNAL ) {
        use_internal = 1;
    } else if ( ld_choice == LD_GCC ) {
        use_internal = 0;
    } else { /* LD_DEFAULT */
        if ( tc.sysroot[0] ) {
            use_internal = 1;
        } else {
            use_internal = 0;
            fprintf( stderr,
                     "clua: note: CRT sysroot not found; using gcc to link "
                     "(run `make -f build/Makefile.luac sysroot` for a "
                     "gcc-free build, or pass --ld=internal once it exists)\n" );
        }
    }

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

    /* ---- internal linker (--ld=internal / CLUA_LD=internal) ----
    ** The built-in COFF->PE64 linker against the CRT sysroot — no gcc/ld.
    ** Static link only (shared_rt stays on the gcc path; the DLL build needs
    ** the import-lib + auto-import pseudo-reloc machinery gcc provides). */
    if ( use_internal && !shared_rt ) {
        if ( !MakeStagedOutput( outExe, staged_out, err, errlen ) ) return 0;
        if ( !LinkInternal( &tc, userObj, staged_out, entry_obj,
                            no_interp, require_ffi, used_libs, no_gc_sections,
                            err, errlen ) ) {
            DeleteFileA( staged_out );
            return 0;
        }
        return PublishStagedOutput( staged_out, outExe, err, errlen );
    }

    /* ---- the shared-runtime link (--shared-rt) ----
    ** userObj + aot_entry.o + protoinit_rt.o (the LCPB deserializer reads
    ** luac_protoblob/luac_fn_table from the user object, so it must live in
    ** the exe — a DLL cannot import from its host) against the clua-rt.dll
    ** import lib. Function calls resolve through import thunks; the
    ** clua_dispatch_hook/clua_invoke_hook data writes resolve via MinGW
    ** auto-import pseudo-relocs. No lvm_nointerp / --gc-sections here: the
    ** DLL carries the full runtime (interpreter included) once, shared by
    ** every --shared-rt exe; the exe itself has nothing left to shake. */
    if ( shared_rt ) {
        if ( !tc.rt_implib[0] || !tc.protoinit_o[0] ) {
            set_errv( err, errlen,
                      "--shared-rt: libclua-rt.dll.a / protoinit_rt.o not "
                      "found next to '%s' — rebuild with build\\build-luac.bat "
                      "(repo) or install a dist with lib\\clua-rt.dll",
                      tc.runtime_a );
            return 0;
        }
        /* The DLL carries every luaopen_*, but aot_entry's weak references to the
           stdlib anchors do NOT trigger MinGW auto-import, so force-undef the
           used ones to pull their import thunks (otherwise &Clua_OpenStrlib is
           null and the library is never opened). */
        if ( !MakeStagedOutput( outExe, staged_out, err, errlen ) ) return 0;
        snprintf( cmd, sizeof( cmd ),
                  "%s -o \"%s\" \"%s\" \"%s\" \"%s\" %s%s\"%s\" "
                  "-Wl,--subsystem,console -s -lm -lkernel32 -ladvapi32",
                  GccCommand( ), staged_out, userObj, entry_obj, tc.protoinit_o,
                  require_ffi ? "-Wl,--undefined=Clua_OpenFfi " : "",
                  libundef,
                  tc.rt_implib );
        rc = run_cmd( cmd );
        if ( rc != 0 ) {
            DeleteFileA( staged_out );
            set_errv( err, errlen,
                      "shared-rt link failed (gcc rc=%d; is MinGW-w64 gcc on "
                      "PATH, or set CLUA_GCC): %s", rc, cmd );
            return 0;
        }
        return PublishStagedOutput( staged_out, outExe, err, errlen );
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
    if ( !MakeStagedOutput( outExe, staged_out, err, errlen ) ) return 0;
    snprintf( cmd, sizeof( cmd ),
              "%s -o \"%s\" \"%s\" \"%s\" %s%s%s\"%s\" \"%s\" "
              "-Wl,--subsystem,console -Wl,--gc-sections -s "
              "-lm -lkernel32 -ladvapi32",
              GccCommand( ), staged_out, userObj, entry_obj, lvm_obj,
              require_ffi ? "-Wl,--undefined=Clua_OpenFfi " : "",
              libundef,
              tc.runtime_a, tc.lualib_a );
    rc = run_cmd( cmd );
    if ( rc != 0 ) {
        DeleteFileA( staged_out );
        set_errv( err, errlen,
                  "link failed (gcc rc=%d; is MinGW-w64 gcc on PATH, or set "
                  "CLUA_GCC): %s", rc, cmd );
        return 0;
    }

    return PublishStagedOutput( staged_out, outExe, err, errlen );
}
