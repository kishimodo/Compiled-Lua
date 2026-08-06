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
#include "argexpand.h"
#include "bugreport.h"
#include "common/version.h"   /* CLUA_VERSION_STRING -- the single source of truth */
#include "compiler/diag_pretty.h"
#include "compiler/paths.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>   /* _getpid, _spawnv */
#include <direct.h>    /* _getcwd (clua init project name) */
#ifdef _WIN32
#include <windows.h>   /* GetModuleFileNameA: exe-relative docs + --print-runtime-path */
#endif

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
        "  clua explain <code>               show the reference page for a\n"
        "                                    diagnostic code (E001, W004, ...)\n"
        "  clua bug-report [--out=<path>]    write a Markdown bug report\n"
        "                                    (toolchain version, target triple,\n"
        "                                    CLUA_* env, OS/CWD, git SHA)\n"
        "  clua version                      print version\n"
        "  clua help                         this help\n"
        "  clua --print-target-triple        the compiler's target triple\n"
        "  clua --print-search-dirs          CLUA_HOME + package + sysroot dirs\n"
        "  clua --print-runtime-path         path to runtime-aot.a\n"
        "  clua --print-package-path         path to bundled packages\n"
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
        "  --output=<kind>  one of exe (default), dll, obj, or lib:\n"
        "                     exe  standard console PE (default)\n"
        "                     dll  Windows DLL exporting each function assigned\n"
        "                          into the module's `_exports` table; default\n"
        "                          output name switches to <input>.dll. See\n"
        "                          tests/differential/dll_output.lua.\n"
        "                     obj  publishes the codegen COFF as the final\n"
        "                          artifact and skips linking. Default name:\n"
        "                          <input>.obj. Suitable for feeding into a\n"
        "                          downstream linker (gcc/ld, MinGW, or MSVC).\n"
        "                     lib  wraps that same COFF in a single-member\n"
        "                          GNU-form ar archive (`.lib`, deterministic\n"
        "                          headers). MinGW `ar`/`ld` consume it as-is;\n"
        "                          MSVC `link.exe` wants a `.lib` with a second\n"
        "                          linker member (round-trip through `lib.exe\n"
        "                          /convert`, or use `--output=dll` with\n"
        "                          `--emit-def=<path>`).\n"
        "                   obj and lib skip aot_entry and the runtime archives,\n"
        "                   so they are incompatible with --shared-rt (no link\n"
        "                   step happens) and with `clua run` (nothing to run).\n"
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
        "  -v, --verbose    print per-phase wall-clock timings on stderr\n"
        "                   after the build (resolve, lift, optimize,\n"
        "                   codegen, link, total). Off = zero overhead.\n"
        "  -g, --debug      emit a .clualn (native offset -> Lua source line)\n"
        "                   debug section into the produced PE, one per\n"
        "                   compiled function. Consumed by\n"
        "                   tools\\decode-clualn.lua. Off by default.\n"
        "  --no-cache       disable the persistent per-function compilation\n"
        "                   cache (both read and write) for this invocation.\n"
        "                   Equivalent to setting CLUA_NO_CACHE=1.\n"
        "  --cache-dir=<path>\n"
        "                   override the default cache directory. Default is\n"
        "                   %%LOCALAPPDATA%%\\clua\\cache (or\n"
        "                   $XDG_CACHE_HOME/clua when set).\n"
        "  --emit-def=<path> / --emit-implib=<path>\n"
        "                   for DLL builds, write a .DEF module-definition\n"
        "                   file at <path> listing the DLL's exports. Both\n"
        "                   MSVC (`link /def:foo.def /dll`) and MinGW\n"
        "                   (`dlltool -d foo.def -D foo.dll -l foo.lib`)\n"
        "                   consume the .def to synthesize the matching\n"
        "                   import library. Default: <dll-basename>.def\n"
        "                   beside the DLL. Ignored for .exe builds.\n"
        "  --emit-compdb=<path>\n"
        "                   write a compile_commands.json file at <path>\n"
        "                   containing one entry (directory / file /\n"
        "                   arguments) describing this invocation. clangd,\n"
        "                   VS Code C/C++, and ccls read this to offer\n"
        "                   navigation and hover over CLua sources.\n"
        "                   Overwrites <path> if present.\n"
        "  --emit-compdb-append=<path>\n"
        "                   like --emit-compdb but appends to the array in\n"
        "                   <path> (or creates it). Use this from a build\n"
        "                   driver that compiles many entry points and wants\n"
        "                   one JSON array per workspace.\n"
        "  --emit-depfile=<path> / -MD\n"
        "                   write a make-style dependency file listing every\n"
        "                   module the resolver walked. `-MD` derives the\n"
        "                   path as <output-basename>.d beside the exe.\n"
        "  --strip=none|debug|all\n"
        "                   linker strip mode. `all` (default) drops every\n"
        "                   debug/symbol byte the loader does not need;\n"
        "                   `debug` drops .clualn / .debug* but keeps other\n"
        "                   symbols; `none` keeps everything (grows the exe).\n"
        "                   -g without --strip auto-upgrades to `none` so the\n"
        "                   requested .clualn actually survives the link.\n"
        "  @<file>          any argument starting with `@` is treated as a\n"
        "                   response file: its whitespace-separated tokens\n"
        "                   are spliced into argv at that position (one level\n"
        "                   deep; nested @ is left as a literal token).\n"
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
        "                   OPTIONAL -- the default internal linker needs none.\n"
        "  CLUA_NO_CACHE    set to a non-empty non-zero value to disable the\n"
        "                   persistent per-function compilation cache.\n"
        "  XDG_CACHE_HOME / LOCALAPPDATA\n"
        "                   root for the cache dir (<root>/clua/cache).\n" );
}

