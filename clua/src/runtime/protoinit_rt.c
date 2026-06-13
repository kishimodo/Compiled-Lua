/*
** protoinit_rt.c — the LCPB deserializer: LuacProgram_BuildEntry for AOT exes.
**
** Compiled ONCE into the runtime archives. Reads the two symbols the COFF
** writer placed in the user object —
**     const unsigned char luac_protoblob[]   (the LCPB blob)
**     JIT_FUNC_T const    luac_fn_table[]    (native body per function index)
** — and reconstructs every reachable Proto at startup, registering each
** native body in the dispatch cache, exactly as the M0 generated-ProtoInit-C
** did. Format: protoblob_format.h (serializer: src/codegen/protoblob_emit.c).
**
** FIDELITY NOTE: the construction order below (luaF_newproto, fields, source,
** lineinfo, abslineinfo, k[], upvalues, nested children RECURSIVELY, code[],
** locvars, register) mirrors the old generated C call-for-call so the
** allocation/GC behavior of compiled programs is unchanged. Do not reorder.
**
** Like the generated C, this runs OUTSIDE any pcall: an allocation error
** during startup propagates to the panic handler (the program cannot run
** anyway). Malformed-blob reads fail soft: BuildEntry returns NULL and
** aot_entry prints "build entry failed".
*/
#include "lua.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"
#include "lfunc.h"
#include "lmem.h"
#include "lopcodes.h"
#include "lgc.h"          /* luaC_barrier (preload _ENV bind) */

#include "jit/dispatch.h"
#include "runtime/protoblob_format.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Defined in the user COFF object emitted by aotc/clua. */
extern const unsigned char luac_protoblob[];
extern JIT_FUNC_T const    luac_fn_table[];

/* ---- bounds-checked little-endian reader ---- */
typedef struct {
    const unsigned char *base;
    uint32_t             len;
    uint32_t             off;
    int                  ok;
} Rd;

static uint32_t rd_u32( Rd *r ) {
    uint32_t v = 0;
    if ( !r->ok || r->len - r->off < 4 || r->off > r->len ) { r->ok = 0; return 0; }
    v = ( uint32_t )r->base[ r->off ]
      | ( ( uint32_t )r->base[ r->off + 1 ] << 8 )
      | ( ( uint32_t )r->base[ r->off + 2 ] << 16 )
      | ( ( uint32_t )r->base[ r->off + 3 ] << 24 );
    r->off += 4;
    return v;
}
static int32_t rd_i32( Rd *r ) { return ( int32_t )rd_u32( r ); }
static uint64_t rd_u64( Rd *r ) {
    uint64_t lo = rd_u32( r );
    uint64_t hi = rd_u32( r );
    return lo | ( hi << 32 );
}
static unsigned rd_u8( Rd *r ) {
    if ( !r->ok || r->off >= r->len ) { r->ok = 0; return 0; }
    return r->base[ r->off++ ];
}
/* Returns a pointer into the blob for `n` raw bytes (no copy). */
static const unsigned char *rd_raw( Rd *r, uint32_t n ) {
    const unsigned char *p;
    if ( !r->ok || r->len - r->off < n || r->off > r->len ) { r->ok = 0; return NULL; }
    p = r->base + r->off;
    r->off += n;
    return p;
}

/* per-function build state */
enum { LCPB_UNBUILT = 0, LCPB_BUILDING = 1, LCPB_BUILT = 2 };

typedef struct {
    const unsigned char *blob;
    uint32_t             blob_len;
    uint32_t             nfuncs;
    const unsigned char *func_off;   /* nfuncs u32s, unaligned (read via helper) */
    Proto              **built;
    unsigned char       *state;
    /* module-preload names harvested during the build (pointers into blob) */
    const unsigned char **mod_name;
    uint32_t             *mod_name_len;
} Ctx;

static uint32_t func_off_at( const Ctx *cx, uint32_t idx ) {
    const unsigned char *p = cx->func_off + ( size_t )idx * 4;
    return ( uint32_t )p[0] | ( ( uint32_t )p[1] << 8 )
         | ( ( uint32_t )p[2] << 16 ) | ( ( uint32_t )p[3] << 24 );
}

