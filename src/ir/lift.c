/*
** lift.c — Bytecode -> SSA IR. See lift.h and ../../PROMPT.md §8.
**
** M0 (Plan 1): faithful, generic, *memory-form* (pre-SSA) lowering of the
** arithmetic + control-flow op set (loads, arith/bitwise/unary/len/concat,
** comparisons, branches, numeric for) on top of the epsilon set
** (VARARGPREP, GETTABUP(_ENV), LOADK, CALL, RETURN*).
**
** Architecture (per the Plan-1 doc): NO CFG/SSA. Instructions are emitted in
** bytecode order into a single basic block; branch targets are resolved *here*
** (from sJ/Bx) and stashed on the instruction so codegen only needs a
** bc_pc -> code-offset map. Every op is emitted in its generic boxed form
** carrying the decoded bytecode A/B/C operands plus `bc_op` (the originating
** Lua opcode) so codegen can dispatch on it for the exact lowering.
**
** Operand carriage on LcInst (M0 memory form):
**   - a/b/c hold decoded operands as documented per-op below.
**   - For branch ops (JMP/FORPREP/FORLOOP) `c` holds the *resolved target pc*.
**   - For comparisons (EQ/LT/LE/EQK/EQI/LTI/LEI/GTI/GEI) `c` holds the k-bit;
**     codegen derives the skip target (bc_pc+2) itself.
**   - LOADKX fuses the following EXTRAARG: `b` carries the const index (Ax) and
**     the EXTRAARG pc is occupied by a benign no-op IR inst (bc_op=OP_EXTRAARG)
**     so branch targets that land on it stay correct.
**
** TODO(M1+): full opcode coverage (tables/closures/generic-for/pcall) + real
**   CFG block splitting at jump targets; SSA construction; call-graph edges.
*/
#include "lift.h"
#include "ir.h"

#include "lobject.h"   /* Proto layout: sizecode, code, sizep, p, ...        */
#include "lopcodes.h"  /* GET_OPCODE / GETARG_* decode macros                 */

