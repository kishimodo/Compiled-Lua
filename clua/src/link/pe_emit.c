/*
** pe_emit.c — the CLua internal COFF -> PE64 linker. See pe_emit.h.
**
** Strategy: gather contributions (one per input-object section that is ALLOC),
** resolve the global symbol table to a fixpoint pulling archive members, lay
** the contributions out into the standard PE sections (grouped + $-sorted),
** assign RVAs, apply relocations, synthesize the import directory + IAT + base
** relocations, and emit a stripped console PE at ImageBase 0x140000000.
**
** Imports are SYNTHESIZED, not copied: when resolution needs a symbol that an
** import-library stub member would define (FOO / __imp_FOO), we register an
** import (dll, FOO) and define __imp_FOO -> a generated IAT slot and FOO -> a
** generated 6-byte `jmp [rip+__imp_FOO]` thunk. This handles both dlltool long
** members and IMPORT_OBJECT short members uniformly, and lets us build the
** .idata directory ourselves rather than stitching .idata$2..7 fragments.
*/
#include "link/pe_emit.h"
#include "link/coff_read.h"
#include "link/ar_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ---------------- tunables / PE constants ---------------- */
#define PE_IMAGE_BASE       0x140000000ULL
#define PE_SECT_ALIGN       0x1000u
#define PE_FILE_ALIGN       0x200u
#define PE_DEF_ENTRY        "mainCRTStartup"

#define DIR_EXPORT     0
#define DIR_IMPORT     1
#define DIR_EXCEPTION  3
#define DIR_BASERELOC  5
#define DIR_TLS        9
#define DIR_IAT        12
#define NUM_DIRS       16

/* ------------- a growable byte buffer ------------- */
typedef struct { uint8_t *p; size_t len, cap; } Buf;
static int b_need( Buf *b, size_t n ) {
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
static int b_putn( Buf *b, const void *s, size_t n ) {
    if ( !n ) return 1;
    if ( !b_need( b, n ) ) return 0;
    memcpy( b->p + b->len, s, n ); b->len += n; return 1;
}
static int b_zero( Buf *b, size_t n ) {
    if ( !b_need( b, n ) ) return 0;
    memset( b->p + b->len, 0, n ); b->len += n; return 1;
}
static int b_pad( Buf *b, size_t align ) {
    while ( b->len % align ) if ( !b_zero( b, 1 ) ) return 0;
    return 1;
}

/* in-place little-endian writers at an offset */
static void w16( uint8_t *p, uint16_t v ) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void w32( uint8_t *p, uint32_t v ) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24); }
static void w64( uint8_t *p, uint64_t v ) { w32(p,(uint32_t)v); w32(p+4,(uint32_t)(v>>32)); }

/* ---------------- output-section model ----------------
** The final PE has a fixed set of output sections. Each input contribution
** (an ALLOC section from an object) is appended into one of these, recording
** its assigned offset so relocations can be resolved later. */
enum { OS_TEXT, OS_RDATA, OS_DATA, OS_PDATA, OS_XDATA, OS_BSS,
       OS_TLS, OS_IDATA, OS_RELOC, OS_COUNT };

typedef struct {
    const char *name;
    uint32_t    characteristics;
    Buf         raw;        /* file-backed bytes (BSS/idata/reloc handled
                               specially) */
    uint32_t    virt_size;  /* may exceed raw.len (BSS tail)               */
    uint32_t    rva;        /* assigned during layout                      */
    uint32_t    file_off;   /* assigned during layout                      */
    uint32_t    file_size;  /* aligned raw size on disk                    */
    int         present;
} OutSec;

/* one input section placed into an output section */
typedef struct {
    LcCoffObj  *obj;          /* owning object                              */
    uint32_t    sec_index;    /* index into obj->sections                   */
    int         out;          /* OS_*                                       */
    uint32_t    out_off;      /* offset within the output section's raw     */
    int         dropped;      /* COMDAT duplicate / discarded               */
    char        group[24];    /* base group key for $-sorting (e.g. ".text")*/
    char        suffix[24];   /* the part after '$' for sort, "" if none    */
} Contrib;

/* how a synthesized linker symbol's RVA is derived at finalize time */
enum {
    SYN_NONE = 0,
    SYN_IMAGEBASE,      /* RVA 0 (== ImageBase)                              */
    SYN_SEC_START,      /* start RVA of output section `syn_sec`             */
    SYN_SEC_END         /* end   RVA of output section `syn_sec`            */
};

/* a globally-resolved symbol */
typedef struct {
    char       *name;
    int         defined;
    /* definition: either a placed section + offset, or an absolute value */
    int         is_abs;
    uint64_t    abs_value;
    LcCoffObj  *obj;
    uint32_t    sec_index;     /* index into obj->sections                  */
    uint32_t    value;         /* symbol Value (offset within its section)  */
    /* resolved address (filled at layout): rva of the definition           */
    uint32_t    rva;
    int         is_import_thunk; /* FOO -> generated jmp thunk              */
    int         is_import_iat;   /* __imp_FOO -> generated IAT slot         */
    uint32_t    import_index;     /* index into L->imports                  */
    int         is_common;
    uint32_t    common_size;
    int         weak;
    char       *weak_default;     /* fallback symbol name, if weak          */
    int         force_resolve;    /* -u root: drive archive extraction even
                                  ** if only weak-referenced elsewhere       */
    int         synth;            /* SYN_*                                   */
    int         syn_sec;          /* OS_* for SYN_SEC_*                      */
} GSym;

/* a synthesized import (dll, exported function). `func` is the name written
** into the hint/name table (the DLL's real export, which may differ from the
** local symbol — e.g. moldname alias __set_app_type -> export _set_app_type). */
typedef struct {
    char     *dll;
    char     *func;        /* real DLL export name (for .idata$6 hint/name) */
    uint16_t  hint;
    uint32_t  iat_rva;     /* RVA of this import's IAT slot                 */
    uint32_t  hintname_rva;
    uint32_t  thunk_rva;   /* RVA of the generated jmp thunk (FOO)         */
} ImportEntry;

/* a base relocation site (DIR64) */
typedef struct { uint32_t rva; } RelocSite;

/* Stable indexes used throughout the link. They store integer indexes rather
** than pointers because both the symbol and contribution arrays can realloc. */
typedef struct { LcCoffObj *obj; uint32_t sec; int contrib; } GcSlot;
typedef struct { GcSlot *slots; uint32_t cap; } GcMap;

typedef struct {
    /* loaded objects (explicit + pulled archive members) */
    LcCoffObj **objs;
    int         nobjs, capobjs;

    /* archives, opened lazily */
    LcArchive  *archives;
    int         narchives;
    /* per-archive head_symbol->dll maps (built once, lazily) */
    void      **head_maps;     /* HeadDllPair* per archive                   */
    int        *head_map_n;    /* entry count per archive                    */
    int        *head_map_done; /* built flag per archive                     */
    int        *ar_is_implib;  /* per archive: 1 import-lib, 0 object, -1 ?  */
    void      **ar_pulled;     /* per archive: set of pulled member hdr_offs */
    int        *ar_npulled;
    int        *ar_cappulled;

    /* global symbol map */
    GSym       *syms;
    int         nsyms, capsyms;
    uint32_t   *sym_slots;       /* open-addressed slots: symbol index + 1   */
    uint32_t    sym_slot_cap;

    /* contributions */
    Contrib    *contribs;
    int         ncontribs, capcontribs;
    GcMap       contrib_map;     /* (object, section) -> contribution index  */

    OutSec      out[OS_COUNT];

    ImportEntry *imports;
    int          nimports, capimports;

    RelocSite   *relocs;
    int          nrelocs, caprelocs;

    const char  *entry;
    uint64_t     image_base;
    int          gc_sections;   /* run dead-section elimination (default 1)  */

    char        err[512];
} Linker;

static int lerr( Linker *L, const char *fmt, const char *a ) {
    snprintf( L->err, sizeof( L->err ), fmt, a ? a : "" );
    return 0;
}

/* ---------------- global symbol table ---------------- */
static uint32_t gsym_hash( const char *name ) {
    uint32_t h = 2166136261u;
    const unsigned char *p = ( const unsigned char * )name;
    while ( *p ) { h ^= *p++; h *= 16777619u; }
    return h;
}

static int gsym_rehash( Linker *L, uint32_t new_cap ) {
    uint32_t *slots;
    int i;
    if ( new_cap < 512 ) new_cap = 512;
    slots = ( uint32_t * )calloc( new_cap, sizeof( uint32_t ) );
    if ( !slots ) return 0;
    for ( i = 0; i < L->nsyms; i++ ) {
        uint32_t p = gsym_hash( L->syms[i].name ) & ( new_cap - 1 );
        while ( slots[p] != 0 ) p = ( p + 1 ) & ( new_cap - 1 );
        slots[p] = ( uint32_t )i + 1;
    }
    free( L->sym_slots );
    L->sym_slots = slots;
    L->sym_slot_cap = new_cap;
    return 1;
}

static GSym *gsym_find( Linker *L, const char *name ) {
    uint32_t p;
    if ( L->sym_slot_cap == 0 ) return NULL;
    p = gsym_hash( name ) & ( L->sym_slot_cap - 1 );
    for ( ;; ) {
        uint32_t slot = L->sym_slots[p];
        if ( slot == 0 ) return NULL;
        if ( strcmp( L->syms[ slot - 1 ].name, name ) == 0 )
            return &L->syms[ slot - 1 ];
        p = ( p + 1 ) & ( L->sym_slot_cap - 1 );
    }
}

static void gsym_index_insert( Linker *L, const char *name, uint32_t index ) {
    uint32_t p = gsym_hash( name ) & ( L->sym_slot_cap - 1 );
    while ( L->sym_slots[p] != 0 ) p = ( p + 1 ) & ( L->sym_slot_cap - 1 );
    L->sym_slots[p] = index + 1;
}

static GSym *gsym_intern( Linker *L, const char *name ) {
    GSym *g;
    char *copy;
    int index;
    g = gsym_find( L, name );
    if ( g ) return g;
    if ( L->sym_slot_cap == 0 ||
         ( ( ( uint64_t )L->nsyms + 1u ) * 10u >=
           ( uint64_t )L->sym_slot_cap * 7u ) ) {
        uint32_t nc = L->sym_slot_cap ? L->sym_slot_cap << 1 : 512;
        if ( nc < L->sym_slot_cap || !gsym_rehash( L, nc ) ) return NULL;
    }
    copy = _strdup( name );
    if ( !copy ) return NULL;
    if ( L->nsyms >= L->capsyms ) {
        int nc = L->capsyms ? L->capsyms * 2 : 256;
        GSym *ns = ( GSym * )realloc( L->syms, nc * sizeof( GSym ) );
        if ( !ns ) { free( copy ); return NULL; }
        L->syms = ns; L->capsyms = nc;
    }
    index = L->nsyms++;
    g = &L->syms[ index ];
    memset( g, 0, sizeof( *g ) );
    g->name = copy;
    gsym_index_insert( L, name, ( uint32_t )index );
    return g;
}

/* ---------------- a string-dup that doesn't depend on _strdup spelling --- */
#ifndef _strdup
/* MinGW provides _strdup; keep a fallback if a stricter libc is used. */
#endif

/* ---------------- imports ---------------- */
static int import_add( Linker *L, const char *dll, const char *func, uint16_t hint,
                       uint32_t *idx_out ) {
    int i;
    for ( i = 0; i < L->nimports; i++ ) {
        if ( strcmp( L->imports[i].func, func ) == 0 &&
             _stricmp( L->imports[i].dll, dll ) == 0 ) { *idx_out = ( uint32_t )i; return 1; }
    }
    if ( L->nimports >= L->capimports ) {
        int nc = L->capimports ? L->capimports * 2 : 64;
        ImportEntry *ni = ( ImportEntry * )realloc( L->imports, nc * sizeof( ImportEntry ) );
        if ( !ni ) return 0;
        L->imports = ni; L->capimports = nc;
    }
    memset( &L->imports[ L->nimports ], 0, sizeof( ImportEntry ) );
    L->imports[ L->nimports ].dll  = _strdup( dll );
    L->imports[ L->nimports ].func = _strdup( func );
    L->imports[ L->nimports ].hint = hint;
    *idx_out = ( uint32_t )L->nimports;
    L->nimports++;
    return 1;
}

/* ---------------- base relocation sites ---------------- */
static int reloc_add( Linker *L, uint32_t rva ) {
    if ( L->nrelocs >= L->caprelocs ) {
        int nc = L->caprelocs ? L->caprelocs * 2 : 256;
        RelocSite *nr = ( RelocSite * )realloc( L->relocs, nc * sizeof( RelocSite ) );
        if ( !nr ) return 0;
        L->relocs = nr; L->caprelocs = nc;
    }
    L->relocs[ L->nrelocs++ ].rva = rva;
    return 1;
}

/* ===================================================================
** Import-library stub detection.
**
** A dlltool import member that defines symbol FOO is recognizable: it has an
** .idata$5 section and (usually) a .text jmp thunk, plus an iname backpointer
** symbol of the form __<...>_iname (e.g. __lib64_libkernel32_a_iname) or
** _head_<...>. The DLL name lives in the head member's .idata$7. An IMPORT
** OBJECT short member uses a different on-disk shape (handled separately).
**
** Rather than re-derive the DLL per member, we precompute, per archive, the
** DLL name once from the head member; every stub member in that archive
** belongs to that DLL.
=================================================================== */

