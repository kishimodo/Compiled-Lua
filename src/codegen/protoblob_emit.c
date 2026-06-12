/*
** protoblob_emit.c — the LCPB serializer (successor to protoinit_emit.c).
**
** Walks the compile-time Protos exactly like the old C-emitter and writes the
** same data into the binary format documented in protoblob_format.h. The
** runtime deserializer (src/runtime/protoinit_rt.c) replays it with the same
** allocation order the generated C had, so compiled-program heap behavior is
** unchanged — but the user build no longer compiles any generated C.
*/
#include "codegen/protoblob_emit.h"
#include "runtime/protoblob_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>

#include "lua.h"
#include "lobject.h"
#include "lstate.h"   /* gco2ts() used by the tsvalue() accessor macro */

static void emit_err( char *err, size_t errlen, const char *fmt, ... ) {
    if ( err == NULL || errlen == 0 ) return;
    va_list ap;
    va_start( ap, fmt );
    vsnprintf( err, errlen, fmt, ap );
    va_end( ap );
}

/* ---- growable little-endian byte buffer ---- */
typedef struct { unsigned char *p; size_t len, cap; } BBuf;

static int bneed( BBuf *b, size_t n ) {
    if ( b->len + n > b->cap ) {
        size_t nc = b->cap ? b->cap * 2 : 1024;
        unsigned char *np;
        while ( nc < b->len + n ) nc *= 2;
        np = ( unsigned char * )realloc( b->p, nc );
        if ( np == NULL ) return 0;
        b->p = np; b->cap = nc;
    }
    return 1;
}
static int w8( BBuf *b, unsigned v ) {
    if ( !bneed( b, 1 ) ) return 0;
    b->p[ b->len++ ] = ( unsigned char )( v & 0xFF );
    return 1;
}
static int w32( BBuf *b, uint32_t v ) {
    return w8( b, v ) && w8( b, v >> 8 ) && w8( b, v >> 16 ) && w8( b, v >> 24 );
}
static int wi32( BBuf *b, int32_t v ) { return w32( b, ( uint32_t )v ); }
static int w64( BBuf *b, uint64_t v ) {
    return w32( b, ( uint32_t )v ) && w32( b, ( uint32_t )( v >> 32 ) );
}
static int wbytes( BBuf *b, const void *src, size_t n ) {
    if ( !bneed( b, n ) ) return 0;
    if ( n ) memcpy( b->p + b->len, src, n );
    b->len += n;
    return 1;
}
/* u32 length-prefixed byte string */
static int wlstr( BBuf *b, const char *s, size_t n ) {
    return w32( b, ( uint32_t )n ) && wbytes( b, s, n );
}
static void patch_u32( BBuf *b, size_t at, uint32_t v ) {
    b->p[ at + 0 ] = ( unsigned char )( v );
    b->p[ at + 1 ] = ( unsigned char )( v >> 8 );
    b->p[ at + 2 ] = ( unsigned char )( v >> 16 );
    b->p[ at + 3 ] = ( unsigned char )( v >> 24 );
}

/* Map a nested-proto child pointer back to its index in m->funcs. */
static int proto_index( LcModule *m, Proto *p ) {
    uint32_t i;
    for ( i = 0; i < m->nfuncs; i++ ) {
        if ( m->funcs[i] != NULL && m->funcs[i]->source == p ) return ( int )i;
    }
    return -1;
}

