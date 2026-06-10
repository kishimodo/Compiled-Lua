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
#include "lobject.h"
#include "lopcodes.h"
#include <stdlib.h>
#include <string.h>

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

/* ---- M1 local type inference (forward dataflow fixpoint) ----------------- */
/* Lattice (per Lua register, per program point): TOP = not-yet-reached (meet
   identity), INT/FLT = proven that type on ALL reaching paths, UNK = bottom
   (could be anything). Meet narrows toward UNK. The result annotates each
   arith/compare LcInst with which operand registers are provably integer ON
   ENTRY, so codegen can drop the runtime tag-check (sound-conservative: when in
   doubt the reg stays UNK and the checked fastpath/helper runs). */
enum { TI_TOP = 0, TI_INT = 1, TI_FLT = 2, TI_UNK = 3 };

static int ti_meet(int a, int b) {
  if (a == TI_TOP) return b;
  if (b == TI_TOP) return a;
  if (a == b) return a;
  return TI_UNK;
}
static int ti_reg(const int8_t *st, int r, int n) {
  return (r >= 0 && r < n) ? st[r] : TI_UNK;
}
static int ti_ktype(Proto *p, int idx) {
  if (!p || idx < 0 || idx >= p->sizek) return TI_UNK;
  if (ttisinteger(&p->k[idx])) return TI_INT;
  if (ttisfloat(&p->k[idx]))   return TI_FLT;
  return TI_UNK;
}
static int ti_isnum(int t) { return t == TI_INT || t == TI_FLT; }
static int ti_combine(int tb, int tc) {            /* +,-,*,//,% operand types */
  if (tb == TI_INT && tc == TI_INT) return TI_INT;
  if (ti_isnum(tb) && ti_isnum(tc)) return TI_FLT;
  return TI_UNK;                                   /* string-coerce / metamethod */
}
/* SOUNDNESS: a value is provably a primitive number ONLY when the producing op
   cannot dispatch to a metamethod -- i.e. its operands are themselves proven
   primitive numbers (integers/floats carry no per-value metatable, so arith/
   bitwise on two proven primitives never runs Lua code). Ops whose operand may
   be a table/string (with __len/__band/__add/...) must yield UNK, because the
   metamethod can return ANY type. (Found by the adversarial soundness attack:
   `#t`, `t & 1`, ~t etc. with metamethods returning a float/string were silently
   miscompiled when their result was assumed integer.) */
static int ti_int2(int tb, int tc) {               /* bitwise: int iff both int */
  return (tb == TI_INT && tc == TI_INT) ? TI_INT : TI_UNK;
}