/* An archive may host members for MANY DLLs (libucrt.a covers a dozen
** api-ms-win-crt-*.dll). Each function stub member's .idata$7 carries an
** ADDR32NB reloc to a _head_<lib>_a symbol; the head member that defines that
** symbol holds the DLL-name string in its own .idata$7. We build, per archive,
** a map head_symbol -> dllname by scanning every member: a member that defines
** a _head_* (or *_iname) symbol and has a printable .idata$7 string is a head.
** A fallback "*" entry records the first dll found (single-DLL import libs like
** libkernel32.a where the head member defines no _head_ symbol of its own). */
typedef struct { char head[256]; char dll[128]; } HeadDllPair;

/* Normalize an import-descriptor anchor symbol to a stable lib key so the
** head member's iname/_head symbols and a function member's reloc target map
** to the same bucket. dlltool emits, for libfoo.a:
**   head:  __lib<bits>_libfoo_a_iname  and  _head_lib<bits>_libfoo_a
**   ref:   _head_lib<bits>_libfoo_a (ADDR32NB in the stub's .idata$7)
** We strip the leading _head_/__/_ and any trailing _iname so both collapse to
** "lib<bits>_libfoo_a". */
static void normalize_lib_key( const char *sym, char *out, size_t outlen ) {
    const char *p = sym;
    size_t n;
    while ( *p == '_' ) p++;            /* drop leading underscores           */
    if ( strncmp( p, "head_", 5 ) == 0 ) p += 5;
    snprintf( out, outlen, "%s", p );
    n = strlen( out );
    if ( n > 6 && strcmp( out + n - 6, "_iname" ) == 0 ) out[ n - 6 ] = '\0';
}

static int section_idata7_string( LcCoffObj *o, char *out, size_t outlen ) {
    uint32_t s;
    for ( s = 0; s < o->nsections; s++ ) {
        const char *sn = o->sections[s].name_long ? o->sections[s].name_long : o->sections[s].name;
        if ( strcmp( sn, ".idata$7" ) == 0 && o->sections[s].data &&
             o->sections[s].size_raw >= 4 ) {
            const char *str = ( const char * )o->sections[s].data;
            size_t k = strnlen( str, o->sections[s].size_raw );
            int ok = 1; size_t j;
            if ( k < 4 || k >= outlen ) continue;
            for ( j = 0; j < k; j++ ) {
                unsigned char c = ( unsigned char )str[j];
                if ( c < 0x20 || c > 0x7e ) { ok = 0; break; }
            }
            if ( ok && strstr( str, "." ) ) { snprintf( out, outlen, "%s", str ); return 1; }
        }
    }
    return 0;
}

/* Build the head->dll map for an archive. Stored on the LcArchive's caller
** side; here we return a malloc'd array (caller frees). */
static HeadDllPair *archive_head_map( LcArchive *a, int *count_out ) {
    HeadDllPair *map = NULL;
    int n = 0, cap = 0;
    uint32_t m;
    for ( m = 0; m < a->nmembers; m++ ) {
        LcCoffObj o;
        char err[128];
        char dll[128];
        const LcArMember *mem = &a->members[m];
        uint32_t s;
        if ( !LcCoff_Parse( mem->data, mem->size, mem->name, &o, err, sizeof err ) ) continue;
        if ( section_idata7_string( &o, dll, sizeof dll ) ) {
            /* find the _head_* / *_iname symbol this member defines */
            for ( s = 0; s < o.nsymbols_slots; s++ ) {
                const LcCoffSymbol *sy = LcCoff_SymByIndex( &o, s );
                if ( !sy || !sy->name[0] || sy->section <= 0 ) continue;
                if ( strncmp( sy->name, "_head_", 6 ) == 0 || strstr( sy->name, "_iname" ) ) {
                    int dup = 0, q;
                    char key[256];
                    normalize_lib_key( sy->name, key, sizeof key );
                    for ( q = 0; q < n; q++ ) if ( strcmp( map[q].head, key ) == 0 ) { dup = 1; break; }
                    if ( dup ) continue;
                    if ( n >= cap ) {
                        int nc = cap ? cap * 2 : 16;
                        HeadDllPair *np = ( HeadDllPair * )realloc( map, nc * sizeof( HeadDllPair ) );
                        if ( !np ) { LcCoff_Free( &o ); *count_out = n; return map; }
                        map = np; cap = nc;
                    }
                    snprintf( map[n].head, sizeof map[n].head, "%s", key );  /* normalized */
                    snprintf( map[n].dll,  sizeof map[n].dll,  "%s", dll );
                    n++;
                }
            }
        }
        LcCoff_Free( &o );
    }
    *count_out = n;
    return map;
}

/* Resolve a stub member's DLL: read its .idata$7 ADDR32NB reloc target symbol
** (_head_<lib>) and look it up in the head map. Falls back to the member's own
** .idata$7 string, then to the first map entry (single-DLL archives). */
static int member_dll_name( const LcArMember *mem, const HeadDllPair *map, int nmap,
                            char *out, size_t outlen ) {
    LcCoffObj o;
    char err[128];
    uint32_t s;
    int found = 0;
    out[0] = '\0';
    if ( !LcCoff_Parse( mem->data, mem->size, mem->name, &o, err, sizeof err ) ) return 0;

    /* its own .idata$7 string? (head members / simple libs) */
    if ( section_idata7_string( &o, out, outlen ) ) { LcCoff_Free( &o ); return 1; }

    /* follow the .idata$7 reloc to a _head_ symbol */
    for ( s = 0; s < o.nsections && !found; s++ ) {
        const char *sn = o.sections[s].name_long ? o.sections[s].name_long : o.sections[s].name;
        if ( strcmp( sn, ".idata$7" ) == 0 ) {
            uint32_t r;
            for ( r = 0; r < o.sections[s].nrelocs; r++ ) {
                const LcCoffSymbol *t = LcCoff_SymByIndex( &o, o.sections[s].relocs[r].symidx );
                char key[256];
                int i;
                if ( !t || !t->name[0] ) continue;
                normalize_lib_key( t->name, key, sizeof key );
                for ( i = 0; i < nmap; i++ ) {
                    if ( strcmp( map[i].head, key ) == 0 ) {
                        snprintf( out, outlen, "%s", map[i].dll );
                        found = 1; break;
                    }
                }
                if ( found ) break;
            }
        }
    }
    LcCoff_Free( &o );
    if ( !found && nmap > 0 ) { snprintf( out, outlen, "%s", map[0].dll ); return 1; }
    return found;
}

/* Is this member an import stub defining `want` (or __imp_want)? If so, return
** the REAL exported function name (from .idata$6's hint/name entry, which can
** differ from the symbol name — e.g. the moldname alias __set_app_type whose
** DLL export is _set_app_type) in func_out, and the 2-byte hint in *hint_out.
** Falls back to the stripped symbol name when .idata$6 is absent. */
static int member_is_import_stub( const LcArMember *mem, const char *want,
                                  char *func_out, size_t func_outlen,
                                  uint16_t *hint_out ) {
    LcCoffObj o;
    char err[128];
    uint32_t s;
    int has_idata5 = 0, has_iname = 0, defines = 0;
    const char *idata6 = NULL;
    uint32_t idata6_len = 0;

    if ( hint_out ) *hint_out = 0;
    if ( !LcCoff_Parse( mem->data, mem->size, mem->name, &o, err, sizeof err ) )
        return 0;
    for ( s = 0; s < o.nsections; s++ ) {
        const char *sn = o.sections[s].name_long ? o.sections[s].name_long : o.sections[s].name;
        if ( strncmp( sn, ".idata$5", 8 ) == 0 ) has_idata5 = 1;
        if ( strcmp( sn, ".idata$6" ) == 0 && o.sections[s].data ) {
            idata6 = ( const char * )o.sections[s].data;
            idata6_len = o.sections[s].size_raw;
        }
    }
    for ( s = 0; s < o.nsymbols_slots; s++ ) {
        const LcCoffSymbol *sy = LcCoff_SymByIndex( &o, s );
        if ( !sy || !sy->name[0] ) continue;
        if ( strstr( sy->name, "_iname" ) || strncmp( sy->name, "_head_", 6 ) == 0 )
            has_iname = 1;
        if ( strcmp( sy->name, want ) == 0 ) defines = 1;
    }

    if ( ( has_idata5 || has_iname ) && defines ) {
        /* prefer .idata$6: hint(2) + NUL-terminated export name */
        if ( idata6 && idata6_len >= 3 ) {
            const char *nm = idata6 + 2;
            size_t nlen = strnlen( nm, idata6_len - 2 );
            if ( nlen > 0 && nlen < func_outlen ) {
                if ( hint_out ) *hint_out = ( uint16_t )( ( unsigned char )idata6[0] |
                                                          ( ( unsigned char )idata6[1] << 8 ) );
                memcpy( func_out, nm, nlen ); func_out[nlen] = '\0';
                LcCoff_Free( &o );
                return 1;
            }
        }
        /* fallback: the symbol name with __imp_ stripped */
        snprintf( func_out, func_outlen, "%s",
                  strncmp( want, "__imp_", 6 ) == 0 ? want + 6 : want );
        LcCoff_Free( &o );
        return 1;
    }
    LcCoff_Free( &o );
    return 0;
}

/* ===================================================================
** Object loading: register a parsed object's defined symbols (first
** definition wins) and remember its undefined externals as references.
=================================================================== */

/* Should this section contribute to the image? Skip LNK_INFO/REMOVE and the
** import-stub .idata$* / .drectve (we synthesize imports). */
static int section_is_alloc( const LcCoffSection *sc ) {
    const char *n = sc->name_long ? sc->name_long : sc->name;
    if ( sc->characteristics & ( LC_IMAGE_SCN_LNK_INFO | LC_IMAGE_SCN_LNK_REMOVE ) )
        return 0;
    if ( strncmp( n, ".idata$", 7 ) == 0 ) return 0; /* synthesized */
    if ( strcmp( n, ".drectve" ) == 0 ) return 0;
    if ( strncmp( n, ".debug", 6 ) == 0 ) return 0;
    /* must be code or data (init or uninit) */
    if ( sc->characteristics & ( LC_IMAGE_SCN_CNT_CODE |
                                 LC_IMAGE_SCN_CNT_INITIALIZED_DATA |
                                 LC_IMAGE_SCN_CNT_UNINIT_DATA ) )
        return 1;
    return 0;
}

/* Register one object's symbols into the global table. `from_archive` marks
** members so we don't redefine on a re-scan. Returns 1 ok. */
static int load_object_syms( Linker *L, LcCoffObj *o ) {
    uint32_t s;
    for ( s = 0; s < o->nsymbols_slots; s++ ) {
        const LcCoffSymbol *sy = LcCoff_SymByIndex( o, s );
        GSym *g;
        if ( !sy || !sy->name[0] ) continue;
        if ( sy->storage == LC_IMAGE_SYM_CLASS_FILE ) continue;
        if ( sy->storage == LC_IMAGE_SYM_CLASS_STATIC && sy->section >= 1 ) {
            /* section symbols (.text/.rdata defs) are local; only register
            ** named statics that aren't section names */
            const char *sn = ( sy->section >= 1 && ( uint32_t )sy->section <= o->nsections )
                ? ( o->sections[sy->section-1].name_long ? o->sections[sy->section-1].name_long
                                                         : o->sections[sy->section-1].name )
                : "";
            if ( strcmp( sy->name, sn ) == 0 ) continue; /* a section symbol */
        }

        if ( sy->storage == LC_IMAGE_SYM_CLASS_EXTERNAL ||
             sy->storage == LC_IMAGE_SYM_CLASS_WEAK_EXTERNAL ) {

            if ( sy->section > 0 ) {
                /* a real definition */
                g = gsym_intern( L, sy->name );
                if ( !g ) return 0;
                if ( !g->defined ) {
                    g->defined  = 1;
                    g->obj      = o;
                    g->sec_index= ( uint32_t )( sy->section - 1 );
                    g->value    = sy->value;
                    g->weak     = 0;
                }
            } else if ( sy->section == LC_IMAGE_SYM_UNDEFINED && sy->value != 0 ) {
                /* COMMON symbol (size in Value) -> tentative def into .bss */
                g = gsym_intern( L, sy->name );
                if ( !g ) return 0;
                if ( !g->defined ) {
                    g->is_common   = 1;
                    g->common_size = sy->value;
                    /* not 'defined' yet: a real def elsewhere wins; commons
                    ** are committed after resolution */
                }
            } else if ( sy->storage == LC_IMAGE_SYM_CLASS_WEAK_EXTERNAL ) {
                /* weak external: record the fallback default symbol */
                g = gsym_intern( L, sy->name );
                if ( !g ) return 0;
                if ( !g->defined ) {
                    const LcCoffSymbol *def = LcCoff_SymByIndex( o, sy->weak_default );
                    g->weak = 1;
                    free( g->weak_default );
                    g->weak_default = ( def && def->name[0] ) ? _strdup( def->name ) : NULL;
                }
            } else {
                /* plain undefined external: just intern (a reference) */
                if ( !gsym_intern( L, sy->name ) ) return 0;
            }
        }
    }
    return 1;
}

