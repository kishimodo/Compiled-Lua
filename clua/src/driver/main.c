/*
** main.c — aotc.exe entry. The AOT analogue of v1 src/compiler/main.c.
**
** Pipeline (M0 epsilon end-to-end):
**   front-end + resolve (reused)  ->  undump + closed-world  ->  lift  ->
**   optimize (no-op @ -O0)  ->  codegen  ->  COFF .o + generated ProtoInit .c
**   ->  native link (gcc) into a standard PE.
**
** Unlike v1's "compile to bytecode + embed a blob" path, aotc emits genuine
** x64 machine code per reachable function (luac_fn_<i>) plus a small generated
** C constructor that rebuilds the Protos at startup and registers each native
** body into the dispatch cache. src/runtime/aot_entry.c supplies main().
*/
#include "aotc.h"

#include "../ir/lift.h"
#include "../ir/ir.h"
#include "../opt/passes.h"
#include "../codegen/codegen.h"
#include "../codegen/lc_cache.h"
#include "../codegen/protoblob_emit.h"
#include "../link/coff_write.h"
#include "../link/pe_link_v2.h"
#include "../link/import_lib.h"
#include "../link/ar_write.h"
#include "../common/version.h"    /* CLUA_VERSION_STRING */

#include "../compiler/resolve.h"
#include "../compiler/paths.h"
#include "../compiler/diag.h"
#include "../compiler/warn_unused.h"
#include "../driver/lc_undump.h"
#include "../driver/closed_world.h"
#include "../driver/supported_ops.h"
#include "../driver/compdb.h"
#include "../driver/argexpand.h"
#include "../driver/bugreport.h"
#include "../common/version.h"
#include "../dump/emit.h"

/* Reused front-end produces a Proto*; we read its nested-proto array (p[]) to
** collect the reachable set for lifting. */
#include "lua.h"
#include "lauxlib.h"
#include "lobject.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>   /* _getpid */
#include <direct.h>    /* _getcwd, _fullpath (compile_commands.json emit) */
#include <windows.h>   /* QueryPerformanceCounter / QueryPerformanceFrequency */

/* ------------------------------------------------------------------ */
/* Per-phase wall-clock accumulator for -v / --verbose.               */
/*                                                                     */
/* Everything is a stack-local struct; QPC ticks are only sampled when */
/* opt->verbose is set (the QPC_NOW() helper collapses to a no-op via  */
/* the (verbose) guard at each call site), so an ordinary build pays   */
/* nothing beyond one extra branch per phase boundary.                 */
/*                                                                     */
/* The five phases match the pipeline stages in lc_drive:              */
/*   resolve   -- Resolve_Walk + builtin-package append                 */
/*   lift      -- undump, closed-world scan, Proto collection, lift IR  */
/*   optimize  -- lc_optimize + lc_module_verify                        */
/*   codegen   -- lc_codegen                                            */
/*   link      -- ProtoInit blob + COFF write + LuacLink_LinkProgram    */
/* ------------------------------------------------------------------ */
typedef struct {
    LONGLONG resolve_ticks;
    LONGLONG lift_ticks;
    LONGLONG optimize_ticks;
    LONGLONG codegen_ticks;
    LONGLONG link_ticks;
    /* Counts populated as each phase finishes, for the printed summary.
    ** Zero-initialised: any phase we did not reach stays at 0 and simply
    ** does not surface in its (parenthetical) count column. */
    size_t   n_modules;         /* resolve: total after builtin append   */
    size_t   n_packages;        /* resolve: builtin packages bundled      */
    int      opt_level;         /* optimize: -O level actually run        */
    int      opt_passes_ran;    /* optimize: 1 if lc_optimize ran, else 0 */
    uint32_t n_functions;       /* codegen: reachable Protos              */
    int      jobs;              /* codegen: -j value from opt             */
} LcPhaseTimings;

/* Wall-clock reading. Windows QPC is monotonic and system-wide; a single
** QueryPerformanceFrequency call is enough for the process lifetime. */
static LONGLONG qpc_now( void ) {
    LARGE_INTEGER li;
    QueryPerformanceCounter( &li );
    return li.QuadPart;
}
static LONGLONG qpc_freq( void ) {
    static LONGLONG f = 0;
    if ( f == 0 ) {
        LARGE_INTEGER li;
        QueryPerformanceFrequency( &li );
        f = li.QuadPart ? li.QuadPart : 1;
    }
    return f;
}
static unsigned long qpc_to_ms( LONGLONG ticks ) {
    /* Round to nearest ms; the difference under 0.5 ms is not meaningful
    ** on a wall-clock report. */
    LONGLONG f = qpc_freq( );
    return ( unsigned long )( ( ticks * 1000 + f / 2 ) / f );
}

/* One-shot flush at the end of the build so the timing lines are not
** interleaved with normal progress output. Format matches the fixed
** column layout the driver documents: `[phase]` left-padded to 12
** characters, `NNN ms` right-aligned to 6. Counts (when a phase has
** them) come after the timing, in parentheses. */
static void lc_print_timings( const LcPhaseTimings *t ) {
    unsigned long ms_r = qpc_to_ms( t->resolve_ticks );
    unsigned long ms_l = qpc_to_ms( t->lift_ticks );
    unsigned long ms_o = qpc_to_ms( t->optimize_ticks );
    unsigned long ms_c = qpc_to_ms( t->codegen_ticks );
    unsigned long ms_k = qpc_to_ms( t->link_ticks );
    unsigned long ms_total = ms_r + ms_l + ms_o + ms_c + ms_k;

    fflush( stdout );
    fprintf( stderr, "%-12s%3lu ms  (%zu module%s, %zu package%s)\n",
             "[resolve]", ms_r,
             t->n_modules,  t->n_modules  == 1 ? "" : "s",
             t->n_packages, t->n_packages == 1 ? "" : "s" );
    fprintf( stderr, "%-12s%3lu ms\n", "[lift]", ms_l );
    fprintf( stderr, "%-12s%3lu ms  (-O%d, %d pass%s)\n",
             "[optimize]", ms_o,
             t->opt_level, t->opt_passes_ran,
             t->opt_passes_ran == 1 ? "" : "es" );
    fprintf( stderr, "%-12s%3lu ms  (%u function%s, -j %d)\n",
             "[codegen]", ms_c,
             t->n_functions, t->n_functions == 1 ? "" : "s",
             t->jobs );
    fprintf( stderr, "%-12s%3lu ms\n", "[link]", ms_k );
    fprintf( stderr, "%-12s%3lu ms\n", "total:", ms_total );
    fflush( stderr );
}

/* ------------------------------------------------------------------ */
/* Reachable-Proto collection.                                         */
/*                                                                     */
/* Flatten a Proto tree (entry first, then nested p[] recursively) into */
/* a growable array. lc_lift_program needs every reachable Proto so     */
/* ProtoInit can rebuild the whole tree and map each child p[] back to   */
/* its module index.                                                   */
/* ------------------------------------------------------------------ */
typedef struct {
    Proto  **items;
    uint32_t count;
    uint32_t cap;
} ProtoVec;

static int ProtoVec_Push( ProtoVec *v, Proto *p ) {
    uint32_t i;
    /* de-dup: a Proto can only appear once in the module (ProtoInit maps a
    ** child p[] back to its single module slot). */
    for ( i = 0; i < v->count; i++ ) {
        if ( v->items[i] == p ) return 1;
    }
    if ( v->count == v->cap ) {
        uint32_t nc = v->cap ? v->cap * 2 : 8;
        Proto **ni = ( Proto ** )realloc( v->items, nc * sizeof( Proto * ) );
        if ( ni == NULL ) return 0;
        v->items = ni;
        v->cap   = nc;
    }
    v->items[ v->count++ ] = p;
    return 1;
}

