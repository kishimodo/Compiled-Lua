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
#include "lstate.h"    /* gco2ts for tsvalue/getstr (the "debug" constant scan) */
#include "lopcodes.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool lc_module_reflects_globals(LcModule *m);

/* TRUE iff any function in the module carries `s` as a string constant.
   The three scans below all reduce to this; keeping one copy means a fix to
   the traversal (a new Proto source, say) cannot land in two of them and be
   forgotten in the third. */
static bool module_has_string_const(LcModule *m, const char *s) {
  for (uint32_t i = 0; i < m->nfuncs; i++) {
    Proto *p = m->funcs[i] ? m->funcs[i]->source : NULL;
    if (!p) continue;
    for (int k = 0; k < p->sizek; k++) {
      const TValue *kv = &p->k[k];
      if (ttisstring(kv) && strcmp(getstr(tsvalue(kv)), s) == 0) return true;
    }
  }
  return false;
}

/* TRUE iff any function in the module carries the string constant "debug".
   debug.setlocal/setupvalue can rewrite ANY local of any live frame at
   runtime, falsifying every static type proof -- so when the module so much
   as mentions the debug global, the type-inference elisions are disabled
   module-wide (the checked fastpaths, which re-verify tags at runtime, stay).
   Conservative by constant-scan: a table FIELD named "debug" also trips it
   (harmless), while a debug table assembled dynamically (_G["de".."bug"])
   evades it -- documented residual, the standard optimizing-compiler
   reflection caveat. */
bool lc_module_uses_debug(LcModule *m) {
  return module_has_string_const(m, "debug");
}

/* TRUE iff any function carries the string constant "ffi" or "bit": the
   driver links the FFI initialization anchor so the runtime-provided globals
   exist (the v1 idiom is `local ffi = _G.ffi`, which the require scan cannot
   see). Conservative: any string mention links the ~25 KB FFI. */
bool lc_module_uses_ffi(LcModule *m) {
  return module_has_string_const(m, "ffi") || module_has_string_const(m, "bit");
}

/* Which optional standard libraries this module can reach.
**
** SOUNDNESS. The per-library bits are set by NAMING a library, so the whole
** scan rests on one claim: a program cannot reach a library table it never
** named. That claim holds only because the world is closed -- no load(), no
** computed require -- and even then exactly three shapes break it:
**
**   1. `_G[k]` / `_ENV[k]` / `pairs(_G)`. Once the global table is a value, any
**      key reaches any library. Detected by lc_module_reflects_globals(), the
**      same scan the -O1 proof gate uses, for the same reason.
**   2. `package.loaded[k]`. package is always opened, and its loaded table maps
**      every name that WAS linked -- so an unlinked os makes
**      `package.loaded["o".."s"]` nil where the interpreter gives a table.
**      Any mention of the constant "package" gives up.
**   3. `debug.getregistry()[LUA_RIDX_LOADED]`, which is that same table by
**      another road. Any mention of "debug" gives up.
**
** For those, return LCLIB_ALL rather than a guess: being wrong here is not a
** slow program, it is a program that silently sees nil. Everything else --
** plain global reads, local table indexing, method calls -- compiles to a
** constant key and cannot manufacture a name, so the bits stand.
**
** Conservative in the safe direction throughout: an unused mention costs size,
** a missed reach costs correctness, and only the first is recoverable. */
unsigned lc_module_used_libs(LcModule *m) {
  unsigned mask = 0;

  if (lc_module_reflects_globals(m) ||
      module_has_string_const(m, "package") ||
      module_has_string_const(m, "debug")) return LCLIB_ALL;

  for (uint32_t i = 0; i < m->nfuncs; i++) {
    Proto *p = m->funcs[i] ? m->funcs[i]->source : NULL;
    if (!p) continue;
    /* The table/math/io/os/utf8/debug libraries are reached only through their
       global, so naming the constant (conservatively, any matching string
       constant) is sufficient. */
    for (int k = 0; k < p->sizek; k++) {
      const TValue *kv = &p->k[k];
      const char   *s;
      if (!ttisstring(kv)) continue;
      s = getstr(tsvalue(kv));
      if      (strcmp(s, "string") == 0) mask |= LCLIB_STRING;
      else if (strcmp(s, "table")  == 0) mask |= LCLIB_TABLE;
      else if (strcmp(s, "math")   == 0) mask |= LCLIB_MATH;
      else if (strcmp(s, "io")     == 0) mask |= LCLIB_IO;
      else if (strcmp(s, "os")     == 0) mask |= LCLIB_OS;
      else if (strcmp(s, "utf8")   == 0) mask |= LCLIB_UTF8;
      else if (strcmp(s, "debug")  == 0) mask |= LCLIB_DEBUG;
    }
    /* string is special: luaopen_string installs the string metatable, which
       backs BOTH string indexing (s:m(), s.m, s[k]) and string->number
       arithmetic coercion ("10" + 1 dispatches the string metatable's __add).
       So force string on for any value-index opcode OR any arith-metamethod
       opcode (OP_MMBIN/MMBINI/MMBINK, emitted after an arith op that may fall to
       a metamethod). A script that does neither and never names "string" -- a
       pure print of constants, say -- safely drops it. */
    if (!(mask & LCLIB_STRING)) {
      for (int pc = 0; pc < p->sizecode; pc++) {
        OpCode op = GET_OPCODE(p->code[pc]);
        if (op == OP_GETFIELD || op == OP_GETI || op == OP_GETTABLE ||
            op == OP_SELF     || op == OP_MMBIN || op == OP_MMBINI  ||
            op == OP_MMBINK) { mask |= LCLIB_STRING; break; }
      }
    }
  }
  return mask;
}

/* TRUE iff any function MATERIALIZES the global environment as a first-class
   value. The "debug" constant scan above misses a debug table fetched without
   the literal string -- _ENV["de".."bug"], _G[k], pairs(_G) -- and once that
   table is in hand, debug.setlocal/setupvalue can rewrite a live local and
   falsify a static type proof at -O1 (bug AOT-DEBUGREFLECT-001). The hole is
   precisely the moment globals become a value a dynamic key can index, which
   shows up in bytecode as exactly two shapes:

     - OP_GETUPVAL of the _ENV upvalue  (`_ENV[expr]`, `pairs(_ENV)`, `e=_ENV`)
     - OP_GETTABUP _ENV "_G" / "_ENV"   (naming the global table itself)

   Plain global *reads* compile to OP_GETTABUP with a constant non-_G/_ENV key
   and never materialize the table; local table indexing is OP_GETTABLE on a
   non-_ENV register. Neither trips this, so ordinary hot loops keep their
   proofs -- only code that actually hoists the global env as a value loses
   them, module-wide, just like a literal "debug" mention. Sound because the
   gate is module-wide: a helper that indexes a passed-in env is covered by the
   caller that materialized it. Relies on upvalue debug names, which are
   present on the freshly parsed Protos this pass runs over. */