/*
** Map a Lua 5.4 bytecode opcode to a *coarse* memory-form IR opcode category.
** The category seeds future opt passes; the precise lowering in M0 codegen is
** driven by inst->bc_op, not this. `bArg` distinguishes GETTABUP-on-_ENV from a
** plain table get for the main-chunk global-read special case.
**
** Anything outside the Plan-1 set falls through to a generic catch-all so
** lifting never crashes on a richer program — but the supported-ops gate
** (src/driver/supported_ops.c) rejects such programs before codegen.
*/
static LcOpcode op_to_lc(int bc_op, int bArg) {
  switch (bc_op) {
    case OP_VARARGPREP:
      return LC_OP_VARARG;
    case OP_VARARG:
      return LC_OP_VARARG;
    case OP_GETTABUP:
      /* For the main chunk, _ENV is upvalue 0; treat that as a global read. */
      return (bArg == 0) ? LC_OP_GLOBAL_GET : LC_OP_TABLE_GET;

    /* --- closures & upvalues (Plan 3) --- */
    case OP_CLOSURE:
      return LC_OP_CLOSURE;
    case OP_GETUPVAL:
      return LC_OP_UPVAL_GET;
    case OP_SETUPVAL:
      return LC_OP_UPVAL_SET;

    /* --- generic-for + to-be-closed (Plan 3) --- */
    case OP_TFORPREP:
      return LC_OP_JMP;        /* coarse: TFORPREP ends with an uncond jump */
    case OP_TFORCALL:
      return LC_OP_TFORCALL;
    case OP_TFORLOOP:
      return LC_OP_TFORLOOP;
    case OP_TBC:
    case OP_CLOSE:
      return LC_OP_CONST;      /* coarse no-result category; codegen by bc_op */

    /* --- tables (Plan 2) --- */
    case OP_NEWTABLE:
      return LC_OP_NEWTABLE;
    case OP_GETFIELD:
    case OP_GETI:
    case OP_GETTABLE:
      return LC_OP_TABLE_GET;
    case OP_SETFIELD:
    case OP_SETI:
    case OP_SETTABLE:
    case OP_SETTABUP:
    case OP_SETLIST:
      return LC_OP_TABLE_SET;

    /* --- loads --- */
    case OP_LOADK:
    case OP_LOADKX:
    case OP_LOADI:
    case OP_LOADF:
    case OP_LOADFALSE:
    case OP_LFALSESKIP:
    case OP_LOADTRUE:
    case OP_LOADNIL:
    case OP_MOVE:
      return LC_OP_CONST;       /* coarse "produces a value" category */

    /* --- arithmetic --- */
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV:
    case OP_MOD: case OP_IDIV: case OP_POW:
    case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_DIVK:
    case OP_MODK: case OP_IDIVK: case OP_POWK:
    case OP_ADDI:
      return LC_OP_ARITH;

    /* --- bitwise --- */
    case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR:
    case OP_BANDK: case OP_BORK: case OP_BXORK:
    case OP_SHRI: case OP_SHLI:
      return LC_OP_BITWISE;

    /* --- unary / len / concat / self --- */
    case OP_UNM:    return LC_OP_UNM;
    case OP_BNOT:   return LC_OP_BITWISE;
    case OP_NOT:    return LC_OP_NOT;
    case OP_LEN:    return LC_OP_LEN;
    case OP_CONCAT: return LC_OP_CONCAT;
    case OP_SELF:   return LC_OP_TABLE_GET;

    /* --- metamethod-bin markers (codegen no-ops them) --- */
    case OP_MMBIN: case OP_MMBINI: case OP_MMBINK:
    case OP_EXTRAARG:
      return LC_OP_CONST;       /* inert no-op */

    /* --- control flow --- */
    case OP_JMP:
      return LC_OP_JMP;
    case OP_EQ: case OP_LT: case OP_LE:
    case OP_EQK: case OP_EQI:
    case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
      return LC_OP_CMP;
    case OP_TEST:    return LC_OP_TEST;
    case OP_TESTSET: return LC_OP_TEST;
    case OP_FORPREP: return LC_OP_FORPREP_I;
    case OP_FORLOOP: return LC_OP_FORLOOP_I;

    /* --- calls / returns --- */
    case OP_CALL:
      return LC_OP_CALL;
    case OP_TAILCALL:
      return LC_OP_TAILCALL;
    case OP_RETURN:
    case OP_RETURN0:
    case OP_RETURN1:
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

  /* Plan 1: a single basic block. Branches are resolved by bc_pc in codegen,
     not via a CFG (M1 work). */
  LcBlock *blk = lc_block_new(f);
  if (!blk) return;

  for (int pc = 0; pc < p->sizecode; pc++) {
    Instruction i = p->code[pc];
    int bc_op = (int)GET_OPCODE(i);
    int A = GETARG_A(i);
    int B = 0, C = 0;

    LcOpcode lc_op = op_to_lc(bc_op, GETARG_B(i));

    switch (bc_op) {
      /* ---- iABx loads: const index in Bx (carried in `b`) ---- */
      case OP_LOADK:
        B = GETARG_Bx(i);
        C = 0;
        break;

      /* ---- LOADKX A : fuse the following EXTRAARG (const index = Ax) ---- */
      case OP_LOADKX: {
        int ax = 0;
        if (pc + 1 < p->sizecode &&
            GET_OPCODE(p->code[pc + 1]) == OP_EXTRAARG) {
          ax = GETARG_Ax(p->code[pc + 1]);
        }
        B = ax;   /* const index carried in `b` */
        C = 0;
        break;
      }

      /* ---- iAsBx loads ---- */
      case OP_LOADI:
        B = GETARG_sBx(i);   /* signed immediate in `b` */
        C = 0;
        break;
      case OP_LOADF:
        B = GETARG_sBx(i);   /* signed immediate; codegen builds (double)sBx */
        C = 0;
        break;

      /* ---- iABC loads ---- */
      case OP_LOADFALSE:
      case OP_LFALSESKIP:
      case OP_LOADTRUE:
        B = 0; C = 0;
        break;
      case OP_LOADNIL:
        B = GETARG_B(i);     /* count - 1 (inclusive) */
        C = 0;
        break;
      case OP_MOVE:
        B = GETARG_B(i);     /* source register */
        C = 0;
        break;

      /* ---- immediate arith / bitwise (signed C) ---- */
      case OP_ADDI:
      case OP_SHRI:
      case OP_SHLI:
        B = GETARG_B(i);
        C = GETARG_sC(i);    /* signed immediate */
        break;

      /* ---- comparisons: a=left, b=right(reg/imm/constidx), c=k-bit ---- */
      case OP_EQ:
      case OP_LT:
      case OP_LE:
        B = GETARG_B(i);     /* right register */
        C = GETARG_k(i);     /* k-bit */
        break;
      case OP_EQK:
        B = GETARG_B(i);     /* right constant index */
        C = GETARG_k(i);
        break;
      case OP_EQI:
      case OP_LTI:
      case OP_LEI:
      case OP_GTI:
      case OP_GEI:
        B = GETARG_sB(i);    /* signed immediate right operand */
        C = GETARG_k(i);
        break;

      /* ---- TEST/TESTSET: a=A, b=B(TESTSET only), c=k-bit ---- */
      case OP_TEST:
        B = 0;
        C = GETARG_k(i);
        break;
      case OP_TESTSET:
        B = GETARG_B(i);
        C = GETARG_k(i);
        break;

      /* ---- unconditional jump: resolve target into `c` ---- */
      case OP_JMP:
        B = 0;
        C = pc + 1 + GETARG_sJ(i);   /* resolved target pc */
        break;

      /* ---- numeric for: resolve target into `c` ---- */
      case OP_FORPREP:
        /* skip the loop body if Rt_ForPrep says zero-trip; target is one past
           the matching FORLOOP = pc + 2 + Bx. */
        B = GETARG_Bx(i);
        C = pc + 2 + GETARG_Bx(i);
        break;
      case OP_FORLOOP:
        /* loop back to the first body instruction = pc + 1 - Bx. */
        B = GETARG_Bx(i);
        C = pc + 1 - GETARG_Bx(i);
        break;

      /* ---- metamethod-bin markers / extraarg: inert; operands irrelevant ---- */
      case OP_MMBIN:
      case OP_MMBINI:
      case OP_MMBINK:
      case OP_EXTRAARG:
        B = 0; C = 0;
        break;

      /* ---- NEWTABLE A B C (+ trailing EXTRAARG): decode size hints like
              v1 Lower_NewTable / lvm.c OP_NEWTABLE. B is log2(hashsize)+1; if the
              k bit is set the EXTRAARG's Ax holds the high bits of the array
              size. The EXTRAARG at pc+1 stays an inert no-op. ---- */
      case OP_NEWTABLE: {
        B = GETARG_B(i);
        C = GETARG_C(i);
        if (B > 0) { B = 1 << (B - 1); }
        if (GETARG_k(i) && pc + 1 < p->sizecode &&
            GET_OPCODE(p->code[pc + 1]) == OP_EXTRAARG) {
          C += GETARG_Ax(p->code[pc + 1]) * (MAXARG_C + 1);
        }
        break;
      }

      /* ---- SETI/SETFIELD/SETTABLE/SETTABUP A B C k: encode the value operand
              as Ck = k ? -C-1 : C (Ck>=0 => R[Ck]; Ck<0 => K[-Ck-1]). a=A,
              b=B (int key / const-key idx / reg key / upvalue idx), c=Ck.
              Matches v1 Lower_SetI/SetField/SetTable/SetTabUp exactly. ---- */
      case OP_SETI:
      case OP_SETFIELD:
      case OP_SETTABLE:
      case OP_SETTABUP: {
        int Carg = GETARG_C(i);
        B = GETARG_B(i);
        C = GETARG_k(i) ? -Carg - 1 : Carg;   /* Ck-encoded value operand */
        break;
      }

      /* ---- SETLIST A B C (+ trailing EXTRAARG when k set): if the k bit is set
              the EXTRAARG's Ax holds the high bits of the starting index:
              real_C = C + Ax*(MAXARG_C+1). The EXTRAARG at pc+1 stays a no-op.
              B==0 ("multret") is passed through; Rt_SetList reads L->top. ---- */
      case OP_SETLIST: {
        B = GETARG_B(i);
        C = GETARG_C(i);
        if (GETARG_k(i) && pc + 1 < p->sizecode &&
            GET_OPCODE(p->code[pc + 1]) == OP_EXTRAARG) {
          C += GETARG_Ax(p->code[pc + 1]) * (MAXARG_C + 1);
        }
        break;
      }

      /* ---- closures & upvalues (Plan 3) ----
              CLOSURE A Bx: a=A, b=Bx (index into P->p). GETUPVAL/SETUPVAL A B:
              a=A, b=B (upvalue index). VARARG A C: a=A, b=C (codegen converts
              C to NRequired). ---- */
      case OP_CLOSURE:
        B = GETARG_Bx(i);
        C = 0;
        break;
      case OP_GETUPVAL:
      case OP_SETUPVAL:
        B = GETARG_B(i);
        C = 0;
        break;
      case OP_VARARG:
        B = GETARG_C(i);     /* raw C; codegen: NRequired = (C==0)?-1:(C-1) */
        C = 0;
        break;

      /* ---- generic-for (Plan 3): resolve branch target into `c` ----
              TFORPREP A Bx: uncond jump forward to pc+1+Bx (the TFORCALL).
              TFORLOOP A Bx: conditional jump back to pc+1-Bx (the body start).
              TFORCALL A C : no branch; a=A, b=C. TBC/CLOSE A: a=A. ---- */
      case OP_TFORPREP:
        B = GETARG_Bx(i);
        C = pc + 1 + GETARG_Bx(i);   /* resolved uncond-jump target */
        break;
      case OP_TFORLOOP:
        B = GETARG_Bx(i);
        C = pc + 1 - GETARG_Bx(i);   /* resolved back-edge target */
        break;
      case OP_TFORCALL:
        B = GETARG_C(i);
        C = 0;
        break;
      case OP_TBC:
      case OP_CLOSE:
        B = 0; C = 0;
        break;

      default:
        /* iABC ops (arith/bitwise reg forms, K forms, unary, len, concat,
           self, GETTABUP, CALL, RETURN, generic catch-all). */
        B = GETARG_B(i);
        C = GETARG_C(i);
        break;
    }

    LcInst *in = lc_emit_bc(blk, lc_op, A, B, C, pc);
    if (in) {
      in->bc_op = bc_op;
      /* C2: carry the RETURN/RETURN0/RETURN1/TAILCALL k-flag. When set, the
         function created closures over its locals and codegen must Rt_Close(L,0)
         before returning/tailcalling so open upvalues don't dangle into freed
         stack slots. */
      if (bc_op == OP_RETURN || bc_op == OP_RETURN0 || bc_op == OP_RETURN1 ||
          bc_op == OP_TAILCALL) {
        in->ret_close = GETARG_k(i);
      }
    }

    /* LOADKX consumed its trailing EXTRAARG (const idx folded into `b`). Emit a
       benign no-op IR inst occupying the EXTRAARG's pc slot so any branch that
       targets that pc still maps to a real code offset. (Codegen emits zero
       bytes for OP_EXTRAARG, so its pc maps to the same offset as the next
       real instruction.) */
    if (bc_op == OP_LOADKX && pc + 1 < p->sizecode &&
        GET_OPCODE(p->code[pc + 1]) == OP_EXTRAARG) {
      LcInst *nop = lc_emit_bc(blk, LC_OP_CONST, 0, 0, 0, pc + 1);
      if (nop) nop->bc_op = OP_EXTRAARG;
      pc++;   /* advance past the EXTRAARG we just represented */
    }

    /* NEWTABLE/SETLIST (when their k bit is set) fuse the following EXTRAARG
       into their size/index hint above. Represent the consumed EXTRAARG's pc
       with a benign no-op IR inst (codegen emits zero bytes for it) so any
       branch landing on that pc still maps to a real code offset. Mirrors the
       LOADKX fusion above. */
    if ((bc_op == OP_NEWTABLE || bc_op == OP_SETLIST) &&
        GETARG_k(i) && pc + 1 < p->sizecode &&
        GET_OPCODE(p->code[pc + 1]) == OP_EXTRAARG) {
      LcInst *nop = lc_emit_bc(blk, LC_OP_CONST, 0, 0, 0, pc + 1);
      if (nop) nop->bc_op = OP_EXTRAARG;
      pc++;   /* advance past the EXTRAARG we just represented */
    }
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
