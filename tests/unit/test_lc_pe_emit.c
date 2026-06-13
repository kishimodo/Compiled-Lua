/* test_lc_pe_emit.c -- the internal COFF->PE64 linker (src/link/{coff_read,
 * ar_read,pe_emit}.c). Three layers:
 *   1. COFF reader: hand-build a tiny in-memory object and assert the parsed
 *      sections / symbols / relocations match what we wrote.
 *   2. GNU archive reader: build a 2-member archive in memory and resolve a
 *      symbol through its index.
 *   3. End-to-end PE: link a minimal `mainCRTStartup -> ExitProcess(0)` object
 *      against the sysroot's libkernel32.a, then PARSE the produced PE and
 *      assert its invariants (MZ/PE magic, PE32+, console subsystem, ImageBase
 *      0x140000000, a resolvable import directory, a sane entry point). The PE
 *      layer SKIPs cleanly when the CRT sysroot isn't present.
 */
#include "test_harness.h"
#include "link/coff_read.h"
#include "link/ar_read.h"
#include "link/pe_emit.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <process.h>   /* _getpid */
#define getpid _getpid

/* ---- little-endian writers into a buffer ---- */
static void p16( uint8_t *p, uint16_t v ) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void p32( uint8_t *p, uint32_t v ) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24); }
static uint16_t g16( const uint8_t *p ) { return (uint16_t)(p[0] | (p[1]<<8)); }
static uint32_t g32( const uint8_t *p ) { return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }

/* Build a minimal AMD64 COFF object in `buf`: one .text section with `code`,
 * one defined EXTERNAL function symbol `funcname` at .text:0, one undefined
 * EXTERNAL `undefname`, and one REL32 reloc at offset `reloc_off` -> undef.
 * Returns the byte length. Long names use the string table. */
static size_t build_min_coff( uint8_t *buf, const uint8_t *code, size_t codelen,
                              const char *funcname, const char *undefname,
                              uint32_t reloc_off ) {
    size_t off = 0;
    uint32_t ptr_text  = 20 + 40;                 /* file hdr + 1 sect hdr   */
    uint32_t ptr_reloc = ptr_text + (uint32_t)codelen;
    uint32_t ptr_sym   = ptr_reloc + 10;          /* 1 reloc                 */
    uint8_t *strtab;
    uint32_t strlen_total;

    memset( buf, 0, 1024 );
    /* IMAGE_FILE_HEADER */
    p16( buf+0, 0x8664 );        /* Machine AMD64        */
    p16( buf+2, 1 );             /* NumberOfSections     */
    p32( buf+8, ptr_sym );       /* PointerToSymbolTable */
    p32( buf+12, 2 );            /* NumberOfSymbols      */
    /* section header .text */
    memcpy( buf+20, ".text", 5 );
    p32( buf+20+16, (uint32_t)codelen ); /* SizeOfRawData        */
    p32( buf+20+20, ptr_text );          /* PointerToRawData     */
    p32( buf+20+24, ptr_reloc );         /* PointerToRelocations */
    p16( buf+20+32, 1 );                 /* NumberOfRelocations  */
    p32( buf+20+36, 0x60000020u );       /* CODE|EXECUTE|READ    */
    /* raw code */
    memcpy( buf+ptr_text, code, codelen );
    /* reloc: REL32 at reloc_off -> symbol #1 (the undef) */
    p32( buf+ptr_reloc+0, reloc_off );
    p32( buf+ptr_reloc+4, 1 );           /* SymbolTableIndex     */
    p16( buf+ptr_reloc+8, 4 );           /* REL32                */
    /* symbol 0: funcname (defined, .text:0, EXTERNAL function) */
    /* symbol 1: undefname (undef, EXTERNAL) -- both via string table */
    strtab = buf + ptr_sym + 2*18;
    /* sym 0 */
    p32( buf+ptr_sym+0, 0 );             /* name: long -> strtab */
    p32( buf+ptr_sym+4, 4 );             /* strtab offset 4      */
    p32( buf+ptr_sym+8, 0 );             /* Value                */
    p16( buf+ptr_sym+12, 1 );            /* SectionNumber .text  */
    p16( buf+ptr_sym+14, 0x20 );         /* Type function        */
    buf[ptr_sym+16] = 2;                 /* EXTERNAL             */
    buf[ptr_sym+17] = 0;                 /* naux                 */
    /* sym 1 */
    {
        uint32_t off2 = 4 + (uint32_t)strlen(funcname) + 1;
        p32( buf+ptr_sym+18+0, 0 );
        p32( buf+ptr_sym+18+4, off2 );
        p32( buf+ptr_sym+18+8, 0 );
        p16( buf+ptr_sym+18+12, 0 );     /* undef                */
        p16( buf+ptr_sym+18+14, 0 );
        buf[ptr_sym+18+16] = 2;          /* EXTERNAL             */
        buf[ptr_sym+18+17] = 0;
    }
    /* string table: [len][funcname\0][undefname\0] */
    {
        uint32_t fl = (uint32_t)strlen(funcname)+1, ul = (uint32_t)strlen(undefname)+1;
        strlen_total = 4 + fl + ul;
        p32( strtab, strlen_total );
        memcpy( strtab+4, funcname, fl );
        memcpy( strtab+4+fl, undefname, ul );
    }
    off = (size_t)(strtab + strlen_total - buf);
    return off;
}