static bool lc_module_reflects_globals(LcModule *m) {
  for (uint32_t i = 0; i < m->nfuncs; i++) {
    Proto *p = m->funcs[i] ? m->funcs[i]->source : NULL;
    if (!p) continue;
    for (int pc = 0; pc < p->sizecode; pc++) {
      Instruction ins = p->code[pc];
      OpCode op = GET_OPCODE(ins);
      if (op == OP_GETUPVAL) {
        int b = GETARG_B(ins);
        if (b >= 0 && b < p->sizeupvalues && p->upvalues[b].name != NULL &&
            strcmp(getstr(p->upvalues[b].name), "_ENV") == 0) return true;
      } else if (op == OP_GETTABUP) {
        int c = GETARG_C(ins);
        if (c >= 0 && c < p->sizek && ttisstring(&p->k[c])) {
          const char *key = getstr(tsvalue(&p->k[c]));
          if (strcmp(key, "_G") == 0 || strcmp(key, "_ENV") == 0) return true;
        }
      }
    }
  }
  return false;
}


/* Run the IR verifier if the caller asked for it, and report WHICH pass left the
** IR malformed. Before this, LcPassConfig.verify_each was declared, set to true
** by the driver, and never read -- a safety control that only appeared active.
**
** A verification failure is a hard error, not a warning: the IR is the input to
** codegen, so continuing past a malformed module means emitting native code from
** it. Better a failed compile with a located message than a binary nobody can
** explain. */
static bool opt_verify(LcModule *m, const LcPassConfig *cfg, const char *after) {
  char err[256];
  if (!cfg || !cfg->verify_each) return true;
  if (lc_module_verify(m, err, sizeof err)) return true;
  fprintf(stderr, "clua: internal error: IR verification failed after %s: %s\n",
          after, err[0] ? err : "(no detail)");
  return false;
}

bool lc_optimize(LcModule *m, const LcPassConfig *cfg) {
  if (!m || !cfg) return false;

  /* Verify what we were HANDED before touching it: a failure here is the lifter's
  ** or the front end's, not any pass's, and saying so saves the next bisect. */
  if (!opt_verify(m, cfg, "lift (module entry to the optimizer)")) return false;

  lc_build_callgraph(m);
  if (!opt_verify(m, cfg, "lc_build_callgraph")) return false;

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
    /* Disable proof-producing inference when the module mentions debug OR
       hoists the global env as a value (either path can reach debug.setlocal
       and falsify a proof -- AOT-DEBUGREFLECT-001). The checked fastpaths,
       which re-verify tags at run time, are unaffected. */
    bool uses_debug   = lc_module_uses_debug(m);
    bool reflects_env = !uses_debug && lc_module_reflects_globals(m);
    bool no_proofs    = uses_debug || reflects_env;

    /* Say so. This gate is a MEASURED 1.3-1.5x on arithmetic-heavy code and it
    ** fires on shapes a user cannot reasonably guess:
    **
    **   * any module carrying the STRING "debug" anywhere -- a log-level name, a
    **     field key, a message -- because the scan is over constants, not over
    **     reachability (see lc_module_uses_debug's own caveat above);
    **   * any chunk with more than 255 constants that also touches a global,
    **     because lcode then spills the access to GETUPVAL _ENV + LOADK +
    **     GETTABLE, which lc_module_reflects_globals cannot distinguish from real
    **     reflection. Measured: the same 20M-iteration integer loop ran 103 ms
    **     with one constant and 152 ms with 300 -- a 48% penalty for a
    **     constant-count threshold unrelated to what the code does.
    **
    ** Silently losing a third to a half of arithmetic performance for either
    ** reason is worse than a line on stderr, so this is on by default and goes to
    ** stderr rather than stdout -- it must not perturb the differential suite's
    ** stdout diffs. CLUA_QUIET_PROOFS=1 silences it for callers that compile in
    ** bulk.
    **
    ** Narrowing the second case needs a real "does this instruction read register
    ** A" dataflow query, which Lua 5.4's opcode tables do not expose; two
    ** structural approximations were tried and both were wrong about the emitted
    ** shape, so the guard stays conservative until the analysis is done properly.
    ** See docs/benchmarks/session-2026-07-26-speed-and-size.md. */
    if (no_proofs && getenv("CLUA_QUIET_PROOFS") == NULL) {
      fprintf(stderr,
              "clua: note: type proofs disabled for this module (%s), which "
              "costs roughly 1.3-1.5x on arithmetic-heavy code\n",
              uses_debug
                ? "a function carries the string constant \"debug\""
                : "a global is reached through _ENV in a register, which lcode "
                  "emits once a chunk has more than 255 constants");
      fprintf(stderr,
              "clua: note: set CLUA_QUIET_PROOFS=1 to silence this\n");
    }
    /* M2: interprocedural argument/return type propagation runs the local
       inference in three phases (baseline -> callee param entries -> callers
       with return summaries); the final phase leaves the same per-inst
       annotations the per-function pass would. */
    if (!no_proofs) lc_pass_ip_typeprop(m);
    for (uint32_t i = 0; i < m->nfuncs; i++) {
      LcFunc *f = m->funcs[i];
      lc_pass_specialize_arith(f);
      lc_pass_unbox_locals(f);
      lc_pass_devirt_local(f);
      lc_pass_raw_table(f);
    }
    lc_pass_inline_small(m);
    if (!opt_verify(m, cfg, "the -O1 pass group")) return false;
  }

  if (cfg->opt_level >= 2 && cfg->interprocedural) {
    /* ip_typeprop already ran in the -O1 block above */
    lc_pass_monomorphize(m);
    lc_pass_ip_devirt(m);
    lc_pass_dead_global(m);
    if (!opt_verify(m, cfg, "the -O2 interprocedural pass group")) return false;
  }

  if (cfg->opt_level >= 3 && cfg->escape_analysis) {
    lc_pass_escape(m);
    lc_pass_scalar_replace(m);
    for (uint32_t i = 0; i < m->nfuncs; i++) lc_pass_barrier_elide(m->funcs[i]);
    /* scalar_replace REWRITES instructions (NEWTABLE becomes LOADNIL), so this
    ** is the one -O group that actually mutates shape today. */
    if (!opt_verify(m, cfg, "the -O3 escape/scalar-replacement group")) return false;
  }

  /* lowering prep — always */
  for (uint32_t i = 0; i < m->nfuncs; i++) {
    lc_pass_lower(m->funcs[i]);
    lc_pass_safepoints(m->funcs[i]);
  }

  /* The boundary that matters: whatever leaves here goes straight into codegen. */
  if (!opt_verify(m, cfg, "lowering prep (final optimizer boundary)")) return false;

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
    /* M2 ip_typeprop: a CALL whose callee was statically identified and
       proven to return exactly one value of a known primitive type, taken
       with exactly one result (C == 2), proves its result register; the
       frame above still clobbers. Everything else falls to the generic
       clobber below. */
    case OP_CALL:
      if ((in->call_ret_ti == TI_INT || in->call_ret_ti == TI_FLT) && in->c == 2) {
        for (i = A + 1; i < n; i++) if (i >= 0) st[i] = TI_UNK;
        SET(A, in->call_ret_ti);
        break;
      }
      for (i = (A >= 0 ? A : 0); i < n; i++) st[i] = TI_UNK;
      break;
    /* multi-result / frame-reshaping ops: clobber [A, n) to UNK (sound) */
    case OP_TAILCALL: case OP_VARARG: case OP_VARARGPREP:
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

/* Kept-alive analysis state for the M2 interprocedural orchestrator. */
typedef struct TiState {
  LcInst **insts; int n;
  int     *idxof; int maxpc;
  int8_t  *st;    int nregs;
  int8_t  *captured;
  uint8_t *reach;                  /* BFS-reachable instruction flags */
} TiState;

static void ti_state_free(TiState *t) {
  if (!t) return;
  free(t->insts); free(t->idxof); free(t->st); free(t->captured); free(t->reach);
  memset(t, 0, sizeof *t);
}

