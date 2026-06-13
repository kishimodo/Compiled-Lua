/*
** coff_read.h — a reader for x86-64 COFF objects (the input the internal
** linker consumes). Parses the file header, section headers + raw data,
** per-section relocation tables, the 18-byte symbol table (with aux records),
** and the string table. Understands the bits the CLua input set exercises:
** COMDAT (IMAGE_SCN_LNK_COMDAT + its section aux), weak externals
** (IMAGE_SYM_CLASS_WEAK_EXTERNAL + its aux), and COMMON (SectionNumber 0 with
** Value = size).
**
** Memory model: one LcCoffObj owns a single malloc'd copy of the whole file
** plus heap arrays of decoded sections/symbols/relocs. Names are returned as
** NUL-terminated pointers into a decoded-name pool (short names are copied,
** long names point past the string table). Free with LcCoff_Free.
*/
#ifndef LUAC_LINK_COFF_READ_H
#define LUAC_LINK_COFF_READ_H

#include <stddef.h>
#include <stdint.h>

/* ---- COFF / IMAGE_* constants (self-contained; mirror winnt.h) ---- */
#define LC_IMAGE_FILE_MACHINE_AMD64        0x8664

#define LC_IMAGE_SCN_CNT_CODE              0x00000020u
#define LC_IMAGE_SCN_CNT_INITIALIZED_DATA  0x00000040u
#define LC_IMAGE_SCN_CNT_UNINIT_DATA       0x00000080u
#define LC_IMAGE_SCN_LNK_INFO              0x00000200u
#define LC_IMAGE_SCN_LNK_REMOVE            0x00000800u
#define LC_IMAGE_SCN_LNK_COMDAT            0x00001000u
#define LC_IMAGE_SCN_ALIGN_MASK            0x00F00000u
#define LC_IMAGE_SCN_ALIGN_SHIFT          20
#define LC_IMAGE_SCN_LNK_NRELOC_OVFL       0x01000000u
#define LC_IMAGE_SCN_MEM_DISCARDABLE       0x02000000u
#define LC_IMAGE_SCN_MEM_EXECUTE           0x20000000u
#define LC_IMAGE_SCN_MEM_READ              0x40000000u
#define LC_IMAGE_SCN_MEM_WRITE             0x80000000u

#define LC_IMAGE_SYM_UNDEFINED             0      /* SectionNumber 0          */
#define LC_IMAGE_SYM_ABSOLUTE              (-1)   /* 0xFFFF                   */
#define LC_IMAGE_SYM_DEBUG                 (-2)   /* 0xFFFE                   */

#define LC_IMAGE_SYM_CLASS_EXTERNAL        2
#define LC_IMAGE_SYM_CLASS_STATIC          3
#define LC_IMAGE_SYM_CLASS_FUNCTION        101
#define LC_IMAGE_SYM_CLASS_FILE            103
#define LC_IMAGE_SYM_CLASS_WEAK_EXTERNAL   105
#define LC_IMAGE_SYM_CLASS_LABEL           6
#define LC_IMAGE_SYM_CLASS_SECTION         104

/* COMDAT selection (section-aux Selection byte) */
#define LC_IMAGE_COMDAT_SELECT_NODUPLICATES 1
#define LC_IMAGE_COMDAT_SELECT_ANY          2
#define LC_IMAGE_COMDAT_SELECT_SAME_SIZE    3
#define LC_IMAGE_COMDAT_SELECT_EXACT_MATCH  4
#define LC_IMAGE_COMDAT_SELECT_ASSOCIATIVE  5
#define LC_IMAGE_COMDAT_SELECT_LARGEST      6

/* weak-external aux Characteristics */
#define LC_IMAGE_WEAK_EXTERN_SEARCH_NOLIBRARY 1
#define LC_IMAGE_WEAK_EXTERN_SEARCH_LIBRARY   2
#define LC_IMAGE_WEAK_EXTERN_SEARCH_ALIAS     3

