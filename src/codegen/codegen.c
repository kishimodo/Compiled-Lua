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
#include "lobject.h"       /* LClosure, Proto, TValue layout (for k recovery) */

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* CI offsets — replicated from v1 src/jit/codegen.c (OFFSET_OF_CI / _FUNC).
   .func is a StkIdRel union whose live pointer .p is at offset 0 of the union. */
#define LC_OFF_CI       ( ( int32_t )offsetof( struct lua_State, ci ) )
#define LC_OFF_CI_FUNC  ( ( int32_t )offsetof( CallInfo, func ) )

/* Offsets used by the LOADK inline lowering (LC_OP_CONST) to recover the
   running closure's constant pool at runtime. v1's Lower_LoadK bakes the
   absolute &P->k[Bx] because the JIT knows P; AOT can't (the Proto is built at
   runtime), so we walk ci->func.p -> LClosure -> Proto -> k exactly like the
   Rt_* helpers do (runtime.c: clLvalue(s2v(L->ci->func.p))->p->k).

   ci->func is a StkIdRel union whose live .p is at offset 0 and points at the
   StackValue holding the closure; s2v(o)=&o->val is the TValue at the SAME
   address, whose value_ (the gc pointer) is at offset 0. gco2lcl is offset 0
   of the GCUnion (cl.l), so the gc pointer numerically IS the LClosure*. */
#define LC_OFF_LCL_P    ( ( int32_t )offsetof( LClosure, p ) )  /* LClosure.p   */
#define LC_OFF_PROTO_K  ( ( int32_t )offsetof( Proto, k ) )     /* Proto.k      */

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

/* ------------------------------------------------------------------ */
/* Per-op lowering — faithful AOT port of v1 src/jit/Lower_* (the      */
/* memory-form path: M0 keeps every Lua register at [RDI + N*16], so   */
/* we always use the memory path v1 emits when a register isn't        */
/* cached). Operands come from inst->a/b/c (decoded by lift.c).        */
/* ------------------------------------------------------------------ */

/*!
 * @brief
 *  LC_OP_VARARG (OP_VARARGPREP): call Rt_VarargPrep(L, A) then re-anchor RDI.
 *  Ported from v1 Lower_VarargPrep (codegen.c ~3073): EmitCall1ArgHelper(L,A,
 *  Rt_VarargPrep) + EmitReloadRdiAndCache. luaT_adjustvarargs advances
 *  ci->func.p, so RDI is stale after the call -> reload_after = 1.
 */
static int lower_vararg( LcCodeBuf *B, LcInst *in ) {
    /* Rt_VarargPrep takes only (L, A); pass b=0,c=0 — unused by the helper. */
    return LcCg_EmitHelperCall3( B, "Rt_VarargPrep", in->a, 0, 0, /*reload*/1 );
}

/*!
 * @brief
 *  LC_OP_GLOBAL_GET (OP_GETTABUP on _ENV): R[A] = UpVal[B][K[C]].
 *  Ported from v1 Lower_GetTabUp (codegen.c ~1328): set RDX=A,R8=B,R9=C, call
 *  Rt_GetTabUp, then EmitReloadRdiAndCache (a metamethod can grow the stack).
 */
static int lower_global_get( LcCodeBuf *B, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_GetTabUp",
                                 in->a, in->b, in->c, /*reload*/1 );
}

/*!
 * @brief
 *  LC_OP_CONST (OP_LOADK): R[A] = K[Bx].  v1 Lower_LoadK (codegen.c ~705)
 *  bakes the absolute &P->k[Bx] (a compile-time constant for the JIT) and
 *  copies the 16-byte TValue to [RDI + A*16] in two halves. For AOT the Proto
 *  is heap-built, so the constant's address is NOT known at compile time; we
 *  recover the constant pool at runtime the same way the Rt_* helpers do:
 *      RAX = L->ci                         ; RBX holds L
 *      RAX = ci->func.p                    ; -> StackValue* (the closure slot)
 *      RAX = [RAX + 0]                     ; gc ptr == LClosure*
 *      RAX = LClosure.p                    ; -> Proto*
 *      RAX = Proto.k                       ; -> &K[0] (TValue array base)
 *  then copy the value half ([RAX + Bx*16]) and tag half ([RAX + Bx*16 + 8])
 *  to [RDI + A*16] / +8. NO .rdata reloc: the constant lives in the runtime
 *  Proto, recovered via ci. Bx is carried in inst->b by the lift.
 */
