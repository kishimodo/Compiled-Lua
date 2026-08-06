/*
** codegen.c — Optimized IR -> relocatable x64. See codegen.h.
** STUB: implement for Milestone M0 (generic lowering: every op -> Rt_* / luaV_* call).
**
** REUSE src/codegen/x64_emit.* (adapted from the removed v1 JIT encoder) for encoding and
**       src/codegen/regalloc.* (adapted from the removed v1 JIT regalloc) for allocation.
** NEW vs the v1 JIT: LcReloc table instead of baked imm64, RIP-relative .rdata
**       loads, .pdata/.xdata UNWIND_INFO per framed function, GC stack maps.
**
** Win64 ABI (preserve from v1): RCX=lua_State*, RDX/R8/R9=operands, RAX=return,
** Lua reg N at [RDI + N*16], tag at +8. Reserve 32B shadow space; keep RSP%16==0
** at calls; reload RDI+cache after stack-relocating helpers; 8-bit tag compares.
*/
#include "codegen.h"
#include "codegen/x64_emit.h"
#include "common/rt_frame_abi.h"

#include "lstate.h"        /* lua_State, CallInfo, StkIdRel layout */
#include "lobject.h"       /* LClosure, Proto, TValue layout (for k recovery) */
#include "lopcodes.h"      /* OP_* opcodes for the M0 bc_op dispatch */

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <windows.h>        /* SYSTEM_INFO / GetSystemInfo for -j default    */

/* CI offsets — replicated from the removed v1 JIT codegen (OFFSET_OF_CI / _FUNC).
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

/* LcCgFnCtx (the per-function codegen state that replaced this file's mutable
   globals) is defined just below LcResRegion, which it holds. */

/* ------------------------------------------------------------------ */
/* savedpc base register (LUAC-001 size fix).                          */
/*                                                                      */
/* Every throw-capable op used to re-walk L -> ci -> func -> LClosure   */
/* -> Proto -> code (5 loads + add + store = 29 bytes) just to publish  */
/* ci->u.l.savedpc. Four of those five loads read state that is         */
/* CONSTANT for the whole frame:                                        */
/*                                                                      */
/*   INVARIANT (savedpc base). For one activation of one compiled body, */
/*   clLvalue(s2v(L->ci->func.p))->p->code is a fixed address.          */
/*     - The body is only ever entered at its entry point: ldo.c ccall  */
/*       and lvm.c luaV_execute both call jitted(L) right after         */
/*       luaD_precall set L->ci, and nothing resumes a native body      */
/*       mid-stream (a native frame has no saved context), so the       */
/*       prologue always runs first for the value it caches.            */
/*     - The running closure at ci->func never changes during the frame */
/*       (OP_VARARGPREP slides ci->func.p and a stack realloc rewrites  */
/*       it, but both keep pointing at the SAME LClosure object; that   */
/*       is exactly why RDI is reloaded and RBX is not).                */
/*     - Proto.code is allocated once when the Proto is built (here: by */
/*       protoinit_rt at startup) and is never reallocated or freed     */
/*       while a frame of it is live.                                   */
/*   OP_TAILCALL rebinds ci to a different closure, but the body        */
/*   returns immediately after it, so no cached value is reused.        */
/*                                                                      */
/* So the prologue computes it once into RBP (the one callee-saved GPR  */
/* nothing else in the backend uses; R12-R15/RSI belong to the M1 loop  */
/* residency cache) and each site collapses to                          */
/*     mov rax, [rbx + L.ci] ; lea r11, [rbp + d] ; mov [rax+pc], r11   */
/* = 15 bytes, or 12 when d fits in a disp8.                            */
/*                                                                      */
/* RBP is biased by the frame's savedpc_bias so d = 4*(pc+1) - bias is         */
/* CENTERED on zero across the function: for a body of <= 63 bytecodes  */
/* every site then reaches the 3-byte-shorter disp8 encoding, and for   */
/* longer bodies the middle 63 do. The bias is a compile-time constant  */
/* applied identically in the prologue and at every site, so the stored */
/* pointer is bit-identical to the unbiased P->code + (pc+1).           */
/* ------------------------------------------------------------------ */
/* (the bias now lives in LcCgFrame.savedpc_bias -- see codegen.h) */

/* Displacement window is [4 - bias, 4*sizecode - bias]; centering it costs a
   one-off LEA in the prologue and is pointless when 4*sizecode already fits
   in a disp8 (sizecode <= 31). Rounded to an instruction so every site's
   displacement stays a multiple of 4. */
static int32_t lc_savedpc_bias_for( int sizecode ) {
    if ( sizecode <= 31 ) return 0;
    return ( int32_t )( 4 * ( ( sizecode + 1 ) / 2 ) );
}

/* ------------------------------------------------------------------ */
/* Frame scaffolding — faithful port of the v1 JIT's prologue/epilogue  */
/* emitters (that compiler has since been removed from the tree),       */
/* retargeted onto X64Emit_*(B,...). The ONLY M0 deviation: skip the    */
/* cache-register preload/reload loop (M0 keeps every Lua register      */
/* memory-resident at [RDI + N*16]; M1 enables register residency).     */
/* All 8 callee-saved regs used (RDI, RBX, R12-R15, RSI, RBP) are      */
/* PUSHed and POPped, so the frame shape is symmetric; see the          */
/* prologue docstring below for why the reservation is 0x28, not 0x20.  */
/* ------------------------------------------------------------------ */

/*!
 * @brief
 *  Emit the function prologue. Saves all callee-saved registers we use, sets
 *  up RBX = L, RDI = ci->func.p + 16 (= ci->func.p + 1 TValue, the Lua
 *  register base) and RBP = P->code + F->savedpc_bias (the savedpc base).
 *
 *  Stack layout: 8 pushes (64 bytes) + return address (8) = 72.
 *  sub rsp, 0x28 (40) -> 112 total, which is 16-aligned at calls.
 */
/* Float-residency constants needed by the prologue/epilogue (the full
   definitions of the residency machinery follow the lowering section). */
#define LC_RES_NREGS 5
static const int k_res_xmm[ LC_RES_NREGS ] = { 6, 7, 8, 9, 10 };
/* (the xmm-spill flag now lives in LcCgFrame.save_xmm -- see codegen.h) */

int LcCg_EmitPrologue( LcCodeBuf *B, const LcCgFrame *F ) {
    /* save all callee-saved registers we'll use: RBX (L), RDI (regbase),
       then R12-R15 and RSI (cache regs in M1; pushed now for frame parity) */
    if ( !X64Emit_PushReg( B, X64_RDI ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_RBX ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R12 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R13 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R14 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_R15 ) ) return 0;
    if ( !X64Emit_PushReg( B, X64_RSI ) ) return 0;
    /* RBP: the savedpc base register (see the INVARIANT block above). Pushed
       last so RDI stays the first push / last pop. */
    if ( !X64Emit_PushReg( B, X64_RBP ) ) return 0;
    /* 8 pushes = 64 bytes; with return address (8) = 72; +0x28 = 112, 16-aligned */
    /* xmm6..xmm10 are Win64 callee-saved (full 128 bits); save them only when
       this function uses float residency (Fn->frame.save_xmm, set by res_analyze
       before the prologue is emitted). 5*16 = 80 preserves RSP alignment
       (it is a multiple of 16), and MOVUPS does not require an aligned slot. */
    if ( F->save_xmm ) {
        int xi;
        if ( !X64Emit_SubRspImm( B, 0x50 ) ) return 0;
        for ( xi = 0; xi < LC_RES_NREGS; xi++ )
            if ( !X64Emit_MovupsStoreXmm( B, k_res_xmm[ xi ], X64_RSP, xi * 16 ) )
                return 0;
    }
    if ( !X64Emit_SubRspImm( B, 0x28 ) )  return 0;
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
    /* RBP = P->code + F->savedpc_bias. RAX still holds ci->func.p, so this is
       the same closure->Proto walk lower_const does, done once per frame. */
    if ( !X64Emit_MovMemToReg( B, X64_RBP, X64_RAX, 0 ) )                 return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RBP, X64_RBP, LC_OFF_LCL_P ) )      return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RBP, X64_RBP, LC_OFF_PROTO_CODE ) ) return 0;
    if ( F->savedpc_bias != 0 &&
         !X64Emit_LeaRegMem( B, X64_RBP, X64_RBP, F->savedpc_bias ) )     return 0;
    /* M0: registers are memory-resident; no cache preload (M1 enables RegAlloc) */
    return 1;
}

/*!
 * @brief
 *  Emit the function epilogue. RAX holds the return count; restore all
 *  callee-saved registers in reverse push order and return.
 */
int LcCg_EmitEpilogue( LcCodeBuf *B, const LcCgFrame *F ) {
    if ( !X64Emit_AddRspImm( B, 0x28 ) )  return 0;
    if ( F->save_xmm ) {                  /* mirror the prologue's xmm saves */
        int xi;
        for ( xi = 0; xi < LC_RES_NREGS; xi++ )
            if ( !X64Emit_MovupsLoadXmm( B, k_res_xmm[ xi ], X64_RSP, xi * 16 ) )
                return 0;
        if ( !X64Emit_AddRspImm( B, 0x50 ) ) return 0;
    }
    if ( !X64Emit_PopReg( B, X64_RBP ) )  return 0;
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
    /* Three instructions / 11 bytes, down from five / 20. Two independent folds,
    ** both of which make the sequence strictly safer rather than merely shorter:
    **
    **   * Read L->ci straight out of RBX. RBX already holds L for the whole
    **     function (see the prologue docstring), so the previous
    **     LcCg_EmitRestoreL -- a bare MOV RCX, RBX -- copied L into RCX only to
    **     dereference it one instruction later. Nothing depended on the reload
    **     leaving L in RCX: RCX is the Win64 first-argument register and every
    **     helper-call site sets it explicitly just before the CALL (see
    **     LcCg_EmitHelperCall3 below). Not clobbering it here is one fewer
    **     surprise, not one more.
    **   * LEA 16(%rax), %rdi instead of MOV %rax,%rdi + ADD $16,%rdi. Same
    **     address, one instruction, and LEA does not write flags where ADD did --
    **     so no lowering that runs after a reload can be affected except
    **     favourably.
    **
    ** Measured on rover/src/rover.lua at -O1, both arms rebuilt from source
    ** (obj/codegen/codegen.o explicitly, because Makefile.luac pulls backend
    ** objects by wildcard and will happily relink a stale one):
    **   .text 536,590 -> 502,926 = -33,664 bytes, -6.27%
    **   whole file 671,232 -> 637,440
    ** The win is large because a reload follows most helper calls -- roughly 3,700
    ** sites in rover. */
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RBX, LC_OFF_CI ) ) return 0;
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RAX, LC_OFF_CI_FUNC ) ) return 0;
    if ( !X64Emit_LeaRegMem( B, X64_RDI, X64_RAX, 16 ) ) return 0;
    /* M0: registers are memory-resident; no cache reload (M1 enables RegAlloc) */
    return 1;
}

