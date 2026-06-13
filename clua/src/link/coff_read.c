/*
** coff_read.c — see coff_read.h. A defensive reader for x86-64 COFF objects.
**
** All multi-byte fields are little-endian on disk; we decode through helpers
** rather than casting structs (struct padding differs from the 18-byte symbol
** record and the 10-byte relocation record). Names:
**   * section name: 8 raw bytes; "/<dec>" => string-table offset.
**   * symbol name: 8 raw bytes; if the first 4 are zero, the next 4 are a
**     string-table offset.
** Decoded names are interned into a growable name pool so callers hold stable
** NUL-terminated pointers.
*/
#include "link/coff_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LC_SZ_FILE_HEADER     20
#define LC_SZ_SECTION_HEADER  40
#define LC_SZ_SYMBOL          18
#define LC_SZ_RELOCATION      10

static int rfail( char *err, size_t errlen, const char *fmt, const char *a ) {
    if ( err && errlen ) snprintf( err, errlen, fmt, a ? a : "" );
    return 0;
}

static uint16_t rd16( const uint8_t *p ) { return ( uint16_t )( p[0] | ( p[1] << 8 ) ); }
static uint32_t rd32( const uint8_t *p ) {
    return ( uint32_t )p[0] | ( ( uint32_t )p[1] << 8 ) |
           ( ( uint32_t )p[2] << 16 ) | ( ( uint32_t )p[3] << 24 );
}

/* ---- name pool: append a name, return its offset ----
** IMPORTANT: the pool is realloc'd as it grows, so callers must store the
** returned OFFSET (not a base+offset pointer) during parsing and convert to a
** stable pointer only after the pool is fully built (fixup pass below). A
** sentinel offset of (size_t)-1 means "no pooled name". */
#define NAME_NONE ( ( size_t )-1 )
static int pool_add( LcCoffObj *o, const char *name, size_t n, size_t *off_out ) {
    size_t need = o->namepool_len + n + 1;
    char  *np;
    np = ( char * )realloc( o->namepool, need );
    if ( !np ) return 0;
    o->namepool = np;
    memcpy( np + o->namepool_len, name, n );
    np[ o->namepool_len + n ] = '\0';
    *off_out = o->namepool_len;
    o->namepool_len = need;
    return 1;
}

/* symbols[] is dense over EVERY raw slot (primary + aux placeholder), so a
** relocation's SymbolTableIndex maps directly to symbols[idx]. Aux slots are
** stamped with section == LC_SLOT_AUX_MARKER. */
#define LC_SLOT_AUX_MARKER  (-3)

const LcCoffSymbol *LcCoff_SymByIndex( const LcCoffObj *o, uint32_t idx ) {
    if ( idx >= o->nsymbols_slots ) return NULL;
    if ( o->symbols[idx].section == LC_SLOT_AUX_MARKER ) return NULL;
    return &o->symbols[idx];
}

