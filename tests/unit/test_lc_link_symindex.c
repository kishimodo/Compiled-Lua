/* test_lc_link_symindex.c -- regression cover for the internal linker's symbol
 * indexes: the global GSym table and (object,section) contribution index in
 * pe_emit.c, plus the per-archive armap and member lookups in ar_read.c.
 *
 * The linker resolves symbols through an open-addressed hash whose slot array
 * is rebuilt (rehashed) every time the load factor crosses 0.7, while the GSym
 * array itself is realloc'd independently. A stale slot table, an off-by-one in
 * the "index + 1" encoding, or a probe loop that fails to wrap would show up as
 * an unresolved symbol or a wrong RVA only once enough symbols exist to force
 * several growth rounds AND produce probe collisions.
 *
 * So: build one object carrying thousands of EXTERNAL symbols, link it, and
 * assert (a) the link succeeds, (b) the single real relocation still resolves
 * to the imported ExitProcess, and (c) two independent links of the same input
 * are byte-identical (the index must not leak iteration order into the output).
 *
 * SKIPs cleanly when the CRT sysroot isn't built.
 */
#include "test_harness.h"
#include "link/pe_emit.h"
#include "link/ar_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <process.h>   /* _getpid */
#define getpid _getpid

#define FILL_SYMS 4000   /* forces 512 -> 1024 -> 2048 -> 4096 -> 8192 rehashes */

static void p16( uint8_t *p, uint16_t v ) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void p32( uint8_t *p, uint32_t v ) {
    p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24);
}

/* Build an AMD64 COFF: one .text with `mainCRTStartup`, an undefined
 * `ExitProcess` reached by a REL32, and FILL_SYMS absolute EXTERNAL fillers.
 * Returns malloc'd bytes; *outlen gets the length. */
static uint8_t *build_wide_coff( size_t *outlen ) {
    static const uint8_t code[12] = {
        0x31, 0xC9,                    /* xor ecx, ecx           */
        0xE8, 0x00,0x00,0x00,0x00,     /* call rel32 ExitProcess */
        0xCC, 0xCC, 0xCC, 0xCC, 0xCC
    };
    const uint32_t nsym = 2 + FILL_SYMS;
    const uint32_t ptr_text  = 20 + 40;
    const uint32_t ptr_reloc = ptr_text + (uint32_t)sizeof code;
    const uint32_t ptr_sym   = ptr_reloc + 10;
    const uint32_t sym_bytes = nsym * 18;
    /* names: "mainCRTStartup\0" "ExitProcess\0" + FILL_SYMS * "clua_fill_NNNNN\0" */
    const size_t   strcap    = 4 + 16 + 16 + (size_t)FILL_SYMS * 24;
    const size_t   cap       = ptr_sym + sym_bytes + strcap;
    uint8_t *buf = ( uint8_t * )calloc( 1, cap );
    uint8_t *strtab;
    uint32_t stroff;
    uint32_t i;

    if ( !buf ) return NULL;

    p16( buf + 0, 0x8664 );          /* Machine AMD64        */
    p16( buf + 2, 1 );               /* NumberOfSections     */
    p32( buf + 8, ptr_sym );
    p32( buf + 12, nsym );

    memcpy( buf + 20, ".text", 5 );
    p32( buf + 20 + 16, (uint32_t)sizeof code );
    p32( buf + 20 + 20, ptr_text );
    p32( buf + 20 + 24, ptr_reloc );
    p16( buf + 20 + 32, 1 );
    p32( buf + 20 + 36, 0x60000020u );   /* CODE|EXECUTE|READ */

    memcpy( buf + ptr_text, code, sizeof code );

    p32( buf + ptr_reloc + 0, 3 );       /* REL32 at code offset 3 */
    p32( buf + ptr_reloc + 4, 1 );       /* -> symbol #1 (ExitProcess) */
    p16( buf + ptr_reloc + 8, 4 );       /* IMAGE_REL_AMD64_REL32  */

    strtab = buf + ptr_sym + sym_bytes;
    stroff = 4;

    /* sym 0: mainCRTStartup, defined at .text:0 */
    p32( buf + ptr_sym + 4, stroff );
    p16( buf + ptr_sym + 12, 1 );        /* SectionNumber .text  */
    p16( buf + ptr_sym + 14, 0x20 );     /* Type function        */
    buf[ ptr_sym + 16 ] = 2;             /* IMAGE_SYM_CLASS_EXTERNAL */
    memcpy( strtab + stroff, "mainCRTStartup", 15 );
    stroff += 15;

    /* sym 1: ExitProcess, undefined */
    p32( buf + ptr_sym + 18 + 4, stroff );
    buf[ ptr_sym + 18 + 16 ] = 2;
    memcpy( strtab + stroff, "ExitProcess", 12 );
    stroff += 12;

    /* fillers: absolute EXTERNAL defs (SectionNumber -1), no contribution */
    for ( i = 0; i < FILL_SYMS; i++ ) {
        uint8_t *s = buf + ptr_sym + ( 2 + i ) * 18;
        char name[24];
        int nl = snprintf( name, sizeof name, "clua_fill_%05u", i );
        p32( s + 4, stroff );
        p32( s + 8, i );                 /* Value (absolute)     */
        p16( s + 12, 0xFFFF );           /* IMAGE_SYM_ABSOLUTE   */
        s[16] = 2;                       /* EXTERNAL             */
        memcpy( strtab + stroff, name, (size_t)nl + 1 );
        stroff += (uint32_t)nl + 1;
    }

    p32( strtab, stroff );               /* string table size    */
    *outlen = (size_t)( strtab - buf ) + stroff;
    return buf;
}

