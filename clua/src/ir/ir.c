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
  if (!m) return;
  /* Free every func, its blocks, and each block's instruction list. */
  for (uint32_t i = 0; i < m->nfuncs; i++) {
    LcFunc *f = m->funcs[i];
    if (!f) continue;
    for (uint32_t j = 0; j < f->nblocks; j++) {
      LcBlock *blk = f->blocks[j];
      if (!blk) continue;
      LcInst *in = blk->first;
      while (in) {
        LcInst *next = in->next;
        free(in->args);
        free(in);
        in = next;
      }
      free(blk->preds);
      free(blk->succs);
      free(blk);
    }
    free(f->blocks);
    free(f->args);
    free(f);
  }
  free(m->funcs);
  /* call-graph arrays, if any */
  if (m->callees) {
    for (uint32_t i = 0; i < m->nfuncs; i++) free(m->callees[i]);
  }
  free(m->callees);
  free(m->ncallees);
  free(m);
}

LcFunc *lc_func_new(LcModule *m, Proto *p) {
  LcFunc *f = (LcFunc *)calloc(1, sizeof(LcFunc));
  if (!f) return NULL;
  f->source = p;
  f->is_ssa = false;   /* M0 memory form until M1 mem2reg lifts to SSA */
  if (m) {
    LcFunc **grown = (LcFunc **)realloc(m->funcs,
                                        (m->nfuncs + 1) * sizeof(LcFunc *));
    if (!grown) { free(f); return NULL; }
    m->funcs = grown;
    m->funcs[m->nfuncs] = f;
    m->nfuncs++;
  }
  return f;
}

LcBlock *lc_block_new(LcFunc *f) {
  if (!f) return NULL;
  LcBlock *blk = (LcBlock *)calloc(1, sizeof(LcBlock));
  if (!blk) return NULL;
  blk->id = f->nblocks;
  LcBlock **grown = (LcBlock **)realloc(f->blocks,
                                        (f->nblocks + 1) * sizeof(LcBlock *));
  if (!grown) { free(blk); return NULL; }
  f->blocks = grown;
  f->blocks[f->nblocks] = blk;
  f->nblocks++;
  return blk;
}

LcInst *lc_emit(LcBlock *b, LcOpcode op) {
  if (!b) return NULL;
  LcInst *in = (LcInst *)calloc(1, sizeof(LcInst));
  if (!in) return NULL;
  in->op = op;
  /* Append to the block's doubly-linked instruction list. */
  in->prev = b->last;
  in->next = NULL;
  if (b->last) b->last->next = in;
  else         b->first = in;
  b->last = in;
  return in;
}

LcInst *lc_emit_bc(LcBlock *blk, LcOpcode op, int a, int b, int c, int bc_pc) {
  LcInst *in = lc_emit(blk, op);
  if (!in) return NULL;
  in->a = a;
  in->b = b;
  in->c = c;
  in->bc_pc = bc_pc;
  return in;
}

void lc_inst_add_arg(LcInst *in, LcValue *v) {
  if (!in) return;
  LcValue **grown = (LcValue **)realloc(in->args,
                                        (in->nargs + 1) * sizeof(LcValue *));
  if (!grown) return;
  in->args = grown;
  in->args[in->nargs] = v;
  in->nargs++;
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
  if (err && errlen) err[0] = '\0';
  /* M0 memory form: functions are pre-SSA (is_ssa == false), so the
  ** SSA-specific invariants (single-definition, dominance, phi arity ==
  ** pred count, no LC_OP_CALL_FFI marked PURE, ...) do NOT yet hold and
  ** must be gated behind f->is_ssa once M1 mem2reg runs.
  ** TODO(M1): assert those invariants for is_ssa functions. */
  (void)m;
  return true;
}