static void ti_run(LcFunc *f, const int8_t *param_ti, TiState *keep);

void lc_pass_local_typeinfer(LcFunc *f) { ti_run(f, NULL, NULL); }

static void ti_run(LcFunc *f, const int8_t *param_ti, TiState *keep) {
  Proto    *p;
  LcInst  **insts = NULL, *in;
  int      *idxof = NULL;          /* bc_pc -> linear index */
  int8_t   *st = NULL, *out = NULL, *captured = NULL;
  uint8_t  *reach = NULL;
  int       n = 0, nregs, maxpc = 0, i, r, changed, cap = 0;
  uint32_t  bi;

  if (keep) memset(keep, 0, sizeof *keep);
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
  /* M2: statically-proven parameter entry types (meet over every call site of
     a non-escaping once-assigned closure). Vararg functions get no benefit:
     their leading OP_VARARGPREP clobbers the whole frame (sound). */
  if (param_ti)
    for (r = 0; r < p->numparams && r < nregs; r++) st[r] = param_ti[r];

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
      case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV:
      case OP_BAND: case OP_BOR: case OP_BXOR:
        o1 = in->b; o2 = in->c; break;                 /* reg-reg: op1=B, op2=C */
      case OP_ADDI: case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_DIVK:
      case OP_BANDK: case OP_BORK: case OP_BXORK:
        o1 = in->b; o2 = -1; break;                    /* reg + immediate/K     */
      case OP_EQ: case OP_LT: case OP_LE:
        o1 = in->a; o2 = in->b; break;                 /* reg-reg compare       */
      case OP_EQI: case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
        o1 = in->a; o2 = -1; break;                    /* reg vs immediate      */
      case OP_MOVE:
        o1 = in->b; o2 = -1; break;                    /* src proof: codegen's
                                                          int-MOVE + residency */
      case OP_FORLOOP:
        /* Integer-loop proof: internal index (R[A]) and step (R[A+2]) proven
           INT at the FORLOOP on every path. R[A+1] is NOT checked: the state
           merges the entry edge (where it still types as the original limit,
           possibly float/unknown) with the back edge, but FORPREP's integer
           path rewrites it to the trip COUNT (always an integer) on the only
           edge that actually reaches the FORLOOP, and erroring limits never
           fall through -- so int init+step alone make the loop integral
           (`for i = 1, n` with an unknown limit qualifies). Codegen may then
           drop the step tag-check AND the float helper arm (bare inline
           loop), and the loop slots become register-residency candidates. */
        if (ti_reg(sin, in->a,     nregs) == TI_INT &&
            ti_reg(sin, in->a + 2, nregs) == TI_INT) {
          in->known |= LC_KNOWN_B_INT;
          /* Export the entry-state INT mask for register residency: the
             dataflow IN-state at the loop body's first instruction (this
             FORLOOP's branch target). Residency must require entry-INT for
             any candidate it fills/spills, because a slot whose only
             in-region writes are conditional reaches the exit spill still
             holding its loop-entry value (attack round 8: 1.5/"s"/nil/true
             were retagged as integers by the unconditional INT-tag spill). */
          in->res_entry_int = 0;
          in->res_entry_flt = 0;
          if (in->c >= 0 && in->c <= maxpc && idxof[in->c] >= 0) {
            const int8_t *entry = &st[(size_t)idxof[in->c] * nregs];
            int s, lim = nregs < 64 ? nregs : 64;
            for (s = 0; s < lim; s++) {
              if (entry[s] == TI_INT) in->res_entry_int |= ((uint64_t)1 << s);
              if (entry[s] == TI_FLT) in->res_entry_flt |= ((uint64_t)1 << s);
            }
          }
        }
        continue;
      default: continue;
    }
    if (o1 >= 0 && ti_reg(sin, o1, nregs) == TI_INT) in->known |= LC_KNOWN_B_INT;
    if (o2 >= 0 && ti_reg(sin, o2, nregs) == TI_INT) in->known |= LC_KNOWN_C_INT;
    /* float proofs too (codegen uses these for the reg-reg ADD/SUB/MUL/DIV
       float elision and the float-K arith elision; harmless on the other
       annotated ops, which ignore them). */
    if (o1 >= 0 && ti_reg(sin, o1, nregs) == TI_FLT) in->known |= LC_KNOWN_B_FLT;
    if (o2 >= 0 && ti_reg(sin, o2, nregs) == TI_FLT) in->known |= LC_KNOWN_C_FLT;
  }

  if (keep) {
    /* BFS reachability over the same successor relation (summaries must
       ignore lcode's dead trailing returns). */
    int *work = (int *)malloc((size_t)n * sizeof(int));
    int  wn = 0;
    reach = (uint8_t *)calloc((size_t)n, 1);
    if (work && reach && n > 0) {
      reach[0] = 1; work[wn++] = 0;
      while (wn > 0) {
        int i2 = work[--wn], ns2 = 0, k2, succ2[2], tgt2;
        switch (insts[i2]->bc_op) {
          case OP_RETURN: case OP_RETURN0: case OP_RETURN1: case OP_TAILCALL:
            break;
          case OP_JMP:
            tgt2 = (insts[i2]->c >= 0 && insts[i2]->c <= maxpc) ? idxof[insts[i2]->c] : -1;
            if (tgt2 >= 0) succ2[ns2++] = tgt2;
            break;
          case OP_FORLOOP: case OP_FORPREP: case OP_TFORLOOP: case OP_TFORPREP:
            tgt2 = (insts[i2]->c >= 0 && insts[i2]->c <= maxpc) ? idxof[insts[i2]->c] : -1;
            if (tgt2 >= 0) succ2[ns2++] = tgt2;
            if (i2 + 1 < n) succ2[ns2++] = i2 + 1;
            break;
          case OP_EQ: case OP_LT: case OP_LE: case OP_EQK: case OP_EQI:
          case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
          case OP_TEST: case OP_TESTSET:
            if (i2 + 1 < n) succ2[ns2++] = i2 + 1;
            if (i2 + 2 < n) succ2[ns2++] = i2 + 2;
            break;
          case OP_LFALSESKIP:
            if (i2 + 2 < n) succ2[ns2++] = i2 + 2;
            break;
          default:
            if (i2 + 1 < n) succ2[ns2++] = i2 + 1;
            break;
        }
        for (k2 = 0; k2 < ns2; k2++)
          if (!reach[succ2[k2]]) { reach[succ2[k2]] = 1; work[wn++] = succ2[k2]; }
      }
    }
    free(work);
    keep->insts = insts; keep->n = n;
    keep->idxof = idxof; keep->maxpc = maxpc;
    keep->st = st;       keep->nregs = nregs;
    keep->captured = captured;
    keep->reach = reach;
    free(out);
    return;
  }
  free(insts); free(idxof); free(st); free(out); free(captured);
}
void lc_pass_specialize_arith(LcFunc *f) { (void)f; /* folded into codegen via LcInst.known */ }
void lc_pass_unbox_locals(LcFunc *f)     { (void)f; /* TODO(M1) */ }
void lc_pass_devirt_local(LcFunc *f)     { (void)f; /* TODO(M1) */ }
void lc_pass_raw_table(LcFunc *f)        { (void)f; /* TODO(M1) only if no reachable metatable */ }
void lc_pass_inline_small(LcModule *m)   { (void)m; /* TODO(M1) */ }

