/* src/codegen/lc_codebuf.c */
#include "codegen/lc_codebuf.h"
#include <stdlib.h>
#include <string.h>

int LcCodeBuf_Init( LcCodeBuf *b, size_t cap ) {
    memset( b, 0, sizeof( *b ) );
    if ( cap < 16 ) cap = 16;
    b->bytes = ( uint8_t * )malloc( cap );
    if ( !b->bytes ) return 0;
    b->cap = cap;
    return 1;
}
int LcCodeBuf_Append( LcCodeBuf *b, const uint8_t *p, size_t n ) {
    if ( b->used + n > b->cap ) {
        size_t nc = b->cap ? b->cap : 16;
        while ( nc < b->used + n ) nc *= 2;
        uint8_t *nb = ( uint8_t * )realloc( b->bytes, nc );
        if ( !nb ) return 0;
        b->bytes = nb; b->cap = nc;
    }
    memcpy( b->bytes + b->used, p, n );
    b->used += n;
    return 1;
}
int LcCodeBuf_AddReloc( LcCodeBuf *b, LcRelocKind k, uint32_t off, const char *sym, int32_t addend ) {
    if ( b->nrelocs == b->relocap ) {
        size_t nc = b->relocap ? b->relocap * 2 : 8;
        LcReloc *nr = ( LcReloc * )realloc( b->relocs, nc * sizeof( LcReloc ) );
        if ( !nr ) return 0;
        b->relocs = nr; b->relocap = nc;
    }
    LcReloc *r = &b->relocs[ b->nrelocs++ ];
    r->kind = k; r->offset = off; r->addend = addend;
    memset( r->symbol, 0, sizeof( r->symbol ) );
    strncpy( r->symbol, sym, sizeof( r->symbol ) - 1 );
    return 1;
}
void LcCodeBuf_Free( LcCodeBuf *b ) {
    free( b->bytes ); free( b->relocs );
    memset( b, 0, sizeof( *b ) );
}
