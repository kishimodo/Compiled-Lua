/*
** passes.h — The LuaC optimization pipeline.
**
** Passes are grouped by delivery milestone (see ../../PROMPT.md §Phasing). Each
** is sound: it only fires when the closed-world proof holds, so output always
** matches the boxed Lua 5.4 semantics. The interprocedural passes iterate to a
** fixpoint over the call graph; FFI edges and any value of type LC_T_ANY act as
** conservative cut points.
**
** Ordering matters: build SSA + CFG analyses first, then local refinement, then
** the whole-program fixpoint, then lowering-prep.
*/
#ifndef LUAC_PASSES_H
#define LUAC_PASSES_H

#include "../ir/ir.h"

typedef struct LcPassConfig {
  int  opt_level;        /* -O0..-O3                                       */
  bool interprocedural;  /* enable the whole-program fixpoint (M2+)        */
  bool escape_analysis;  /* enable table escape/unbox (M3)                 */
  bool verify_each;      /* run lc_module_verify after every pass group.   */
                         /* NOT debug-only: driver/main.c sets it true     */
                         /* unconditionally, and verifies once more before */
                         /* codegen so -O0 (which skips lc_optimize) is    */
                         /* covered too. A failure is a hard error.        */
} LcPassConfig;

/* Run the whole pipeline. Returns false on an internal invariant failure. */
bool lc_optimize(LcModule *m, const LcPassConfig *cfg);

/* TRUE iff any function carries the string constant "debug" (conservative
** constant scan). Two consumers: -O1+ disables the type-inference proofs
** (reflection can falsify them), and the driver links the full bytecode
** interpreter only for such programs (debug hooks need it; a debug-free
** closed-world program can never activate a hook, so its exe links
** lvm_nointerp.o instead — see pe_link_v2.c). */
bool lc_module_uses_debug(LcModule *m);

/* TRUE iff any function mentions the string "ffi"/"bit" (conservative): the
** driver links the FFI anchor so the runtime globals exist in the exe. */
bool lc_module_uses_ffi(LcModule *m);

/* Which OPTIONAL standard libraries the program references, so the AOT exe
** opens (and links) only those -- a `print` hello-world drops table/io/os/math/
** utf8/string (~38 KB). Bit i set => the matching luaopen_* is needed. base,
** package and coroutine are always opened (not represented here). string is
** special: it backs the string metatable, so any value-indexing opcode
** (GETFIELD/GETI/GETTABLE/SELF) could hit a string and forces it on; a program
** that indexes nothing (and never names "string") drops it. The others are
** reached only through their global, so naming the constant suffices
** (conservative, like lc_module_uses_ffi). Bit values: common/stdlib_libs.h. */
#include "common/stdlib_libs.h"
unsigned lc_module_used_libs(LcModule *m);

/* ---- Analyses (no IR mutation; populate side tables) ---- */
void lc_analyze_dominators(LcFunc *f);
void lc_analyze_liveness(LcFunc *f);
void lc_build_callgraph(LcModule *m);

/* ---- M0: faithful baseline (correctness; removes interp/dispatch only) ---- */
void lc_pass_mem2reg(LcFunc *f);        /* registers -> SSA values         */
void lc_pass_dce(LcFunc *f);            /* dead-code elimination (effects)  */
void lc_pass_const_fold(LcFunc *f);     /* fold provable constants          */

/* ---- M1: per-function (local) specialization ---- */
void lc_pass_local_typeinfer(LcFunc *f);   /* intra-fn type lattice fixpoint */
void lc_pass_specialize_arith(LcFunc *f);  /* ARITH -> IARITH/FARITH; unbox   */
void lc_pass_unbox_locals(LcFunc *f);      /* keep scalars in raw regs        */
void lc_pass_devirt_local(LcFunc *f);      /* known local/closure -> DIRECT    */
void lc_pass_raw_table(LcFunc *f);         /* drop __index when no metatable  */
void lc_pass_inline_small(LcModule *m);    /* inline tiny leaf callees         */

/* ---- M2: whole-program (interprocedural) ---- */
void lc_pass_ip_typeprop(LcModule *m);     /* propagate arg/return types       */
void lc_pass_monomorphize(LcModule *m);    /* clone polymorphic fns per type    */
void lc_pass_ip_devirt(LcModule *m);       /* whole-program call devirt         */
void lc_pass_dead_global(LcModule *m);     /* unused globals/fields/functions   */

/* ---- M3: memory optimization ---- */
void lc_pass_escape(LcModule *m);          /* escape analysis                   */
void lc_pass_scalar_replace(LcModule *m);  /* explode non-escaping tables        */
void lc_pass_barrier_elide(LcFunc *f);     /* drop provably-unneeded GC barriers */

/* ---- lowering prep (always) ---- */
void lc_pass_lower(LcFunc *f);             /* canonicalize to codegen-ready ops  */
void lc_pass_safepoints(LcFunc *f);        /* insert GC safepoints on back-edges */

#endif /* LUAC_PASSES_H */