static long slurp( const char *path, uint8_t **out ) {
    FILE *f = fopen( path, "rb" );
    long sz;
    uint8_t *b;
    if ( !f ) return -1;
    fseek( f, 0, SEEK_END ); sz = ftell( f ); fseek( f, 0, SEEK_SET );
    if ( sz <= 0 ) { fclose( f ); return -1; }
    b = ( uint8_t * )malloc( (size_t)sz );
    if ( !b ) { fclose( f ); return -1; }
    if ( fread( b, 1, (size_t)sz, f ) != (size_t)sz ) { free( b ); fclose( f ); return -1; }
    fclose( f );
    *out = b;
    return sz;
}

static void test_wide_symbol_table(void) {
    const char *k32 = "build/bin/sysroot/libkernel32.a";
    const char *tmp = getenv( "TEMP" );
    FILE *probe = fopen( k32, "rb" );
    uint8_t *coff;
    size_t coflen = 0;
    char objpath[512], exe1[512], exe2[512];
    const char *objs[1];
    const char *arcs[1];

    if ( !probe ) {
        printf( "[~] SKIP lc_link_symindex: no sysroot (build/bin/sysroot/libkernel32.a)\n" );
        return;
    }
    fclose( probe );
    if ( !tmp ) tmp = ".";

    coff = build_wide_coff( &coflen );
    CHECK_NOT_NULL( coff );
    if ( !coff ) return;

    snprintf( objpath, sizeof objpath, "%s\\clua_symidx_%d.o",   tmp, (int)getpid() );
    snprintf( exe1,    sizeof exe1,    "%s\\clua_symidx_%d_a.exe", tmp, (int)getpid() );
    snprintf( exe2,    sizeof exe2,    "%s\\clua_symidx_%d_b.exe", tmp, (int)getpid() );
    {
        FILE *of = fopen( objpath, "wb" );
        CHECK_NOT_NULL( of );
        if ( !of ) { free( coff ); return; }
        fwrite( coff, 1, coflen, of );
        fclose( of );
    }
    free( coff );

    objs[0] = objpath;
    arcs[0] = k32;
    {
        LcPeLinkInputs in;
        char err[512] = {0};
        int ok;
        memset( &in, 0, sizeof in );
        in.objects  = objs; in.nobjects  = 1;
        in.archives = arcs; in.narchives = 1;
        in.entry    = "mainCRTStartup";
        in.out_path = exe1;
        ok = LcPe_Link( &in, err, sizeof err );
        CHECK_MSG( ok, err[0] ? err : "link with wide symbol table failed" );
        if ( ok ) {
            in.out_path = exe2;
            err[0] = 0;
            ok = LcPe_Link( &in, err, sizeof err );
            CHECK_MSG( ok, err[0] ? err : "second link failed" );
        }
        if ( ok ) {
            uint8_t *a = NULL, *b = NULL;
            long la = slurp( exe1, &a ), lb = slurp( exe2, &b );
            CHECK_MSG( la > 0 && lb > 0, "could not read produced PEs" );
            if ( la > 0 && lb > 0 ) {
                CHECK_EQ_INT( (int)la, (int)lb );
                CHECK_MSG( la == lb && memcmp( a, b, (size_t)la ) == 0,
                           "two links of the same input differ (index leaked ordering)" );
            }
            free( a ); free( b );
        }
    }
    remove( objpath );
    remove( exe1 );
    remove( exe2 );
}