static int linker_add_object( Linker *L, LcCoffObj *o ) {
    if ( L->nobjs >= L->capobjs ) {
        int nc = L->capobjs ? L->capobjs * 2 : 16;
        LcCoffObj **no = ( LcCoffObj ** )realloc( L->objs, nc * sizeof( LcCoffObj * ) );
        if ( !no ) return 0;
        L->objs = no; L->capobjs = nc;
    }
    L->objs[ L->nobjs++ ] = o;
    return load_object_syms( L, o );
}

static int load_object_file( Linker *L, const char *path ) {
    LcCoffObj *o = ( LcCoffObj * )calloc( 1, sizeof( LcCoffObj ) );
    char err[256];
    if ( !o ) return lerr( L, "oom", NULL );
    if ( !LcCoff_ParseFile( path, o, err, sizeof err ) ) {
        free( o );
        return lerr( L, "%s", err );
    }
    if ( !linker_add_object( L, o ) ) { LcCoff_Free( o ); free( o ); return lerr( L, "oom adding %s", path ); }
    return 1;
}

/* Has this symbol got an unresolved reference we must satisfy by pulling an
** archive member? Mirrors ld: a WEAK undefined reference does NOT drive
** archive extraction (it resolves to its default / 0 if never strongly
** defined). A `-u` force-undef root DOES drive extraction even when only
** weak-referenced (force_resolve). */
static int sym_unresolved( const GSym *g ) {
    if ( g->defined ) return 0;
    if ( g->is_import_thunk || g->is_import_iat ) return 0;
    if ( g->is_common ) return 0;          /* committed to .bss later        */
    if ( g->is_abs ) return 0;
    if ( g->weak && !g->force_resolve ) return 0; /* weak: don't pull archives */
    return 1;
}

/* Try to resolve `name` from a single import library archive (synthesize an
** import). Returns 1 if satisfied. */
static int try_resolve_import( Linker *L, LcArchive *a, const char *dllname,
                               const char *name ) {
    const LcArMember *mem;
    char export_name[256];   /* the DLL's real export (for the hint/name)    */
    char local[300];         /* the local symbol name (what code references) */
    uint16_t hint = 0;
    uint32_t imp_idx;
    GSym *g;

    /* the LOCAL symbol code binds to: `name` with __imp_ stripped */
    snprintf( local, sizeof local, "%s",
              strncmp( name, "__imp_", 6 ) == 0 ? name + 6 : name );

    mem = LcAr_MemberDefining( a, name );
    if ( !mem ) return 0;
    if ( !member_is_import_stub( mem, name, export_name, sizeof export_name, &hint ) )
        return 0;

    if ( !import_add( L, dllname, export_name, hint, &imp_idx ) ) return 0;

    /* define both __imp_<local> (IAT slot) and <local> (jmp thunk), keyed by
    ** the LOCAL name so the references resolve, while the import's hint/name
    ** uses the real export. */
    {
        char impname[320];
        snprintf( impname, sizeof impname, "__imp_%s", local );
        g = gsym_intern( L, impname );
        if ( !g ) return 0;
        g->is_import_iat = 1; g->import_index = imp_idx; g->defined = 1;
    }
    g = gsym_intern( L, local );
    if ( !g ) return 0;
    g->is_import_thunk = 1; g->import_index = imp_idx; g->defined = 1;
    return 1;
}

/* ===================================================================
** Archive resolution to a fixpoint. Explicit objects are already loaded, so
** their definitions shadow archive members (first-definition-wins). Each pass:
**   for every still-unresolved symbol, search each archive in order; if a
**   member defines it, pull that member (load its object + symbols, which may
**   create new undefineds) or synthesize an import. Repeat until a pass pulls
**   nothing.
=================================================================== */
static int pull_member_object( Linker *L, LcArchive *a, const LcArMember *mem ) {
    LcCoffObj *o = ( LcCoffObj * )calloc( 1, sizeof( LcCoffObj ) );
    char err[256];
    char origin[600];
    if ( !o ) return -1;
    snprintf( origin, sizeof origin, "%s(%s)", a->path, mem->name );
    if ( !LcCoff_Parse( mem->data, mem->size, origin, o, err, sizeof err ) ) {
        free( o );
        snprintf( L->err, sizeof L->err, "%s", err );
        return -1;
    }
    if ( !linker_add_object( L, o ) ) { LcCoff_Free( o ); free( o ); return -1; }
    return 1;
}

/* Define a synthesized linker symbol (only if not already a real definition).
** These are the ld-script-provided anchors the MinGW CRT references. */
static int def_synth( Linker *L, const char *name, int syn, int os ) {
    GSym *g = gsym_intern( L, name );
    if ( !g ) return 0;
    if ( g->defined ) return 1;          /* a real object already defined it */
    g->defined = 1;
    g->synth   = syn;
    g->syn_sec = os;
    return 1;
}

/* After contributions are gathered, define linker symbols the CRT needs.
** __ImageBase is RVA 0. The CTOR/DTOR/pseudo-reloc list brackets and the TLS
** index/callback anchors are normally provided by crtbegin/crtend objects in
** the input; we synthesize the remaining ones (section start/end) as a safety
** net so the link doesn't fail when a particular CRT build omits one. */
static int define_linker_symbols( Linker *L ) {
    if ( !def_synth( L, "__ImageBase", SYN_IMAGEBASE, 0 ) ) return 0;
    if ( !def_synth( L, "__image_base__", SYN_IMAGEBASE, 0 ) ) return 0;
    if ( !def_synth( L, "_image_base__", SYN_IMAGEBASE, 0 ) ) return 0;
    return 1;
}

/* lazily build + cache the head->dll map for archive `a` */
static HeadDllPair *archive_head_map_cached( Linker *L, int a, int *n_out ) {
    if ( !L->head_map_done[a] ) {
        int n = 0;
        L->head_maps[a] = archive_head_map( &L->archives[a], &n );
        L->head_map_n[a] = n;
        L->head_map_done[a] = 1;
    }
    *n_out = L->head_map_n[a];
    return ( HeadDllPair * )L->head_maps[a];
}

/* Classify an archive as an import library (1) or an object archive (0), ONCE.
** An import library's members carry .idata$* sections + an iname; a regular
** object archive does not. We sample the member that the head map was built
** from: if the archive yielded any head->dll entries, it's an import lib. */
static int archive_is_implib( Linker *L, int a ) {
    if ( L->ar_is_implib[a] == -1 ) {
        int n = 0;
        archive_head_map_cached( L, a, &n );
        L->ar_is_implib[a] = ( n > 0 ) ? 1 : 0;
    }
    return L->ar_is_implib[a];
}

/* Has member at hdr_off already been pulled from archive a? Records it if not. */
static int already_pulled( Linker *L, int a, uint32_t hdr_off ) {
    uint32_t *set = ( uint32_t * )L->ar_pulled[a];
    int i;
    for ( i = 0; i < L->ar_npulled[a]; i++ ) if ( set[i] == hdr_off ) return 1;
    if ( L->ar_npulled[a] >= L->ar_cappulled[a] ) {
        int nc = L->ar_cappulled[a] ? L->ar_cappulled[a] * 2 : 64;
        uint32_t *ns = ( uint32_t * )realloc( set, nc * sizeof( uint32_t ) );
        if ( !ns ) return 1; /* fail-safe: treat as pulled to avoid loop */
        L->ar_pulled[a] = ns; set = ns; L->ar_cappulled[a] = nc;
    }
    set[ L->ar_npulled[a]++ ] = hdr_off;
    return 0;
}

/* CLUA_GC_DEBUG: report what archive symbol resolution actually cost.
**
** The loop below asks every archive about every unresolved symbol, and the outer
** fixpoint restarts from symbol 0 after every pull, so unresolved symbols are
** re-queried once per round -- 25,114 archive queries for one Rover link.
**
** `compares` now counts strcmps along a HASH PROBE CHAIN, not armap entries
** walked: LcAr_MemberDefining builds a per-archive index on first query. A
** healthy link therefore reports about 1 compare per query. A figure in the
** thousands means either the index degraded to the linear fallback (allocation
** failure) or the hash has collapsed -- the "on the fallback scan" line below
** distinguishes the two. Before the index this read ~1,634 per query, which was
** ~43% of a warm build. See docs/benchmarks/archive-symbol-lookup.md.
**
** One getenv per link, not per lookup. */
static void ar_report_stats( const Linker *L, int rounds ) {
    unsigned long long queries = 0, compares = 0, matched = 0, hits = 0;
    unsigned long long mem_lookups = 0, mem_compares = 0;
    unsigned long long entries = 0, members = 0;
    int fallback = 0;
    int i;

    if ( !getenv( "CLUA_GC_DEBUG" ) ) return;

    for ( i = 0; i < L->narchives; i++ ) {
        const LcArStats *s = &L->archives[i].stats;
        /* -1 means the index could not be built (allocation failure, or an
        ** archive with no entries) and lookups fell back to the linear scan.
        ** Report it: a silent degradation looks exactly like a slow machine. */
        if ( L->archives[i].sym_index_state == -1 ||
             L->archives[i].mem_index_state == -1 ) fallback++;
        queries      += s->queries;
        compares     += s->compares;
        matched      += s->matched;
        hits         += s->hits;
        mem_lookups  += s->mem_lookups;
        mem_compares += s->mem_compares;
        entries      += L->archives[i].nindex;
        members      += L->archives[i].nmembers;
    }

    fprintf( stderr, "[ar] %d archive(s), %llu armap entries, %llu members, "
                     "%d fixpoint round(s)\n", L->narchives, entries, members,
             rounds );
    /* "queries" counts (symbol, archive) pairs: one scan of one archive's
    ** index. A single symbol resolution asks several archives in turn, so
    ** queries exceed resolutions by roughly the archive count -- the label says
    ** so because dividing by the wrong denominator overstates the per-scan cost
    ** by an order of magnitude. */
    fprintf( stderr, "[ar] archive queries %llu (%llu answered, %llu missed), "
                     "%llu name compares", queries, hits, queries - hits,
             compares );
    if ( queries ) fprintf( stderr, " (%llu per query)", compares / queries );
    fprintf( stderr, "\n[ar] member lookups %llu, %llu member compares\n",
             mem_lookups, mem_compares );
    /* A name that matched an armap entry naming no real member means the archive
    ** is malformed; it would otherwise hide inside an ordinary-looking tally. */
    if ( matched != hits )
        fprintf( stderr, "[ar] WARNING: %llu armap entr%s matched a name but "
                         "named no member\n", matched - hits,
                 ( matched - hits ) == 1 ? "y" : "ies" );
    if ( fallback )
        fprintf( stderr, "[ar] %d archive(s) on the linear fallback scan "
                         "(no index built)\n", fallback );
}

static int resolve_fixpoint( Linker *L ) {
    int changed = 1;
    int rounds  = 0;

    while ( changed ) {
        int i;
        changed = 0;
        rounds++;
        /* Walk every currently-known symbol. Pulling a member can append new
        ** symbols (handled by the outer while + nsyms re-read each pass) and
        ** realloc the array, so re-index L->syms[i] every iteration and never
        ** hold a GSym* across a pull. */
        for ( i = 0; i < L->nsyms; i++ ) {
            char namebuf[300];
            int a;
            if ( !sym_unresolved( &L->syms[i] ) ) continue;
            snprintf( namebuf, sizeof namebuf, "%s", L->syms[i].name );

            for ( a = 0; a < L->narchives; a++ ) {
                LcArchive *ar = &L->archives[a];
                const LcArMember *mem = LcAr_MemberDefining( ar, namebuf );
                char func[256];
                uint16_t hint = 0;
                if ( !mem ) continue;

                /* Mixed archives (libucrt.a) host BOTH import stubs (api-ms-*)
                ** AND regular objects (ucrt_fprintf.o). Classify the DEFINING
                ** member, not the archive: only import-lib archives are even
                ** worth the stub probe (cheap guard via the cached flag). */
                if ( archive_is_implib( L, a ) &&
                     member_is_import_stub( mem, namebuf, func, sizeof func, &hint ) ) {
                    int nmap = 0;
                    HeadDllPair *map = archive_head_map_cached( L, a, &nmap );
                    char dll[128];
                    if ( member_dll_name( mem, map, nmap, dll, sizeof dll ) && dll[0] ) {
                        if ( try_resolve_import( L, ar, dll, namebuf ) ) { changed = 1; break; }
                    }
                } else {
                    /* regular object member: pull it once */
                    int r;
                    if ( already_pulled( L, a, mem->hdr_off ) ) continue;
                    r = pull_member_object( L, ar, mem );
                    if ( r < 0 ) return 0;
                    if ( r > 0 ) { changed = 1; break; }
                }
            }
            if ( changed ) break; /* array may have moved; restart the pass */
        }
    }
    ar_report_stats( L, rounds );
    return 1;
}