/* Apply one instruction's effect to the register-type state `st` (out = in). */
static void ti_transfer(int8_t *st, LcInst *in, Proto *p, int n) {
  int A = in->a, B = in->b, C = in->c, i;
#define SET(r,t) do { if ((r) >= 0 && (r) < n) st[(r)] = (int8_t)(t); } while (0)
  switch (in->bc_op) {
    case OP_LOADI: SET(A, TI_INT); break;
    case OP_LOADF: SET(A, TI_FLT); break;
    case OP_LOADK: SET(A, ti_ktype(p, B)); break;          /* B carries Bx */
    case OP_MOVE:  SET(A, ti_reg(st, B, n)); break;
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_IDIV: case OP_MOD:
      SET(A, ti_combine(ti_reg(st, B, n), ti_reg(st, C, n))); break;
    case OP_DIV: case OP_POW:                               /* / and ^ -> float,  */
      SET(A, (ti_isnum(ti_reg(st, B, n)) && ti_isnum(ti_reg(st, C, n)))
               ? TI_FLT : TI_UNK); break;                   /* unless __div/__pow */
    case OP_DIVK: case OP_POWK:
      SET(A, (ti_isnum(ti_reg(st, B, n)) && ti_isnum(ti_ktype(p, C)))
               ? TI_FLT : TI_UNK); break;
    case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_IDIVK: case OP_MODK:
      SET(A, ti_combine(ti_reg(st, B, n), ti_ktype(p, C))); break;
    case OP_ADDI: {
      int tb = ti_reg(st, B, n);
      SET(A, tb == TI_INT ? TI_INT : tb == TI_FLT ? TI_FLT : TI_UNK);
    } break;
    case OP_UNM: {                                          /* __unm if non-number */
      int tb = ti_reg(st, B, n);
      SET(A, tb == TI_INT ? TI_INT : tb == TI_FLT ? TI_FLT : TI_UNK);
    } break;
    /* bitwise: integer ONLY when operands are proven integers (else a __band/
       __bor/__bxor/__bnot/__shl/__shr metamethod could return any type). */
    case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR:
      SET(A, ti_int2(ti_reg(st, B, n), ti_reg(st, C, n))); break;
    case OP_BANDK: case OP_BORK: case OP_BXORK: case OP_SHLI: case OP_SHRI:
    case OP_BNOT:                                           /* reg + int imm/K     */
      SET(A, ti_reg(st, B, n) == TI_INT ? TI_INT : TI_UNK); break;
    case OP_LEN: SET(A, TI_UNK); break;        /* # honors __len -> ANY type */
    case OP_LOADNIL: for (i = A; i <= A + B && i < n; i++) if (i >= 0) st[i] = TI_UNK; break;
    case OP_SELF: SET(A, TI_UNK); SET(A + 1, TI_UNK); break;
    case OP_FORPREP: {                                      /* R[A+3] = loop var */
      int ti = ti_reg(st, A, n), ts = ti_reg(st, A + 2, n);
      SET(A + 3, (ti == TI_INT && ts == TI_INT) ? TI_INT : TI_UNK);
    } break;
    case OP_FORLOOP:
      SET(A + 3, ti_reg(st, A, n) == TI_INT ? TI_INT : TI_UNK); break;
    /* multi-result / frame-reshaping ops: clobber [A, n) to UNK (sound) */
    case OP_CALL: case OP_TAILCALL: case OP_VARARG: case OP_VARARGPREP:
    case OP_TFORCALL: case OP_TFORPREP: case OP_TFORLOOP:
      for (i = (in->bc_op == OP_VARARGPREP) ? 0 : A; i < n; i++) if (i >= 0) st[i] = TI_UNK;
      break;
    /* value-producing ops with a non-provable (UNK) result in R[A] */
    case OP_GETUPVAL: case OP_GETTABUP: case OP_GETTABLE: case OP_GETI:
    case OP_GETFIELD: case OP_NEWTABLE: case OP_CLOSURE: case OP_LOADKX:
    case OP_LOADFALSE: case OP_LFALSESKIP: case OP_LOADTRUE: case OP_NOT:
    case OP_CONCAT: case OP_TESTSET:
      SET(A, TI_UNK); break;
    /* no tracked-register write: control flow, stores, comparisons, returns */
    case OP_JMP: case OP_EQ: case OP_LT: case OP_LE: case OP_EQK: case OP_EQI:
    case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI: case OP_TEST:
    case OP_SETUPVAL: case OP_SETTABUP: case OP_SETTABLE: case OP_SETI:
    case OP_SETFIELD: case OP_SETLIST: case OP_RETURN: case OP_RETURN0:
    case OP_RETURN1: case OP_CLOSE: case OP_TBC: case OP_MMBIN: case OP_MMBINI:
    case OP_MMBINK: case OP_EXTRAARG:
      break;
    default:                                                /* unknown -> clobber */
      for (i = (A >= 0 ? A : 0); i < n; i++) st[i] = TI_UNK;
      break;
  }
#undef SET
}