int LcCoff_Parse( const uint8_t *buf, size_t len, const char *origin,
                  LcCoffObj *out, char *err, size_t errlen ) {
    const uint8_t *fh;
    uint16_t machine, nsec;
    uint32_t ptr_symtab, nsym_slots;
    uint32_t strtab_off;
    const uint8_t *strtab = NULL;
    uint32_t strtab_len = 0;
    uint32_t i;
    uint32_t s;
    size_t  *sec_name_off = NULL;   /* per-section pooled-name offset / NONE  */
    size_t  *sym_name_off = NULL;   /* per-symbol-slot pooled-name offset     */

    memset( out, 0, sizeof( *out ) );
    if ( origin ) { snprintf( out->origin, sizeof( out->origin ), "%s", origin ); }

    if ( len < LC_SZ_FILE_HEADER )
        return rfail( err, errlen, "COFF too small (%s)", origin );

    /* own a copy so callers can free the source buffer / archive blob */
    out->file = ( uint8_t * )malloc( len );
    if ( !out->file ) return rfail( err, errlen, "oom copying COFF (%s)", origin );
    memcpy( out->file, buf, len );
    out->file_len = len;
    buf = out->file;

    fh = buf;
    machine    = rd16( fh + 0 );
    nsec       = rd16( fh + 2 );
    ptr_symtab = rd32( fh + 8 );
    nsym_slots = rd32( fh + 12 );

    if ( machine != LC_IMAGE_FILE_MACHINE_AMD64 ) {
        LcCoff_Free( out );
        return rfail( err, errlen, "not an AMD64 COFF (%s)", origin );
    }

    /* string table sits right after the symbol table */
    if ( ptr_symtab != 0 && nsym_slots != 0 ) {
        strtab_off = ptr_symtab + nsym_slots * LC_SZ_SYMBOL;
        if ( strtab_off + 4 <= len ) {
            strtab     = buf + strtab_off;
            strtab_len = rd32( strtab );
            if ( ( size_t )strtab_off + strtab_len > len ) strtab_len = ( uint32_t )( len - strtab_off );
        }
    }

    /* ---- sections ---- */
    if ( ( size_t )LC_SZ_FILE_HEADER + ( size_t )nsec * LC_SZ_SECTION_HEADER > len ) {
        LcCoff_Free( out );
        return rfail( err, errlen, "section headers run past EOF (%s)", origin );
    }
    out->nsections = nsec;
    out->sections  = ( LcCoffSection * )calloc( nsec ? nsec : 1, sizeof( LcCoffSection ) );
    sec_name_off   = ( size_t * )malloc( ( nsec ? nsec : 1 ) * sizeof( size_t ) );
    if ( !out->sections || !sec_name_off ) { free( sec_name_off ); LcCoff_Free( out ); return rfail( err, errlen, "oom (%s)", origin ); }
    for ( i = 0; i < nsec; i++ ) sec_name_off[i] = NAME_NONE;

    for ( i = 0; i < nsec; i++ ) {
        const uint8_t *sh = buf + LC_SZ_FILE_HEADER + i * LC_SZ_SECTION_HEADER;
        LcCoffSection *sec = &out->sections[i];
        uint32_t nreloc, ptr_reloc;

        memcpy( sec->name, sh, 8 );
        sec->name[8] = '\0';
        sec->name_long = NULL;
        if ( sec->name[0] == '/' ) {
            /* long section name: "/<decimal offset into string table>" */
            uint32_t off = ( uint32_t )strtol( sec->name + 1, NULL, 10 );
            if ( strtab && off < strtab_len ) {
                size_t poff;
                const char *ln = ( const char * )strtab + off;
                size_t lnlen = strnlen( ln, strtab_len - off );
                if ( pool_add( out, ln, lnlen, &poff ) )
                    sec_name_off[i] = poff;   /* resolve to ptr after pool done */
            }
        }
        sec->virtual_size    = rd32( sh + 8 );
        sec->size_raw        = rd32( sh + 16 );
        sec->ptr_raw         = rd32( sh + 20 );
        ptr_reloc            = rd32( sh + 24 );
        nreloc               = rd16( sh + 32 );
        sec->characteristics = rd32( sh + 36 );

        if ( sec->ptr_raw != 0 && sec->size_raw != 0 ) {
            if ( ( size_t )sec->ptr_raw + sec->size_raw <= len )
                sec->data = buf + sec->ptr_raw;
        }

        /* NRELOC_OVFL: real count lives in the first reloc's VirtualAddress */
        if ( ( sec->characteristics & LC_IMAGE_SCN_LNK_NRELOC_OVFL ) && nreloc == 0xFFFF ) {
            if ( ptr_reloc + LC_SZ_RELOCATION <= len )
                nreloc = rd32( buf + ptr_reloc ); /* includes the sentinel */
        }

        if ( nreloc && ptr_reloc &&
             ( size_t )ptr_reloc + ( size_t )nreloc * LC_SZ_RELOCATION <= len ) {
            uint32_t skip = 0, r;
            /* overflow sentinel occupies reloc[0] when NRELOC_OVFL set */
            if ( ( sec->characteristics & LC_IMAGE_SCN_LNK_NRELOC_OVFL ) &&
                 rd16( sh + 32 ) == 0xFFFF ) {
                skip = 1;
            }
            sec->nrelocs = nreloc - skip;
            sec->relocs  = ( LcCoffReloc * )calloc( sec->nrelocs ? sec->nrelocs : 1,
                                                    sizeof( LcCoffReloc ) );
            if ( !sec->relocs ) { LcCoff_Free( out ); return rfail( err, errlen, "oom (%s)", origin ); }
            for ( r = 0; r < sec->nrelocs; r++ ) {
                const uint8_t *rp = buf + ptr_reloc + ( r + skip ) * LC_SZ_RELOCATION;
                sec->relocs[r].va     = rd32( rp + 0 );
                sec->relocs[r].symidx = rd32( rp + 4 );
                sec->relocs[r].type   = rd16( rp + 8 );
            }
        }
    }

    /* ---- symbols (dense over EVERY raw slot; aux slots get a marker) ---- */
    out->nsymbols_slots = nsym_slots;
    out->symbols = ( LcCoffSymbol * )calloc( nsym_slots ? nsym_slots : 1,
                                             sizeof( LcCoffSymbol ) );
    if ( !out->symbols ) { LcCoff_Free( out ); return rfail( err, errlen, "oom (%s)", origin ); }

    if ( ptr_symtab + ( size_t )nsym_slots * LC_SZ_SYMBOL > len && nsym_slots ) {
        LcCoff_Free( out );
        return rfail( err, errlen, "symbol table past EOF (%s)", origin );
    }

    sym_name_off = ( size_t * )malloc( ( nsym_slots ? nsym_slots : 1 ) * sizeof( size_t ) );
    if ( !sym_name_off ) { free( sec_name_off ); LcCoff_Free( out ); return rfail( err, errlen, "oom (%s)", origin ); }
    for ( s = 0; s < nsym_slots; s++ ) sym_name_off[s] = NAME_NONE;

    for ( s = 0; s < nsym_slots; ) {
        const uint8_t *sp = buf + ptr_symtab + s * LC_SZ_SYMBOL;
        LcCoffSymbol *sym = &out->symbols[s];
        uint8_t naux;
        uint8_t k;
        size_t poff = NAME_NONE;

        /* name (store the pooled OFFSET; pool may realloc, so resolve later) */
        if ( sp[0] == 0 && sp[1] == 0 && sp[2] == 0 && sp[3] == 0 ) {
            uint32_t off = rd32( sp + 4 );
            if ( strtab && off < strtab_len ) {
                const char *ln = ( const char * )strtab + off;
                size_t lnlen = strnlen( ln, strtab_len - off );
                if ( !pool_add( out, ln, lnlen, &poff ) ) { free(sec_name_off); free(sym_name_off); LcCoff_Free( out ); return rfail( err, errlen, "oom (%s)", origin ); }
            } else {
                if ( !pool_add( out, "", 0, &poff ) ) { free(sec_name_off); free(sym_name_off); LcCoff_Free( out ); return rfail( err, errlen, "oom (%s)", origin ); }
            }
        } else {
            char nm[9];
            memcpy( nm, sp, 8 );
            nm[8] = '\0';
            if ( !pool_add( out, nm, strnlen( nm, 8 ), &poff ) ) { free(sec_name_off); free(sym_name_off); LcCoff_Free( out ); return rfail( err, errlen, "oom (%s)", origin ); }
        }
        sym_name_off[s] = poff;

        sym->value   = rd32( sp + 8 );
        sym->section = ( int16_t )rd16( sp + 12 ); /* signed: 0xFFFF == -1 */
        sym->type    = rd16( sp + 14 );
        sym->storage = sp[16];
        naux         = sp[17];
        sym->naux    = naux;
        sym->aux     = naux ? ( sp + LC_SZ_SYMBOL ) : NULL;  /* into stable file copy */

        /* weak external aux: TagIndex (default symbol) + Characteristics */
        if ( sym->storage == LC_IMAGE_SYM_CLASS_WEAK_EXTERNAL && naux >= 1 &&
             s + 1 < nsym_slots ) {
            const uint8_t *ax = sp + LC_SZ_SYMBOL;
            sym->weak_default         = rd32( ax + 0 );
            sym->weak_characteristics = rd32( ax + 4 );
        }

        /* mark the aux slots so SymByIndex / reloc lookups land on primaries */
        for ( k = 1; k <= naux && ( s + k ) < nsym_slots; k++ ) {
            out->symbols[ s + k ].section = LC_SLOT_AUX_MARKER;
            sym_name_off[ s + k ] = NAME_NONE;
        }

        s += ( uint32_t )( 1 + naux );
    }

    /* ---- name fixup: the pool is now final; convert stored offsets to stable
    ** pointers. Empty names point at a shared "" in the pool. ---- */
    for ( i = 0; i < nsec; i++ )
        out->sections[i].name_long = ( sec_name_off[i] != NAME_NONE )
            ? out->namepool + sec_name_off[i] : NULL;
    for ( s = 0; s < nsym_slots; s++ )
        out->symbols[s].name = ( sym_name_off[s] != NAME_NONE )
            ? out->namepool + sym_name_off[s] : "";
    free( sec_name_off ); sec_name_off = NULL;
    free( sym_name_off ); sym_name_off = NULL;

    /* ---- COMDAT: a section flagged LNK_COMDAT is described by its section-
    ** definition symbol's aux (Number/Selection). The defining symbol is the
    ** one whose SectionNumber points at the COMDAT section and whose aux
    ** carries the selection. Find it by scanning for the section symbol. */
    for ( i = 0; i < nsec; i++ ) {
        if ( out->sections[i].characteristics & LC_IMAGE_SCN_LNK_COMDAT )
            out->sections[i].is_comdat = 1;
    }
    for ( s = 0; s < nsym_slots; s++ ) {
        const LcCoffSymbol *sym = &out->symbols[s];
        int32_t secn = sym->section;
        if ( secn == LC_SLOT_AUX_MARKER ) continue;
        if ( secn >= 1 && ( uint32_t )secn <= nsec &&
             out->sections[ secn - 1 ].is_comdat &&
             sym->storage == LC_IMAGE_SYM_CLASS_STATIC &&
             sym->naux >= 1 && sym->aux ) {
            /* section-definition aux: Length(4) NumberOfRelocations(2)
            ** NumberOfLinenumbers(2) CheckSum(4) Number(2) Selection(1) */
            uint8_t selection = sym->aux[14];
            if ( out->sections[ secn - 1 ].comdat_selection == 0 ) {
                out->sections[ secn - 1 ].comdat_selection = selection;
                out->sections[ secn - 1 ].comdat_symidx    = ( int )s;
            }
        }
    }

    return 1;
}

