/*
** codegen.c — Optimized IR -> relocatable x64. See codegen.h and ../../PROMPT.md §11.
** STUB: implement for Milestone M0 (generic lowering: every op -> Rt_* / luaV_* call).
**
** REUSE src/codegen/x64_emit.* (adapted from src/jit/emit_x64.*) for encoding and
**       src/codegen/regalloc.* (adapted from src/jit/regalloc.*) for allocation.
** NEW vs the v1 JIT: LcReloc table instead of baked imm64, RIP-relative .rdata
**       loads, .pdata/.xdata UNWIND_INFO per framed function, GC stack maps.
**
** Win64 ABI (preserve from v1): RCX=lua_State*, RDX/R8/R9=operands, RAX=return,
** Lua reg N at [RDI + N*16], tag at +8. Reserve 32B shadow space; keep RSP%16==0
** at calls; reload RDI+cache after stack-relocating helpers; 8-bit tag compares.
*/
#include "codegen.h"
#include "codegen/x64_emit.h"

#include "lstate.h"        /* lua_State, CallInfo, StkIdRel layout */

#include <stddef.h>
#include <stdlib.h>

/* CI offsets — replicated from v1 src/jit/codegen.c (OFFSET_OF_CI / _FUNC).
   .func is a StkIdRel union whose live pointer .p is at offset 0 of the union. */
#define LC_OFF_CI       ( ( int32_t )offsetof( struct lua_State, ci ) )
#define LC_OFF_CI_FUNC  ( ( int32_t )offsetof( CallInfo, func ) )

/* ------------------------------------------------------------------ */
/* Frame scaffolding — faithful port of v1 EmitPrologue/EmitEpilogue/  */
/* EmitRestoreL/EmitReloadRdiAndCache (src/jit/codegen.c), retargeted   */
/* from EmitX64_*(Slot,...) onto X64Emit_*(B,...). The ONLY M0          */
/* deviation: skip the cache-register preload/reload loop (M0 keeps     */
/* every Lua register memory-resident at [RDI + N*16]; M1 enables       */
/* RegAlloc). The PUSH/POP of all 7 callee-saved regs is preserved so   */
/* the frame shape + future .pdata unwind match v1 exactly.             */
/* ------------------------------------------------------------------ */

/*!
 * @brief
 *  Emit the function prologue. Saves all callee-saved registers we use, sets
 *  up RBX = L and RDI = ci->func.p + 16 (= ci->func.p + 1 TValue, the Lua
 *  register base).
 *
 *  Stack layout: 7 pushes (56 bytes) + return address (8) = 64.
 *  sub rsp, 0x20 (32) -> 96 total, which is 16-aligned at calls.
 */
int LcCg_EmitPrologue( LcCodeBuf *B ) {
    /* save all callee-saved registers we'll use: RBX (L), RDI (regbase),
       then R12-R15 and RSI (cache regs in M1; pushed now for frame parity) */
    if ( !X64Emit_PushReg( B, X64_RDI ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_RBX ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R12 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R13 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R14 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R15 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_RSI ) ) return 0;
    /* 7 pushes = 56 bytes; with return address (8) = 64; +0x20 shadow = 96, 16-aligned */
    if ( !X64Emit_SubRspImm( B, 0x20 ) )  return 0;
    /* rbx = rcx (save L in a callee-saved register; rcx is volatile across calls) */
    if ( !X64Emit_MovRegToReg( B, X64_RBX, X64_RCX ) ) return 0;
    /* rax = [rcx + LC_OFF_CI] */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RCX, LC_OFF_CI ) ) return 0;
    /* rax = [rax + LC_OFF_CI_FUNC] */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_CI_FUNC ) ) return 0;
    /* rdi = rax */
    if ( !X64Emit_MovRegToReg( B, X64_RDI, X64_RAX ) ) return 0;
    /* ADD RDI, 16  (advance past the function slot): 48 81 C7 10 00 00 00 */
    if ( !X64Emit_AddRegImm32( B, X64_RDI, 16 ) ) return 0;
    /* M0: registers are memory-resident; no cache preload (M1 enables RegAlloc) */
    return 1;
}

/*!
 * @brief
 *  Emit the function epilogue. RAX holds the return count; restore all
 *  callee-saved registers in reverse push order and return.
 */
