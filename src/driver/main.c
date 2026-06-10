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
#include "../codegen/protoinit_emit.h"
#include "../link/coff_write.h"
#include "../link/pe_link_v2.h"

#include "../compiler/resolve.h"
#include "../compiler/paths.h"
#include "../compiler/diag.h"
#include "../driver/lc_undump.h"
#include "../driver/closed_world.h"

/* Reused front-end produces a Proto*; we read its nested-proto array (p[]) to
** collect the reachable set for lifting. */
#include "lua.h"
#include "lauxlib.h"
#include "lobject.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>   /* _getpid */
#include <direct.h>    /* _mkdir   */

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
    if ( opt == NULL || opt->input == NULL || opt->output == NULL ) return 2;

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

    /* ---- 3. lift to IR ---- */
    m = lc_lift_program( entryProto, reach.items, reach.count );
    if ( m == NULL ) {
        fprintf( stderr, "aotc: error: lifting failed\n" );
        goto cleanup;
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

    /* ---- 5. codegen ---- */
    cm = lc_codegen( m );
    if ( cm == NULL ) {
        fprintf( stderr, "aotc: error: codegen failed\n" );
        goto cleanup;
    }

    /* ---- 6/7. emit COFF .o + generated ProtoInit .c, then native link ---- */
    {
        char obj_path[ 1024 ];
        char proto_c[ 1024 ];
        char err[ 512 ] = { 0 };
        int  pid = ( int )_getpid( );

        _mkdir( "build" );
        _mkdir( "build\\tmp" );

        snprintf( obj_path, sizeof( obj_path ),
                  "build\\tmp\\luac_user_%d.o", pid );
        snprintf( proto_c, sizeof( proto_c ),
                  "build\\tmp\\luac_protoinit_%d.c", pid );

        if ( !LcCoff_Write( obj_path, cm, err, sizeof( err ) ) ) {
            fprintf( stderr, "aotc: error: COFF write failed: %s\n",
                     err[0] ? err : "(unknown)" );
            goto cleanup;
        }
        if ( !LcEmitProtoInitC( proto_c, m, err, sizeof( err ) ) ) {
            fprintf( stderr, "aotc: error: ProtoInit emit failed: %s\n",
                     err[0] ? err : "(unknown)" );
            goto cleanup;
        }

        /* The Protos must stay alive through codegen + ProtoInit emit (both read
        ** func->source). Both are done now; the link reads only the files. */
        if ( !LuacLink_LinkProgram( obj_path, proto_c, opt->output,
                                    err, sizeof( err ) ) ) {
            fprintf( stderr, "aotc: error: link failed: %s\n",
                     err[0] ? err : "(unknown)" );
            goto cleanup;
        }

        printf( "[+] %s (%zu module%s, %u function%s) -> %s\n",
                opt->input, res.Count, res.Count == 1 ? "" : "s",
                reach.count, reach.count == 1 ? "" : "s", opt->output );
    }

    rc = 0;

cleanup:
    lc_codemodule_free( cm );
    lc_module_free( m );
    free( reach.items );
    lua_close( L );          /* AFTER codegen — Protos lived on L's stack */
    Resolve_FreeResult( &res );
    return rc;
}

#ifdef LUAC_AOTC_STANDALONE
static void usage( const char *argv0 ) {
    fprintf( stderr,
             "aotc (LuaC) — Lua 5.4 -> native Windows x64 PE\n"
             "usage: %s <main.lua> [-o output.exe] [-O<n>] [-L <pkg>]...\n",
             argv0 );
}

int main( int argc, char **argv ) {
    LcDriverOptions opt;
    const char *force[ 64 ];
    int  nforce = 0;
    int  i;

    memset( &opt, 0, sizeof( opt ) );
    opt.opt_level = 0;

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
