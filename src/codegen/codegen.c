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
#include "lopcodes.h"      /* OP_* opcodes for the M0 bc_op dispatch */

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

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
#define LC_OFF_PROTO_CODE ( ( int32_t )offsetof( Proto, code ) ) /* Proto.code  */

/* ci->u.l.savedpc: the program-counter snapshot luaG_getfuncline reads to map
   an error site to a source line (LUAC-001). v1 bakes &P->code[pc+1] absolute;
   AOT recovers P->code at runtime (same chain as LOADK) and stores
   P->code + (pc+1) so pcRel(savedpc,P) == pc. */
#define LC_OFF_CI_SAVEDPC ( ( int32_t )offsetof( CallInfo, u.l.savedpc ) )

/* -O level, set by lc_codegen from m->opt_level. 0 = faithful boxed baseline;
   >=1 enables the M1 typed fastpaths (arith/compare). */
static int g_lc_opt_level = 0;

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
/* Branch infrastructure — port of v1 BranchCtx, keyed by bc_pc.       */
/*                                                                      */
/* M0 lays the function out linearly in bytecode order (no CFG). Each   */
/* instruction's first emitted byte offset is recorded in PcOff[bc_pc]  */
/* (parallel Seen[] flags whether it has been emitted yet). Branch ops  */
/* emit a rel32 placeholder; backward targets (already emitted) patch   */
/* immediately, forward targets defer onto Fwd[] and resolve after the  */
/* instruction loop. This mirrors src/jit/codegen.c's BranchCtx exactly */
/* (only the buffer plumbing differs: Slot->LcCodeBuf, EmitX64_->X64Emit_). */
/* ------------------------------------------------------------------ */
typedef struct LcFwdJump {
    size_t patch_site;   /* offset of the disp32 word inside buf.bytes */
    int    target_pc;    /* bc_pc the jump lands on                    */
} LcFwdJump;

typedef struct LcBranchCtx {
    LcCodeBuf *buf;
    size_t    *pc_off;   /* PcOff[bc_pc] = code offset (sized sizecode) */
    uint8_t   *seen;     /* Seen[bc_pc]  = 1 once recorded             */
    int        sizecode;
    LcFwdJump *fwd;
    int        nfwd, capfwd;
} LcBranchCtx;

/* Record bc_pc -> current code offset (call immediately before lowering). */
static void LcBr_RecordPc( LcBranchCtx *Br, int Pc, size_t Offset ) {
    if ( Pc < 0 || Pc >= Br->sizecode ) { return; }
    /* Only record the FIRST emission for a pc (zero-byte no-ops that follow,
       e.g. EXTRAARG, must not overwrite the real instruction's offset; but the
       no-op is emitted at its own pc, so this is moot — kept defensive). */
    Br->pc_off[ Pc ] = Offset;
    Br->seen[ Pc ]   = 1;
}

/* Queue a forward (not-yet-emitted) rel32 patch site. */
static int LcBr_AddFwd( LcBranchCtx *Br, size_t PatchSite, int TargetPc ) {
    if ( Br->nfwd >= Br->capfwd ) {
        int newcap = Br->capfwd ? Br->capfwd * 2 : 32;
        LcFwdJump *grown = ( LcFwdJump * )realloc( Br->fwd,
                                                   ( size_t )newcap * sizeof( LcFwdJump ) );
        if ( !grown ) { return 0; }
        Br->fwd = grown;
        Br->capfwd = newcap;
    }
    Br->fwd[ Br->nfwd ].patch_site = PatchSite;
    Br->fwd[ Br->nfwd ].target_pc  = TargetPc;
    Br->nfwd++;
    return 1;
}

/* Emit a rel32 placeholder of the given flavour and route it: backward targets
   patch now, forward targets defer. `Cc` < 0 => unconditional JMP rel32. */
static int LcBr_EmitBranch( LcBranchCtx *Br, int Cc, int TargetPc, int Pc ) {
    size_t site = ( Cc < 0 )
                ? X64Emit_JmpRel32_Placeholder( Br->buf )
                : X64Emit_JccRel32_Placeholder( Br->buf, ( unsigned )Cc );
    if ( site == ( size_t )-1 ) { return 0; }
    if ( TargetPc < 0 || TargetPc >= Br->sizecode ) { return 0; }
    if ( TargetPc <= Pc && Br->seen[ TargetPc ] ) {
        /* backward target already laid out — patch immediately. */
        return X64Emit_PatchRel32( Br->buf, site, Br->pc_off[ TargetPc ] );
    }
    /* forward (or not-yet-seen) target — defer. */
    return LcBr_AddFwd( Br, site, TargetPc );
}

/* Resolve every deferred forward patch. Call after the instruction loop and
   BEFORE taking ownership of the buffer. */
static int LcBr_Resolve( LcBranchCtx *Br ) {
    int i;
    for ( i = 0; i < Br->nfwd; i++ ) {
        int t = Br->fwd[ i ].target_pc;
        if ( t < 0 || t >= Br->sizecode || !Br->seen[ t ] ) {
            fprintf( stderr, "[-] luac: branch target pc %d never emitted\n", t );
            return 0;
        }
        if ( !X64Emit_PatchRel32( Br->buf, Br->fwd[ i ].patch_site, Br->pc_off[ t ] ) ) {
            fprintf( stderr, "[-] luac: branch to pc %d out of rel32 range\n", t );
            return 0;
        }
    }
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
 *  C2 (Plan 3): dispatch on bc_op so RETURN0/RETURN1 don't read b-1/c (their
 *  bytecode has no B/C meaning) — they would otherwise compute garbage counts.
 *    OP_RETURN0      -> Rt_PrepReturn(L, 0, 0, 0)
 *    OP_RETURN1      -> Rt_PrepReturn(L, A, 1, 0)
 *    OP_RETURN  A B C-> Rt_PrepReturn(L, A, B-1, C)   (B==0 => -1 MULTRET)
 *  And honor the k-flag (in->ret_close): a function that created closures over
 *  its locals MUST close those upvalues (Rt_Close(L,0)) before returning, else
 *  the closures' upvalue refs dangle into freed stack memory. v1 Lower_Return /
 *  Lower_Return0 / Lower_Return1 do exactly this.
 */
static int lower_return( LcCodeBuf *B, LcInst *in ) {
    int A, N, NParams1;

    /* k-flag: close open upvalues before returning (mirrors v1 EmitCall1ArgHelper
       (0, Rt_Close)). Rt_Close runs __close metamethods (arbitrary Lua) and can
       relocate the stack — but we return immediately after Rt_PrepReturn, so the
       only state that must survive is L (RBX, callee-saved). reload after is
       harmless and keeps RDI valid for the PrepReturn that follows. */
    if ( in->ret_close ) {
        if ( !LcCg_EmitHelperCall3( B, "Rt_Close", 0, 0, 0, /*reload*/1 ) ) return 0;
    }

    switch ( in->bc_op ) {
        case OP_RETURN0: A = 0;     N = 0;          NParams1 = 0;      break;
        case OP_RETURN1: A = in->a; N = 1;          NParams1 = 0;      break;
        case OP_RETURN:
        default:         A = in->a; N = in->b - 1;  NParams1 = in->c;  break;
    }
    /* Rt_PrepReturn(L, A, N, NParams1) -> RAX = nresults */
    if ( !LcCg_EmitHelperCall3( B, "Rt_PrepReturn",
                                A, N, NParams1, /*reload*/0 ) ) return 0;
    /* RAX holds the result count; epilogue restores callee-saved regs + RET. */
    return LcCg_EmitEpilogue( B );
}

/*!
 * @brief
 *  LC_OP_TAILCALL (OP_TAILCALL A B C k): return R[A](R[A+1..A+B-1]). Ported from
 *  v1 Lower_TailCall (codegen.c ~1280): if the k-flag is set, close open
 *  upvalues first (Rt_Close(L,0)); then Rt_TailCall(L, A, NArgs) — NArgs =
 *  (B==0)? -1 : (B-1) — which returns the tail-called function's result count in
 *  RAX. v1 then JMPs to the shared epilogue; LuaC inlines the epilogue directly
 *  (RAX survives the epilogue, which only restores callee-saved regs + RET). No
 *  reload: we return immediately. Args decoded by lift into in->a/b; close flag
 *  in in->ret_close.
 */
static int lower_tailcall( LcCodeBuf *B, LcInst *in ) {
    int Bee   = in->b;
    int NArgs = ( Bee == 0 ) ? -1 : ( Bee - 1 );
    if ( in->ret_close ) {
        if ( !LcCg_EmitHelperCall3( B, "Rt_Close", 0, 0, 0, /*reload*/1 ) ) return 0;
    }
    /* Rt_TailCall(L, A, NArgs) -> RAX = nresults */
    if ( !LcCg_EmitHelperCall3( B, "Rt_TailCall", in->a, NArgs, 0, /*reload*/0 ) )
        return 0;
    return LcCg_EmitEpilogue( B );
}