/* ===================================================================
** Map an input section name to an output section + group/suffix key.
=================================================================== */
static int classify_section( const char *name, uint32_t characteristics,
                             char *group, size_t glen,
                             char *suffix, size_t slen ) {
    const char *dollar = strchr( name, '$' );
    int out;
    /* split group$suffix */
    if ( dollar ) {
        size_t gl = ( size_t )( dollar - name );
        if ( gl >= glen ) gl = glen - 1;
        memcpy( group, name, gl ); group[gl] = '\0';
        snprintf( suffix, slen, "%s", dollar + 1 );
    } else {
        snprintf( group, glen, "%s", name );
        suffix[0] = '\0';
    }

    /* ANY executable-code section belongs in .text regardless of name
    ** (.text.unlikely, .gnu.linkonce.t.*, .glue_7, etc.) — otherwise a
    ** function lands in non-executable .rdata and faults when called (NX). */
    if ( characteristics & LC_IMAGE_SCN_MEM_EXECUTE ) return OS_TEXT;
    if ( characteristics & LC_IMAGE_SCN_CNT_CODE )    return OS_TEXT;

    if      ( strcmp( group, ".text" )  == 0 ) out = OS_TEXT;
    else if ( strcmp( group, ".rdata" ) == 0 ) out = OS_RDATA;
    else if ( strcmp( group, ".rodata" )== 0 ) out = OS_RDATA;
    else if ( strcmp( group, ".data" )  == 0 ) out = OS_DATA;
    else if ( strcmp( group, ".bss" )   == 0 ) out = OS_BSS;
    else if ( strcmp( group, ".pdata" ) == 0 ) out = OS_PDATA;
    else if ( strcmp( group, ".xdata" ) == 0 ) out = OS_XDATA;
    else if ( strcmp( group, ".tls" )   == 0 ) out = OS_TLS;
    else if ( strcmp( group, ".CRT" )   == 0 ) out = OS_RDATA;
    else if ( strcmp( group, ".ctors" ) == 0 ) out = OS_RDATA;
    else if ( strcmp( group, ".dtors" ) == 0 ) out = OS_RDATA;
    else if ( strcmp( group, ".eh_frame")==0 ) out = OS_RDATA;
    else if ( strcmp( group, ".gcc_except_table")==0 ) out = OS_RDATA;
    else                                       out = OS_RDATA; /* default RO */
    return out;
}

/* COMDAT dedup: keep the first contribution for a given COMDAT key (the
** defining symbol name), drop later duplicates (SELECT_ANY/SAME_SIZE/etc.,
** all treated as select-any for our input set). */
typedef struct { char *key; } ComdatSeen;

static int collect_contribs( Linker *L ) {
    int oi;
    ComdatSeen *seen = NULL;
    int nseen = 0, capseen = 0;
    int rc = 1;

    for ( oi = 0; oi < L->nobjs; oi++ ) {
        LcCoffObj *o = L->objs[oi];
        uint32_t si;
        for ( si = 0; si < o->nsections; si++ ) {
            LcCoffSection *sc = &o->sections[si];
            const char *name = sc->name_long ? sc->name_long : sc->name;
            Contrib *c;
            if ( !section_is_alloc( sc ) ) continue;

            /* COMDAT dedup keyed by the defining symbol's name */
            if ( sc->is_comdat ) {
                const LcCoffSymbol *def = LcCoff_SymByIndex( o, ( uint32_t )sc->comdat_symidx );
                const char *key = ( def && def->name[0] ) ? def->name : name;
                int k, dup = 0;
                for ( k = 0; k < nseen; k++ )
                    if ( strcmp( seen[k].key, key ) == 0 ) { dup = 1; break; }
                if ( dup ) continue; /* drop duplicate COMDAT */
                if ( nseen >= capseen ) {
                    int nc = capseen ? capseen * 2 : 32;
                    ComdatSeen *ns = ( ComdatSeen * )realloc( seen, nc * sizeof( ComdatSeen ) );
                    if ( !ns ) { rc = 0; goto done; }
                    seen = ns; capseen = nc;
                }
                seen[nseen++].key = _strdup( key );
            }

            if ( L->ncontribs >= L->capcontribs ) {
                int nc = L->capcontribs ? L->capcontribs * 2 : 256;
                Contrib *ncc = ( Contrib * )realloc( L->contribs, nc * sizeof( Contrib ) );
                if ( !ncc ) { rc = 0; goto done; }
                L->contribs = ncc; L->capcontribs = nc;
            }
            c = &L->contribs[ L->ncontribs++ ];
            memset( c, 0, sizeof( *c ) );
            c->obj = o;
            c->sec_index = si;
            c->out = classify_section( name, sc->characteristics,
                                       c->group, sizeof c->group,
                                       c->suffix, sizeof c->suffix );
        }
    }
done:
    { int k; for ( k = 0; k < nseen; k++ ) free( seen[k].key ); }
    free( seen );
    return rc;
}

/* ===================================================================
** --gc-sections: dead-section elimination.
**
** The CLua runtime + Lua archives are built -ffunction-sections (and the Lua
** archive -fdata-sections), so every function/data item lives in its own COFF
** section. After the fixpoint has pulled members and COMDAT dedup has run, we
** mark the sections reachable from the roots and DROP the rest before RVA
** assignment — exactly like ld's --gc-sections. A wrongly-dropped section is a
** silent crash, so the mark phase follows EXACTLY the relocation edges that
** apply_relocations() will later resolve (same target resolution), guaranteeing
** no live relocation can ever point at a dropped section.
**
** ROOTS:
**   * every section of the FIRST explicit object (the user object: its single
**     .text holds the luac_fn_* bodies reached via the luac_fn_table, and
**     .rdata$L is the ProtoInit blob — both always live);
**   * the section defining the entry symbol, each force-undef root, _tls_used,
**     and __ImageBase;
**   * KEEP-by-name sections that must survive even when no live relocation
**     targets them: CRT ctor/dtor + .CRT XC/XI/XT init arrays, the mingw
**     pseudo-reloc list, the TLS template/callback sections, and the SEH
**     unwind sections (.pdata/.xdata) — these are reached by the loader / CRT
**     startup walkers, not by ordinary relocations. They are tiny.
**
** MARK: worklist to a fixpoint — a section becomes live when a live section
** has a relocation whose target symbol is DEFINED in it.
=================================================================== */

static uint32_t gc_hash( const LcCoffObj *o, uint32_t sec ) {
    uint64_t h = ( uint64_t )( uintptr_t )o * 1099511628211ull;
    h ^= ( uint64_t )sec + 0x9e3779b97f4a7c15ull + ( h << 6 ) + ( h >> 2 );
    return ( uint32_t )( h ^ ( h >> 32 ) );
}
static int gc_map_init( GcMap *m, int ncontribs ) {
    uint32_t cap = 16;
    while ( cap < ( uint32_t )ncontribs * 2u + 16u ) cap <<= 1;
    m->slots = ( GcSlot * )calloc( cap, sizeof( GcSlot ) );
    if ( !m->slots ) return 0;
    m->cap = cap;
    return 1;
}
static void gc_map_put( GcMap *m, LcCoffObj *o, uint32_t sec, int contrib ) {
    uint32_t i = gc_hash( o, sec ) & ( m->cap - 1 );
    for ( ;; ) {
        if ( m->slots[i].obj == NULL ) {
            m->slots[i].obj = o; m->slots[i].sec = sec; m->slots[i].contrib = contrib;
            return;
        }
        if ( m->slots[i].obj == o && m->slots[i].sec == sec ) {
            return; /* first contribution for this (obj,sec) wins */
        }
        i = ( i + 1 ) & ( m->cap - 1 );
    }
}
static int gc_map_get( const GcMap *m, const LcCoffObj *o, uint32_t sec ) {
    uint32_t i = gc_hash( o, sec ) & ( m->cap - 1 );
    for ( ;; ) {
        if ( m->slots[i].obj == NULL ) return -1;
        if ( m->slots[i].obj == o && m->slots[i].sec == sec ) return m->slots[i].contrib;
        i = ( i + 1 ) & ( m->cap - 1 );
    }
}

static int contrib_map_build( Linker *L ) {
    int i;
    free( L->contrib_map.slots );
    memset( &L->contrib_map, 0, sizeof( L->contrib_map ) );
    if ( !gc_map_init( &L->contrib_map, L->ncontribs ) ) return 0;
    for ( i = 0; i < L->ncontribs; i++ )
        gc_map_put( &L->contrib_map, L->contribs[i].obj,
                    L->contribs[i].sec_index, i );
    return 1;
}

/* Sections kept even when no live relocation targets them. */
static int gc_keep_by_name( const char *n ) {
    if ( strncmp( n, ".ctors", 6 ) == 0 ) return 1;
    if ( strncmp( n, ".dtors", 6 ) == 0 ) return 1;
    if ( strncmp( n, ".CRT",   4 ) == 0 ) return 1;  /* .CRT XC/XI/XL/XT init  */
    if ( strncmp( n, ".tls",   4 ) == 0 ) return 1;  /* TLS template/callbacks*/
    if ( strncmp( n, ".pdata", 6 ) == 0 ) return 1;  /* SEH unwind (loader)   */
    if ( strncmp( n, ".xdata", 6 ) == 0 ) return 1;
    /* mingw pseudo-reloc list bracket sections */
    if ( strstr( n, "RUNTIME_PSEUDO_RELOC_LIST" ) ) return 1;
    return 0;
}

/* Mark the contribution that defines symbol `sy` (referenced from object `o`)
** live, enqueueing it. Mirrors reloc_target_rva()'s resolution so the mark and
** the later relocation pass agree on which section a symbol lands in. */
static void gc_mark_target( Linker *L, GcMap *map, int *queue, int *qn,
                            LcCoffObj *o, const LcCoffSymbol *sy ) {
    int ci;
    /* local definition in THIS object (covers STATIC section symbols and
    ** ordinary local refs) — unless it is a dropped COMDAT dup, in which case
    ** fall through to the kept copy by name. */
    if ( sy->section >= 1 && ( uint32_t )sy->section <= o->nsections ) {
        ci = gc_map_get( map, o, ( uint32_t )( sy->section - 1 ) );
        if ( ci >= 0 ) {
            if ( !L->contribs[ci].dropped ) return;       /* already live     */
            L->contribs[ci].dropped = 0; queue[ (*qn)++ ] = ci; return;
        }
        /* not contributed (dropped COMDAT) -> resolve by name below */
    }
    if ( sy->name[0] ) {
        GSym *g = gsym_find( L, sy->name );
        if ( g && g->defined && g->obj ) {
            ci = gc_map_get( map, g->obj, g->sec_index );
            if ( ci >= 0 && L->contribs[ci].dropped ) {
                L->contribs[ci].dropped = 0; queue[ (*qn)++ ] = ci;
            }
        }
    }
}

/* Walk a live contribution's relocations, marking each target's section live. */
static void gc_scan_contrib( Linker *L, GcMap *map, int *queue, int *qn, int ci ) {
    Contrib *c = &L->contribs[ci];
    LcCoffObj *o = c->obj;
    LcCoffSection *sc = &o->sections[ c->sec_index ];
    uint32_t r;
    for ( r = 0; r < sc->nrelocs; r++ ) {
        const LcCoffSymbol *sy = LcCoff_SymByIndex( o, sc->relocs[r].symidx );
        if ( !sy ) continue;
        gc_mark_target( L, map, queue, qn, o, sy );
    }
}

/* Mark a named symbol's defining section live (entry / force-undef / linker
** anchors). No-op if it resolves to an import/common/synth (no section). */
static void gc_root_symbol( Linker *L, GcMap *map, int *queue, int *qn,
                            const char *name ) {
    GSym *g = gsym_find( L, name );
    int ci;
    if ( !g || !g->defined || !g->obj ) return;
    ci = gc_map_get( map, g->obj, g->sec_index );
    if ( ci >= 0 && L->contribs[ci].dropped ) {
        L->contribs[ci].dropped = 0; queue[ (*qn)++ ] = ci;
    }
}

static int gc_sections( Linker *L, const char *const *force_undef, int nforce ) {
    GcMap *map = &L->contrib_map;
    int *queue;
    int qn = 0, i;
    size_t nc;

    if ( !L->gc_sections || L->ncontribs <= 0 ) return 1;
    nc = ( size_t )L->ncontribs;

    /* each contribution enqueues at most once (guarded by the dropped flag), so
    ** the worklist never exceeds ncontribs entries. */
    queue = ( int * )malloc( nc * sizeof( int ) );
    if ( !queue ) return lerr( L, "oom (gc queue)", NULL );

    /* Start everything dead; roots flip live + enqueue. */
    for ( i = 0; i < L->ncontribs; i++ ) L->contribs[i].dropped = 1;

    /* ROOT 1: every section of the user object (objs[0]) + KEEP-by-name. */
    for ( i = 0; i < L->ncontribs; i++ ) {
        Contrib *c = &L->contribs[i];
        const char *n = c->obj->sections[ c->sec_index ].name_long
                      ? c->obj->sections[ c->sec_index ].name_long
                      : c->obj->sections[ c->sec_index ].name;
        int is_user = ( L->nobjs > 0 && c->obj == L->objs[0] );
        if ( is_user || gc_keep_by_name( n ) ) {
            if ( c->dropped ) { c->dropped = 0; queue[ qn++ ] = i; }
        }
    }

    /* ROOT 2: entry, force-undef roots (e.g. Clua_OpenFfi for FFI programs),
    ** and the linker anchors the loader / data directories consume. */
    gc_root_symbol( L, map, queue, &qn, L->entry );
    gc_root_symbol( L, map, queue, &qn, "_tls_used" );
    for ( i = 0; i < nforce; i++ )
        gc_root_symbol( L, map, queue, &qn, force_undef[i] );

    /* MARK to fixpoint. */
    while ( qn > 0 ) {
        int ci = queue[ --qn ];
        gc_scan_contrib( L, map, queue, &qn, ci );
    }

    /* CLUA_GC_DEBUG: one-line tally of what the sweep kept vs dropped. */
    if ( getenv( "CLUA_GC_DEBUG" ) ) {
        int live = 0, dead = 0; size_t deadsz = 0;
        for ( i = 0; i < L->ncontribs; i++ ) {
            Contrib *c = &L->contribs[i];
            LcCoffSection *sc = &c->obj->sections[ c->sec_index ];
            if ( c->dropped ) { dead++; deadsz += sc->size_raw ? sc->size_raw : sc->virtual_size; }
            else live++;
        }
        fprintf( stderr, "[gc] kept %d, dropped %d sections (%zu B of dead code)\n",
                 live, dead, deadsz );
    }

    free( queue );
    return 1;
}