/* dir/app.lua -> "app.<ext>" in the CWD, heap-allocated. Extension picked by
** the output kind:
**   LC_OUTPUT_EXE -> ".exe"
**   LC_OUTPUT_DLL -> ".dll"
**   LC_OUTPUT_OBJ -> ".obj"
**   LC_OUTPUT_LIB -> ".lib"
**
** The .obj/.lib extensions match the Windows convention downstream toolchains
** (link.exe, lib.exe, MinGW ld) reach for when consuming the artifact. */
static char *derive_output( const char *input, int kind ) {
    const char *base = input, *p, *dot;
    const char *suffix;
    size_t      n;
    char       *out;

    switch ( kind ) {
        case LC_OUTPUT_DLL: suffix = ".dll"; break;
        case LC_OUTPUT_OBJ: suffix = ".obj"; break;
        case LC_OUTPUT_LIB: suffix = ".lib"; break;
        default:            suffix = ".exe"; break;
    }

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
    if ( strcmp( val, "ast"      ) == 0 ) { a->opt.emit_mode = LC_EMIT_AST;      return 1; }
    fprintf( stderr, "clua: unknown --emit mode '%s' "
                     "(supported: bytecode, ir, asm, ast)\n", val );
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
            } else if ( strcmp( kind, "obj" ) == 0 ) {
                a->opt.output_kind = LC_OUTPUT_OBJ;
            } else if ( strcmp( kind, "lib" ) == 0 ) {
                a->opt.output_kind = LC_OUTPUT_LIB;
            } else {
                fprintf( stderr, "clua: unknown --output kind '%s' "
                                 "(supported: exe, dll, obj, lib; "
                                 "see `clua help`)\n", kind );
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
        } else if ( strcmp( s, "--no-cache" ) == 0 ) {
            /* Disable the persistent per-function compilation cache for this
               invocation. Same effect as setting CLUA_NO_CACHE=1. */
            a->opt.no_cache = true;
        } else if ( strncmp( s, "--cache-dir=", 12 ) == 0 ) {
            /* Override the default cache directory. */
            a->opt.cache_dir = s + 12;
        } else if ( strncmp( s, "--color=", 8 ) == 0 ) {
            LC_DIAG_COLOR_MODE_T mode;
            if ( !LcDiag_ParseColorMode( s + 8, &mode ) ) {
                fprintf( stderr, "clua: unknown --color '%s' "
                                 "(expected: auto|always|never)\n", s + 8 );
                return 0;
            }
            LcDiag_SetColorMode( mode );
        } else if ( strncmp( s, "--diagnostics-format=", 21 ) == 0 ) {
            LC_DIAG_FORMAT_T fmt;
            if ( !LcDiag_ParseFormat( s + 21, &fmt ) ) {
                fprintf( stderr, "clua: unknown --diagnostics-format '%s' "
                                 "(expected: text|json)\n", s + 21 );
                return 0;
            }
            LcDiag_SetFormat( fmt );
        } else if ( strcmp( s, "-v" ) == 0 || strcmp( s, "--verbose" ) == 0 ) {
            /* Per-phase wall-clock on stderr after the build. Off by default;
            ** the driver only samples QPC when the flag is set. NOTE: `clua
            ** -v` at the top-level still means "version" -- that path never
            ** reaches parse_build_args. */
            a->opt.verbose = true;
        } else if ( strcmp( s, "-g" ) == 0 || strcmp( s, "--debug" ) == 0 ) {
            /* Emit the .clualn (native-pc -> Lua-line) debug section into
            ** the produced PE. See tools/decode-clualn.lua. Off by default. */
            a->opt.debug_line_info = true;
        } else if ( ( emit_rc = parse_emit_arg( a, s ) ) != -1 ) {
            if ( emit_rc == 0 ) return 0;
        } else if ( strncmp( s, "--emit-compdb=", 14 ) == 0 ) {
            a->opt.compdb_path   = s + 14;
            a->opt.compdb_append = false;
        } else if ( strncmp( s, "--emit-compdb-append=", 21 ) == 0 ) {
            a->opt.compdb_path   = s + 21;
            a->opt.compdb_append = true;
        } else if ( strncmp( s, "--emit-depfile=", 15 ) == 0 ) {
            /* Make-style dependency file listing every module the resolver
            ** walked, mirroring gcc's `-MF <path>`. Off unless the user asks. */
            a->opt.depfile_path = s + 15;
        } else if ( strcmp( s, "-MD" ) == 0 ) {
            /* gcc-compatible shorthand: --emit-depfile=<output-basename>.d.
            ** lc_drive derives the real path (needs the resolved output). */
            a->opt.depfile_path = "-MD";
        } else if ( strncmp( s, "--strip=", 8 ) == 0 ) {
            const char *m = s + 8;
            if      ( strcmp( m, "none"  ) == 0 ) a->opt.strip_mode = LC_STRIP_NONE;
            else if ( strcmp( m, "debug" ) == 0 ) a->opt.strip_mode = LC_STRIP_DEBUG;
            else if ( strcmp( m, "all"   ) == 0 ) a->opt.strip_mode = LC_STRIP_ALL;
            else {
                fprintf( stderr, "clua: unknown --strip mode '%s' "
                                 "(supported: none, debug, all)\n", m );
                return 0;
            }
            a->opt.strip_mode_explicit = true;
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
        } else if ( s[0] == '-' && s[1] == 'W' && s[2] != '\0' ) {
            /* Diagnostic-category flags. See main.c for the same branch;
            ** placed BEFORE the "unknown argument" fall-through below so a
            ** legitimate -Wunused / -Werror is never rejected. An unknown
            ** category is reported by LcWarn_ParseFlag (returns 0), we keep
            ** parsing so the rest of the command line is still processed
            ** rather than aborting the build on a lint typo. */
            ( void )LcWarn_ParseFlag( &a->opt.warn, s + 2 );
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
    a.opt.drv_argc = argc;
    a.opt.drv_argv = ( const char *const * )argv;
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
    a.opt.drv_argc   = argc;
    a.opt.drv_argv   = ( const char *const * )argv;
    return lc_drive( &a.opt );
}