/* The three argument moves below use the imm32 encoder, not the imm64 one, and
** that is a pure size change rather than an ABI bet:
**
**   * X64Emit_MovImm32ToReg leaves the register bit-identical to what
**     `mov r64, imm64` of (uint64_t)(int64_t)x left there, for every value -- it
**     sign-extends negatives instead of taking the shorter zero-extending form.
**     So no argument about how many bits the callee reads is required, though
**     for the record every Rt_* symbol reachable here takes `int` parameters.
**   * The zero tier clobbers EFLAGS, which is dead at this point: the next
**     instruction this shim emits is always the CALL, and an arbitrary C callee
**     may destroy flags anyway.
**
** Measured on rover: 4,724 call sites, 30 bytes of argument loads each, none of
** the 14,172 immediates needing more than 32 bits.
** See docs/benchmarks/helper-call-args.md. */
enum { LC_CHK_INT_IS_32BIT = 1 / ( ( int )sizeof( int ) == 4 ) };

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
    if ( !X64Emit_MovImm32ToReg( B, X64_RDX, ( int32_t )a ) ) return 0;
    if ( !X64Emit_MovImm32ToReg( B, X64_R8,  ( int32_t )b ) ) return 0;
    if ( !X64Emit_MovImm32ToReg( B, X64_R9,  ( int32_t )c ) ) return 0;
    if ( !X64Emit_CallSym( B, Sym ) ) return 0;
    if ( reload_after && !LcCg_EmitReloadRdiAndCache( B ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Call a frame-passing helper: RCX = L, RDX = Base, R8 = packed operands.
 *
 *  RDI holds the frame base at every call site -- that is the invariant
 *  LcCg_EmitReloadRdiAndCache exists to maintain -- so handing it over is a
 *  register copy. The helper then reaches L->ci->func.p as Base - 1 instead of
 *  chasing two loads for it and three more for the constant array.
 *
 *  Twelve bytes against LcCg_EmitHelperCall3's twenty: one MOV r64,r64 replaces
 *  a 32-bit immediate move, and the two remaining operands travel folded into
 *  one word rather than in R8 and R9 separately. See common/rt_frame_abi.h.
 */
int LcCg_EmitHelperCallFrame( LcCodeBuf *B, const char *Sym,
                              int32_t packed, int reload_after ) {
    if ( !LcCg_EmitRestoreL( B ) ) return 0;                          /* RCX = L */
    if ( !X64Emit_MovRegToReg( B, X64_RDX, X64_RDI ) ) return 0;      /* RDX = Base */
    if ( !X64Emit_MovImm32ToReg( B, X64_R8, packed ) ) return 0;
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
/* instruction loop. This mirrors the removed v1 JIT's BranchCtx exactly */
/* (only the buffer plumbing differs: LcCodeBuf instead of an exec slot). */
/* ------------------------------------------------------------------ */
typedef struct LcFwdJump {
    size_t patch_site;   /* offset of the disp32 word inside buf.bytes */
    int    target_pc;    /* bc_pc the jump lands on                    */
} LcFwdJump;

/* Defined below LcResRegion, which it owns; LcBranchCtx only holds a pointer. */
typedef struct LcCgFnCtx LcCgFnCtx;

typedef struct LcBranchCtx {
    LcCgFnCtx *fn;       /* per-function codegen state; never NULL in lowering */
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
/* Per-op lowering — faithful AOT port of the removed v1 JIT's Lower_* (the      */
/* memory-form path: M0 keeps every Lua register at [RDI + N*16], so   */
/* we always use the memory path v1 emits when a register isn't        */
/* cached). Operands come from inst->a/b/c (decoded by lift.c).        */
/* ------------------------------------------------------------------ */

typedef enum { LC_AR_ADD, LC_AR_SUB, LC_AR_MUL,
               LC_AR_AND, LC_AR_OR, LC_AR_XOR } LcArOp;

/* ------------------------------------------------------------------ */
/* M1 loop-region register residency.                                  */
/*                                                                      */
/* Within a qualified innermost FORLOOP region (every instruction       */
/* frame-blind: fully-elided arith/compares, MOVE/LOADI/consts, JMPs    */
/* contained, the FORLOOP itself proven integral — see res_analyze),    */
/* up to five proven-int Lua slots live in the callee-saved cache       */
/* registers R12-R15/RSI that the prologue already preserves. The frame */
/* is filled into registers once at region entry (fall-in from FORPREP, */
/* before the back-edge label) and spilled (value + INT tag) once at    */
/* the FORLOOP fall-through exit. No helper can run inside the region,  */
/* so no GC, error, or reflection can observe the stale slots; resident */
/* slot tags stay INT throughout. The zero-trip FORPREP branch targets  */
/* the pc after the spills, skipping fill and spill alike.              */
/* ------------------------------------------------------------------ */
typedef struct LcResRegion {
    int    start;                  /* first body pc (FORLOOP back-edge target) */
    int    end;                    /* the OP_FORLOOP pc                        */
    int8_t slot[ LC_RES_NREGS ];   /* resident int slot per cache GPR, or -1  */
    int8_t fslot[ LC_RES_NREGS ];  /* resident float slot per cache XMM, -1   */
    uint8_t *obs;                  /* per-body-pc observation flags            */
                                   /* ([end-start] entries; pc T+i -> obs[i]): */
                                   /* spill all residents BEFORE this op       */
} LcResRegion;

/* Per-function codegen state. Everything here was a file-scope global until the
   state was isolated; the point of the struct is that a future per-function
   worker can own one, so nothing in this file may reintroduce a mutable global.
   Threaded through LcBranchCtx where a function already receives one, and as an
   explicit parameter where it does not. */
struct LcCgFnCtx {
    const LcCgCtx *cg;           /* per-compilation, read-only                  */
    LcCgFrame      frame;        /* prologue/epilogue agreement (see codegen.h) */
    LcResRegion   *res_regions;  /* M1 residency regions for this function      */
    int            res_n;
    int            res_cur;      /* active region, -1 = none. NOT zero: see
                                    lc_cg_fn_init -- a memset leaves 0, which
                                    means "region 0 is live" and would emit
                                    spills for a region that never started. */
};

static const X64_GPR_T k_res_gpr[ LC_RES_NREGS ] =
    { X64_R12, X64_R13, X64_R14, X64_R15, X64_RSI };
/* (k_res_xmm is defined above the prologue, which needs it; the xmm-spill flag
   is LcCgFrame.save_xmm.) */

/* (the residency arrays and the region cursor now live in LcCgFnCtx) */

/* Initialise the per-function state. res_cur MUST be set here rather than left
   to a memset: 0 would mean "region 0 is active" before any region starts. */
static void lc_cg_fn_init( LcCgFnCtx *fn, const LcCgCtx *cg, int sizecode ) {
    memset( fn, 0, sizeof( *fn ) );
    fn->cg                  = cg;
    fn->frame.savedpc_bias  = lc_savedpc_bias_for( sizecode );
    fn->frame.save_xmm      = 0;
    fn->res_cur             = -1;
}

static void lc_cg_fn_dispose( LcCgFnCtx *fn ) {
    int ri;
    for ( ri = 0; ri < fn->res_n; ri++ ) free( fn->res_regions[ ri ].obs );
    free( fn->res_regions );
    fn->res_regions = NULL;
    fn->res_n       = 0;
    fn->res_cur     = -1;
}

/* Cache GPR holding `slot` in the active region, or -1 (memory form). */
static int res_reg_of( const LcCgFnCtx *Fn, int slot ) {
    int i;
    if ( Fn->res_cur < 0 ) return -1;
    for ( i = 0; i < LC_RES_NREGS; i++ )
        if ( Fn->res_regions[ Fn->res_cur ].slot[ i ] == slot ) return ( int )k_res_gpr[ i ];
    return -1;
}

/* dst = slot (resident reg move, or frame-slot load). */
static int res_load_reg( const LcCgFnCtx *Fn, LcCodeBuf *B, X64_GPR_T dst, int slot ) {
    int r = res_reg_of( Fn, slot );
    return ( r >= 0 ) ? X64Emit_MovRegToReg( B, dst, ( X64_GPR_T )r )
                      : X64Emit_MovMemToReg( B, dst, X64_RDI, slot * 16 );
}
/* slot = src, as a proven integer (reg move, or value store + INT tag). */
static int res_store_reg_int( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot, X64_GPR_T src ) {
    int r = res_reg_of( Fn, slot );
    if ( r >= 0 ) return X64Emit_MovRegToReg( B, ( X64_GPR_T )r, src );
    if ( !X64Emit_MovRegToMem( B, X64_RDI, slot * 16, src ) ) return 0;
    return X64Emit_MovImm32ToMem( B, X64_RDI, slot * 16 + 8, LUA_VNUMINT );
}
static int res_load_rax( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot )      { return res_load_reg( Fn, B, X64_RAX, slot ); }
static int res_store_rax_int( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot ) { return res_store_reg_int( Fn, B, slot, X64_RAX ); }
static int res_arith_rax( const LcCgFnCtx *Fn, LcCodeBuf *B, LcArOp op, int slot );  /* after emit_arith_rax_mem */
static int res_cmp_rax( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot );               /* after emit_cmp_rax_mem  */

/* Cache XMM holding `slot` in the active region, or -1 (memory form). */
static int res_freg_of( const LcCgFnCtx *Fn, int slot ) {
    int i;
    if ( Fn->res_cur < 0 ) return -1;
    for ( i = 0; i < LC_RES_NREGS; i++ )
        if ( Fn->res_regions[ Fn->res_cur ].fslot[ i ] == slot ) return k_res_xmm[ i ];
    return -1;
}
/* xmm0 = slot (resident xmm move, or frame-slot load). */
static int res_f_load_xmm0( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot ) {
    int x = res_freg_of( Fn, slot );
    return ( x >= 0 ) ? X64Emit_MovsdXmmXmm( B, 0, x )
                      : X64Emit_MovsdMemToXmm0( B, X64_RDI, slot * 16 );
}
/* xmmN = slot (N may be 1 for the K-compare forms). */
static int res_f_load_xmmn( const LcCgFnCtx *Fn, LcCodeBuf *B, int n, int slot ) {
    int x = res_freg_of( Fn, slot );
    return ( x >= 0 ) ? X64Emit_MovsdXmmXmm( B, n, x )
                      : X64Emit_MovsdLoadXmm( B, n, X64_RDI, slot * 16 );
}
/* slot = xmm0, as a proven float (xmm move, or value store + FLT tag). */
static int res_f_store_xmm0_flt( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot ) {
    int x = res_freg_of( Fn, slot );
    if ( x >= 0 ) return X64Emit_MovsdXmmXmm( B, x, 0 );
    if ( !X64Emit_MovsdXmm0ToMem( B, X64_RDI, slot * 16 ) ) return 0;
    return X64Emit_MovImm32ToMem( B, X64_RDI, slot * 16 + 8, LUA_VNUMFLT );
}
/* xmm0 <sse-op>= slot (0x58 add / 0x5C sub / 0x59 mul / 0x5E div). */
static int res_f_arith_xmm0( const LcCgFnCtx *Fn, LcCodeBuf *B, unsigned char sse_op, int slot ) {
    int x = res_freg_of( Fn, slot );
    return ( x >= 0 ) ? X64Emit_ArithSdXmm0Xmm( B, sse_op, x )
                      : X64Emit_ArithSdXmm0Mem( B, sse_op, X64_RDI, slot * 16 );
}
/* ucomisd xmm0, slot. */
static int res_f_ucomisd_xmm0( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot ) {
    int x = res_freg_of( Fn, slot );
    return ( x >= 0 ) ? X64Emit_UcomisdXmm0Xmm( B, x )
                      : X64Emit_UcomisdXmm0Mem( B, X64_RDI, slot * 16 );
}

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
 *  Route a table access to its frame-passing helper, falling back to the plain
 *  one when an operand will not fit the packed word.
 *
 *  `signed_c` says whether in->c is a setter's Ck -- negative meaning "the
 *  value operand is K[-c-1]", the encoding DecodeCk undoes at run time. Here it
 *  is a compile-time constant, so it is undone at compile time and the K bit
 *  travels in the packed word; the helper does no decoding at all.
 *
 *  The fallback is not dead code awaiting a pathological program: it is what
 *  makes the 10-bit fields safe to assume everywhere else. lift.c pre-encodes
 *  some operands, so "iABC operands are 8 bits" describes Lua's instruction
 *  format, not a guarantee about what reaches this function.
 *
 *  reload_after is 1 throughout, matching the plain lowerings: any of these can
 *  run an __index/__newindex metamethod, which is arbitrary Lua and may
 *  relocate the stack.
 */
static int lower_table_frame( LcCodeBuf *B, LcInst *in, const char *FrameSym,
                              const char *PlainSym, int signed_c ) {
    int c = in->c, k = 0;
    if ( signed_c && c < 0 ) { c = -c - 1; k = 1; }
    if ( !LC_RTF_FITS( in->a, in->b, c ) )
        return LcCg_EmitHelperCall3( B, PlainSym, in->a, in->b, in->c, /*reload*/1 );
    return LcCg_EmitHelperCallFrame(
        B, FrameSym, ( int32_t )LC_RTF_PACK( in->a, in->b, c, k ), /*reload*/1 );
}

/*!
 * @brief
 *  LC_OP_GLOBAL_GET (OP_GETTABUP on _ENV): R[A] = UpVal[B][K[C]].
 *  Ported from v1 Lower_GetTabUp (codegen.c ~1328): set RDX=A,R8=B,R9=C, call
 *  Rt_GetTabUp, then EmitReloadRdiAndCache (a metamethod can grow the stack).
 */
static int lower_global_get( LcCodeBuf *B, LcInst *in ) {
    return lower_table_frame( B, in, "Rt_GetTabUpF", "Rt_GetTabUp", /*signed_c*/0 );
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
static int lower_return( const LcCgFnCtx *Fn, LcCodeBuf *B, LcInst *in ) {
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
    return LcCg_EmitEpilogue( B, &Fn->frame );
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
static int lower_tailcall( const LcCgFnCtx *Fn, LcCodeBuf *B, LcInst *in ) {
    int Bee   = in->b;
    int NArgs = ( Bee == 0 ) ? -1 : ( Bee - 1 );
    if ( in->ret_close ) {
        if ( !LcCg_EmitHelperCall3( B, "Rt_Close", 0, 0, 0, /*reload*/1 ) ) return 0;
    }
    /* Rt_TailCall(L, A, NArgs) -> RAX = nresults */
    if ( !LcCg_EmitHelperCall3( B, "Rt_TailCall", in->a, NArgs, 0, /*reload*/0 ) )
        return 0;
    return LcCg_EmitEpilogue( B, &Fn->frame );
}

/* ------------------------------------------------------------------ */
/* Plan 1 — inline loads (no helper). Faithful ports of v1's           */
/* Lower_Move/LoadI/LoadF/LoadFalse/LoadTrue/LoadNil onto the          */
/* memory-form path: every Lua register lives at [RDI + N*16] (value), */
/* tag dword at +8.                                                    */
/* ------------------------------------------------------------------ */

/* MOVE A B: 16-byte TValue copy [RDI+B*16] -> [RDI+A*16] (value + tag). */
static int lower_move( const LcCgFnCtx *Fn, LcCodeBuf *B, LcInst *in ) {
    int A = in->a, Bs = in->b;
    /* Proven-int source: single value move + INT tag (identical observable
       state to copying the tag), residency-aware on both sides. */
    if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_INT ) ) {
        if ( !res_load_rax( Fn, B, Bs ) ) return 0;
        return res_store_rax_int( Fn, B, A );
    }
    /* Proven-float source: same, with the FLT tag. */
    if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT ) ) {
        if ( !res_f_load_xmm0( Fn, B, Bs ) ) return 0;
        return res_f_store_xmm0_flt( Fn, B, A );
    }
    /* value half via R10 */
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RDI, Bs * 16 ) )       return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_R10 ) )        return 0;
    /* tag half via R10 */
    if ( !X64Emit_MovMemToReg( B, X64_R10, X64_RDI, Bs * 16 + 8 ) )   return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16 + 8, X64_R10 ) )    return 0;
    return 1;
}

