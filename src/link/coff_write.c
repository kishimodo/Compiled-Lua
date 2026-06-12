/* coff_write.c -- LuaC COFF object writer (Task 12).
 *
 * Turns an LcCodeModule (the output of lc_codegen) into a single linkable x64
 * COFF .o. Generalizes the hand-built spike in tests/unit/test_lc_coff_spike.c
 * from one function / one reloc to N functions / M relocations sharing one
 * symbol table + string table.
 *
 * On-disk layout (all little-endian raw bytes; sizes are the on-disk record
 * sizes, NOT sizeof an IMAGE_* struct, which would be padded):
 *
 *   [0x00] IMAGE_FILE_HEADER (20 bytes)
 *   [0x14] section header(s) (40 bytes each): .text, optional .rdata
 *   .text raw  = concatenation of every funcs[i].code (tight, see TODO on align)
 *   .rdata raw = cm->rodata (only if rodata_len > 0)
 *   .text relocations (10 bytes each)
 *   symbol table (18 bytes each)
 *   string table (4-byte length prefix incl. itself + NUL-terminated long names)
 *
 * Symbol table order:
 *   [0..nfuncs)            defined function symbols (.text, section #1, EXTERNAL,
 *                          Type=0x20 function, Value = its .text offset)
 *   [__lc_rodata]         (only if rodata) a STATIC symbol at .rdata offset 0
 *   [undefined externals] one per distinct reloc target name not already defined
 *
 * Relocation SymbolTableIndex resolves through a name->index map, so a call from
 * one generated function to another (luac_fn_i -> luac_fn_j) binds to the DEFINED
 * function symbol in this same table (a local/intra-module reloc), while Rt_*
 * targets become undefined externals resolved by ld against the runtime archive.
 */
#include "link/coff_write.h"
#include "codegen/lc_codebuf.h"
#include "runtime/protoblob_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- COFF constants (mirror winnt.h; spelled out so this is self-contained) ---- */
#define LC_IMAGE_FILE_MACHINE_AMD64       0x8664
#define LC_IMAGE_SCN_CNT_CODE             0x00000020u
#define LC_IMAGE_SCN_CNT_INITIALIZED_DATA 0x00000040u
#define LC_IMAGE_SCN_ALIGN_16BYTES        0x00500000u
#define LC_IMAGE_SCN_MEM_EXECUTE          0x20000000u
#define LC_IMAGE_SCN_MEM_READ             0x40000000u
#define LC_IMAGE_SYM_CLASS_EXTERNAL       0x0002
#define LC_IMAGE_SYM_CLASS_STATIC         0x0003
#define LC_IMAGE_SYM_TYPE_FUNC            0x0020 /* DTYPE FUNCTION << 4 */
#define LC_IMAGE_REL_AMD64_ADDR64         0x0001
#define LC_IMAGE_REL_AMD64_REL32          0x0004

/* on-disk record sizes (NOT sizeof an IMAGE_* struct) */
#define LC_SZ_FILE_HEADER     20
#define LC_SZ_SECTION_HEADER  40
#define LC_SZ_SYMBOL          18
#define LC_SZ_RELOCATION      10

/* ---- little-endian writers into a growing byte buffer ---- */
typedef struct { unsigned char *p; size_t len, cap; } Buf;

static int buf_need( Buf *b, size_t n ) {
    if ( b->len + n > b->cap ) {
        size_t nc = b->cap ? b->cap * 2 : 256;
        unsigned char *np;
        while ( nc < b->len + n ) nc *= 2;
        np = ( unsigned char * )realloc( b->p, nc );
        if ( !np ) return 0;
        b->p = np;
        b->cap = nc;
    }
    return 1;
}
static int put8 ( Buf *b, unsigned v ) { if ( !buf_need( b, 1 ) ) return 0; b->p[b->len++] = ( unsigned char )( v & 0xFF ); return 1; }
static int put16( Buf *b, unsigned v ) { return put8( b, v ) && put8( b, v >> 8 ); }
static int put32( Buf *b, unsigned v ) { return put16( b, v ) && put16( b, v >> 16 ); }
static int putn ( Buf *b, const void *src, size_t n ) { if ( !buf_need( b, n ) ) return 0; memcpy( b->p + b->len, src, n ); b->len += n; return 1; }

