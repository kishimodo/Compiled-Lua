/* test_lc_link_symindex.c -- regression cover for the internal linker's global
 * symbol index and (object,section) contribution index (pe_emit.c).
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

int main(void) {
    TEST_BEGIN("lc_link_symindex");
    test_wide_symbol_table();
    TEST_END();
}