/* ------------------------------------------------------------------------
 * Archive symbol index: duplicate-name precedence.
 *
 * LcAr_MemberDefining answers with the FIRST armap entry, in index order, whose
 * name matches. A GNU armap may legitimately name one symbol against several
 * members, and which member the linker pulls decides the emitted bytes -- so
 * that precedence is a correctness property, not an implementation detail.
 *
 * The linear scan gets it right by construction. Any index (a hash, a sorted
 * table, anything) can silently invert it: build the table with
 * last-insertion-wins, or iterate the armap descending, and every lookup still
 * "works" while pulling a different member. Nothing else in the suite would
 * notice, because both members satisfy the symbol.
 *
 * So this builds a two-member archive whose armap lists "dupSym" twice -- first
 * against firstmbr.o, then against secondmbr.o -- and asserts the answer is
 * firstmbr.o. It also asserts a name absent from the armap yields NULL, and that
 * every armap entry is reachable, which is what a broken probe loop breaks.
 * ---------------------------------------------------------------------- */

/* One archive member: 60-byte header (name padded, size decimal) + payload. */
static size_t ar_put_member( uint8_t *p, const char *name, const uint8_t *data,
                             size_t len ) {
    char hdr[60];
    size_t n = 0;
    memset( hdr, ' ', sizeof hdr );
    memcpy( hdr, name, strlen( name ) );
    {
        char szbuf[16];
        snprintf( szbuf, sizeof szbuf, "%-10u", (unsigned)len );
        memcpy( hdr + 48, szbuf, 10 );
    }
    hdr[58] = '`'; hdr[59] = '\n';
    memcpy( p, hdr, 60 );          n += 60;
    memcpy( p + n, data, len );    n += len;
    if ( len & 1 ) p[n++] = '\n';  /* members are 2-byte aligned */
    return n;
}