/* Build function `idx` (and, recursively, its nested children) — the exact
** construction sequence of the old generated ProtoInit_<idx>. */
static Proto *BuildOne( lua_State *L, Ctx *cx, uint32_t idx ) {
    Rd       r;
    Proto   *P;
    uint32_t n, j;
    unsigned has;

    if ( idx >= cx->nfuncs ) return NULL;
    if ( cx->state[ idx ] != LCPB_UNBUILT ) return NULL;  /* cycle/dup = malformed */
    cx->state[ idx ] = LCPB_BUILDING;

    r.base = cx->blob;
    r.len  = cx->blob_len;
    r.off  = func_off_at( cx, idx );
    r.ok   = ( r.off <= r.len );
    if ( !r.ok ) return NULL;

    P = luaF_newproto( L );

    P->numparams    = ( lu_byte )rd_u8( &r );
    P->is_vararg    = ( lu_byte )rd_u8( &r );
    P->maxstacksize = ( lu_byte )rd_u8( &r );
    has             = rd_u8( &r );
    P->linedefined     = ( int )rd_i32( &r );
    P->lastlinedefined = ( int )rd_i32( &r );
    if ( !r.ok ) return NULL;

    if ( has ) {
        uint32_t slen = rd_u32( &r );
        const unsigned char *s = rd_raw( &r, slen );
        if ( !r.ok ) return NULL;
        P->source = luaS_newlstr( L, ( const char * )s, ( size_t )slen );
    }

    n = rd_u32( &r );
    P->sizelineinfo = ( int )n;
    if ( r.ok && n > 0 ) {
        const unsigned char *s = rd_raw( &r, n );
        if ( !r.ok ) return NULL;
        P->lineinfo = luaM_newvector( L, ( int )n, ls_byte );
        memcpy( P->lineinfo, s, ( size_t )n );
    }

    n = rd_u32( &r );
    P->sizeabslineinfo = ( int )n;
    if ( r.ok && n > 0 ) {
        P->abslineinfo = luaM_newvector( L, ( int )n, AbsLineInfo );
        for ( j = 0; j < n; j++ ) {
            P->abslineinfo[j].pc   = ( int )rd_i32( &r );
            P->abslineinfo[j].line = ( int )rd_i32( &r );
        }
        if ( !r.ok ) return NULL;
    }

    n = rd_u32( &r );
    P->sizek = ( int )n;
    if ( r.ok && n > 0 ) {
        P->k = luaM_newvector( L, ( int )n, TValue );
        for ( j = 0; j < n; j++ ) {
            unsigned tag = rd_u8( &r );
            switch ( tag ) {
                case LCPB_K_NIL:   setnilvalue( &P->k[j] ); break;
                case LCPB_K_FALSE: setbfvalue( &P->k[j] );  break;
                case LCPB_K_TRUE:  setbtvalue( &P->k[j] );  break;
                case LCPB_K_INT: {
                    uint64_t bits = rd_u64( &r );
                    setivalue( &P->k[j], ( lua_Integer )( int64_t )bits );
                    break;
                }
                case LCPB_K_FLT: {
                    uint64_t bits = rd_u64( &r );
                    double   d;
                    memcpy( &d, &bits, sizeof( d ) );
                    setfltvalue( &P->k[j], ( lua_Number )d );
                    break;
                }
                case LCPB_K_STR: {
                    uint32_t slen = rd_u32( &r );
                    const unsigned char *s = rd_raw( &r, slen );
                    if ( !r.ok ) return NULL;
                    setsvalue( L, &P->k[j],
                               luaS_newlstr( L, ( const char * )s,
                                             ( size_t )slen ) );
                    break;
                }
                default:
                    return NULL;
            }
            if ( !r.ok ) return NULL;
        }
    }

    n = rd_u32( &r );
    P->sizeupvalues = ( int )n;
    if ( r.ok && n > 0 ) {
        P->upvalues = luaM_newvector( L, ( int )n, Upvaldesc );
        for ( j = 0; j < n; j++ ) {
            P->upvalues[j].instack = ( lu_byte )rd_u8( &r );
            P->upvalues[j].idx     = ( lu_byte )rd_u8( &r );
            P->upvalues[j].kind    = ( lu_byte )rd_u8( &r );
            has = rd_u8( &r );
            if ( has ) {
                uint32_t slen = rd_u32( &r );
                const unsigned char *s = rd_raw( &r, slen );
                if ( !r.ok ) return NULL;
                P->upvalues[j].name =
                    luaS_newlstr( L, ( const char * )s, ( size_t )slen );
            } else {
                P->upvalues[j].name = NULL;
            }
        }
        if ( !r.ok ) return NULL;
    }

    n = rd_u32( &r );
    P->sizep = ( int )n;
    if ( r.ok && n > 0 ) {
        P->p = luaM_newvector( L, ( int )n, Proto * );
        for ( j = 0; j < n; j++ ) {
            uint32_t ci = rd_u32( &r );
            Proto   *child;
            if ( !r.ok ) return NULL;
            /* The reader for THIS record is positional state on the C stack;
            ** the recursive child build uses its own reader, so r stays
            ** valid across the call (the generated C had the same shape). */
            child = BuildOne( L, cx, ci );
            if ( child == NULL ) return NULL;
            P->p[j] = child;
        }
    }

    n = rd_u32( &r );
    P->sizecode = ( int )n;
    if ( r.ok && n > 0 ) {
        const unsigned char *s = rd_raw( &r, n * ( uint32_t )sizeof( Instruction ) );
        if ( !r.ok ) return NULL;
        P->code = luaM_newvector( L, ( int )n, Instruction );
        memcpy( P->code, s, ( size_t )n * sizeof( Instruction ) );
    }

    n = rd_u32( &r );
    P->sizelocvars = ( int )n;
    if ( r.ok && n > 0 ) {
        P->locvars = luaM_newvector( L, ( int )n, LocVar );
        for ( j = 0; j < n; j++ ) {
            P->locvars[j].startpc = ( int )rd_i32( &r );
            P->locvars[j].endpc   = ( int )rd_i32( &r );
            has = rd_u8( &r );
            if ( has ) {
                uint32_t slen = rd_u32( &r );
                const unsigned char *s = rd_raw( &r, slen );
                if ( !r.ok ) return NULL;
                P->locvars[j].varname =
                    luaS_newlstr( L, ( const char * )s, ( size_t )slen );
            } else {
                P->locvars[j].varname = NULL;
            }
        }
        if ( !r.ok ) return NULL;
    }

    has = rd_u8( &r );
    if ( has ) {
        uint32_t slen = rd_u32( &r );
        const unsigned char *s = rd_raw( &r, slen );
        if ( !r.ok ) return NULL;
        cx->mod_name[ idx ]     = s;
        cx->mod_name_len[ idx ] = slen;
    }
    if ( !r.ok ) return NULL;

    /* Register with the function-id (the blob index) so a native worker thread
       can resolve a function shipped to it by id (thread.spawn native path). */
    if ( !Jit_RegisterCompiledId( P, luac_fn_table[ idx ], ( int )idx ) ) return NULL;

    cx->built[ idx ] = P;
    cx->state[ idx ] = LCPB_BUILT;
    return P;
}

