/*
** rsrc_emit.c -- build the PE .rsrc section blob.
**
** Layout (per the Microsoft PE spec):
**   IMAGE_RESOURCE_DIRECTORY (Type)
**     entries[]  -- one per distinct RT_ code
**       -> IMAGE_RESOURCE_DIRECTORY (Name)
**            entries[]  -- one per distinct name/id
**              -> IMAGE_RESOURCE_DIRECTORY (Language)
**                   entries[]  -- one per distinct lang_id
**                     -> IMAGE_RESOURCE_DATA_ENTRY
**                          OffsetToData = rsrc_rva + <offset of raw>
**                          Size, CodePage=0, Reserved=0
**   -- then a run of IMAGE_RESOURCE_DATA_ENTRY records --
**   -- then the raw payloads, each aligned to 4 bytes --
**
** Every id (type / name / lang) is stored as an integer here; the top bit of
** the entry's Name field is CLEAR, indicating an integer id (not a Unicode
** string offset). VS_VERSION_INFO and RT_MANIFEST always use integer ids so
** the string-name path is unused; keeping it out saves a fair bit of code.
*/
#include "link/rsrc_emit.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Small growable buffer identical in shape to pe_emit.c's Buf. */
typedef struct { uint8_t *p; size_t len, cap; } RBuf;

static int rb_need( RBuf *b, size_t n ) {
    if ( b->len + n > b->cap ) {
        size_t nc = b->cap ? b->cap : 256;
        uint8_t *np;
        while ( nc < b->len + n ) nc *= 2;
        np = ( uint8_t * )realloc( b->p, nc );
        if ( !np ) return 0;
        b->p = np; b->cap = nc;
    }
    return 1;
}
static int rb_putn( RBuf *b, const void *s, size_t n ) {
    if ( !n ) return 1;
    if ( !rb_need( b, n ) ) return 0;
    memcpy( b->p + b->len, s, n ); b->len += n; return 1;
}
static int rb_zero( RBuf *b, size_t n ) {
    if ( !rb_need( b, n ) ) return 0;
    memset( b->p + b->len, 0, n ); b->len += n; return 1;
}
static int rb_pad4( RBuf *b ) {
    while ( b->len & 3 ) if ( !rb_zero( b, 1 ) ) return 0;
    return 1;
}
static void rw16( uint8_t *p, uint16_t v ) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void rw32( uint8_t *p, uint32_t v ) {
    p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24);
}

static int rerr( char *err, size_t errlen, const char *msg ) {
    if ( err && errlen ) snprintf( err, errlen, "%s", msg );
    return 0;
}

/* Sort helpers: within a resource directory, entries with numeric ids must be
** sorted ascending by id. We don't emit named entries, so a single ascending
** integer sort covers all three levels. */
typedef struct { uint16_t key; int idx; } SortKey;
static int cmp_sortkey( const void *a, const void *b ) {
    uint16_t ka = ( ( const SortKey * )a )->key;
    uint16_t kb = ( ( const SortKey * )b )->key;
    if ( ka < kb ) return -1;
    if ( ka > kb ) return 1;
    return 0;
}

