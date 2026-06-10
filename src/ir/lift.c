/*
** lift.c — Bytecode -> SSA IR. See lift.h and ../../PROMPT.md §8.
** STUB: implement for Milestone M0 (faithful, generic, boxed lowering).
**
** M0 algorithm:
**   for each RESOLVED_MODULE_T: lundump bytes -> Proto*; lc_func_new per Proto.
**   per function: build CFG from jump targets; SSA-construct over register slots;
**   map each opcode to its GENERIC IR op (see the table in lift.h / PROMPT §8);
**   record call-graph edges; mark ffi/C callees as LC_FX_FFI_BARRIER.
**   NO optimization here.
*/
#include "lift.h"
#include "ir.h"

/* Upstream front-end handle. */
typedef struct Proto Proto;

LcModule *lc_lift_program(Proto *entry, Proto **reachable, uint32_t nreachable) {
  (void)entry; (void)reachable; (void)nreachable;
  LcModule *m = lc_module_new();
  /* TODO(M0):
  **   for (i = 0; i < nreachable; i++) lc_lift_func(lc_func_new(m, reachable[i]));
  **   m->entry = <func for entry>;
  **   lc_build_callgraph(m) is run by the opt pipeline, not here.
  */
  return m;
}

void lc_lift_func(LcFunc *f) {
  (void)f;
  /* TODO(M0):
  **   1. decode f->source->code[] into basic blocks (split at jump targets).
  **   2. SSA construction (dominance-frontier phi insertion) over Lua registers.
  **   3. per-opcode generic lowering; fuse LOADKX/NEWTABLE + EXTRAARG.
  **   4. globals -> LC_OP_GLOBAL_GET/SET on _ENV (upvalue 0).
  **   5. pcall/xpcall regions -> LC_OP_PCALL_BEGIN/END.
  */
}
