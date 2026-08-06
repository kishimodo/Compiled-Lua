/*
** clua_main.c — clua.exe, the CLua toolchain front-end.
**
** The single binary a user interacts with (the rustc/go of CLua):
**
**   clua build <main.lua> [-o <out.exe>] [-O0|-O1|-O2|-O3] [-L <pkg>] [--keep-temps]
**   clua run   <main.lua> [build flags] [-- <program args...>]
**   clua check <main.lua>
**   clua version | help
**   clua <main.lua>          (implicit `build`)
**
** Differences from aotc.exe (the low-level driver kept for test infra):
** -O2 is the default (aotc defaults to -O0), the output name derives from the input
** (dir/app.lua -> app.exe in the CWD), and `run` compiles to %TEMP% and
** executes in place. Both front-ends share lc_drive() — same pipeline,
** same fidelity guarantees.
**
** Wrapped in LUAC_CLUA_STANDALONE: the base Makefile's wildcard compiles
** every src/driver/*.c into the unit-test archive, and an unguarded main()
** here would collide with each test's own main().
*/
#ifdef LUAC_CLUA_STANDALONE

#include "aotc.h"
#include "common/version.h"   /* CLUA_VERSION_STRING -- the single source of truth */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>   /* _getpid, _spawnv */
#include <direct.h>    /* _getcwd (clua init project name) */

#define CLUA_VERSION CLUA_VERSION_STRING

static void usage( FILE *to ) {
    fprintf( to,
        "clua " CLUA_VERSION " — the CLua toolchain (Lua 5.4 -> native x64)\n"
        "\n"
        "usage:\n"
        "  clua build <main.lua> [options]   compile to a native .exe\n"
        "  clua run   <main.lua> [options] [-- <args...>]\n"
        "                                    compile and run\n"
        "  clua check <main.lua>             front-end + closed-world check only\n"
        "  clua init [name]                  scaffold a project here (main.lua,\n"
        "                                    rover.toml, .gitignore)\n"
        "  clua version                      print version\n"
        "  clua help                         this help\n"
        "\n"
        "build options:\n"
        "  -o <out.exe>     output path (default: <input-basename>.exe)\n"
        "  -O0|-O1|-O2|-O3  optimization level (default: -O2). What each does today:\n"
        "                     -O0  no optimizer passes; faithful boxed baseline\n"
        "                     -O1  type inference + interprocedural type propagation,\n"
        "                          plus the typed codegen fastpaths (tag-check\n"
        "                          elision, integer FORLOOP, loop register\n"
        "                          residency). Costs about 14 KB over -O0.\n"
        "                     -O2  the SAME BYTES as -O1 today: the three passes this\n"
        "                          level gates (monomorphize, ip_devirt, dead_global)\n"
        "                          are not implemented yet.\n"
        "                     -O3  -O2 plus scalar replacement of non-escaping\n"
        "                          constant-key tables (real, but narrow).\n"
        "                   -Os and -Oz do not exist: they are rejected, not ignored.\n"
        "  -L <pkg>         force-bundle a package\n"
        "  --output=<kind>  exe (default) or dll. dll produces a Windows DLL\n"
        "                   exporting each function assigned into the module's\n"
        "                   `_exports` table; default output name switches to\n"
        "                   <input>.dll. See tests/differential/dll_output.lua.\n"
        "  -shared          shorthand for --output=dll (matches gcc/link.exe).\n"
        "  --keep-temps     keep the intermediate object file\n"
        "  --shared-rt      link against the shared runtime (clua-rt.dll)\n"
        "                   instead of the static archives: ~30 KB exes for\n"
        "                   many-tool workspaces. The exe needs clua-rt.dll\n"
        "                   beside it (or on PATH) at run time — copy it from\n"
        "                   <toolchain>\\lib\\ (repo: build\\bin\\). Default\n"
        "                   stays fully static, single-file.\n"
        "  --ld=internal    force the built-in COFF->PE64 linker (no gcc;\n"
        "                   needs the shipped lib\\sysroot). This is the\n"
        "                   DEFAULT when the sysroot is present.\n"
        "  --ld=gcc         force the MinGW gcc/ld link (needs gcc on PATH).\n"
        "  --no-gc-sections-internal\n"
        "                   disable the built-in linker's dead-code sweep\n"
        "                   (debug; larger exe).\n"
        "  -j <N>           parallel per-function codegen workers. -j 1 is\n"
        "                   the sequential path (no threads). Omit -j to let\n"
        "                   CLUA_JOBS decide, falling back to the CPU count.\n"
        "  --emit=<mode>    diagnostic dump. <mode> is one of:\n"
        "                     bytecode  Lua 5.4 bytecode per Proto (luac -l)\n"
        "                     ir        optimized LcModule before codegen\n"
        "                     asm       emitted x64 as an assembly listing\n"
        "                   With no -o the dump lands on stdout and NO\n"
        "                   binary is produced. With -o the binary is still\n"
        "                   written and the dump lands on stdout; add\n"
        "                   --emit-only to repurpose -o as the dump path.\n"
        "                   `-o -` writes the dump to stdout explicitly.\n"
        "  --emit-only      suppress the binary output even when -o is set\n"
        "                   (only meaningful with --emit=<mode>). With\n"
        "                   --emit-only the -o path is the dump destination.\n"
        "  --emit-def=<path> / --emit-implib=<path>\n"
        "                   for DLL builds, write a .DEF module-definition\n"
        "                   file at <path> listing the DLL's exports. Both\n"
        "                   MSVC (`link /def:foo.def /dll`) and MinGW\n"
        "                   (`dlltool -d foo.def -D foo.dll -l foo.lib`)\n"
        "                   consume the .def to synthesize the matching\n"
        "                   import library. Default: <dll-basename>.def\n"
        "                   beside the DLL. Ignored for .exe builds.\n"
        "\n"
        "environment:\n"
        "  CLUA_HOME        CLua installation root (lib\\runtime-aot.a ...)\n"
        "  CLUA_LD          force the linker: 'internal' (built-in, no gcc) or\n"
        "                   'gcc'. Unset = internal when lib\\sysroot ships,\n"
        "                   else gcc.\n"
        "  CLUA_JOBS        parallel codegen job count; overridden by -j.\n"
        "                   Default is the CPU count clamped to the module's\n"
        "                   function count. Set to 1 for the sequential path.\n"
        "  CLUA_GCC         gcc driver for --ld=gcc / --shared-rt / cold trees\n"
        "                   (default: x86_64-w64-mingw32-gcc on PATH). gcc is\n"
        "                   OPTIONAL -- the default internal linker needs none.\n" );
}

