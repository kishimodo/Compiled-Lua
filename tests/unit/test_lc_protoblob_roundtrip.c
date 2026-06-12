/* test_lc_protoblob_roundtrip.c — the LCPB blob is a faithful, in-sync
 * serialization of every reachable Proto.
 *
 * Compiles a source (env CLUA_BLOBTEST_SRC = path to a .lua file, else an
 * embedded nested-function default), lifts the full module, serializes with
 * LcBuildProtoBlob, then WALKS the blob with an independent reader:
 *   - every record's parse cursor must land exactly on the next record's
 *     func_off (desync detector — a writer/reader field asymmetry corrupts
 *     the tail of one record and this catches it at the byte level);
 *   - every parsed field must equal the source Proto's field (counts,
 *     constants, upvalue descs, code bytes, line tables, locvars).
 * Guards AOT-MULTIMOD-001's investigation surface.
 */
#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "ir/ir.h"
#include "ir/lift.h"
#include "codegen/protoblob_emit.h"
#include "runtime/protoblob_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define MAXP 4096
static Proto   *g_reach[ MAXP ];
static uint32_t g_nreach = 0;

static int collect( Proto *p ) {
    uint32_t i;
    int      c;
    for ( i = 0; i < g_nreach; i++ ) if ( g_reach[ i ] == p ) return 1;
    if ( g_nreach >= MAXP ) return 0;
    g_reach[ g_nreach++ ] = p;
    for ( c = 0; c < p->sizep; c++ ) if ( !collect( p->p[ c ] ) ) return 0;
    return 1;
}

/* ---- independent little-endian reader ---- */
typedef struct { const unsigned char *b; uint32_t len, off; int ok; } R;
static uint32_t ru32( R *r ) {
    uint32_t v;
    if ( !r->ok || r->off + 4 > r->len ) { r->ok = 0; return 0; }
    v = ( uint32_t )r->b[r->off] | ( ( uint32_t )r->b[r->off+1] << 8 )
      | ( ( uint32_t )r->b[r->off+2] << 16 ) | ( ( uint32_t )r->b[r->off+3] << 24 );
    r->off += 4;
    return v;
}
static int32_t ri32( R *r ) { return ( int32_t )ru32( r ); }
static unsigned ru8( R *r ) {
    if ( !r->ok || r->off >= r->len ) { r->ok = 0; return 0; }
    return r->b[ r->off++ ];
}
static uint64_t ru64( R *r ) {
    uint64_t lo = ru32( r ), hi = ru32( r );
    return lo | ( hi << 32 );
}
static const unsigned char *rraw( R *r, uint32_t n ) {
    const unsigned char *p;
    if ( !r->ok || r->off + n > r->len || r->off + n < r->off ) { r->ok = 0; return NULL; }
    p = r->b + r->off;
    r->off += n;
    return p;
}

static int g_fail = 0;
#define FCHECK( cond, idx, what ) do { \
    if ( !( cond ) ) { \
        printf( "[-] FAIL blob func %u field %s (off ~%u)\n", ( unsigned )( idx ), what, r.off ); \
        g_fail = 1; \
        return 0; \
    } } while ( 0 )

/* Parse one record at `off`, comparing against source Proto P. Returns the
 * end cursor through *endp (0 on hard failure). */