/* ------------------------------------------------------------------ */
/* Plan 1 — inline loads (no helper). Faithful ports of v1's           */
/* Lower_Move/LoadI/LoadF/LoadFalse/LoadTrue/LoadNil onto the          */
/* memory-form path: every Lua register lives at [RDI + N*16] (value), */
/* tag dword at +8.                                                    */
/* ------------------------------------------------------------------ */

/* MOVE A B: 16-byte TValue copy [RDI+B*16] -> [RDI+A*16] (value + tag). */
static int lower_move( LcCodeBuf *B, LcInst *in ) {
    int A = in->a, Bs = in->b;
    /* value half via R10 */
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RDI, Bs * 16 ) )       return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_R10 ) )        return 0;
    /* tag half via R10 */
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RDI, Bs * 16 + 8 ) )   return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16 + 8, X64_R10 ) )    return 0;
    return 1;
}

/* LOADI A sBx: R[A] = sBx (sign-extended integer), tag LUA_VNUMINT. */
static int lower_loadi( LcCodeBuf *B, LcInst *in ) {
    int A = in->a;
    int64_t v = ( int64_t )in->b;   /* sBx carried in `b` */
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, ( uint64_t )v ) )        return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_RAX ) )        return 0;
    if ( !X64Emit_MovImm32ToMem( B, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
    return 1;
}

/* LOADF A sBx: R[A] = (double)sBx (bit pattern), tag LUA_VNUMFLT. */
static int lower_loadf( LcCodeBuf *B, LcInst *in ) {
    int A = in->a;
    double d = ( double )in->b;     /* sBx carried in `b` */
    uint64_t bits = 0;
    memcpy( &bits, &d, 8 );
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, bits ) )                return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_RAX ) )        return 0;
    if ( !X64Emit_MovImm32ToMem( B, X64_RDI, A * 16 + 8, LUA_VNUMFLT ) ) return 0;
    return 1;
}

/* LOADFALSE A: R[A] = false (value 0, tag LUA_VFALSE). */
static int lower_loadfalse( LcCodeBuf *B, LcInst *in ) {
    int A = in->a;
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, 0 ) )                   return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_RAX ) )        return 0;
    if ( !X64Emit_MovImm32ToMem( B, X64_RDI, A * 16 + 8, LUA_VFALSE ) ) return 0;
    return 1;
}

/* LOADTRUE A: R[A] = true (value 0, tag LUA_VTRUE). */
static int lower_loadtrue( LcCodeBuf *B, LcInst *in ) {
    int A = in->a;
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, 0 ) )                   return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_RAX ) )        return 0;
    if ( !X64Emit_MovImm32ToMem( B, X64_RDI, A * 16 + 8, LUA_VTRUE ) ) return 0;
    return 1;
}

/* LOADNIL A B: R[A..A+B] = nil (tag LUA_VNIL). */
static int lower_loadnil( LcCodeBuf *B, LcInst *in ) {
    int A = in->a, n = in->b, i;
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, 0 ) )                   return 0;
    for ( i = 0; i <= n; i++ ) {
        if ( !X64Emit_MovRegToMem( B, X64_RDI, ( A + i ) * 16, X64_RAX ) )       return 0;
        if ( !X64Emit_MovImm32ToMem( B, X64_RDI, ( A + i ) * 16 + 8, LUA_VNIL ) ) return 0;
    }
    return 1;
}

/* LFALSESKIP A: R[A] = false; then skip the next instruction (the paired
   LOADTRUE). M0: write false, then unconditional jump to bc_pc+2. The skipped
   instruction still gets its own pc->offset entry and emits its own code; we
   just branch over it. */
static int lower_lfalseskip( LcBranchCtx *Br, LcInst *in ) {
    int A = in->a;
    if ( !X64Emit_MovImm64ToReg( Br->buf, X64_RAX, 0 ) )                   return 0;
    if ( !X64Emit_MovRegToMem( Br->buf, X64_RDI, A * 16, X64_RAX ) )       return 0;
    if ( !X64Emit_MovImm32ToMem( Br->buf, X64_RDI, A * 16 + 8, LUA_VFALSE ) ) return 0;
    /* skip next instruction: unconditional jump to bc_pc + 2 */
    return LcBr_EmitBranch( Br, -1, in->bc_pc + 2, in->bc_pc );
}

/* LOADKX A (fused EXTRAARG): R[A] = K[Ax]. Like lower_const but the const index
   (Ax) is carried in `b` and recovered from the runtime Proto via ci. */
static int lower_loadkx( LcCodeBuf *B, LcInst *in ) {
    int A  = in->a;
    int Ax = in->b;
    int32_t kdisp = ( int32_t )( Ax * 16 );
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RBX, LC_OFF_CI ) )       return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_CI_FUNC ) )  return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, 0 ) )              return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_LCL_P ) )    return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_PROTO_K ) )  return 0;
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RAX, kdisp ) )           return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_R10 ) )          return 0;
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RAX, kdisp + 8 ) )       return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16 + 8, X64_R10 ) )      return 0;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Plan 1 — comparisons + conditional branch.                          */
/*                                                                      */
/* M0 protocol: call the complete comparison helper (returns 0/1 in     */
/* RAX), then branch: `jne` to bc_pc+2 (skip the following JMP) when     */
/* result != k. The paired JMP lowers independently as an unconditional */
/* jump to its resolved target.                                         */
/*                                                                      */
/* A comparison helper can run __eq/__lt/__le — arbitrary Lua that may   */
/* relocate the Lua stack — so RDI must be reloaded before the branch    */
/* (both successors assume the function-wide RDI invariant). But the     */
/* reload (LcCg_EmitReloadRdiAndCache) CLOBBERS RAX. So, exactly like v1 */
/* EmitCompareSlowReloadAndBranch: stash the 0/1 result in R11D, reload  */
/* RDI, then `cmp r11d, k; jne`. R11 is volatile and untouched by the    */
/* reload sequence.                                                     */
/* ------------------------------------------------------------------ */
/* cmp rax, [rdi+disp]  (48 3B /r, reg=RAX=0, rm=RDI=7). */
static int emit_cmp_rax_mem( LcCodeBuf *B, int32_t disp ) {
    uint8_t b[8]; int n = 0;
    b[n++] = 0x48; b[n++] = 0x3B;
    if ( disp == 0 ) { b[n++] = ( uint8_t )( ( 0 << 6 ) | ( 0 << 3 ) | 7 ); }
    else if ( disp >= -128 && disp <= 127 ) {
        b[n++] = ( uint8_t )( ( 1 << 6 ) | ( 0 << 3 ) | 7 ); b[n++] = ( uint8_t )( int8_t )disp;
    } else {
        b[n++] = ( uint8_t )( ( 2 << 6 ) | ( 0 << 3 ) | 7 );
        b[n++] = ( uint8_t )( disp & 0xFF ); b[n++] = ( uint8_t )( ( disp >> 8 ) & 0xFF );
        b[n++] = ( uint8_t )( ( disp >> 16 ) & 0xFF ); b[n++] = ( uint8_t )( ( disp >> 24 ) & 0xFF );
    }
    return LcCodeBuf_Append( B, b, ( size_t )n );
}
/* cmp rax, imm32 (sign-extended to 64): 48 3D id. */
static int emit_cmp_rax_imm32( LcCodeBuf *B, int32_t imm ) {
    uint8_t b[6] = { 0x48, 0x3D, ( uint8_t )( imm & 0xFF ), ( uint8_t )( ( imm >> 8 ) & 0xFF ),
                     ( uint8_t )( ( imm >> 16 ) & 0xFF ), ( uint8_t )( ( imm >> 24 ) & 0xFF ) };
    return LcCodeBuf_Append( B, b, 6 );
}
/* set<cc> al ; movzx r11d, al  -> r11d = 0/1. cc = low nibble of the 0F 9x setcc. */
static int emit_setcc_movzx_r11( LcCodeBuf *B, unsigned cc ) {
    uint8_t s[3] = { 0x0F, ( uint8_t )( 0x90 | ( cc & 0xF ) ), 0xC0 };  /* setcc al */
    uint8_t m[4] = { 0x44, 0x0F, 0xB6, 0xD8 };                          /* movzx r11d, al */
    if ( !LcCodeBuf_Append( B, s, 3 ) ) return 0;
    return LcCodeBuf_Append( B, m, 4 );
}
/* setcc condition (low nibble) for a comparison op, or -1 if not int-fastpathable.
   *is_regreg set when the right operand is a register (else a signed immediate). */