/* section alignment encoded in characteristics (default 16) */
static uint32_t sec_align( const LcCoffSection *sc ) {
    uint32_t a = ( sc->characteristics & LC_IMAGE_SCN_ALIGN_MASK ) >> LC_IMAGE_SCN_ALIGN_SHIFT;
    if ( a == 0 ) return 1;
    return 1u << ( a - 1 );
}

/* comparison key for $-sorting: group first (stable), then suffix ascending.
** Within a group the suffix orders the pieces (.text$mn, .CRT$XCA<XCU<XCZ,
** .ctors etc.). Empty suffix sorts first. */
static int contrib_cmp( const void *pa, const void *pb ) {
    const Contrib *a = ( const Contrib * )pa;
    const Contrib *b = ( const Contrib * )pb;
    int g;
    if ( a->out != b->out ) return a->out - b->out;
    g = strcmp( a->group, b->group );
    if ( g ) return g;
    return strcmp( a->suffix, b->suffix );
}

/* Lay out contributions into output-section raw buffers. Stable within equal
** keys via index tiebreak (qsort isn't stable, so we tag order). */
static int layout_sections( Linker *L ) {
    int i;
    /* stable sort: decorate with original index */
    /* simple insertion-stable approach: copy, sort with index tiebreak */
    for ( i = 0; i < OS_COUNT; i++ ) {
        static const char *names[OS_COUNT] = {
            ".text", ".rdata", ".data", ".pdata", ".xdata", ".bss",
            ".tls", ".idata", ".reloc" };
        static const uint32_t chars[OS_COUNT] = {
            LC_IMAGE_SCN_CNT_CODE|LC_IMAGE_SCN_MEM_EXECUTE|LC_IMAGE_SCN_MEM_READ,
            LC_IMAGE_SCN_CNT_INITIALIZED_DATA|LC_IMAGE_SCN_MEM_READ,
            LC_IMAGE_SCN_CNT_INITIALIZED_DATA|LC_IMAGE_SCN_MEM_READ|LC_IMAGE_SCN_MEM_WRITE,
            LC_IMAGE_SCN_CNT_INITIALIZED_DATA|LC_IMAGE_SCN_MEM_READ,
            LC_IMAGE_SCN_CNT_INITIALIZED_DATA|LC_IMAGE_SCN_MEM_READ,
            LC_IMAGE_SCN_CNT_UNINIT_DATA|LC_IMAGE_SCN_MEM_READ|LC_IMAGE_SCN_MEM_WRITE,
            LC_IMAGE_SCN_CNT_INITIALIZED_DATA|LC_IMAGE_SCN_MEM_READ|LC_IMAGE_SCN_MEM_WRITE,
            LC_IMAGE_SCN_CNT_INITIALIZED_DATA|LC_IMAGE_SCN_MEM_READ|LC_IMAGE_SCN_MEM_WRITE,
            LC_IMAGE_SCN_CNT_INITIALIZED_DATA|LC_IMAGE_SCN_MEM_READ|LC_IMAGE_SCN_MEM_DISCARDABLE };
        L->out[i].name = names[i];
        L->out[i].characteristics = chars[i];
    }

    /* stable sort of contributions by (out, group, suffix, original index) */
    {
        int n = L->ncontribs, a, b;
        for ( a = 1; a < n; a++ ) {
            Contrib key = L->contribs[a];
            b = a - 1;
            while ( b >= 0 && contrib_cmp( &L->contribs[b], &key ) > 0 ) {
                L->contribs[b+1] = L->contribs[b];
                b--;
            }
            L->contribs[b+1] = key;
        }
    }

    /* append each contribution to its output section */
    for ( i = 0; i < L->ncontribs; i++ ) {
        Contrib *c = &L->contribs[i];
        LcCoffSection *sc = &c->obj->sections[ c->sec_index ];
        OutSec *os = &L->out[ c->out ];
        uint32_t align = sec_align( sc );
        uint32_t size = sc->size_raw ? sc->size_raw : sc->virtual_size;

        if ( c->dropped ) continue;   /* gc-sections: dead, contributes nothing */

        /* align within the output section */
        while ( os->virt_size % align ) {
            if ( c->out == OS_BSS ) { os->virt_size++; }
            else { if ( !b_zero( &os->raw, 1 ) ) return lerr( L, "oom", NULL ); os->virt_size++; }
        }
        c->out_off = os->virt_size;

        if ( c->out == OS_BSS || sc->ptr_raw == 0 || sc->data == NULL ) {
            /* uninitialized: reserve virtual space only */
            os->virt_size += size;
        } else {
            if ( !b_putn( &os->raw, sc->data, sc->size_raw ) ) return lerr( L, "oom", NULL );
            os->virt_size += sc->size_raw;
        }
        os->present = 1;
    }

    /* commit COMMON symbols into .bss (those not satisfied by a real def) */
    for ( i = 0; i < L->nsyms; i++ ) {
        GSym *g = &L->syms[i];
        OutSec *bss = &L->out[OS_BSS];
        uint32_t align = 16;
        if ( !g->is_common || g->defined ) continue;
        while ( bss->virt_size % align ) bss->virt_size++;
        /* record as defined at .bss offset (obj NULL => absolute-by-rva later) */
        g->defined  = 1;
        g->obj      = NULL;
        g->is_abs   = 0;
        g->sec_index= ( uint32_t )OS_BSS;     /* sentinel: resolved by out rva */
        g->value    = bss->virt_size;
        g->is_common= 2;                       /* mark "placed in bss"          */
        bss->virt_size += g->common_size ? g->common_size : 1;
        bss->present = 1;
    }
    return 1;
}

/* ===================================================================
** Import directory synthesis.
**
** Build, into OS_IDATA:
**   [IAT]            one 8-byte slot per import, grouped by DLL, each DLL's
**                    run NUL-terminated (a zero qword) — this is also the
**                    Import Address Table the loader patches.
**   [ILT]            identical layout (lookup table)
**   [descriptors]    one IMAGE_IMPORT_DESCRIPTOR (20 bytes) per DLL + a null
**   [hint/name]      2-byte hint + name + pad per import
**   [dll names]      NUL-terminated DLL name strings
** And, into OS_TEXT, one 6-byte `jmp [rip+disp32]` thunk per import (the FOO
** symbol), the disp32 patched to point at the import's IAT slot.
**
** RVAs aren't known yet, so we record per-import IAT/ILT/hintname/thunk
** OFFSETS within their buffers; addresses are finalized after RVA assignment.
=================================================================== */
typedef struct {
    uint32_t iat_off;       /* IAT slot offset within OS_IDATA raw          */
    uint32_t ilt_off;
    uint32_t hint_off;      /* hint/name offset within OS_IDATA raw         */
    uint32_t thunk_off;     /* thunk offset within OS_TEXT raw              */
} ImpLayout;

/* descriptor table offset + dll-name offsets, all within OS_IDATA raw */
typedef struct {
    uint32_t descr_off;     /* offset of the descriptor array              */
    uint32_t ndlls;
    uint32_t *dll_first;    /* index of first import for each dll          */
    uint32_t *dll_count;
    uint32_t *dll_name_off; /* dll-name string offset within OS_IDATA      */
    uint32_t iat_base;      /* OS_IDATA offset where the IAT begins         */
    ImpLayout *imp;         /* per-import offsets                           */
} ImportLayout;

static void import_layout_free( ImportLayout *il ) {
    if ( !il ) return;
    free( il->dll_first ); free( il->dll_count ); free( il->dll_name_off ); free( il->imp );
    memset( il, 0, sizeof( *il ) );
}

/* group imports by DLL (stable: order of first appearance) */
static int build_imports( Linker *L, ImportLayout *il ) {
    int i, j;
    uint32_t ndll = 0;
    char (*dllnames)[128];
    OutSec *idata = &L->out[OS_IDATA];
    OutSec *text  = &L->out[OS_TEXT];
    uint32_t off;

    memset( il, 0, sizeof( *il ) );
    if ( L->nimports == 0 ) return 1;

    il->imp = ( ImpLayout * )calloc( L->nimports, sizeof( ImpLayout ) );
    dllnames = ( char (*)[128] )calloc( L->nimports, 128 );
    il->dll_first    = ( uint32_t * )calloc( L->nimports, sizeof( uint32_t ) );
    il->dll_count    = ( uint32_t * )calloc( L->nimports, sizeof( uint32_t ) );
    il->dll_name_off = ( uint32_t * )calloc( L->nimports, sizeof( uint32_t ) );
    if ( !il->imp || !dllnames || !il->dll_first || !il->dll_count || !il->dll_name_off ) {
        free( dllnames ); import_layout_free( il ); return lerr( L, "oom imports", NULL );
    }

    /* a sorted-by-dll ordering of imports: assign each import to a dll bucket */
    {
        /* map import -> dll index, creating buckets in first-seen order */
        int *imp_dll = ( int * )calloc( L->nimports, sizeof( int ) );
        if ( !imp_dll ) { free( dllnames ); import_layout_free( il ); return lerr( L, "oom", NULL ); }
        for ( i = 0; i < L->nimports; i++ ) {
            int found = -1;
            for ( j = 0; j < ( int )ndll; j++ )
                if ( _stricmp( dllnames[j], L->imports[i].dll ) == 0 ) { found = j; break; }
            if ( found < 0 ) {
                found = ( int )ndll;
                snprintf( dllnames[ndll], 128, "%s", L->imports[i].dll );
                ndll++;
            }
            imp_dll[i] = found;
        }
        il->ndlls = ndll;

        /* IAT: per dll, its imports' slots contiguous + a null terminator */
        off = 0;
        il->iat_base = off;
        for ( j = 0; j < ( int )ndll; j++ ) {
            il->dll_first[j] = ( uint32_t )-1;
            for ( i = 0; i < L->nimports; i++ ) {
                if ( imp_dll[i] != j ) continue;
                if ( il->dll_first[j] == ( uint32_t )-1 ) il->dll_first[j] = ( uint32_t )i;
                il->dll_count[j]++;
                il->imp[i].iat_off = off;
                off += 8;
            }
            off += 8; /* null terminator slot */
        }
        /* ILT mirrors the IAT */
        for ( j = 0; j < ( int )ndll; j++ ) {
            for ( i = 0; i < L->nimports; i++ ) {
                if ( imp_dll[i] != j ) continue;
                il->imp[i].ilt_off = off;
                off += 8;
            }
            off += 8;
        }
        /* descriptor array: ndll descriptors (20 bytes) + null */
        while ( off % 4 ) off++;
        il->descr_off = off;
        off += ( ndll + 1 ) * 20;
        /* hint/name entries */
        for ( i = 0; i < L->nimports; i++ ) {
            size_t nl = strlen( L->imports[i].func );
            il->imp[i].hint_off = off;
            off += 2 + ( uint32_t )nl + 1;
            if ( off & 1 ) off++;
        }
        /* dll-name strings */
        for ( j = 0; j < ( int )ndll; j++ ) {
            il->dll_name_off[j] = off;
            off += ( uint32_t )strlen( dllnames[j] ) + 1;
            if ( off & 1 ) off++;
        }

        /* reserve the OS_IDATA raw space (zeroed; filled after RVA assign) */
        if ( !b_zero( &idata->raw, off ) ) { free( imp_dll ); free( dllnames ); import_layout_free( il ); return lerr( L, "oom", NULL ); }
        idata->virt_size = off;
        idata->present = ndll ? 1 : 0;

        /* thunks into OS_TEXT: 6 bytes each (ff 25 disp32), 16-align start */
        while ( text->virt_size % 16 ) {
            if ( !b_zero( &text->raw, 1 ) ) { free( imp_dll ); free( dllnames ); import_layout_free( il ); return lerr( L, "oom", NULL ); }
            text->virt_size++;
        }
        for ( i = 0; i < L->nimports; i++ ) {
            uint8_t stub[6] = { 0xFF, 0x25, 0,0,0,0 };
            il->imp[i].thunk_off = text->virt_size;
            if ( !b_putn( &text->raw, stub, 6 ) ) { free( imp_dll ); free( dllnames ); import_layout_free( il ); return lerr( L, "oom", NULL ); }
            text->virt_size += 6;
        }
        text->present = 1;

        free( imp_dll );
    }

    /* stash dll-name strings on the linker via il (we keep them in idata raw
    ** during finalize; copy into a side store now) */
    {
        /* re-store dll names into a contiguous buffer the finalize step reads */
        il->dll_name_off = il->dll_name_off; /* already offsets */
        /* keep dllnames around: store via static is unsafe; instead remember
        ** the names by re-deriving from L->imports[dll_first].dll at finalize */
    }
    free( dllnames );
    return 1;
}