static int lower_const( LcCodeBuf *B, LcInst *in ) {
    int A  = in->a;
    int Bx = in->b;
    int32_t kdisp = ( int32_t )( Bx * 16 );
    /* RAX = L->ci  (RBX holds L for the whole body) */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RBX, LC_OFF_CI ) )       return 0;
    /* RAX = ci->func.p */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_CI_FUNC ) )  return 0;
    /* RAX = [RAX + 0]  (TValue.value_.gc == LClosure*) */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, 0 ) )              return 0;
    /* RAX = LClosure.p  (Proto*) */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_LCL_P ) )    return 0;
    /* RAX = Proto.k  (&K[0]) */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_PROTO_K ) )  return 0;
    /* value half: R10 = [RAX + Bx*16] ; [RDI + A*16] = R10 */
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RAX, kdisp ) )           return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_R10 ) )          return 0;
    /* tag half: R10 = [RAX + Bx*16 + 8] ; [RDI + A*16 + 8] = R10 */
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RAX, kdisp + 8 ) )       return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16 + 8, X64_R10 ) )      return 0;
    return 1;
}

/*!
 * @brief
 *  LC_OP_CALL (OP_CALL): call R[A] with B-1 args, expecting C-1 results.
 *  Ported from v1 Lower_Call (codegen.c ~1121): NArgs = (B==0)?-1:(B-1)
 *  (B==0 => "args up to L->top", encoded as -1); NResults = C-1 (C==0 =>
 *  MULTRET, encoded as -1). Call Rt_Call then EmitReloadRdiAndCache (a callee
 *  may reallocate the Lua stack). Operands: A=in->a, B=in->b, C=in->c.
 */
static int lower_call( LcCodeBuf *B, LcInst *in ) {
    int Bee      = in->b;
    int Cee      = in->c;
    int NArgs    = ( Bee == 0 ) ? -1 : ( Bee - 1 );
    int NResults = Cee - 1;
    return LcCg_EmitHelperCall3( B, "Rt_Call",
                                 in->a, NArgs, NResults, /*reload*/1 );
}

/*!
 * @brief
 *  LC_OP_RETURN (OP_RETURN / RETURN0 / RETURN1): set up the return via
 *  Rt_PrepReturn(L, A, N, NParams1), which returns the result count in RAX,
 *  then emit the epilogue + RET (RAX is the native body's Lua result count).
 *
 *  Ported from v1 Lower_Return + EmitCallRtPrep (codegen.c ~1179 / ~615):
 *    N        = B - 1   (B==1 -> 0 results; B==2 -> 1; B==0 -> -1 MULTRET)
 *    NParams1 = C       (nparams+1 for a vararg frame, 0 otherwise; Rt_PrepReturn
 *                        uses it to reverse OP_VARARGPREP's ci->func.p relocation)
 *  v1 then JMPs to a shared epilogue (functions may have several returns); for
 *  the epsilon slice (single trailing return) we inline the epilogue directly.
 *  No reload_after: we return immediately.
 *
 *  TODO(M0): v1 also runs Rt_Close(L,0) when GETARG_k(Ins) is set (the function
 *  created closures over its locals). The lift does not yet carry the RETURN k
 *  flag; the epsilon main chunk has no upvalue-capturing closures (k=0), so it
 *  is a no-op here. M1 must thread the k flag through the IR and emit the close.
 */
static int lower_return( LcCodeBuf *B, LcInst *in ) {
    int N        = in->b - 1;   /* result count (or -1 for MULTRET) */
    int NParams1 = in->c;
    /* Rt_PrepReturn(L, A, N, NParams1) -> RAX = nresults */
    if ( !LcCg_EmitHelperCall3( B, "Rt_PrepReturn",
                                in->a, N, NParams1, /*reload*/0 ) ) return 0;
    /* RAX holds the result count; epilogue restores callee-saved regs + RET. */
    return LcCg_EmitEpilogue( B );
}