static int cmp_setcc( int bc_op, int *is_regreg ) {
    *is_regreg = 0;
    switch ( bc_op ) {
        case OP_EQ:  *is_regreg = 1; return 0x4; /* sete  */
        case OP_LT:  *is_regreg = 1; return 0xC; /* setl  */
        case OP_LE:  *is_regreg = 1; return 0xE; /* setle */
        case OP_EQI: return 0x4;  /* sete  (R[A] == sB)  */
        case OP_LTI: return 0xC;  /* setl  (R[A] <  sB)  */
        case OP_LEI: return 0xE;  /* setle (R[A] <= sB)  */
        case OP_GTI: return 0xF;  /* setg  (R[A] >  sB)  */
        case OP_GEI: return 0xD;  /* setge (R[A] >= sB)  */
        default: return -1;
    }
}

/* `harg2` is the value passed as the slow helper's second argument: in->b for
   the reg-reg/EQK/EQI helpers, or the comparison's own raw instruction word
   for Rt_OrderISlow (LTI/LEI/GTI/GEI), which needs the sB immediate plus the
   float-immediate flag in C to type a metamethod operand correctly. The
   inline fastpath always compares against in->b (the sB immediate). */
static int lower_cmp( LcBranchCtx *Br, LcInst *in, const char *Helper, int harg2 ) {
    LcCodeBuf *B = Br->buf;
    int A = in->a, Bop = in->b, K = in->c;
    int is_regreg, cc;

    /* --- M1 (-O1+): inline integer comparison fastpath, helper fallback. ---
       Sound: only when the operand tags are LUA_VNUMINT does the inline path run
       (exact integer compare, no NaN concerns); float/string/table/__eq/__lt fall
       to the complete helper. EQK (reg-vs-constant) keeps the helper. */
    cc = g_lc_opt_level >= 1 ? cmp_setcc( in->bc_op, &is_regreg ) : -1;
    if ( cc >= 0 ) {
        size_t jneA, jneB = 0, jmp_fast, slow, cmpk;

        /* M1 elision: operand(s) PROVEN integer -> inline compare with no
           tag-check, no helper. op1 = R[A]; op2 = R[B] (reg-reg) or the signed
           immediate (the *I forms, statically integer). */
        int op1_int = ( in->known & LC_KNOWN_B_INT ) != 0;
        int op2_int = is_regreg ? ( ( in->known & LC_KNOWN_C_INT ) != 0 ) : 1;
        if ( op1_int && op2_int ) {
            if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RDI, A * 16 ) ) return 0;
            if ( is_regreg ) { if ( !emit_cmp_rax_mem( B, Bop * 16 ) ) return 0; }
            else             { if ( !emit_cmp_rax_imm32( B, Bop ) ) return 0; }
            if ( !emit_setcc_movzx_r11( B, ( unsigned )cc ) ) return 0;
            { unsigned char C[ 4 ] = { 0x41, 0x83, 0xFB, ( unsigned char )( int8_t )K };
              if ( !LcCodeBuf_Append( B, C, 4 ) ) return 0; }   /* cmp r11d, K */
            return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->bc_pc + 2, in->bc_pc );
        }

        if ( !X64Emit_CmpMem8Imm8( B, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
        if ( !X64Emit_JneRel8( B, 0 ) ) return 0; jneA = B->used - 1;
        if ( is_regreg ) {
            if ( !X64Emit_CmpMem8Imm8( B, X64_RDI, Bop * 16 + 8, LUA_VNUMINT ) ) return 0;
            if ( !X64Emit_JneRel8( B, 0 ) ) return 0; jneB = B->used - 1;
        }
        if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RDI, A * 16 ) ) return 0;
        if ( is_regreg ) { if ( !emit_cmp_rax_mem( B, Bop * 16 ) ) return 0; }
        else             { if ( !emit_cmp_rax_imm32( B, Bop ) ) return 0; }
        if ( !emit_setcc_movzx_r11( B, ( unsigned )cc ) ) return 0;   /* r11d = 0/1 */
        jmp_fast = X64Emit_JmpRel32_Placeholder( B );
        if ( jmp_fast == ( size_t )-1 ) return 0;
        /* slow: */
        slow = B->used;
        if ( !X64Emit_PatchRel8( B, jneA, slow ) ) return 0;
        if ( is_regreg && !X64Emit_PatchRel8( B, jneB, slow ) ) return 0;
        if ( !LcCg_EmitHelperCall3( B, Helper, A, harg2, 0, /*reload*/0 ) ) return 0;
        { unsigned char S[ 3 ] = { 0x41, 0x89, 0xC3 };           /* mov r11d, eax */
          if ( !LcCodeBuf_Append( B, S, 3 ) ) return 0; }
        if ( !LcCg_EmitReloadRdiAndCache( B ) ) return 0;
        /* cmpk: */
        cmpk = B->used;
        if ( !X64Emit_PatchRel32( B, jmp_fast, cmpk ) ) return 0;
        { unsigned char C[ 4 ] = { 0x41, 0x83, 0xFB, ( unsigned char )( int8_t )K };
          if ( !LcCodeBuf_Append( B, C, 4 ) ) return 0; }   /* cmp r11d, K */
        return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->bc_pc + 2, in->bc_pc );
    }

    /* --- M0 baseline: complete helper -> RAX 0/1, then branch. --- */
    if ( !LcCg_EmitHelperCall3( B, Helper, A, harg2, 0, /*reload*/0 ) ) return 0;
    { unsigned char S[ 3 ] = { 0x41, 0x89, 0xC3 };
      if ( !LcCodeBuf_Append( B, S, 3 ) ) return 0; }
    if ( !LcCg_EmitReloadRdiAndCache( B ) ) return 0;
    { unsigned char C[ 4 ] = { 0x41, 0x83, 0xFB, ( unsigned char )( int8_t )K };
      if ( !LcCodeBuf_Append( B, C, 4 ) ) return 0; }
    return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->bc_pc + 2, in->bc_pc );
}

/* ------------------------------------------------------------------ */
/* Plan 1 — TEST / TESTSET (truthiness branch).                        */
/*                                                                      */
/* Truthiness check ported from v1 EmitIsTruthyEax: falsy iff tag is    */
/* LUA_VNIL or LUA_VFALSE. Result 0/1 in EAX, then `cmp eax,k; jne      */
/* bc_pc+2`. TESTSET copies R[B]->R[A] on the fall-through (truthy==k). */
/* The paired JMP lowers independently.                                */
/* ------------------------------------------------------------------ */
static int emit_is_truthy_eax( LcCodeBuf *B, int RegSlot ) {
    /* mov eax, 1 */
    unsigned char MovEax1[ 5 ] = { 0xB8, 0x01, 0x00, 0x00, 0x00 };
    if ( !LcCodeBuf_Append( B, MovEax1, 5 ) ) return 0;
    /* cmp byte [rdi + RegSlot*16 + 8], LUA_VNIL */
    if ( !X64Emit_CmpMem8Imm8( B, X64_RDI, RegSlot * 16 + 8, LUA_VNIL ) ) return 0;
    /* je .set_falsy (rel8 placeholder) */
    unsigned char JeBytes[ 2 ] = { 0x74, 0x00 };
    if ( !LcCodeBuf_Append( B, JeBytes, 2 ) ) return 0;
    size_t JeNilPatch = B->used - 1;
    /* cmp byte [rdi + RegSlot*16 + 8], LUA_VFALSE */
    if ( !X64Emit_CmpMem8Imm8( B, X64_RDI, RegSlot * 16 + 8, LUA_VFALSE ) ) return 0;
    /* jne .done (rel8 placeholder) */
    if ( !X64Emit_JneRel8( B, 0 ) ) return 0;
    size_t JneFalsePatch = B->used - 1;
    /* .set_falsy: mov eax, 0 */
    size_t SetFalsyStart = B->used;
    unsigned char MovEax0[ 5 ] = { 0xB8, 0x00, 0x00, 0x00, 0x00 };
    if ( !LcCodeBuf_Append( B, MovEax0, 5 ) ) return 0;
    /* .done: */
    size_t DoneOff = B->used;
    if ( !X64Emit_PatchRel8( B, JeNilPatch,    SetFalsyStart ) ) return 0;
    if ( !X64Emit_PatchRel8( B, JneFalsePatch, DoneOff       ) ) return 0;
    return 1;
}

static int lower_test( LcBranchCtx *Br, LcInst *in ) {
    int A = in->a, K = in->c;
    if ( !emit_is_truthy_eax( Br->buf, A ) ) return 0;
    if ( !X64Emit_CmpEaxImm8( Br->buf, ( int8_t )K ) ) return 0;
    /* jne -> bc_pc+2 (skip the trailing JMP when truthy != k) */
    return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->bc_pc + 2, in->bc_pc );
}