/* Depth-first: push P, then recurse into each nested proto. Entry is pushed
** first so lc_lift_program sees the entry as funcs[...] containing it. */
static int CollectReachable( ProtoVec *v, Proto *p ) {
    int i;
    if ( p == NULL ) return 1;
    if ( !ProtoVec_Push( v, p ) ) return 0;
    for ( i = 0; i < p->sizep; i++ ) {
        if ( !CollectReachable( v, p->p[i] ) ) return 0;
    }
    return 1;
}

/* Open the file the diagnostic dump should be written to.
**
** The rule the task specifies is: "output goes to -o if set, else to
** stdout; -o - means stdout". We honour that only when the caller has
** made it clear the -o path is FOR the diagnostic -- specifically, when
** --emit-only is set (so the binary is suppressed and the -o path is
** free) or when --emit is set with no other consumer of -o (skip_binary
** true). In the common case where --emit runs alongside a binary build,
** -o still names the binary and the dump lands on stdout so redirection
** stays predictable.
**
** Callers close the returned FILE* only if `close_me` is set on return
** (never true for stdout). */
static FILE *OpenEmitOut( const LcDriverOptions *opt, int diagnostic_owns_o,
                          int *close_me ) {
    *close_me = 0;
    if ( diagnostic_owns_o && opt->output != NULL &&
         strcmp( opt->output, "-" ) != 0 ) {
        FILE *f = fopen( opt->output, "wb" );
        if ( f == NULL ) {
            fprintf( stderr, "aotc: error: cannot open --emit output '%s'\n",
                     opt->output );
            return NULL;
        }
        *close_me = 1;
        return f;
    }
    return stdout;
}

/* Escape a single path token for a make-style depfile: whitespace and $ /
** # / : need backslash-quoting so `make` reads the token as one name.
** Writes to `out` (size out_size) and returns the number of bytes written,
** truncating to out_size - 1 if the input is oversized. */
static size_t make_escape( const char *src, char *out, size_t out_size ) {
    size_t si = 0, oi = 0;
    if ( out_size == 0 ) return 0;
    while ( src[ si ] != '\0' && oi + 2 < out_size ) {
        unsigned char c = ( unsigned char )src[ si++ ];
        if ( c == ' ' || c == '\t' || c == '#' || c == '$' ) {
            out[ oi++ ] = '\\';
        }
        out[ oi++ ] = ( char )c;
    }
    out[ oi ] = '\0';
    return oi;
}

/* Derive a "<basename>.d" path from an output path, into `out` (size
** out_size). Trims the last extension if present. Returns 0 on overflow. */
static int derive_depfile_path( const char *output_path,
                                char *out, size_t out_size ) {
    const char *base = output_path, *p, *dot;
    size_t n;
    if ( output_path == NULL || out == NULL || out_size == 0 ) return 0;
    for ( p = output_path; *p; p++ ) {
        if ( *p == '/' || *p == '\\' ) base = p + 1;
    }
    dot = strrchr( base, '.' );
    n = ( dot && dot != base ) ? ( size_t )( dot - output_path )
                                : strlen( output_path );
    if ( n + 3 >= out_size ) return 0;
    memcpy( out, output_path, n );
    memcpy( out + n, ".d", 3 );
    return 1;
}

/* Write a make-style depfile listing every path in `modules`. Uses the
** `<target>: <dep1> <dep2>` shape make / ninja both understand; wraps
** each token through make_escape so paths with spaces survive. */
static int write_depfile( const char *depfile_path,
                          const char *target_path,
                          const RESOLVED_MODULE_T *modules, size_t nmodules ) {
    char  esc[ 1024 ];
    FILE *f;
    size_t i;

    if ( depfile_path == NULL || depfile_path[ 0 ] == '\0' ) return 0;
    if ( target_path == NULL || target_path[ 0 ] == '\0' ) target_path = "a.out";

    f = fopen( depfile_path, "wb" );
    if ( f == NULL ) return 0;

    make_escape( target_path, esc, sizeof( esc ) );
    fputs( esc, f );
    fputs( ":", f );
    for ( i = 0; i < nmodules; i++ ) {
        const char *p = modules[ i ].Path;
        if ( p == NULL || p[ 0 ] == '\0' ) continue;
        make_escape( p, esc, sizeof( esc ) );
        fputc( ' ', f );
        fputs( esc, f );
    }
    fputc( '\n', f );
    fclose( f );
    return 1;
}

static const char *DirOf( const char *Path, char *Buf, size_t BufSize ) {
    size_t L = strlen( Path );
    size_t I;
    if ( L >= BufSize ) { return "."; }
    memcpy( Buf, Path, L + 1 );
    for ( I = L; I > 0; I-- ) {
        if ( Buf[ I - 1 ] == '/' || Buf[ I - 1 ] == '\\' ) {
            Buf[ I - 1 ] = '\0';
            return Buf;
        }
    }
    return ".";
}