static int cmd_run( int argc, char **argv, int from ) {
    CluaArgs    a;
    char        exe_path[ 1024 ];
    const char *tmpdir;
    int         rc, i, n;
    const char **child_argv;

    if ( !parse_build_args( &a, argc, argv, from, 1 ) ) return 2;

    /* `clua run` compiles then executes the produced artifact. --output=obj /
    ** --output=lib yield a COFF object / static archive respectively -- neither
    ** is runnable on its own -- so reject the combination up front rather than
    ** stage a temp file the child _spawnv could not launch. */
    if ( a.opt.output_kind == LC_OUTPUT_OBJ ||
         a.opt.output_kind == LC_OUTPUT_LIB ) {
        fprintf( stderr, "clua: error: `clua run` is incompatible with "
                         "--output=%s (nothing to run; use `clua build` to "
                         "produce the artifact)\n",
                 ( a.opt.output_kind == LC_OUTPUT_OBJ ) ? "obj" : "lib" );
        return 2;
    }

    tmpdir = getenv( "TEMP" );
    if ( tmpdir == NULL || tmpdir[0] == '\0' ) tmpdir = getenv( "TMP" );
    if ( tmpdir == NULL || tmpdir[0] == '\0' ) tmpdir = ".";
    snprintf( exe_path, sizeof( exe_path ), "%s\\clua_run_%d.exe",
              tmpdir, ( int )_getpid( ) );
    a.opt.output   = exe_path;
    a.opt.drv_argc = argc;
    a.opt.drv_argv = ( const char *const * )argv;

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

/* Locate docs/errors/<code>.md in the toolchain layout. Discovery mirrors
** Paths_BuiltinPackagesRoot so a dist install works from any CWD:
**   1. CWD repo checkout      docs/errors
**   2. exe-relative repo      <exedir>/../../docs/errors
**   3. exe-relative dist      <exedir>/docs/errors, <exedir>/../docs/errors
**   4. %CLUA_HOME%            <home>/docs/errors
** Returns 1 with OutPath populated on success, 0 on miss. */
static int probe_errors_file( const char *root, const char *sep,
                              const char *code, char *out, size_t out_sz ) {
    FILE *f;
    int n = snprintf( out, out_sz, "%s%s%s.md", root, sep, code );
    if ( n <= 0 || ( size_t )n >= out_sz ) return 0;
    f = fopen( out, "rb" );
    if ( f == NULL ) return 0;
    fclose( f );
    return 1;
}

static int find_error_doc( const char *code, char *out, size_t out_sz ) {
    /* 1. CWD repo checkout */
    if ( probe_errors_file( "docs/errors", "/", code, out, out_sz ) ) return 1;

#ifdef _WIN32
    /* 2 + 3. exe-relative */
    {
        char exe[ 512 ] = { 0 };
        if ( GetModuleFileNameA( NULL, exe, sizeof( exe ) ) > 0 ) {
            char *slash = strrchr( exe, '\\' );
            if ( slash != NULL ) {
                *slash = '\0';
                static const char *rel[ 4 ] = {
                    "\\..\\..\\docs\\errors",
                    "\\docs\\errors",
                    "\\..\\docs\\errors",
                    "\\..\\share\\clua\\docs\\errors",
                };
                for ( int i = 0; i < 4; i++ ) {
                    char root[ 700 ];
                    int n = snprintf( root, sizeof( root ), "%s%s", exe, rel[ i ] );
                    if ( n <= 0 || ( size_t )n >= sizeof( root ) ) continue;
                    if ( probe_errors_file( root, "\\", code, out, out_sz ) )
                        return 1;
                }
            }
        }
    }
#endif

    /* 4. CLUA_HOME */
    {
        const char *home = getenv( "CLUA_HOME" );
        if ( home != NULL && home[ 0 ] != '\0' ) {
            char root[ 700 ];
            int n = snprintf( root, sizeof( root ), "%s\\docs\\errors", home );
            if ( n > 0 && ( size_t )n < sizeof( root ) &&
                 probe_errors_file( root, "\\", code, out, out_sz ) )
                return 1;
            n = snprintf( root, sizeof( root ), "%s/docs/errors", home );
            if ( n > 0 && ( size_t )n < sizeof( root ) &&
                 probe_errors_file( root, "/", code, out, out_sz ) )
                return 1;
        }
    }
    return 0;
}

/* `clua explain <code>` — print the reference page for a diagnostic code.
** Accepts any case (E001, e001), rejects anything that doesn't look like a
** code (letter + digits). Exits non-zero on missing/unknown code. */
static int cmd_explain( int argc, char **argv, int from ) {
    const char *raw;
    char        code[ 32 ] = { 0 };
    char        path[ 800 ] = { 0 };
    size_t      i, len;
    FILE       *f;
    char        buf[ 4096 ];
    size_t      n;

    if ( from >= argc ) {
        fprintf( stderr, "clua explain: missing code (e.g. `clua explain E001`; "
                         "codes appear in the [E###] or [W###] bracket on\n"
                         "diagnostic messages)\n" );
        return 2;
    }
    raw = argv[ from ];
    len = strlen( raw );
    if ( len == 0 || len >= sizeof( code ) ) {
        fprintf( stderr, "clua explain: invalid code '%s'\n", raw );
        return 2;
    }
    /* Uppercase the letter; keep the digits. Reject anything that isn't a
    ** single leading letter followed by digits. */
    if ( !( ( raw[ 0 ] >= 'A' && raw[ 0 ] <= 'Z' ) ||
            ( raw[ 0 ] >= 'a' && raw[ 0 ] <= 'z' ) ) ) {
        fprintf( stderr, "clua explain: code must start with a letter "
                         "(e.g. E001, W004); got '%s'\n", raw );
        return 2;
    }
    code[ 0 ] = ( char )( ( raw[ 0 ] >= 'a' && raw[ 0 ] <= 'z' )
                          ? raw[ 0 ] - ( 'a' - 'A' ) : raw[ 0 ] );
    for ( i = 1; i < len; i++ ) {
        if ( raw[ i ] < '0' || raw[ i ] > '9' ) {
            fprintf( stderr, "clua explain: code must be a letter followed by "
                             "digits (e.g. E001, W004); got '%s'\n", raw );
            return 2;
        }
        code[ i ] = raw[ i ];
    }
    code[ len ] = '\0';

    if ( !find_error_doc( code, path, sizeof( path ) ) ) {
        fprintf( stderr, "clua explain: no explanation for code %s\n", code );
        return 1;
    }
    f = fopen( path, "rb" );
    if ( f == NULL ) {
        fprintf( stderr, "clua explain: cannot open %s\n", path );
        return 1;
    }
    while ( ( n = fread( buf, 1, sizeof( buf ), f ) ) > 0 ) {
        fwrite( buf, 1, n, stdout );
    }
    fclose( f );
    return 0;
}

/* --print-<name> diagnostic helpers (see the four --print-* CLI flags):
** each one prints ONE line and exits 0. Same behaviour as clang / gcc's
** `-print-<name>` flags. */
static void print_search_dirs( void ) {
    const char *home = getenv( "CLUA_HOME" );
    char        pkgs[ 1024 ] = { 0 };
    printf( "CLUA_HOME=%s\n", ( home && home[ 0 ] ) ? home : "(unset)" );
    if ( Paths_BuiltinPackagesRoot( pkgs, sizeof( pkgs ) ) ) {
        printf( "packages=%s\n", pkgs );
    } else {
        printf( "packages=(not found)\n" );
    }
    printf( "cwd-sysroot=%s\n", "build\\bin\\sysroot" );
}

static void print_runtime_path( void ) {
    const char *home = getenv( "CLUA_HOME" );
    char        exedir[ 1024 ] = { 0 };
    if ( home && home[ 0 ] ) {
        printf( "%s\\lib\\runtime-aot.a\n", home );
        return;
    }
    if ( GetModuleFileNameA( NULL, exedir, sizeof( exedir ) ) > 0 ) {
        char *slash = strrchr( exedir, '\\' );
        if ( slash ) *slash = '\0';
        printf( "%s\\lib\\runtime-aot.a\n", exedir );
        return;
    }
    printf( "runtime-aot.a\n" );
}

static void print_package_path( void ) {
    char pkgs[ 1024 ] = { 0 };
    if ( Paths_BuiltinPackagesRoot( pkgs, sizeof( pkgs ) ) ) {
        printf( "%s\n", pkgs );
    } else {
        printf( "(not found)\n" );
    }
}

/* `clua bug-report [--out=<path>]` -- collect toolchain state into a
** self-contained Markdown file the user can drop into an issue. Doc:
** clua/src/driver/bugreport.h. Returns the CLI exit code. */
static int cmd_bug_report( int argc, char **argv, int from ) {
    const char *out = NULL;
    char        used[ 512 ] = { 0 };
    char        err[ 256 ] = { 0 };
    int         i;
    for ( i = from; i < argc; i++ ) {
        const char *s = argv[ i ];
        if ( strncmp( s, "--out=", 6 ) == 0 ) {
            out = s + 6;
        } else if ( strcmp( s, "--out" ) == 0 && i + 1 < argc ) {
            out = argv[ ++i ];
        } else {
            fprintf( stderr,
                     "clua: unknown argument '%s' to bug-report\n", s );
            return 2;
        }
    }
    if ( !LcBugreport_Write( out, used, sizeof( used ),
                             err, sizeof( err ) ) ) {
        fprintf( stderr, "clua: bug-report failed: %s\n",
                 err[ 0 ] ? err : "(no detail)" );
        return 1;
    }
    printf( "[+] wrote bug report to %s\n", used );
    return 0;
}

int main( int raw_argc, char **raw_argv ) {
    const char *cmd;
    int         argc = 0;
    char      **argv = LcArg_Expand( raw_argc, raw_argv, &argc );
    int         rc;

    if ( argv == NULL ) return 2;

    /* --print-* flags win over everything else so `clua --print-...` works
    ** at the top level too, not just inside a build. Scan argv up front. */
    {
        int i;
        for ( i = 1; i < argc; i++ ) {
            const char *a = argv[ i ];
            if ( strcmp( a, "--print-target-triple" ) == 0 ) {
                printf( "%s\n", LcBugreport_TargetTriple( ) );
                LcArg_FreeExpanded( argc, argv );
                return 0;
            }
            if ( strcmp( a, "--print-search-dirs" ) == 0 ) {
                print_search_dirs( );
                LcArg_FreeExpanded( argc, argv );
                return 0;
            }
            if ( strcmp( a, "--print-runtime-path" ) == 0 ) {
                print_runtime_path( );
                LcArg_FreeExpanded( argc, argv );
                return 0;
            }
            if ( strcmp( a, "--print-package-path" ) == 0 ) {
                print_package_path( );
                LcArg_FreeExpanded( argc, argv );
                return 0;
            }
        }
    }

    if ( argc < 2 ) { usage( stderr ); LcArg_FreeExpanded( argc, argv ); return 2; }
    cmd = argv[ 1 ];

    if ( strcmp( cmd, "build"      ) == 0 ) { rc = cmd_build  ( argc, argv, 2 ); goto done; }
    if ( strcmp( cmd, "run"        ) == 0 ) { rc = cmd_run    ( argc, argv, 2 ); goto done; }
    if ( strcmp( cmd, "check"      ) == 0 ) { rc = cmd_check  ( argc, argv, 2 ); goto done; }
    if ( strcmp( cmd, "init"       ) == 0 ) { rc = cmd_init   ( argc, argv, 2 ); goto done; }
    if ( strcmp( cmd, "explain"    ) == 0 ) { rc = cmd_explain( argc, argv, 2 ); goto done; }
    if ( strcmp( cmd, "bug-report" ) == 0 ) { rc = cmd_bug_report( argc, argv, 2 ); goto done; }
    if ( strcmp( cmd, "version" ) == 0 || strcmp( cmd, "--version" ) == 0 ||
         strcmp( cmd, "-v" ) == 0 ) {
        printf( "clua " CLUA_VERSION " (Lua 5.4, x86-64 Windows)\n" );
        LcArg_FreeExpanded( argc, argv );
        return 0;
    }
    if ( strcmp( cmd, "help" ) == 0 || strcmp( cmd, "--help" ) == 0 ||
         strcmp( cmd, "-h" ) == 0 ) {
        usage( stdout );
        LcArg_FreeExpanded( argc, argv );
        return 0;
    }

    /* `clua app.lua` == `clua build app.lua` */
    {
        size_t len = strlen( cmd );
        if ( len > 4 && strcmp( cmd + len - 4, ".lua" ) == 0 ) {
            rc = cmd_build( argc, argv, 1 );
            goto done;
        }
    }

    fprintf( stderr, "clua: unknown command '%s' (see `clua help`)\n", cmd );
    LcArg_FreeExpanded( argc, argv );
    return 2;
done:
    LcArg_FreeExpanded( argc, argv );
    return rc;
}

#else /* !LUAC_CLUA_STANDALONE */

/* Keep this translation unit non-empty for the plain wildcard build that
** lands in the unit-test archive (no main() there — see file banner). */
typedef int clua_main_not_built;

#endif /* LUAC_CLUA_STANDALONE */
