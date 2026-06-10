/* src/codegen/lc_codebuf.h */
#ifndef LUAC_CODEGEN_LC_CODEBUF_H
#define LUAC_CODEGEN_LC_CODEBUF_H
#include <stddef.h>
#include <stdint.h>

typedef enum {
    LC_RELOC_REL32,        /* IMAGE_REL_AMD64_REL32: disp32 at offset, vs symbol  */
    LC_RELOC_ADDR64,       /* IMAGE_REL_AMD64_ADDR64: abs64 at offset, vs symbol  */
    LC_RELOC_REL32_RDATA   /* REL32 against a .rdata local symbol (RIP-relative)  */
} LcRelocKind;

typedef struct {
    LcRelocKind kind;
    uint32_t    offset;    /* byte offset within .bytes of the field to patch */
    char        symbol[64];
    int32_t     addend;
} LcReloc;

typedef struct {
    uint8_t *bytes; size_t used, cap;
    LcReloc *relocs; size_t nrelocs, relocap;
} LcCodeBuf;

int  LcCodeBuf_Init    ( LcCodeBuf *b, size_t cap );
int  LcCodeBuf_Append  ( LcCodeBuf *b, const uint8_t *p, size_t n );
int  LcCodeBuf_AddReloc( LcCodeBuf *b, LcRelocKind k, uint32_t off, const char *sym, int32_t addend );
void LcCodeBuf_Free    ( LcCodeBuf *b );
#endif