/* lc_pass_ip_typeprop: real implementation at the end of this file (M2). */
void lc_pass_monomorphize(LcModule *m)   { (void)m; /* TODO(M2) keep ANY fallback clone */ }
void lc_pass_ip_devirt(LcModule *m)      { (void)m; /* TODO(M2) */ }
void lc_pass_dead_global(LcModule *m)    { (void)m; /* TODO(M2) */ }

/* M3 escape analysis: slice 2 will make this the INTERPROCEDURAL non-escape
   summary that scalar replacement consumes. For the slice-1 intra-procedural
   pass the candidate analysis is self-contained inside lc_pass_scalar_replace
   (real implementation at the end of this file). */
void lc_pass_escape(LcModule *m)         { (void)m; }
/* lc_pass_scalar_replace: real implementation at the end of this file (M3). */
void lc_pass_barrier_elide(LcFunc *f)    { (void)f; /* TODO(M3) HIGHEST RISK — prove or keep barrier */ }

void lc_pass_lower(LcFunc *f)            { (void)f; /* TODO(M0) canonicalize for codegen */ }
void lc_pass_safepoints(LcFunc *f)       { (void)f; /* TODO(M0) back-edges + throw-capable ops */ }

/* ------------------------------------------------------------------ */
/* M2 -- interprocedural type propagation (lc_pass_ip_typeprop).       */
/*                                                                      */
/* Closed-world, sound-conservative, no SSA needed:                     */
/*   1. A "tracked closure slot" is a local S with EXACTLY ONE writer   */
/*      in its function -- `CLOSURE S, Bx` -- that is never captured    */
/*      and whose every reader is the MOVE that feeds a direct CALL's   */
/*      function register (verified by a straight-line backward scan    */
/*      from each CALL, stopping at branches and jump targets).         */
/*   2. If EVERY closure of a proto module-wide is tracked, all of its  */
/*      call sites are enumerable: the callee's parameter entry types   */
/*      become the meet of the argument types across all sites          */
/*      (phase-A states; missing args or multret argument lists poison  */
/*      to UNK).                                                        */
/*   3. Callees re-run inference with those entries (phase B1); every   */
/*      REACHABLE return must then yield exactly one first value of one */
/*      proven primitive type for the proto to gain a return summary.   */
/*   4. Call sites taking exactly one result (C == 2) consume the       */
/*      summary via LcInst.call_ret_ti in a final re-run (phase B2),    */
/*      extending elision and residency across helper calls.            */
/* Anything outside the tracked pattern -- captured helpers (upvalue    */
/* calls), escaping closures, varargs, multret -- conservatively stays  */
/* UNK exactly as before. */
/* ------------------------------------------------------------------ */

/* Frame write range of an instruction: 1 = range in [*lo,*hi], 0 = writes
   nothing, -1 = unknown/whole-frame (disqualifies once-assignment). */
static int ip_write_range(LcInst *in, int nregs, int *lo, int *hi) {
  switch (in->bc_op) {
    case OP_MOVE: case OP_LOADI: case OP_LOADF: case OP_LOADK: case OP_LOADKX:
    case OP_LOADTRUE: case OP_LOADFALSE: case OP_LFALSESKIP:
    case OP_GETUPVAL: case OP_GETTABUP: case OP_GETTABLE: case OP_GETI:
    case OP_GETFIELD: case OP_NEWTABLE: case OP_CLOSURE:
    case OP_NOT: case OP_UNM: case OP_BNOT: case OP_LEN: case OP_CONCAT:
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
    case OP_IDIV: case OP_POW: case OP_BAND: case OP_BOR: case OP_BXOR:
    case OP_SHL: case OP_SHR:
    case OP_ADDI: case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_DIVK:
    case OP_MODK: case OP_IDIVK: case OP_POWK:
    case OP_BANDK: case OP_BORK: case OP_BXORK: case OP_SHRI: case OP_SHLI:
    case OP_TESTSET:
      *lo = *hi = in->a; return 1;
    case OP_SELF:
      *lo = in->a; *hi = in->a + 1; return 1;
    case OP_LOADNIL:
      *lo = in->a; *hi = in->a + in->b; return 1;
    case OP_CALL:
      if (in->c >= 1) { *lo = in->a; *hi = in->a + in->c - 2; return (*hi >= *lo) ? 1 : 0; }
      *lo = in->a; *hi = nregs - 1; return 1;
    case OP_FORPREP: case OP_FORLOOP:
      *lo = in->a; *hi = in->a + 3; return 1;
    case OP_SETTABUP: case OP_SETTABLE: case OP_SETI: case OP_SETFIELD:
    case OP_SETLIST: case OP_SETUPVAL:
    case OP_EQ: case OP_LT: case OP_LE: case OP_EQK: case OP_EQI:
    case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI: case OP_TEST:
    case OP_JMP: case OP_RETURN: case OP_RETURN0: case OP_RETURN1:
    case OP_MMBIN: case OP_MMBINI: case OP_MMBINK: case OP_EXTRAARG:
      return 0;
    case OP_VARARGPREP:
      /* entry frame adjustment: it (re)positions PARAMS, not locals, and any
         read of a slot before its CLOSURE assignment already disqualifies the
         slot via the reader check -- counting it as a writer would poison
         every slot of every vararg function (incl. every main chunk). */
      return 0;
    default:
      return -1;                  /* TFOR*/ /* VARARG / unknown: whole frame */
  }
}

/* Conservative "may instruction `in` READ slot s?" (excluding the writes
   above). Unknown ops read everything. */
static int ip_reads_slot(LcInst *in, int s, int nregs) {
  switch (in->bc_op) {
    case OP_MOVE: case OP_UNM: case OP_BNOT: case OP_NOT: case OP_LEN:
    case OP_GETI: case OP_GETFIELD:
      return in->b == s;
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
    case OP_IDIV: case OP_POW: case OP_BAND: case OP_BOR: case OP_BXOR:
    case OP_SHL: case OP_SHR: case OP_GETTABLE:
      return in->b == s || in->c == s;
    case OP_ADDI: case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_DIVK:
    case OP_MODK: case OP_IDIVK: case OP_POWK:
    case OP_BANDK: case OP_BORK: case OP_BXORK: case OP_SHRI: case OP_SHLI:
      return in->b == s;
    case OP_EQ: case OP_LT: case OP_LE:
      return in->a == s || in->b == s;
    case OP_EQK: case OP_EQI: case OP_LTI: case OP_LEI: case OP_GTI:
    case OP_GEI: case OP_TEST: case OP_SETUPVAL:
      return in->a == s;
    case OP_TESTSET:
      return in->b == s;
    case OP_GETTABUP:
      return 0;                          /* B is an UPVALUE index, not a reg */
    case OP_SETTABUP:
      return in->c == s;                 /* value operand (k-form reads K) */
    case OP_SETTABLE: case OP_SETI: case OP_SETFIELD:
      return in->a == s || in->b == s || in->c == s;
    case OP_SELF:
      return in->b == s || in->c == s;
    case OP_CONCAT:
      return s >= in->a && s <= in->a + in->b - 1;
    case OP_CALL:
      if (in->b >= 1) return s >= in->a && s <= in->a + in->b - 1;
      return s >= in->a;                 /* args to top */
    case OP_TAILCALL:
      return s >= in->a;
    case OP_RETURN:
      if (in->b >= 1) return s >= in->a && s <= in->a + in->b - 2;
      return s >= in->a;
    case OP_RETURN1: return in->a == s;
    case OP_RETURN0: return 0;
    case OP_FORPREP: case OP_FORLOOP:
      return s >= in->a && s <= in->a + 2;
    case OP_SETLIST:
      if (in->b >= 1) return s >= in->a && s <= in->a + in->b;
      return s >= in->a;
    case OP_LOADI: case OP_LOADF: case OP_LOADK: case OP_LOADKX:
    case OP_LOADTRUE: case OP_LOADFALSE: case OP_LFALSESKIP: case OP_LOADNIL:
    case OP_NEWTABLE: case OP_CLOSURE: case OP_GETUPVAL: case OP_JMP:
    case OP_MMBIN: case OP_MMBINI: case OP_MMBINK: case OP_EXTRAARG:
    case OP_VARARGPREP:        /* entry adjustment: reads params/varargs only */
      return 0;
    default:
      return 1;                          /* unknown: assume it reads */
  }
}

