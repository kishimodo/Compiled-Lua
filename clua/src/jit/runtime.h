/*!
 * @brief
 *  C helpers callable from JIT-emitted CALL instructions.
 *  All use the Windows x64 ABI.
 */

#ifndef LUAVM_JIT_RUNTIME_H
#define LUAVM_JIT_RUNTIME_H

#include "lua.h"

/*!
 * @brief
 *  Slow-path ADD: at least one operand isn't an integer.
 *  Performs the same work as the OP_ADD slow path in lvm.c.
 *  R[A] = R[B] + R[C].
 *  Returns LUA_OK (0) on success, raises Lua error on failure (longjmps).
 */
int Rt_AddSlow( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Slow-path SUB: at least one operand isn't an integer.
 *  R[A] = R[B] - R[C].
 *  Returns 0 on success, raises Lua error on failure (longjmps).
 */
int Rt_SubSlow( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Slow-path MUL: at least one operand isn't an integer.
 *  R[A] = R[B] * R[C].
 *  Returns 0 on success, raises Lua error on failure (longjmps).
 */
int Rt_MulSlow( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Adjust L->top for an N-result return at register A.
 *  Returns N (so the JIT epilogue can store the value into RAX directly
 *  by tail-calling this from epilogue).
 */
int Rt_PrepReturn( lua_State *L, int A, int N, int NParams1 );

/*!
 * @brief
 *  Call R[A] with NArgs args (R[A+1]..R[A+NArgs]), expecting NResults
 *  results. NArgs is encoded as B-1 from the OP_CALL bytecode, NResults
 *  as C-1. Delegates to upstream luaD_call.
 *  Returns 0 on success, raises Lua error on failure.
 */
int Rt_Call( lua_State *L, int A, int NArgs, int NResults );

/*!
 * @brief
 *  R[A] = UpValue[B][K[C]:shortstring]. Delegates to upstream luaH_get.
 *  Returns 0 on success; raises Lua error on type mismatch.
 */
int Rt_GetTabUp( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  R[A] = UpValue[B]. 16-byte TValue copy.
 */
int Rt_GetUpval( lua_State *L, int A, int B );

/*!
 * @brief
 *  UpValue[B] = R[A]. 16-byte TValue copy with GC write-barrier.
 */
int Rt_SetUpval( lua_State *L, int A, int B );

/*!
 * @brief
 *  Create an LClosure for P->p[Bx] and store it in R[A]. The upvalue
 *  binding logic is the same as upstream lvm.c OP_CLOSURE.
 */
int Rt_NewClosure( lua_State *L, int A, int Bx );

/*!
 * @brief
 *  Compare R[A] vs R[B] for equality / less-than / less-equal. Used as the
 *  slow path when either operand isn't a Lua integer. Returns 0 or 1
 *  (the comparison result). Delegates to upstream luaV_equalobj /
 *  luaV_lessthan / luaV_lessequal.
 */
int Rt_EqSlow( lua_State *L, int A, int B );
int Rt_LtSlow( lua_State *L, int A, int B );
int Rt_LeSlow( lua_State *L, int A, int B );

/*!
 * @brief
 *  Slow-path helpers for immediate-comparison opcodes (EQI/LTI/LEI) and
 *  constant-pool equality (EQK). Called when R[A] is not an integer or
 *  for metamethod dispatch. Return 0 or 1 (comparison result).
 *
 * @param A
 *  source register index
 *
 * @param sB
 *  signed immediate integer (for EQI/LTI/LEI)
 *
 * @param B
 *  constant-pool index (for EQK)
 */
int Rt_EqISlow( lua_State *L, int A, int sB );
int Rt_LtISlow( lua_State *L, int A, int sB );
int Rt_LeISlow( lua_State *L, int A, int sB );
int Rt_EqKSlow( lua_State *L, int A, int B );

/* Rt_OrderISlow: unified LTI/LEI/GTI/GEI slow path; RawIns = the comparison's
   own raw instruction word (carries sB, the float-immediate flag in C, and the
   opcode selecting direction/swap). Returns the 0/1 comparison result. */
int Rt_OrderISlow( lua_State *L, int A, int RawIns );

/* Rt_ArithIK: unified immediate/constant arith slow path; MmIns = the trailing
   OP_MMBINI/OP_MMBINK word (true metamethod event, original operand, flip). */
int Rt_ArithIK( lua_State *L, int A, int B, int MmIns );

/*!
 * @brief
 *  Initialise a numeric for loop. Reads R[A], R[A+1], R[A+2] as
 *  init/limit/step, validates types (raises on non-integer/non-float),
 *  computes whether the loop should run at all. Sets R[A+3] = init (the
 *  loop variable). Returns:
 *    0 = run the loop body (caller proceeds)
 *    1 = skip the loop body (caller jumps forward by Bx+1)
 *  This wraps upstream luaV_forprep semantics for integer loops; for the
 *  float subcase it also sets the closing flag like upstream does.
 */
int Rt_ForPrep( lua_State *L, int A );

/*!
 * @brief
 *  Iteration step for OP_FORLOOP. Increments R[A] by R[A+2] (the step),
 *  compares to R[A+1] (the limit), updates R[A+3] (the loop variable
 *  visible in the body). Returns:
 *    1 = continue the loop (caller branches back)
 *    0 = loop done (caller falls through)
 *  Integer overflow handling matches upstream luaV_forloop.
 */
int Rt_ForLoop( lua_State *L, int A );

/*!
 * @brief
 *  R[A] = new empty table. B and C are raw size hints from the OP_NEWTABLE
 *  instruction (NOT decoded via luaO_fb2int — for 2d's scope we don't
 *  pre-size large tables; they resize on first insert). Triggers a GC step.
 */
int Rt_NewTable( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Table access slow paths — all delegate to upstream luaV_finishget /
 *  luaV_finishset (which handle metamethods + raw access).
 *  See lvm.c's OP_GETI/SETI/GETFIELD/SETFIELD/GETTABLE/SETTABLE/SETTABUP
 *  for the exact semantics each helper implements.
 *
 *  Setter variants encode C and K into a single Ck parameter to stay
 *  within the four-register Win64 ABI (RCX/RDX/R8/R9):
 *    K == 0  ->  Ck =  C        (source is R[C])
 *    K == 1  ->  Ck = -C - 1   (source is K[C])
 */
int Rt_GetI    ( lua_State *L, int A, int B, int C );   /* R[A] = R[B][C]          (C immediate int) */
int Rt_SetI    ( lua_State *L, int A, int B, int Ck );  /* R[A][B] = R[C] or K[C]  (Ck-encoded)     */
int Rt_GetField( lua_State *L, int A, int B, int C );   /* R[A] = R[B][K[C]:string]                  */
int Rt_SetField( lua_State *L, int A, int B, int Ck );  /* R[A][K[B]] = R[C] or K[C]                 */
int Rt_GetTable( lua_State *L, int A, int B, int C );   /* R[A] = R[B][R[C]]                         */
int Rt_SetTable( lua_State *L, int A, int B, int Ck );  /* R[A][R[B]] = R[C] or K[C]                 */
int Rt_SetTabUp( lua_State *L, int A, int B, int Ck );  /* UpValue[A][K[B]] = R[C] or K[C]           */

/*!
 * @brief
 *  Populate a table: t = R[A]; t[C+1..C+B] = R[A+1..A+B].
 *  If B == 0 the helper reads from R[A+1] up to L->top - 1.
 *  Caller must ensure L->top is set when B == 0.
 *  The OP_SETLIST k-bit / EXTRAARG offset (array parts > MAXARG_C elements) IS
 *  handled: Lower_SetList folds GETARG_Ax into C at compile time before calling
 *  this, so C already carries the full starting index.
 */
int Rt_SetList( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  R[A] = #R[B].  Length operator; delegates to luaV_objlen.
 */
int Rt_Len( lua_State *L, int A, int B );

/*!
 * @brief
 *  R[A] = R[A] .. R[A+1] .. ... .. R[A+B-1] (B values).
 *  Sets L->top above R[A+B-1], calls luaV_concat(L, B), then copies the
 *  result back into R[A].
 */
int Rt_Concat( lua_State *L, int A, int B );

/*!
 * @brief
 *  Tail-call R[A] with NArgs args (B-1 from OP_TAILCALL bytecode). For
 *  v1 this is a normal Rt_Call followed by a multi-result propagation —
 *  semantically correct but does NOT optimise stack frames. True
 *  frame-reusing tailcalls are 2f+ work.
 *  Returns the number of results the callee produced.
 */
int Rt_TailCall( lua_State *L, int A, int NArgs );

/*!
 * @brief
 *  Copy varargs into R[A..A+NRequired-1] using upstream luaT_getvarargs.
 *  NRequired == -1 means "all available varargs". Delegates to luaT_getvarargs.
 */
int Rt_Vararg( lua_State *L, int A, int NRequired );

/*!
 * @brief
 *  OP_VARARGPREP A: prepare the call frame for a vararg function. A is
 *  the number of fixed parameters. Delegates to upstream
 *  luaT_adjustvarargs which moves the function + fixed args to the top
 *  of the stack and sets ci->u.l.nextraargs so subsequent OP_VARARG
 *  reads from the right place.
 */
int Rt_VarargPrep( lua_State *L, int A );

/*!
 * @brief
 *  R[A] = not R[B] (logical NOT, result is boolean).
 */
int Rt_NotOp( lua_State *L, int A, int B );

/*!
 * @brief
 *  R[A] = -R[B] (arithmetic unary minus). Delegates to luaO_arith
 *  with LUA_OPUNM.
 */
int Rt_UnmOp( lua_State *L, int A, int B );

/*!
 * @brief
 *  R[A] = ~R[B] (bitwise NOT). Delegates to luaO_arith with LUA_OPBNOT.
 */
int Rt_BNotOp( lua_State *L, int A, int B );

/*!
 * @brief
 *  Complete ADD/SUB/MUL for any operand types (int, float, string coercion,
 *  metamethods). Safe to call unconditionally from the AOT codegen — unlike
 *  the slow-path-only Rt_AddSlow/SubSlow/MulSlow which assume the int/float
 *  fast path already ran. All delegate to luaO_arith.
 */
/* Complete ADD (any operands + metamethods), unlike the slow-path-only Rt_AddSlow. */
int Rt_AddOp ( lua_State *L, int A, int B, int C );
/* Complete SUB (any operands + metamethods), unlike the slow-path-only Rt_SubSlow. */
int Rt_SubOp ( lua_State *L, int A, int B, int C );
/* Complete MUL (any operands + metamethods), unlike the slow-path-only Rt_MulSlow. */
int Rt_MulOp ( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Binary arithmetic ops with float / edge-case semantics. All delegate
 *  to upstream luaO_arith — no integer fast path in v1.
 */
int Rt_DivOp ( lua_State *L, int A, int B, int C );
int Rt_ModOp ( lua_State *L, int A, int B, int C );
int Rt_IDivOp( lua_State *L, int A, int B, int C );
int Rt_PowOp ( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  *K arithmetic variants — R[A] = R[B] <op> K[C].
 *  K[C] is fetched from the constant pool of the current closure's proto.
 *  All delegate to upstream luaO_arith with the appropriate LUA_OP* constant.
 */
int Rt_AddKOp ( lua_State *L, int A, int B, int C );
int Rt_AddIOp ( lua_State *L, int A, int B, int sC );  /* R[A] = R[B] + sC (signed immediate) */
int Rt_SubKOp ( lua_State *L, int A, int B, int C );
int Rt_MulKOp ( lua_State *L, int A, int B, int C );
int Rt_DivKOp ( lua_State *L, int A, int B, int C );
int Rt_ModKOp ( lua_State *L, int A, int B, int C );
int Rt_IDivKOp( lua_State *L, int A, int B, int C );
int Rt_PowKOp ( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Bitwise register-register ops — R[A] = R[B] <op> R[C].
 *  All delegate to upstream luaO_arith with the appropriate LUA_OP* constant.
 */
int Rt_BAndOp( lua_State *L, int A, int B, int C );
int Rt_BOrOp ( lua_State *L, int A, int B, int C );
int Rt_BXorOp( lua_State *L, int A, int B, int C );
int Rt_ShlOp ( lua_State *L, int A, int B, int C );
int Rt_ShrOp ( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Bitwise K variants — R[A] = R[B] <op> K[C].
 *  K[C] is fetched from the constant pool of the current closure's proto.
 */
int Rt_BAndKOp( lua_State *L, int A, int B, int C );
int Rt_BOrKOp ( lua_State *L, int A, int B, int C );
int Rt_BXorKOp( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Shift-with-immediate variants. sC is the sB-encoded signed integer from
 *  the instruction, not a constant-pool index.
 *
 * @param sC
 *  signed immediate operand
 *
 * Rt_ShrIOp: R[A] = R[B] >> sC
 * Rt_ShlIOp: R[A] = sC << R[B]  (note: encoded backwards in Lua 5.4)
 */
int Rt_ShrIOp( lua_State *L, int A, int B, int sC );
int Rt_ShlIOp( lua_State *L, int A, int B, int sC );
/* Rt_ShiftI: unified SHRI/SHLI slow path; MmIns = the trailing OP_MMBINI word.
 * Dispatches the correct __shl/__shr metamethod (see runtime.c for rationale). */
int Rt_ShiftI( lua_State *L, int A, int B, int MmIns );

/*!
 * @brief
 *  OP_SELF: R[A+1] = R[B]; R[A] = R[B][K[C]:string].
 *  Method dispatch helper. Delegates to upstream luaV_fastget +
 *  luaV_finishget for the table lookup with metamethod semantics.
 */
int Rt_Self( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  OP_TBC A: mark R[A] as to-be-closed. Delegates to luaF_newtbcupval.
 */
int Rt_Tbc( lua_State *L, int A );

/*!
 * @brief
 *  OP_CLOSE A: close all upvalues at or above R[A]. Invokes __close
 *  metamethods. Delegates to luaF_close.
 */
int Rt_Close( lua_State *L, int A );

/*!
 * @brief
 *  OP_TFORPREP A Bx: create the to-be-closed upvalue at R[A+3] for the
 *  iterator's state cleanup. The JIT then jumps forward by Bx to reach
 *  the TFORCALL at the end of the loop body.
 */
int Rt_TForPrep( lua_State *L, int A );

/*!
 * @brief
 *  OP_TFORCALL A C: call the iterator (R[A]) with state (R[A+1]) and
 *  control (R[A+2]), storing C results into R[A+4..A+3+C].
 */
int Rt_TForCall( lua_State *L, int A, int C );

/*!
 * @brief
 *  OP_TFORLOOP A: check if R[A+4] is non-nil. If so, R[A+2] = R[A+4]
 *  (update control) and return 1 (caller jumps back to loop body).
 *  Otherwise return 0 (loop done).
 */
int Rt_TForLoop( lua_State *L, int A );

#endif /* LUAVM_JIT_RUNTIME_H */
