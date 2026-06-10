/*
** codegen.c — Optimized IR -> relocatable x64. See codegen.h and ../../PROMPT.md §11.
** STUB: implement for Milestone M0 (generic lowering: every op -> Rt_* / luaV_* call).
**
** REUSE src/codegen/x64_emit.* (adapted from src/jit/emit_x64.*) for encoding and
**       src/codegen/regalloc.* (adapted from src/jit/regalloc.*) for allocation.
** NEW vs the v1 JIT: LcReloc table instead of baked imm64, RIP-relative .rdata
**       loads, .pdata/.xdata UNWIND_INFO per framed function, GC stack maps.
**
** Win64 ABI (preserve from v1): RCX=lua_State*, RDX/R8/R9=operands, RAX=return,
** Lua reg N at [RDI + N*16], tag at +8. Reserve 32B shadow space; keep RSP%16==0
** at calls; reload RDI+cache after stack-relocating helpers; 8-bit tag compares.
*/
#include "codegen.h"
#include <stdlib.h>

LcCodeModule *lc_codegen(LcModule *m) {
  (void)m;
  LcCodeModule *cm = (LcCodeModule *)calloc(1, sizeof(LcCodeModule));
  /* TODO(M0): for each LcFunc:
  **   - emit prologue (save callee-saved regs, RBX=L, RDI=stack base, reserve frame)
  **   - per-instruction lowering: generic ops -> CALL Rt_* / luaV_* (record LcReloc),
  **     typed ops (M1+) -> inline machine code
  **   - emit epilogue; build UNWIND_INFO describing the prologue
  **   - collect forward-branch placeholders, patch after the instruction loop
  **   - emit the GC stack map for each safepoint
  ** Pool string/float constants into cm->rodata; reference via RIP-relative + LcReloc.
  */
  return cm;
}

void lc_codemodule_free(LcCodeModule *cm) {
  if (!cm) return;
  /* TODO(M0): free per-func code/relocs/unwind/stackmap and rodata. */
  free(cm);
}