Proto *LuacProgram_BuildEntry( lua_State *L ) {
    Rd       r;
    Ctx      cx;
    uint32_t total, nfuncs, entry_idx, i;
    const unsigned char *is_root;
    Proto   *entry = NULL;

    memset( &cx, 0, sizeof( cx ) );

    /* header — the blob carries its own length (the symbol has no size) */
    r.base = luac_protoblob;
    r.len  = 5 * 4;           /* provisional: just the header */
    r.off  = 0;
    r.ok   = 1;
    if ( rd_u32( &r ) != LCPB_MAGIC )   return NULL;
    if ( rd_u32( &r ) != LCPB_VERSION ) return NULL;
    total = rd_u32( &r );
    if ( !r.ok || total < 5 * 4 ) return NULL;
    r.len = total;
    nfuncs    = rd_u32( &r );
    entry_idx = rd_u32( &r );
    if ( !r.ok || nfuncs == 0 || entry_idx >= nfuncs ) return NULL;

    cx.blob     = luac_protoblob;
    cx.blob_len = total;
    cx.nfuncs   = nfuncs;
    cx.func_off = rd_raw( &r, nfuncs * 4 );
    is_root     = rd_raw( &r, nfuncs );
    if ( !r.ok ) return NULL;

    cx.built        = ( Proto ** )calloc( nfuncs, sizeof( Proto * ) );
    cx.state        = ( unsigned char * )calloc( nfuncs, 1 );
    cx.mod_name     = ( const unsigned char ** )calloc( nfuncs, sizeof( void * ) );
    cx.mod_name_len = ( uint32_t * )calloc( nfuncs, sizeof( uint32_t ) );
    if ( !cx.built || !cx.state || !cx.mod_name || !cx.mod_name_len ) goto done;

    /* Build each ROOT in index order (children are built recursively by their
    ** parents) — same order as the old generated LuacProgram_BuildEntry. */
    for ( i = 0; i < nfuncs; i++ ) {
        if ( !is_root[ i ] ) continue;
        if ( BuildOne( L, &cx, i ) == NULL ) goto done;
    }
    if ( cx.built[ entry_idx ] == NULL ) goto done;

    /* Register each REQUIRED module (root, has module_name, not the entry) in
    ** package.preload: closure over the built Proto with _ENV bound to the
    ** globals, exactly as the generated C did. */
    for ( i = 0; i < nfuncs; i++ ) {
        Proto *p;
        if ( !is_root[ i ] || i == entry_idx ) continue;
        if ( cx.mod_name[ i ] == NULL ) continue;
        p = cx.built[ i ];
        {
            LClosure *mcl = luaF_newLclosure( L, p->sizeupvalues );
            mcl->p = p;
            setclLvalue2s( L, L->top.p, mcl );
            L->top.p++;
            luaF_initupvals( L, mcl );
            if ( p->sizeupvalues >= 1 ) {
                const TValue *gt =
                    &hvalue( &G( L )->l_registry )->array[ LUA_RIDX_GLOBALS - 1 ];
                setobj( L, mcl->upvals[0]->v.p, gt );
                luaC_barrier( L, mcl->upvals[0], gt );
            }
            lua_getglobal( L, "package" );
            lua_getfield( L, -1, "preload" );
            lua_pushlstring( L, ( const char * )cx.mod_name[ i ],
                             ( size_t )cx.mod_name_len[ i ] );
            lua_pushvalue( L, -4 );                /* the module closure */
            lua_settable( L, -3 );                 /* preload[name] = closure */
            lua_pop( L, 3 );                       /* preload, package, closure */
        }
    }

    entry = cx.built[ entry_idx ];

done:
    free( cx.built );
    free( cx.state );
    free( ( void * )cx.mod_name );
    free( cx.mod_name_len );
    return entry;
}