/* Per-proto interprocedural facts. */
typedef struct IpProto {
  int     func_idx;        /* index in m->funcs, or -1 */
  int     tracked;         /* every CLOSURE of this proto is a tracked slot */
  int     nsites;
  int8_t *param_meet;      /* numparams meet over sites (TI_TOP start) */
  int8_t  ret_ti;          /* TI_INT/TI_FLT summary or TI_UNK */
} IpProto;

void lc_pass_ip_typeprop(LcModule *m) {
  uint32_t fi;
  int      i, k, r;
  TiState *A = NULL;
  IpProto *ip = NULL;

  if (!m || m->nfuncs == 0) return;
  A  = (TiState *)calloc(m->nfuncs, sizeof(TiState));
  ip = (IpProto *)calloc(m->nfuncs, sizeof(IpProto));
  if (!A || !ip) { free(A); free(ip); return; }

  for (fi = 0; fi < m->nfuncs; fi++) {
    ip[fi].func_idx = (int)fi;
    ip[fi].tracked  = 1;               /* until proven otherwise */
    ip[fi].ret_ti   = TI_UNK;
  }

  /* zero stale per-inst ip fields, run phase A, allocate param meets */
  for (fi = 0; fi < m->nfuncs; fi++) {
    LcFunc *f = m->funcs[fi];
    uint32_t bi; LcInst *in;
    if (!f) continue;
    for (bi = 0; bi < f->nblocks; bi++)
      for (in = f->blocks[bi]->first; in; in = in->next)
        { in->call_ret_ti = 0; in->call_callee = -1; }
    ti_run(f, NULL, &A[fi]);
    if (f->source && f->source->numparams > 0) {
      ip[fi].param_meet = (int8_t *)calloc((size_t)f->source->numparams, 1);
    }
  }

  /* ---- discover tracked closure slots + enumerate static call sites ---- */
  for (fi = 0; fi < m->nfuncs; fi++) {
    LcFunc  *f = m->funcs[fi];
    TiState *t = &A[fi];
    Proto   *p = f ? f->source : NULL;
    uint8_t *is_tgt = NULL;
    int     *writers = NULL;       /* writer count per slot */
    int     *writer_ix = NULL;     /* sole writer's index   */
    uint8_t *site_move = NULL;     /* inst i is a verified call-base MOVE */
    if (!p || t->n == 0) continue;

    is_tgt    = (uint8_t *)calloc((size_t)t->n, 1);
    writers   = (int *)calloc((size_t)t->nregs, sizeof(int));   /* slot_clos */
    writer_ix = (int *)calloc((size_t)t->nregs, sizeof(int));   /* (reused)  */
    site_move = (uint8_t *)calloc((size_t)t->n, 1);
    if (!is_tgt || !writers || !writer_ix || !site_move) goto next_fn;

    /* slot_clos[S] (in writers[]): index+1 of S's unique tracked CLOSURE
       writer, 0 = none, -1 = disqualified. Lua REUSES freed slots as
       expression temporaries, so absolute once-assignment never holds for
       later locals; the sound rule is scoped instead: pre-CLOSURE traffic on
       the slot belongs to dead temps and is ignored, provided (a) no
       backward edge spans the CLOSURE (its pc can never re-execute via a
       loop, so the closure value is final), and (b) no other instruction
       writes the slot AFTER the CLOSURE. Reads after it are vetted against
       the verified call-base MOVEs in the escape sweep below. */
    {
      uint8_t *in_loop = (uint8_t *)calloc((size_t)t->n, 1);
      if (!in_loop) goto next_fn_inloop;
      for (i = 0; i < t->n; i++) {
        LcInst *in = t->insts[i];
        int tgt = -1, j2;
        switch (in->bc_op) {
          case OP_JMP: case OP_FORLOOP: case OP_FORPREP:
          case OP_TFORLOOP: case OP_TFORPREP:
            tgt = (in->c >= 0 && in->c <= t->maxpc) ? t->idxof[in->c] : -1;
            if (tgt >= 0) is_tgt[tgt] = 1;
            if (tgt >= 0 && tgt <= i)                  /* backward edge */
              for (j2 = tgt; j2 <= i; j2++) in_loop[j2] = 1;
            if (in->bc_op != OP_JMP && i + 1 < t->n) is_tgt[i + 1] = 1;
            break;
          case OP_EQ: case OP_LT: case OP_LE: case OP_EQK: case OP_EQI:
          case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
          case OP_TEST: case OP_TESTSET: case OP_LFALSESKIP:
            if (i + 2 < t->n) is_tgt[i + 2] = 1;
            break;
          default: break;
        }
      }
      for (i = 0; i < t->n; i++) {
        LcInst *in = t->insts[i];
        int S2;
        if (in->bc_op != OP_CLOSURE) continue;
        S2 = in->a;
        if (S2 < 0 || S2 >= t->nregs) continue;
        if (writers[S2] != 0) { writers[S2] = -1; continue; }  /* 2nd closure */
        if (t->captured[S2] || in_loop[i]) { writers[S2] = -1; continue; }
        writers[S2] = i + 1;
      }
      /* any non-CLOSURE write AFTER the closure disqualifies the slot */
      for (i = 0; i < t->n; i++) {
        int lo, hi, w = ip_write_range(t->insts[i], t->nregs, &lo, &hi);
        if (w < 0) {                       /* unknown writer: poison all */
          for (r = 0; r < t->nregs; r++)
            if (writers[r] > 0 && i >= writers[r]) writers[r] = -1;
        } else if (w > 0) {
          for (r = lo; r <= hi && r < t->nregs; r++)
            if (r >= 0 && writers[r] > 0 && i >= writers[r] &&
                t->insts[i]->bc_op != OP_CLOSURE) writers[r] = -1;
        }
      }
      free(in_loop);
      goto inloop_ok;
next_fn_inloop:
      goto next_fn;
inloop_ok: ;
    }

    /* static callee per CALL: straight-line backward scan for R[A]'s writer */
    for (i = 0; i < t->n; i++) {
      LcInst *call = t->insts[i];
      int j, freg, callee = -1;
      if (call->bc_op != OP_CALL) continue;
      freg = call->a;
      for (j = i - 1; j >= 0; j--) {
        LcInst *w = t->insts[j];
        int lo, hi, wr, is_branch = 0;
        switch (w->bc_op) {                      /* control flow: give up */
          case OP_JMP: case OP_FORLOOP: case OP_FORPREP: case OP_TFORLOOP:
          case OP_TFORPREP: case OP_EQ: case OP_LT: case OP_LE: case OP_EQK:
          case OP_EQI: case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
          case OP_TEST: case OP_TESTSET: case OP_LFALSESKIP:
          case OP_RETURN: case OP_RETURN0: case OP_RETURN1: case OP_TAILCALL:
            is_branch = 1; break;
          default: break;
        }
        if (is_branch) break;
        wr = ip_write_range(w, t->nregs, &lo, &hi);
        if (wr < 0) break;
        if (wr > 0 && freg >= lo && freg <= hi) {
          /* found the writer. NOTE: the writer itself being a jump target is
             fine (every path through it executes it); the join hazard is a
             target strictly BETWEEN the writer and the call, checked below
             via the early `is_tgt` break on non-writer instructions. */
          /* found the function-register writer */
          if (w->bc_op == OP_MOVE) {
            int S = w->b;
            if (S >= 0 && S < t->nregs && writers[S] > 0 &&
                j > writers[S] - 1) {          /* read AFTER its CLOSURE */
              int bx = t->insts[writers[S] - 1]->b;
              if (bx >= 0 && bx < p->sizep) {
                uint32_t cj;
                for (cj = 0; cj < m->nfuncs; cj++)
                  if (m->funcs[cj] && m->funcs[cj]->source == p->p[bx])
                    { callee = (int)cj; break; }
                if (callee >= 0) site_move[j] = 1;
              }
            }
          } else if (w->bc_op == OP_CLOSURE) {
            int bx = w->b;
            if (bx >= 0 && bx < p->sizep) {
              uint32_t cj;
              for (cj = 0; cj < m->nfuncs; cj++)
                if (m->funcs[cj] && m->funcs[cj]->source == p->p[bx])
                  { callee = (int)cj; break; }
            }
          }
          break;
        }
        if (is_tgt[j]) break;          /* join strictly between writer and call */
      }
      if (callee < 0) continue;
      /* record the site: meet argument types; poison on multret/short args */
      {
        LcFunc *K = m->funcs[callee];
        int npar = (K && K->source) ? K->source->numparams : 0;
        int argc = (call->b >= 1) ? call->b - 1 : -1;   /* -1 = to-top */
        const int8_t *sin = &t->st[(size_t)i * t->nregs];
        ip[callee].nsites++;
        call->call_callee = callee;          /* resolved to a TI after B1 */
        if (ip[callee].param_meet) {
          for (k = 0; k < npar; k++) {
            int ti = TI_UNK;
            if (argc >= 0 && k < argc) {
              int as = call->a + 1 + k;
              ti = (as < t->nregs) ? t->st[(size_t)i * t->nregs + as] : TI_UNK;
            }
            (void)sin;
            ip[callee].param_meet[k] =
              (int8_t)ti_meet(ip[callee].param_meet[k], ti);
          }
        }
      }
    }

    /* escape sweep: every POST-CLOSURE reader of a tracked slot must be a
       verified call-base MOVE; otherwise the closure value leaks to call
       sites we cannot enumerate. And every CLOSURE inst that did NOT earn a
       tracked slot (slot_clos != its index+1) leaks its proto outright. */
    for (r = 0; r < t->nregs; r++) {
      int bx, ci;
      if (writers[r] <= 0) continue;
      ci = writers[r] - 1;
      bx = t->insts[ci]->b;
      if (bx < 0 || bx >= p->sizep) continue;
      for (i = ci + 1; i < t->n; i++) {
        LcInst *in = t->insts[i];
        if (in->bc_op == OP_MOVE && in->b == r && site_move[i]) continue;
        if (ip_reads_slot(in, r, t->nregs)) {
          uint32_t cj;
          if (getenv("LC_IP_DEBUG"))
            fprintf(stderr, "[ip]   leak: fn slot %d read by inst %d (op %d)%c",
                    r, i, in->bc_op, 10);
          for (cj = 0; cj < m->nfuncs; cj++)
            if (m->funcs[cj] && m->funcs[cj]->source == p->p[bx])
              { ip[cj].tracked = 0; break; }
          break;
        }
      }
    }
    for (i = 0; i < t->n; i++) {
      LcInst *in = t->insts[i];
      int bx, S;
      if (in->bc_op != OP_CLOSURE) continue;
      bx = in->b; S = in->a;
      if (bx < 0 || bx >= p->sizep) continue;
      if (S < 0 || S >= t->nregs || writers[S] != i + 1) {
        uint32_t cj;
        if (getenv("LC_IP_DEBUG"))
          fprintf(stderr,
                  "[ip]   untracked closure: slot %d slot_clos=%d cap=%d i=%d%c",
                  S, (S >= 0 && S < t->nregs) ? writers[S] : -99,
                  (S >= 0 && S < t->nregs) ? t->captured[S] : -1, i, 10);
        for (cj = 0; cj < m->nfuncs; cj++)
          if (m->funcs[cj] && m->funcs[cj]->source == p->p[bx])
            { ip[cj].tracked = 0; break; }
      }
    }
next_fn:
    free(is_tgt); free(writers); free(writer_ix); free(site_move);
  }

  /* ---- phase B1: re-run tracked callees with parameter entry types ---- */
  for (fi = 0; fi < m->nfuncs; fi++) {
    LcFunc *f = m->funcs[fi];
    if (!f || !f->source) continue;
    if (!ip[fi].tracked || ip[fi].nsites == 0 || !ip[fi].param_meet) continue;
    for (k = 0; k < f->source->numparams; k++)
      if (ip[fi].param_meet[k] == TI_TOP) ip[fi].param_meet[k] = TI_UNK;
    ti_state_free(&A[fi]);
    ti_run(f, ip[fi].param_meet, &A[fi]);
  }

  /* ---- return summaries from the (possibly improved) states ---- */
  for (fi = 0; fi < m->nfuncs; fi++) {
    TiState *t = &A[fi];
    int rt = TI_TOP, bad = 0;
    if (!ip[fi].tracked || t->n == 0 || !t->reach) { ip[fi].ret_ti = TI_UNK; continue; }
    for (i = 0; i < t->n; i++) {
      LcInst *in = t->insts[i];
      int v;
      if (!t->reach[i]) continue;
      switch (in->bc_op) {
        case OP_RETURN1:
          v = ti_reg(&t->st[(size_t)i * t->nregs], in->a, t->nregs);
          rt = ti_meet(rt, v); break;
        case OP_RETURN:
          if (in->b >= 2) {
            v = ti_reg(&t->st[(size_t)i * t->nregs], in->a, t->nregs);
            rt = ti_meet(rt, v);
          } else bad = 1;                /* 0 values or multret */
          break;
        case OP_RETURN0: case OP_TAILCALL:
          bad = 1; break;
        default: break;
      }
      if (bad) break;
    }
    ip[fi].ret_ti = (int8_t)((!bad && (rt == TI_INT || rt == TI_FLT)) ? rt : TI_UNK);
  }

  /* ---- resolve stashed callee indexes into return-type proofs ---- */
  {
    int applied = 0, sites = 0;
    for (fi = 0; fi < m->nfuncs; fi++) {
      LcFunc *f = m->funcs[fi];
      uint32_t bi; LcInst *in;
      if (!f) continue;
      for (bi = 0; bi < f->nblocks; bi++)
        for (in = f->blocks[bi]->first; in; in = in->next) {
          if (in->bc_op == OP_CALL && in->call_callee >= 0) {
            int callee = in->call_callee;
            sites++;
            in->call_ret_ti = ((uint32_t)callee < m->nfuncs)
                                ? ip[callee].ret_ti : 0;
            if (in->call_ret_ti == TI_UNK) in->call_ret_ti = 0;
            if (in->call_ret_ti) applied++;
          } else if (in->bc_op != OP_CALL) {
            in->call_ret_ti = 0;
          }
        }
    }
    if (getenv("LC_IP_DEBUG")) {
      fprintf(stderr, "[ip] static call sites: %d, summaries applied: %d%c",
              sites, applied, 10);
      for (fi = 0; fi < m->nfuncs; fi++)
        fprintf(stderr,
                "[ip]   fn%u: tracked=%d nsites=%d ret_ti=%d pmeet0=%d%c",
                fi, ip[fi].tracked, ip[fi].nsites, ip[fi].ret_ti,
                ip[fi].param_meet ? ip[fi].param_meet[0] : -1, 10);
    }
  }

  /* ---- phase B2: final inference everywhere with summaries visible ---- */
  for (fi = 0; fi < m->nfuncs; fi++) {
    LcFunc *f = m->funcs[fi];
    if (!f) continue;
    ti_state_free(&A[fi]);
    ti_run(f, (ip[fi].tracked && ip[fi].nsites > 0) ? ip[fi].param_meet : NULL,
           NULL);
  }

  for (fi = 0; fi < m->nfuncs; fi++) { ti_state_free(&A[fi]); free(ip[fi].param_meet); }
  free(A); free(ip);
}

