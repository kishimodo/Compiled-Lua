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

/* Accounting is done AFTER each loop from the exit index, never inside it: the
** loop that ran to `i` performed i+1 comparisons if it matched and `n` if it
** ran out. 41 million per link is enough that a counter in the loop body would
** measurably slow every build in order to measure it. The loop bodies below are
** therefore byte-for-byte the uninstrumented ones. */
static uint64_t scanned( uint32_t i, uint32_t n ) {
    return ( i < n ) ? ( uint64_t )i + 1u : ( uint64_t )n;
}

/* ------------------------------------------------------------------------
** Lazily built lookup indexes (see the LcArchive comment in ar_read.h).
**
** Why: resolve_fixpoint asks every archive about every unresolved symbol and
** restarts after each pull, which measured 25,114 archive queries and 41 million
** armap name comparisons for one Rover link -- about 43% of a warm build. The
** same FNV-1a shape the linker already uses for its global symbol table
** (gsym_hash in pe_emit.c) applies directly here.
** See docs/benchmarks/archive-symbol-lookup.md.
** ---------------------------------------------------------------------- */

static uint32_t ar_hash_name( const char *s ) {
    uint32_t h = 2166136261u;
    const unsigned char *p = ( const unsigned char * )s;
    while ( *p ) { h ^= *p++; h *= 16777619u; }
    return h;
}

static uint32_t ar_hash_u32( uint32_t v ) {
    uint32_t h = 2166136261u;
    int i;
    for ( i = 0; i < 4; i++ ) { h ^= ( v >> ( i * 8 ) ) & 0xFFu; h *= 16777619u; }
    return h;
}

/* Smallest power of two >= 2n + 16. With at most n insertions the load factor
** can never exceed 0.5, so every probe terminates on an empty slot -- a probe
** loop that cannot terminate is a compiler HANG, which on a build server looks
** like a stuck link rather than a crash. Callers guard n against overflow. */
static uint32_t ar_slot_cap( uint32_t n ) {
    uint32_t cap = 16;
    while ( cap < n * 2u + 16u ) cap <<= 1;
    return cap;
}

/* n is bounded well below the point where 2n+16 or n+1 could wrap; past that we
** simply keep the linear scan rather than risk a tiny capacity. */
#define AR_INDEX_MAX ( 1u << 28 )

static void ar_build_sym_index( LcArchive *a ) {
    uint32_t cap, i;
    a->sym_index_state = -1;                 /* pessimistic: never retried */
    if ( a->nindex == 0 || a->nindex > AR_INDEX_MAX ) return;
    cap = ar_slot_cap( a->nindex );
    a->sym_slots = ( uint32_t * )calloc( cap, sizeof( uint32_t ) );
    if ( !a->sym_slots ) return;             /* degrade to the linear scan */
    a->sym_slot_cap = cap;
    for ( i = 0; i < a->nindex; i++ ) {
        uint32_t p = ar_hash_name( a->index[i].symname ) & ( cap - 1 );
        for ( ;; ) {
            uint32_t s = a->sym_slots[p];
            if ( s == 0 ) { a->sym_slots[p] = i + 1; break; }
            /* DUPLICATE NAME -> KEEP THE ENTRY ALREADY THERE. An armap may name
            ** one symbol against several members, and LcAr_MemberDefining must
            ** answer with the FIRST in index order, because that decides which
            ** member the linker pulls and therefore the emitted bytes. Ascending
            ** i plus this break is exactly first-insertion-wins. Overwriting
            ** here would still "work" on every lookup while silently changing
            ** the output -- tests/unit/test_lc_link_symindex.c pins it. */
            if ( strcmp( a->index[ s - 1 ].symname, a->index[i].symname ) == 0 )
                break;
            p = ( p + 1 ) & ( cap - 1 );
        }
    }
    a->sym_index_state = 1;
}

static void ar_build_mem_index( LcArchive *a ) {
    uint32_t cap, i;
    a->mem_index_state = -1;
    if ( a->nmembers == 0 || a->nmembers > AR_INDEX_MAX ) return;
    cap = ar_slot_cap( a->nmembers );
    a->mem_slots = ( uint32_t * )calloc( cap, sizeof( uint32_t ) );
    if ( !a->mem_slots ) return;
    a->mem_slot_cap = cap;
    for ( i = 0; i < a->nmembers; i++ ) {
        uint32_t p = ar_hash_u32( a->members[i].hdr_off ) & ( cap - 1 );
        for ( ;; ) {
            uint32_t s = a->mem_slots[p];
            if ( s == 0 ) { a->mem_slots[p] = i + 1; break; }
            /* First wins here too. hdr_offs are distinct file positions so this
            ** cannot fire on a well-formed archive, but keeping both builders
            ** the same shape means the answer equals the scan's regardless. */
            if ( a->members[ s - 1 ].hdr_off == a->members[i].hdr_off ) break;
            p = ( p + 1 ) & ( cap - 1 );
        }
    }
    a->mem_index_state = 1;
}