/* dir/app.lua -> "app.exe" (or "app.dll" when kind == LC_OUTPUT_DLL), in the
** CWD, heap-allocated. */
static char *derive_output( const char *input, int kind ) {
    const char *base = input, *p, *dot;
    const char *suffix = ( kind == LC_OUTPUT_DLL ) ? ".dll" : ".exe";
    size_t      n;
    char       *out;

    for ( p = input; *p; p++ ) {
        if ( *p == '/' || *p == '\\' ) base = p + 1;
    }
    dot = strrchr( base, '.' );
    n   = ( dot && dot != base ) ? ( size_t )( dot - base ) : strlen( base );
    out = ( char * )malloc( n + 5 );
    if ( out == NULL ) return NULL;
    memcpy( out, base, n );
    memcpy( out + n, suffix, 5 );
    return out;
}

typedef struct {
    LcDriverOptions opt;
    const char     *force[ 64 ];
    int             run_arg0;      /* argv index of "--" + 1 (run only), or 0 */
} CluaArgs;

/* --emit=<mode> ; error message includes the accepted values so a typo lands
** somewhere useful. Returns 1 on match/success, 0 on match/failure, -1 on
** no-match (caller keeps scanning). */
static int parse_emit_arg( CluaArgs *a, const char *s ) {
    const char *val;
    if ( strncmp( s, "--emit=", 7 ) != 0 ) return -1;
    val = s + 7;
    if ( strcmp( val, "bytecode" ) == 0 ) { a->opt.emit_mode = LC_EMIT_BYTECODE; return 1; }
    if ( strcmp( val, "ir"       ) == 0 ) { a->opt.emit_mode = LC_EMIT_IR;       return 1; }
    if ( strcmp( val, "asm"      ) == 0 ) { a->opt.emit_mode = LC_EMIT_ASM;      return 1; }
    fprintf( stderr, "clua: unknown --emit mode '%s' "
                     "(supported: bytecode, ir, asm)\n", val );
    return 0;
}

