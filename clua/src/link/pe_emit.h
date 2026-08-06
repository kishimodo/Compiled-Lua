/*
** pe_emit.h — the CLua internal COFF -> PE64 linker (x86-64 Windows only).
**
** Replaces the MinGW gcc/ld invocation in pe_link_v2.c: takes the same input
** set today's gcc command consumes (the user COFF, aot_entry.o, the optional
** lvm_nointerp.o, the runtime/Lua archives, plus the MinGW CRT pieces from a
** prepared sysroot directory) and emits a runnable console PE directly — no
** external toolchain at user-build time.
**
** Link semantics implemented (the subset the CLua input set exercises, held
** to ld-compatible behavior):
**   * archives: GNU symbol index ("/" member, "//" long names), pulled by an
**     iterate-to-fixpoint loop with first-definition-wins (explicit objects
**     load first, so aot_entry.o's closed-world stubs shadow the Lua parser
**     members exactly like the gcc link)
**   * COMDAT sections (select-any dedup; MinGW .refptr.* / CRT bits)
**   * weak externals (IMAGE_SYM_CLASS_WEAK_EXTERNAL; unresolved weak -> its
**     default symbol, i.e. absolute 0 — aot_entry's Clua_OpenFfi probe)
**   * COMMON symbols (allocated into .bss)
**   * AMD64 relocations: ADDR64, ADDR32NB, REL32, REL32_1..5, SECREL, SECTION
**   * grouped sections sorted by $-suffix (.CRT$XC*, .idata$2..7, .rdata$*),
**     ld-script synthesis: __CTOR_LIST__/__DTOR_LIST__ blocks, the import
**     directory null terminator, the pseudo-reloc list bounds, __ImageBase
**   * long (dlltool) import members AND short import members (the latter get
**     their thunk + .idata$* pieces synthesized per DLL)
**   * .pdata sorted by BeginAddress; TLS directory via _tls_used;
**     .reloc (DIR64) generated from ADDR64 sites
**
** Output invariants: ImageBase 0x140000000, console subsystem 5.02, entry
** mainCRTStartup (configurable), DYNAMIC_BASE|NX_COMPAT|HIGH_ENTROPY_VA|
** TERMINAL_SERVER_AWARE, 2 MB stack reserve, no COFF symbol table (stripped
** by construction), PE checksum filled in.
*/
#ifndef LUAC_LINK_PE_EMIT_H
#define LUAC_LINK_PE_EMIT_H

#include <stddef.h>
#include <stdint.h>

/* PE output subsystem. exe (default) shipped every build before this arc;
   dll flips IMAGE_FILE_DLL, builds an export directory from `exports[]`, and
   picks Rt_DllMain as the entry. Kept behind an enum in case a further kind
   (sys, driver, etc.) is added later. */
enum { LC_PE_OUTPUT_EXE = 0, LC_PE_OUTPUT_DLL = 1 };

/* --strip=<mode>, mirrored into the linker so gc_keep_by_name / debug-section
** emission can react. Kept in lock-step with driver/aotc.h LcStripMode enum:
**   LC_PE_STRIP_ALL   (0): default; drop every debug section (.clualn, ...)
**                          -- matches the pre-flag baseline byte-for-byte.
**   LC_PE_STRIP_DEBUG (1): same as ALL today (nothing else the loader can
**                          ignore is emitted right now); reserved for the
**                          future when the internal linker starts writing
**                          a COFF symbol table by default.
**   LC_PE_STRIP_NONE  (2): keep every section, including .clualn even when
**                          gc-sections would otherwise sweep it. Grows the
**                          exe; useful when a downstream debugger wants the
**                          native-pc -> Lua-line map without recompiling. */
enum {
    LC_PE_STRIP_ALL   = 0,
    LC_PE_STRIP_DEBUG = 1,
    LC_PE_STRIP_NONE  = 2
};

typedef struct LcPeLinkInputs {
    const char *const *objects;     /* explicit .o paths, loaded in order    */
    int                nobjects;
    const char *const *archives;    /* .a paths, searched in order           */
    int                narchives;
    const char *const *force_undef; /* extra root undefineds (-u equivalent,
                                       e.g. Clua_OpenFfi for FFI programs)   */
    int                nforce_undef;
    const char        *entry;       /* entry symbol; NULL = "mainCRTStartup" */
    const char        *out_path;    /* output PE path                        */
    int                no_gc_sections; /* 1 = disable --gc-sections dead-code
                                       ** elimination (debug escape hatch);
                                       ** 0 (default) drops unreachable
                                       ** function/data sections like ld's
                                       ** --gc-sections.                      */
    /* DLL output. Ignored when output_kind == LC_PE_OUTPUT_EXE. */
    int                output_kind;     /* LC_PE_OUTPUT_EXE (default) or _DLL */
    const char *const *export_names;    /* alphabetical is nice but not required;
                                           the linker sorts before emit         */
    int                nexport_names;
    /* Per-export C-ABI shape token, one entry per export_names[] slot. NULL
       (or NULL slots) mean "use the default `dd_d` dispatcher"; the recognised
       tokens are `dd_d`, `ii_i`, `s_s` -- see build_export_trampolines /
       aot_entry_dll.c for the marshalling those tokens promise. The linker
       keeps this array paired with export_names[] across the sort inside
       build_exports, so the caller need not pre-sort. */
    const char *const *export_abi_shapes;
    const char        *dll_module_name; /* the DLLName field in the export dir;
                                           NULL falls back to the basename of
                                           out_path                             */
    int                strip_mode;      /* LC_PE_STRIP_ALL (default) /
                                           _DEBUG / _NONE. Threaded from the
                                           driver's --strip=<mode>.             */

    /* .rsrc content. When any of these is non-NULL/nonzero, an .rsrc section
    ** is emitted and the PE RESOURCE data directory populated. All three are
    ** optional; passing all NULL leaves the exe resource-less (byte-identical
    ** to the pre-.rsrc output). Bytes are OWNED BY THE CALLER; the linker
    ** reads them during build and does not free them.                        */
    const uint8_t     *rsrc_versioninfo;      /* VS_VERSION_INFO blob         */
    uint32_t           rsrc_versioninfo_len;
    const uint8_t     *rsrc_manifest;         /* RT_MANIFEST XML payload       */
    uint32_t           rsrc_manifest_len;
    const uint8_t     *rsrc_icon;             /* raw .ico file bytes           */
    uint32_t           rsrc_icon_len;
} LcPeLinkInputs;

/* Link. Returns 1 on success, 0 + a message in err. */
int LcPe_Link( const LcPeLinkInputs *in, char *err, size_t errlen );

#endif /* LUAC_LINK_PE_EMIT_H */
