/*
** ir.c — LcModule/LcFunc/LcBlock/LcInst construction + SSA verifier.
** See ir.h and ../../PROMPT.md §7. STUB: implement for Milestone M0.
*/
#include "ir.h"
#include <stdlib.h>
#include <string.h>

/* TODO(M0): arena-allocate modules/funcs/blocks/insts; dense id assignment. */

LcModule *lc_module_new(void) {
  LcModule *m = (LcModule *)calloc(1, sizeof(LcModule));
  return m;
}

void lc_module_free(LcModule *m) {
  /* TODO(M0): free arenas. */
  free(m);
}

LcFunc *lc_func_new(LcModule *m, Proto *p) {
  (void)m; (void)p;
  /* TODO(M0): allocate LcFunc, register in module, set source = p. */
  return NULL;
}

LcBlock *lc_block_new(LcFunc *f) {
  (void)f;
  /* TODO(M0): allocate block, append to f->blocks. */
  return NULL;
}

LcInst *lc_emit(LcBlock *b, LcOpcode op) {
  (void)b; (void)op;
  /* TODO(M0): allocate inst, append to block list, assign result id. */
  return NULL;
}

void lc_inst_add_arg(LcInst *in, LcValue *v) {
  (void)in; (void)v;
  /* TODO(M0): grow args[], record use for the def-use chain. */
}

/* ---- type lattice ---- */

LcType lc_type_meet(LcType a, LcType b) {
  /* TODO(M1): proper lattice meet (narrow). Placeholder widens to ANY on mismatch. */
  if (a.kind == b.kind) return a;
  LcType any; memset(&any, 0, sizeof(any)); any.kind = LC_T_ANY; return any;
}

LcType lc_type_join(LcType a, LcType b) {
  /* TODO(M1): proper lattice join (widen). */
  if (a.kind == b.kind) return a;
  LcType any; memset(&any, 0, sizeof(any)); any.kind = LC_T_ANY; return any;
}

bool lc_type_is_unboxable(LcType t) {
  return t.kind == LC_T_INT || t.kind == LC_T_FLT || t.kind == LC_T_BOOL;
}

bool lc_module_verify(LcModule *m, char *err, size_t errlen) {
  (void)m;
  /* TODO: assert SSA single-definition, dominance of uses, effect consistency,
  ** phi arity == pred count, no LC_OP_CALL_FFI marked PURE, etc. */
  if (err && errlen) err[0] = '\0';
  return true;
}
