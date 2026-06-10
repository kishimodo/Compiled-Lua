/*
** pe_write.c — Standard PE writer. See pe_write.h and ../../PROMPT.md §12.
** STUB: implement for Milestone M0.
**
** Bring-up recommendation (strategy B): emit one COFF object per function via
** lc_emit_coff() and delegate final linking to the MinGW `ld` already in the
** toolchain, against the prebuilt runtime-embedded.a. Graduate to the
** self-contained writer (strategy A) once relocations + unwind are solid.
**
** Either way the output has ONLY standard sections — no blob, no overlay,
** no module searcher. PostLinkPatchPE (ported from v1 pe_link.c) must PRESERVE
** .pdata/.xdata (load-bearing for SEH unwind).
*/
#include "pe_write.h"
#include <stdio.h>
#include <string.h>

bool lc_write_pe(const LcCodeModule *cm, const LcLinkOptions *opt,
                 char *err, size_t errlen) {
  (void)cm; (void)opt;
  /* TODO(M0):
  **   Strategy B: write COFF objs, then invoke ld:
  **     ld -o <out> <user objs...> <package objs...> runtime-embedded.a \
  **        -lkernel32 -ladvapi32 -liphlpapi -lpsapi  (+ --image-base / --gc-sections)
  **   Strategy A: lay out sections, resolve LcReloc against the runtime symbol
  **     table, write headers + .text/.rdata/.data/.bss/.pdata/.xdata/.reloc/.idata.
  */
  if (err && errlen) snprintf(err, errlen, "lc_write_pe: not implemented");
  return false;
}

bool lc_emit_coff(const LcCompiledFunc *f, const char *out_obj) {
  (void)f; (void)out_obj;
  /* TODO(M0): emit a COFF object: .text section = f->code, symbol table entry
  ** f->symbol, relocations from f->relocs (HELPER/LUAFUNC/RODATA/IMPORT ->
  ** IMAGE_REL_AMD64_REL32 / ADDR64), .pdata/.xdata from f->unwind. */
  return false;
}