/* Parse build/run/check flags from argv[from..argc). Returns 0 on error. */
static int parse_build_args( CluaArgs *a, int argc, char **argv, int from,
                             int allow_dashdash ) {
    int i, nforce = 0;

    memset( a, 0, sizeof( *a ) );
    a->opt.opt_level = 2;                       /* clua default. NOTE: -O2 currently emits the SAME BYTES
                                                ** as -O1 -- the M2 interprocedural passes are stubs. The
                                                ** default is 2 for forward compatibility, and usage()
                                                ** says so per level rather than implying work happens. */
    a->opt.ld_internal = -1;                    /* env (CLUA_LD) decides   */

    for ( i = from; i < argc; i++ ) {
        const char *s = argv[ i ];
        int emit_rc;
        if ( strcmp( s, "--" ) == 0 && allow_dashdash ) {
            a->run_arg0 = i + 1;
            break;
        } else if ( strcmp( s, "-o" ) == 0 && i + 1 < argc ) {
            a->opt.output = argv[ ++i ];
        } else if ( s[0] == '-' && s[1] == 'O' ) {
            if ( !lc_parse_opt_level( s, &a->opt.opt_level ) ) {
                fprintf( stderr, "clua: unsupported optimization level '%s' "
                                 "(use -O0, -O1, -O2 or -O3; see `clua help`)\n", s );
                return 0;
            }
        } else if ( strcmp( s, "--keep-temps" ) == 0 ) {
            a->opt.keep_temps = true;
        } else if ( strcmp( s, "-shared" ) == 0 ) {
            /* GCC-style shorthand for --output=dll. */
            a->opt.output_kind = LC_OUTPUT_DLL;
        } else if ( strncmp( s, "--output=", 9 ) == 0 ) {
            const char *kind = s + 9;
            if ( strcmp( kind, "exe" ) == 0 ) {
                a->opt.output_kind = LC_OUTPUT_EXE;
            } else if ( strcmp( kind, "dll" ) == 0 ) {
                a->opt.output_kind = LC_OUTPUT_DLL;
            } else {
                fprintf( stderr, "clua: unknown --output kind '%s' "
                                 "(supported: exe, dll; see `clua help`)\n", kind );
                return 0;
            }
        } else if ( strcmp( s, "--shared-rt" ) == 0 ) {
            a->opt.shared_rt = true;
        } else if ( strcmp( s, "--ld=internal" ) == 0 ) {
            a->opt.ld_internal = 1;
        } else if ( strcmp( s, "--ld=gcc" ) == 0 ) {
            a->opt.ld_internal = 0;
        } else if ( strcmp( s, "--no-gc-sections-internal" ) == 0 ) {
            a->opt.no_gc_sections = true;
        } else if ( strcmp( s, "-j" ) == 0 && i + 1 < argc ) {
            /* -j N: parallel per-function codegen. -j 1 is the sequential
               path; -j 0 means "decide from CLUA_JOBS or the CPU count". */
            int n = atoi( argv[ ++i ] );
            if ( n < 0 ) n = 1;
            a->opt.jobs = n;
        } else if ( strcmp( s, "--emit-only" ) == 0 ) {
            a->opt.emit_only = true;
        } else if ( ( emit_rc = parse_emit_arg( a, s ) ) != -1 ) {
            if ( emit_rc == 0 ) return 0;
        } else if ( strncmp( s, "--emit-def=", 11 ) == 0 ) {
            a->opt.emit_def_path = s + 11;
        } else if ( strncmp( s, "--emit-implib=", 14 ) == 0 ) {
            /* Alias: users reach for "implib"; we always emit the .def
            ** (both MSVC link.exe and MinGW dlltool consume it). */
            a->opt.emit_def_path = s + 14;
        } else if ( ( strcmp( s, "-L" ) == 0 || strcmp( s, "--link" ) == 0 )
                    && i + 1 < argc ) {
            if ( nforce < 63 ) {
                a->force[ nforce++ ] = argv[ ++i ];
                a->force[ nforce ]   = NULL;
            } else {
                ++i;
            }
        } else if ( s[0] != '-' && a->opt.input == NULL ) {
            a->opt.input = s;
        } else {
            fprintf( stderr, "clua: unknown argument '%s' (see `clua help`)\n", s );
            return 0;
        }
    }
    if ( a->opt.input == NULL ) {
        fprintf( stderr, "clua: no input file (see `clua help`)\n" );
        return 0;
    }
    if ( nforce > 0 ) {
        a->opt.force_pkgs  = a->force;
        a->opt.nforce_pkgs = nforce;
    }
    return 1;
}

