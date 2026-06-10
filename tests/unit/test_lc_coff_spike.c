/* test_lc_coff_spike.c -- COFF-object + link spike (LuaC Task 2).
 *
 * Hand-builds a minimal x64 COFF .o containing a single function
 * `luac_fn_spike` whose body issues a `call rel32` relocated against the
 * external symbol `Rt_Len` (provided by build/bin/runtime-embedded.a). We then
 * prove MinGW `ld` accepts the format and resolves the reloc by linking the
 * object against the runtime archives. This LOCKS the on-disk COFF layout that
 * the real COFF writer (Task 12) must reproduce byte-for-byte.
 *
 * Two link probes:
 *   positive  -- reloc names the real `Rt_Len`            -> link succeeds (rc==0)
 *   negative  -- reloc names `Rt_DoesNotExist_ZZZ`        -> link fails   (rc!=0)
 * The negative control proves the symbol/reloc machinery is genuinely
 * resolved by name against the archive, not a format-only no-op.
 *
 * Everything is written by emitting raw little-endian bytes (no reliance on
 * `sizeof` of an IMAGE_* struct, since IMAGE_SYMBOL is 18 bytes / pack(2) and
 * IMAGE_RELOCATION is 10 bytes -- naive structs would be padded). This file is
 * therefore the authoritative byte-level spec for the COFF writer.
 *
 * --------------------------------------------------------------------------
 * COFF layout produced (the Task-12 spec):
 *
 *   [0x00] IMAGE_FILE_HEADER (20 bytes)
 *            Machine=0x8664(AMD64) NumberOfSections=1 TimeDateStamp=0
 *            PointerToSymbolTable=<off> NumberOfSymbols=2
 *            SizeOfOptionalHeader=0 Characteristics=0
 *   [0x14] one .text IMAGE_SECTION_HEADER (40 bytes)
 *            Name=".text" VirtualSize=0 VirtualAddress=0
 *            SizeOfRawData=8 PointerToRawData=<off>
 *            PointerToRelocations=<off> PointerToLinenumbers=0
 *            NumberOfRelocations=1 NumberOfLinenumbers=0
 *            Characteristics=CNT_CODE|MEM_EXECUTE|MEM_READ|ALIGN_16BYTES
 *   .text raw (8 bytes): E8 00 00 00 00  31 C0  C3
 *            call rel32 (disp32 placeholder at off+1) ; xor eax,eax ; ret
 *   one IMAGE_RELOCATION (10 bytes):
 *            VirtualAddress=1 SymbolTableIndex=<Rt_Len idx> Type=REL32(0x0004)
 *   symbol table (2 symbols * 18 bytes):
 *            [0] luac_fn_spike  Name via string table (>8 chars)
 *                Value=0 SectionNumber=1 Type=0x20(func) Class=EXTERNAL(2) aux=0
 *            [1] Rt_Len         Name inline (<=8 chars)
 *                Value=0 SectionNumber=0(undef) Type=0 Class=EXTERNAL(2) aux=0
 *   string table:
 *            DWORD size (incl. itself) + NUL-terminated long names
 * -------------------------------------------------------------------------- */
#include "test_harness.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <direct.h> /* _mkdir */

/* ---- COFF constants (mirror winnt.h; spelled out so the spec is self-contained) ---- */
#define LC_IMAGE_FILE_MACHINE_AMD64   0x8664
#define LC_IMAGE_SCN_CNT_CODE         0x00000020u
#define LC_IMAGE_SCN_ALIGN_16BYTES    0x00500000u
#define LC_IMAGE_SCN_MEM_EXECUTE      0x20000000u
#define LC_IMAGE_SCN_MEM_READ         0x40000000u
#define LC_IMAGE_SYM_CLASS_EXTERNAL   0x0002
#define LC_IMAGE_SYM_TYPE_FUNC        0x0020 /* DTYPE FUNCTION << 4 */
#define LC_IMAGE_REL_AMD64_REL32      0x0004

/* sizes of the on-disk records (NOT sizeof a struct) */
#define LC_SZ_FILE_HEADER    20
#define LC_SZ_SECTION_HEADER  40
#define LC_SZ_SYMBOL          18
#define LC_SZ_RELOCATION      10

/* ---- little-endian writers into a growing byte buffer ---- */
typedef struct { unsigned char *p; size_t len, cap; } Buf;

static void buf_need(Buf *b, size_t n) {
    if (b->len + n > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 256;
        while (nc < b->len + n) nc *= 2;
        b->p = (unsigned char *)realloc(b->p, nc);
        b->cap = nc;
    }
}
static void put8(Buf *b, unsigned v)  { buf_need(b, 1); b->p[b->len++] = (unsigned char)(v & 0xFF); }
static void put16(Buf *b, unsigned v) { put8(b, v); put8(b, v >> 8); }
static void put32(Buf *b, unsigned v) { put16(b, v); put16(b, v >> 16); }
static void putn(Buf *b, const void *src, size_t n) { buf_need(b, n); memcpy(b->p + b->len, src, n); b->len += n; }