static void test_coff_reader(void) {
    uint8_t buf[1024];
    uint8_t code[8] = { 0xE8,0,0,0,0, 0xC3, 0x90, 0x90 }; /* call rel32 ; ret */
    size_t len = build_min_coff( buf, code, sizeof code, "myStartFunc", "myExternFn", 1 );
    LcCoffObj o;
    char err[256] = {0};
    int ok = LcCoff_Parse( buf, len, "mem", &o, err, sizeof err );
    CHECK_MSG( ok, err[0] ? err : "coff parse failed" );
    if ( !ok ) return;

    CHECK_EQ_INT( o.nsections, 1 );
    CHECK_EQ_STR( o.sections[0].name, ".text" );
    CHECK_EQ_INT( o.sections[0].size_raw, 8 );
    CHECK_EQ_INT( o.sections[0].nrelocs, 1 );
    CHECK_EQ_INT( o.sections[0].relocs[0].va, 1 );
    CHECK_EQ_INT( o.sections[0].relocs[0].type, LC_IMAGE_REL_AMD64_REL32 );

    /* symbol 0: the defined function */
    {
        const LcCoffSymbol *s0 = LcCoff_SymByIndex( &o, 0 );
        const LcCoffSymbol *s1 = LcCoff_SymByIndex( &o, 1 );
        CHECK_NOT_NULL( s0 );
        CHECK_NOT_NULL( s1 );
        if ( s0 ) { CHECK_EQ_STR( s0->name, "myStartFunc" ); CHECK_EQ_INT( s0->section, 1 ); }
        if ( s1 ) { CHECK_EQ_STR( s1->name, "myExternFn" );  CHECK_EQ_INT( s1->section, 0 ); }
    }
    LcCoff_Free( &o );
}

/* Build a tiny GNU archive with a symbol index and one trivial member. We embed
 * a minimal valid COFF as the member so LcAr_Open accepts it; we only assert the
 * index resolves the symbol to that member. */
static void test_archive_reader(void) {
    /* member payload: a minimal COFF (no sections, no syms) */
    uint8_t coff[20] = {0};
    p16( coff+0, 0x8664 ); /* Machine */
    /* archive: "!<arch>\n" + "/" index member + the coff member */
    uint8_t ar[512];
    size_t pos = 0;
    uint32_t member_hdr_off;
    char hdr[60];

    memcpy( ar, "!<arch>\n", 8 ); pos = 8;

    /* the member comes AFTER the index; we need its header offset for the index.
     * index member size = 4 (count) + 4 (offset) + len("theSym\0"). */
    {
        const char *sym = "theSym";
        uint32_t idx_payload = 4 + 4 + (uint32_t)strlen(sym) + 1;
        uint32_t idx_member_total = 60 + idx_payload + (idx_payload & 1);
        member_hdr_off = (uint32_t)(8 + idx_member_total);

        /* index member header: name "/" */
        memset( hdr, ' ', 60 );
        hdr[0] = '/';
        memcpy( hdr+48, "        ", 8 );
        {
            char szbuf[16]; snprintf( szbuf, sizeof szbuf, "%-10u", idx_payload );
            memcpy( hdr+48, szbuf, 10 );
        }
        hdr[58] = '`'; hdr[59] = '\n';
        memcpy( ar+pos, hdr, 60 ); pos += 60;
        /* index payload: BE count=1, BE member-offset, "theSym\0" */
        ar[pos+0]=0; ar[pos+1]=0; ar[pos+2]=0; ar[pos+3]=1; pos += 4;
        ar[pos+0]=(uint8_t)(member_hdr_off>>24); ar[pos+1]=(uint8_t)(member_hdr_off>>16);
        ar[pos+2]=(uint8_t)(member_hdr_off>>8);  ar[pos+3]=(uint8_t)member_hdr_off; pos += 4;
        memcpy( ar+pos, sym, strlen(sym)+1 ); pos += (uint32_t)strlen(sym)+1;
        if ( idx_payload & 1 ) { ar[pos++] = '\n'; }
    }

    /* the COFF member header: name "obj.o/" */
    memset( hdr, ' ', 60 );
    memcpy( hdr, "obj.o/", 6 );
    { char szbuf[16]; snprintf( szbuf, sizeof szbuf, "%-10u", (unsigned)sizeof coff );
      memcpy( hdr+48, szbuf, 10 ); }
    hdr[58]='`'; hdr[59]='\n';
    memcpy( ar+pos, hdr, 60 ); pos += 60;
    memcpy( ar+pos, coff, sizeof coff ); pos += sizeof coff;

    /* write to a temp file and open it */
    {
        char path[512];
        const char *tmp = getenv("TEMP"); if (!tmp) tmp = ".";
        snprintf( path, sizeof path, "%s\\clua_test_ar_%d.a", tmp, (int)getpid() );
        FILE *f = fopen( path, "wb" );
        CHECK_NOT_NULL( f );
        if ( f ) {
            fwrite( ar, 1, pos, f );
            fclose( f );
            {
                LcArchive a; char err[256] = {0};
                int ok = LcAr_Open( path, &a, err, sizeof err );
                CHECK_MSG( ok, err[0] ? err : "ar open failed" );
                if ( ok ) {
                    CHECK_EQ_INT( a.nindex, 1 );
                    const LcArMember *m = LcAr_MemberDefining( &a, "theSym" );
                    CHECK_NOT_NULL( m );
                    LcAr_Close( &a );
                }
            }
            remove( path );
        }
    }
}