static int check_record( const unsigned char *blob, uint32_t len, uint32_t off,
                         uint32_t idx, LcModule *m, Proto *P, uint32_t *endp ) {
    R r = { blob, len, off, 1 };
    uint32_t n, j;
    unsigned has;
    const unsigned char *raw;

    FCHECK( ru8( &r ) == ( unsigned )P->numparams,    idx, "numparams" );
    FCHECK( ru8( &r ) == ( unsigned )P->is_vararg,    idx, "is_vararg" );
    FCHECK( ru8( &r ) == ( unsigned )P->maxstacksize, idx, "maxstacksize" );
    has = ru8( &r );
    FCHECK( r.ok && has == ( P->source != NULL ? 1u : 0u ), idx, "has_source" );
    FCHECK( ri32( &r ) == P->linedefined,     idx, "linedefined" );
    FCHECK( ri32( &r ) == P->lastlinedefined, idx, "lastlinedefined" );
    if ( has ) {
        n = ru32( &r );
        FCHECK( r.ok && n == ( uint32_t )tsslen( P->source ), idx, "srclen" );
        raw = rraw( &r, n );
        FCHECK( raw && memcmp( raw, getstr( P->source ), n ) == 0, idx, "srcbytes" );
    }
    n = ru32( &r );
    FCHECK( r.ok && n == ( uint32_t )P->sizelineinfo, idx, "sizelineinfo" );
    raw = rraw( &r, n );
    FCHECK( ( n == 0 || raw ) && ( n == 0 || memcmp( raw, P->lineinfo, n ) == 0 ),
            idx, "lineinfo" );
    n = ru32( &r );
    FCHECK( r.ok && n == ( uint32_t )P->sizeabslineinfo, idx, "sizeabslineinfo" );
    for ( j = 0; j < n; j++ ) {
        FCHECK( ri32( &r ) == P->abslineinfo[j].pc,   idx, "abs.pc" );
        FCHECK( ri32( &r ) == P->abslineinfo[j].line, idx, "abs.line" );
    }
    n = ru32( &r );
    FCHECK( r.ok && n == ( uint32_t )P->sizek, idx, "sizek" );
    for ( j = 0; j < n; j++ ) {
        const TValue *o = &P->k[j];
        unsigned tag = ru8( &r );
        if ( ttisstring( o ) ) {
            uint32_t sl = ( tag == LCPB_K_STR ) ? ru32( &r ) : 0;
            FCHECK( tag == LCPB_K_STR, idx, "k.tag(str)" );
            FCHECK( r.ok && sl == ( uint32_t )tsslen( tsvalue( o ) ), idx, "k.strlen" );
            raw = rraw( &r, sl );
            FCHECK( raw && memcmp( raw, getstr( tsvalue( o ) ), sl ) == 0, idx, "k.strbytes" );
        } else if ( ttisinteger( o ) ) {
            FCHECK( tag == LCPB_K_INT, idx, "k.tag(int)" );
            FCHECK( ru64( &r ) == ( uint64_t )( int64_t )ivalue( o ), idx, "k.int" );
        } else if ( ttisfloat( o ) ) {
            uint64_t bits, want;
            double d = ( double )fltvalue( o );
            FCHECK( tag == LCPB_K_FLT, idx, "k.tag(flt)" );
            bits = ru64( &r );
            memcpy( &want, &d, 8 );
            FCHECK( bits == want, idx, "k.fltbits" );
        } else if ( ttisboolean( o ) ) {
            FCHECK( tag == ( ttistrue( o ) ? LCPB_K_TRUE : LCPB_K_FALSE ), idx, "k.bool" );
        } else {
            FCHECK( tag == LCPB_K_NIL, idx, "k.nil" );
        }
    }
    n = ru32( &r );
    FCHECK( r.ok && n == ( uint32_t )P->sizeupvalues, idx, "sizeupvalues" );
    for ( j = 0; j < n; j++ ) {
        Upvaldesc *uv = &P->upvalues[j];
        FCHECK( ru8( &r ) == ( unsigned )uv->instack, idx, "uv.instack" );
        FCHECK( ru8( &r ) == ( unsigned )uv->idx,     idx, "uv.idx" );
        FCHECK( ru8( &r ) == ( unsigned )uv->kind,    idx, "uv.kind" );
        has = ru8( &r );
        FCHECK( r.ok && has == ( uv->name != NULL ? 1u : 0u ), idx, "uv.hasname" );
        if ( has ) {
            uint32_t sl = ru32( &r );
            FCHECK( r.ok && sl == ( uint32_t )tsslen( uv->name ), idx, "uv.namelen" );
            raw = rraw( &r, sl );
            FCHECK( raw && memcmp( raw, getstr( uv->name ), sl ) == 0, idx, "uv.namebytes" );
        }
    }
    n = ru32( &r );
    FCHECK( r.ok && n == ( uint32_t )P->sizep, idx, "sizep" );
    for ( j = 0; j < n; j++ ) {
        uint32_t ci = ru32( &r );
        uint32_t k2;
        Proto   *want = P->p[j];
        FCHECK( r.ok && ci < m->nfuncs, idx, "child.range" );
        k2 = ci;
        FCHECK( m->funcs[k2] && m->funcs[k2]->source == want, idx, "child.map" );
    }
    n = ru32( &r );
    FCHECK( r.ok && n == ( uint32_t )P->sizecode, idx, "sizecode" );
    raw = rraw( &r, n * ( uint32_t )sizeof( Instruction ) );
    FCHECK( ( n == 0 || raw ) &&
            ( n == 0 || memcmp( raw, P->code, ( size_t )n * sizeof( Instruction ) ) == 0 ),
            idx, "codebytes" );
    n = ru32( &r );
    FCHECK( r.ok && n == ( uint32_t )P->sizelocvars, idx, "sizelocvars" );
    for ( j = 0; j < n; j++ ) {
        LocVar *v = &P->locvars[j];
        FCHECK( ri32( &r ) == v->startpc, idx, "lv.startpc" );
        FCHECK( ri32( &r ) == v->endpc,   idx, "lv.endpc" );
        has = ru8( &r );
        FCHECK( r.ok && has == ( v->varname != NULL ? 1u : 0u ), idx, "lv.hasname" );
        if ( has ) {
            uint32_t sl = ru32( &r );
            FCHECK( r.ok && sl == ( uint32_t )tsslen( v->varname ), idx, "lv.namelen" );
            raw = rraw( &r, sl );
            FCHECK( raw && memcmp( raw, getstr( v->varname ), sl ) == 0, idx, "lv.namebytes" );
        }
    }
    has = ru8( &r );
    FCHECK( r.ok, idx, "has_module_name" );
    if ( has ) {
        uint32_t sl = ru32( &r );
        raw = rraw( &r, sl );
        FCHECK( raw != NULL, idx, "module_name" );
    }
    *endp = r.off;
    return 1;
}

