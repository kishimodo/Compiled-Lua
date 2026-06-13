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
} LcPeLinkInputs;

/* Link. Returns 1 on success, 0 + a message in err. */
int LcPe_Link( const LcPeLinkInputs *in, char *err, size_t errlen );

#endif /* LUAC_LINK_PE_EMIT_H */