/* Write the spike COFF object. `undef_name` is the undefined external symbol the
 * .text reloc points at (the real `Rt_Len` for the positive case, a bogus name
 * for the negative control). Returns 0 on success, non-zero on I/O failure. */
static int WriteSpikeObj(const char *path, const char *undef_name) {
    /* --- .text raw code: call rel32 ; xor eax,eax ; ret (8 bytes) --- */
    static const unsigned char text[] = { 0xE8,0x00,0x00,0x00,0x00, 0x31,0xC0, 0xC3 };
    const unsigned text_size = (unsigned)sizeof(text);

    const char *func_name = "luac_fn_spike"; /* > 8 chars -> string table */
    const int   func_long = (int)strlen(func_name) > 8;             /* yes */
    const int   undef_long = (int)strlen(undef_name) > 8;           /* "Rt_Len"=no, bogus=yes */

    const unsigned num_sections = 1;
    const unsigned num_symbols  = 2;
    const unsigned num_relocs   = 1;

    /* --- file offsets --- */
    unsigned off = LC_SZ_FILE_HEADER + num_sections * LC_SZ_SECTION_HEADER;
    const unsigned ptr_raw    = off;                       /* .text raw bytes */
    off += text_size;
    const unsigned ptr_reloc  = off;                       /* .text relocations */
    off += num_relocs * LC_SZ_RELOCATION;
    const unsigned ptr_symtab = off;                       /* symbol table */
    off += num_symbols * LC_SZ_SYMBOL;
    /* string table follows the symbol table */

    /* --- build the string table; record offsets for long names ---
     * The string table begins with a 4-byte total length (including itself);
     * the first real string therefore starts at offset 4. */
    Buf strtab; memset(&strtab, 0, sizeof strtab);
    put32(&strtab, 0); /* placeholder for length, patched below */
    unsigned func_str_off = 0, undef_str_off = 0;
    if (func_long)  { func_str_off  = (unsigned)strtab.len; putn(&strtab, func_name,  strlen(func_name)  + 1); }
    if (undef_long) { undef_str_off = (unsigned)strtab.len; putn(&strtab, undef_name, strlen(undef_name) + 1); }
    /* patch the length prefix (total size incl. the 4-byte field itself) */
    { unsigned tl = (unsigned)strtab.len;
      strtab.p[0]=(unsigned char)(tl); strtab.p[1]=(unsigned char)(tl>>8);
      strtab.p[2]=(unsigned char)(tl>>16); strtab.p[3]=(unsigned char)(tl>>24); }

    /* --- assemble the object --- */
    Buf o; memset(&o, 0, sizeof o);

    /* IMAGE_FILE_HEADER */
    put16(&o, LC_IMAGE_FILE_MACHINE_AMD64); /* Machine */
    put16(&o, num_sections);                /* NumberOfSections */
    put32(&o, 0);                           /* TimeDateStamp */
    put32(&o, ptr_symtab);                  /* PointerToSymbolTable */
    put32(&o, num_symbols);                 /* NumberOfSymbols */
    put16(&o, 0);                           /* SizeOfOptionalHeader */
    put16(&o, 0);                           /* Characteristics */

    /* .text IMAGE_SECTION_HEADER */
    { char nm[8] = { '.','t','e','x','t', 0,0,0 }; putn(&o, nm, 8); } /* Name */
    put32(&o, 0);            /* VirtualSize (Misc) */
    put32(&o, 0);            /* VirtualAddress */
    put32(&o, text_size);    /* SizeOfRawData */
    put32(&o, ptr_raw);      /* PointerToRawData */
    put32(&o, ptr_reloc);    /* PointerToRelocations */
    put32(&o, 0);            /* PointerToLinenumbers */
    put16(&o, num_relocs);   /* NumberOfRelocations */
    put16(&o, 0);            /* NumberOfLinenumbers */
    put32(&o, LC_IMAGE_SCN_CNT_CODE | LC_IMAGE_SCN_MEM_EXECUTE |
              LC_IMAGE_SCN_MEM_READ | LC_IMAGE_SCN_ALIGN_16BYTES); /* Characteristics */

    /* .text raw bytes */
    putn(&o, text, text_size);

    /* relocation: the disp32 of the call lives at .text offset 1.
     * SymbolTableIndex must point at the undefined symbol, which we place at
     * index 1 (luac_fn_spike is 0). */
    put32(&o, 1);                        /* VirtualAddress */
    put32(&o, 1);                        /* SymbolTableIndex -> undef symbol */
    put16(&o, LC_IMAGE_REL_AMD64_REL32); /* Type */

    /* symbol table.
     * [0] luac_fn_spike: defined in .text (section 1), function, EXTERNAL. */
    if (func_long) { put32(&o, 0); put32(&o, func_str_off); }   /* Name: {0,0,0,0, strtab off} */
    else           { char nm[8]={0}; strncpy(nm, func_name, 8); putn(&o, nm, 8); }
    put32(&o, 0);                          /* Value */
    put16(&o, 1);                          /* SectionNumber = 1 (.text) */
    put16(&o, LC_IMAGE_SYM_TYPE_FUNC);     /* Type = 0x20 */
    put8 (&o, LC_IMAGE_SYM_CLASS_EXTERNAL);/* StorageClass = EXTERNAL */
    put8 (&o, 0);                          /* NumberOfAuxSymbols */

    /* [1] undef_name: undefined external (SectionNumber 0). */
    if (undef_long) { put32(&o, 0); put32(&o, undef_str_off); }
    else            { char nm[8]={0}; strncpy(nm, undef_name, 8); putn(&o, nm, 8); }
    put32(&o, 0);                          /* Value */
    put16(&o, 0);                          /* SectionNumber = 0 (undefined) */
    put16(&o, 0);                          /* Type */
    put8 (&o, LC_IMAGE_SYM_CLASS_EXTERNAL);/* StorageClass = EXTERNAL */
    put8 (&o, 0);                          /* NumberOfAuxSymbols */

    /* string table */
    putn(&o, strtab.p, strtab.len);

    /* --- flush to disk --- */
    int rc = 0;
    FILE *f = fopen(path, "wb");
    if (!f) { rc = -1; }
    else {
        if (fwrite(o.p, 1, o.len, f) != o.len) rc = -2;
        if (fclose(f) != 0) rc = -3;
    }
    free(o.p);
    free(strtab.p);
    return rc;
}