/* Two-pass build: pass 1 counts nodes so we can pre-size the directory area
** and know where the data entries and raw payloads land; pass 2 fills the
** bytes with correct forward offsets. */
int LcRsrc_Build( const LcRsrcEntry *entries, size_t nentries,
                  uint32_t rsrc_rva,
                  uint8_t **out_bytes, size_t *out_len,
                  char *err, size_t errlen ) {
    /* Group entries into type -> name -> lang. Simple O(n^2) group loops are
    ** fine: real inputs have <= a few dozen resources. */
    if ( out_bytes ) *out_bytes = NULL;
    if ( out_len   ) *out_len = 0;
    if ( nentries == 0 ) return rerr( err, errlen, "rsrc: no entries" );

    /* Collect distinct types */
    uint16_t types[ 32 ];
    size_t   ntypes = 0;
    for ( size_t i = 0; i < nentries; i++ ) {
        int found = 0;
        for ( size_t t = 0; t < ntypes; t++ ) if ( types[t] == entries[i].type_id ) { found = 1; break; }
        if ( !found ) {
            if ( ntypes >= sizeof( types ) / sizeof( types[0] ) )
                return rerr( err, errlen, "rsrc: too many resource types" );
            types[ ntypes++ ] = entries[i].type_id;
        }
    }
    /* sort ascending */
    {
        SortKey k[ 32 ];
        for ( size_t i = 0; i < ntypes; i++ ) { k[i].key = types[i]; k[i].idx = 0; }
        qsort( k, ntypes, sizeof( k[0] ), cmp_sortkey );
        for ( size_t i = 0; i < ntypes; i++ ) types[i] = k[i].key;
    }

    /* Count directory nodes and data entries. One Name directory per (type)
    ** and one Language directory per (type,name). */
    size_t total_name_dirs = 0;   /* one Name directory per distinct type */
    size_t total_lang_dirs = 0;   /* one Language directory per (type,name) */
    size_t total_data      = nentries;   /* one data entry per input row */

    /* For each type, distinct names */
    for ( size_t t = 0; t < ntypes; t++ ) {
        total_name_dirs++;
        uint16_t names[ 64 ];
        size_t   nn = 0;
        for ( size_t i = 0; i < nentries; i++ ) {
            if ( entries[i].type_id != types[t] ) continue;
            int fnd = 0;
            for ( size_t j = 0; j < nn; j++ ) if ( names[j] == entries[i].name_id ) { fnd = 1; break; }
            if ( !fnd ) {
                if ( nn >= sizeof( names ) / sizeof( names[0] ) )
                    return rerr( err, errlen, "rsrc: too many names per type" );
                names[ nn++ ] = entries[i].name_id;
            }
        }
        total_lang_dirs += nn;
    }

    /* Directory sizes:
    **   IMAGE_RESOURCE_DIRECTORY   = 16 bytes header
    **   IMAGE_RESOURCE_DIRECTORY_ENTRY = 8 bytes
    **   IMAGE_RESOURCE_DATA_ENTRY  = 16 bytes
    **
    ** The single top-level (Type) directory has `ntypes` entries.
    ** Each Name directory has as many entries as distinct names of that type.
    ** Each Language directory has as many entries as (type,name) rows.
    ** We compute the total by walking again. */
    size_t entries_type = ntypes;
    size_t entries_name = 0;
    size_t entries_lang = nentries; /* one per input row */
    for ( size_t t = 0; t < ntypes; t++ ) {
        uint16_t names[ 64 ]; size_t nn = 0;
        for ( size_t i = 0; i < nentries; i++ ) {
            if ( entries[i].type_id != types[t] ) continue;
            int fnd = 0;
            for ( size_t j = 0; j < nn; j++ ) if ( names[j] == entries[i].name_id ) { fnd = 1; break; }
            if ( !fnd ) names[ nn++ ] = entries[i].name_id;
        }
        entries_name += nn;
    }

    size_t dir_area = 16 * ( 1 + total_name_dirs + total_lang_dirs )
                    + 8  * ( entries_type + entries_name + entries_lang );
    size_t data_area = 16 * total_data;

    /* Payload area starts here; pad each payload up to 4 bytes. */
    size_t payload_off = dir_area + data_area;
    /* Precompute per-input-row raw offset (in the section) */
    uint32_t *raw_off = ( uint32_t * )calloc( nentries, sizeof( uint32_t ) );
    if ( raw_off == NULL ) return rerr( err, errlen, "rsrc: oom" );
    size_t cur = payload_off;
    for ( size_t i = 0; i < nentries; i++ ) {
        while ( cur & 3 ) cur++;
        raw_off[i] = ( uint32_t )cur;
        cur += entries[i].size;
    }
    size_t total_size = cur;

    RBuf buf; memset( &buf, 0, sizeof buf );
    if ( !rb_zero( &buf, total_size ) ) { free( raw_off ); return rerr( err, errlen, "rsrc: oom" ); }

    /* Layout offsets within the flat buffer:
    **   top-level dir at 0 (16 bytes) + ntypes*8 entry array
    **   then name dirs (one per type) each 16 + Nnames*8
    **   then lang dirs (one per (type,name)) each 16 + Nlangs*8
    **   then data entries: 16 bytes each, one per input row
    ** We build a per-row `data_entry_off[i]` and a per-(type,name) `lang_dir_off`. */
    size_t off_top = 0;
    size_t off_type_entries = off_top + 16;                         /* first entry array */
    size_t off_first_name_dir = off_type_entries + 8 * entries_type;

    /* Compute where each type's Name directory starts. */
    size_t *name_dir_off = ( size_t * )calloc( ntypes, sizeof( size_t ) );
    /* For each (type,name), starting offset of its Language directory. */
    typedef struct { uint16_t type_id; uint16_t name_id; size_t lang_dir_off; size_t nlangs; } TNRec;
    TNRec *tn = ( TNRec * )calloc( entries_name, sizeof( TNRec ) );
    if ( !name_dir_off || !tn ) {
        free( name_dir_off ); free( tn ); free( raw_off ); free( buf.p );
        return rerr( err, errlen, "rsrc: oom" );
    }

    size_t running = off_first_name_dir;
    size_t tn_pos = 0;
    for ( size_t t = 0; t < ntypes; t++ ) {
        name_dir_off[t] = running;
        /* count distinct names for this type */
        uint16_t names[ 64 ]; size_t nn = 0;
        for ( size_t i = 0; i < nentries; i++ ) {
            if ( entries[i].type_id != types[t] ) continue;
            int fnd = 0;
            for ( size_t j = 0; j < nn; j++ ) if ( names[j] == entries[i].name_id ) { fnd = 1; break; }
            if ( !fnd ) names[ nn++ ] = entries[i].name_id;
        }
        /* sort ascending */
        {
            SortKey k[ 64 ];
            for ( size_t i = 0; i < nn; i++ ) { k[i].key = names[i]; k[i].idx = 0; }
            qsort( k, nn, sizeof( k[0] ), cmp_sortkey );
            for ( size_t i = 0; i < nn; i++ ) names[i] = k[i].key;
        }
        running += 16 + 8 * nn;
        /* record TN entries in the sorted-name order */
        for ( size_t i = 0; i < nn; i++ ) {
            tn[ tn_pos ].type_id = types[t];
            tn[ tn_pos ].name_id = names[i];
            tn[ tn_pos ].lang_dir_off = 0; /* filled below */
            tn[ tn_pos ].nlangs = 0;
            tn_pos++;
        }
    }
    /* Now that name dirs are placed, place language dirs */
    for ( size_t k = 0; k < entries_name; k++ ) {
        tn[k].lang_dir_off = running;
        /* count langs for (type,name) */
        size_t nl = 0;
        for ( size_t i = 0; i < nentries; i++ ) {
            if ( entries[i].type_id == tn[k].type_id && entries[i].name_id == tn[k].name_id ) nl++;
        }
        tn[k].nlangs = nl;
        running += 16 + 8 * nl;
    }
    /* Data entries follow; per row */
    size_t off_data_entries = running;
    /* row_data_off[i] gives the byte offset of the i-th input row's
    ** IMAGE_RESOURCE_DATA_ENTRY within the flat blob. */
    size_t *row_data_off = ( size_t * )calloc( nentries, sizeof( size_t ) );
    if ( !row_data_off ) {
        free( name_dir_off ); free( tn ); free( raw_off ); free( buf.p );
        return rerr( err, errlen, "rsrc: oom" );
    }
    /* Assign in flat order matching how we visit them below (per tn group, per
    ** language ascending). */
    size_t drow = 0;
    for ( size_t k = 0; k < entries_name; k++ ) {
        /* gather + sort langs for this (type,name) */
        uint16_t langs[ 32 ]; int rowidx[ 32 ]; size_t nl = 0;
        for ( size_t i = 0; i < nentries; i++ ) {
            if ( entries[i].type_id == tn[k].type_id && entries[i].name_id == tn[k].name_id ) {
                if ( nl >= sizeof( langs ) / sizeof( langs[0] ) ) {
                    free( row_data_off ); free( name_dir_off ); free( tn );
                    free( raw_off ); free( buf.p );
                    return rerr( err, errlen, "rsrc: too many langs per (type,name)" );
                }
                langs[ nl ] = entries[i].lang_id;
                rowidx[ nl ] = ( int )i;
                nl++;
            }
        }
        /* sort by lang_id */
        for ( size_t a = 1; a < nl; a++ ) {
            uint16_t lk = langs[a]; int rk = rowidx[a]; size_t b = a;
            while ( b > 0 && langs[b-1] > lk ) { langs[b] = langs[b-1]; rowidx[b] = rowidx[b-1]; b--; }
            langs[b] = lk; rowidx[b] = rk;
        }
        for ( size_t i = 0; i < nl; i++ ) {
            row_data_off[ rowidx[i] ] = off_data_entries + drow * 16;
            drow++;
        }
    }

    /* --- pass 2: write --- */
    /* top-level (Type) directory */
    {
        uint8_t *p = buf.p + off_top;
        rw32( p + 0, 0 );                    /* Characteristics */
        rw32( p + 4, 0 );                    /* TimeDateStamp   */
        rw16( p + 8, 0 ); rw16( p + 10, 0 ); /* Major/Minor version */
        rw16( p + 12, 0 );                   /* NumberOfNamedEntries */
        rw16( p + 14, ( uint16_t )ntypes );  /* NumberOfIdEntries    */
        for ( size_t t = 0; t < ntypes; t++ ) {
            uint8_t *e = buf.p + off_type_entries + t * 8;
            rw32( e + 0, ( uint32_t )types[t] );
            /* subdir bit (0x80000000) set: OffsetToDirectory */
            rw32( e + 4, 0x80000000u | ( uint32_t )name_dir_off[t] );
        }
    }
    /* Name directories */
    {
        size_t tn_i = 0;
        for ( size_t t = 0; t < ntypes; t++ ) {
            uint16_t names[ 64 ]; size_t nn = 0;
            for ( size_t i = 0; i < nentries; i++ ) {
                if ( entries[i].type_id != types[t] ) continue;
                int fnd = 0;
                for ( size_t j = 0; j < nn; j++ ) if ( names[j] == entries[i].name_id ) { fnd = 1; break; }
                if ( !fnd ) names[ nn++ ] = entries[i].name_id;
            }
            /* sort ascending */
            {
                SortKey k[ 64 ];
                for ( size_t i = 0; i < nn; i++ ) { k[i].key = names[i]; k[i].idx = 0; }
                qsort( k, nn, sizeof( k[0] ), cmp_sortkey );
                for ( size_t i = 0; i < nn; i++ ) names[i] = k[i].key;
            }

            uint8_t *p = buf.p + name_dir_off[t];
            rw32( p + 0, 0 ); rw32( p + 4, 0 );
            rw16( p + 8, 0 ); rw16( p + 10, 0 );
            rw16( p + 12, 0 );
            rw16( p + 14, ( uint16_t )nn );
            for ( size_t i = 0; i < nn; i++ ) {
                uint8_t *e = p + 16 + i * 8;
                /* tn[] was populated in this exact (type,name) order above */
                rw32( e + 0, ( uint32_t )names[i] );
                rw32( e + 4, 0x80000000u | ( uint32_t )tn[ tn_i ].lang_dir_off );
                tn_i++;
            }
        }
    }
    /* Language directories */
    {
        for ( size_t k = 0; k < entries_name; k++ ) {
            uint16_t langs[ 32 ]; int rowidx[ 32 ]; size_t nl = 0;
            for ( size_t i = 0; i < nentries; i++ ) {
                if ( entries[i].type_id == tn[k].type_id && entries[i].name_id == tn[k].name_id ) {
                    langs[ nl ] = entries[i].lang_id;
                    rowidx[ nl ] = ( int )i;
                    nl++;
                }
            }
            /* sort by lang_id ascending */
            for ( size_t a = 1; a < nl; a++ ) {
                uint16_t lk = langs[a]; int rk = rowidx[a]; size_t b = a;
                while ( b > 0 && langs[b-1] > lk ) { langs[b] = langs[b-1]; rowidx[b] = rowidx[b-1]; b--; }
                langs[b] = lk; rowidx[b] = rk;
            }
            uint8_t *p = buf.p + tn[k].lang_dir_off;
            rw32( p + 0, 0 ); rw32( p + 4, 0 );
            rw16( p + 8, 0 ); rw16( p + 10, 0 );
            rw16( p + 12, 0 );
            rw16( p + 14, ( uint16_t )nl );
            for ( size_t i = 0; i < nl; i++ ) {
                uint8_t *e = p + 16 + i * 8;
                rw32( e + 0, ( uint32_t )langs[i] );
                /* leaf bit CLEAR: OffsetToData points at IMAGE_RESOURCE_DATA_ENTRY */
                rw32( e + 4, ( uint32_t )row_data_off[ rowidx[i] ] );
            }
        }
    }
    /* Data entries + payload */
    for ( size_t i = 0; i < nentries; i++ ) {
        uint8_t *d = buf.p + row_data_off[i];
        /* OffsetToData is an RVA (relative to image base), which for the
        ** loader means "start of the raw within the loaded image". We were
        ** given rsrc_rva; the raw sits at raw_off[i] inside the section. */
        rw32( d + 0, rsrc_rva + raw_off[i] );
        rw32( d + 4, entries[i].size );
        rw32( d + 8, 0 );  /* CodePage: 0 = default */
        rw32( d + 12, 0 ); /* Reserved */
        /* copy the raw payload */
        memcpy( buf.p + raw_off[i], entries[i].data, entries[i].size );
    }

    free( name_dir_off ); free( tn ); free( raw_off ); free( row_data_off );

    *out_bytes = buf.p;
    *out_len = buf.len;
    return 1;
}
