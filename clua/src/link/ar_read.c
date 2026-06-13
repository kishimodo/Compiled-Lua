/*
** ar_read.c — see ar_read.h. GNU `ar` archive reader.
*/
#include "link/ar_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AR_MAGIC      "!<arch>\n"
#define AR_MAGIC_LEN  8
#define AR_HDR_LEN    60

static int afail( char *err, size_t errlen, const char *fmt, const char *a ) {
    if ( err && errlen ) snprintf( err, errlen, fmt, a ? a : "" );
    return 0;
}

static uint32_t be32( const uint8_t *p ) {
    return ( ( uint32_t )p[0] << 24 ) | ( ( uint32_t )p[1] << 16 ) |
           ( ( uint32_t )p[2] << 8 ) | ( uint32_t )p[3];
}

/* parse a fixed-width decimal field (space-padded) */
static uint32_t dec_field( const uint8_t *p, int width ) {
    uint32_t v = 0;
    int i;
    for ( i = 0; i < width; i++ ) {
        if ( p[i] >= '0' && p[i] <= '9' ) v = v * 10 + ( uint32_t )( p[i] - '0' );
        else break;
    }
    return v;
}

int LcAr_Open( const char *path, LcArchive *out, char *err, size_t errlen ) {
    FILE   *f;
    long    sz;
    size_t  off;
    const uint8_t *longnames = NULL;
    uint32_t longnames_len = 0;
    uint32_t capm = 0;

    memset( out, 0, sizeof( *out ) );
    snprintf( out->path, sizeof( out->path ), "%s", path ? path : "" );

    f = fopen( path, "rb" );
    if ( !f ) return afail( err, errlen, "cannot open archive %s", path );
    fseek( f, 0, SEEK_END );
    sz = ftell( f );
    fseek( f, 0, SEEK_SET );
    if ( sz <= AR_MAGIC_LEN ) { fclose( f ); return afail( err, errlen, "archive too small %s", path ); }
    out->buf = ( uint8_t * )malloc( ( size_t )sz );
    if ( !out->buf ) { fclose( f ); return afail( err, errlen, "oom %s", path ); }
    if ( fread( out->buf, 1, ( size_t )sz, f ) != ( size_t )sz ) {
        fclose( f ); LcAr_Close( out ); return afail( err, errlen, "short read %s", path );
    }
    fclose( f );
    out->buf_len = ( size_t )sz;

    if ( memcmp( out->buf, AR_MAGIC, AR_MAGIC_LEN ) != 0 ) {
        LcAr_Close( out );
        return afail( err, errlen, "bad archive magic %s", path );
    }

    /* First pass: locate the "//" long-name member (it can precede members
    ** whose names reference it). The "/" symbol index is member 0. */
    off = AR_MAGIC_LEN;
    while ( off + AR_HDR_LEN <= out->buf_len ) {
        const uint8_t *h = out->buf + off;
        uint32_t msize = dec_field( h + 48, 10 );
        size_t   data_off = off + AR_HDR_LEN;
        if ( h[0] == '/' && h[1] == '/' && ( h[2] == ' ' || h[2] == '/' ) ) {
            longnames = out->buf + data_off;
            longnames_len = msize;
        }
        off = data_off + msize;
        if ( msize & 1 ) off++; /* 2-byte pad */
    }

    /* Second pass: collect members (skip the "/" and "//" specials) and the
    ** symbol index. */
    off = AR_MAGIC_LEN;
    while ( off + AR_HDR_LEN <= out->buf_len ) {
        const uint8_t *h = out->buf + off;
        uint32_t msize = dec_field( h + 48, 10 );
        size_t   data_off = off + AR_HDR_LEN;
        char     rawname[17];
        int      is_special = 0;

        memcpy( rawname, h, 16 );
        rawname[16] = '\0';

        if ( data_off + msize > out->buf_len ) break;

        /* Special members: name "/ " (symbol index), "// " (long-name table).
        ** A member named "/<dec>" is an ordinary member with a long name. */
        if ( rawname[0] == '/' && ( rawname[1] == ' ' || rawname[1] == '\0' ) ) {
            /* "/" symbol index member (SysV/GNU big-endian form) */
            const uint8_t *d = out->buf + data_off;
            if ( msize >= 4 ) {
                uint32_t n = be32( d );
                uint32_t i;
                const uint8_t *names = d + 4 + ( size_t )n * 4;
                const uint8_t *names_end = d + msize;
                out->index = ( LcArSym * )calloc( n ? n : 1, sizeof( LcArSym ) );
                if ( !out->index ) { LcAr_Close( out ); return afail( err, errlen, "oom %s", path ); }
                /* copy the name pool wholesale so symname ptrs stay valid */
                out->sympool = ( char * )malloc( msize );
                if ( !out->sympool ) { LcAr_Close( out ); return afail( err, errlen, "oom %s", path ); }
                memcpy( out->sympool, d, msize );
                out->sympool_len = msize;
                {
                    char *pn = out->sympool + ( names - d );
                    char *pend = out->sympool + msize;
                    for ( i = 0; i < n && pn < pend; i++ ) {
                        out->index[i].member_off = be32( d + 4 + ( size_t )i * 4 );
                        out->index[i].symname    = pn;
                        pn += strlen( pn ) + 1;
                    }
                    out->nindex = i;
                }
                (void)names_end;
            }
            is_special = 1;
        } else if ( rawname[0] == '/' && rawname[1] == '/' ) {
            is_special = 1; /* long-name table, already captured */
        }

        if ( !is_special ) {
            char name[256];
            if ( rawname[0] == '/' && rawname[1] >= '0' && rawname[1] <= '9' && longnames ) {
                uint32_t lnoff = ( uint32_t )strtol( rawname + 1, NULL, 10 );
                uint32_t k = 0;
                name[0] = '\0';
                while ( lnoff + k < longnames_len && k < sizeof( name ) - 1 ) {
                    char c = ( char )longnames[ lnoff + k ];
                    if ( c == '\n' || c == '\0' || ( c == '/' ) ) break;
                    name[k] = c; k++;
                }
                name[k] = '\0';
            } else {
                int k = 0;
                while ( k < 16 && rawname[k] != '/' && rawname[k] != ' ' ) { name[k] = rawname[k]; k++; }
                name[k] = '\0';
            }
            if ( out->nmembers >= capm ) {
                uint32_t nc = capm ? capm * 2 : 32;
                LcArMember *nm = ( LcArMember * )realloc( out->members, nc * sizeof( LcArMember ) );
                if ( !nm ) { LcAr_Close( out ); return afail( err, errlen, "oom %s", path ); }
                out->members = nm; capm = nc;
            }
            snprintf( out->members[ out->nmembers ].name,
                      sizeof( out->members[ out->nmembers ].name ), "%s", name );
            out->members[ out->nmembers ].data    = out->buf + data_off;
            out->members[ out->nmembers ].size    = msize;
            out->members[ out->nmembers ].hdr_off = ( uint32_t )off;
            out->nmembers++;
        }

        off = data_off + msize;
        if ( msize & 1 ) off++;
    }

    return 1;
}

const LcArMember *LcAr_MemberByHdrOff( const LcArchive *a, uint32_t hdr_off ) {
    uint32_t i;
    for ( i = 0; i < a->nmembers; i++ )
        if ( a->members[i].hdr_off == hdr_off ) return &a->members[i];
    return NULL;
}

const LcArMember *LcAr_MemberDefining( const LcArchive *a, const char *sym ) {
    uint32_t i;
    for ( i = 0; i < a->nindex; i++ ) {
        if ( strcmp( a->index[i].symname, sym ) == 0 )
            return LcAr_MemberByHdrOff( a, a->index[i].member_off );
    }
    return NULL;
}

void LcAr_Close( LcArchive *a ) {
    if ( !a ) return;
    free( a->buf );
    free( a->members );
    free( a->index );
    free( a->sympool );
    memset( a, 0, sizeof( *a ) );
}