int lc_drive( const LcDriverOptions *opt ) {
    if ( opt == NULL || opt->input == NULL ) return 2;
    /* --emit=<mode> and --emit-only both let the driver run with no output
    ** path: the diagnostic dump goes to stdout, the binary is skipped. */
    bool skip_binary = opt->emit_only ||
                       ( opt->emit_mode != LC_EMIT_NONE && opt->output == NULL );
    if ( opt->output == NULL && !opt->check_only &&
         opt->emit_mode == LC_EMIT_NONE ) return 2;

    /* Backstop for programmatic callers that fill LcDriverOptions directly.
    ** REJECT rather than clamp: clamping would compile at a level the caller did
    ** not ask for, which is the behaviour being removed here. A memset-zeroed
    ** options struct gives 0, so no existing caller breaks. */
    if ( opt->opt_level < 0 || opt->opt_level > 3 ) {
        fprintf( stderr, "clua: error: unsupported optimization level %d "
                         "(supported: 0-3)\n", opt->opt_level );
        return 2;
    }

    /* --emit-compdb[-append]=<path>: write the compile_commands.json entry
    ** before we do any real work, so an editor / clang-tooling integration
    ** can pick up the invocation even if the build itself fails later. The
    ** entry records the absolute input path (resolved via _fullpath) and the
    ** absolute CWD, which is what clangd / VS Code C/C++ / ccls expect. */
    if ( opt->compdb_path != NULL && opt->drv_argc > 0 && opt->drv_argv != NULL ) {
        char cwd_buf[ 1024 ] = { 0 };
        char in_buf[ 1024 ]  = { 0 };
        const char *cwd_s = _getcwd( cwd_buf, ( int )sizeof( cwd_buf ) );
        const char *in_s  = _fullpath( in_buf, opt->input, sizeof( in_buf ) );
        if ( cwd_s == NULL ) cwd_s = ".";
        if ( in_s  == NULL ) in_s  = opt->input;
        if ( LcCompdb_Write( opt->compdb_path,
                             opt->drv_argc, opt->drv_argv,
                             cwd_s, in_s,
                             opt->compdb_append ? 1 : 0 ) != 0 ) {
            return 1;
        }
    }

    /* --dll / --output=dll / -shared: emit a DLL. The exe path stays the
    ** default so byte-identity of every existing exe test is preserved. */
    int output_kind = opt->output_kind;
    if ( opt->emit_dll ) output_kind = LC_OUTPUT_DLL;

    /* --output=obj / --output=lib skip linking entirely: the codegen COFF is
    ** the artifact (obj), optionally wrapped in a GNU-form archive (lib). No
    ** aot_entry, no runtime pull-in, so --shared-rt has nothing to swap. */
    if ( opt->shared_rt &&
         ( output_kind == LC_OUTPUT_OBJ || output_kind == LC_OUTPUT_LIB ) ) {
        fprintf( stderr, "clua: error: --shared-rt cannot be combined with "
                         "--output=%s (no link happens; the shared runtime "
                         "would have nowhere to be pulled in)\n",
                 ( output_kind == LC_OUTPUT_OBJ ) ? "obj" : "lib" );
        return 2;
    }

    /* Per-phase timing accumulator. Populated only when opt->verbose is set;
    ** every QPC read is guarded so a normal build pays no clock cost. Printed
    ** in one flush at the end of the pipeline (before cleanup). */
    LcPhaseTimings T;
    memset( &T, 0, sizeof( T ) );
    T.opt_level = opt->opt_level;
    T.jobs      = opt->jobs;
    LONGLONG t0 = opt->verbose ? qpc_now( ) : 0;

    /* ---- 1. closed-world discovery (reused front-end) ---- */
    char            dirbuf[ 512 ] = { 0 };
    PATHS_OPTS_T    paths   = { 0 };
    RESOLVE_OPTS_T  ropts   = { 0 };
    RESOLVE_RESULT_T res    = { 0 };
    DIAG_OPTS_T     diag    = { 0 };
    LC_DIAG_COLLECTOR_T collector;
    LcDiagCollector_Init( &collector );

    paths.BasePath  = DirOf( opt->input, dirbuf, sizeof( dirbuf ) );
    paths.IncludeDirs = NULL;
    ropts.PathsOpts = &paths;
    ropts.Strip     = 0;
    ropts.ForceLink      = ( opt->nforce_pkgs > 0 ) ? opt->force_pkgs : NULL;
    ropts.ForceLinkCount = ( size_t )opt->nforce_pkgs;
    diag.Warnings   = 0;  /* M0: skip the advisory lint pass */
    diag.Color      = 0;
    ropts.Diag      = &diag;
    /* Multi-error collector: rather than stopping at the first failing
       module, resolve keeps parsing every module and records each error.
       We drain and print all of them before failing the build. */
    ropts.DiagCollector = &collector;

    if ( !Resolve_Walk( opt->input, &ropts, &res ) ) {
        size_t n = LcDiagCollector_Drain( &collector, &diag );
        if ( n > 0 ) {
            fprintf( stderr,
                     "aotc: error: %zu compile error(s); build aborted\n", n );
        } else {
            fprintf( stderr, "aotc: error: resolve failed for '%s'\n", opt->input );
        }
        LcDiagCollector_Free( &collector );
        Resolve_FreeResult( &res );
        return 1;
    }
    LcDiagCollector_Free( &collector );
    if ( res.WarnCount > 0 ) {
        /* A dynamic require(var) can't be resolved in a closed world. */
        fprintf( stderr,
                 "aotc: error: %zu dynamic require(...) call(s) cannot be "
                 "resolved in an AOT-compiled program (closed world); use -L "
                 "<pkg> to force-bundle each\n",
                 res.WarnCount );
        Resolve_FreeResult( &res );
        return 1;
    }
    if ( res.Count == 0 ) {
        fprintf( stderr, "aotc: error: no modules resolved from '%s'\n", opt->input );
        Resolve_FreeResult( &res );
        return 1;
    }
    /* Builtin packages bundle like any other module: compile each one's
    ** source (located via the toolchain's packages directory) and append it
    ** to the module set, so it is AOT-compiled + preload-registered. imgui
    ** needs a native archive the AOT link does not carry — keep that loud. */
    if ( res.RequiresImgui ) {
        fprintf( stderr, "aotc: error: 'imgui' requires a native archive not "
                         "yet supported in compiled exes\n" );
        Resolve_FreeResult( &res );
        return 1;
    }
    if ( res.BuiltinPackageCount > 0 ) {
        char berr[ 512 ] = { 0 };
        if ( !Resolve_AppendBuiltinModules( &res, &ropts, berr, sizeof( berr ) ) ) {
            fprintf( stderr, "aotc: error: %s\n",
                     berr[0] ? berr : "builtin package bundling failed" );
            Resolve_FreeResult( &res );
            return 1;
        }
    }
    /* --emit-depfile=<path> / -MD: dump the make-style dependency file the
    ** moment resolve is complete. All the paths we need (each module's on-
    ** disk source file) live in RESOLVE_RESULT_T already. Fires before the
    ** rest of the pipeline so an editor / IDE can pick up the deps even if
    ** the build itself fails later; matches the compile_commands.json
    ** ordering already implemented above.
    **
    ** `-MD` is signalled with the sentinel value "-MD" (the driver level
    ** doesn't know the output basename until after this point); derive the
    ** actual path from opt->output when we see the sentinel. */
    if ( opt->depfile_path != NULL && opt->depfile_path[ 0 ] != '\0' ) {
        const char *target = ( opt->output != NULL && opt->output[ 0 ] != '\0' )
                              ? opt->output
                              : opt->input;
        char        derived_dep[ 1024 ] = { 0 };
        const char *dep_target = opt->depfile_path;
        if ( strcmp( opt->depfile_path, "-MD" ) == 0 ) {
            const char *basis = ( opt->output != NULL && opt->output[ 0 ] != '\0' )
                                  ? opt->output : opt->input;
            if ( !derive_depfile_path( basis, derived_dep,
                                       sizeof( derived_dep ) ) ) {
                fprintf( stderr, "aotc: error: -MD path derivation failed "
                                 "(output path too long)\n" );
                Resolve_FreeResult( &res );
                return 1;
            }
            dep_target = derived_dep;
        }
        if ( !write_depfile( dep_target, target,
                             res.Modules, res.Count ) ) {
            fprintf( stderr,
                     "aotc: error: cannot write depfile '%s'\n",
                     dep_target );
            Resolve_FreeResult( &res );
            return 1;
        }
    }

    if ( opt->verbose ) {
        LONGLONG t1 = qpc_now( );
        T.resolve_ticks = t1 - t0;
        /* n_modules is the post-append total; n_packages is what triggered
        ** the append. Read them here so the numbers reflect the completed
        ** resolve phase whether or not any builtin package was requested. */
        T.n_modules  = res.Count;
        T.n_packages = res.BuiltinPackageCount;
        t0 = t1;
    }

    /* ---- 2. undump each module + closed-world scan; collect reachable set ----
    ** Keep the loader lua_State open until AFTER codegen: the Protos live on
    ** L's stack and codegen reads func->source. */
    int        rc = 1;
    lua_State *L  = luaL_newstate( );
    if ( L == NULL ) {
        fprintf( stderr, "aotc: error: cannot create loader state\n" );
        Resolve_FreeResult( &res );
        return 1;
    }

    LcModule     *m  = NULL;
    LcCodeModule *cm = NULL;
    ProtoVec      reach = { 0 };
    Proto        *entryProto = NULL;
    /* Per-module root Protos (Modules[0]=entry, i>0 = required modules). Used
    ** after lift to tag each required module's LcFunc with its require-name so
    ** ProtoInit registers it in package.preload (self-contained require). */
    Proto       **modProtos = ( Proto ** )calloc( res.Count ? res.Count : 1,
                                                  sizeof( Proto * ) );
    if ( modProtos == NULL ) { fprintf( stderr, "aotc: oom\n" ); goto cleanup; }

    {
        size_t i;
        char   err[ 256 ] = { 0 };
        for ( i = 0; i < res.Count; i++ ) {
            Proto *P = Lc_Undump( L, res.Modules[ i ].Bytes,
                                  res.Modules[ i ].BytesLen );
            if ( P == NULL ) {
                fprintf( stderr, "aotc: error: failed to load bytecode for "
                                 "module '%s'\n", res.Modules[ i ].Name );
                goto cleanup;
            }
            if ( !Lc_CheckClosedWorld( P, err, sizeof( err ) ) ) {
                fprintf( stderr, "aotc: %s\n", err );
                goto cleanup;
            }
            if ( !Lc_CheckSupportedOps( P, err, sizeof( err ) ) ) {
                fprintf( stderr, "aotc: %s\n", err );
                goto cleanup;
            }
            modProtos[ i ] = P;
            if ( i == 0 ) entryProto = P;
            /* Collect this module's Proto + all its nested protos. For the
            ** single-module epsilon program this is just the entry tree; for
            ** multi-module programs every module's tree is included. */
            if ( !CollectReachable( &reach, P ) ) {
                fprintf( stderr, "aotc: error: out of memory collecting reachable "
                                 "protos\n" );
                goto cleanup;
            }
        }
    }

    if ( entryProto == NULL || reach.count == 0 ) {
        fprintf( stderr, "aotc: error: no entry proto\n" );
        goto cleanup;
    }

    /* -W diagnostic categories run here, right after the front end has
    ** produced Protos for every module. Order matters:
    **   - AFTER closed-world / supported-ops so we know the module set is
    **     well-formed enough that a Proto walk is meaningful.
    **   - BEFORE check_only's short-circuit and BEFORE lifting/codegen so
    **     the warnings surface in `clua check` too and don't cost the
    **     expensive tail of the pipeline in a warning-only run.
    ** Every enabled category walks each module's entry Proto (which recurses
    ** into nested Protos). Fatal_count is turned into a non-zero exit at
    ** the very end so ALL warnings across ALL modules print before we bail. */
    {
        int warn_fatal = 0;
        if ( opt->warn.unused ) {
            size_t i;
            bool   promote = opt->warn.werror_all ||
                             ( opt->warn.werror_bits &
                               LCWARN_BIT( LCWARN_CAT_UNUSED ) );
            for ( i = 0; i < res.Count; i++ ) {
                if ( modProtos[ i ] == NULL ) continue;
                LcWarn_ScanUnused( modProtos[ i ], res.Modules[ i ].Path,
                                   promote, &warn_fatal );
            }
        }
        if ( warn_fatal > 0 ) {
            fprintf( stderr,
                     "aotc: %d warning%s treated as errors (-Werror)\n",
                     warn_fatal, warn_fatal == 1 ? "" : "s" );
            goto cleanup;
        }
    }

    /* `check` mode: the front-end, closed-world and supported-ops gates all
    ** passed — report and stop before lifting/codegen/link. */
    if ( opt->check_only ) {
        printf( "[+] %s: OK (%zu module%s, closed world)\n",
                opt->input, res.Count, res.Count == 1 ? "" : "s" );
        rc = 0;
        goto cleanup;
    }

    /* --emit=bytecode: dump the raw Lua 5.4 bytecode for every reachable
    ** Proto. If skip_binary is true (--emit=X alone, or --emit-only) the -o
    ** path becomes the dump destination; otherwise the dump lands on stdout
    ** and the binary build continues to whatever -o names. */
    if ( opt->emit_mode == LC_EMIT_BYTECODE ) {
        int close_me = 0;
        FILE *of = OpenEmitOut( opt, skip_binary, &close_me );
        if ( of == NULL ) goto cleanup;
        Lc_DumpBytecode( of, entryProto );
        fflush( of );
        if ( close_me ) fclose( of );
        if ( skip_binary ) { rc = 0; goto cleanup; }
    }

    /* --emit=ast: dump the front-end Proto tree as an indented tree of
    ** node shapes (params, locals, upvalues, constants, children). Same
    ** dump timing as --emit=bytecode (right after front-end resolve,
    ** before IR lift) so both dumps reflect the parsed structure without
    ** any optimizer transforms in between. */
    if ( opt->emit_mode == LC_EMIT_AST ) {
        int close_me = 0;
        FILE *of = OpenEmitOut( opt, skip_binary, &close_me );
        if ( of == NULL ) goto cleanup;
        Lc_DumpAst( of, entryProto );
        fflush( of );
        if ( close_me ) fclose( of );
        if ( skip_binary ) { rc = 0; goto cleanup; }
    }

    /* ---- 3. lift to IR ---- */
    m = lc_lift_program( entryProto, reach.items, reach.count );
    if ( m == NULL ) {
        fprintf( stderr, "aotc: error: lifting failed\n" );
        goto cleanup;
    }
    m->opt_level = opt->opt_level;   /* codegen picks M1 fastpaths at -O1+ */
    m->jobs      = opt->jobs;        /* -j N; 0 = env CLUA_JOBS or CPU count */
    m->emit_line_info = opt->debug_line_info ? 1 : 0; /* -g: .clualn per fn */

    /* Persistent per-function compilation cache. Default on; --no-cache or
       CLUA_NO_CACHE=1 disables. --cache-dir=<path> overrides the default
       (%LOCALAPPDATA%\clua\cache). If dir resolution fails, caching is
       silently off; correctness never depends on it. */
    char cache_dir_buf[ 1024 ];
    {
      const char *env_no = getenv( "CLUA_NO_CACHE" );
      int env_disables = ( env_no != NULL && env_no[ 0 ] != '\0' &&
                           env_no[ 0 ] != '0' );
      int cache_on = ( !opt->no_cache && !env_disables );
      m->cache_dir   = NULL;
      m->cache_read  = 0;
      m->cache_write = 0;
      if ( cache_on ) {
        if ( LcCache_ResolveDir( opt->cache_dir,
                                 cache_dir_buf, sizeof( cache_dir_buf ) ) ) {
          m->cache_dir   = cache_dir_buf;
          m->cache_read  = 1;
          m->cache_write = 1;
        }
      }
    }

    /* Tag each REQUIRED module's main-chunk LcFunc with its require-name so the
    ** ProtoInit emitter registers it in package.preload at startup (the entry,
    ** module 0, is run directly and is NOT a preload module). This makes
    ** require("mod") resolve to the compiled-in module — self-contained, no
    ** disk dependency. */
    {
        size_t i; uint32_t j;
        for ( i = 1; i < res.Count; i++ ) {
            for ( j = 0; j < m->nfuncs; j++ ) {
                if ( m->funcs[ j ] != NULL &&
                     m->funcs[ j ]->source == modProtos[ i ] ) {
                    m->funcs[ j ]->module_name = res.Modules[ i ].Name;
                    break;
                }
            }
        }
    }

    if ( opt->verbose ) {
        LONGLONG t1 = qpc_now( );
        T.lift_ticks  = t1 - t0;
        T.n_functions = m->nfuncs;   /* codegen operates on the same set */
        t0 = t1;
    }

    /* ---- 4. optimize (no-op at -O0) ---- */
    {
        LcPassConfig cfg;
        memset( &cfg, 0, sizeof( cfg ) );
        cfg.opt_level       = opt->opt_level;
        cfg.interprocedural = ( opt->opt_level >= 2 );
        cfg.escape_analysis = ( opt->opt_level >= 3 );
        cfg.verify_each     = true;
        if ( opt->opt_level > 0 ) {
            if ( !lc_optimize( m, &cfg ) ) {
                fprintf( stderr, "aotc: error: optimizer failed\n" );
                goto cleanup;
            }
            T.opt_passes_ran = 1;
        }
    }

    /* Verify the IR that is about to be code-generated, at EVERY level. The
    ** optimizer's own verify_each checks only run when lc_optimize runs, and it
    ** is skipped entirely at -O0 -- which is precisely the configuration used to
    ** isolate a suspected miscompile, so it is the last place that should go
    ** unchecked. Cheap: one walk of the IR against the source Proto. */
    {
        char verr[256] = { 0 };
        if ( !lc_module_verify( m, verr, sizeof verr ) ) {
            fprintf( stderr, "aotc: internal error: malformed IR before codegen: %s\n",
                     verr[0] ? verr : "(no detail)" );
            goto cleanup;
        }
    }

    /* --emit=ir: dump the module as the optimizer left it. Comes AFTER
    ** verify so a dump reflects the exact IR codegen will consume. */
    if ( opt->emit_mode == LC_EMIT_IR ) {
        int close_me = 0;
        FILE *of = OpenEmitOut( opt, skip_binary, &close_me );
        if ( of == NULL ) goto cleanup;
        Lc_DumpIr( of, m );
        fflush( of );
        if ( close_me ) fclose( of );
        if ( skip_binary ) { rc = 0; goto cleanup; }
    }

    if ( opt->verbose ) {
        LONGLONG t1 = qpc_now( );
        /* Include lc_module_verify in the optimize bucket: it is IR-verification
        ** work paired with (and gated by) the optimizer stage, not codegen. */
        T.optimize_ticks = t1 - t0;
        t0 = t1;
    }

    /* ---- 5. codegen ---- */
    cm = lc_codegen( m );
    if ( cm == NULL ) {
        fprintf( stderr, "aotc: error: codegen failed\n" );
        goto cleanup;
    }
    if ( opt->verbose ) {
        LONGLONG t1 = qpc_now( );
        T.codegen_ticks = t1 - t0;
        t0 = t1;
    }

    /* --emit=asm: dump the emitted machine code as an assembly listing.
    ** Skip when the caller only asked for the diagnostic. */
    if ( opt->emit_mode == LC_EMIT_ASM ) {
        int close_me = 0;
        FILE *of = OpenEmitOut( opt, skip_binary, &close_me );
        if ( of == NULL ) goto cleanup;
        Lc_DumpAsm( of, cm );
        fflush( of );
        if ( close_me ) fclose( of );
        if ( skip_binary ) { rc = 0; goto cleanup; }
    }

    /* Any --emit=<other> that already dumped its stage and had no binary
    ** requested: the corresponding branch above returned early. If skip_binary
    ** is set without a matched mode (i.e. --emit-only with an unknown mode --
    ** currently unreachable, but keep the check explicit for future modes)
    ** we still stop here rather than link. */
    if ( skip_binary ) { rc = 0; goto cleanup; }

    /* ---- 6/7. serialize the ProtoInit blob, emit ONE COFF .o, link ----
    ** The blob (constants/upvalues/debug-info/code per Proto) rides in the
    ** user object's .rdata$L next to the relocated luac_fn_table; the runtime
    ** archive's protoinit_rt.o rebuilds the Protos at startup. Everything
    ** from .lua to .o happens in-process — the only external step is the
    ** single native link. */
    {
        char           obj_path[ 1024 ];
        char           err[ 512 ] = { 0 };
        unsigned char *blob = NULL;
        size_t         blob_len = 0;
        int            pid = ( int )_getpid( );
        const char    *tmpdir = getenv( "TEMP" );

        if ( tmpdir == NULL || tmpdir[0] == '\0' ) tmpdir = getenv( "TMP" );
        if ( tmpdir == NULL || tmpdir[0] == '\0' ) tmpdir = ".";
        snprintf( obj_path, sizeof( obj_path ),
                  "%s\\clua_user_%d.o", tmpdir, pid );

        if ( !LcBuildProtoBlob( m, &blob, &blob_len, err, sizeof( err ) ) ) {
            fprintf( stderr, "aotc: error: ProtoInit blob failed: %s\n",
                     err[0] ? err : "(unknown)" );
            goto cleanup;
        }
        cm->protoblob     = blob;        /* owned by cm now */
        cm->protoblob_len = blob_len;

        if ( !LcCoff_Write( obj_path, cm, err, sizeof( err ) ) ) {
            fprintf( stderr, "aotc: error: COFF write failed: %s\n",
                     err[0] ? err : "(unknown)" );
            goto cleanup;
        }

        /* --output=obj / --output=lib: republish the staged COFF as the final
        ** artifact and return before the native link. `obj` copies the COFF
        ** to opt->output; `lib` wraps that same COFF in a single-member
        ** GNU-form ar archive. Neither pulls the runtime or aot_entry.
        **
        ** Rationale for going through the staged temp path rather than writing
        ** to opt->output directly: LcCoff_Write's temp path is on the same
        ** volume as %TEMP%, so a rename would land cross-volume in the common
        ** case; a byte-for-byte copy is simpler and keeps the "atomic COFF
        ** write followed by promotion" shape symmetric across kinds. */
        if ( output_kind == LC_OUTPUT_OBJ ) {
            FILE   *in  = fopen( obj_path,   "rb" );
            FILE   *out = NULL;
            char    chunk[ 8192 ];
            size_t  n;
            int     copy_ok = 1;
            if ( in == NULL ) {
                fprintf( stderr, "aotc: error: cannot re-open staged obj '%s'\n",
                         obj_path );
                if ( !opt->keep_temps ) remove( obj_path );
                goto cleanup;
            }
            out = fopen( opt->output, "wb" );
            if ( out == NULL ) {
                fprintf( stderr, "aotc: error: cannot open output '%s'\n",
                         opt->output );
                fclose( in );
                if ( !opt->keep_temps ) remove( obj_path );
                goto cleanup;
            }
            while ( ( n = fread( chunk, 1, sizeof( chunk ), in ) ) > 0 ) {
                if ( fwrite( chunk, 1, n, out ) != n ) { copy_ok = 0; break; }
            }
            if ( ferror( in ) ) copy_ok = 0;
            fflush( out );
            if ( fclose( out ) != 0 ) copy_ok = 0;
            fclose( in );
            if ( !copy_ok ) {
                fprintf( stderr, "aotc: error: copy to '%s' failed\n",
                         opt->output );
                if ( !opt->keep_temps ) remove( obj_path );
                remove( opt->output );
                goto cleanup;
            }
            if ( !opt->keep_temps ) remove( obj_path );
            printf( "[+] %s (%zu module%s, %u function%s) -> %s\n",
                    opt->input, res.Count, res.Count == 1 ? "" : "s",
                    reach.count, reach.count == 1 ? "" : "s", opt->output );
            rc = 0;
            goto cleanup;
        }
        if ( output_kind == LC_OUTPUT_LIB ) {
            char aerr[ 256 ] = { 0 };
            if ( !LcArWrite_SingleMemberObject( obj_path, opt->output,
                                                aerr, sizeof( aerr ) ) ) {
                fprintf( stderr, "aotc: error: ar write failed: %s\n",
                         aerr[0] ? aerr : "(unknown)" );
                if ( !opt->keep_temps ) remove( obj_path );
                goto cleanup;
            }
            if ( !opt->keep_temps ) remove( obj_path );
            printf( "[+] %s (%zu module%s, %u function%s) -> %s\n",
                    opt->input, res.Count, res.Count == 1 ? "" : "s",
                    reach.count, reach.count == 1 ? "" : "s", opt->output );
            rc = 0;
            goto cleanup;
        }

        /* Resource inputs: load the user's manifest / icon files from disk
        ** if paths were supplied. Byte buffers live for the duration of the
        ** link call and are freed right after. */
        LuacRsrcInputs rsrc; memset( &rsrc, 0, sizeof rsrc );
        uint8_t *manifest_buf = NULL; uint32_t manifest_len = 0;
        uint8_t *icon_buf     = NULL; uint32_t icon_len     = 0;
        int      rsrc_ok = 1;

        rsrc.want_versioninfo = ( output_kind != LC_OUTPUT_OBJ &&
                                  output_kind != LC_OUTPUT_LIB ) &&
                                opt->emit_versioninfo ? 1 : 0;
        rsrc.want_manifest    = ( output_kind == LC_OUTPUT_EXE ) &&
                                opt->emit_manifest ? 1 : 0;
        rsrc.product_name     = opt->product_name;
        rsrc.product_version  = opt->product_version;
        rsrc.file_version     = CLUA_VERSION_STRING;   /* single source of truth */
        rsrc.file_description = opt->file_description;
        rsrc.company_name     = opt->company_name;
        rsrc.legal_copyright  = opt->legal_copyright;
        rsrc.original_filename = NULL;    /* defaults to basename(out_path)     */

        if ( opt->manifest_path && opt->manifest_path[0] ) {
            FILE *mf = fopen( opt->manifest_path, "rb" );
            if ( mf == NULL ) {
                fprintf( stderr, "aotc: error: cannot open --manifest '%s'\n",
                         opt->manifest_path );
                rsrc_ok = 0;
            } else {
                fseek( mf, 0, SEEK_END );
                long msz = ftell( mf );
                fseek( mf, 0, SEEK_SET );
                if ( msz < 0 ) msz = 0;
                manifest_buf = ( uint8_t * )malloc( msz ? ( size_t )msz : 1 );
                if ( manifest_buf == NULL ) { fclose( mf ); rsrc_ok = 0; }
                else if ( msz > 0 && fread( manifest_buf, 1, ( size_t )msz, mf ) != ( size_t )msz ) {
                    fclose( mf ); free( manifest_buf ); manifest_buf = NULL; rsrc_ok = 0;
                    fprintf( stderr, "aotc: error: short read on --manifest '%s'\n",
                             opt->manifest_path );
                } else {
                    fclose( mf );
                    manifest_len = ( uint32_t )msz;
                    rsrc.want_manifest = 1;
                    rsrc.manifest_xml = manifest_buf;
                    rsrc.manifest_xml_len = manifest_len;
                }
            }
        }
        if ( rsrc_ok && opt->icon_path && opt->icon_path[0] ) {
            FILE *icf = fopen( opt->icon_path, "rb" );
            if ( icf == NULL ) {
                fprintf( stderr, "aotc: error: cannot open --icon '%s'\n",
                         opt->icon_path );
                rsrc_ok = 0;
            } else {
                fseek( icf, 0, SEEK_END );
                long isz = ftell( icf );
                fseek( icf, 0, SEEK_SET );
                if ( isz < 0 ) isz = 0;
                icon_buf = ( uint8_t * )malloc( isz ? ( size_t )isz : 1 );
                if ( icon_buf == NULL ) { fclose( icf ); rsrc_ok = 0; }
                else if ( isz > 0 && fread( icon_buf, 1, ( size_t )isz, icf ) != ( size_t )isz ) {
                    fclose( icf ); free( icon_buf ); icon_buf = NULL; rsrc_ok = 0;
                    fprintf( stderr, "aotc: error: short read on --icon '%s'\n",
                             opt->icon_path );
                } else {
                    fclose( icf );
                    icon_len = ( uint32_t )isz;
                    rsrc.icon_bytes = icon_buf;
                    rsrc.icon_bytes_len = icon_len;
                }
            }
        }
        if ( !rsrc_ok ) {
            free( manifest_buf ); free( icon_buf );
            if ( !opt->keep_temps ) remove( obj_path );
            goto cleanup;
        }

        /* Programs that never mention "debug" can't activate debug hooks, so
        ** their exes drop the bytecode interpreter (same conservative scan
        ** that gates the -O1 type proofs). Programs referencing ffi/bit get
        ** the FFI initialization anchor linked in.
        **
        ** --strip default is LC_STRIP_ALL (byte-identical to the pre-flag
        ** baseline). When -g was requested WITHOUT an explicit --strip=<x>,
        ** promote to LC_STRIP_NONE so the .clualn section the codegen just
        ** emitted actually survives the link -- otherwise -g would be a
        ** no-op under the default strip. Explicit --strip=debug / =all with
        ** -g wins (matches gcc: `-g -s` strips debug). */
        int effective_strip = opt->strip_mode;
        if ( !opt->strip_mode_explicit && opt->debug_line_info ) {
            effective_strip = LC_STRIP_NONE;
        }
        if ( !LuacLink_LinkProgram( obj_path, opt->output,
                                    !lc_module_uses_debug( m ),
                                    res.RequiresFfi || lc_module_uses_ffi( m ),
                                    lc_module_uses_coroutine( m ),
                                    lc_module_used_libs( m ),
                                    opt->shared_rt,
                                    opt->ld_internal,
                                    opt->no_gc_sections,
                                    output_kind,
                                    res.Exports, res.ExportCount,
                                    effective_strip,
                                    &rsrc,
                                    err, sizeof( err ) ) ) {
            fprintf( stderr, "aotc: error: link failed: %s\n",
                     err[0] ? err : "(unknown)" );
            free( manifest_buf ); free( icon_buf );
            if ( !opt->keep_temps ) remove( obj_path );
            goto cleanup;
        }
        free( manifest_buf ); free( icon_buf );
        if ( !opt->keep_temps ) remove( obj_path );

        /* DLL builds: emit a .DEF module-definition file next to the .dll so
        ** downstream C consumers can produce a matching .lib (MSVC:
        ** `link /def:foo.def /dll`) or libfoo.a (MinGW:
        ** `dlltool -d foo.def -D foo.dll -l foo.lib`). Gated on
        ** output_kind == LC_OUTPUT_DLL rather than the legacy emit_dll bool,
        ** so `-shared` (which only sets output_kind) still triggers the .def
        ** emit -- an .exe has no import surface to describe, and skipping the
        ** write for exe builds keeps the byte-for-byte output the fidelity
        ** tests already pin.
        **
        ** The export set is the real one: each name from the module's
        ** `_exports = { name = fn, ...}` table, discovered by Resolve_Walk's
        ** ScanEntryExports pass and shipped in res.Exports[]. The runtime
        ** trampoline generator (pe_emit.c) wires each of those names into
        ** the DLL's IMAGE_EXPORT_DIRECTORY, so what the .def lists matches
        ** exactly what `dumpbin /exports` reports on the produced DLL. */
        if ( output_kind == LC_OUTPUT_DLL ) {
            const char **exp_names = NULL;
            char derr[ 256 ] = { 0 };
            char def_derived[ 1024 ];
            const char *def_target = opt->emit_def_path;
            int emit_ok;

            if ( def_target == NULL || def_target[0] == '\0' ) {
                if ( !LcEmit_DeriveDefPath( opt->output, def_derived,
                                            sizeof( def_derived ) ) ) {
                    fprintf( stderr, "aotc: error: cannot derive .def path "
                                     "from '%s' (path too long)\n", opt->output );
                    goto cleanup;
                }
                def_target = def_derived;
            }

            if ( res.ExportCount > 0 ) {
                size_t ei;
                exp_names = ( const char ** )calloc( res.ExportCount,
                                                    sizeof( char * ) );
                if ( exp_names == NULL ) {
                    fprintf( stderr, "aotc: oom\n" );
                    goto cleanup;
                }
                for ( ei = 0; ei < res.ExportCount; ei++ ) {
                    exp_names[ ei ] = res.Exports[ ei ].Name;
                }
            }

            emit_ok = LuacLink_EmitDllDef( opt->output, def_target,
                                           exp_names, res.ExportCount,
                                           derr, sizeof( derr ) );
            free( exp_names );
            if ( !emit_ok ) {
                fprintf( stderr, "aotc: error: .def emit failed: %s\n",
                         derr[0] ? derr : "(unknown)" );
                goto cleanup;
            }
        }

        printf( "[+] %s (%zu module%s, %u function%s) -> %s\n",
                opt->input, res.Count, res.Count == 1 ? "" : "s",
                reach.count, reach.count == 1 ? "" : "s", opt->output );
    }

    if ( opt->verbose ) {
        LONGLONG t1 = qpc_now( );
        T.link_ticks = t1 - t0;
        lc_print_timings( &T );
    }

    rc = 0;

cleanup:
    lc_codemodule_free( cm );
    lc_module_free( m );
    free( reach.items );
    free( modProtos );
    lua_close( L );          /* AFTER codegen — Protos lived on L's stack */
    Resolve_FreeResult( &res );
    return rc;
}