/* Serialize one function record (field order = the deserializer's
** construction order = the old generated C's construction order). */
static int emit_func( BBuf *b, LcModule *m, int idx, char *err, size_t errlen ) {
    Proto *P = m->funcs[idx]->source;
    int    j;

    if ( P == NULL ) {
        emit_err( err, errlen, "protoblob: function %d has no source Proto", idx );
        return 0;
    }

    if ( !w8( b, ( unsigned )P->numparams )    ||
         !w8( b, ( unsigned )P->is_vararg )    ||
         !w8( b, ( unsigned )P->maxstacksize ) ||
         !w8( b, P->source != NULL ? 1u : 0u ) ||
         !wi32( b, P->linedefined )            ||
         !wi32( b, P->lastlinedefined ) ) goto oom;

    if ( P->source != NULL ) {
        if ( !wlstr( b, getstr( P->source ), ( size_t )tsslen( P->source ) ) )
            goto oom;
    }

    if ( !w32( b, ( uint32_t )P->sizelineinfo ) ||
         !wbytes( b, P->lineinfo, ( size_t )P->sizelineinfo ) ) goto oom;

    if ( !w32( b, ( uint32_t )P->sizeabslineinfo ) ) goto oom;
    for ( j = 0; j < P->sizeabslineinfo; j++ ) {
        if ( !wi32( b, P->abslineinfo[j].pc ) ||
             !wi32( b, P->abslineinfo[j].line ) ) goto oom;
    }

    if ( !w32( b, ( uint32_t )P->sizek ) ) goto oom;
    for ( j = 0; j < P->sizek; j++ ) {
        const TValue *o = &P->k[j];
        if ( ttisstring( o ) ) {
            TString *ts = tsvalue( o );
            if ( !w8( b, LCPB_K_STR ) ||
                 !wlstr( b, getstr( ts ), ( size_t )tsslen( ts ) ) ) goto oom;
        } else if ( ttisinteger( o ) ) {
            if ( !w8( b, LCPB_K_INT ) ||
                 !w64( b, ( uint64_t )( int64_t )ivalue( o ) ) ) goto oom;
        } else if ( ttisfloat( o ) ) {
            /* raw IEEE-754 bits: exact round-trip, no text formatting */
            double   d = ( double )fltvalue( o );
            uint64_t bits;
            memcpy( &bits, &d, sizeof( bits ) );
            if ( !w8( b, LCPB_K_FLT ) || !w64( b, bits ) ) goto oom;
        } else if ( ttisboolean( o ) ) {
            if ( !w8( b, ttistrue( o ) ? LCPB_K_TRUE : LCPB_K_FALSE ) ) goto oom;
        } else if ( ttisnil( o ) ) {
            if ( !w8( b, LCPB_K_NIL ) ) goto oom;
        } else {
            emit_err( err, errlen,
                      "protoblob: unsupported constant type (tag=%d) at k[%d]",
                      ( int )ttypetag( o ), j );
            return 0;
        }
    }

    if ( !w32( b, ( uint32_t )P->sizeupvalues ) ) goto oom;
    for ( j = 0; j < P->sizeupvalues; j++ ) {
        Upvaldesc *uv = &P->upvalues[j];
        if ( !w8( b, ( unsigned )uv->instack ) ||
             !w8( b, ( unsigned )uv->idx )     ||
             !w8( b, ( unsigned )uv->kind )    ||
             !w8( b, uv->name != NULL ? 1u : 0u ) ) goto oom;
        if ( uv->name != NULL ) {
            if ( !wlstr( b, getstr( uv->name ), ( size_t )tsslen( uv->name ) ) )
                goto oom;
        }
    }

    if ( !w32( b, ( uint32_t )P->sizep ) ) goto oom;
    for ( j = 0; j < P->sizep; j++ ) {
        int ci = proto_index( m, P->p[j] );
        if ( ci < 0 ) {
            emit_err( err, errlen,
                      "protoblob: nested Proto p[%d] of function %d is not in "
                      "the module (lifting must include all reachable nested "
                      "functions)", j, idx );
            return 0;
        }
        if ( !w32( b, ( uint32_t )ci ) ) goto oom;
    }

    /* code[] shipped verbatim: getobjname reads it for error-message operand
    ** annotations, and it keeps savedpc arithmetic + the interpreter fallback
    ** valid (see the old protoinit_emit.c rationale). */
    if ( !w32( b, ( uint32_t )P->sizecode ) ||
         !wbytes( b, P->code, ( size_t )P->sizecode * sizeof( Instruction ) ) )
        goto oom;

    if ( !w32( b, ( uint32_t )P->sizelocvars ) ) goto oom;
    for ( j = 0; j < P->sizelocvars; j++ ) {
        LocVar *v = &P->locvars[j];
        if ( !wi32( b, v->startpc ) ||
             !wi32( b, v->endpc )   ||
             !w8( b, v->varname != NULL ? 1u : 0u ) ) goto oom;
        if ( v->varname != NULL ) {
            if ( !wlstr( b, getstr( v->varname ),
                         ( size_t )tsslen( v->varname ) ) ) goto oom;
        }
    }

    {
        const char *mn = m->funcs[idx]->module_name;
        if ( !w8( b, mn != NULL ? 1u : 0u ) ) goto oom;
        if ( mn != NULL && !wlstr( b, mn, strlen( mn ) ) ) goto oom;
    }
    return 1;

oom:
    emit_err( err, errlen, "protoblob: out of memory" );
    return 0;
}

