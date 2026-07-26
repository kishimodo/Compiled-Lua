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
#include "../codegen/protoblob_emit.h"
#include "../link/coff_write.h"
#include "../link/pe_link_v2.h"

#include "../compiler/resolve.h"
#include "../compiler/paths.h"
#include "../compiler/diag.h"
#include "../driver/lc_undump.h"
#include "../driver/closed_world.h"
#include "../driver/supported_ops.h"

/* Reused front-end produces a Proto*; we read its nested-proto array (p[]) to
** collect the reachable set for lifting. */
#include "lua.h"
#include "lauxlib.h"
#include "lobject.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>   /* _getpid */

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
    if ( opt->output == NULL && !opt->check_only ) return 2;

    if ( opt->emit_dll ) {
        fprintf( stderr, "aotc: --dll is not supported in M0 (exe only)\n" );
        return 2;
    }

    /* ---- 1. closed-world discovery (reused front-end) ---- */
    char            dirbuf[ 512 ] = { 0 };
    PATHS_OPTS_T    paths   = { 0 };
    RESOLVE_OPTS_T  ropts   = { 0 };
    RESOLVE_RESULT_T res    = { 0 };
    DIAG_OPTS_T     diag    = { 0 };

    paths.BasePath  = DirOf( opt->input, dirbuf, sizeof( dirbuf ) );
    paths.IncludeDirs = NULL;
    ropts.PathsOpts = &paths;
    ropts.Strip     = 0;
    ropts.ForceLink      = ( opt->nforce_pkgs > 0 ) ? opt->force_pkgs : NULL;
    ropts.ForceLinkCount = ( size_t )opt->nforce_pkgs;
    diag.Warnings   = 0;  /* M0: skip the advisory lint pass */
    diag.Color      = 0;
    ropts.Diag      = &diag;

    if ( !Resolve_Walk( opt->input, &ropts, &res ) ) {
        fprintf( stderr, "aotc: error: resolve failed for '%s'\n", opt->input );
        Resolve_FreeResult( &res );
        return 1;
    }
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

    /* `check` mode: the front-end, closed-world and supported-ops gates all
    ** passed — report and stop before lifting/codegen/link. */
    if ( opt->check_only ) {
        printf( "[+] %s: OK (%zu module%s, closed world)\n",
                opt->input, res.Count, res.Count == 1 ? "" : "s" );
        rc = 0;
        goto cleanup;
    }

    /* ---- 3. lift to IR ---- */
    m = lc_lift_program( entryProto, reach.items, reach.count );
    if ( m == NULL ) {
        fprintf( stderr, "aotc: error: lifting failed\n" );
        goto cleanup;
    }
    m->opt_level = opt->opt_level;   /* codegen picks M1 fastpaths at -O1+ */

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

    /* ---- 5. codegen ---- */
    cm = lc_codegen( m );
    if ( cm == NULL ) {
        fprintf( stderr, "aotc: error: codegen failed\n" );
        goto cleanup;
    }

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

        /* Programs that never mention "debug" can't activate debug hooks, so
        ** their exes drop the bytecode interpreter (same conservative scan
        ** that gates the -O1 type proofs). Programs referencing ffi/bit get
        ** the FFI initialization anchor linked in. */
        if ( !LuacLink_LinkProgram( obj_path, opt->output,
                                    !lc_module_uses_debug( m ),
                                    res.RequiresFfi || lc_module_uses_ffi( m ),
                                    lc_module_used_libs( m ),
                                    opt->shared_rt,
                                    opt->ld_internal,
                                    opt->no_gc_sections,
                                    err, sizeof( err ) ) ) {
            fprintf( stderr, "aotc: error: link failed: %s\n",
                     err[0] ? err : "(unknown)" );
            if ( !opt->keep_temps ) remove( obj_path );
            goto cleanup;
        }
        if ( !opt->keep_temps ) remove( obj_path );

        printf( "[+] %s (%zu module%s, %u function%s) -> %s\n",
                opt->input, res.Count, res.Count == 1 ? "" : "s",
                reach.count, reach.count == 1 ? "" : "s", opt->output );
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
             "usage: %s <main.lua> [-o output.exe] [-O<n>] [-L <pkg>]... "
             "[--shared-rt]\n",
             argv0 );
}

int main( int argc, char **argv ) {
    LcDriverOptions opt;
    const char *force[ 64 ];
    int  nforce = 0;
    int  i;

    memset( &opt, 0, sizeof( opt ) );
    opt.opt_level = 0;
    opt.ld_internal = -1;          /* env (CLUA_LD) decides unless flagged */

    for ( i = 1; i < argc; i++ ) {
        const char *a = argv[ i ];
        if ( strcmp( a, "-o" ) == 0 && i + 1 < argc ) {
            opt.output = argv[ ++i ];
        } else if ( strncmp( a, "-O", 2 ) == 0 && a[2] != '\0' ) {
            opt.opt_level = atoi( a + 2 );
        } else if ( strcmp( a, "-O" ) == 0 ) {
            opt.opt_level = 1;
        } else if ( strcmp( a, "--dll" ) == 0 ) {
            opt.emit_dll = true;
        } else if ( strcmp( a, "--shared-rt" ) == 0 ) {
            opt.shared_rt = true;
        } else if ( strcmp( a, "--ld=internal" ) == 0 ) {
            opt.ld_internal = 1;
        } else if ( strcmp( a, "--ld=gcc" ) == 0 ) {
            opt.ld_internal = 0;
        } else if ( strcmp( a, "--no-gc-sections-internal" ) == 0 ) {
            opt.no_gc_sections = true;
        } else if ( ( strcmp( a, "-L" ) == 0 || strcmp( a, "--link" ) == 0 )
                    && i + 1 < argc ) {
            if ( nforce < 63 ) {
                force[ nforce++ ] = argv[ ++i ];
                force[ nforce ]   = NULL;
            } else {
                ++i;
            }
        } else if ( a[0] != '-' && opt.input == NULL ) {
            opt.input = a;
        } else {
            fprintf( stderr, "aotc: warning: ignoring unknown argument '%s'\n", a );
        }
    }

    if ( opt.input == NULL ) {
        usage( argv[ 0 ] );
        return 2;
    }
    if ( opt.output == NULL ) {
        opt.output = "out.exe";
    }
    if ( nforce > 0 ) {
        opt.force_pkgs  = force;
        opt.nforce_pkgs = nforce;
    }

    return lc_drive( &opt );
}
#endif