/* Compile a tiny companion object that provides `main` and references
 * `luac_fn_spike`. We supply our OWN `main` so the linker does NOT pull the
 * runtime archive's `main` (runtime_entry.o), which in turn drags in
 * runtime_init.o and the per-program blob symbols g_LuaBlob / g_LuaBlob_size /
 * Runtime_GetPackages -- those are produced by the (not-yet-built) codegen/
 * embedding step and are undefined in these stock archives. Keeping the
 * runtime's main out lets us link ONLY what we want to prove: that ld accepts
 * our hand-built COFF object and resolves its `Rt_Len` reloc from runtime.o.
 * Returns 0 on success. */
static int build_main_obj(const char *src, const char *obj) {
    FILE *f = fopen(src, "wb");
    if (!f) return -1;
    fputs("extern void luac_fn_spike(void);\n"
          "int main(void){ return (void*)luac_fn_spike ? 0 : 1; }\n", f);
    if (fclose(f) != 0) return -2;
    char cmd[1024];
    snprintf(cmd, sizeof cmd,
        "x86_64-w64-mingw32-gcc -c \"%s\" -o \"%s\"", src, obj);
    return system(cmd);
}

/* Build the gcc/ld command line. `-Wl,--undefined=luac_fn_spike` forces the
 * function (and thus its reloc) to be retained so the link actually exercises
 * the relocation against the archive. `main_obj` supplies `main` (see above). */
static int link_probe(const char *obj, const char *main_obj, const char *exe) {
    char cmd[1024];
    snprintf(cmd, sizeof cmd,
        "x86_64-w64-mingw32-gcc \"%s\" \"%s\" build\\bin\\runtime-embedded.a "
        "build\\bin\\liblua54-embedded.a -o \"%s\" "
        "-Wl,--undefined=luac_fn_spike "
        "-lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi",
        obj, main_obj, exe);
    return system(cmd);
}

int main(void) {
    TEST_BEGIN("lc_coff_spike");

    _mkdir("build");
    _mkdir("build\\tmp");

    const char *obj_pos  = "build\\tmp\\spike.o";
    const char *obj_neg  = "build\\tmp\\spike_neg.o";
    const char *exe_pos  = "build\\tmp\\spike_probe.exe";
    const char *exe_neg  = "build\\tmp\\spike_probe_neg.exe";
    const char *main_src = "build\\tmp\\spikemain.c";
    const char *main_obj = "build\\tmp\\spikemain.o";

    /* ---- write both objects ---- */
    int wrc_pos = WriteSpikeObj(obj_pos, "Rt_Len");
    int wrc_neg = WriteSpikeObj(obj_neg, "Rt_DoesNotExist_ZZZ");
    CHECK_EQ_INT(wrc_pos, 0);
    CHECK_EQ_INT(wrc_neg, 0);

    /* ---- companion main object (keeps the runtime's incomplete main out) ---- */
    int mrc = build_main_obj(main_src, main_obj);
    CHECK_EQ_INT(mrc, 0);

    /* ---- negative control first (TDD: it must fail for unresolved symbol) ---- */
    int rc_neg = link_probe(obj_neg, main_obj, exe_neg);
    printf("[i] negative-control link rc = %d (expect != 0: unresolved Rt_DoesNotExist_ZZZ)\n", rc_neg);
    CHECK_NEQ_INT(rc_neg, 0);

    /* ---- positive link: real Rt_Len resolves from the archive ---- */
    int rc_pos = link_probe(obj_pos, main_obj, exe_pos);
    printf("[i] positive link rc = %d (expect 0: Rt_Len resolved, COFF accepted)\n", rc_pos);
    CHECK_EQ_INT(rc_pos, 0);

    TEST_END();
}