/* ===================================================================
** RVA + file-offset assignment. Output sections are laid in a fixed order;
** each gets a page-aligned RVA and a FILE_ALIGN-aligned file offset. .bss
** occupies no file space; .reloc is built last (after we know all sites).
=================================================================== */
static uint32_t align_up( uint32_t v, uint32_t a ) { return ( v + a - 1 ) & ~( a - 1 ); }

/* The output-section emission order (must match section-header order). */
static const int kSecOrder[] = { OS_TEXT, OS_RDATA, OS_DATA, OS_PDATA, OS_XDATA,
                                 OS_IDATA, OS_TLS, OS_BSS, OS_RELOC };
#define N_SECORDER ( (int)( sizeof(kSecOrder)/sizeof(kSecOrder[0]) ) )

/* A section appears in the image only if it has nonzero virtual size. Empty
** sections (e.g. an empty .data brought by a CRT stub) must NOT consume an
** RVA / section header, or the loader rejects the image. */
static int os_emitted( const OutSec *os ) {
    uint32_t vsz = os->virt_size > ( uint32_t )os->raw.len ? os->virt_size : ( uint32_t )os->raw.len;
    return vsz != 0;
}

static uint32_t g_headers_size; /* SizeOfHeaders, set in emit */

/* assign RVAs to all present output sections (except .reloc, sized later) */
static void assign_rvas( Linker *L, uint32_t headers_size ) {
    uint32_t rva = align_up( headers_size, PE_SECT_ALIGN );
    uint32_t foff = align_up( headers_size, PE_FILE_ALIGN );
    int k;
    for ( k = 0; k < N_SECORDER; k++ ) {
        int oi = kSecOrder[k];
        OutSec *os = &L->out[oi];
        uint32_t vsz;
        if ( oi == OS_RELOC ) continue;      /* sized after reloc gen        */
        if ( !os_emitted( os ) ) continue;
        vsz = ( oi == OS_BSS ) ? os->virt_size
                               : ( os->virt_size > os->raw.len ? os->virt_size : ( uint32_t )os->raw.len );
        os->rva = rva;
        if ( oi == OS_BSS ) {
            os->file_off = 0;
            os->file_size = 0;
        } else {
            os->file_off = foff;
            os->file_size = align_up( vsz, PE_FILE_ALIGN );
            foff += os->file_size;
        }
        os->virt_size = vsz;
        rva += align_up( vsz, PE_SECT_ALIGN );
    }
    (void)L;
}

/* the RVA of a synthesized linker symbol */
static int synth_rva( Linker *L, const GSym *g, uint32_t *out ) {
    switch ( g->synth ) {
    case SYN_IMAGEBASE: *out = 0; return 1;
    case SYN_SEC_START: *out = L->out[ g->syn_sec ].rva; return 1;
    case SYN_SEC_END:   *out = L->out[ g->syn_sec ].rva + L->out[ g->syn_sec ].virt_size; return 1;
    default: return 0;
    }
}

/* the RVA of a symbol definition */
static int sym_rva( Linker *L, GSym *g, uint32_t *out, ImportLayout *il ) {
    if ( g->synth ) return synth_rva( L, g, out );
    if ( g->is_abs ) { *out = ( uint32_t )g->abs_value; return 1; }
    if ( g->is_import_thunk ) {
        *out = L->out[OS_TEXT].rva + il->imp[ g->import_index ].thunk_off;
        return 1;
    }
    if ( g->is_import_iat ) {
        *out = L->out[OS_IDATA].rva + il->imp[ g->import_index ].iat_off;
        return 1;
    }
    if ( g->is_common == 2 ) {
        *out = L->out[OS_BSS].rva + g->value;
        return 1;
    }
    if ( g->defined && g->obj ) {
        int ci = gc_map_get( &L->contrib_map, g->obj, g->sec_index );
        if ( ci >= 0 && !L->contribs[ci].dropped ) {
            Contrib *c = &L->contribs[ci];
            *out = L->out[ c->out ].rva + c->out_off + g->value;
            return 1;
        }
        /* section wasn't contributed (e.g. dropped COMDAT dup): point at the
        ** kept copy is hard; treat as 0 (should not happen for referenced
        ** defs since the kept COMDAT defines the same symbol). */
        return 0;
    }
    return 0;
}

/* resolve every symbol's final rva (cached in g->rva) */
static int resolve_addrs( Linker *L, ImportLayout *il ) {
    int i;
    for ( i = 0; i < L->nsyms; i++ ) {
        GSym *g = &L->syms[i];
        uint32_t r;
        if ( !g->defined ) {
            /* weak external falling back to its default (or absolute 0) */
            if ( g->weak ) {
                if ( g->weak_default ) {
                    GSym *d = gsym_find( L, g->weak_default );
                    if ( d && d->defined ) { g->rva = d->rva; continue; }
                }
                g->is_abs = 1; g->abs_value = 0; g->rva = 0;
                continue;
            }
            continue; /* genuinely undefined: caught by caller */
        }
        if ( sym_rva( L, g, &r, il ) ) g->rva = r;
    }
    /* second pass for weak defaults whose target resolved after them */
    for ( i = 0; i < L->nsyms; i++ ) {
        GSym *g = &L->syms[i];
        if ( !g->defined && g->weak && g->weak_default ) {
            GSym *d = gsym_find( L, g->weak_default );
            if ( d && d->defined ) g->rva = d->rva;
        }
    }
    return 1;
}

/* Resolve a relocation's target symbol to an RVA + a flag telling whether it's
** a genuine ABSOLUTE value (a weak-undefined symbol that fell back to 0, or an
** IMAGE_SYM_ABSOLUTE symbol) vs an image-relative address. Returns 0 if
** genuinely unresolved. For local section symbols (STATIC class), the value is
** the section's placed RVA + the symbol Value. An absolute target must NOT get
** image_base added and must NOT generate a base relocation. */
static int reloc_target_rva( Linker *L, LcCoffObj *o, const LcCoffSymbol *sy,
                             ImportLayout *il, uint32_t *out_rva, int *is_abs ) {
    if ( is_abs ) *is_abs = 0;
    /* defined in THIS object's section? (covers local .text/.rdata refs and
    ** STATIC section symbols) */
    if ( sy->section >= 1 && ( uint32_t )sy->section <= o->nsections ) {
        int ci = gc_map_get( &L->contrib_map, o,
                             ( uint32_t )( sy->section - 1 ) );
        if ( ci >= 0 && !L->contribs[ci].dropped ) {
            Contrib *c = &L->contribs[ci];
            *out_rva = L->out[ c->out ].rva + c->out_off + sy->value;
            return 1;
        }
        /* a dropped COMDAT section: fall through to the global by name */
    }
    /* otherwise resolve by name through the global table */
    if ( sy->name[0] ) {
        GSym *g = gsym_find( L, sy->name );
        if ( g && ( g->defined || g->weak ) ) {
            *out_rva = g->rva;
            /* a weak symbol that never got a real definition resolves to an
            ** absolute 0 (NULL) — ld semantics. So does an explicit absolute. */
            if ( is_abs && ( g->is_abs || ( g->weak && !g->defined ) ) ) *is_abs = 1;
            return 1;
        }
    }
    (void)il;
    return 0;
}

