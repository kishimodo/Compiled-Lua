/*
** lift.c — Bytecode -> SSA IR. See lift.h and ../../PROMPT.md §8.
**
** M0 (epsilon): faithful, generic, *memory-form* (pre-SSA) lowering of the
** epsilon op set produced by `print("hello")` — VARARGPREP, GETTABUP(_ENV),
** LOADK, CALL, RETURN*. One basic block per function (the epsilon program has
** no branches). Every op is emitted in its generic boxed form carrying the
** decoded bytecode A/B/C operands; later passes (M1+) refine specifics from
** inst->a/b/c + bc_pc.
**
** TODO(M1+): full opcode coverage + CFG block splitting at jump targets;
**   SSA construction (dominance-frontier phi insertion) over Lua registers;
**   fuse LOADKX/NEWTABLE + EXTRAARG; pcall/xpcall regions; call-graph edges.
*/
#include "lift.h"
#include "ir.h"

#include "lobject.h"   /* Proto layout: sizecode, code, sizep, p, ...        */
#include "lopcodes.h"  /* GET_OPCODE / GETARG_A/B/C / GETARG_Bx decode macros */

/*
** Map a Lua 5.4 bytecode opcode to its generic memory-form IR opcode for the
** M0 epsilon set. `bc_op` is the decoded OpCode; `bArg` is the already-decoded
** B operand (needed to distinguish GETTABUP-on-_ENV from a plain table get).
**
** Anything outside the epsilon set falls through to a generic catch-all so
** lifting never crashes on a richer program — but those ops are NOT lowered
** correctly here (that is M1+ work). We reuse LC_OP_CONST as an inert
** placeholder: it produces a value, has no side effects, and the operands are
** preserved on inst->a/b/c for whoever finishes coverage later.
*/
static LcOpcode op_to_lc(int bc_op, int bArg) {
  switch (bc_op) {
    case OP_VARARGPREP:           /* (adjust vararg params) — prep marker     */
      return LC_OP_VARARG;
    case OP_GETTABUP:             /* R[A] := UpValue[B][K[C]]                 */
      /* For the main chunk, _ENV is upvalue 0; treat that as a global read.  */
      return (bArg == 0) ? LC_OP_GLOBAL_GET : LC_OP_TABLE_GET;
    case OP_LOADK:                /* R[A] := K[Bx]                            */
      return LC_OP_CONST;
    case OP_CALL:                 /* R[A],... := R[A](R[A+1],...)             */
      return LC_OP_CALL;
    case OP_RETURN:               /* return R[A],...                          */
    case OP_RETURN0:              /* return                                   */
    case OP_RETURN1:              /* return R[A]                              */
      return LC_OP_RETURN;
    default:
      /* TODO(M1+): full opcode coverage. Inert placeholder for now. */
      return LC_OP_CONST;
  }
}

void lc_lift_func(LcFunc *f) {
  if (!f || !f->source) return;

  Proto *p = f->source;

  /* M0 memory form, not SSA — be explicit (lc_func_new already sets this). */
  f->is_ssa = false;
  f->is_vararg = (p->is_vararg != 0);

  /* Epsilon: a single basic block is sufficient (no branches). */
  LcBlock *blk = lc_block_new(f);
  if (!blk) return;

  for (int pc = 0; pc < p->sizecode; pc++) {
    Instruction i = p->code[pc];
    int bc_op = (int)GET_OPCODE(i);
    int A = GETARG_A(i);
    int B, C;

    LcOpcode lc_op = op_to_lc(bc_op, GETARG_B(i));

    switch (bc_op) {
      case OP_LOADK:
        /* iABx form: const index lives in Bx, not B/C. Carry it in `b`. */
        B = GETARG_Bx(i);
        C = 0;
        break;
      case OP_VARARGPREP:
        /* iABx-shaped prep marker; A is the param count. */
        B = 0;
        C = 0;
        break;
      default:
        /* iABC ops (GETTABUP / CALL / RETURN / generic catch-all). */
        B = GETARG_B(i);
        C = GETARG_C(i);
        break;
    }

    lc_emit_bc(blk, lc_op, A, B, C, pc);

    /* TODO(M1+): LOADKX/NEWTABLE are each followed by OP_EXTRAARG that must be
    ** fused into the preceding op. They don't appear in epsilon; skip for now
    ** (the catch-all path keeps the EXTRAARG word from crashing the walk). */
  }
}

LcModule *lc_lift_program(Proto *entry, Proto **reachable, uint32_t nreachable) {
  LcModule *m = lc_module_new();
  if (!m) return NULL;

  for (uint32_t i = 0; i < nreachable; i++) {
    Proto *p = reachable[i];
    LcFunc *f = lc_func_new(m, p);
    if (!f) continue;
    if (p == entry) m->entry = f;
    lc_lift_func(f);
  }

  /* TODO(M1+): lc_build_callgraph(m) is run by the opt pipeline, not here. */
  return m;
}