/* ---- AMD64 relocation types ---- */
#define LC_IMAGE_REL_AMD64_ABSOLUTE  0x0000
#define LC_IMAGE_REL_AMD64_ADDR64    0x0001
#define LC_IMAGE_REL_AMD64_ADDR32    0x0002
#define LC_IMAGE_REL_AMD64_ADDR32NB  0x0003
#define LC_IMAGE_REL_AMD64_REL32     0x0004
#define LC_IMAGE_REL_AMD64_REL32_1   0x0005
#define LC_IMAGE_REL_AMD64_REL32_2   0x0006
#define LC_IMAGE_REL_AMD64_REL32_3   0x0007
#define LC_IMAGE_REL_AMD64_REL32_4   0x0008
#define LC_IMAGE_REL_AMD64_REL32_5   0x0009
#define LC_IMAGE_REL_AMD64_SECTION   0x000A
#define LC_IMAGE_REL_AMD64_SECREL    0x000B

typedef struct {
    uint32_t va;       /* VirtualAddress (offset within the section)   */
    uint32_t symidx;   /* SymbolTableIndex                             */
    uint16_t type;     /* LC_IMAGE_REL_AMD64_*                         */
} LcCoffReloc;

typedef struct {
    char           name[9];     /* NUL-terminated (8-byte names; long names
                                   resolved into the name pool, ptr below)  */
    const char    *name_long;   /* NULL unless name came from string table  */
    uint32_t       virtual_size;
    uint32_t       size_raw;    /* SizeOfRawData                            */
    uint32_t       ptr_raw;     /* PointerToRawData (0 == .bss-like)        */
    const uint8_t *data;        /* NULL when ptr_raw==0; else into file copy*/
    uint32_t       characteristics;
    LcCoffReloc   *relocs;
    uint32_t       nrelocs;
    /* COMDAT bookkeeping (filled after symbol parse): */
    int            is_comdat;       /* section has LNK_COMDAT                */
    int            comdat_selection;/* LC_IMAGE_COMDAT_SELECT_*              */
    int            comdat_symidx;   /* symtab index of the COMDAT defn symbol*/
} LcCoffSection;

typedef struct {
    const char *name;       /* NUL-terminated (name pool)                   */
    uint32_t    value;      /* Value field                                  */
    int32_t     section;    /* SectionNumber (1-based; 0 undef, -1 abs ...) */
    uint16_t    type;       /* Type (0x20 == function)                      */
    uint8_t     storage;    /* StorageClass                                 */
    uint8_t     naux;       /* NumberOfAuxSymbols                           */
    /* decoded weak-external aux (valid when storage==WEAK_EXTERNAL): */
    uint32_t    weak_default;       /* aux TagIndex: the fallback symbol idx */
    uint32_t    weak_characteristics;
    const uint8_t *aux;     /* raw pointer to the first aux record, or NULL */
} LcCoffSymbol;

typedef struct {
    uint8_t       *file;        /* owned copy of the whole object file      */
    size_t         file_len;
    LcCoffSection *sections;
    uint32_t       nsections;
    LcCoffSymbol  *symbols;     /* one entry per primary symbol slot; aux
                                   slots are skipped but counted in indices */
    uint32_t       nsymbols_slots;  /* raw symbol-slot count (incl. aux)    */
    char          *namepool;    /* owned; NUL-joined decoded names          */
    size_t         namepool_len;
    /* identity for diagnostics (archive member name, or file path) */
    char           origin[256];
} LcCoffObj;

/* Parse a COFF object from an in-memory buffer (copied internally).
** `origin` is a label used in error messages (path or archive member).
** Returns 1 on success (fills *out), 0 + message in err. */
int LcCoff_Parse( const uint8_t *buf, size_t len, const char *origin,
                  LcCoffObj *out, char *err, size_t errlen );

/* Parse a COFF object from a file path. */
int LcCoff_ParseFile( const char *path, LcCoffObj *out,
                      char *err, size_t errlen );

void LcCoff_Free( LcCoffObj *o );

/* Look up a symbol slot by raw index; returns NULL if the slot is an aux
** record or out of range. (Relocations name the primary slot index.) */
const LcCoffSymbol *LcCoff_SymByIndex( const LcCoffObj *o, uint32_t idx );

#endif /* LUAC_LINK_COFF_READ_H */