/* Apply all relocations of every contributed section into the OS raw buffers.
** Records base-relocation sites for ADDR64. */
static int apply_relocations( Linker *L, ImportLayout *il ) {
    int ci;
    for ( ci = 0; ci < L->ncontribs; ci++ ) {
        Contrib *c = &L->contribs[ci];
        LcCoffObj *o = c->obj;
        LcCoffSection *sc = &o->sections[ c->sec_index ];
        OutSec *os = &L->out[ c->out ];
        uint32_t r;
        if ( c->dropped ) continue;       /* gc-sections: not placed          */
        if ( c->out == OS_BSS ) continue; /* no raw to patch */
        for ( r = 0; r < sc->nrelocs; r++ ) {
            const LcCoffReloc *rl = &sc->relocs[r];
            const LcCoffSymbol *sy = LcCoff_SymByIndex( o, rl->symidx );
            uint64_t patch_off64;   /* offset within os->raw, before narrowing */
            uint32_t patch_off;
            uint32_t target_rva;
            int      tgt_abs = 0;   /* target is an absolute value (weak NULL) */
            size_t   patch_width;
            uint8_t *p;
            if ( !sy ) return lerr( L, "reloc references aux/oob symbol in %s", o->origin );

            switch ( rl->type ) {
            case LC_IMAGE_REL_AMD64_ABSOLUTE: patch_width = 0; break;
            case LC_IMAGE_REL_AMD64_ADDR64:   patch_width = 8; break;
            case LC_IMAGE_REL_AMD64_SECTION:  patch_width = 2; break;
            default:                          patch_width = 4; break;
            }
            patch_off64 = ( uint64_t )c->out_off + ( uint64_t )rl->va;
            if ( rl->va > sc->size_raw ||
                 patch_width > ( size_t )sc->size_raw - rl->va ||
                 patch_off64 > UINT32_MAX ||
                 patch_off64 > ( uint64_t )os->raw.len ||
                 patch_width > os->raw.len - ( size_t )patch_off64 ) {
                snprintf( L->err, sizeof L->err,
                          "relocation patch is outside section data in %s",
                          o->origin );
                return 0;
            }
            patch_off = ( uint32_t )patch_off64;
            p = os->raw.p + patch_off;

            if ( !reloc_target_rva( L, o, sy, il, &target_rva, &tgt_abs ) ) {
                snprintf( L->err, sizeof L->err,
                          "unresolved symbol '%s' (reloc type %u in %s)",
                          sy->name, rl->type, o->origin );
                return 0;
            }

            switch ( rl->type ) {
            case LC_IMAGE_REL_AMD64_ADDR64: {
                /* absolute target (weak-NULL): write the bare value, NO base
                ** reloc — so &weak_undef == 0 (NULL), matching ld. */
                uint64_t base = tgt_abs ? 0 : L->image_base;
                uint64_t va = base + target_rva;
                /* addend already in place (usually 0) */
                uint64_t add = ( uint64_t )p[0] | ((uint64_t)p[1]<<8) | ((uint64_t)p[2]<<16)
                             | ((uint64_t)p[3]<<24) | ((uint64_t)p[4]<<32) | ((uint64_t)p[5]<<40)
                             | ((uint64_t)p[6]<<48) | ((uint64_t)p[7]<<56);
                if ( target_rva > UINT64_MAX - base ||
                     add > UINT64_MAX - ( base + target_rva ) ) {
                    return lerr( L, "ADDR64 relocation overflows in %s", o->origin );
                }
                w64( p, va + add );
                if ( !tgt_abs ) {
                    if ( patch_off > UINT32_MAX - os->rva ) {
                        return lerr( L, "base relocation RVA overflows in %s", o->origin );
                    }
                    if ( !reloc_add( L, os->rva + patch_off ) ) return lerr( L, "oom", NULL );
                }
                break;
            }
            case LC_IMAGE_REL_AMD64_ADDR32: {
                uint32_t add = (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
                uint64_t value = ( tgt_abs ? 0 : L->image_base ) +
                                 ( uint64_t )target_rva + ( uint64_t )add;
                if ( value > UINT32_MAX ) {
                    return lerr( L, "ADDR32 relocation overflows in %s", o->origin );
                }
                w32( p, ( uint32_t )value );
                break;
            }
            case LC_IMAGE_REL_AMD64_ADDR32NB: {
                uint32_t add = (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
                uint64_t value = ( uint64_t )target_rva + ( uint64_t )add;
                if ( value > UINT32_MAX ) {
                    return lerr( L, "ADDR32NB relocation overflows in %s", o->origin );
                }
                w32( p, ( uint32_t )value );  /* image-relative; no base reloc */
                break;
            }
            case LC_IMAGE_REL_AMD64_REL32:
            case LC_IMAGE_REL_AMD64_REL32_1:
            case LC_IMAGE_REL_AMD64_REL32_2:
            case LC_IMAGE_REL_AMD64_REL32_3:
            case LC_IMAGE_REL_AMD64_REL32_4:
            case LC_IMAGE_REL_AMD64_REL32_5: {
                int extra = ( int )( rl->type - LC_IMAGE_REL_AMD64_REL32 ); /* 0..5 */
                int32_t add = (int32_t)((uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24));
                uint64_t site_rva = ( uint64_t )os->rva + patch_off;
                /* disp = target - (next_insn). next = site + 4 + extra */
                int64_t disp;
                if ( site_rva > INT64_MAX - 9 ) {
                    return lerr( L, "REL32 site RVA overflows in %s", o->origin );
                }
                disp = ( int64_t )target_rva - ( int64_t )( site_rva + 4 + extra ) + add;
                if ( disp < INT32_MIN || disp > INT32_MAX ) {
                    return lerr( L, "REL32 relocation overflows in %s", o->origin );
                }
                w32( p, ( uint32_t )( int32_t )disp );
                break;
            }
            case LC_IMAGE_REL_AMD64_SECREL: {
                /* offset of target within its output section */
                uint32_t secbase = 0;
                /* find the output section the target lands in */
                int oi;
                for ( oi = 0; oi < OS_COUNT; oi++ ) {
                    OutSec *t = &L->out[oi];
                    if ( t->rva && target_rva >= t->rva &&
                         target_rva < t->rva + t->virt_size ) { secbase = t->rva; break; }
                }
                w32( p, target_rva - secbase );
                break;
            }
            case LC_IMAGE_REL_AMD64_SECTION: {
                /* 1-based index of the output section containing the target */
                uint16_t idx = 0, n = 0;
                int oi, k;
                for ( k = 0; k < N_SECORDER; k++ ) {
                    OutSec *t = &L->out[ kSecOrder[k] ];
                    if ( !( t->present || t->virt_size ) ) continue;
                    n++;
                    oi = kSecOrder[k];
                    if ( t->rva && target_rva >= t->rva && target_rva < t->rva + t->virt_size ) { idx = n; }
                    (void)oi;
                }
                w16( p, idx );
                break;
            }
            case LC_IMAGE_REL_AMD64_ABSOLUTE:
                break; /* no-op (alignment) */
            default:
                return lerr( L, "unsupported reloc type in %s", o->origin );
            }
        }
    }
    return 1;
}

/* Fill the .idata content (IAT/ILT/descriptors/hint-names/dll-names) and the
** import jmp thunks now that all RVAs are known. */
static int finalize_imports( Linker *L, ImportLayout *il ) {
    OutSec *idata = &L->out[OS_IDATA];
    OutSec *text  = &L->out[OS_TEXT];
    uint8_t *base;
    int i, j;
    uint32_t idata_rva = idata->rva;

    if ( L->nimports == 0 ) return 1;
    base = idata->raw.p;

    /* IAT + ILT entries point at their hint/name RVA */
    for ( i = 0; i < L->nimports; i++ ) {
        uint64_t hn_rva = idata_rva + il->imp[i].hint_off;
        w64( base + il->imp[i].iat_off, hn_rva );
        w64( base + il->imp[i].ilt_off, hn_rva );
        /* hint(2) + export name + NUL */
        {
            uint8_t *hp = base + il->imp[i].hint_off;
            const char *fn = L->imports[i].func;
            w16( hp, L->imports[i].hint );
            memcpy( hp + 2, fn, strlen( fn ) + 1 );
        }
    }
    /* descriptors + dll-name strings */
    for ( j = 0; j < ( int )il->ndlls; j++ ) {
        uint8_t *d = base + il->descr_off + ( uint32_t )j * 20;
        uint32_t first = il->dll_first[j];
        const char *dll = L->imports[first].dll;
        w32( d + 0,  idata_rva + il->imp[first].ilt_off );  /* OriginalFirstThunk */
        w32( d + 4,  0 );                                    /* TimeDateStamp     */
        w32( d + 8,  0 );                                    /* ForwarderChain    */
        w32( d + 12, idata_rva + il->dll_name_off[j] );      /* Name              */
        w32( d + 16, idata_rva + il->imp[first].iat_off );   /* FirstThunk (IAT)  */
        memcpy( base + il->dll_name_off[j], dll, strlen( dll ) + 1 );
    }
    /* null descriptor already zeroed */

    /* thunks: ff 25 disp32 ; disp = iat_rva - (thunk_rva + 6) */
    for ( i = 0; i < L->nimports; i++ ) {
        uint32_t thunk_rva = text->rva + il->imp[i].thunk_off;
        uint32_t iat_rva   = idata_rva + il->imp[i].iat_off;
        int32_t disp = ( int32_t )( iat_rva - ( thunk_rva + 6 ) );
        w32( text->raw.p + il->imp[i].thunk_off + 2, ( uint32_t )disp );
    }
    return 1;
}

/* ===================================================================
** .reloc generation: group ADDR64/ADDR32 sites into 4 KB page blocks. Each
** block: PageRVA(4) BlockSize(4) then 2-byte entries (type<<12 | offset).
=================================================================== */
static int cmp_u32( const void *a, const void *b ) {
    uint32_t x = *( const uint32_t * )a, y = *( const uint32_t * )b;
    return ( x > y ) - ( x < y );
}

static int build_reloc_section( Linker *L ) {
    OutSec *rs = &L->out[OS_RELOC];
    uint32_t *sites;
    int i;
    uint32_t cur_page;
    int have_page = 0;
    size_t block_start = 0;

    if ( L->nrelocs == 0 ) { rs->present = 0; return 1; }

    sites = ( uint32_t * )malloc( ( size_t )L->nrelocs * sizeof( uint32_t ) );
    if ( !sites ) return lerr( L, "oom", NULL );
    for ( i = 0; i < L->nrelocs; i++ ) sites[i] = L->relocs[i].rva;
    qsort( sites, ( size_t )L->nrelocs, sizeof( uint32_t ), cmp_u32 );

    cur_page = 0;
    for ( i = 0; i < L->nrelocs; i++ ) {
        uint32_t page = sites[i] & ~0xFFFu;
        if ( i > 0 && sites[i] == sites[i-1] ) continue; /* dedup */
        if ( !have_page || page != cur_page ) {
            /* close previous block: pad to 4-byte, patch BlockSize */
            if ( have_page ) {
                while ( ( rs->raw.len - block_start ) & 3 ) { if ( !b_zero( &rs->raw, 1 ) ) { free(sites); return lerr(L,"oom",NULL); } }
                w32( rs->raw.p + block_start + 4, ( uint32_t )( rs->raw.len - block_start ) );
            }
            block_start = rs->raw.len;
            cur_page = page;
            have_page = 1;
            { uint8_t hdr[8]; w32( hdr, page ); w32( hdr+4, 0 ); if ( !b_putn( &rs->raw, hdr, 8 ) ) { free(sites); return lerr(L,"oom",NULL); } }
        }
        { uint16_t e = ( uint16_t )( ( 10u << 12 ) | ( sites[i] - cur_page ) ); /* IMAGE_REL_BASED_DIR64=10 */
          uint8_t eb[2]; w16( eb, e ); if ( !b_putn( &rs->raw, eb, 2 ) ) { free(sites); return lerr(L,"oom",NULL); } }
    }
    if ( have_page ) {
        while ( ( rs->raw.len - block_start ) & 3 ) { if ( !b_zero( &rs->raw, 1 ) ) { free(sites); return lerr(L,"oom",NULL); } }
        w32( rs->raw.p + block_start + 4, ( uint32_t )( rs->raw.len - block_start ) );
    }
    free( sites );
    rs->virt_size = ( uint32_t )rs->raw.len;
    rs->present = rs->raw.len ? 1 : 0;
    return 1;
}

/* ===================================================================
** Final PE emission. Counts the present sections, lays the headers, then
** writes section headers + raw data at FILE_ALIGN offsets.
=================================================================== */
#define DOS_STUB_LEN 0x80

static int count_sections( Linker *L ) {
    int k, n = 0;
    for ( k = 0; k < N_SECORDER; k++ ) {
        OutSec *os = &L->out[ kSecOrder[k] ];
        if ( os_emitted( os ) ) n++;
    }
    return n;
}

/* compute .reloc RVA/file-off after everything else is placed */
static void place_reloc_section( Linker *L ) {
    OutSec *rs = &L->out[OS_RELOC];
    uint32_t rva = 0, foff = 0;
    int k;
    if ( !rs->present ) return;
    /* find the end of the last placed non-reloc section */
    for ( k = 0; k < N_SECORDER; k++ ) {
        int oi = kSecOrder[k];
        OutSec *os = &L->out[oi];
        if ( oi == OS_RELOC ) continue;
        if ( !os_emitted( os ) ) continue;
        if ( os->rva + align_up( os->virt_size, PE_SECT_ALIGN ) > rva )
            rva = os->rva + align_up( os->virt_size, PE_SECT_ALIGN );
        if ( oi != OS_BSS && os->file_off + os->file_size > foff )
            foff = os->file_off + os->file_size;
    }
    rs->rva = rva;
    rs->file_off = foff;
    rs->file_size = align_up( ( uint32_t )rs->raw.len, PE_FILE_ALIGN );
    rs->virt_size = ( uint32_t )rs->raw.len;
}

static uint32_t total_image_size( Linker *L ) {
    uint32_t end = 0;
    int k;
    for ( k = 0; k < N_SECORDER; k++ ) {
        OutSec *os = &L->out[ kSecOrder[k] ];
        if ( !os_emitted( os ) ) continue;
        if ( os->rva + align_up( os->virt_size, PE_SECT_ALIGN ) > end )
            end = os->rva + align_up( os->virt_size, PE_SECT_ALIGN );
    }
    return end;
}

static int emit_pe( Linker *L, const char *out_path, ImportLayout *il ) {
    Buf file;
    uint32_t nsec = ( uint32_t )count_sections( L );
    uint32_t opt_hdr_size = 0xF0;          /* PE32+ optional header size      */
    uint32_t sizeof_headers;
    uint32_t pe_off = DOS_STUB_LEN;
    uint32_t sechdr_off;
    uint32_t entry_rva = 0;
    GSym *eg;
    int k;
    FILE *f;

    memset( &file, 0, sizeof file );

    /* headers size: DOS(0x80)+PE sig(4)+file hdr(20)+opt hdr(0xF0)+sect hdrs */
    sizeof_headers = pe_off + 4 + 20 + opt_hdr_size + nsec * 40;
    sizeof_headers = align_up( sizeof_headers, PE_FILE_ALIGN );
    g_headers_size = sizeof_headers;

    /* assign RVAs / file offsets to the real sections, build imports content,
    ** relocations, .reloc — all needs the headers size. Done by the caller
    ** before emit; here we just serialize. */

    /* resolve entry */
    eg = gsym_find( L, L->entry );
    if ( !eg || !eg->defined ) return lerr( L, "entry symbol '%s' undefined", L->entry );
    entry_rva = eg->rva;

    /* ---- DOS header + stub ---- */
    if ( !b_zero( &file, DOS_STUB_LEN ) ) return lerr( L, "oom", NULL );
    file.p[0] = 'M'; file.p[1] = 'Z';
    w32( file.p + 0x3C, pe_off );           /* e_lfanew                        */
    /* a minimal DOS stub that prints nothing is fine; leave zeros */

    /* ---- PE signature ---- */
    { uint8_t sig[4] = { 'P','E',0,0 }; if ( !b_putn( &file, sig, 4 ) ) return lerr( L, "oom", NULL ); }

    /* ---- IMAGE_FILE_HEADER (20) ---- */
    {
        uint8_t fh[20]; memset( fh, 0, 20 );
        w16( fh + 0, 0x8664 );              /* Machine AMD64                   */
        w16( fh + 2, ( uint16_t )nsec );    /* NumberOfSections                */
        w32( fh + 4, 0 );                   /* TimeDateStamp                   */
        w32( fh + 8, 0 );                   /* PointerToSymbolTable (stripped) */
        w32( fh + 12, 0 );                  /* NumberOfSymbols                 */
        w16( fh + 16, ( uint16_t )opt_hdr_size );
        /* EXECUTABLE | LARGE_ADDRESS_AWARE | LINE_NUMS_STRIPPED |
        ** LOCAL_SYMS_STRIPPED | DEBUG_STRIPPED */
        w16( fh + 18, 0x0002 | 0x0020 | 0x0004 | 0x0008 | 0x0200 );
        if ( !b_putn( &file, fh, 20 ) ) return lerr( L, "oom", NULL );
    }

    /* ---- IMAGE_OPTIONAL_HEADER64 (0xF0) ---- */
    {
        uint8_t oh[0xF0]; memset( oh, 0, sizeof oh );
        uint32_t size_code = L->out[OS_TEXT].file_size;
        uint32_t size_init = 0, size_uninit = L->out[OS_BSS].virt_size;
        for ( k = 0; k < N_SECORDER; k++ ) {
            int oi = kSecOrder[k];
            if ( oi == OS_TEXT || oi == OS_BSS ) continue;
            if ( L->out[oi].present ) size_init += L->out[oi].file_size;
        }
        w16( oh + 0, 0x020B );              /* Magic PE32+                     */
        oh[2] = 14; oh[3] = 0;              /* Linker version                  */
        w32( oh + 4, size_code );
        w32( oh + 8, size_init );
        w32( oh + 12, size_uninit );
        w32( oh + 16, entry_rva );          /* AddressOfEntryPoint             */
        w32( oh + 20, L->out[OS_TEXT].rva );/* BaseOfCode                      */
        w64( oh + 24, L->image_base );      /* ImageBase                       */
        w32( oh + 32, PE_SECT_ALIGN );      /* SectionAlignment                */
        w32( oh + 36, PE_FILE_ALIGN );      /* FileAlignment                   */
        w16( oh + 40, 4 ); w16( oh + 42, 0 );   /* OS version 4.0              */
        w16( oh + 44, 0 ); w16( oh + 46, 0 );   /* Image version               */
        w16( oh + 48, 5 ); w16( oh + 50, 2 );   /* Subsystem version 5.02      */
        w32( oh + 52, 0 );                  /* Win32VersionValue               */
        w32( oh + 56, total_image_size( L ) );  /* SizeOfImage                 */
        w32( oh + 60, sizeof_headers );     /* SizeOfHeaders                   */
        w32( oh + 64, 0 );                  /* CheckSum (0 ok for non-driver)  */
        w16( oh + 68, 3 );                  /* Subsystem = CONSOLE             */
        /* DllCharacteristics: HIGH_ENTROPY_VA|DYNAMIC_BASE|NX_COMPAT|TS_AWARE */
        w16( oh + 70, 0x0020 | 0x0040 | 0x0100 | 0x8000 );
        w64( oh + 72, 0x200000 );           /* SizeOfStackReserve 2 MB         */
        w64( oh + 80, 0x1000 );             /* SizeOfStackCommit               */
        w64( oh + 88, 0x100000 );           /* SizeOfHeapReserve               */
        w64( oh + 96, 0x1000 );             /* SizeOfHeapCommit                */
        w32( oh + 104, 0 );                 /* LoaderFlags                     */
        w32( oh + 108, NUM_DIRS );          /* NumberOfRvaAndSizes             */
        /* data directories start at oh+112, 8 bytes each (rva,size) */
        if ( L->nimports > 0 ) {
            uint32_t iat_rva = L->out[OS_IDATA].rva + il->iat_base;
            uint32_t iat_size = 0; int q;
            for ( q = 0; q < ( int )il->ndlls; q++ ) iat_size += ( il->dll_count[q] + 1 ) * 8;
            w32( oh + 112 + DIR_IMPORT*8 + 0, L->out[OS_IDATA].rva + il->descr_off );
            w32( oh + 112 + DIR_IMPORT*8 + 4, ( il->ndlls + 1 ) * 20 );
            w32( oh + 112 + DIR_IAT*8 + 0, iat_rva );
            w32( oh + 112 + DIR_IAT*8 + 4, iat_size );
        }
        if ( L->out[OS_RELOC].present ) {
            w32( oh + 112 + DIR_BASERELOC*8 + 0, L->out[OS_RELOC].rva );
            w32( oh + 112 + DIR_BASERELOC*8 + 4, ( uint32_t )L->out[OS_RELOC].raw.len );
        }
        if ( L->out[OS_PDATA].present ) {
            w32( oh + 112 + DIR_EXCEPTION*8 + 0, L->out[OS_PDATA].rva );
            w32( oh + 112 + DIR_EXCEPTION*8 + 4, L->out[OS_PDATA].virt_size );
        }
        /* TLS directory: _tls_used points at the IMAGE_TLS_DIRECTORY64 (0x28
        ** bytes) the mingw CRT builds. Without this, TLS callbacks / __tls_*
        ** init never run and TLS-using startup faults. */
        {
            GSym *tu = gsym_find( L, "_tls_used" );
            if ( tu && tu->defined ) {
                w32( oh + 112 + DIR_TLS*8 + 0, tu->rva );
                w32( oh + 112 + DIR_TLS*8 + 4, 0x28 );
            }
        }
        if ( !b_putn( &file, oh, sizeof oh ) ) return lerr( L, "oom", NULL );
    }

    /* ---- section headers ---- */
    sechdr_off = ( uint32_t )file.len;
    (void)sechdr_off;
    for ( k = 0; k < N_SECORDER; k++ ) {
        int oi = kSecOrder[k];
        OutSec *os = &L->out[oi];
        uint8_t sh[40]; char nm[8];
        if ( !os_emitted( os ) ) continue;
        memset( sh, 0, 40 );
        memset( nm, 0, 8 );
        memcpy( nm, os->name, strlen( os->name ) < 8 ? strlen( os->name ) : 8 );
        memcpy( sh, nm, 8 );
        w32( sh + 8,  os->virt_size );      /* VirtualSize                     */
        w32( sh + 12, os->rva );            /* VirtualAddress                  */
        if ( oi == OS_BSS ) {
            w32( sh + 16, 0 );              /* SizeOfRawData                   */
            w32( sh + 20, 0 );              /* PointerToRawData                */
        } else {
            w32( sh + 16, os->file_size );
            w32( sh + 20, os->file_off );
        }
        w32( sh + 36, os->characteristics );
        if ( !b_putn( &file, sh, 40 ) ) return lerr( L, "oom", NULL );
    }

    /* pad headers to FILE_ALIGN */
    if ( !b_pad( &file, PE_FILE_ALIGN ) ) return lerr( L, "oom", NULL );

    /* ---- section raw data, in file-offset order ---- */
    for ( k = 0; k < N_SECORDER; k++ ) {
        int oi = kSecOrder[k];
        OutSec *os = &L->out[oi];
        if ( oi == OS_BSS ) continue;
        if ( !os_emitted( os ) ) continue;
        if ( os->file_size == 0 ) continue;
        /* pad file to this section's file offset */
        while ( file.len < os->file_off ) if ( !b_zero( &file, 1 ) ) return lerr( L, "oom", NULL );
        if ( !b_putn( &file, os->raw.p, os->raw.len ) ) return lerr( L, "oom", NULL );
        while ( file.len < ( size_t )os->file_off + os->file_size )
            if ( !b_zero( &file, 1 ) ) return lerr( L, "oom", NULL );
    }

    /* ---- write ---- */
    f = fopen( out_path, "wb" );
    if ( !f ) { free( file.p ); return lerr( L, "cannot open output %s", out_path ); }
    if ( fwrite( file.p, 1, file.len, f ) != file.len ) { fclose( f ); free( file.p ); return lerr( L, "short write", NULL ); }
    fclose( f );
    free( file.p );
    return 1;
}

/* ===================================================================
** Public entry: LcPe_Link.
=================================================================== */
static void linker_free( Linker *L ) {
    int i;
    for ( i = 0; i < L->nobjs; i++ ) { LcCoff_Free( L->objs[i] ); free( L->objs[i] ); }
    free( L->objs );
    for ( i = 0; i < L->narchives; i++ ) LcAr_Close( &L->archives[i] );
    free( L->archives );
    if ( L->head_maps ) for ( i = 0; i < L->narchives; i++ ) free( L->head_maps[i] );
    free( L->head_maps ); free( L->head_map_n ); free( L->head_map_done );
    free( L->ar_is_implib );
    if ( L->ar_pulled ) for ( i = 0; i < L->narchives; i++ ) free( L->ar_pulled[i] );
    free( L->ar_pulled ); free( L->ar_npulled ); free( L->ar_cappulled );
    for ( i = 0; i < L->nsyms; i++ ) { free( L->syms[i].name ); free( L->syms[i].weak_default ); }
    free( L->syms );
    free( L->sym_slots );
    free( L->contribs );
    free( L->contrib_map.slots );
    for ( i = 0; i < OS_COUNT; i++ ) free( L->out[i].raw.p );
    for ( i = 0; i < L->nimports; i++ ) { free( L->imports[i].dll ); free( L->imports[i].func ); }
    free( L->imports );
    free( L->relocs );
}

int LcPe_Link( const LcPeLinkInputs *in, char *err, size_t errlen ) {
    Linker L;
    ImportLayout il;
    int i, rc = 0;
    uint32_t sizeof_headers, nsec;

    memset( &L, 0, sizeof L );
    memset( &il, 0, sizeof il );
    L.entry = ( in->entry && in->entry[0] ) ? in->entry : PE_DEF_ENTRY;
    L.image_base = PE_IMAGE_BASE;
    L.gc_sections = !in->no_gc_sections;   /* default ON; escape via input flag */

    /* open archives first (kept open for the fixpoint) */
    if ( in->narchives > 0 ) {
        L.archives     = ( LcArchive * )calloc( in->narchives, sizeof( LcArchive ) );
        L.head_maps    = ( void ** )calloc( in->narchives, sizeof( void * ) );
        L.head_map_n   = ( int * )calloc( in->narchives, sizeof( int ) );
        L.head_map_done= ( int * )calloc( in->narchives, sizeof( int ) );
        L.ar_is_implib = ( int * )calloc( in->narchives, sizeof( int ) );
        L.ar_pulled    = ( void ** )calloc( in->narchives, sizeof( void * ) );
        L.ar_npulled   = ( int * )calloc( in->narchives, sizeof( int ) );
        L.ar_cappulled = ( int * )calloc( in->narchives, sizeof( int ) );
        if ( !L.archives || !L.head_maps || !L.head_map_n || !L.head_map_done ||
             !L.ar_is_implib || !L.ar_pulled || !L.ar_npulled || !L.ar_cappulled ) {
            snprintf( err, errlen, "oom" ); goto out;
        }
        for ( i = 0; i < in->narchives; i++ ) L.ar_is_implib[i] = -1;
        for ( i = 0; i < in->narchives; i++ ) {
            if ( !LcAr_Open( in->archives[i], &L.archives[ L.narchives ], err, errlen ) )
                goto out;
            L.narchives++;
        }
    }

    /* load explicit objects in order (definitions shadow archives) */
    for ( i = 0; i < in->nobjects; i++ ) {
        if ( !load_object_file( &L, in->objects[i] ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }
    }

    /* force-undefined roots (e.g. Clua_OpenFfi, the entry symbol). These are
    ** `-u` requests: they drive archive extraction even if the only other
    ** reference is weak (aot_entry weak-calls Clua_OpenFfi). */
    {
        GSym *eg = gsym_intern( &L, L.entry );
        if ( !eg ) { snprintf( err, errlen, "oom" ); goto out; }
        eg->force_resolve = 1;
    }
    for ( i = 0; i < in->nforce_undef; i++ ) {
        GSym *fg = gsym_intern( &L, in->force_undef[i] );
        if ( !fg ) { snprintf( err, errlen, "oom" ); goto out; }
        fg->force_resolve = 1;
    }

    /* define linker-provided symbols (__ImageBase etc.) so the fixpoint treats
    ** them as satisfied rather than chasing them through the archives */
    if ( !define_linker_symbols( &L ) ) { snprintf( err, errlen, "oom" ); goto out; }

    /* resolve to fixpoint, pulling archive members + synthesizing imports */
    if ( !resolve_fixpoint( &L ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }

    /* collect contributions (COMDAT-deduped) */
    if ( !collect_contribs( &L ) ) { snprintf( err, errlen, "%s", L.err[0]?L.err:"collect failed" ); goto out; }
    if ( !contrib_map_build( &L ) ) { snprintf( err, errlen, "%s", "oom (contribution index)" ); goto out; }

    /* --gc-sections: drop unreachable function/data sections before layout. */
    if ( !gc_sections( &L, in->force_undef, in->nforce_undef ) ) {
        snprintf( err, errlen, "%s", L.err ); goto out;
    }

    /* lay sections (no RVA yet) */
    if ( !layout_sections( &L ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }
    /* layout sorts the contribution array; refresh the integer-index map. */
    if ( !contrib_map_build( &L ) ) { snprintf( err, errlen, "%s", "oom (contribution index)" ); goto out; }

    /* synthesize imports into idata + thunks into text (offsets only) */
    if ( !build_imports( &L, &il ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }

    /* headers size depends on the final section count. .reloc is built later
    ** (it needs RVAs), so predict whether it will exist: any ADDR64 site
    ** produces a base relocation. Reserve its header slot up front so the
    ** computed SizeOfHeaders matches the final section count. */
    nsec = ( uint32_t )count_sections( &L );
    {
        int ci; int will_reloc = 0;
        for ( ci = 0; ci < L.ncontribs && !will_reloc; ci++ ) {
            LcCoffSection *sc;
            uint32_t r;
            if ( L.contribs[ci].dropped ) continue;
            sc = &L.contribs[ci].obj->sections[ L.contribs[ci].sec_index ];
            for ( r = 0; r < sc->nrelocs; r++ ) {
                uint16_t t = sc->relocs[r].type;
                if ( t == LC_IMAGE_REL_AMD64_ADDR64 ) { will_reloc = 1; break; }
            }
        }
        if ( will_reloc ) nsec++;   /* reserve the .reloc section header      */
    }
    sizeof_headers = align_up( DOS_STUB_LEN + 4 + 20 + 0xF0 + nsec * 40, PE_FILE_ALIGN );

    /* assign RVAs / file offsets */
    assign_rvas( &L, sizeof_headers );

    /* resolve every symbol address */
    if ( !resolve_addrs( &L, &il ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }

    /* apply relocations (records ADDR64 base-reloc sites) */
    if ( !apply_relocations( &L, &il ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }

    /* fill the import directory + thunks now that RVAs are final */
    if ( !finalize_imports( &L, &il ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }

    /* build + place .reloc */
    if ( !build_reloc_section( &L ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }
    place_reloc_section( &L );

    /* genuinely unresolved symbols are caught by apply_relocations (it errors
    ** on any reloc whose target can't be placed); symbols that are interned but
    ** never referenced by a reloc don't matter. */

    /* emit */
    if ( !emit_pe( &L, in->out_path, &il ) ) { snprintf( err, errlen, "%s", L.err ); goto out; }

    rc = 1;
out:
    import_layout_free( &il );
    linker_free( &L );
    return rc;
}