static int lower_testset( LcBranchCtx *Br, LcInst *in ) {
    int A = in->a, Bs = in->b, K = in->c;
    LcCodeBuf *B = Br->buf;
    if ( !emit_is_truthy_eax( B, Bs ) ) return 0;
    if ( !X64Emit_CmpEaxImm8( B, ( int8_t )K ) ) return 0;
    /* jne .done — when truthy != k, skip the copy AND skip the trailing JMP
       (i.e. branch to bc_pc+2). When truthy == k, fall through: copy then let
       the independent JMP execute. */
    if ( !LcBr_EmitBranch( Br, 0x5 /* JNE */, in->bc_pc + 2, in->bc_pc ) ) return 0;
    /* fall-through (truthy == k): copy R[B] -> R[A] (value + tag). */
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RDI, Bs * 16 ) )     return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_R10 ) )      return 0;
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RDI, Bs * 16 + 8 ) ) return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16 + 8, X64_R10 ) )  return 0;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Plan 1 — numeric for (FORPREP/FORLOOP).                             */
/*                                                                      */
/* Rt_ForPrep(L,A)/Rt_ForLoop(L,A) return a skip/continue flag in RAX.  */
/* FORPREP: `test eax,eax; jne target` (skip loop body if RAX != 0).    */
/* FORLOOP: `test eax,eax; jne target` (loop back if RAX != 0).         */
/* The resolved target pc is carried in in->c by the lift. These        */
/* helpers do plain arithmetic on stack slots (no metamethod, no        */
/* allocation), so RDI stays valid — and reload would clobber RAX,      */
/* which the `test` needs. So: reload_after = 0.                        */
/* ------------------------------------------------------------------ */
static int lower_forprep( LcBranchCtx *Br, LcInst *in ) {
    if ( !LcCg_EmitHelperCall3( Br->buf, "Rt_ForPrep", in->a, 0, 0, /*reload*/0 ) ) return 0;
    if ( !X64Emit_TestEaxEax( Br->buf ) ) return 0;
    return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->c, in->bc_pc );
}

static int lower_forloop( LcBranchCtx *Br, LcInst *in ) {
    LcCodeBuf *B = Br->buf;
    int    A = in->a;
    size_t jne_slow, jz_exit, slow, ex;

    if ( g_lc_opt_level < 1 ) {                     /* -O0: faithful helper path */
        if ( !LcCg_EmitHelperCall3( B, "Rt_ForLoop", A, 0, 0, /*reload*/0 ) ) return 0;
        if ( !X64Emit_TestEaxEax( B ) ) return 0;
        return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->c, in->bc_pc );
    }

    /* -O1: inline the integer-loop fast path (mirrors lvm.c OP_FORLOOP integer
       case), runtime-checked on the step tag; float/other loops fall to the
       complete Rt_ForLoop helper. Removes the per-iteration call -- a win even
       over v1, which always calls the helper. Slots: R[A]=internal index,
       R[A+1]=remaining count, R[A+2]=step, R[A+3]=control variable. */
    if ( !X64Emit_CmpMem8Imm8( B, X64_RDI, ( A + 2 ) * 16 + 8, LUA_VNUMINT ) ) return 0;
    jne_slow = X64Emit_JccRel32_Placeholder( B, 0x5 /* JNE -> slow */ );
    if ( jne_slow == ( size_t )-1 ) return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RDI, ( A + 1 ) * 16 ) ) return 0;  /* count */
    { unsigned char t[ 3 ] = { 0x48, 0x85, 0xC0 };                /* test rax, rax */
      if ( !LcCodeBuf_Append( B, t, 3 ) ) return 0; }
    jz_exit = X64Emit_JccRel32_Placeholder( B, 0x4 /* JZ -> exit (count==0) */ );
    if ( jz_exit == ( size_t )-1 ) return 0;
    { unsigned char d[ 3 ] = { 0x48, 0xFF, 0xC8 };                /* dec rax */
      if ( !LcCodeBuf_Append( B, d, 3 ) ) return 0; }
    if ( !X64Emit_MovRegToMem( B, X64_RDI, ( A + 1 ) * 16, X64_RAX ) ) return 0;  /* count-1 */
    if ( !X64Emit_MovMemToReg( B, X64_RCX, X64_RDI, ( A + 2 ) * 16 ) ) return 0;  /* step */
    if ( !X64Emit_MovMemToReg( B, X64_RDX, X64_RDI, A * 16 ) ) return 0;          /* idx */
    { unsigned char a[ 3 ] = { 0x48, 0x01, 0xCA };                /* add rdx, rcx (wrap) */
      if ( !LcCodeBuf_Append( B, a, 3 ) ) return 0; }
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_RDX ) ) return 0;          /* R[A]=idx */
    if ( !X64Emit_MovRegToMem( B, X64_RDI, ( A + 3 ) * 16, X64_RDX ) ) return 0;  /* R[A+3]=idx */
    if ( !X64Emit_MovImm32ToMem( B, X64_RDI, ( A + 3 ) * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !LcBr_EmitBranch( Br, -1 /* JMP */, in->c, in->bc_pc ) ) return 0;       /* back-edge */

    slow = B->used;                                  /* float / other -> helper */
    if ( !X64Emit_PatchRel32( B, jne_slow, slow ) ) return 0;
    if ( !LcCg_EmitHelperCall3( B, "Rt_ForLoop", A, 0, 0, /*reload*/0 ) ) return 0;
    if ( !X64Emit_TestEaxEax( B ) ) return 0;
    if ( !LcBr_EmitBranch( Br, 0x5 /* JNE */, in->c, in->bc_pc ) ) return 0;

    ex = B->used;                                    /* count==0 falls here (done) */
    if ( !X64Emit_PatchRel32( B, jz_exit, ex ) ) return 0;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Plan 3 — closures, upvalues, vararg-consume, generic-for, tbc.      */
/*                                                                      */
/* Faithful AOT ports of v1 Lower_Closure/GetUpval/SetUpval/Vararg/     */
/* TForPrep/TForCall/TForLoop/Tbc/Close (src/jit/codegen.c). Operands   */
/* come from in->a/b/c decoded by lift.c; the generic-for branch        */
/* targets are pre-resolved into in->c.                                 */
/* ------------------------------------------------------------------ */

/* CLOSURE A Bx: R[A] = new LClosure from P->p[Bx], upvalues bound.
   Rt_NewClosure ends with luaC_checkGC which may relocate the stack -> reload. */
static int lower_closure( LcCodeBuf *B, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_NewClosure", in->a, in->b, 0, /*reload*/1 );
}

/* GETUPVAL A B: R[A] = UpValue[B]. Pure setobj2s copy — no alloc, no metamethod,
   so RDI stays valid (v1 only resyncs cache regs, a no-op here). reload=0. */
static int lower_getupval( LcCodeBuf *B, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_GetUpval", in->a, in->b, 0, /*reload*/0 );
}

/* SETUPVAL A B: UpValue[B] = R[A] (+ GC write-barrier). No stack relocation.
   reload=0 (matches v1 Lower_SetUpval — no reload at all). */
static int lower_setupval( LcCodeBuf *B, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_SetUpval", in->a, in->b, 0, /*reload*/0 );
}

/* VARARG A C: copy varargs to R[A..]. NRequired = (C==0)? -1 : (C-1). The C is
   carried in in->b by the lift. Rt_Vararg's MULTRET path runs checkstackGCp ->
   may grow the stack -> reload. */
static int lower_vararg_consume( LcCodeBuf *B, LcInst *in ) {
    int C         = in->b;
    int NRequired = ( C == 0 ) ? -1 : ( C - 1 );
    return LcCg_EmitHelperCall3( B, "Rt_Vararg", in->a, NRequired, 0, /*reload*/1 );
}

/* TBC A: mark R[A] to-be-closed. Rt_Tbc allocates a tbc UpVal -> reload. */
static int lower_tbc( LcCodeBuf *B, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_Tbc", in->a, 0, 0, /*reload*/1 );
}

/* CLOSE A: close upvalues >= R[A]. Rt_Close runs __close (arbitrary Lua) and may
   relocate the stack -> reload. */
static int lower_close( LcCodeBuf *B, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_Close", in->a, 0, 0, /*reload*/1 );
}

/* TFORPREP A Bx: make tbc upval for R[A+3], then unconditionally jump forward to
   the TFORCALL (resolved into in->c by the lift). Rt_TForPrep allocates an UpVal
   -> reload. */
static int lower_tforprep( LcBranchCtx *Br, LcInst *in ) {
    if ( !LcCg_EmitHelperCall3( Br->buf, "Rt_TForPrep", in->a, 0, 0, /*reload*/1 ) )
        return 0;
    return LcBr_EmitBranch( Br, -1 /* uncond JMP */, in->c, in->bc_pc );
}

/* TFORCALL A C: invoke the iterator R[A](R[A+1],R[A+2]); results -> R[A+4..].
   Rt_TForCall calls the iterator via luaD_call -> may grow the stack -> reload.
   The C is carried in in->b by the lift. */
static int lower_tforcall( LcCodeBuf *B, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_TForCall", in->a, in->b, 0, /*reload*/1 );
}

/* TFORLOOP A Bx: if the iterator returned non-nil, set the control var and loop
   back to the body (target resolved into in->c). Rt_TForLoop is a single ttisnil
   check + setobjs2s copy — no metamethod, no allocation, no stack relocation —
   so RDI stays valid and we must NOT reload (the reload sequence clobbers RAX,
   which the `test eax,eax` below needs). Mirrors v1 (which only resyncs cache
   regs, a no-op here) and the Plan-1 lower_forloop RAX-clobber handling. */
static int lower_tforloop( LcBranchCtx *Br, LcInst *in ) {
    if ( !LcCg_EmitHelperCall3( Br->buf, "Rt_TForLoop", in->a, 0, 0, /*reload*/0 ) )
        return 0;
    if ( !X64Emit_TestEaxEax( Br->buf ) ) return 0;
    return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->c, in->bc_pc );
}