int LcCoff_ParseFile( const char *path, LcCoffObj *out, char *err, size_t errlen ) {
    FILE *f;
    long  sz;
    uint8_t *buf;
    int   rc;

    f = fopen( path, "rb" );
    if ( !f ) return rfail( err, errlen, "cannot open %s", path );
    fseek( f, 0, SEEK_END );
    sz = ftell( f );
    fseek( f, 0, SEEK_SET );
    if ( sz <= 0 ) { fclose( f ); return rfail( err, errlen, "empty %s", path ); }
    buf = ( uint8_t * )malloc( ( size_t )sz );
    if ( !buf ) { fclose( f ); return rfail( err, errlen, "oom reading %s", path ); }
    if ( fread( buf, 1, ( size_t )sz, f ) != ( size_t )sz ) {
        free( buf ); fclose( f ); return rfail( err, errlen, "short read %s", path );
    }
    fclose( f );
    rc = LcCoff_Parse( buf, ( size_t )sz, path, out, err, errlen );
    free( buf );
    return rc;
}

void LcCoff_Free( LcCoffObj *o ) {
    uint32_t i;
    if ( !o ) return;
    if ( o->sections ) {
        for ( i = 0; i < o->nsections; i++ ) free( o->sections[i].relocs );
        free( o->sections );
    }
    free( o->symbols );
    free( o->namepool );
    free( o->file );
    memset( o, 0, sizeof( *o ) );
}