/* ================================================================== */
/* M3 -- escape analysis + scalar replacement of non-escaping tables.  */
/* slice 1: intra-procedural. Spec:                                     */
/*   docs/superpowers/specs/2026-06-13-scalar-replacement-o3-design.md   */
/*                                                                      */
/* A table from OP_NEWTABLE whose home register never escapes its        */
/* function and is touched ONLY by constant-key field ops can never gain */
/* a metatable (setmetatable is a call = an escape, which bails), so its */
/* raw get/set semantics are EXACTLY modeled by one fresh stack slot per */
/* distinct key. Rewrite (reusing existing opcodes -- no codegen change, */
/* so the differential oracle covers every emitted byte):               */
/*   NEWTABLE A         -> LOADNIL slot_base .. slot_base+nkeys-1        */
/*   GET{FIELD,I} d,A,k -> MOVE   d        <- slot[k]                    */
/*   SET{FIELD,I} A,k,v -> MOVE   slot[k]  <- v       (v a register)     */
/*                      -> LOADK  slot[k]  <- K[v]    (v a constant)     */
/* removing the heap allocation (Rt_NewTable + GC) and the per-access    */
/* Rt_GetField/Rt_SetField (hash lookup + barrier) on the hot path. The  */
/* reserved slots live inside the (bumped) frame, so the GC treats them  */
/* exactly like any Lua local. The whole soundness burden is the         */
/* exhaustive "does any OTHER op touch register A?" test, discharged by   */
/* reusing the audited operand model (ip_write_range + ip_reads_slot):    */
/* any read or write of A outside the four allowed field ops bails.      */
/* ================================================================== */

