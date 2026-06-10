/*
** passes.c — Optimization pipeline driver. See passes.h and ../../PROMPT.md §9.
** STUB: M0 needs only mem2reg/dce/const_fold + lower/safepoints to be real;
** the M1/M2/M3 passes can be no-ops until their milestone.
**
** GOVERNING PRINCIPLE: sound-conservative. A pass fires only when the
** closed-world proof holds; otherwise the value stays LC_T_ANY and codegen emits
** the generic dynamic path. No deopt, no guards. When unsure, do nothing.
*/
#include "passes.h"

bool lc_optimize(LcModule *m, const LcPassConfig *cfg) {
  if (!m || !cfg) return false;

  lc_build_callgraph(m);

  for (uint32_t i = 0; i < m->nfuncs; i++) {
    LcFunc *f = m->funcs[i];
    lc_analyze_dominators(f);
    lc_analyze_liveness(f);

    /* M0 — faithful baseline */
    lc_pass_mem2reg(f);
    lc_pass_const_fold(f);
    lc_pass_dce(f);
  }

  if (cfg->opt_level >= 1) {
    for (uint32_t i = 0; i < m->nfuncs; i++) {
      LcFunc *f = m->funcs[i];
      lc_pass_local_typeinfer(f);
      lc_pass_specialize_arith(f);
      lc_pass_unbox_locals(f);
      lc_pass_devirt_local(f);
      lc_pass_raw_table(f);
    }
    lc_pass_inline_small(m);
  }

  if (cfg->opt_level >= 2 && cfg->interprocedural) {
    lc_pass_ip_typeprop(m);
    lc_pass_monomorphize(m);
    lc_pass_ip_devirt(m);
    lc_pass_dead_global(m);
  }

  if (cfg->opt_level >= 3 && cfg->escape_analysis) {
    lc_pass_escape(m);
    lc_pass_scalar_replace(m);
    for (uint32_t i = 0; i < m->nfuncs; i++) lc_pass_barrier_elide(m->funcs[i]);
  }

  /* lowering prep — always */
  for (uint32_t i = 0; i < m->nfuncs; i++) {
    lc_pass_lower(m->funcs[i]);
    lc_pass_safepoints(m->funcs[i]);
  }

  return true;
}

/* ---- STUB pass bodies: implement per milestone (PROMPT §9). ---- */
void lc_analyze_dominators(LcFunc *f) { (void)f; /* TODO(M0) */ }
void lc_analyze_liveness(LcFunc *f)   { (void)f; /* TODO(M0) */ }
void lc_build_callgraph(LcModule *m)  { (void)m; /* TODO(M2) complete graph + FFI sentinels */ }

void lc_pass_mem2reg(LcFunc *f)     { (void)f; /* TODO(M0) */ }
void lc_pass_dce(LcFunc *f)         { (void)f; /* TODO(M0) effect-aware */ }
void lc_pass_const_fold(LcFunc *f)  { (void)f; /* TODO(M0) */ }

void lc_pass_local_typeinfer(LcFunc *f)  { (void)f; /* TODO(M1) */ }
void lc_pass_specialize_arith(LcFunc *f) { (void)f; /* TODO(M1) exact 5.4 int/float */ }
void lc_pass_unbox_locals(LcFunc *f)     { (void)f; /* TODO(M1) */ }
void lc_pass_devirt_local(LcFunc *f)     { (void)f; /* TODO(M1) */ }
void lc_pass_raw_table(LcFunc *f)        { (void)f; /* TODO(M1) only if no reachable metatable */ }
void lc_pass_inline_small(LcModule *m)   { (void)m; /* TODO(M1) */ }

void lc_pass_ip_typeprop(LcModule *m)    { (void)m; /* TODO(M2) FFI/ANY are cut points */ }
void lc_pass_monomorphize(LcModule *m)   { (void)m; /* TODO(M2) keep ANY fallback clone */ }
void lc_pass_ip_devirt(LcModule *m)      { (void)m; /* TODO(M2) */ }
void lc_pass_dead_global(LcModule *m)    { (void)m; /* TODO(M2) */ }

void lc_pass_escape(LcModule *m)         { (void)m; /* TODO(M3) coro/pcall/ffi force escape */ }
void lc_pass_scalar_replace(LcModule *m) { (void)m; /* TODO(M3) */ }
void lc_pass_barrier_elide(LcFunc *f)    { (void)f; /* TODO(M3) HIGHEST RISK — prove or keep barrier */ }

void lc_pass_lower(LcFunc *f)            { (void)f; /* TODO(M0) canonicalize for codegen */ }
void lc_pass_safepoints(LcFunc *f)       { (void)f; /* TODO(M0) back-edges + throw-capable ops */ }