const LcArMember *LcAr_MemberByHdrOff( LcArchive *a, uint32_t hdr_off ) {
    uint32_t i;

    if ( a->mem_index_state == 0 ) ar_build_mem_index( a );
    if ( a->mem_index_state == 1 ) {
        uint32_t p = ar_hash_u32( hdr_off ) & ( a->mem_slot_cap - 1 );
        uint64_t probes = 0;
        for ( ;; ) {
            uint32_t s = a->mem_slots[p];
            /* Count only slots actually COMPARED, so this counter means the same
            ** thing as LcAr_MemberDefining's: the empty terminator ends the probe
            ** without a comparison and must not be charged. Incrementing above
            ** this break instead overstated every miss by one and made the two
            ** counters non-comparable. */
            if ( s == 0 ) break;
            probes++;
            if ( a->members[ s - 1 ].hdr_off == hdr_off ) {
                a->stats.mem_lookups++;
                a->stats.mem_compares += probes;
                return &a->members[ s - 1 ];
            }
            p = ( p + 1 ) & ( a->mem_slot_cap - 1 );
        }
        a->stats.mem_lookups++;
        a->stats.mem_compares += probes;
        return NULL;
    }

    for ( i = 0; i < a->nmembers; i++ )
        if ( a->members[i].hdr_off == hdr_off ) break;
    a->stats.mem_lookups++;
    a->stats.mem_compares += scanned( i, a->nmembers );
    return ( i < a->nmembers ) ? &a->members[i] : NULL;
}

/* Linear walk of the archive symbol index. The FIRST matching entry wins, even
** when its member_off resolves to no member -- we then return NULL and the
** caller tries the next archive. An armap may name one symbol against several
** members, and which member gets pulled decides output bytes, so scanning past
** a NULL here, or letting a later duplicate win, would change the emitted
** binary. Any future index must preserve that precedence exactly.
** See docs/benchmarks/archive-symbol-lookup.md. */
const LcArMember *LcAr_MemberDefining( LcArchive *a, const char *sym ) {
    const LcArMember *found = NULL;
    int matched = 0;
    uint32_t i;

    if ( a->sym_index_state == 0 ) ar_build_sym_index( a );
    if ( a->sym_index_state == 1 ) {
        uint32_t p = ar_hash_name( sym ) & ( a->sym_slot_cap - 1 );
        uint64_t probes = 0;
        for ( ;; ) {
            uint32_t s = a->sym_slots[p];
            if ( s == 0 ) break;                    /* empty slot: not present */
            probes++;
            if ( strcmp( a->index[ s - 1 ].symname, sym ) == 0 ) {
                matched = 1;
                /* May legitimately be NULL when member_off names no member. Do
                ** NOT fall through to a later duplicate looking for a non-NULL
                ** answer: the first entry wins, and the caller tries the next
                ** archive. Searching on would change which member is pulled. */
                found = LcAr_MemberByHdrOff( a, a->index[ s - 1 ].member_off );
                break;
            }
            p = ( p + 1 ) & ( a->sym_slot_cap - 1 );
        }
        a->stats.queries++;
        a->stats.compares += probes;   /* probe-chain strcmps, not armap entries */
        if ( matched ) a->stats.matched++;
        if ( found ) a->stats.hits++;
        return found;
    }

    for ( i = 0; i < a->nindex; i++ )
        if ( strcmp( a->index[i].symname, sym ) == 0 ) break;
    if ( i < a->nindex ) {
        matched = 1;
        found = LcAr_MemberByHdrOff( a, a->index[i].member_off );
    }
    a->stats.queries++;
    a->stats.compares += scanned( i, a->nindex );
    /* `matched` and `hits` are counted separately on purpose: a name can match
    ** an armap entry whose member_off names no member, which resolves to NULL.
    ** Blurring the two would hide a malformed archive behind a plausible tally. */
    if ( matched ) a->stats.matched++;
    if ( found ) a->stats.hits++;
    return found;
}

void LcAr_Close( LcArchive *a ) {
    if ( !a ) return;
    free( a->buf );
    free( a->members );
    free( a->index );
    free( a->sympool );
    free( a->sym_slots );
    free( a->mem_slots );
    memset( a, 0, sizeof( *a ) );
}