#ifdef LUAC_AOTC_STANDALONE
static void usage( const char *argv0 ) {
    fprintf( stderr,
             "aotc (LuaC) — Lua 5.4 -> native Windows x64 PE\n"
             "usage: %s <main.lua> [-o output] [-O<n>] [-L <pkg>]... "
             "[--shared-rt] [--output=exe|dll|obj|lib] [-shared] "
             "[--emit-def=<path>] "
             "[--emit-compdb=<path>|--emit-compdb-append=<path>] "
             "[--emit-depfile=<path>|-MD] [--emit=ast|bytecode|ir|asm] "
             "[--strip=none|debug|all] "
             "[-v|--verbose] "
             "[@<response-file>]\n"
             "  --print-target-triple / --print-search-dirs / "
             "--print-runtime-path / --print-package-path exit after printing.\n",
             argv0 );
}

/* Shared print helpers: one line to stdout and return 0 so the wrapper
** callers can `exit(rc)` immediately without touching the argv scanner. */
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
    /* Match the resolution order LuacLink_LinkProgram uses; without wanting
    ** to duplicate ResolveToolchain, we print the FIRST plausible location
    ** in the same priority order: CLUA_HOME\lib, <exedir>\lib, <exedir>. */
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

/* Returns 1 if `a` was handled as a --print-* flag; caller should exit(0). */
static int handle_print_flag( const char *a ) {
    if ( strcmp( a, "--print-target-triple" ) == 0 ) {
        printf( "%s\n", LcBugreport_TargetTriple( ) );
        return 1;
    }
    if ( strcmp( a, "--print-search-dirs" ) == 0 ) {
        print_search_dirs( );
        return 1;
    }
    if ( strcmp( a, "--print-runtime-path" ) == 0 ) {
        print_runtime_path( );
        return 1;
    }
    if ( strcmp( a, "--print-package-path" ) == 0 ) {
        print_package_path( );
        return 1;
    }
    return 0;
}