/* ---- a symbol about to be written into the table ---- */
typedef struct {
    const char *name;       /* points into a funcs[i].name / reloc.symbol / literal */
    unsigned    value;      /* Value field (text offset for funcs, 0 otherwise)     */
    int         section;    /* SectionNumber: 1=.text, rdata sect, 0=undefined      */
    unsigned    type;       /* 0x20 for functions, else 0                           */
    unsigned    storage;    /* EXTERNAL / STATIC                                    */
    unsigned    str_off;    /* string-table offset if name > 8, else 0              */
} CoffSym;

static int fail( char *err, size_t errlen, const char *msg ) {
    if ( err && errlen ) { snprintf( err, errlen, "%s", msg ); }
    return 0;
}

int LcCoff_Write( const char *path, const LcCodeModule *cm, char *err, size_t errlen ) {
    unsigned i, s;
    size_t   r;
    int      rc = 0;
    FILE    *f;

    CoffSym *syms = NULL;
    unsigned nsyms = 0, capsyms = 0;
    unsigned *text_off = NULL;     /* text offset of each function */
    Buf text, reloc, strtab, obj, lcpb_reloc;
    unsigned have_rdata, have_lcpb, num_sections, rdata_section_no, lcpb_section_no;
    unsigned ptr_text, ptr_rdata, ptr_lcpb, ptr_reloc, ptr_lcpb_reloc, ptr_symtab;
    unsigned num_relocs = 0;
    unsigned lcpb_fn_table_len = 0, lcpb_raw_len = 0;

    memset( &text,       0, sizeof text );
    memset( &reloc,      0, sizeof reloc );
    memset( &strtab,     0, sizeof strtab );
    memset( &obj,        0, sizeof obj );
    memset( &lcpb_reloc, 0, sizeof lcpb_reloc );

    if ( !cm ) return fail( err, errlen, "null code module" );

    have_rdata       = ( cm->rodata && cm->rodata_len > 0 ) ? 1u : 0u;
    rdata_section_no = have_rdata ? 2u : 0u;
    /* .rdata$L (the ProtoInit blob section): luac_fn_table — nfuncs ADDR64-
    ** relocated native body pointers — followed by the luac_protoblob bytes.
    ** Grouped into .rdata by the linker (PE COFF $-section semantics). */
    have_lcpb        = ( cm->protoblob && cm->protoblob_len > 0 ) ? 1u : 0u;
    lcpb_section_no  = have_lcpb ? 2u + have_rdata : 0u;
    num_sections     = 1u + have_rdata + have_lcpb;
    if ( have_lcpb ) {
        if ( cm->nfuncs > 0xFFFFu )
            return fail( err, errlen, "too many functions for the fn-table reloc count" );
        lcpb_fn_table_len = cm->nfuncs * 8u;
        lcpb_raw_len      = lcpb_fn_table_len + ( unsigned )cm->protoblob_len;
    }

    /* ---------------------------------------------------------------- */
    /* Pass 1: build the symbol table + .text raw, and add a name->index */
    /* map (linear scan; symbol counts are small for M0).                */
    /* ---------------------------------------------------------------- */

    text_off = ( unsigned * )calloc( cm->nfuncs ? cm->nfuncs : 1, sizeof( unsigned ) );
    if ( !text_off ) { fail( err, errlen, "oom" ); goto done; }

    /* defined function symbols + concatenated .text */
    for ( i = 0; i < cm->nfuncs; i++ ) {
        const LcCompiledFunc *fn = &cm->funcs[i];
        text_off[i] = ( unsigned )text.len;
        if ( fn->code_len && !putn( &text, fn->code, fn->code_len ) ) { fail( err, errlen, "oom" ); goto done; }

        if ( nsyms >= capsyms ) {
            unsigned nc = capsyms ? capsyms * 2 : 16;
            CoffSym *ns = ( CoffSym * )realloc( syms, nc * sizeof( CoffSym ) );
            if ( !ns ) { fail( err, errlen, "oom" ); goto done; }
            syms = ns; capsyms = nc;
        }
        syms[nsyms].name    = fn->name;
        syms[nsyms].value   = text_off[i];
        syms[nsyms].section = 1;                       /* .text */
        syms[nsyms].type    = LC_IMAGE_SYM_TYPE_FUNC;  /* 0x20  */
        syms[nsyms].storage = LC_IMAGE_SYM_CLASS_EXTERNAL;
        syms[nsyms].str_off = 0;
        nsyms++;
    }

    /* a single STATIC symbol covering .rdata (target of LC_RELOC_REL32_RDATA) */
    if ( have_rdata ) {
        if ( nsyms >= capsyms ) {
            unsigned nc = capsyms ? capsyms * 2 : 16;
            CoffSym *ns = ( CoffSym * )realloc( syms, nc * sizeof( CoffSym ) );
            if ( !ns ) { fail( err, errlen, "oom" ); goto done; }
            syms = ns; capsyms = nc;
        }
        syms[nsyms].name    = "__lc_rodata";
        syms[nsyms].value   = 0;                       /* .rdata offset 0 */
        syms[nsyms].section = ( int )rdata_section_no;
        syms[nsyms].type    = 0;
        syms[nsyms].storage = LC_IMAGE_SYM_CLASS_STATIC;
        syms[nsyms].str_off = 0;
        nsyms++;
    }

    /* luac_fn_table + luac_protoblob: the runtime deserializer's two anchors
    ** into the .rdata$L section (EXTERNAL — referenced by protoinit_rt.o in
    ** the runtime archive). */
    if ( have_lcpb ) {
        if ( nsyms + 2 > capsyms ) {
            unsigned nc = capsyms ? capsyms * 2 : 16;
            while ( nc < nsyms + 2 ) nc *= 2;
            CoffSym *ns = ( CoffSym * )realloc( syms, nc * sizeof( CoffSym ) );
            if ( !ns ) { fail( err, errlen, "oom" ); goto done; }
            syms = ns; capsyms = nc;
        }
        syms[nsyms].name    = LCPB_SYM_FNTABLE;
        syms[nsyms].value   = 0;                       /* section offset 0   */
        syms[nsyms].section = ( int )lcpb_section_no;
        syms[nsyms].type    = 0;
        syms[nsyms].storage = LC_IMAGE_SYM_CLASS_EXTERNAL;
        syms[nsyms].str_off = 0;
        nsyms++;
        syms[nsyms].name    = LCPB_SYM_BLOB;
        syms[nsyms].value   = lcpb_fn_table_len;       /* right after the table */
        syms[nsyms].section = ( int )lcpb_section_no;
        syms[nsyms].type    = 0;
        syms[nsyms].storage = LC_IMAGE_SYM_CLASS_EXTERNAL;
        syms[nsyms].str_off = 0;
        nsyms++;
    }

    /* undefined externals: one per distinct reloc target not already a symbol */
    for ( i = 0; i < cm->nfuncs; i++ ) {
        const LcCompiledFunc *fn = &cm->funcs[i];
        for ( r = 0; r < fn->nrelocs; r++ ) {
            const LcReloc *rl = &fn->relocs[r];
            unsigned k;
            int found = 0;
            if ( rl->kind == LC_RELOC_REL32_RDATA ) continue; /* targets __lc_rodata */
            for ( k = 0; k < nsyms; k++ ) {
                if ( strcmp( syms[k].name, rl->symbol ) == 0 ) { found = 1; break; }
            }
            if ( found ) continue;
            if ( nsyms >= capsyms ) {
                unsigned nc = capsyms ? capsyms * 2 : 16;
                CoffSym *ns = ( CoffSym * )realloc( syms, nc * sizeof( CoffSym ) );
                if ( !ns ) { fail( err, errlen, "oom" ); goto done; }
                syms = ns; capsyms = nc;
            }
            syms[nsyms].name    = rl->symbol;
            syms[nsyms].value   = 0;
            syms[nsyms].section = 0;   /* undefined */
            syms[nsyms].type    = 0;
            syms[nsyms].storage = LC_IMAGE_SYM_CLASS_EXTERNAL;
            syms[nsyms].str_off = 0;
            nsyms++;
        }
    }

    /* ---------------------------------------------------------------- */
    /* Pass 2: emit the .text relocation records (point them at the      */
    /* matching symbol-table index).                                     */
    /* ---------------------------------------------------------------- */
    for ( i = 0; i < cm->nfuncs; i++ ) {
        const LcCompiledFunc *fn = &cm->funcs[i];
        for ( r = 0; r < fn->nrelocs; r++ ) {
            const LcReloc *rl = &fn->relocs[r];
            unsigned k, idx = 0;
            unsigned type;
            const char *want;

            if ( rl->kind == LC_RELOC_REL32_RDATA ) {
                if ( !have_rdata ) { fail( err, errlen, "rdata reloc but no rdata section" ); goto done; }
                want = "__lc_rodata";
                type = LC_IMAGE_REL_AMD64_REL32;
            } else {
                want = rl->symbol;
                type = ( rl->kind == LC_RELOC_ADDR64 ) ? LC_IMAGE_REL_AMD64_ADDR64
                                                       : LC_IMAGE_REL_AMD64_REL32;
            }
            for ( k = 0; k < nsyms; k++ ) {
                if ( strcmp( syms[k].name, want ) == 0 ) { idx = k; break; }
            }
            if ( k == nsyms ) { fail( err, errlen, "reloc symbol not in table" ); goto done; }

            if ( !put32( &reloc, text_off[i] + rl->offset ) ||  /* VirtualAddress    */
                 !put32( &reloc, idx ) ||                       /* SymbolTableIndex  */
                 !put16( &reloc, type ) )                       /* Type              */
            { fail( err, errlen, "oom" ); goto done; }
            num_relocs++;
        }
    }
    if ( num_relocs > 0xFFFFu )
        { fail( err, errlen, "too many relocations (>0xFFFF; overflow form unsupported in M0)" ); goto done; }

    /* .rdata$L relocations: ADDR64 at table slot i*8 -> defined function
    ** symbol i (function symbols occupy table indices [0, nfuncs)). */
    if ( have_lcpb ) {
        for ( i = 0; i < cm->nfuncs; i++ ) {
            if ( !put32( &lcpb_reloc, i * 8u ) ||   /* VirtualAddress   */
                 !put32( &lcpb_reloc, i ) ||        /* SymbolTableIndex */
                 !put16( &lcpb_reloc, LC_IMAGE_REL_AMD64_ADDR64 ) )
            { fail( err, errlen, "oom" ); goto done; }
        }
    }

    /* ---------------------------------------------------------------- */
    /* String table: collect names > 8 chars. Starts with a 4-byte total */
    /* length prefix (includes itself), so the first string is at off 4. */
    /* ---------------------------------------------------------------- */
    if ( !put32( &strtab, 0 ) ) { fail( err, errlen, "oom" ); goto done; } /* length placeholder */
    for ( i = 0; i < nsyms; i++ ) {
        if ( strlen( syms[i].name ) > 8 ) {
            syms[i].str_off = ( unsigned )strtab.len;
            if ( !putn( &strtab, syms[i].name, strlen( syms[i].name ) + 1 ) ) { fail( err, errlen, "oom" ); goto done; }
        }
    }
    { unsigned tl = ( unsigned )strtab.len;
      strtab.p[0] = ( unsigned char )( tl );        strtab.p[1] = ( unsigned char )( tl >> 8 );
      strtab.p[2] = ( unsigned char )( tl >> 16 );  strtab.p[3] = ( unsigned char )( tl >> 24 ); }

    /* ---------------------------------------------------------------- */
    /* File offsets.                                                     */
    /* ---------------------------------------------------------------- */
    ptr_text  = LC_SZ_FILE_HEADER + num_sections * LC_SZ_SECTION_HEADER;
    ptr_rdata = ptr_text + ( unsigned )text.len;
    ptr_lcpb  = ptr_rdata + ( have_rdata ? ( unsigned )cm->rodata_len : 0u );
    ptr_reloc = ptr_lcpb + lcpb_raw_len;
    ptr_lcpb_reloc = ptr_reloc + num_relocs * LC_SZ_RELOCATION;
    ptr_symtab = ptr_lcpb_reloc + ( have_lcpb ? cm->nfuncs * LC_SZ_RELOCATION : 0u );
    /* string table follows the symbol table */

    /* ---------------------------------------------------------------- */
    /* Assemble the object.                                              */
    /* ---------------------------------------------------------------- */

    /* IMAGE_FILE_HEADER */
    if ( !put16( &obj, LC_IMAGE_FILE_MACHINE_AMD64 ) ||  /* Machine             */
         !put16( &obj, num_sections ) ||                 /* NumberOfSections    */
         !put32( &obj, 0 ) ||                            /* TimeDateStamp       */
         !put32( &obj, ptr_symtab ) ||                   /* PointerToSymbolTable*/
         !put32( &obj, nsyms ) ||                        /* NumberOfSymbols     */
         !put16( &obj, 0 ) ||                            /* SizeOfOptionalHeader*/
         !put16( &obj, 0 ) )                             /* Characteristics     */
    { fail( err, errlen, "oom" ); goto done; }

    /* .text IMAGE_SECTION_HEADER */
    { char nm[8] = { '.','t','e','x','t', 0,0,0 }; if ( !putn( &obj, nm, 8 ) ) { fail( err, errlen, "oom" ); goto done; } }
    if ( !put32( &obj, 0 ) ||                         /* VirtualSize          */
         !put32( &obj, 0 ) ||                         /* VirtualAddress       */
         !put32( &obj, ( unsigned )text.len ) ||      /* SizeOfRawData        */
         !put32( &obj, ptr_text ) ||                  /* PointerToRawData     */
         !put32( &obj, num_relocs ? ptr_reloc : 0 ) ||/* PointerToRelocations */
         !put32( &obj, 0 ) ||                          /* PointerToLinenumbers */
         !put16( &obj, num_relocs ) ||                 /* NumberOfRelocations  */
         !put16( &obj, 0 ) ||                          /* NumberOfLinenumbers  */
         !put32( &obj, LC_IMAGE_SCN_CNT_CODE | LC_IMAGE_SCN_MEM_EXECUTE |
                       LC_IMAGE_SCN_MEM_READ | LC_IMAGE_SCN_ALIGN_16BYTES ) )
    { fail( err, errlen, "oom" ); goto done; }

    /* .rdata IMAGE_SECTION_HEADER (optional) */
    if ( have_rdata ) {
        char nm[8] = { '.','r','d','a','t','a', 0,0 };
        if ( !putn( &obj, nm, 8 ) ||
             !put32( &obj, 0 ) ||                        /* VirtualSize          */
             !put32( &obj, 0 ) ||                        /* VirtualAddress       */
             !put32( &obj, ( unsigned )cm->rodata_len ) ||/* SizeOfRawData       */
             !put32( &obj, ptr_rdata ) ||                /* PointerToRawData     */
             !put32( &obj, 0 ) ||                        /* PointerToRelocations */
             !put32( &obj, 0 ) ||                        /* PointerToLinenumbers */
             !put16( &obj, 0 ) ||                        /* NumberOfRelocations  */
             !put16( &obj, 0 ) ||                        /* NumberOfLinenumbers  */
             !put32( &obj, LC_IMAGE_SCN_CNT_INITIALIZED_DATA | LC_IMAGE_SCN_MEM_READ |
                           LC_IMAGE_SCN_ALIGN_16BYTES ) )
        { fail( err, errlen, "oom" ); goto done; }
    }

    /* .rdata$L IMAGE_SECTION_HEADER (optional; fn table + ProtoInit blob) */
    if ( have_lcpb ) {
        char nm[8] = { '.','r','d','a','t','a','$','L' };
        if ( !putn( &obj, nm, 8 ) ||
             !put32( &obj, 0 ) ||                        /* VirtualSize          */
             !put32( &obj, 0 ) ||                        /* VirtualAddress       */
             !put32( &obj, lcpb_raw_len ) ||             /* SizeOfRawData        */
             !put32( &obj, ptr_lcpb ) ||                 /* PointerToRawData     */
             !put32( &obj, ptr_lcpb_reloc ) ||           /* PointerToRelocations */
             !put32( &obj, 0 ) ||                        /* PointerToLinenumbers */
             !put16( &obj, cm->nfuncs ) ||               /* NumberOfRelocations  */
             !put16( &obj, 0 ) ||                        /* NumberOfLinenumbers  */
             !put32( &obj, LC_IMAGE_SCN_CNT_INITIALIZED_DATA | LC_IMAGE_SCN_MEM_READ |
                           LC_IMAGE_SCN_ALIGN_16BYTES ) )
        { fail( err, errlen, "oom" ); goto done; }
    }

    /* .text raw bytes */
    if ( text.len && !putn( &obj, text.p, text.len ) ) { fail( err, errlen, "oom" ); goto done; }

    /* .rdata raw bytes */
    if ( have_rdata && !putn( &obj, cm->rodata, cm->rodata_len ) ) { fail( err, errlen, "oom" ); goto done; }

    /* .rdata$L raw bytes: the zero-filled fn table (the linker writes the
    ** addresses via the ADDR64 relocs) followed by the blob. */
    if ( have_lcpb ) {
        for ( i = 0; i < lcpb_fn_table_len; i++ ) {
            if ( !put8( &obj, 0 ) ) { fail( err, errlen, "oom" ); goto done; }
        }
        if ( !putn( &obj, cm->protoblob, cm->protoblob_len ) )
        { fail( err, errlen, "oom" ); goto done; }
    }

    /* .text relocations */
    if ( reloc.len && !putn( &obj, reloc.p, reloc.len ) ) { fail( err, errlen, "oom" ); goto done; }

    /* .rdata$L relocations */
    if ( lcpb_reloc.len && !putn( &obj, lcpb_reloc.p, lcpb_reloc.len ) ) { fail( err, errlen, "oom" ); goto done; }

    /* symbol table */
    for ( s = 0; s < nsyms; s++ ) {
        const CoffSym *sym = &syms[s];
        if ( strlen( sym->name ) > 8 ) {
            if ( !put32( &obj, 0 ) || !put32( &obj, sym->str_off ) ) { fail( err, errlen, "oom" ); goto done; }
        } else {
            char nm[8] = { 0 };
            memcpy( nm, sym->name, strlen( sym->name ) );
            if ( !putn( &obj, nm, 8 ) ) { fail( err, errlen, "oom" ); goto done; }
        }
        if ( !put32( &obj, sym->value ) ||             /* Value             */
             !put16( &obj, ( unsigned )sym->section ) ||/* SectionNumber    */
             !put16( &obj, sym->type ) ||              /* Type              */
             !put8 ( &obj, sym->storage ) ||           /* StorageClass      */
             !put8 ( &obj, 0 ) )                       /* NumberOfAuxSymbols*/
        { fail( err, errlen, "oom" ); goto done; }
    }

    /* string table */
    if ( !putn( &obj, strtab.p, strtab.len ) ) { fail( err, errlen, "oom" ); goto done; }

    /* ---------------------------------------------------------------- */
    /* Flush to disk.                                                    */
    /* ---------------------------------------------------------------- */
    f = fopen( path, "wb" );
    if ( !f ) { fail( err, errlen, "cannot open output file" ); goto done; }
    if ( fwrite( obj.p, 1, obj.len, f ) != obj.len ) { fclose( f ); fail( err, errlen, "short write" ); goto done; }
    if ( fclose( f ) != 0 ) { fail( err, errlen, "close failed" ); goto done; }

    rc = 1; /* success */

done:
    free( text.p );
    free( reloc.p );
    free( lcpb_reloc.p );
    free( strtab.p );
    free( obj.p );
    free( syms );
    free( text_off );
    return rc;
}