int LcBuildProtoBlob( LcModule *m, unsigned char **out, size_t *out_len,
                      char *err, size_t errlen ) {
    BBuf     b = { 0 };
    char    *nested = NULL;
    uint32_t i;
    int      entry_idx = -1;
    size_t   off_table_at, total_len_at;

    if ( err && errlen ) err[0] = '\0';
    if ( out ) *out = NULL;
    if ( out_len ) *out_len = 0;

    if ( m == NULL || out == NULL || out_len == NULL ) {
        emit_err( err, errlen, "protoblob: NULL argument" );
        return 0;
    }
    if ( m->nfuncs == 0 ) {
        emit_err( err, errlen, "protoblob: module has no functions" );
        return 0;
    }

    for ( i = 0; i < m->nfuncs; i++ ) {
        if ( m->funcs[i] == m->entry ) { entry_idx = ( int )i; break; }
    }
    if ( entry_idx < 0 ) {
        emit_err( err, errlen, "protoblob: module entry is not among funcs" );
        return 0;
    }

    /* Root set: mark every Proto that appears in another function's p[] as
    ** nested; the rest are roots (entry + independently-required module main
    ** chunks). Same computation as the old LcEmitProtoInitC. */
    nested = ( char * )calloc( m->nfuncs, 1 );
    if ( nested == NULL ) { emit_err( err, errlen, "protoblob: oom" ); return 0; }
    for ( i = 0; i < m->nfuncs; i++ ) {
        Proto *P;
        int    c;
        if ( m->funcs[i] == NULL || m->funcs[i]->source == NULL ) continue;
        P = m->funcs[i]->source;
        for ( c = 0; c < P->sizep; c++ ) {
            int ci = proto_index( m, P->p[c] );
            if ( ci >= 0 ) nested[ ci ] = 1;
        }
    }

    /* header */
    if ( !w32( &b, LCPB_MAGIC ) || !w32( &b, LCPB_VERSION ) ) goto oom;
    total_len_at = b.len;
    if ( !w32( &b, 0 ) ) goto oom;                    /* total_len placeholder */
    if ( !w32( &b, m->nfuncs ) || !w32( &b, ( uint32_t )entry_idx ) ) goto oom;

    /* func_off placeholders + is_root flags */
    off_table_at = b.len;
    for ( i = 0; i < m->nfuncs; i++ ) { if ( !w32( &b, 0 ) ) goto oom; }
    for ( i = 0; i < m->nfuncs; i++ ) {
        if ( !w8( &b, nested[i] ? 0u : 1u ) ) goto oom;
    }

    /* records */
    for ( i = 0; i < m->nfuncs; i++ ) {
        patch_u32( &b, off_table_at + ( size_t )i * 4, ( uint32_t )b.len );
        if ( !emit_func( &b, m, ( int )i, err, errlen ) ) {
            free( nested );
            free( b.p );
            return 0;
        }
    }

    if ( b.len > 0xFFFFFFFFu ) {
        emit_err( err, errlen, "protoblob: blob exceeds 4 GiB" );
        free( nested );
        free( b.p );
        return 0;
    }
    patch_u32( &b, total_len_at, ( uint32_t )b.len );

    free( nested );
    *out = b.p;
    *out_len = b.len;
    return 1;

oom:
    emit_err( err, errlen, "protoblob: out of memory" );
    free( nested );
    free( b.p );
    return 0;
}