/* LOADI A sBx: R[A] = sBx (sign-extended integer), tag LUA_VNUMINT. */
static int lower_loadi( const LcCgFnCtx *Fn, LcCodeBuf *B, LcInst *in ) {
    int A = in->a;
    int64_t v = ( int64_t )in->b;   /* sBx carried in `b` */
    int r = res_reg_of( Fn, A );
    if ( r >= 0 )                   /* resident dst: load the imm straight in */
        return X64Emit_MovImm64ToReg( B, ( X64_GPR_T )r, ( uint64_t )v );
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, ( uint64_t )v ) )        return 0;
    if ( !X64Emit_MovRegToMem( B, X64_RDI, A * 16, X64_RAX ) )        return 0;
    if ( !X64Emit_MovImm32ToMem( B, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
    return 1;
}

/* LOADF A sBx: R[A] = (double)sBx (bit pattern), tag LUA_VNUMFLT. */
static int res_f_loadf_resident( LcCodeBuf *B, int xreg, uint64_t bits ) {
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, bits ) ) return 0;
    return X64Emit_MovqReg64ToXmmN( B, xreg, X64_RAX );
}
static int lower_loadf( const LcCgFnCtx *Fn, LcCodeBuf *B, LcInst *in ) {
    int A = in->a;
    double d = ( double )in->b;     /* sBx carried in `b` */
    uint64_t bits = 0;
    int x;
    memcpy( &bits, &d, 8 );
    x = res_freg_of( Fn, A );
    if ( x >= 0 )                   /* resident dst: materialize straight in */
        return res_f_loadf_resident( B, x, bits );
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
    const LcCgFnCtx *Fn = Br->fn;
    LcCodeBuf *B = Br->buf;
    int A = in->a, Bop = in->b, K = in->c;
    int is_regreg, cc;

    /* --- M1 (-O1+): inline integer comparison fastpath, helper fallback. ---
       Sound: only when the operand tags are LUA_VNUMINT does the inline path run
       (exact integer compare, no NaN concerns); float/string/table/__eq/__lt fall
       to the complete helper. EQK (reg-vs-constant) keeps the helper. */
    cc = Fn->cg->opt_level >= 1 ? cmp_setcc( in->bc_op, &is_regreg ) : -1;
    if ( cc >= 0 ) {
        size_t jneA, jneB = 0, jmp_fast, slow, cmpk;

        /* M1 elision: operand(s) PROVEN integer -> inline compare with no
           tag-check, no helper. op1 = R[A]; op2 = R[B] (reg-reg) or the signed
           immediate (the *I forms, statically integer). */
        int op1_int = ( in->known & LC_KNOWN_B_INT ) != 0;
        int op2_int = is_regreg ? ( ( in->known & LC_KNOWN_C_INT ) != 0 ) : 1;
        int op1_flt = ( in->known & LC_KNOWN_B_FLT ) != 0;
        int op2_flt = is_regreg ? ( ( in->known & LC_KNOWN_C_FLT ) != 0 ) : 1;

        if ( op1_int && op2_int ) {     /* INT elide, residency-aware */
            if ( !res_load_rax( Fn, B, A ) ) return 0;
            if ( is_regreg ) { if ( !res_cmp_rax( Fn, B, Bop ) ) return 0; }
            else             { if ( !emit_cmp_rax_imm32( B, Bop ) ) return 0; }
            if ( !emit_setcc_movzx_r11( B, ( unsigned )cc ) ) return 0;
            { unsigned char C[ 4 ] = { 0x41, 0x83, 0xFB, ( unsigned char )( int8_t )K };
              if ( !LcCodeBuf_Append( B, C, 4 ) ) return 0; }   /* cmp r11d, K */
            return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->bc_pc + 2, in->bc_pc );
        }

        /* M1 FLT elision: operand(s) PROVEN float -> bare ucomisd, no
           tag-check, no helper. Lua NaN semantics come free: ucomisd's
           unordered result sets ZF=PF=CF=1, so the CF-based seta/setae are
           false-on-NaN; equality additionally requires PF=0. The compare is
           operand-swapped so `<`/`<=` map onto above/above-equal:
             a <  b : ucomisd(b, a) seta    a <= b : ucomisd(b, a) setae
             a >  K : ucomisd(a, K) seta    a >= K : ucomisd(a, K) setae
             a <  K : ucomisd(K, a) seta    a <= K : ucomisd(K, a) setae
           An *I immediate is statically int (never NaN); converting it to
           double at compile time is the same cast lvm.c's op_orderI applies.
           EQI keeps the helper (number-vs-number only; rare for floats). */
        if ( op1_flt && op2_flt && in->bc_op != OP_EQI ) {
            if ( is_regreg ) {
                if ( in->bc_op == OP_EQ ) {
                    if ( !res_f_load_xmm0( Fn, B, A ) ) return 0;
                    if ( !res_f_ucomisd_xmm0( Fn, B, Bop ) ) return 0;
                    if ( !emit_setcc_movzx_r11( B, 0x4 ) ) return 0;   /* r11d = ZF */
                    { unsigned char S[ 6 ] = { 0x0F, 0x9B, 0xC0,       /* setnp al  */
                                               0x41, 0x20, 0xC3 };     /* and r11b, al */
                      if ( !LcCodeBuf_Append( B, S, 6 ) ) return 0; }
                } else {            /* LT / LE: compare swapped, then seta/setae */
                    if ( !res_f_load_xmm0( Fn, B, Bop ) ) return 0;
                    if ( !res_f_ucomisd_xmm0( Fn, B, A ) ) return 0;
                    if ( !emit_setcc_movzx_r11( B,
                            in->bc_op == OP_LT ? 0x7 : 0x3 ) ) return 0;
                }
            } else {
                double   kd = ( double )( int32_t )Bop;
                uint64_t kbits; memcpy( &kbits, &kd, 8 );
                int gt = ( in->bc_op == OP_GTI || in->bc_op == OP_GEI );
                if ( gt ) {         /* a > K / a >= K: xmm0 = a, xmm1 = K */
                    if ( !res_f_load_xmm0( Fn, B, A ) ) return 0;
                    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, kbits ) ) return 0;
                    if ( !X64Emit_MovqReg64ToXmmN( B, 1, X64_RAX ) ) return 0;
                } else {            /* a < K / a <= K: xmm0 = K, xmm1 = a */
                    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, kbits ) ) return 0;
                    if ( !X64Emit_MovqReg64ToXmm0( B, X64_RAX ) ) return 0;
                    if ( !res_f_load_xmmn( Fn, B, 1, A ) ) return 0;
                }
                if ( !X64Emit_UcomisdXmm0Xmm1( B ) ) return 0;
                if ( !emit_setcc_movzx_r11( B,
                        ( in->bc_op == OP_LTI || in->bc_op == OP_GTI )
                            ? 0x7 : 0x3 ) ) return 0;
            }
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
    const LcCgFnCtx *Fn = Br->fn;
    LcCodeBuf *B = Br->buf;
    int    A = in->a;
    size_t jne_slow, jz_exit, slow, ex;

    if ( Fn->cg->opt_level < 1 ) {                     /* -O0: faithful helper path */
        if ( !LcCg_EmitHelperCall3( B, "Rt_ForLoop", A, 0, 0, /*reload*/0 ) ) return 0;
        if ( !X64Emit_TestEaxEax( B ) ) return 0;
        return LcBr_EmitBranch( Br, 0x5 /* JNE */, in->c, in->bc_pc );
    }

    /* -O1, PROVEN integer loop (index+step INT on every path; the count in
       R[A+1] is an integer whenever FORPREP fell through): the BARE inline
       loop -- no step tag-check, no helper arm -- with residency-aware slot
       access. In a qualified region the whole update runs in cache registers. */
    if ( in->known & LC_KNOWN_B_INT ) {
        size_t jz_exit2, ex2;
        if ( !res_load_rax( Fn, B, A + 1 ) ) return 0;                 /* count */
        { unsigned char t[ 3 ] = { 0x48, 0x85, 0xC0 };             /* test rax, rax */
          if ( !LcCodeBuf_Append( B, t, 3 ) ) return 0; }
        jz_exit2 = X64Emit_JccRel32_Placeholder( B, 0x4 /* JZ -> exit */ );
        if ( jz_exit2 == ( size_t )-1 ) return 0;
        { unsigned char d[ 3 ] = { 0x48, 0xFF, 0xC8 };             /* dec rax */
          if ( !LcCodeBuf_Append( B, d, 3 ) ) return 0; }
        if ( !res_store_rax_int( Fn, B, A + 1 ) ) return 0;            /* count-1 */
        if ( !res_load_reg( Fn, B, X64_RCX, A + 2 ) ) return 0;        /* step */
        if ( !res_load_reg( Fn, B, X64_RDX, A ) ) return 0;            /* idx */
        { unsigned char a2[ 3 ] = { 0x48, 0x01, 0xCA };            /* add rdx, rcx */
          if ( !LcCodeBuf_Append( B, a2, 3 ) ) return 0; }
        if ( !res_store_reg_int( Fn, B, A, X64_RDX ) ) return 0;       /* R[A] = idx */
        if ( !res_store_reg_int( Fn, B, A + 3, X64_RDX ) ) return 0;   /* ctrl var */
        if ( !LcBr_EmitBranch( Br, -1 /* JMP */, in->c, in->bc_pc ) ) return 0;
        ex2 = B->used;                                             /* count==0 */
        if ( !X64Emit_PatchRel32( B, jz_exit2, ex2 ) ) return 0;
        return 1;
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
/* TForPrep/TForCall/TForLoop/Tbc/Close (the removed v1 JIT codegen). Operands   */
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

/* rax <op>= slot (resident cache reg or frame slot). */
static int res_arith_rax( const LcCgFnCtx *Fn, LcCodeBuf *B, LcArOp op, int slot ) {
    static const unsigned char regop[] =
        { 0x03, 0x2B, 0xAF, 0x23, 0x0B, 0x33 };  /* ADD SUB IMUL AND OR XOR */
    int r = res_reg_of( Fn, slot );
    if ( r >= 0 ) return X64Emit_ArithRaxReg( B, regop[ op ], ( X64_GPR_T )r );
    return emit_arith_rax_mem( B, op, slot * 16 );
}
/* cmp rax, slot (resident cache reg or frame slot). */
static int res_cmp_rax( const LcCgFnCtx *Fn, LcCodeBuf *B, int slot ) {
    int r = res_reg_of( Fn, slot );
    if ( r >= 0 ) return X64Emit_ArithRaxReg( B, 0x3B, ( X64_GPR_T )r );
    return emit_cmp_rax_mem( B, slot * 16 );
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
static int lower_arith_fast( const LcCgFnCtx *Fn, LcCodeBuf *Bb, LcInst *in, LcArOp op,
                             const char *slow_sym, int has_float ) {
    int    A = in->a, Br = in->b, Cr = in->c;
    size_t jne_fB = 0, jne_fC = 0, jmp_df = 0, jne_iB, jne_iC, jmp_di, int_check, slow, done;
    int    ok;

    /* M1 type-inference elision: both operands PROVEN integer (lc_pass_local_
       typeinfer) -> emit the bare integer op with no tag-check, no float arm, no
       helper. Sound iff the proof is sound (no runtime guard, per PROMPT §9).
       Slot access goes through the residency accessors (register-resident in a
       qualified loop region, frame slot otherwise). */
    if ( ( in->known & LC_KNOWN_B_INT ) && ( in->known & LC_KNOWN_C_INT ) ) {
        if ( !res_load_rax( Fn, Bb, Br ) ) return 0;
        if ( !res_arith_rax( Fn, Bb, op, Cr ) ) return 0;
        if ( !res_store_rax_int( Fn, Bb, A ) ) return 0;
        return 1;
    }

    /* M1 float elision: both operands PROVEN float -> bare SSE op, no tag-check,
       no helper. has_float gates it to ADD/SUB/MUL (never bitwise). Sound: float
       arith carries no metamethod, so two proven floats always yield a float. */
    if ( has_float && ( in->known & LC_KNOWN_B_FLT ) && ( in->known & LC_KNOWN_C_FLT ) ) {
        unsigned char sse =
            ( op == LC_AR_ADD ) ? 0x58 : ( op == LC_AR_SUB ) ? 0x5C : 0x59;
        int xa = res_freg_of( Fn, A );
        if ( xa >= 0 && A == Br ) {            /* in-place: f = f <op> g */
            int xc = res_freg_of( Fn, Cr );
            return ( xc >= 0 ) ? X64Emit_ArithSdXmmXmm( Bb, sse, xa, xc )
                               : X64Emit_ArithSdXmmMem( Bb, sse, xa, X64_RDI, Cr * 16 );
        }
        if ( !res_f_load_xmm0( Fn, Bb, Br ) ) return 0;
        if ( !res_f_arith_xmm0( Fn, Bb, sse, Cr ) ) return 0;
        if ( !res_f_store_xmm0_flt( Fn, Bb, A ) ) return 0;
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
static int lower_arith_imm_fast( const LcCgFnCtx *Fn, LcCodeBuf *Bb, LcInst *in, LcArOp op,
                                 int32_t imm, int mmw ) {
    int    A = in->a, Br = in->b;
    size_t jne_iB, jmp_di, slow, done;

    /* M1 elision: R[B] PROVEN integer -> bare int op with the immediate, no
       tag-check, no helper. Residency-aware slot access. */
    if ( in->known & LC_KNOWN_B_INT ) {
        if ( !res_load_rax( Fn, Bb, Br ) ) return 0;
        if ( !emit_arith_rax_imm32( Bb, op, imm ) ) return 0;
        if ( !res_store_rax_int( Fn, Bb, A ) ) return 0;
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
   the right line. Mirrors the removed v1 JIT codegen's OpcodeNeedsSavedPc. */
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

/* Store ci->u.l.savedpc = P->code + (pc+1) (LUAC-001), so pcRel(savedpc, P)
   == pc and a raised error reports the right source:line (and the right
   variable name -- ldebug's varinfo decodes the instruction AT that pc, so
   every throw-capable op needs its OWN pc, not merely its own line).

   The P->code walk is hoisted into the prologue (RBP = P->code + bias; see the
   INVARIANT block near the top of this file), leaving three instructions:
   reload ci (L->ci is NOT frame-cached -- it is only stable across this frame,
   and RBX/RDI/RBP already consume every register we can spare), compute the
   pointer, store it. Clobbers RAX (= ci) and R11, exactly as before. */
static int emit_store_savedpc( const LcCgFnCtx *Fn, LcCodeBuf *B, int pc ) {
    if ( !X64Emit_MovMemToReg( B, X64_RAX, X64_RBX, LC_OFF_CI ) )         return 0;
    if ( !X64Emit_LeaRegMem( B, X64_R11, X64_RBP,
                             ( int32_t )( pc + 1 ) * 4 - Fn->frame.savedpc_bias ) ) return 0;
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
static int lower_arithk_flt_elide( const LcCgFnCtx *Fn, LcCodeBuf *B, LcInst *in,
                                   unsigned char sse_op, uint64_t kbits ) {
    int A = in->a, Br = in->b;
    int xa = res_freg_of( Fn, A );
    /* In-place resident accumulate (f = f <op> K): operate directly on the
       resident xmm -- the xmm0 round-trip costs two movsd on the loop's
       critical dependency chain. */
    if ( xa >= 0 && A == Br ) {
        if ( !X64Emit_MovImm64ToReg( B, X64_RAX, kbits ) ) return 0;
        if ( !X64Emit_MovqReg64ToXmmN( B, 1, X64_RAX ) ) return 0;
        return X64Emit_ArithSdXmmXmm( B, sse_op, xa, 1 );
    }
    if ( !res_f_load_xmm0( Fn, B, Br ) ) return 0;
    if ( !X64Emit_MovImm64ToReg( B, X64_RAX, kbits ) ) return 0;
    if ( !X64Emit_MovqReg64ToXmmN( B, 1, X64_RAX ) ) return 0;
    if ( !X64Emit_ArithSdXmm0Xmm1( B, sse_op ) ) return 0;
    if ( !res_f_store_xmm0_flt( Fn, B, A ) ) return 0;
    return 1;
}

static int lower_inst( LcBranchCtx *Br, LcFunc *f, LcInst *in ) {
    const LcCgFnCtx *Fn = Br->fn;
    LcCodeBuf *B = Br->buf;
    /* LUAC-001: keep ci->u.l.savedpc current before any throw-capable op so a
       raised error reports the correct source:line (matching the interpreter). */
    if ( op_needs_savedpc( in->bc_op ) && !emit_store_savedpc( Fn, B, in->bc_pc ) )
        return 0;
    switch ( in->bc_op ) {
        /* --- epsilon set --- */
        case OP_VARARGPREP:  return lower_vararg( B, in );
        case OP_GETTABUP:    return lower_global_get( B, in );
        case OP_LOADK:       return lower_const( B, in );
        case OP_CALL:        return lower_call( B, in );
        case OP_TAILCALL:    return lower_tailcall( Fn, B, in );
        case OP_RETURN:
        case OP_RETURN0:
        case OP_RETURN1:     return lower_return( Fn, B, in );

        /* --- inline loads --- */
        case OP_MOVE:        return lower_move( Fn, B, in );
        case OP_LOADI:       return lower_loadi( Fn, B, in );
        case OP_LOADF:       return lower_loadf( Fn, B, in );
        case OP_LOADKX:      return lower_loadkx( B, in );
        case OP_LOADFALSE:   return lower_loadfalse( B, in );
        case OP_LOADTRUE:    return lower_loadtrue( B, in );
        case OP_LOADNIL:     return lower_loadnil( B, in );
        case OP_LFALSESKIP:  return lower_lfalseskip( Br, in );

        /* --- arithmetic: -O1 int/float fastpath (ADD/SUB/MUL) + int-immediate
           fastpath (ADDI / ADDK / SUBK / MULK with an int constant); else the
           complete boxed helper. --- */
        case OP_ADD:   return ( Fn->cg->opt_level >= 1 )
                           ? lower_arith_fast( Fn, B, in, LC_AR_ADD, "Rt_AddOp", 1 )
                           : lower_helper3( B, in, "Rt_AddOp", 1 );
        case OP_SUB:   return ( Fn->cg->opt_level >= 1 )
                           ? lower_arith_fast( Fn, B, in, LC_AR_SUB, "Rt_SubOp", 1 )
                           : lower_helper3( B, in, "Rt_SubOp", 1 );
        case OP_MUL:   return ( Fn->cg->opt_level >= 1 )
                           ? lower_arith_fast( Fn, B, in, LC_AR_MUL, "Rt_MulOp", 1 )
                           : lower_helper3( B, in, "Rt_MulOp", 1 );
        case OP_DIV:   /* M1 elision: both operands PROVEN float -> bare divsd
                          (DIV of two floats is always a float, no metamethod). */
                       if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                            && ( in->known & LC_KNOWN_C_FLT ) ) {
                           if ( !res_f_load_xmm0( Fn, B, in->b ) ) return 0;
                           if ( !res_f_arith_xmm0( Fn, B, 0x5E, in->c ) ) return 0;
                           if ( !res_f_store_xmm0_flt( Fn, B, in->a ) ) return 0;
                           return 1;
                       }
                       return lower_helper3( B, in, "Rt_DivOp",  1 );
        case OP_MOD:   return lower_helper3( B, in, "Rt_ModOp",  1 );
        case OP_IDIV:  return lower_helper3( B, in, "Rt_IDivOp", 1 );
        case OP_POW:   return lower_helper3( B, in, "Rt_PowOp",  1 );
        case OP_ADDI:  /* PROVEN-float R[B]: bare addsd of the (possibly
                          sub-negated) immediate as a double -- exactly lvm.c's
                          ADDI float arm, luai_numadd(fa, cast_num(sC)). This is
                          the `f + 1` / `f - 1` float-loop pattern (an int imm
                          in sC range compiles to ADDI, not ADDK). */
                       if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT ) ) {
                           double   kd = ( double )( int32_t )in->c;
                           uint64_t kb; memcpy( &kb, &kd, 8 );
                           return lower_arithk_flt_elide( Fn, B, in, 0x58, kb );
                       }
                       return ( Fn->cg->opt_level >= 1 )
                           ? lower_arith_imm_fast( Fn, B, in, LC_AR_ADD, in->c, arith_mm_word( f, in ) )
                           : lower_arith_ik( B, f, in );
        case OP_ADDK:  { int32_t kv; uint64_t kb;
                         if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( Fn, B, in, 0x58, kb );
                         if ( Fn->cg->opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( Fn, B, in, LC_AR_ADD, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_SUBK:  { int32_t kv; uint64_t kb;
                         if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( Fn, B, in, 0x5C, kb );
                         if ( Fn->cg->opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( Fn, B, in, LC_AR_SUB, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_MULK:  { int32_t kv; uint64_t kb;
                         if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( Fn, B, in, 0x59, kb );
                         if ( Fn->cg->opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( Fn, B, in, LC_AR_MUL, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_DIVK:  { uint64_t kb;
                         if ( Fn->cg->opt_level >= 1 && ( in->known & LC_KNOWN_B_FLT )
                              && k_flt_bits( f, in->c, &kb ) )
                             return lower_arithk_flt_elide( Fn, B, in, 0x5E, kb );
                         return lower_arith_ik( B, f, in ); }
        case OP_MODK:  return lower_arith_ik( B, f, in );
        case OP_IDIVK: return lower_arith_ik( B, f, in );
        case OP_POWK:  return lower_arith_ik( B, f, in );

        /* --- bitwise: -O1 int fastpath (no float arm — bitwise is integer-only;
           float/non-integral operands fall to the coercing helper). --- */
        case OP_BAND:  return ( Fn->cg->opt_level >= 1 )
                           ? lower_arith_fast( Fn, B, in, LC_AR_AND, "Rt_BAndOp", 0 )
                           : lower_helper3( B, in, "Rt_BAndOp", 1 );
        case OP_BOR:   return ( Fn->cg->opt_level >= 1 )
                           ? lower_arith_fast( Fn, B, in, LC_AR_OR, "Rt_BOrOp", 0 )
                           : lower_helper3( B, in, "Rt_BOrOp",  1 );
        case OP_BXOR:  return ( Fn->cg->opt_level >= 1 )
                           ? lower_arith_fast( Fn, B, in, LC_AR_XOR, "Rt_BXorOp", 0 )
                           : lower_helper3( B, in, "Rt_BXorOp", 1 );
        case OP_SHL:   return lower_helper3( B, in, "Rt_ShlOp",  1 );
        case OP_SHR:   return lower_helper3( B, in, "Rt_ShrOp",  1 );
        case OP_BANDK: { int32_t kv;
                         if ( Fn->cg->opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( Fn, B, in, LC_AR_AND, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_BORK:  { int32_t kv;
                         if ( Fn->cg->opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( Fn, B, in, LC_AR_OR, kv, arith_mm_word( f, in ) );
                         return lower_arith_ik( B, f, in ); }
        case OP_BXORK: { int32_t kv;
                         if ( Fn->cg->opt_level >= 1 && k_int32( f, in->c, &kv ) )
                             return lower_arith_imm_fast( Fn, B, in, LC_AR_XOR, kv, arith_mm_word( f, in ) );
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
        case OP_SELF:   return lower_table_frame( B, in, "Rt_SelfF",
                                                  "Rt_Self", /*signed_c*/1 );

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
        case OP_GETFIELD:  return lower_table_frame( B, in, "Rt_GetFieldF",
                                                     "Rt_GetField", /*signed_c*/0 );
        case OP_GETI:      return lower_table_frame( B, in, "Rt_GetIF",
                                                     "Rt_GetI",     /*signed_c*/0 );
        case OP_GETTABLE:  return lower_table_frame( B, in, "Rt_GetTableF",
                                                     "Rt_GetTable", /*signed_c*/0 );
        case OP_SETFIELD:  return lower_table_frame( B, in, "Rt_SetFieldF",
                                                     "Rt_SetField", /*signed_c*/1 );
        case OP_SETI:      return lower_table_frame( B, in, "Rt_SetIF",
                                                     "Rt_SetI",     /*signed_c*/1 );
        case OP_SETTABLE:  return lower_table_frame( B, in, "Rt_SetTableF",
                                                     "Rt_SetTable", /*signed_c*/1 );
        case OP_SETTABUP:  return lower_table_frame( B, in, "Rt_SetTabUpF",
                                                     "Rt_SetTabUp", /*signed_c*/1 );
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

/* ------------------------------------------------------------------ */
/* M1 register residency — region qualification.                       */
/*                                                                      */
/* A FORLOOP region [T,P] qualifies iff EVERY body instruction is       */
/* frame-blind (its lowering provably emits no helper call): the fully- */
/* elided arith/compare forms (conditions mirrored 1:1 from the         */
/* lowerings above), MOVE/LOADI/constant loads, and branches contained  */
/* in [T,P]. The FORLOOP itself must carry the integer-loop proof. A    */
/* slot is a residency candidate only if every access to it in the      */
/* region is integer-proven (any float/unknown access marks it dirty).  */
/* Anything unrecognized rejects the region -- the boxed/elided memory  */
/* path is emitted unchanged.                                           */
/* ------------------------------------------------------------------ */
/* ------------------------------------------------------------------ */
/* Spill-around observation points.                                    */
/*                                                                      */
/* A helper-calling op inside a residency region is admissible as an    */
/* OBSERVATION POINT: all residents are spilled (value + tag) right     */
/* before it, making the frame fully current for whatever the helper    */
/* does -- GC scan, error unwind, metamethod, coroutine switch, stack   */
/* relocation. NO REFILL is needed afterwards: helpers can observe but  */
/* can never MUTATE a non-captured local's VALUE (relocation moves      */
/* addresses, not values; metamethods cannot reference this frame's     */
/* locals; captured slots are excluded from residency entirely; debug   */
/* reflection disables all proofs module-wide), so the resident         */
/* registers remain authoritative. The one mutation channel a helper    */
/* DOES have is its own frame WRITE-SET (CALL results, GETs' dest) --   */
/* those slots are marked dirty so they can never be residents.        */
/*                                                                      */
/* res_obs_op classifies an op: returns 0 (not admissible -> region     */
/* rejected), or 1 with *wr_lo..*wr_hi the frame write range (lo > hi   */
/* = none), *cmpbr set when the op branches via pc+2 (containment must  */
/* be checked), *term set for ops that LEAVE the function (the RETURN   */
/* family and TAILCALL -- spill-before still makes them sound: the      */
/* frame is current when control departs). */
/* ------------------------------------------------------------------ */
static int res_obs_op( LcInst *in, int nslots,
                       int *wr_lo, int *wr_hi, int *cmpbr, int *term ) {
    *wr_lo = 1; *wr_hi = 0; *cmpbr = 0; *term = 0;
    switch ( in->bc_op ) {
        /* helper ops writing one result slot */
        case OP_GETTABUP: case OP_GETTABLE: case OP_GETI: case OP_GETFIELD:
        case OP_GETUPVAL: case OP_NEWTABLE: case OP_CLOSURE: case OP_LOADKX:
        case OP_NOT: case OP_UNM: case OP_BNOT: case OP_LEN: case OP_CONCAT:
            *wr_lo = *wr_hi = in->a; return 1;
        case OP_SELF:
            *wr_lo = in->a; *wr_hi = in->a + 1; return 1;
        /* pure stores: no frame writes at all */
        case OP_SETTABUP: case OP_SETTABLE: case OP_SETI: case OP_SETFIELD:
        case OP_SETLIST: case OP_SETUPVAL:
            return 1;
        /* calls: results land in [A, A+C-2]; C==0 -> all-to-top */
        case OP_CALL:
            if ( in->c >= 1 ) { *wr_lo = in->a; *wr_hi = in->a + in->c - 2; }
            else              { *wr_lo = in->a; *wr_hi = nslots - 1; }
            return 1;
        /* checked-fastpath arith (elide conditions failed): one dest slot */
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
        case OP_IDIV: case OP_POW: case OP_BAND: case OP_BOR: case OP_BXOR:
        case OP_SHL: case OP_SHR:
        case OP_ADDI: case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_DIVK:
        case OP_MODK: case OP_IDIVK: case OP_POWK:
        case OP_BANDK: case OP_BORK: case OP_BXORK: case OP_SHRI: case OP_SHLI:
            *wr_lo = *wr_hi = in->a; return 1;
        /* helper comparisons: branch via pc+2 (containment checked by caller) */
        case OP_EQ: case OP_LT: case OP_LE: case OP_EQK: case OP_EQI:
        case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
            *cmpbr = 1; return 1;
        /* control leaves the function: spill-before only */
        case OP_RETURN: case OP_RETURN0: case OP_RETURN1: case OP_TAILCALL:
            *term = 1; return 1;
        default:
            return 0;   /* VARARG / nested loops / close-tbc / unknown: reject */
    }
}

#define RES_RD_INT( s ) do { int _s = ( s ); \
    if ( _s >= 0 && _s < nslots ) cnti[ _s ]++; } while ( 0 )
#define RES_RD_FLT( s ) do { int _s = ( s ); \
    if ( _s >= 0 && _s < nslots ) cntf[ _s ]++; } while ( 0 )
#define RES_RD_OTH( s ) do { int _s = ( s ); \
    if ( _s >= 0 && _s < nslots ) dirty[ _s ] = 1; } while ( 0 )
#define RES_WR_INT( s ) do { int _s = ( s ); \
    if ( _s >= La && _s <= La + 2 ) goto reject;  /* loop internals */ \
    if ( _s >= 0 && _s < nslots ) cnti[ _s ]++; } while ( 0 )
#define RES_WR_FLT( s ) do { int _s = ( s ); \
    if ( _s >= La && _s <= La + 2 ) goto reject; \
    if ( _s >= 0 && _s < nslots ) cntf[ _s ]++; } while ( 0 )
#define RES_WR_OTH( s ) do { int _s = ( s ); \
    if ( _s >= La && _s <= La + 2 ) goto reject; \
    if ( _s >= 0 && _s < nslots ) dirty[ _s ] = 1; } while ( 0 )

static int res_qualify( LcFunc *f, LcInst **map, int T, int P, LcResRegion *out ) {
    int     nslots = ( f && f->source ) ? f->source->maxstacksize : 0;
    int     La     = map[ P ]->a;
    int    *cnti   = NULL;
    int    *cntf   = NULL;
    uint8_t *dirty = NULL;
    int     pc, i, k;
    int     n_obs = 0;

    out->obs = NULL;
    if ( nslots <= 0 || La + 3 >= nslots ) return 0;
    if ( T < 1 || T > P ) return 0;
    if ( !map[ T - 1 ] || map[ T - 1 ]->bc_op != OP_FORPREP ) return 0;
    cnti  = ( int * )calloc( ( size_t )nslots, sizeof( int ) );
    cntf  = ( int * )calloc( ( size_t )nslots, sizeof( int ) );
    dirty = ( uint8_t * )calloc( ( size_t )nslots, 1 );
    out->obs = ( P > T ) ? ( uint8_t * )calloc( ( size_t )( P - T ), 1 ) : NULL;
    if ( !cnti || !cntf || !dirty || ( P > T && !out->obs ) ) goto reject;

    for ( pc = T; pc < P; pc++ ) {
        LcInst *in = map[ pc ];
        int32_t kv; uint64_t kb;
        int blind = 1;
        if ( !in ) goto reject;
        switch ( in->bc_op ) {
        /* elided arith reg-reg (mirror lower_arith_fast) */
        case OP_ADD: case OP_SUB: case OP_MUL:
            if ( ( in->known & LC_KNOWN_B_INT ) && ( in->known & LC_KNOWN_C_INT ) ) {
                RES_RD_INT( in->b ); RES_RD_INT( in->c ); RES_WR_INT( in->a );
            } else if ( ( in->known & LC_KNOWN_B_FLT ) && ( in->known & LC_KNOWN_C_FLT ) ) {
                RES_RD_FLT( in->b ); RES_RD_FLT( in->c ); RES_WR_FLT( in->a );
            } else blind = 0;                  /* checked fastpath: -> obs */
            break;
        case OP_BAND: case OP_BOR: case OP_BXOR:
            if ( ( in->known & LC_KNOWN_B_INT ) && ( in->known & LC_KNOWN_C_INT ) ) {
                RES_RD_INT( in->b ); RES_RD_INT( in->c ); RES_WR_INT( in->a );
            } else blind = 0;
            break;
        case OP_DIV:                            /* FLT/FLT divsd elide only */
            if ( ( in->known & LC_KNOWN_B_FLT ) && ( in->known & LC_KNOWN_C_FLT ) ) {
                RES_RD_FLT( in->b ); RES_RD_FLT( in->c ); RES_WR_FLT( in->a );
            } else blind = 0;
            break;
        /* elided imm/K arith (mirror the dispatch + lower_arith_imm_fast) */
        case OP_ADDI:
            if ( in->known & LC_KNOWN_B_FLT ) {
                RES_RD_FLT( in->b ); RES_WR_FLT( in->a );
            } else if ( in->known & LC_KNOWN_B_INT ) {
                RES_RD_INT( in->b ); RES_WR_INT( in->a );
            } else blind = 0;
            break;
        case OP_ADDK: case OP_SUBK: case OP_MULK:
            if ( ( in->known & LC_KNOWN_B_FLT ) && k_flt_bits( f, in->c, &kb ) ) {
                RES_RD_FLT( in->b ); RES_WR_FLT( in->a );
            } else if ( ( in->known & LC_KNOWN_B_INT ) && k_int32( f, in->c, &kv ) ) {
                RES_RD_INT( in->b ); RES_WR_INT( in->a );
            } else blind = 0;
            break;
        case OP_DIVK:
            if ( ( in->known & LC_KNOWN_B_FLT ) && k_flt_bits( f, in->c, &kb ) ) {
                RES_RD_FLT( in->b ); RES_WR_FLT( in->a );
            } else blind = 0;
            break;
        case OP_BANDK: case OP_BORK: case OP_BXORK:
            if ( ( in->known & LC_KNOWN_B_INT ) && k_int32( f, in->c, &kv ) ) {
                RES_RD_INT( in->b ); RES_WR_INT( in->a );
            } else blind = 0;
            break;
        /* elided comparisons (mirror lower_cmp); their branch must stay in */
        case OP_EQ: case OP_LT: case OP_LE:
            if ( pc + 2 > P ) goto reject;
            if ( ( in->known & LC_KNOWN_B_INT ) && ( in->known & LC_KNOWN_C_INT ) ) {
                RES_RD_INT( in->a ); RES_RD_INT( in->b );
            } else if ( ( in->known & LC_KNOWN_B_FLT ) && ( in->known & LC_KNOWN_C_FLT ) ) {
                RES_RD_FLT( in->a ); RES_RD_FLT( in->b );
            } else blind = 0;
            break;
        case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
            if ( pc + 2 > P ) goto reject;
            if ( in->known & LC_KNOWN_B_INT )      { RES_RD_INT( in->a ); }
            else if ( in->known & LC_KNOWN_B_FLT ) { RES_RD_FLT( in->a ); }
            else blind = 0;
            break;
        case OP_EQI:
            if ( pc + 2 > P ) goto reject;
            if ( in->known & LC_KNOWN_B_INT ) { RES_RD_INT( in->a ); }
            else blind = 0;                     /* float EQI: helper -> obs */
            break;
        /* frame-blind data movement */
        case OP_MOVE:
            if ( in->known & LC_KNOWN_B_INT ) {
                RES_RD_INT( in->b ); RES_WR_INT( in->a );
            } else if ( in->known & LC_KNOWN_B_FLT ) {
                RES_RD_FLT( in->b ); RES_WR_FLT( in->a );
            } else {
                RES_RD_OTH( in->b ); RES_WR_OTH( in->a );
            }
            break;
        case OP_LOADI:
            RES_WR_INT( in->a ); break;
        case OP_LOADF:
            RES_WR_FLT( in->a ); break;
        case OP_LOADK: case OP_LOADTRUE: case OP_LOADFALSE:
        case OP_LFALSESKIP:
            RES_WR_OTH( in->a ); break;
        case OP_LOADNIL:
            for ( i = in->a; i <= in->a + in->b; i++ ) RES_WR_OTH( i );
            break;
        /* metamethod-bin markers + extraarg: zero-byte no-ops in codegen --
           frame-blind by definition. EVERY binary arith op is followed by its
           MMBIN/MMBINI/MMBINK word, so without these cases no loop containing
           arithmetic could ever qualify (found while building spill-around:
           residency had only ever engaged on arith-free bodies). */
        case OP_MMBIN: case OP_MMBINI: case OP_MMBINK: case OP_EXTRAARG:
            break;
        /* contained control flow */
        case OP_JMP:
            if ( in->c < T || in->c > P ) goto reject;
            break;
        case OP_TEST:
            if ( pc + 2 > P ) goto reject;
            RES_RD_OTH( in->a ); break;
        case OP_TESTSET:
            if ( pc + 2 > P ) goto reject;
            RES_RD_OTH( in->b ); RES_WR_OTH( in->a ); break;
        default:
            blind = 0;                          /* helper-shaped: try obs */
        }
        if ( !blind ) {
            int lo, hi, cmpbr, term;
            if ( !res_obs_op( in, nslots, &lo, &hi, &cmpbr, &term ) )
                goto reject;
            if ( cmpbr && pc + 2 > P ) goto reject;   /* branch containment */
            if ( ++n_obs > 6 ) goto reject;           /* crude spill-cost cap */
            out->obs[ pc - T ] = 1;
            for ( i = lo; i <= hi && i < nslots; i++ ) { RES_WR_OTH( i ); }
        }
    }

    if ( dirty[ La ] || dirty[ La + 1 ] || dirty[ La + 2 ] ) goto reject;

    /* A slot accessed as BOTH int and float (retyped mid-region) stays in
       memory: each access is still elided per its own per-pc proof. */
    for ( i = 0; i < nslots; i++ )
        if ( cnti[ i ] && cntf[ i ] ) dirty[ i ] = 1;

    /* ENTRY-TYPE GATE (attack round 8): a candidate must be PROVEN to hold
       its class's type in the dataflow state at region entry (res_entry_int /
       res_entry_flt masks on the FORLOOP). In-region access proofs alone are
       NOT enough -- a slot whose only writes sit behind a branch can reach
       the exit spill still holding its loop-entry value, which the spill's
       unconditional retag would silently corrupt (round 8: 1.5 became
       4609434218613702656). The loop internals La..La+2 are exempt: FORPREP
       rewrote them as integers on the only edge that enters the region, and
       the body provably never writes them (checked above). Slots >= 64
       simply never qualify. */
    for ( i = 0; i < nslots; i++ ) {
        if ( i >= La && i <= La + 2 ) continue;
        if ( cnti[ i ] &&
             ( i >= 64 || !( ( map[ P ]->res_entry_int >> i ) & 1 ) ) )
            dirty[ i ] = 1;
        if ( cntf[ i ] &&
             ( i >= 64 || !( ( map[ P ]->res_entry_flt >> i ) & 1 ) ) )
            dirty[ i ] = 1;
    }

    /* the FORLOOP touches index/count/step/ctrl every iteration */
    cnti[ La ] += 1000; cnti[ La + 1 ] += 1000; cnti[ La + 2 ] += 500;
    if ( !dirty[ La + 3 ] && !cntf[ La + 3 ] ) cnti[ La + 3 ] += 1000;

    out->start = T;
    out->end   = P;
    for ( k = 0; k < LC_RES_NREGS; k++ ) {
        int best = -1, besti = -1;
        for ( i = 0; i < nslots; i++ )
            if ( !dirty[ i ] && cntf[ i ] == 0 && cnti[ i ] > 0 && cnti[ i ] > best )
                { best = cnti[ i ]; besti = i; }
        out->slot[ k ] = ( int8_t )besti;
        if ( besti >= 0 ) cnti[ besti ] = 0;    /* consumed */
    }
    for ( k = 0; k < LC_RES_NREGS; k++ ) {
        int best = -1, besti = -1;
        for ( i = 0; i < nslots; i++ )
            if ( !dirty[ i ] && cnti[ i ] == 0 && cntf[ i ] > 0 && cntf[ i ] > best )
                { best = cntf[ i ]; besti = i; }
        out->fslot[ k ] = ( int8_t )besti;
        if ( besti >= 0 ) cntf[ besti ] = 0;    /* consumed */
    }
    free( cnti ); free( cntf ); free( dirty );
    return out->slot[ 0 ] >= 0 || out->fslot[ 0 ] >= 0;
reject:
    free( cnti ); free( cntf ); free( dirty );
    free( out->obs ); out->obs = NULL;
    return 0;
}

/* Find every qualified region in `f` (fills Fn->res_regions / Fn->res_n and
   sets Fn->frame.save_xmm; must run BEFORE the prologue reads the frame). */
static void res_analyze( LcCgFnCtx *Fn, LcFunc *f ) {
    int       sizecode = ( f && f->source ) ? f->source->sizecode : 0;
    LcInst  **map;
    uint32_t  bi;
    LcInst   *in;
    int       pc;
    Fn->res_regions = NULL; Fn->res_n = 0; Fn->res_cur = -1; Fn->frame.save_xmm = 0;
    if ( Fn->cg->opt_level < 1 || sizecode <= 0 ) return;
    map = ( LcInst ** )calloc( ( size_t )sizecode, sizeof( LcInst * ) );
    if ( !map ) return;
    for ( bi = 0; bi < f->nblocks; bi++ )
        for ( in = f->blocks[ bi ]->first; in; in = in->next )
            if ( in->bc_pc >= 0 && in->bc_pc < sizecode && !map[ in->bc_pc ] )
                map[ in->bc_pc ] = in;
    for ( pc = 0; pc < sizecode; pc++ ) {
        LcInst *fl = map[ pc ];
        if ( !fl || fl->bc_op != OP_FORLOOP ) continue;
        if ( !( fl->known & LC_KNOWN_B_INT ) ) continue;
        if ( fl->c < 0 || fl->c > pc ) continue;
        {
            LcResRegion r;
            if ( res_qualify( f, map, fl->c, pc, &r ) ) {
                LcResRegion *grown = ( LcResRegion * )realloc(
                    Fn->res_regions, ( size_t )( Fn->res_n + 1 ) * sizeof( LcResRegion ) );
                if ( !grown ) break;
                Fn->res_regions = grown;
                Fn->res_regions[ Fn->res_n++ ] = r;
                if ( r.fslot[ 0 ] >= 0 ) Fn->frame.save_xmm = 1;
            }
        }
    }
    free( map );
}

static int res_emit_fills( const LcCgFnCtx *Fn, LcCodeBuf *B, int ri ) {
    int i;
    for ( i = 0; i < LC_RES_NREGS; i++ ) {
        int s = Fn->res_regions[ ri ].slot[ i ];
        int fs = Fn->res_regions[ ri ].fslot[ i ];
        if ( s >= 0 && !X64Emit_MovMemToReg( B, k_res_gpr[ i ], X64_RDI, s * 16 ) )
            return 0;
        if ( fs >= 0 && !X64Emit_MovsdLoadXmm( B, k_res_xmm[ i ], X64_RDI, fs * 16 ) )
            return 0;
    }
    return 1;
}
static int res_emit_spills( const LcCgFnCtx *Fn, LcCodeBuf *B ) {
    int i;
    for ( i = 0; i < LC_RES_NREGS; i++ ) {
        int s  = Fn->res_regions[ Fn->res_cur ].slot[ i ];
        int fs = Fn->res_regions[ Fn->res_cur ].fslot[ i ];
        if ( s >= 0 ) {
            if ( !X64Emit_MovRegToMem( B, X64_RDI, s * 16, k_res_gpr[ i ] ) ) return 0;
            if ( !X64Emit_MovImm32ToMem( B, X64_RDI, s * 16 + 8, LUA_VNUMINT ) ) return 0;
        }
        if ( fs >= 0 ) {
            if ( !X64Emit_MovsdStoreXmm( B, k_res_xmm[ i ], X64_RDI, fs * 16 ) ) return 0;
            if ( !X64Emit_MovImm32ToMem( B, X64_RDI, fs * 16 + 8, LUA_VNUMFLT ) ) return 0;
        }
    }
    return 1;
}

/* Extracted from lc_codegen so it can also be driven by the parallel worker
   pool in parallel.c. All state used here is either
   - shared read-only across workers (m, cg -- IR is frozen at codegen entry,
     LcCgCtx is const), or
   - disjoint per worker (cm->funcs[i] with a unique i per pull, and every
     other object stack-allocated inside this body). The invariant enforced by
     tools/test-codegen-no-globals.lua (zero mutable file-scope state in
     clua/src/codegen/) is what makes this safe to call from multiple threads;
     do not introduce a `static` in here that a second thread could observe.

   Returns 1 on success (populated cm->funcs[i]), 0 on any failure; on failure
   nothing is written to cm->funcs[i] (leaving zeroed calloc contents so
   lc_codemodule_free is safe). */
int LcCg_CompileFunctionBody( LcModule *m, LcCodeModule *cm,
                              const LcCgCtx *cg, uint32_t i ) {
    LcFunc *f = m->funcs[i];
    LcCompiledFunc *cf = &cm->funcs[i];
    LcCodeBuf buf;
    int ok = 1;
    int saw_return = 0;

    if (!LcCodeBuf_Init(&buf, 256)) return 0;

    /* Per-function branch context (bc_pc -> code-offset map + deferred rel32
       patch queue). Sized by the source Proto's instruction count. */
    int sizecode = (f && f->source) ? f->source->sizecode : 0;
    /* Per-function codegen state, owned by this call. Nothing here is
       file-scope any more, which is what the per-function worker needs. */
    LcCgFnCtx fnctx;
    LcCgFnCtx *Fn = &fnctx;
    lc_cg_fn_init(Fn, cg, sizecode);
    LcBranchCtx Br;
    memset(&Br, 0, sizeof(Br));
    Br.fn  = Fn;
    Br.buf = &buf;
    Br.sizecode = sizecode;
    if (sizecode > 0) {
      Br.pc_off = (size_t *)calloc((size_t)sizecode, sizeof(size_t));
      Br.seen   = (uint8_t *)calloc((size_t)sizecode, sizeof(uint8_t));
      if (!Br.pc_off || !Br.seen) {
        free(Br.pc_off); free(Br.seen);
        LcCodeBuf_Free(&buf); return 0;
      }
    }

    /* M1 register residency: qualify FORLOOP regions for this function
       BEFORE the prologue -- it decides whether xmm6..xmm10 must be saved
       (frame.save_xmm gates the prologue/epilogue xmm spill area). The savedpc
       bias was already fixed by lc_cg_fn_init, which must run before the
       prologue for the same reason: the prologue's LEA and every site's
       4*(pc+1) - bias have to use one value or they stop cancelling. */
    res_analyze(Fn, f);

    if (!LcCg_EmitPrologue(&buf, &Fn->frame)) {
      lc_cg_fn_dispose(Fn);
      free(Br.pc_off); free(Br.seen); free(Br.fwd);
      LcCodeBuf_Free(&buf); return 0;
    }

    for (uint32_t bi = 0; ok && f && bi < f->nblocks; bi++) {
      LcInst *in;
      for (in = f->blocks[bi]->first; in; in = in->next) {
        if (in->op == LC_OP_RETURN) saw_return = 1;
        /* Region entry: fill the cache registers BEFORE the back-edge label
           is recorded, so the fills run once on the FORPREP fall-in and the
           FORLOOP back-edge skips them. */
        if (Fn->res_cur < 0) {
          for (int ri = 0; ri < Fn->res_n; ri++) {
            if (Fn->res_regions[ri].start == in->bc_pc) {
              if (!res_emit_fills( Fn,&buf, ri)) { ok = 0; }
              Fn->res_cur = ri;
              break;
            }
          }
          if (!ok) break;
        }
        /* Record this bytecode pc -> current code offset BEFORE lowering, so
           backward branches and the pc->offset resolution see the right base. */
        LcBr_RecordPc(&Br, in->bc_pc, buf.used);
        /* Observation point: make the frame fully current before the helper
           runs (residents stay authoritative afterwards -- no refill; see the
           spill-around block comment). Emitted AFTER the pc label so a branch
           to this pc also passes through the spill. */
        if (Fn->res_cur >= 0) {
          const LcResRegion *rg = &Fn->res_regions[Fn->res_cur];
          if (in->bc_pc >= rg->start && in->bc_pc < rg->end &&
              rg->obs && rg->obs[in->bc_pc - rg->start]) {
            if (!res_emit_spills( Fn,&buf)) { ok = 0; break; }
          }
        }
        if (!lower_inst(&Br, f, in)) { ok = 0; break; }
        /* Region exit: the FORLOOP's fall-through (count==0) lands here --
           spill values + INT tags before the next pc's label is recorded.
           The zero-trip FORPREP branch targets that next pc, skipping both
           fill and spill (the frame was never stale on that path). */
        if (Fn->res_cur >= 0 && in->bc_pc == Fn->res_regions[Fn->res_cur].end) {
          if (!res_emit_spills( Fn,&buf)) { ok = 0; break; }
          Fn->res_cur = -1;
        }
      }
    }
    lc_cg_fn_dispose(Fn);

    /* If the function fell through without an explicit RETURN (shouldn't
       happen for epsilon, but keep codegen total), emit a default 0-result
       return + epilogue so the body always terminates. */
    if (ok && !saw_return) {
      if (!LcCg_EmitHelperCall3(&buf, "Rt_PrepReturn", 0, 0, 0, /*reload*/0) ||
          !LcCg_EmitEpilogue(&buf, &Fn->frame)) {
        ok = 0;
      }
    }

    /* Resolve all deferred forward branches now that every pc has an offset.
       MUST run before we take ownership of buf.bytes. */
    if (ok && !LcBr_Resolve(&Br)) { ok = 0; }

    free(Br.pc_off); free(Br.seen); free(Br.fwd);

    if (!ok) { LcCodeBuf_Free(&buf); return 0; }

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
    return 1;
}

/* Job-count discovery: -j on the command line wins, then CLUA_JOBS env, then
   the CPU count. Clamped to nfuncs -- more workers than functions is dead
   overhead, and 1 (or below) collapses to the sequential path. Kept in
   codegen.c so lc_codegen honours the env var without pulling the priority
   logic into parallel.c. */
static int lc_codegen_pick_jobs( const LcModule *m, uint32_t nfuncs ) {
    int jobs;
    const char *env;
    SYSTEM_INFO si;

    /* Explicit -j from the driver wins; a zero (default calloc) means the
       caller wants the env / cpu count logic. A driver that passes 1
       explicitly gets the sequential path (which is the point of -j 1). */
    if ( m != NULL && m->jobs > 0 ) {
        jobs = m->jobs;
    } else {
        env = getenv( "CLUA_JOBS" );
        if ( env != NULL && env[0] != '\0' ) {
            jobs = atoi( env );
            if ( jobs < 1 ) jobs = 1;
        } else {
            GetSystemInfo( &si );
            jobs = ( int )si.dwNumberOfProcessors;
            if ( jobs < 1 ) jobs = 1;
        }
    }
    if ( ( uint32_t )jobs > nfuncs ) jobs = ( int )nfuncs;
    if ( jobs < 1 ) jobs = 1;
    return jobs;
}

LcCodeModule *lc_codegen(LcModule *m) {
  if (!m) return NULL;
  /* Per-compilation configuration: set once here, then read-only for the whole
     run, so a future worker can share it by const pointer. */
  LcCgCtx cg;
  cg.opt_level = m->opt_level;        /* -O1+ enables the M1 arith fastpaths */
  LcCodeModule *cm = (LcCodeModule *)calloc(1, sizeof(LcCodeModule));
  if (!cm) return NULL;
  cm->nfuncs = m->nfuncs;
  cm->rodata = NULL;        /* epsilon: no .rdata — constants come from the    */
  cm->rodata_len = 0;       /* runtime Proto via ci (see lower_const).         */
  if (cm->nfuncs == 0) return cm;

  cm->funcs = (LcCompiledFunc *)calloc(cm->nfuncs, sizeof(LcCompiledFunc));
  if (!cm->funcs) { free(cm); return NULL; }

  /* Parallel path: env-selected job count, silently no-op'd to sequential if
     jobs == 1 or only one function. Byte-identity requires the SAME bytes for
     the same input regardless of the value of jobs; that is why every op that
     touches shared state was moved off file scope in the codegen arc. */
  {
    int jobs = lc_codegen_pick_jobs( m, cm->nfuncs );
    if ( jobs > 1 ) {
      if ( !LcCg_RunParallel( m, cm, &cg, jobs ) ) {
        lc_codemodule_free( cm );
        return NULL;
      }
      return cm;
    }
  }

  /* Sequential path -- byte-identical to what this file did before parallel
     codegen landed, and the fallback when jobs collapses to 1. */
  for (uint32_t i = 0; i < m->nfuncs; i++) {
    if (!LcCg_CompileFunctionBody(m, cm, &cg, i)) {
      lc_codemodule_free(cm);
      return NULL;
    }
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
  free(cm->protoblob);
  free(cm);
}