/* Validate a produced PE by parsing its headers from disk. */
static int validate_pe( const char *path ) {
    FILE *f = fopen( path, "rb" );
    long sz; uint8_t *b; uint32_t pe_off, opt;
    int ok = 1;
    if ( !f ) return 0;
    fseek( f, 0, SEEK_END ); sz = ftell( f ); fseek( f, 0, SEEK_SET );
    if ( sz < 0x200 ) { fclose(f); return 0; }
    b = (uint8_t*)malloc( (size_t)sz );
    if ( !b ) { fclose(f); return 0; }
    if ( fread( b, 1, (size_t)sz, f ) != (size_t)sz ) { free(b); fclose(f); return 0; }
    fclose( f );

    ok &= ( b[0] == 'M' && b[1] == 'Z' );
    pe_off = g32( b + 0x3C );
    ok &= ( pe_off + 24 < (uint32_t)sz );
    ok &= ( b[pe_off]=='P' && b[pe_off+1]=='E' && b[pe_off+2]==0 && b[pe_off+3]==0 );
    ok &= ( g16( b + pe_off + 4 ) == 0x8664 );        /* Machine AMD64        */
    opt = pe_off + 4 + 20;
    ok &= ( g16( b + opt ) == 0x020B );               /* PE32+                */
    ok &= ( g16( b + opt + 68 ) == 3 );               /* Subsystem console    */
    {
        uint64_t base = (uint64_t)g32(b+opt+24) | ((uint64_t)g32(b+opt+28)<<32);
        ok &= ( base == 0x140000000ULL );             /* ImageBase            */
    }
    ok &= ( g32( b + opt + 16 ) != 0 );               /* AddressOfEntryPoint  */
    /* import directory present + nonzero */
    ok &= ( g32( b + opt + 112 + 1*8 + 0 ) != 0 );    /* DIR_IMPORT rva       */
    free( b );
    return ok;
}

static void test_end_to_end_pe(void) {
    /* find the sysroot's libkernel32.a next to the test binary's build dir.
     * The runner runs from the repo root, so build/bin/sysroot is the path. */
    const char *k32 = "build/bin/sysroot/libkernel32.a";
    FILE *probe = fopen( k32, "rb" );
    if ( !probe ) {
        printf("[~] SKIP lc_pe_emit/e2e: no sysroot (build/bin/sysroot/libkernel32.a)\n");
        return;
    }
    fclose( probe );

    /* mainCRTStartup: mov ecx,0 ; call ExitProcess (REL32) ; (never returns) */
    {
        uint8_t code[12] = {
            0x31, 0xC9,                         /* xor ecx, ecx          */
            0xE8, 0x00,0x00,0x00,0x00,          /* call rel32 ExitProcess*/
            0xCC, 0xCC, 0xCC, 0xCC, 0xCC        /* pad                   */
        };
        uint8_t buf[1024];
        char objpath[512], exepath[512];
        const char *tmp = getenv("TEMP"); if (!tmp) tmp = ".";
        size_t len = build_min_coff( buf, code, sizeof code,
                                     "mainCRTStartup", "ExitProcess", 3 );
        snprintf( objpath, sizeof objpath, "%s\\clua_test_pe_%d.o", tmp, (int)getpid() );
        snprintf( exepath, sizeof exepath, "%s\\clua_test_pe_%d.exe", tmp, (int)getpid() );
        {
            FILE *of = fopen( objpath, "wb" );
            CHECK_NOT_NULL( of );
            if ( of ) { fwrite( buf, 1, len, of ); fclose( of ); }
        }
        {
            const char *objs[1] = { objpath };
            const char *arcs[1] = { k32 };
            char err[512] = {0};
            LcPeLinkInputs in;
            int ok;
            memset( &in, 0, sizeof in );
            in.objects = objs; in.nobjects = 1;
            in.archives = arcs; in.narchives = 1;
            in.entry = "mainCRTStartup";
            in.out_path = exepath;
            ok = LcPe_Link( &in, err, sizeof err );
            CHECK_MSG( ok, err[0] ? err : "LcPe_Link failed" );
            if ( ok ) {
                CHECK_MSG( validate_pe( exepath ), "produced PE failed invariant checks" );
            }
            remove( objpath );
            remove( exepath );
        }
    }
}

int main(void) {
    TEST_BEGIN("lc_pe_emit");
    test_coff_reader();
    test_archive_reader();
    test_end_to_end_pe();
    TEST_END();
}