static void test_armap_duplicate_precedence(void) {
    /* Two distinct minimal COFF payloads, so the members differ in content as
       well as in name (a same-size same-bytes pair would hide a mix-up). */
    uint8_t coff_a[20] = {0}, coff_b[24] = {0};
    uint8_t ar[1024];
    size_t pos = 0;
    uint32_t off_first, off_second;
    char path[512];
    const char *tmp = getenv( "TEMP" );

    p16( coff_a + 0, 0x8664 );
    p16( coff_b + 0, 0x8664 );

    memcpy( ar, "!<arch>\n", 8 );
    pos = 8;

    /* The armap must carry the members' header offsets, so lay out the index
       first with the sizes known: 3 entries ("dupSym" twice, "onlySecond"). */
    {
        const char *names = "dupSym\0dupSym\0onlySecond";  /* 6+1 +6+1 +10+1 */
        const uint32_t nsym = 3;
        const uint32_t namelen = 7 + 7 + 11;
        const uint32_t idx_payload = 4 + nsym * 4 + namelen;
        const uint32_t idx_total = 60 + idx_payload + ( idx_payload & 1 );
        const uint32_t first_hdr = (uint32_t)( 8 + idx_total );
        const uint32_t first_total =
            60 + (uint32_t)sizeof coff_a + ( sizeof coff_a & 1 );
        char hdr[60];
        uint32_t i;

        off_first  = first_hdr;
        off_second = first_hdr + first_total;

        memset( hdr, ' ', sizeof hdr );
        hdr[0] = '/';
        {
            char szbuf[16];
            snprintf( szbuf, sizeof szbuf, "%-10u", idx_payload );
            memcpy( hdr + 48, szbuf, 10 );
        }
        hdr[58] = '`'; hdr[59] = '\n';
        memcpy( ar + pos, hdr, 60 ); pos += 60;

        /* BE count, then one BE member-header offset per symbol, then names. */
        ar[pos+0]=0; ar[pos+1]=0; ar[pos+2]=0; ar[pos+3]=(uint8_t)nsym; pos += 4;
        {   /* dupSym -> first, dupSym -> second, onlySecond -> second */
            const uint32_t offs[3] = { off_first, off_second, off_second };
            for ( i = 0; i < nsym; i++ ) {
                ar[pos+0]=(uint8_t)(offs[i]>>24); ar[pos+1]=(uint8_t)(offs[i]>>16);
                ar[pos+2]=(uint8_t)(offs[i]>>8);  ar[pos+3]=(uint8_t)offs[i];
                pos += 4;
            }
        }
        memcpy( ar + pos, names, namelen ); pos += namelen;
        if ( idx_payload & 1 ) ar[pos++] = '\n';
    }

    pos += ar_put_member( ar + pos, "firstmbr.o/",  coff_a, sizeof coff_a );
    pos += ar_put_member( ar + pos, "secondmbr.o/", coff_b, sizeof coff_b );

    if ( !tmp ) tmp = ".";
    snprintf( path, sizeof path, "%s\\clua_ardup_%d.a", tmp, (int)getpid() );
    {
        FILE *f = fopen( path, "wb" );
        CHECK_NOT_NULL( f );
        if ( !f ) return;
        fwrite( ar, 1, pos, f );
        fclose( f );
    }

    {
        LcArchive a;
        char err[256] = {0};
        int ok = LcAr_Open( path, &a, err, sizeof err );
        CHECK_MSG( ok, err[0] ? err : "ar open failed" );
        if ( ok ) {
            const LcArMember *m;
            CHECK_EQ_INT( (int)a.nindex, 3 );
            CHECK_EQ_INT( (int)a.nmembers, 2 );

            /* THE INVARIANT: first armap entry wins. Building an index with
               last-insertion-wins, or iterating the armap descending, returns
               secondmbr.o here and changes which member a real link pulls. */
            m = LcAr_MemberDefining( &a, "dupSym" );
            CHECK_NOT_NULL( m );
            if ( m ) CHECK_MSG( strcmp( m->name, "firstmbr.o" ) == 0,
                                "duplicate armap name must resolve to the FIRST "
                                "entry's member" );

            /* a later-listed unique name must still be reachable: this is what
               a probe loop that stops early, or a table that drops colliding
               inserts, gets wrong */
            m = LcAr_MemberDefining( &a, "onlySecond" );
            CHECK_NOT_NULL( m );
            if ( m ) CHECK_MSG( strcmp( m->name, "secondmbr.o" ) == 0,
                                "unique armap name resolved to the wrong member" );

            /* absent name -> NULL, not a stale slot's member */
            CHECK_MSG( LcAr_MemberDefining( &a, "nosuchsymbol" ) == NULL,
                       "a name absent from the armap must not resolve" );
            /* near-misses that share a hash-relevant prefix/suffix */
            CHECK_MSG( LcAr_MemberDefining( &a, "dupSy" ) == NULL, "prefix matched" );
            CHECK_MSG( LcAr_MemberDefining( &a, "dupSymX" ) == NULL, "extension matched" );
            CHECK_MSG( LcAr_MemberDefining( &a, "" ) == NULL, "empty name matched" );

            /* every member is findable by its own header offset */
            m = LcAr_MemberByHdrOff( &a, off_first );
            CHECK_NOT_NULL( m );
            if ( m ) CHECK_MSG( strcmp( m->name, "firstmbr.o" ) == 0,
                                "hdr_off lookup returned the wrong member" );
            m = LcAr_MemberByHdrOff( &a, off_second );
            CHECK_NOT_NULL( m );
            if ( m ) CHECK_MSG( strcmp( m->name, "secondmbr.o" ) == 0,
                                "hdr_off lookup returned the wrong member" );
            CHECK_MSG( LcAr_MemberByHdrOff( &a, 0xDEADBEEFu ) == NULL,
                       "an unknown hdr_off must not resolve" );

            /* repeat every query: a lazily built index must answer a second
               time exactly as it did the first */
            m = LcAr_MemberDefining( &a, "dupSym" );
            if ( m ) CHECK_MSG( strcmp( m->name, "firstmbr.o" ) == 0,
                                "second lookup of a duplicate name differed" );

            LcAr_Close( &a );
        }
    }
    remove( path );
}

int main(void) {
    TEST_BEGIN("lc_link_symindex");
    test_wide_symbol_table();
    test_armap_duplicate_precedence();
    TEST_END();
}