int main( int raw_argc, char **raw_argv ) {
    LcDriverOptions opt;
    const char *force[ 64 ];
    int  nforce = 0;
    int  i;
    int  argc = 0;
    char **argv = LcArg_Expand( raw_argc, raw_argv, &argc );
    if ( argv == NULL ) return 2;

    /* --print-* flags win over everything else; scan once up front so the
    ** user can drop them anywhere on the command line. */
    for ( i = 1; i < argc; i++ ) {
        if ( handle_print_flag( argv[ i ] ) ) {
            LcArg_FreeExpanded( argc, argv );
            return 0;
        }
    }

    memset( &opt, 0, sizeof( opt ) );
    opt.opt_level = 0;
    opt.ld_internal = -1;          /* env (CLUA_LD) decides unless flagged */
    /* .rsrc defaults: emit VS_VERSION_INFO + RT_MANIFEST by default so the
    ** produced exe carries a populated "Details" tab and a Win10/11 manifest
    ** without any user opt-in. --no-versioninfo / --no-manifest / -icon flags
    ** below let the caller override. */
    opt.emit_versioninfo = true;
    opt.emit_manifest    = true;

    for ( i = 1; i < argc; i++ ) {
        const char *a = argv[ i ];
        if ( strcmp( a, "-o" ) == 0 && i + 1 < argc ) {
            opt.output = argv[ ++i ];
        } else if ( a[0] == '-' && a[1] == 'O' ) {
            /* Deliberately an ERROR while other unknown args stay warnings
            ** (see the tail of this loop): a wrong -O silently changes the
            ** generated code, an unknown flag does not. */
            if ( !lc_parse_opt_level( a, &opt.opt_level ) ) {
                fprintf( stderr, "aotc: unsupported optimization level '%s' "
                                 "(use -O0, -O1, -O2 or -O3)\n", a );
                LcArg_FreeExpanded( argc, argv );
                return 2;
            }
        } else if ( strcmp( a, "--dll" ) == 0
                    || strcmp( a, "--output=dll" ) == 0 ) {
            opt.emit_dll = true;
            opt.output_kind = LC_OUTPUT_DLL;
        } else if ( strcmp( a, "-shared" ) == 0 ) {
            /* GCC-style shorthand: link a shared library (DLL on Windows). */
            opt.output_kind = LC_OUTPUT_DLL;
        } else if ( strncmp( a, "--output=", 9 ) == 0 ) {
            const char *kind = a + 9;
            if ( strcmp( kind, "exe" ) == 0 ) {
                opt.output_kind = LC_OUTPUT_EXE;
            } else if ( strcmp( kind, "dll" ) == 0 ) {
                opt.output_kind = LC_OUTPUT_DLL;
            } else if ( strcmp( kind, "obj" ) == 0 ) {
                opt.output_kind = LC_OUTPUT_OBJ;
            } else if ( strcmp( kind, "lib" ) == 0 ) {
                opt.output_kind = LC_OUTPUT_LIB;
            } else {
                fprintf( stderr, "aotc: unknown --output kind '%s' "
                                 "(supported: exe, dll, obj, lib)\n", kind );
                LcArg_FreeExpanded( argc, argv );
                return 2;
            }
        } else if ( strncmp( a, "--emit-def=", 11 ) == 0 ) {
            opt.emit_def_path = a + 11;
        } else if ( strncmp( a, "--emit-implib=", 14 ) == 0 ) {
            /* Alias: the naming users reach for. Today we always emit a .def
            ** (both MSVC and MinGW consume it); the path is treated as the
            ** .def destination. */
            opt.emit_def_path = a + 14;
        } else if ( strcmp( a, "--shared-rt" ) == 0 ) {
            opt.shared_rt = true;
        } else if ( strcmp( a, "--ld=internal" ) == 0 ) {
            opt.ld_internal = 1;
        } else if ( strcmp( a, "--ld=gcc" ) == 0 ) {
            opt.ld_internal = 0;
        } else if ( strcmp( a, "--no-gc-sections-internal" ) == 0 ) {
            opt.no_gc_sections = true;
        } else if ( strcmp( a, "-j" ) == 0 && i + 1 < argc ) {
            /* -j N: parallel per-function codegen. -j 1 collapses to the
               sequential path; -j 0 means "let the env / cpu count decide".
               Negative or nonsense values become 1 (sequential) so a typo
               fails safely rather than crashing the compiler. */
            int n = atoi( argv[ ++i ] );
            if ( n < 0 ) n = 1;
            opt.jobs = n;
        } else if ( strcmp( a, "--emit-only" ) == 0 ) {
            opt.emit_only = true;
        } else if ( strcmp( a, "--no-cache" ) == 0 ) {
            /* Disable the persistent per-function compilation cache for this
               invocation (both read and write). Equivalent to setting
               CLUA_NO_CACHE=1 in the env. */
            opt.no_cache = true;
        } else if ( strncmp( a, "--cache-dir=", 12 ) == 0 ) {
            /* Override the default cache location. Silently disables the
               cache if the path can't be created (see lc_drive). */
            opt.cache_dir = a + 12;
        } else if ( strcmp( a, "-v" ) == 0 || strcmp( a, "--verbose" ) == 0 ) {
            /* Print per-phase wall-clock on stderr after the build. Zero
            ** overhead when unset -- every QPC read in lc_drive is guarded
            ** by opt->verbose. */
            opt.verbose = true;
        } else if ( strcmp( a, "-g" ) == 0 || strcmp( a, "--debug" ) == 0 ) {
            /* Emit .clualn source-line mapping into the produced PE. Off by
            ** default; adds bytes to the exe. Byte-identity of a non-debug
            ** build depends on the flag staying off. */
            opt.debug_line_info = true;
        } else if ( strncmp( a, "--emit=", 7 ) == 0 ) {
            const char *v = a + 7;
            if      ( strcmp( v, "bytecode" ) == 0 ) opt.emit_mode = LC_EMIT_BYTECODE;
            else if ( strcmp( v, "ir"       ) == 0 ) opt.emit_mode = LC_EMIT_IR;
            else if ( strcmp( v, "asm"      ) == 0 ) opt.emit_mode = LC_EMIT_ASM;
            else if ( strcmp( v, "ast"      ) == 0 ) opt.emit_mode = LC_EMIT_AST;
            else {
                fprintf( stderr, "aotc: unknown --emit mode '%s' "
                                 "(supported: bytecode, ir, asm, ast)\n", v );
                LcArg_FreeExpanded( argc, argv );
                return 2;
            }
        } else if ( strncmp( a, "--emit-depfile=", 15 ) == 0 ) {
            /* Make-style dependency file. Absolute path recommended; a
            ** relative path resolves against the CWD at compile time. */
            opt.depfile_path = a + 15;
        } else if ( strcmp( a, "-MD" ) == 0 ) {
            /* GCC-style shorthand for --emit-depfile=<basename>.d beside
            ** the output. The actual path is derived inside lc_drive once
            ** it knows the final output path. Signalled here via the
            ** sentinel value "-MD" -- lc_drive checks for it and computes
            ** the actual name. */
            opt.depfile_path = "-MD";
        } else if ( strncmp( a, "--strip=", 8 ) == 0 ) {
            const char *m = a + 8;
            if      ( strcmp( m, "none"  ) == 0 ) opt.strip_mode = LC_STRIP_NONE;
            else if ( strcmp( m, "debug" ) == 0 ) opt.strip_mode = LC_STRIP_DEBUG;
            else if ( strcmp( m, "all"   ) == 0 ) opt.strip_mode = LC_STRIP_ALL;
            else {
                fprintf( stderr, "aotc: unknown --strip mode '%s' "
                                 "(supported: none, debug, all)\n", m );
                LcArg_FreeExpanded( argc, argv );
                return 2;
            }
            opt.strip_mode_explicit = true;
        } else if ( strncmp( a, "--emit-compdb=", 14 ) == 0 ) {
            opt.compdb_path   = a + 14;
            opt.compdb_append = false;
        } else if ( strncmp( a, "--emit-compdb-append=", 21 ) == 0 ) {
            opt.compdb_path   = a + 21;
            opt.compdb_append = true;
        } else if ( ( strcmp( a, "-L" ) == 0 || strcmp( a, "--link" ) == 0 )
                    && i + 1 < argc ) {
            if ( nforce < 63 ) {
                force[ nforce++ ] = argv[ ++i ];
                force[ nforce ]   = NULL;
            } else {
                ++i;
            }
        } else if ( a[0] == '-' && a[1] == 'W' && a[2] != '\0' ) {
            /* -W diagnostic-category flags: -Wname / -Wno-name / -Wall /
            ** -Werror / -Werror=name. Handled BEFORE the fall-through so a
            ** typoed -Wfoo lands in LcWarn_ParseFlag's own message rather
            ** than the generic "unknown argument" text below (which the tests
            ** for other flags key off of). LcWarn_ParseFlag returns 0 for an
            ** unknown category and prints its own diagnostic; keep going so
            ** the rest of the command line still parses. */
            ( void )LcWarn_ParseFlag( &opt.warn, a + 2 );
        } else if ( strncmp( a, "--product-name=", 15 ) == 0 ) {
            opt.product_name = a + 15;
        } else if ( strncmp( a, "--product-version=", 18 ) == 0 ) {
            opt.product_version = a + 18;
        } else if ( strncmp( a, "--file-description=", 19 ) == 0 ) {
            opt.file_description = a + 19;
        } else if ( strncmp( a, "--company-name=", 15 ) == 0 ) {
            opt.company_name = a + 15;
        } else if ( strncmp( a, "--copyright=", 12 ) == 0 ) {
            opt.legal_copyright = a + 12;
        } else if ( strncmp( a, "--manifest=", 11 ) == 0 ) {
            opt.manifest_path = a + 11;
        } else if ( strncmp( a, "--icon=", 7 ) == 0 ) {
            opt.icon_path = a + 7;
        } else if ( strcmp( a, "--no-versioninfo" ) == 0 ) {
            opt.emit_versioninfo = false;
        } else if ( strcmp( a, "--no-manifest" ) == 0 ) {
            opt.emit_manifest = false;
        } else if ( a[0] != '-' && opt.input == NULL ) {
            opt.input = a;
        } else {
            fprintf( stderr, "aotc: warning: ignoring unknown argument '%s'\n", a );
        }
    }

    if ( opt.input == NULL ) {
        usage( argv[ 0 ] );
        LcArg_FreeExpanded( argc, argv );
        return 2;
    }
    /* Same rule as clua_main.c cmd_build: only synthesise an output path
    ** when a binary is actually going to be written. --emit=<mode> alone or
    ** --emit-only produces a diagnostic and no binary. When a binary IS
    ** written, the output kind (exe vs dll) picks the suffix. */
    if ( opt.output == NULL &&
         opt.emit_mode == LC_EMIT_NONE &&
         !opt.emit_only ) {
        switch ( opt.output_kind ) {
            case LC_OUTPUT_DLL: opt.output = "out.dll"; break;
            case LC_OUTPUT_OBJ: opt.output = "out.o";   break;
            case LC_OUTPUT_LIB: opt.output = "out.lib"; break;
            default:            opt.output = "out.exe"; break;
        }
    }
    if ( nforce > 0 ) {
        opt.force_pkgs  = force;
        opt.nforce_pkgs = nforce;
    }

    /* Give the driver the raw argv so --emit-compdb records the invocation
    ** verbatim. lc_drive only reads it when compdb_path is set. */
    opt.drv_argc = argc;
    opt.drv_argv = ( const char *const * )argv;

    {
        int rc = lc_drive( &opt );
        LcArg_FreeExpanded( argc, argv );
        return rc;
    }
}
#endif