int main( void ) {
    lua_State *L = luaL_newstate( );
    Proto     *P;
    LcModule  *m;
    unsigned char *blob = NULL;
    size_t     blen = 0;
    char       err[ 256 ] = { 0 };
    const char *srcpath = getenv( "CLUA_BLOBTEST_SRC" );
    uint32_t   i;

    TEST_BEGIN( "lc_protoblob_roundtrip" );

    if ( srcpath != NULL && srcpath[0] != '\0' ) {
        CHECK( luaL_loadfile( L, srcpath ) == LUA_OK );
    } else {
        CHECK( luaL_loadstring( L,
            "local M = {}\n"
            "local function inner(a, b) return a .. tostring(b) end\n"
            "function M.outer(t)\n"
            "  local acc = 0.5\n"
            "  for i = 1, #t do acc = acc + i; M[i] = inner('x', i) end\n"
            "  return acc, nil, true, false, 9007199254740993\n"
            "end\n"
            "return M\n" ) == LUA_OK );
    }
    P = ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
    CHECK_NOT_NULL( P );
    CHECK( collect( P ) );
    printf( "[i] reachable protos: %u\n", g_nreach );

    m = lc_lift_program( P, g_reach, g_nreach );
    CHECK_NOT_NULL( m );
    CHECK( m->nfuncs == g_nreach );

    CHECK( LcBuildProtoBlob( m, &blob, &blen, err, sizeof( err ) ) );
    if ( err[0] ) printf( "[i] emit err: %s\n", err );
    CHECK_NOT_NULL( blob );
    printf( "[i] blob bytes: %u\n", ( unsigned )blen );

    /* header */
    {
        R r = { blob, ( uint32_t )blen, 0, 1 };
        uint32_t total, nfuncs, entry_idx;
        CHECK( ru32( &r ) == LCPB_MAGIC );
        CHECK( ru32( &r ) == LCPB_VERSION );
        total = ru32( &r );
        CHECK( total == ( uint32_t )blen );
        nfuncs = ru32( &r );
        CHECK( nfuncs == m->nfuncs );
        entry_idx = ru32( &r );
        CHECK( entry_idx < nfuncs );

        /* offsets + roots */
        {
            uint32_t off_at = r.off;
            uint32_t roots_at = off_at + nfuncs * 4;
            uint32_t first_rec = roots_at + nfuncs;
            uint32_t prev_end = first_rec;
            for ( i = 0; i < nfuncs; i++ ) {
                R ro = { blob, ( uint32_t )blen, off_at + i * 4, 1 };
                uint32_t off = ru32( &ro );
                uint32_t end = 0;
                if ( off != prev_end ) {
                    printf( "[-] FAIL func %u: func_off=%u but previous record "
                            "ended at %u (DESYNC)\n", i, off, prev_end );
                    g_fail = 1;
                    break;
                }
                if ( !check_record( blob, ( uint32_t )blen, off, i, m,
                                    m->funcs[i]->source, &end ) ) break;
                prev_end = end;
            }
            if ( !g_fail && i == nfuncs ) {
                CHECK( prev_end == ( uint32_t )blen );
                printf( "[i] all %u records in sync, every field matches\n", nfuncs );
            }
        }
    }
    CHECK( !g_fail );

    free( blob );
    lc_module_free( m );
    lua_close( L );
    TEST_END();
}