void lc_pass_local_typeinfer(LcFunc *f) {
  Proto    *p;
  LcInst  **insts = NULL, *in;
  int      *idxof = NULL;          /* bc_pc -> linear index */
  int8_t   *st = NULL, *out = NULL, *captured = NULL;
  int       n = 0, nregs, maxpc = 0, i, r, changed, cap = 0;
  uint32_t  bi;

  if (!f || !f->source) return;
  p = f->source;
  nregs = p->maxstacksize;
  if (nregs <= 0) return;

  /* collect instructions in order; track max bc_pc for the target map */
  for (bi = 0; bi < f->nblocks; bi++)
    for (in = f->blocks[bi]->first; in; in = in->next) {
      if (n >= cap) { cap = cap ? cap * 2 : 64;
                      insts = (LcInst **)realloc(insts, cap * sizeof(*insts)); }
      insts[n++] = in;
      if (in->bc_pc > maxpc) maxpc = in->bc_pc;
    }
  if (n == 0) { free(insts); return; }

  idxof = (int *)malloc((maxpc + 2) * sizeof(int));
  for (i = 0; i <= maxpc + 1; i++) idxof[i] = -1;
  for (i = 0; i < n; i++) if (insts[i]->bc_pc >= 0) idxof[insts[i]->bc_pc] = i;

  /* SOUNDNESS (upvalue aliasing): a local/loop-var captured as an open upvalue
     by a nested closure can be MUTATED to any type from inside that closure via
     OP_SETUPVAL (which writes the aliased parent stack slot). The dataflow has no
     cross-closure model, so any such register must never be trusted as a proven
     type. Collect every register captured `instack` by a nested Proto and force
     it to UNK after each transfer. (Found by the adversarial attack: an int
     for-loop var `i` captured by `function() i = 9.5 end` was elided as integer.) */
  captured = (int8_t *)calloc((size_t)nregs, 1);
  for (i = 0; i < n; i++) {
    if (insts[i]->bc_op == OP_CLOSURE && insts[i]->bc_pc >= 0 &&
        insts[i]->bc_pc < p->sizecode) {
      int bx = GETARG_Bx(p->code[insts[i]->bc_pc]);
      if (bx >= 0 && bx < p->sizep && p->p[bx]) {
        Proto *np = p->p[bx];
        int j;
        for (j = 0; j < np->sizeupvalues; j++)
          if (np->upvalues[j].instack && np->upvalues[j].idx < nregs)
            captured[np->upvalues[j].idx] = 1;
      }
    }
  }

  /* in_state[i*nregs + r] = type of reg r on entry to inst i (TOP initially) */
  st  = (int8_t *)calloc((size_t)n * nregs, 1);   /* TI_TOP == 0 */
  out = (int8_t *)malloc(nregs);
  for (r = 0; r < nregs; r++) st[r] = TI_UNK;     /* entry: params/locals UNK */

  /* iterate to fixpoint */
  changed = 1;
  while (changed) {
    changed = 0;
    for (i = 0; i < n; i++) {
      int succ[2], ns = 0, k, op = insts[i]->bc_op, tgt;
      memcpy(out, &st[(size_t)i * nregs], nregs);
      ti_transfer(out, insts[i], p, nregs);
      for (r = 0; r < nregs; r++) if (captured[r]) out[r] = TI_UNK;  /* upvalue alias */
      /* successors */
      switch (op) {
        case OP_RETURN: case OP_RETURN0: case OP_RETURN1: case OP_TAILCALL:
          break;                                  /* terminators: no successor */
        case OP_JMP:
          tgt = (insts[i]->c >= 0 && insts[i]->c <= maxpc) ? idxof[insts[i]->c] : -1;
          if (tgt >= 0) succ[ns++] = tgt;
          break;
        case OP_FORLOOP: case OP_FORPREP: case OP_TFORLOOP: case OP_TFORPREP:
          tgt = (insts[i]->c >= 0 && insts[i]->c <= maxpc) ? idxof[insts[i]->c] : -1;
          if (tgt >= 0) succ[ns++] = tgt;
          if (i + 1 < n) succ[ns++] = i + 1;       /* fall-through */
          break;
        case OP_EQ: case OP_LT: case OP_LE: case OP_EQK: case OP_EQI:
        case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
        case OP_TEST: case OP_TESTSET:
          if (i + 1 < n) succ[ns++] = i + 1;        /* take the paired JMP */
          if (i + 2 < n) succ[ns++] = i + 2;        /* or skip it */
          break;
        case OP_LFALSESKIP:
          if (i + 2 < n) succ[ns++] = i + 2;        /* always skips one */
          break;
        default:
          if (i + 1 < n) succ[ns++] = i + 1;
          break;
      }
      for (k = 0; k < ns; k++) {
        int8_t *sin = &st[(size_t)succ[k] * nregs];
        for (r = 0; r < nregs; r++) {
          int mv = ti_meet(sin[r], out[r]);
          if (mv != sin[r]) { sin[r] = (int8_t)mv; changed = 1; }
        }
      }
    }
  }

  /* annotate: mark provably-integer operands so codegen elides the tag-check.
     "operand 1 / 2" = the two registers the codegen fastpath reads for this op:
       arith reg-reg (ADD/SUB/MUL/...):   op1 = b, op2 = c
       arith immediate (ADDI/ADDK/...):   op1 = b
       comparisons (EQ/LT/LE):            op1 = a, op2 = b   (EQ/LT/LE only)  */
  for (i = 0; i < n; i++) {
    int8_t *sin = &st[(size_t)i * nregs];
    int o1 = -1, o2 = -1;
    in = insts[i];
    switch (in->bc_op) {
      case OP_ADD: case OP_SUB: case OP_MUL:
      case OP_BAND: case OP_BOR: case OP_BXOR:
        o1 = in->b; o2 = in->c; break;                 /* reg-reg: op1=B, op2=C */
      case OP_ADDI: case OP_ADDK: case OP_SUBK: case OP_MULK:
      case OP_BANDK: case OP_BORK: case OP_BXORK:
        o1 = in->b; o2 = -1; break;                    /* reg + immediate/K     */
      case OP_EQ: case OP_LT: case OP_LE:
        o1 = in->a; o2 = in->b; break;                 /* reg-reg compare       */
      case OP_EQI: case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
        o1 = in->a; o2 = -1; break;                    /* reg vs immediate      */
      default: continue;
    }
    if (o1 >= 0 && ti_reg(sin, o1, nregs) == TI_INT) in->known |= LC_KNOWN_B_INT;
    if (o2 >= 0 && ti_reg(sin, o2, nregs) == TI_INT) in->known |= LC_KNOWN_C_INT;
  }

  free(insts); free(idxof); free(st); free(out); free(captured);
}
void lc_pass_specialize_arith(LcFunc *f) { (void)f; /* folded into codegen via LcInst.known */ }
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