/*!
 * @brief
 *  Dispatch one IR instruction to its lowering. Unknown ops (not in the
 *  epsilon set) emit nothing and continue — lift.c's catch-all keeps the IR
 *  well-formed, and richer coverage is M1+ work.
 *
 * @return 1 on success, 0 on emission failure.
 */
static int lower_inst( LcCodeBuf *B, LcFunc *f, LcInst *in ) {
    (void)f;
    /* TODO(LUAC-001): runtime-relative savedpc; deferred — affects only
       error-traceback line numbers, not stdout. The epsilon program raises
       no error, so the differential is unaffected. */
    switch ( in->op ) {
        case LC_OP_VARARG:      return lower_vararg( B, in );
        case LC_OP_GLOBAL_GET:  return lower_global_get( B, in );
        case LC_OP_CONST:       return lower_const( B, in );
        case LC_OP_CALL:        return lower_call( B, in );
        case LC_OP_RETURN:      return lower_return( B, in );
        default:
            /* TODO(M1+): full opcode coverage. Inert for non-epsilon ops. */
            return 1;
    }
}

LcCodeModule *lc_codegen(LcModule *m) {
  if (!m) return NULL;
  LcCodeModule *cm = (LcCodeModule *)calloc(1, sizeof(LcCodeModule));
  if (!cm) return NULL;
  cm->nfuncs = m->nfuncs;
  cm->rodata = NULL;        /* epsilon: no .rdata — constants come from the    */
  cm->rodata_len = 0;       /* runtime Proto via ci (see lower_const).         */
  if (cm->nfuncs == 0) return cm;

  cm->funcs = (LcCompiledFunc *)calloc(cm->nfuncs, sizeof(LcCompiledFunc));
  if (!cm->funcs) { free(cm); return NULL; }

  for (uint32_t i = 0; i < m->nfuncs; i++) {
    LcFunc *f = m->funcs[i];
    LcCompiledFunc *cf = &cm->funcs[i];
    LcCodeBuf buf;
    int ok = 1;
    int saw_return = 0;

    if (!LcCodeBuf_Init(&buf, 256)) { lc_codemodule_free(cm); return NULL; }

    if (!LcCg_EmitPrologue(&buf)) { LcCodeBuf_Free(&buf); lc_codemodule_free(cm); return NULL; }

    for (uint32_t bi = 0; ok && f && bi < f->nblocks; bi++) {
      LcInst *in;
      for (in = f->blocks[bi]->first; in; in = in->next) {
        if (in->op == LC_OP_RETURN) saw_return = 1;
        if (!lower_inst(&buf, f, in)) { ok = 0; break; }
      }
    }

    /* If the function fell through without an explicit RETURN (shouldn't
       happen for epsilon, but keep codegen total), emit a default 0-result
       return + epilogue so the body always terminates. */
    if (ok && !saw_return) {
      if (!LcCg_EmitHelperCall3(&buf, "Rt_PrepReturn", 0, 0, 0, /*reload*/0) ||
          !LcCg_EmitEpilogue(&buf)) {
        ok = 0;
      }
    }

    if (!ok) { LcCodeBuf_Free(&buf); lc_codemodule_free(cm); return NULL; }

    /* Take ownership of the buffer's bytes + relocs (do NOT LcCodeBuf_Free). */
    cf->code      = buf.bytes;
    cf->code_len  = buf.used;
    cf->relocs    = buf.relocs;
    cf->nrelocs   = buf.nrelocs;
    cf->unwind    = NULL;     /* M0 epsilon: deferred to the pcall/.pdata plan */
    cf->unwind_len = 0;
    snprintf(cf->name, sizeof(cf->name), "luac_fn_%u", (unsigned)i);

    /* Null out the moved-from buffer so a stray free can't double-free. */
    buf.bytes = NULL; buf.relocs = NULL;
    buf.used = buf.cap = 0; buf.nrelocs = buf.relocap = 0;
  }

  return cm;
}

void lc_codemodule_free(LcCodeModule *cm) {
  if (!cm) return;
  if (cm->funcs) {
    for (uint32_t i = 0; i < cm->nfuncs; i++) {
      free(cm->funcs[i].code);
      free(cm->funcs[i].relocs);
      free(cm->funcs[i].unwind);
    }
    free(cm->funcs);
  }
  free(cm->rodata);
  free(cm);
}