/* ------------------------------------------------------------------ */
/* Plan 1 dispatch on the originating Lua opcode (in->bc_op).          */
/* ------------------------------------------------------------------ */

/* Helper-backed dynamic ops: emit Helper(L, A, B, C) with optional reload. */
static int lower_helper3( LcCodeBuf *B, LcInst *in, const char *Sym, int reload ) {
    return LcCg_EmitHelperCall3( B, Sym, in->a, in->b, in->c, reload );
}

typedef enum { LC_AR_ADD, LC_AR_SUB, LC_AR_MUL,
               LC_AR_AND, LC_AR_OR, LC_AR_XOR } LcArOp;

/* rax <op>= [RDI + disp]. ADD via X64Emit_AddMemToReg; the rest by raw bytes
   (REX.W + opcode, reg=RAX=0, rm=RDI=7). Ports v1 EmitArithRax + the bitwise ops.
   SUB 2B, IMUL 0F AF, AND 23, OR 0B, XOR 33. */
static int emit_arith_rax_mem( LcCodeBuf *B, LcArOp op, int32_t disp ) {
    uint8_t b[8]; int n = 0;
    if ( op == LC_AR_ADD ) return X64Emit_AddMemToReg( B, X64_RAX, X64_RDI, disp );
    b[n++] = 0x48;                                   /* REX.W */
    switch ( op ) {
        case LC_AR_SUB: b[n++] = 0x2B; break;
        case LC_AR_MUL: b[n++] = 0x0F; b[n++] = 0xAF; break;  /* imul r64, r/m64 */
        case LC_AR_AND: b[n++] = 0x23; break;
        case LC_AR_OR:  b[n++] = 0x0B; break;
        case LC_AR_XOR: b[n++] = 0x33; break;
        default: return 0;
    }
    if ( disp == 0 ) {
        b[n++] = ( uint8_t )( ( 0 << 6 ) | ( 0 << 3 ) | 7 );
    } else if ( disp >= -128 && disp <= 127 ) {
        b[n++] = ( uint8_t )( ( 1 << 6 ) | ( 0 << 3 ) | 7 );
        b[n++] = ( uint8_t )( int8_t )disp;
    } else {
        b[n++] = ( uint8_t )( ( 2 << 6 ) | ( 0 << 3 ) | 7 );
        b[n++] = ( uint8_t )( disp & 0xFF );
        b[n++] = ( uint8_t )( ( disp >> 8 ) & 0xFF );
        b[n++] = ( uint8_t )( ( disp >> 16 ) & 0xFF );
        b[n++] = ( uint8_t )( ( disp >> 24 ) & 0xFF );
    }
    return LcCodeBuf_Append( B, b, ( size_t )n );
}

/*!
 * @brief
 *  M1 (-O1+): runtime-checked int/float arithmetic fastpath for ADD/SUB/MUL,
 *  with the complete Rt_*Op helper as the fallback. ALWAYS correct — it
 *  dynamically dispatches on the operand tags, so only genuine int+int or
 *  float+float take the inline path (which replicates 5.4 wrapping/IEEE
 *  semantics exactly); mixed/string/table operands fall to the helper
 *  (luaO_arith). This is a pure speedup over the always-boxed M0 path, with no
 *  static type proof required. Ports v1 EmitBinArith (memory-form: M0 keeps
 *  every Lua register at [RDI+N*16], no RegAlloc cache). a/b/c = A/B/C regs.
 */