static int cmd_build( int argc, char **argv, int from ) {
    CluaArgs a;
    char    *derived = NULL;
    int      rc;

    if ( !parse_build_args( &a, argc, argv, from, 0 ) ) return 2;
    /* Only synthesise an output path when a binary is actually going to be
    ** written. In pure-diagnostic mode (--emit=X with no -o, or --emit-only
    ** without -o) the driver leaves opt.output NULL and skips linking. When
    ** the binary IS going to be written, the output kind (exe vs dll)
    ** decides the suffix on the derived name. */
    if ( a.opt.output == NULL &&
         a.opt.emit_mode == LC_EMIT_NONE &&
         !a.opt.emit_only ) {
        derived = derive_output( a.opt.input, a.opt.output_kind );
        if ( derived == NULL ) { fprintf( stderr, "clua: oom\n" ); return 1; }
        a.opt.output = derived;
    }
    rc = lc_drive( &a.opt );
    free( derived );
    return rc;
}

/* `clua init [name]` — scaffold a project in the CWD, Go-style: a runnable
 * main.lua, a rover.toml manifest (rover's own format), and a .gitignore.
 * Existing files are never overwritten. */
static int write_new_file( const char *path, const char *content ) {
    FILE *probe = fopen( path, "rb" );
    if ( probe != NULL ) { fclose( probe ); return 0; }   /* exists: skip */
    FILE *f = fopen( path, "wb" );
    if ( f == NULL ) return -1;
    fputs( content, f );
    fclose( f );
    return 1;
}

static int cmd_init( int argc, char **argv, int from ) {
    const char *name = ( from < argc && argv[ from ][ 0 ] != '-' )
                         ? argv[ from ] : NULL;
    char cwd[ 512 ] = { 0 };
    char toml[ 1024 ];
    int  rc;

    if ( name == NULL ) {
        /* default project name = current folder name */
        if ( _getcwd( cwd, sizeof( cwd ) ) != NULL ) {
            char *slash = strrchr( cwd, '\\' );
            name = ( slash != NULL && slash[ 1 ] != '\0' ) ? slash + 1 : "my-project";
        } else {
            name = "my-project";
        }
    }

    rc = write_new_file( "main.lua",
        "local function greet(who)\n"
        "    return (\"Hello, %s!\"):format(who)\n"
        "end\n"
        "\n"
        "print(greet(arg[1] or \"world\"))\n" );
    if ( rc > 0 )  printf( "[+] wrote main.lua\n" );
    if ( rc == 0 ) printf( "[=] main.lua already exists, kept\n" );

    snprintf( toml, sizeof( toml ),
        "# rover.toml -- rover (the CLua package manager) project manifest\n"
        "[project]\n"
        "name = \"%s\"\n"
        "version = \"0.1.0\"\n"
        "\n"
        "# Declare dependencies here, then `rover install` (no args) installs them\n"
        "# all and writes rover.lock with resolved versions + sha256 hashes.\n"
        "# `rover add <name>` installs + records a dependency for you.\n"
        "[dependencies]\n"
        "# greet = \"^1.0.0\"\n"
        "\n", name );
    rc = write_new_file( "rover.toml", toml );
    if ( rc > 0 )  printf( "[+] wrote rover.toml\n" );
    if ( rc == 0 ) printf( "[=] rover.toml already exists, kept\n" );

    rc = write_new_file( ".gitignore", "*.exe\nrover.lock\n" );
    if ( rc > 0 )  printf( "[+] wrote .gitignore\n" );

    printf( "[+] project '%s' ready: `clua run main.lua`, `rover add <pkg>`, "
            "`clua build main.lua`\n", name );
    return 0;
}