#define SR_MAX_KEYS 8

typedef struct { int is_int; int kval; } SrKey;   /* is_int 1=int imm, 0=K-idx */
typedef struct { SrKey k[SR_MAX_KEYS]; int n; } SrKeySet;

static int sr_key_find(const SrKeySet *ks, int is_int, int kval) {
  int i;
  for (i = 0; i < ks->n; i++)
    if (ks->k[i].is_int == is_int && ks->k[i].kval == kval) return i;
  return -1;
}
static int sr_key_intern(SrKeySet *ks, int is_int, int kval) {
  int i = sr_key_find(ks, is_int, kval);
  if (i >= 0) return i;
  if (ks->n >= SR_MAX_KEYS) return -1;
  ks->k[ks->n].is_int = is_int; ks->k[ks->n].kval = kval;
  return ks->n++;
}

/* Allowed constant-key GET on table register R (d = R.k / R[k])?
   GET{FIELD,I}: a=dst, b=table reg, c=key (FIELD: string K-idx; I: int imm). */
static int sr_is_get(const LcInst *in, int R, int *is_int, int *kval, int *dst) {
  if (in->b != R || in->a == R) return 0;        /* a==R would redefine R   */
  if (in->bc_op == OP_GETFIELD) { *is_int = 0; *kval = in->c; *dst = in->a; return 1; }
  if (in->bc_op == OP_GETI)     { *is_int = 1; *kval = in->c; *dst = in->a; return 1; }
  return 0;
}
/* Allowed constant-key SET on table register R (R.k = v / R[k] = v, v != R)?
   SET{FIELD,I}: a=table reg, b=key (FIELD: string K-idx; I: int imm),
   c=value Ck-encoded by lift.c (c>=0 -> register c; c<0 -> constant K[-c-1]). */
static int sr_is_set(const LcInst *in, int R, int *is_int, int *kval,
                     int *valreg, int *valk) {
  if (in->a != R) return 0;
  if (in->bc_op != OP_SETFIELD && in->bc_op != OP_SETI) return 0;
  if (in->c >= 0) {                              /* value is register in->c */
    if (in->c == R) return 0;                    /* R[k]=R -> R escapes; bail */
    *valreg = in->c; *valk = -1;
  } else {                                       /* value is constant K[-c-1] */
    *valreg = -1; *valk = -in->c - 1;
  }
  *is_int = (in->bc_op == OP_SETI);
  *kval   = in->b;
  return 1;
}

/* Rewrite one instruction in place into MOVE/LOADK/LOADNIL (all LC_OP_CONST;
   codegen dispatches on bc_op). Drop stale proof/effect annotations. */
static void sr_rewrite(LcInst *in, int bc_op, int a, int b) {
  in->op = LC_OP_CONST; in->bc_op = bc_op;
  in->a = a; in->b = b; in->c = 0;
  in->known = 0; in->flags = LC_FX_PURE;
}

/* Does any nested closure capture parent register R on the stack? Such a slot
   can be mutated to any type / observed elsewhere -> not scalar-replaceable. */
static int sr_reg_captured(Proto *p, int R) {
  int j, k;
  for (j = 0; j < p->sizep; j++) {
    Proto *ch = p->p[j];
    if (!ch) continue;
    for (k = 0; k < ch->sizeupvalues; k++)
      if (ch->upvalues[k].instack && ch->upvalues[k].idx == R) return 1;
  }
  return 0;
}

/* Can this op execute inside the table's live range without risking a GC or a
   nested call? The reserved slots sit at the TOP of the frame, so a GC (whose
   atomic phase nils [L->top, stack_end)) or a call (which drops L->top below
   them) while they hold live values would clobber them. Scalar replacement is
   sound only when the live range is free of allocations, calls, GC-able throws
   and metamethod dispatch. Proven-primitive arith (typeinfer `known` bits)
   cannot dispatch a metamethod, so it stays safe; generic arith does not. */