static int lower_arith_fast( LcCodeBuf *Bb, LcInst *in, LcArOp op,
                             const char *slow_sym, int has_float ) {
    int    A = in->a, Br = in->b, Cr = in->c;
    size_t jne_fB = 0, jne_fC = 0, jmp_df = 0, jne_iB, jne_iC, jmp_di, int_check, slow, done;
    int    ok;

    /* M1 type-inference elision: both operands PROVEN integer (lc_pass_local_
       typeinfer) -> emit the bare integer op with no tag-check, no float arm, no
       helper. Sound iff the proof is sound (no runtime guard, per PROMPT §9). */
    if ( ( in->known & LC_KNOWN_B_INT ) && ( in->known & LC_KNOWN_C_INT ) ) {
        if ( !X64Emit_MovMemToReg( Bb, X64_RAX, X64_RDI, Br * 16 ) ) return 0;
        if ( !emit_arith_rax_mem( Bb, op, Cr * 16 ) ) return 0;
        if ( !X64Emit_MovRegToMem( Bb, X64_RDI, A * 16, X64_RAX ) ) return 0;
        if ( !X64Emit_MovImm32ToMem( Bb, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
        return 1;
    }

    /* M1 float elision: both operands PROVEN float -> bare SSE op, no tag-check,
       no helper. has_float gates it to ADD/SUB/MUL (never bitwise). Sound: float
       arith carries no metamethod, so two proven floats always yield a float. */
    if ( has_float && ( in->known & LC_KNOWN_B_FLT ) && ( in->known & LC_KNOWN_C_FLT ) ) {
        if ( !X64Emit_MovsdMemToXmm0( Bb, X64_RDI, Br * 16 ) ) return 0;
        ok = ( op == LC_AR_ADD ) ? X64Emit_AddsdMemToXmm0( Bb, X64_RDI, Cr * 16 )
           : ( op == LC_AR_SUB ) ? X64Emit_SubsdMemToXmm0( Bb, X64_RDI, Cr * 16 )
                                 : X64Emit_MulsdMemToXmm0( Bb, X64_RDI, Cr * 16 );
        if ( !ok ) return 0;
        if ( !X64Emit_MovsdXmm0ToMem( Bb, X64_RDI, A * 16 ) ) return 0;
        if ( !X64Emit_MovImm32ToMem( Bb, X64_RDI, A * 16 + 8, LUA_VNUMFLT ) ) return 0;
        return 1;
    }

    /* --- float fast path: both operands LUA_VNUMFLT (ADD/SUB/MUL only) --- */
    if ( has_float ) {
        if ( !X64Emit_CmpMem8Imm8( Bb, X64_RDI, Br * 16 + 8, LUA_VNUMFLT ) ) return 0;
        if ( !X64Emit_JneRel8( Bb, 0 ) ) return 0; jne_fB = Bb->used - 1;
        if ( !X64Emit_CmpMem8Imm8( Bb, X64_RDI, Cr * 16 + 8, LUA_VNUMFLT ) ) return 0;
        if ( !X64Emit_JneRel8( Bb, 0 ) ) return 0; jne_fC = Bb->used - 1;
        if ( !X64Emit_MovsdMemToXmm0( Bb, X64_RDI, Br * 16 ) ) return 0;
        ok = ( op == LC_AR_ADD ) ? X64Emit_AddsdMemToXmm0( Bb, X64_RDI, Cr * 16 )
           : ( op == LC_AR_SUB ) ? X64Emit_SubsdMemToXmm0( Bb, X64_RDI, Cr * 16 )
                                 : X64Emit_MulsdMemToXmm0( Bb, X64_RDI, Cr * 16 );
        if ( !ok ) return 0;
        if ( !X64Emit_MovsdXmm0ToMem( Bb, X64_RDI, A * 16 ) ) return 0;
        if ( !X64Emit_MovImm32ToMem( Bb, X64_RDI, A * 16 + 8, LUA_VNUMFLT ) ) return 0;
        jmp_df = X64Emit_JmpRel32_Placeholder( Bb );
        if ( jmp_df == ( size_t )-1 ) return 0;
        /* int_check: float JNEs land here */
        int_check = Bb->used;
        if ( !X64Emit_PatchRel8( Bb, jne_fB, int_check ) ) return 0;
        if ( !X64Emit_PatchRel8( Bb, jne_fC, int_check ) ) return 0;
    }

    /* --- int fast path: both operands LUA_VNUMINT --- */
    if ( !X64Emit_CmpMem8Imm8( Bb, X64_RDI, Br * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !X64Emit_JneRel8( Bb, 0 ) ) return 0; jne_iB = Bb->used - 1;
    if ( !X64Emit_CmpMem8Imm8( Bb, X64_RDI, Cr * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !X64Emit_JneRel8( Bb, 0 ) ) return 0; jne_iC = Bb->used - 1;
    if ( !X64Emit_MovMemToReg( Bb, X64_RAX, X64_RDI, Br * 16 ) ) return 0;
    if ( !emit_arith_rax_mem( Bb, op, Cr * 16 ) ) return 0;
    if ( !X64Emit_MovRegToMem( Bb, X64_RDI, A * 16, X64_RAX ) ) return 0;
    if ( !X64Emit_MovImm32ToMem( Bb, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
    jmp_di = X64Emit_JmpRel32_Placeholder( Bb );
    if ( jmp_di == ( size_t )-1 ) return 0;

    /* slow: int JNEs land here -> the complete helper (handles mixed/string/TM) */
    slow = Bb->used;
    if ( !X64Emit_PatchRel8( Bb, jne_iB, slow ) ) return 0;
    if ( !X64Emit_PatchRel8( Bb, jne_iC, slow ) ) return 0;
    if ( !LcCg_EmitHelperCall3( Bb, slow_sym, A, Br, Cr, /*reload*/1 ) ) return 0;

    /* done: both JMPs land here */
    done = Bb->used;
    if ( has_float && !X64Emit_PatchRel32( Bb, jmp_df, done ) ) return 0;
    if ( !X64Emit_PatchRel32( Bb, jmp_di, done ) ) return 0;
    return 1;
}

/* cmp byte [rdi+disp+8], imm8 already exists (X64Emit_CmpMem8Imm8). Immediate-
   operand arith: rax <op>= imm32. ADD 48 05, SUB 48 2D, IMUL(by imm) 48 69 C0. */
static int emit_arith_rax_imm32( LcCodeBuf *B, LcArOp op, int32_t imm ) {
    uint8_t b[7]; int n = 0;
    b[n++] = 0x48;
    if ( op == LC_AR_ADD ) b[n++] = 0x05;
    else if ( op == LC_AR_SUB ) b[n++] = 0x2D;
    else if ( op == LC_AR_MUL ) { b[n++] = 0x69; b[n++] = 0xC0; }  /* imul rax,rax,imm32 */
    else if ( op == LC_AR_AND ) { b[n++] = 0x25; }
    else if ( op == LC_AR_OR )  { b[n++] = 0x0D; }
    else if ( op == LC_AR_XOR ) { b[n++] = 0x35; }
    else return 0;
    b[n++] = ( uint8_t )( imm & 0xFF );        b[n++] = ( uint8_t )( ( imm >> 8 ) & 0xFF );
    b[n++] = ( uint8_t )( ( imm >> 16 ) & 0xFF ); b[n++] = ( uint8_t )( ( imm >> 24 ) & 0xFF );
    return LcCodeBuf_Append( B, b, ( size_t )n );
}

/*!
 *  M1 (-O1+): integer fastpath for an op whose second operand is a compile-time
 *  immediate (ADDI / ADDK / SUBK / MULK with an int constant). Checks only R[B]'s
 *  tag (the constant is statically int); inline `rax = R[B] <op> imm`, else the
 *  Rt_ArithIK slow path driven by the trailing MMBINI/MMBINK word `mmw` (which
 *  carries the true metamethod event + operand order -- e.g. `x - 1` is
 *  ADDI x,-1 + MMBINI(TM_SUB), and a metatable'd x must get __sub, not __add).
 *  No float arm — a float R[B] falls to the slow path (correct: -> float).
 */
static int lower_arith_imm_fast( LcCodeBuf *Bb, LcInst *in, LcArOp op,
                                 int32_t imm, int mmw ) {
    int    A = in->a, Br = in->b;
    size_t jne_iB, jmp_di, slow, done;

    /* M1 elision: R[B] PROVEN integer -> bare int op with the immediate, no
       tag-check, no helper. */
    if ( in->known & LC_KNOWN_B_INT ) {
        if ( !X64Emit_MovMemToReg( Bb, X64_RAX, X64_RDI, Br * 16 ) ) return 0;
        if ( !emit_arith_rax_imm32( Bb, op, imm ) ) return 0;
        if ( !X64Emit_MovRegToMem( Bb, X64_RDI, A * 16, X64_RAX ) ) return 0;
        if ( !X64Emit_MovImm32ToMem( Bb, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
        return 1;
    }

    if ( !X64Emit_CmpMem8Imm8( Bb, X64_RDI, Br * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !X64Emit_JneRel8( Bb, 0 ) ) return 0; jne_iB = Bb->used - 1;
    if ( !X64Emit_MovMemToReg( Bb, X64_RAX, X64_RDI, Br * 16 ) ) return 0;
    if ( !emit_arith_rax_imm32( Bb, op, imm ) ) return 0;
    if ( !X64Emit_MovRegToMem( Bb, X64_RDI, A * 16, X64_RAX ) ) return 0;
    if ( !X64Emit_MovImm32ToMem( Bb, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
    jmp_di = X64Emit_JmpRel32_Placeholder( Bb );
    if ( jmp_di == ( size_t )-1 ) return 0;
    slow = Bb->used;
    if ( !X64Emit_PatchRel8( Bb, jne_iB, slow ) ) return 0;
    if ( !LcCg_EmitHelperCall3( Bb, "Rt_ArithIK", A, Br, mmw, /*reload*/1 ) ) return 0;
    done = Bb->used;
    if ( !X64Emit_PatchRel32( Bb, jmp_di, done ) ) return 0;
    return 1;
}

/* The trailing OP_MMBINI/OP_MMBINK word for an immediate/K arith op at bc_pc
   (always present: lcode.c finishbinexpval emits it right after the op). */
static int arith_mm_word( LcFunc *f, LcInst *in ) {
    return ( int )( unsigned )f->source->code[ in->bc_pc + 1 ];
}

/* Complete (baseline) lowering for every immediate/K arith op: the Rt_ArithIK
   helper IS the op -- raw arith for numbers/strings, correct metamethod
   (event + operand order from the MMBIN* word) otherwise. */
static int lower_arith_ik( LcCodeBuf *B, LcFunc *f, LcInst *in ) {
    return LcCg_EmitHelperCall3( B, "Rt_ArithIK", in->a, in->b,
                                 arith_mm_word( f, in ), /*reload*/1 );
}

/*!
 * @brief
 *  Dispatch one IR instruction to its lowering, keyed on in->bc_op (the exact
 *  originating Lua opcode). Branch ops use the LcBranchCtx for pc-keyed
 *  placeholder/patch. Ops outside the Plan-1 set should be rejected by the
 *  supported-ops gate before reaching here; we treat any unknown op as an
 *  inert no-op (returns 1) to stay total.
 *
 * @return 1 on success, 0 on emission failure.
 */
/* True for opcodes that can raise a Lua error (directly or via a call/
   metamethod). They need ci->u.l.savedpc current so luaG_getfuncline reports
   the right line. Mirrors v1 src/jit/codegen.c OpcodeNeedsSavedPc. */
static int op_needs_savedpc( int op ) {
    switch ( op ) {
        case OP_MOVE: case OP_LOADI: case OP_LOADF: case OP_LOADK:
        case OP_LOADKX: case OP_LOADFALSE: case OP_LFALSESKIP:
        case OP_LOADTRUE: case OP_LOADNIL: case OP_GETUPVAL:
        case OP_SETUPVAL: case OP_JMP: case OP_TEST: case OP_TESTSET:
        case OP_FORLOOP: case OP_TFORLOOP: case OP_MMBIN: case OP_MMBINI:
        case OP_MMBINK: case OP_EXTRAARG:
            return 0;
        default:
            return 1;
    }
}

/* Store ci->u.l.savedpc = P->code + (pc+1) (LUAC-001). Recovers P->code at
   runtime via ci->func -> closure -> Proto -> code (the chain lower_const uses
   for Proto.k), so pcRel(savedpc, P) == pc and a raised error reports the right
   source:line. Clobbers RAX (= ci) and R11; emitted before each throwing op. */
static int emit_store_savedpc( LcCodeBuf *B, int pc ) {
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RBX, LC_OFF_CI ) )         return 0;
    if ( !X64Emit_MovMemToReg( B, X64_R11, X64_RAX, LC_OFF_CI_FUNC ) )    return 0;
    if ( !X64Emit_MovMemToReg( B, X64_R11, X64_R11, 0 ) )                 return 0;
    if ( !X64Emit_MovMemToReg( B, X64_R11, X64_R11, LC_OFF_LCL_P ) )      return 0;
    if ( !X64Emit_MovMemToReg( B, X64_R11, X64_R11, LC_OFF_PROTO_CODE ) ) return 0;
    if ( !X64Emit_AddRegImm32( B, X64_R11, ( pc + 1 ) * 4 ) )            return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RAX, LC_OFF_CI_SAVEDPC, X64_R11 ) ) return 0;
    return 1;
}

/* If func's constant #idx is an integer in int32 range, store it in *out and
   return 1 (enables the immediate fastpath for ADDK/SUBK/MULK/BANDK/...). The
   imm32 sign-extends to exactly that 64-bit integer, so the inline op matches. */
static int k_int32( LcFunc *f, int idx, int32_t *out ) {
    TValue *k;
    lua_Integer v;
    if ( f == NULL || f->source == NULL || idx < 0 || idx >= f->source->sizek )
        return 0;
    k = &f->source->k[ idx ];
    if ( !ttisinteger( k ) ) return 0;
    v = ivalue( k );
    if ( v < INT32_MIN || v > INT32_MAX ) return 0;
    *out = ( int32_t )v;
    return 1;
}

/* If func's constant #idx is numeric, store its value-as-double bit pattern in
   *out and return 1 (enables the float-K arith elision). An integer K is
   converted with the same C cast the runtime helper applies (cast_num), so the
   inline op is bit-identical to the helper for any proven-float R[B]. NaN K is
   rejected defensively (lcode's constant folding never emits one). */
static int k_flt_bits( LcFunc *f, int idx, uint64_t *out ) {
    TValue *k;
    double d;
    if ( f == NULL || f->source == NULL || idx < 0 || idx >= f->source->sizek )
        return 0;
    k = &f->source->k[ idx ];
    if ( ttisfloat( k ) )        d = fltvalue( k );
    else if ( ttisinteger( k ) ) d = ( double )ivalue( k );
    else return 0;
    if ( d != d ) return 0;
    memcpy( out, &d, 8 );
    return 1;
}

/* M1 elision, float-K arm: R[A] = R[B] <op> K with R[B] PROVEN float and K a
   compile-time numeric constant -> bare SSE op, no tag-check, no helper.
   Sound: float arith on a proven float and a number never dispatches a
   metamethod and always yields a float (DIV included). xmm0 = R[B],
   xmm1 = K bits via rax, then op xmm0,xmm1 keeps operand order exact --
   no commutativity assumptions. */
static int lower_arithk_flt_elide( LcCodeBuf *B, LcInst *in,
                                   unsigned char sse_op, uint64_t kbits ) {
    int A = in->a, Br = in->b;
    if ( !X64Emit_MovsdMemToXmm0( B, X64_RDI, Br * 16 ) ) return 0;
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, kbits ) ) return 0;
    if ( !X64Emit_MovqReg64ToXmmN( B, 1, X64_RAX ) ) return 0;
    if ( !X64Emit_ArithSdXmm0Xmm1( B, sse_op ) ) return 0;
    if ( !X64Emit_MovsdXmm0ToMem( B, X64_RDI, A * 16 ) ) return 0;
    if ( !X64Emit_MovImm32ToMem( B, X64_RDI, A * 16 + 8, LUA_VNUMFLT ) ) return 0;
    return 1;
}

static int lower_inst( LcBranchCtx *Br, LcFunc *f, LcInst *in ) {
    LcCodeBuf *B = Br->buf;
    /* LUAC-001: keep ci->u.l.savedpc current before any throw-capable op so a
       raised error reports the correct source:line (matching the interpreter). */
    if ( op_needs_savedpc( in->bc_op ) && !emit_store_savedpc( B, in->bc_pc ) )
        return 0;
    switch ( in->bc_op ) {
        /* --- epsilon set --- */
        case OP_VARARGPREP:  return lower_vararg( B, in );
        case OP_GETTABUP:    return lower_global_get( B, in );
        case OP_LOADK:       return lower_const( B, in );
        case OP_CALL:        return lower_call( B, in );
        case OP_TAILCALL:    return lower_tailcall( B, in );
        case OP_RETURN:
        case OP_RETURN0:
        case OP_RETURN1:     return lower_return( B, in );

        /* --- inline loads --- */
        case OP_MOVE:        return lower_move( B, in );
        case OP_LOADI:       return lower_loadi( B, in );
        case OP_LOADF:       return lower_loadf( B, in );
        case OP_LOADKX:      return lower_loadkx( B, in );
        case OP_LOADFALSE:   return lower_loadfalse( B, in );
        case OP_LOADTRUE:    return lower_loadtrue( B, in );
        case OP_LOADNIL:     return lower_loadnil( B, in );
        case OP_LFALSESKIP:  return lower_lfalseskip( Br, in );

        /* --- arithmetic: -O1 int/float fastpath (ADD/SUB/MUL) + int-immediate
           fastpath (ADDI / ADDK / SUBK / MULK with an int constant); else the
           complete boxed helper. --- */
        case OP_ADD:   return ( g_lc_opt_level >= 1 )
                           ? lower_arith_fast( B, in, LC_AR_ADD, "Rt_AddOp", 1 )
                           : lower_helper3( B, in, "Rt_AddOp", 1 );
        case OP_SUB:   return ( g_lc_opt_level >= 1 )
                           ? lower_arith_fast( B, in, LC_AR_SUB, "Rt_SubOp", 1 )
                           : lower_helper3( B, in, "Rt_SubOp", 1 );
        case OP_MUL:   return ( g_lc_opt_level >= 1 )
                           ? lower_arith_fast( B, in, LC_AR_MUL, "Rt_MulOp", 1 )
                           : lower_helper3( B, in, "Rt_MulOp", 1 );
        case OP_DIV:   /* M1 elision: both operands PROVEN float -> bare divsd
                          (DIV of two floats is always a float, no metamethod). */
                       if ( g_lc_opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                            && ( in->known & LC_KNOWN_C_FLT ) ) {
                           if ( !X64Emit_MovsdMemToXmm0( B, X64_RDI, in->b * 16 ) ) return 0;
                           if ( !X64Emit_DivsdMemToXmm0( B, X64_RDI, in->c * 16 ) ) return 0;
                           if ( !X64Emit_MovsdXmm0ToMem( B, X64_RDI, in->a * 16 ) ) return 0;
                           if ( !X64Emit_MovImm32ToMem( B, X64_RDI, in->a * 16 + 8, LUA_VNUMFLT ) ) return 0;
                           return 1;
                       }
                       return lower_helper3( B, in, "Rt_DivOp",  1 );
        case OP_MOD:   return lower_helper3( B, in, "Rt_ModOp",  1 );
        case OP_IDIV:  return lower_helper3( B, in, "Rt_IDivOp", 1 );
        case OP_POW:   return lower_helper3( B, in, "Rt_PowOp",  1 );
        case OP_ADDI:  return ( g_lc_opt_level >= 1 )
                           ? lower_arith_imm_fast( B, in, LC_AR_ADD, in->c, arith_mm_word( f, in ) )
                           : lower_arith_ik( B, f, in );
        case OP_ADDK:  { int32_t kv; uint64_t kb;
                         if ( g_lc_opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( B, in, 0x58, kb );
                         if ( g_lc_opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( B, in, LC_AR_ADD, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_SUBK:  { int32_t kv; uint64_t kb;
                         if ( g_lc_opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( B, in, 0x5C, kb );
                         if ( g_lc_opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( B, in, LC_AR_SUB, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_MULK:  { int32_t kv; uint64_t kb;
                         if ( g_lc_opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( B, in, 0x59, kb );
                         if ( g_lc_opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( B, in, LC_AR_MUL, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_DIVK:  { uint64_t kb;
                         if ( g_lc_opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( B, in, 0x5E, kb );
                         return lower_arith_ik( B, f, in ); }
        case OP_MODK:  return lower_arith_ik( B, f, in );
        case OP_IDIVK: return lower_arith_ik( B, f, in );
        case OP_POWK:  return lower_arith_ik( B, f, in );

        /* --- bitwise: -O1 int fastpath (no float arm — bitwise is integer-only;
           float/non-integral operands fall to the coercing helper). --- */
        case OP_BAND:  return ( g_lc_opt_level >= 1 )
                           ? lower_arith_fast( B, in, LC_AR_AND, "Rt_BAndOp", 0 )
                           : lower_helper3( B, in, "Rt_BAndOp", 1 );
        case OP_BOR:   return ( g_lc_opt_level >= 1 )
                           ? lower_arith_fast( B, in, LC_AR_OR, "Rt_BOrOp", 0 )
                           : lower_helper3( B, in, "Rt_BOrOp",  1 );
        case OP_BXOR:  return ( g_lc_opt_level >= 1 )
                           ? lower_arith_fast( B, in, LC_AR_XOR, "Rt_BXorOp", 0 )
                           : lower_helper3( B, in, "Rt_BXorOp", 1 );
        case OP_SHL:   return lower_helper3( B, in, "Rt_ShlOp",  1 );
        case OP_SHR:   return lower_helper3( B, in, "Rt_ShrOp",  1 );
        case OP_BANDK: { int32_t kv;
                         if ( g_lc_opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( B, in, LC_AR_AND, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_BORK:  { int32_t kv;
                         if ( g_lc_opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( B, in, LC_AR_OR, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_BXORK: { int32_t kv;
                         if ( g_lc_opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( B, in, LC_AR_XOR, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_SHRI:
        case OP_SHLI:
            /* a>>K, a<<K (Lua compiles this to SHRI a,a,-K), and K<<a all carry
               the TRUE metamethod tag (__shr/__shl) + corrected immediate in the
               trailing MMBINI, not in the SHRI/SHLI opcode. Rt_ShiftI reads that
               word and dispatches exactly like the interpreter; the per-opcode
               Rt_Sh{r,l}IOp helpers hardcode the wrong TM (e.g. dispatch __shr
               for a metatable'd `a<<K`). MMBINI always follows (lcode.c). */
            if ( f && f->source && in->bc_pc + 1 < f->source->sizecode ) {
                Instruction mm = f->source->code[ in->bc_pc + 1 ];
                return LcCg_EmitHelperCall3( B, "Rt_ShiftI", in->a, in->b,
                                             ( int )( unsigned )mm, /*reload*/1 );
            }
            return lower_helper3( B, in,
                                  in->bc_op == OP_SHRI ? "Rt_ShrIOp" : "Rt_ShlIOp", 1 );

        /* --- unary / len / concat / self --- */
        case OP_UNM:    return lower_helper3( B, in, "Rt_UnmOp",  1 );
        case OP_BNOT:   return lower_helper3( B, in, "Rt_BNotOp", 1 );
        case OP_NOT:    return lower_helper3( B, in, "Rt_NotOp",  0 );
        case OP_LEN:    return lower_helper3( B, in, "Rt_Len",    1 );
        case OP_CONCAT: return lower_helper3( B, in, "Rt_Concat", 1 );
        case OP_SELF:   return lower_helper3( B, in, "Rt_Self",   1 );

        /* --- tables (Plan 2): all helper-call lowerings. lift.c pre-encodes
               operands (size hints for NEWTABLE, Ck value operand for the SET
               ops, fused EXTRAARG hints) into in->a/b/c, so codegen just routes
               each to its Rt_* helper via the 3-arg shim.

               reload_after=1 for everything EXCEPT SETLIST: any GET/SET can run
               an __index/__newindex metamethod (arbitrary Lua) and NEWTABLE
               allocates — both may relocate the Lua stack, so RDI must be
               re-anchored. Rt_SetList only resizes the array part (luaH_resize
               can GC-step but never moves the Lua stack), so v1 Lower_SetList
               skips the reload — match it. --- */
        case OP_NEWTABLE:  return lower_helper3( B, in, "Rt_NewTable", 1 );
        case OP_GETFIELD:  return lower_helper3( B, in, "Rt_GetField", 1 );
        case OP_GETI:      return lower_helper3( B, in, "Rt_GetI",     1 );
        case OP_GETTABLE:  return lower_helper3( B, in, "Rt_GetTable", 1 );
        case OP_SETFIELD:  return lower_helper3( B, in, "Rt_SetField", 1 );
        case OP_SETI:      return lower_helper3( B, in, "Rt_SetI",     1 );
        case OP_SETTABLE:  return lower_helper3( B, in, "Rt_SetTable", 1 );
        case OP_SETTABUP:  return lower_helper3( B, in, "Rt_SetTabUp", 1 );
        case OP_SETLIST:   return lower_helper3( B, in, "Rt_SetList",  0 );

        /* --- metamethod-bin markers + extraarg: no-op (zero bytes) --- */
        case OP_MMBIN:
        case OP_MMBINI:
        case OP_MMBINK:
        case OP_EXTRAARG:
            return 1;

        /* --- control flow --- */
        case OP_JMP:     return LcBr_EmitBranch( Br, -1, in->c, in->bc_pc );
        case OP_EQ:      return lower_cmp( Br, in, "Rt_EqSlow", in->b );
        case OP_LT:      return lower_cmp( Br, in, "Rt_LtSlow", in->b );
        case OP_LE:      return lower_cmp( Br, in, "Rt_LeSlow", in->b );
        case OP_EQK:     return lower_cmp( Br, in, "Rt_EqKSlow", in->b );
        case OP_EQI:     return lower_cmp( Br, in, "Rt_EqISlow", in->b );
        /* LTI/LEI/GTI/GEI share Rt_OrderISlow, which decodes the raw word
           (sB + the float-immediate C flag lvm.c's op_orderI passes to a
           __lt/__le metamethod -- `t < 2.0` must hand the metamethod 2.0,
           not 2). EQI keeps Rt_EqISlow: lvm.c dispatches no metamethod for
           a number-vs-non-number equality, so the flag is unobservable. */
        case OP_LTI:     return lower_cmp( Br, in, "Rt_OrderISlow",
                                           ( int )( unsigned )f->source->code[ in->bc_pc ] );
        case OP_LEI:     return lower_cmp( Br, in, "Rt_OrderISlow",
                                           ( int )( unsigned )f->source->code[ in->bc_pc ] );
        case OP_GTI:     return lower_cmp( Br, in, "Rt_OrderISlow",
                                           ( int )( unsigned )f->source->code[ in->bc_pc ] );
        case OP_GEI:     return lower_cmp( Br, in, "Rt_OrderISlow",
                                           ( int )( unsigned )f->source->code[ in->bc_pc ] );
        case OP_TEST:    return lower_test( Br, in );
        case OP_TESTSET: return lower_testset( Br, in );
        case OP_FORPREP: return lower_forprep( Br, in );
        case OP_FORLOOP: return lower_forloop( Br, in );

        /* --- closures & upvalues (Plan 3) --- */
        case OP_CLOSURE:  return lower_closure( B, in );
        case OP_GETUPVAL: return lower_getupval( B, in );
        case OP_SETUPVAL: return lower_setupval( B, in );
        case OP_VARARG:   return lower_vararg_consume( B, in );

        /* --- to-be-closed (Plan 3) --- */
        case OP_TBC:      return lower_tbc( B, in );
        case OP_CLOSE:    return lower_close( B, in );

        /* --- generic-for (Plan 3) --- */
        case OP_TFORPREP: return lower_tforprep( Br, in );
        case OP_TFORCALL: return lower_tforcall( B, in );
        case OP_TFORLOOP: return lower_tforloop( Br, in );

        default:
            /* Unknown op (rejected by the supported-ops gate). Inert. */
            return 1;
    }
}

LcCodeModule *lc_codegen(LcModule *m) {
  if (!m) return NULL;
  g_lc_opt_level = m->opt_level;   /* -O1+ enables the M1 arith fastpaths */
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

    /* Per-function branch context (bc_pc -> code-offset map + deferred rel32
       patch queue). Sized by the source Proto's instruction count. */
    int sizecode = (f && f->source) ? f->source->sizecode : 0;
    LcBranchCtx Br;
    memset(&Br, 0, sizeof(Br));
    Br.buf = &buf;
    Br.sizecode = sizecode;
    if (sizecode > 0) {
      Br.pc_off = (size_t *)calloc((size_t)sizecode, sizeof(size_t));
      Br.seen   = (uint8_t *)calloc((size_t)sizecode, sizeof(uint8_t));
      if (!Br.pc_off || !Br.seen) {
        free(Br.pc_off); free(Br.seen);
        LcCodeBuf_Free(&buf); lc_codemodule_free(cm); return NULL;
      }
    }

    if (!LcCg_EmitPrologue(&buf)) {
      free(Br.pc_off); free(Br.seen); free(Br.fwd);
      LcCodeBuf_Free(&buf); lc_codemodule_free(cm); return NULL;
    }

    for (uint32_t bi = 0; ok && f && bi < f->nblocks; bi++) {
      LcInst *in;
      for (in = f->blocks[bi]->first; in; in = in->next) {
        if (in->op == LC_OP_RETURN) saw_return = 1;
        /* Record this bytecode pc -> current code offset BEFORE lowering, so
           backward branches and the pc->offset resolution see the right base. */
        LcBr_RecordPc(&Br, in->bc_pc, buf.used);
        if (!lower_inst(&Br, f, in)) { ok = 0; break; }
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

    /* Resolve all deferred forward branches now that every pc has an offset.
       MUST run before we take ownership of buf.bytes. */
    if (ok && !LcBr_Resolve(&Br)) { ok = 0; }

    free(Br.pc_off); free(Br.seen); free(Br.fwd);

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