static int cmd_check( int argc, char **argv, int from ) {
    CluaArgs a;
    if ( !parse_build_args( &a, argc, argv, from, 0 ) ) return 2;
    a.opt.check_only = true;
    a.opt.output     = NULL;
    return lc_drive( &a.opt );
}

static int cmd_run( int argc, char **argv, int from ) {
    CluaArgs    a;
    char        exe_path[ 1024 ];
    const char *tmpdir;
    int         rc, i, n;
    const char **child_argv;

    if ( !parse_build_args( &a, argc, argv, from, 1 ) ) return 2;

    tmpdir = getenv( "TEMP" );
    if ( tmpdir == NULL || tmpdir[0] == '\0' ) tmpdir = getenv( "TMP" );
    if ( tmpdir == NULL || tmpdir[0] == '\0' ) tmpdir = ".";
    snprintf( exe_path, sizeof( exe_path ), "%s\\clua_run_%d.exe",
              tmpdir, ( int )_getpid( ) );
    a.opt.output = exe_path;

    rc = lc_drive( &a.opt );
    if ( rc != 0 ) return rc;

    /* argv for the program: exe + everything after "--". Quote args with
    ** spaces (the CRT joins spawn argv with plain spaces). */
    n = 0;
    if ( a.run_arg0 > 0 ) n = argc - a.run_arg0;
    child_argv = ( const char ** )calloc( ( size_t )n + 2, sizeof( char * ) );
    if ( child_argv == NULL ) { fprintf( stderr, "clua: oom\n" ); return 1; }
    child_argv[ 0 ] = exe_path;
    for ( i = 0; i < n; i++ ) {
        const char *arg = argv[ a.run_arg0 + i ];
        if ( strchr( arg, ' ' ) != NULL ) {
            size_t len = strlen( arg );
            char  *q   = ( char * )malloc( len + 3 );
            if ( q == NULL ) { fprintf( stderr, "clua: oom\n" ); return 1; }
            q[0] = '"';
            memcpy( q + 1, arg, len );
            q[ len + 1 ] = '"';
            q[ len + 2 ] = '\0';
            child_argv[ 1 + i ] = q;
        } else {
            child_argv[ 1 + i ] = arg;
        }
    }
    child_argv[ 1 + n ] = NULL;

    fflush( stdout );   /* the compile banner precedes the program's output */
    rc = ( int )_spawnv( _P_WAIT, exe_path, child_argv );
    if ( rc == -1 ) {
        fprintf( stderr, "clua: failed to run '%s'\n", exe_path );
        rc = 1;
    }
    remove( exe_path );
    return rc;
}

int main( int argc, char **argv ) {
    const char *cmd;

    if ( argc < 2 ) { usage( stderr ); return 2; }
    cmd = argv[ 1 ];

    if ( strcmp( cmd, "build" ) == 0 )   return cmd_build( argc, argv, 2 );
    if ( strcmp( cmd, "run" ) == 0 )     return cmd_run( argc, argv, 2 );
    if ( strcmp( cmd, "check" ) == 0 )   return cmd_check( argc, argv, 2 );
    if ( strcmp( cmd, "init" ) == 0 )    return cmd_init( argc, argv, 2 );
    if ( strcmp( cmd, "version" ) == 0 || strcmp( cmd, "--version" ) == 0 ||
         strcmp( cmd, "-v" ) == 0 ) {
        printf( "clua " CLUA_VERSION " (Lua 5.4, x86-64 Windows)\n" );
        return 0;
    }
    if ( strcmp( cmd, "help" ) == 0 || strcmp( cmd, "--help" ) == 0 ||
         strcmp( cmd, "-h" ) == 0 ) {
        usage( stdout );
        return 0;
    }

    /* `clua app.lua` == `clua build app.lua` */
    {
        size_t len = strlen( cmd );
        if ( len > 4 && strcmp( cmd + len - 4, ".lua" ) == 0 ) {
            return cmd_build( argc, argv, 1 );
        }
    }

    fprintf( stderr, "clua: unknown command '%s' (see `clua help`)\n", cmd );
    return 2;
}

#else /* !LUAC_CLUA_STANDALONE */

/* Keep this translation unit non-empty for the plain wildcard build that
** lands in the unit-test archive (no main() there — see file banner). */
typedef int clua_main_not_built;

#endif /* LUAC_CLUA_STANDALONE */