static int sr_op_is_gcsafe(const LcInst *in) {
  unsigned k = (unsigned)in->known;
  int bok = (k & (LC_KNOWN_B_INT | LC_KNOWN_B_FLT)) != 0;
  int cok = (k & (LC_KNOWN_C_INT | LC_KNOWN_C_FLT)) != 0;
  switch (in->bc_op) {
    case OP_MOVE: case OP_LOADK: case OP_LOADKX: case OP_LOADI: case OP_LOADF:
    case OP_LOADNIL: case OP_LOADFALSE: case OP_LOADTRUE: case OP_LFALSESKIP:
    case OP_NOT: case OP_GETUPVAL: case OP_SETUPVAL:
    case OP_JMP: case OP_FORLOOP: case OP_FORPREP:
    case OP_EXTRAARG:                             /* inert; codegen emits 0 B  */
      return 1;                                   /* no alloc/call/metamethod  */
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
    case OP_IDIV: case OP_POW: case OP_BAND: case OP_BOR: case OP_BXOR:
    case OP_SHL: case OP_SHR:
      return bok && cok;                          /* both operands proven num  */
    case OP_ADDI: case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_DIVK:
    case OP_MODK: case OP_IDIVK: case OP_POWK: case OP_BANDK: case OP_BORK:
    case OP_BXORK: case OP_SHRI: case OP_SHLI: case OP_UNM: case OP_BNOT:
      return bok;                                 /* reg operand proven num    */
    /* metamethod-fallback markers: each immediately follows its arith op and
       runs ONLY if the fast path failed. Whenever this op is in range its arith
       is in range too; if that arith is not proven-primitive we bail on it
       first, so reaching here means the arith was proven and this marker is
       statically dead -> no metamethod, no GC. */
    case OP_MMBIN: case OP_MMBINI: case OP_MMBINK:
      return 1;
    default:
      return 0;            /* calls, allocs, len, concat, compares, table ops  */
  }
}

static void sr_try_func(LcFunc *f) {
  Proto   *p   = f ? f->source : NULL;
  int      dbg = getenv("SR_DEBUG") != NULL;
  uint32_t bi, bj;
  if (!p) return;

  for (bi = 0; bi < f->nblocks; bi++) {
    LcInst *nt;
    for (nt = f->blocks[bi]->first; nt; nt = nt->next) {
      int R, nregs, slot_base, ok, is_int, kval, dst, valreg, valk, lo, hi, wr;
      int nt_pc, last_pc;
      SrKeySet ks;
      LcInst *in;

      if (nt->bc_op != OP_NEWTABLE) continue;
      R       = nt->a;
      nregs   = p->maxstacksize;
      nt_pc   = nt->bc_pc;
      last_pc = nt_pc;
      ks.n    = 0;
      ok      = !sr_reg_captured(p, R);

      /* (a) every OTHER use of R must be an allowed constant-key field op; any
         read/write of R elsewhere disqualifies. Track the last field-use pc. */
      for (bj = 0; ok && bj < f->nblocks; bj++) {
        for (in = f->blocks[bj]->first; in; in = in->next) {
          if (in == nt) continue;
          if (sr_is_get(in, R, &is_int, &kval, &dst) ||
              sr_is_set(in, R, &is_int, &kval, &valreg, &valk)) {
            if (sr_key_intern(&ks, is_int, kval) < 0) { ok = 0; break; }
            if (in->bc_pc > last_pc) last_pc = in->bc_pc;
            continue;
          }
          wr = ip_write_range(in, nregs, &lo, &hi);
          if (wr < 0 || (wr == 1 && R >= lo && R <= hi)) {
            if (dbg) fprintf(stderr, "[SR] R=%d bail(use-write) bc_op=%d\n", R, in->bc_op);
            ok = 0; break;
          }
          if (ip_reads_slot(in, R, nregs)) {
            if (dbg) fprintf(stderr, "[SR] R=%d bail(use-read) bc_op=%d\n", R, in->bc_op);
            ok = 0; break;
          }
        }
      }
      if (!ok || ks.n == 0) {
        if (dbg && ks.n == 0) fprintf(stderr, "[SR] R=%d bail(nokeys)\n", R);
        continue;
      }

      /* (a2) the live range (nt_pc, last_pc] must contain no GC safepoint -- the
         reserved slots are above L->top, so a GC/call there would nil them. */
      for (bj = 0; ok && bj < f->nblocks; bj++) {
        for (in = f->blocks[bj]->first; in; in = in->next) {
          if (in == nt) continue;
          if (in->bc_pc <= nt_pc || in->bc_pc > last_pc) continue;   /* out of range */
          if (sr_is_get(in, R, &is_int, &kval, &dst) ||
              sr_is_set(in, R, &is_int, &kval, &valreg, &valk)) continue;  /* our op */
          if (!sr_op_is_gcsafe(in)) {
            if (dbg) fprintf(stderr, "[SR] R=%d bail: safepoint bc_op=%d pc=%d in (%d,%d]\n",
                             R, in->bc_op, in->bc_pc, nt_pc, last_pc);
            ok = 0; break;
          }
        }
      }
      if (!ok) continue;

      /* (a3) no loop back-edge may re-enter the live range (nt_pc, last_pc]
         WITHOUT re-executing the home NEWTABLE (which re-nils the slots): such
         an edge carries a live slot across whatever safepoint the loop holds,
         and the flat (a2) pc-interval is blind to it. A table created INSIDE a
         loop is safe -- its back-edge targets <= nt_pc, re-running the nil. The
         branch target is in `c`; a backward edge has c < bc_pc. (Found by the
         scalar-replace soundness attack: a `goto` re-reading a field after a GC
         whose pc was textually past last_pc.) */
      for (bj = 0; ok && bj < f->nblocks; bj++) {
        for (in = f->blocks[bj]->first; in; in = in->next) {
          if (in->bc_op != OP_JMP && in->bc_op != OP_FORLOOP &&
              in->bc_op != OP_TFORLOOP) continue;
          if (in->c < in->bc_pc && in->c > nt_pc && in->c <= last_pc) {
            if (dbg) fprintf(stderr, "[SR] R=%d bail: back-edge to pc=%d in (%d,%d]\n",
                             R, in->c, nt_pc, last_pc);
            ok = 0; break;
          }
        }
      }
      if (!ok) continue;
      if (dbg) fprintf(stderr, "[SR] R=%d FIRE nkeys=%d range=(%d,%d]\n", R, ks.n, nt_pc, last_pc);

      /* (b) reserve fresh slots above the frame; maxstacksize is a lu_byte. */
      slot_base = p->maxstacksize;
      if (slot_base + ks.n > 255) continue;
      p->maxstacksize = (lu_byte)(slot_base + ks.n);

      /* (c) rewrite the home NEWTABLE (-> nil the slots) and every field op. */
      sr_rewrite(nt, OP_LOADNIL, slot_base, ks.n - 1);
      for (bj = 0; bj < f->nblocks; bj++) {
        for (in = f->blocks[bj]->first; in; in = in->next) {
          if (in == nt) continue;
          if (sr_is_get(in, R, &is_int, &kval, &dst)) {
            sr_rewrite(in, OP_MOVE, dst, slot_base + sr_key_find(&ks, is_int, kval));
          } else if (sr_is_set(in, R, &is_int, &kval, &valreg, &valk)) {
            int slot = slot_base + sr_key_find(&ks, is_int, kval);
            if (valreg >= 0) sr_rewrite(in, OP_MOVE,  slot, valreg);
            else             sr_rewrite(in, OP_LOADK, slot, valk);
          }
        }
      }
    }
  }
}

void lc_pass_scalar_replace(LcModule *m) {
  uint32_t i;
  if (!m) return;
  for (i = 0; i < m->nfuncs; i++)
    if (m->funcs[i]) sr_try_func(m->funcs[i]);
}