int LcCg_EmitEpilogue( LcCodeBuf *B ) {
    if ( !X64Emit_AddRspImm( B, 0x20 ) )  return 0;
    if ( !X64Emit_PopReg( B, X64_RSI ) )  return 0;
    if ( !X64Emit_PopReg( B, X64_R15 ) )  return 0;
    if ( !X64Emit_PopReg( B, X64_R14 ) )  return 0;
    if ( !X64Emit_PopReg( B, X64_R13 ) )  return 0;
    if ( !X64Emit_PopReg( B, X64_R12 ) )  return 0;
    if ( !X64Emit_PopReg( B, X64_RBX ) )  return 0;
    if ( !X64Emit_PopReg( B, X64_RDI ) )  return 0;
    if ( !X64Emit_Ret( B ) )              return 0;
    return 1;
}

/*!
 * @brief
 *  Restore L (first argument) into RCX from RBX before a helper call.
 *  RBX is callee-saved and holds L since the prologue; RCX is volatile.
 */
int LcCg_EmitRestoreL( LcCodeBuf *B ) {
    return X64Emit_MovRegToReg( B, X64_RCX, X64_RBX );
}

/*!
 * @brief
 *  For helpers that can RELOCATE the lua stack (Rt_VarargPrep, anything that
 *  may trigger checkstackGCp / GC shrink): re-derive RDI from L->ci->func.p+16.
 *
 *  M0: no cache reload — registers are memory-resident.
 */
int LcCg_EmitReloadRdiAndCache( LcCodeBuf *B ) {
    if ( !LcCg_EmitRestoreL( B ) ) return 0;  /* rcx = rbx */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RCX, LC_OFF_CI ) ) return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_CI_FUNC ) ) return 0;
    if ( !X64Emit_MovRegToReg( B, X64_RDI, X64_RAX ) ) return 0;
    if ( !X64Emit_AddRegImm32( B, X64_RDI, 16 ) ) return 0;
    /* M0: registers are memory-resident; no cache reload (M1 enables RegAlloc) */
    return 1;
}

/*!
 * @brief
 *  Helper-call shim: load L into RCX and three integer args into the Win64
 *  argument registers, CALL the named runtime symbol (recorded as a rel32
 *  reloc the linker resolves), then optionally reload RDI if the helper may
 *  have relocated the Lua stack. Reusable by per-op lowering (Task 11).
 */
int LcCg_EmitHelperCall3( LcCodeBuf *B, const char *Sym,
                          int a, int b, int c, int reload_after ) {
    if ( !LcCg_EmitRestoreL( B ) ) return 0;                          /* RCX = L */
    if ( !X64Emit_MovImm64ToReg( B, X64_RDX, ( uint64_t )( int64_t )a ) ) return 0;
    if ( !X64Emit_MovImm64ToReg( B, X64_R8,  ( uint64_t )( int64_t )b ) ) return 0;
    if ( !X64Emit_MovImm64ToReg( B, X64_R9,  ( uint64_t )( int64_t )c ) ) return 0;
    if ( !X64Emit_CallSym( B, Sym ) ) return 0;
    if ( reload_after && !LcCg_EmitReloadRdiAndCache( B ) ) return 0;
    return 1;
}

LcCodeModule *lc_codegen(LcModule *m) {
  (void)m;
  LcCodeModule *cm = (LcCodeModule *)calloc(1, sizeof(LcCodeModule));
  /* TODO(M0): for each LcFunc:
  **   - emit prologue (save callee-saved regs, RBX=L, RDI=stack base, reserve frame)
  **   - per-instruction lowering: generic ops -> CALL Rt_* / luaV_* (record LcReloc),
  **     typed ops (M1+) -> inline machine code
  **   - emit epilogue; build UNWIND_INFO describing the prologue
  **   - collect forward-branch placeholders, patch after the instruction loop
  **   - emit the GC stack map for each safepoint
  ** Pool string/float constants into cm->rodata; reference via RIP-relative + LcReloc.
  */
  return cm;
}

void lc_codemodule_free(LcCodeModule *cm) {
  if (!cm) return;
  /* TODO(M0): free per-func code/relocs/unwind/stackmap and rodata. */
  free(cm);
}
