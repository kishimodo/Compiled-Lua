#include "jit/codegen.h"
#include "jit/emit_x64.h"
#include "jit/regalloc.h"
#include "jit/runtime.h"
#include "jit/codegen_ffi.h"
#include "ffi/ffi_load.h"
#include "ffi/ctype.h"

#include "lstate.h"
#include "lopcodes.h"
#include "lobject.h"
#include "lstring.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* Set per-call by Codegen_EmitFunction; consulted by Lower_* helpers via
   the RegAlloc_* helpers. NULL when no compilation is in flight. */
static PREGALLOC_T  g_CurrentRegAlloc = NULL;
static KNOWN_FFI_T *g_CurrentKnownFfi = NULL;

/* Compute the offset of L->ci within lua_State at compile time */
#define OFFSET_OF_CI ( ( int32_t )offsetof( struct lua_State, ci ) )
/* Within a CallInfo, .func is StkIdRel which has a `.p` (StkId == StackValue*) */
#define OFFSET_OF_CI_FUNC ( ( int32_t )offsetof( CallInfo, func ) )
/* ci->u.l.savedpc: the program-counter snapshot luaG_traceback reads to map a
   running Lua frame back to a source line (R2.4 -- accurate JIT tracebacks). */
#define OFFSET_OF_CI_SAVEDPC ( ( int32_t )offsetof( CallInfo, u.l.savedpc ) )

/*!
 * @brief
 *  Forward-jump patch list. Each RETURN opcode emits a JMP placeholder and
 *  records its position here; after the opcode loop the epilogue is laid
 *  out and every placeholder is patched to its address.
 */
#define MAX_EPILOG_JUMPS 256
typedef struct _EPILOG_PATCHES {
    size_t Offsets[ MAX_EPILOG_JUMPS ];
    size_t Count;
} EPILOG_PATCHES_T, *PEPILOG_PATCHES_T;

static int Patches_Add( PEPILOG_PATCHES_T P, size_t Offset ) {
    if ( P->Count >= MAX_EPILOG_JUMPS ) {
        fprintf( stderr, "[-] jit: too many epilog jumps\n" );
        return 0;
    }
    P->Offsets[ P->Count++ ] = Offset;
    return 1;
}

static int Patches_Resolve( PEPILOG_PATCHES_T P, PEXEC_MEM_SLOT_T Slot, size_t Target ) {
    size_t I = { 0 };
    for ( I = 0; I < P->Count; I++ ) {
        /* rel32 — fib-sized functions easily exceed rel8 range from
           mid-function RETURN sites to the epilogue at the end */
        if ( !EmitX64_PatchRel32( Slot, P->Offsets[ I ], Target ) ) {
            fprintf( stderr, "[-] jit: epilog jump %zu out of rel32 range\n", I );
            return 0;
        }
    }
    return 1;
}

/*!
 * @brief
 *  Per-function PC offset table and forward-branch patch queue. PcOffsets[i]
 *  records the byte offset of the i-th Lua opcode's first emitted byte.
 *  ForwardJumps queues rel32 patches that target Lua PCs not yet emitted
 *  (loops, forward branches); they're resolved after the opcode loop.
 */
#define MAX_PROTO_OPCODES 4096
#define MAX_FWD_JUMPS     1024

typedef struct _FWD_JUMP {
    size_t PatchOffset;   /* offset of the disp word in Slot->Code */
    int    TargetPc;      /* Lua PC the jump lands on */
    int    IsRel8;        /* 1 = rel8 patch, 0 = rel32 patch */
} FWD_JUMP_T, *PFWD_JUMP_T;

typedef struct _BRANCH_CTX {
    size_t       PcOffsets[ MAX_PROTO_OPCODES ];
    int          PcCount;
    FWD_JUMP_T   Fwds[ MAX_FWD_JUMPS ];
    int          FwdCount;
} BRANCH_CTX_T, *PBRANCH_CTX_T;

static int BranchCtx_RecordPc( PBRANCH_CTX_T Ctx, int Pc, size_t Offset ) {
    if ( Pc < 0 || Pc >= MAX_PROTO_OPCODES ) { return 0; }
    Ctx->PcOffsets[ Pc ] = Offset;
    if ( Pc + 1 > Ctx->PcCount ) { Ctx->PcCount = Pc + 1; }
    return 1;
}

static int BranchCtx_AddFwd( PBRANCH_CTX_T Ctx, size_t PatchOffset, int TargetPc, int IsRel8 ) {
    if ( Ctx->FwdCount >= MAX_FWD_JUMPS ) {
        fprintf( stderr, "[-] jit: too many forward jumps\n" );
        return 0;
    }
    Ctx->Fwds[ Ctx->FwdCount ].PatchOffset = PatchOffset;
    Ctx->Fwds[ Ctx->FwdCount ].TargetPc    = TargetPc;
    Ctx->Fwds[ Ctx->FwdCount ].IsRel8      = IsRel8;
    Ctx->FwdCount++;
    return 1;
}

static int BranchCtx_Resolve( PBRANCH_CTX_T Ctx, PEXEC_MEM_SLOT_T Slot ) {
    int I = { 0 };
    for ( I = 0; I < Ctx->FwdCount; I++ ) {
        FWD_JUMP_T *J = &Ctx->Fwds[ I ];
        if ( J->TargetPc < 0 || J->TargetPc >= Ctx->PcCount ) {
            fprintf( stderr, "[-] jit: forward jump targets invalid PC %d\n", J->TargetPc );
            return 0;
        }
        size_t Target = Ctx->PcOffsets[ J->TargetPc ];
        int    Ok     = J->IsRel8
                      ? EmitX64_PatchRel8 ( Slot, J->PatchOffset, Target )
                      : EmitX64_PatchRel32( Slot, J->PatchOffset, Target );
        if ( !Ok ) {
            fprintf( stderr, "[-] jit: forward jump %d out of range\n", I );
            return 0;
        }
    }
    return 1;
}

/*!
 * @brief
 *  Emit the function prologue. Saves all callee-saved registers we use, sets
 *  up RBX = L and RDI = ci->func.p + 1, then loads initial values for any
 *  Lua registers assigned to cache GPRs.
 *
 *  Stack layout: 7 pushes (56 bytes) + return address (8) = 64.
 *  sub rsp, 0x20 (32) -> 96 total, which is 16-aligned.
 */
static int EmitPrologue( PEXEC_MEM_SLOT_T Slot ) {
    /* save all callee-saved registers we'll use: RBX (L), RDI (regbase),
       then R12-R15 and RSI (cache regs) */
    if ( !EmitX64_PushReg( Slot, X64_RDI ) ) return 0;
    if ( !EmitX64_PushReg( Slot, X64_RBX ) ) return 0;
    if ( !EmitX64_PushReg( Slot, X64_R12 ) ) return 0;
    if ( !EmitX64_PushReg( Slot, X64_R13 ) ) return 0;
    if ( !EmitX64_PushReg( Slot, X64_R14 ) ) return 0;
    if ( !EmitX64_PushReg( Slot, X64_R15 ) ) return 0;
    if ( !EmitX64_PushReg( Slot, X64_RSI ) ) return 0;
    /* 7 pushes = 56 bytes; with return address (8) = 64; +0x20 shadow = 96, 16-aligned */
    if ( !EmitX64_SubRspImm( Slot, 0x20 ) )  return 0;
    /* rbx = rcx (save L in a callee-saved register; rcx is volatile across calls) */
    if ( !EmitX64_MovRegToReg( Slot, X64_RBX, X64_RCX ) ) return 0;
    /* rax = [rcx + OFFSET_OF_CI] */
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RCX, OFFSET_OF_CI ) ) return 0;
    /* rax = [rax + OFFSET_OF_CI_FUNC] */
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RAX, OFFSET_OF_CI_FUNC ) ) return 0;
    /* rdi = rax */
    if ( !EmitX64_MovRegToReg( Slot, X64_RDI, X64_RAX ) ) return 0;
    /* ADD RDI, 16 (imm32 form): 48 81 C7 10 00 00 00 */
    unsigned char AddRdi16[ ] = { 0x48, 0x81, 0xC7, 0x10, 0x00, 0x00, 0x00 };
    if ( !ExecMem_Append( Slot, AddRdi16, sizeof( AddRdi16 ) ) ) return 0;

    /* load initial values for cached Lua registers from memory into their GPRs */
    if ( g_CurrentRegAlloc != NULL ) {
        int I = { 0 };
        for ( I = 0; I < g_CurrentRegAlloc->NumCached; I++ ) {
            int       LuaReg = g_CurrentRegAlloc->CacheSlotLuaReg[ I ];
            X64_GPR_T XReg   = g_CurrentRegAlloc->CachePool[ I ];
            if ( LuaReg < 0 ) continue;
            /* mov XReg, [rdi + LuaReg * 16]  — load value half (offset 0); tag stays in memory */
            if ( !EmitX64_MovMemToReg( Slot, XReg, X64_RDI, LuaReg * 16 ) ) return 0;
        }
    }
    return 1;
}

/*!
 * @brief
 *  Emit the function epilogue. RAX holds the return count; restore all
 *  callee-saved registers in reverse push order and return.
 */
static int EmitEpilogue( PEXEC_MEM_SLOT_T Slot ) {
    if ( !EmitX64_AddRspImm( Slot, 0x20 ) )  return 0;
    if ( !EmitX64_PopReg( Slot, X64_RSI ) )  return 0;
    if ( !EmitX64_PopReg( Slot, X64_R15 ) )  return 0;
    if ( !EmitX64_PopReg( Slot, X64_R14 ) )  return 0;
    if ( !EmitX64_PopReg( Slot, X64_R13 ) )  return 0;
    if ( !EmitX64_PopReg( Slot, X64_R12 ) )  return 0;
    if ( !EmitX64_PopReg( Slot, X64_RBX ) )  return 0;
    if ( !EmitX64_PopReg( Slot, X64_RDI ) )  return 0;
    if ( !EmitX64_Ret( Slot ) )              return 0;
    return 1;
}

/* Restore L (first argument) into RCX from RBX before a helper call.
   RBX is callee-saved and holds L since the prologue; RCX is volatile. */
static int EmitRestoreL( PEXEC_MEM_SLOT_T Slot ) {
    return EmitX64_MovRegToReg( Slot, X64_RCX, X64_RBX );
}

/*!
 * @brief
 *  After a helper call that may have mutated Lua register memory, reload
 *  every cache register from its memory slot to resync.
 *
 *  Note: helpers like Rt_VarargPrep RELOCATE ci->func.p — after such helpers
 *  RDI is also stale. Those call sites should use EmitReloadRdiAndCache
 *  instead. This helper assumes RDI is current.
 */
static int EmitReloadCacheAll( PEXEC_MEM_SLOT_T Slot ) {
    if ( g_CurrentRegAlloc == NULL ) return 1;
    int I = { 0 };
    for ( I = 0; I < g_CurrentRegAlloc->NumCached; I++ ) {
        int       LuaReg = g_CurrentRegAlloc->CacheSlotLuaReg[ I ];
        X64_GPR_T XReg   = g_CurrentRegAlloc->CachePool[ I ];
        if ( LuaReg < 0 ) continue;
        if ( !EmitX64_MovMemToReg( Slot, XReg, X64_RDI, LuaReg * 16 ) ) return 0;
    }
    return 1;
}

/*!
 * @brief
 *  For helpers that can RELOCATE the lua stack (Rt_VarargPrep, anything
 *  that may trigger checkstackGCp / GC shrink — Rt_GetField/Rt_GetTable
 *  via cdata __index, Rt_NewClosure via luaC_checkGC, Rt_NewTable, etc):
 *  re-derive RDI from L->ci->func.p+16 then reload cache.
 *
 *  Use this instead of EmitReloadCacheAll whenever the called helper
 *  might end up in code that grows or shrinks the Lua stack.
 */
static int EmitReloadRdiAndCache( PEXEC_MEM_SLOT_T Slot ) {
    if ( !EmitRestoreL( Slot ) ) return 0;  /* rcx = rbx */
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RCX, OFFSET_OF_CI ) ) return 0;
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RAX, OFFSET_OF_CI_FUNC ) ) return 0;
    if ( !EmitX64_MovRegToReg( Slot, X64_RDI, X64_RAX ) ) return 0;
    unsigned char AddRdi16[ ] = { 0x48, 0x81, 0xC7, 0x10, 0x00, 0x00, 0x00 };
    if ( !ExecMem_Append( Slot, AddRdi16, sizeof( AddRdi16 ) ) ) return 0;
    return EmitReloadCacheAll( Slot );
}

/*!
 * @brief
 *  R2.4 -- store ci->u.l.savedpc so an error raised from this instruction
 *  (or any callee it invokes) yields an accurate file:line traceback, matching
 *  the interpreter. savedpc points one *past* the current instruction because
 *  luaG_traceback computes the line via pcRel = (savedpc - p->code) - 1; the
 *  interpreter advances savedpc before executing, so this mirrors it exactly.
 *
 *  Proto->code is allocated once and never relocated while the function is
 *  callable, so embedding the absolute &P->code[Pc+1] is safe (Rt_Call seeds
 *  ci->u.l.savedpc from the same proto code pointer). Clobbers only RAX/R11 --
 *  both scratch at instruction entry -- and leaves the Lua-register cache and
 *  L (RBX) / base (RDI) untouched, so it composes before any Lower_*.
 */
static int EmitStoreSavedPc( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    const Instruction *Target = P->code + Pc + 1;
    /* rax = L->ci  (rbx holds L for the whole function body) */
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RBX, OFFSET_OF_CI ) ) return 0;
    /* r11 = &P->code[Pc+1] */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R11, ( uint64_t )( uintptr_t )Target ) ) return 0;
    /* ci->u.l.savedpc = r11 */
    if ( !EmitX64_MovRegToMem( Slot, X64_RAX, OFFSET_OF_CI_SAVEDPC, X64_R11 ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  True for opcodes that can raise a Lua error -- directly (arithmetic/index
 *  type errors, concat, length) or transitively through a call/metamethod.
 *  Only these need a savedpc update; excluding the hot, non-throwing ops
 *  (register moves, constant loads, branches, the integer FORLOOP back-edge,
 *  upvalue access) keeps loop bodies tight. EXTRAARG/MMBIN* are inert trailers.
 */
static int OpcodeNeedsSavedPc( int Op ) {
    switch ( Op ) {
        case OP_MOVE:      case OP_LOADI:     case OP_LOADF:
        case OP_LOADK:     case OP_LOADKX:    case OP_LOADFALSE:
        case OP_LFALSESKIP:case OP_LOADTRUE:  case OP_LOADNIL:
        case OP_GETUPVAL:  case OP_SETUPVAL:  case OP_JMP:
        case OP_TEST:      case OP_TESTSET:   case OP_FORLOOP:
        case OP_TFORLOOP:  case OP_MMBIN:     case OP_MMBINI:
        case OP_MMBINK:    case OP_EXTRAARG:
            return 0;
        default:
            return 1;
    }
}

/*!
 * @brief
 *  Emit a write-through to Lua register LuaReg: if it's cached, copy the
 *  RAX value to its cache reg; in all cases also store RAX to memory.
 *  Assumes RAX holds the new value.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param LuaReg
 *  Lua register index to write
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int EmitWriteThroughRax( PEXEC_MEM_SLOT_T Slot, int LuaReg ) {
    /* memory write: mov [rdi + LuaReg * 16], rax */
    if ( !EmitX64_MovRegToMem( Slot, X64_RDI, LuaReg * 16, X64_RAX ) ) return 0;
    /* cache write: if assigned, mov XReg, rax */
    X64_GPR_T XReg = { 0 };
    if ( g_CurrentRegAlloc != NULL &&
         RegAlloc_IsCached( g_CurrentRegAlloc, LuaReg, &XReg ) ) {
        if ( !EmitX64_MovRegToReg( Slot, XReg, X64_RAX ) ) return 0;
    }
    return 1;
}

/*!
 * @brief
 *  Emit a load into RAX from Lua register LuaReg: if cached, read from
 *  the cache reg; else from memory.
 *
 *  Note: do NOT wire this into call sites until ALL register writes are
 *  write-through and every helper call is followed by a cache reload.
 *  Until then, the cache reg can be stale and reads will return garbage.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param LuaReg
 *  Lua register index to read
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int EmitLoadRaxFromLua( PEXEC_MEM_SLOT_T Slot, int LuaReg ) {
    X64_GPR_T XReg = { 0 };
    if ( g_CurrentRegAlloc != NULL &&
         RegAlloc_IsCached( g_CurrentRegAlloc, LuaReg, &XReg ) ) {
        return EmitX64_MovRegToReg( Slot, X64_RAX, XReg );
    }
    return EmitX64_MovMemToReg( Slot, X64_RAX, X64_RDI, LuaReg * 16 );
}

/* per-opcode lowering forwards — implemented in later tasks of this plan */
static int EmitCall1ArgHelper( PEXEC_MEM_SLOT_T Slot, int A, void *Helper );
static int Lower_LoadI    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Add      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Sub      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Mul      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Call     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Return   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PEPILOG_PATCHES_T Patches );
static int Lower_Return0  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PEPILOG_PATCHES_T Patches );
static int Lower_Return1  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PEPILOG_PATCHES_T Patches );
static int Lower_TailCall ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PEPILOG_PATCHES_T Patches );
static int Lower_Move     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_LoadK    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_LoadFalse( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_LoadTrue ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_LoadNil  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_GetTabUp ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_GetUpval ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_SetUpval ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Closure  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Jmp      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches );
static int Lower_Eq       ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Lt       ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Le       ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_ForPrep  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches );
static int Lower_ForLoop  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches );
static int Lower_NewTable ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_GetI     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_SetI     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_GetField ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_SetField ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_GetTable ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_SetTable ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_SetTabUp ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Len      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Concat   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_SetList  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, int *ExtraPc );
static int Lower_Test     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_TestSet  ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Eqi      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Lti      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Lei      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Gti      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Gei      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Eqk      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_Vararg   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_NotOp    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_UnmOp    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_BNotOp   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_DivOp    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_ModOp    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_IDivOp   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_PowOp    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_AddI     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_AddK     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_SubK     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_MulK     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_DivK     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_ModK     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_IDivK    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_PowK     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_BAnd     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_BOr      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_BXor     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Shl      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Shr      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_BAndK    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_BOrK     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_BXorK    ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_ShrI     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_ShlI     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_LoadF      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_LFalseSkip ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc );
static int Lower_LoadKX     ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, int *ExtraPc );
static int Lower_Self       ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Tbc        ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_Close      ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_VarargPrep ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_TForPrep   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches );
static int Lower_TForCall   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc );
static int Lower_TForLoop   ( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches );

static int CodegenInternal( PEXEC_MEM_SLOT_T Slot, Proto *P, size_t *OutPcToOffset );

/* clear KnownFfi entry for register A on any opcode that writes R[A] */
static void ClearKnownFfi( int A ) {
    if ( g_CurrentKnownFfi != NULL ) {
        KnownFfi_Clear( g_CurrentKnownFfi, A );
    }
}

int Codegen_EmitFunction( PEXEC_MEM_SLOT_T Slot,
                          Proto *P,
                          PREGALLOC_T RegAlloc,
                          size_t *OutPcToOffset ) {
    KNOWN_FFI_T LocalKnownFfi = { 0 };
    KnownFfi_Reset( &LocalKnownFfi );
    g_CurrentRegAlloc = RegAlloc;
    g_CurrentKnownFfi = &LocalKnownFfi;
    int Ok = CodegenInternal( Slot, P, OutPcToOffset );
    g_CurrentRegAlloc = NULL;
    g_CurrentKnownFfi = NULL;
    return Ok;
}

static int CodegenInternal( PEXEC_MEM_SLOT_T Slot, Proto *P, size_t *OutPcToOffset ) {
    EPILOG_PATCHES_T Patches      = { 0 };
    BRANCH_CTX_T     Branches     = { 0 };
    int              Pc           = { 0 };
    size_t           EpilogOffset = { 0 };

    /* Reject Protos bigger than the fixed PC-offset table BEFORE emitting. For
       Pc >= MAX_PROTO_OPCODES, BranchCtx_RecordPc silently no-ops (it returns 0,
       but the loop below ignores that), leaving PcOffsets[Pc] unwritten -- a
       forward branch into that range then resolves against a garbage offset and
       hard-segfaults. Declining here makes the compile hook return NULL, which
       routes the Proto to the bytecode-interpreter fallback in luaV_execute (a
       correct, slower path) instead of crashing the process. The forward-jump
       limit (MAX_FWD_JUMPS) is already handled gracefully by BranchCtx_AddFwd. */
    if ( P->sizecode > MAX_PROTO_OPCODES ) {
        fprintf( stderr, "[*] jit: proto too large (%d opcodes > %d) -- using interpreter\n",
                 ( int )P->sizecode, MAX_PROTO_OPCODES );
        return 0;
    }

    if ( !EmitPrologue( Slot ) ) {
        fprintf( stderr, "[-] codegen: prologue failed\n" );
        return 0;
    }
    for ( Pc = 0; Pc < P->sizecode; Pc++ ) {
        BranchCtx_RecordPc( &Branches, Pc, Slot->Used );
        int Op      = GET_OPCODE( P->code[ Pc ] );
        int Ok      = 0;
        int ExtraPc = 0;
        /* R2.4: keep ci->u.l.savedpc current before any throw-capable op so a
           raised error maps to the right source line. Emitted after RecordPc,
           so the recorded Pc->offset (a branch target) spans this store and a
           back-edge re-runs it harmlessly. */
        if ( OpcodeNeedsSavedPc( Op ) && !EmitStoreSavedPc( Slot, P, Pc ) ) {
            fprintf( stderr, "[-] codegen: savedpc store failed at pc %d\n", Pc );
            return 0;
        }
        switch ( Op ) {
            case OP_MOVE:      Ok = Lower_Move     ( Slot, P, Pc ); break;
            case OP_LOADK:     Ok = Lower_LoadK    ( Slot, P, Pc ); break;
            case OP_LOADFALSE: Ok = Lower_LoadFalse( Slot, P, Pc ); break;
            case OP_LOADTRUE:  Ok = Lower_LoadTrue ( Slot, P, Pc ); break;
            case OP_LOADNIL:   Ok = Lower_LoadNil  ( Slot, P, Pc ); break;
            case OP_LOADI:     Ok = Lower_LoadI    ( Slot, P, Pc ); break;
            case OP_ADD:       Ok = Lower_Add      ( Slot, P, Pc ); break;
            case OP_SUB:       Ok = Lower_Sub      ( Slot, P, Pc ); break;
            case OP_MUL:       Ok = Lower_Mul      ( Slot, P, Pc ); break;
            case OP_CALL:      Ok = Lower_Call     ( Slot, P, Pc ); break;
            case OP_TAILCALL:  Ok = Lower_TailCall ( Slot, P, Pc, &Patches ); break;
            case OP_VARARG:     Ok = Lower_Vararg   ( Slot, P, Pc ); break;
            case OP_MMBIN:      Ok = 1; break;
            case OP_MMBINI:     Ok = 1; break;
            case OP_MMBINK:     Ok = 1; break;
            case OP_VARARGPREP: Ok = Lower_VarargPrep( Slot, P, Pc ); break;
            case OP_RETURN:    Ok = Lower_Return   ( Slot, P, Pc, &Patches ); break;
            case OP_RETURN0:   Ok = Lower_Return0  ( Slot, P, Pc, &Patches ); break;
            case OP_RETURN1:   Ok = Lower_Return1  ( Slot, P, Pc, &Patches ); break;
            case OP_GETTABUP:  Ok = Lower_GetTabUp ( Slot, P, Pc ); break;
            case OP_GETUPVAL:  Ok = Lower_GetUpval ( Slot, P, Pc ); break;
            case OP_SETUPVAL:  Ok = Lower_SetUpval ( Slot, P, Pc ); break;
            case OP_CLOSURE:   Ok = Lower_Closure  ( Slot, P, Pc ); break;
            case OP_JMP:       Ok = Lower_Jmp      ( Slot, P, Pc, &Branches ); break;
            case OP_EQ:        Ok = Lower_Eq       ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_LT:        Ok = Lower_Lt       ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_LE:        Ok = Lower_Le       ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_TEST:      Ok = Lower_Test     ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_TESTSET:   Ok = Lower_TestSet  ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_EQI:       Ok = Lower_Eqi      ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_LTI:       Ok = Lower_Lti      ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_LEI:       Ok = Lower_Lei      ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_GTI:       Ok = Lower_Gti      ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_GEI:       Ok = Lower_Gei      ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_EQK:       Ok = Lower_Eqk      ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_FORPREP:   Ok = Lower_ForPrep  ( Slot, P, Pc, &Branches ); break;
            case OP_FORLOOP:   Ok = Lower_ForLoop  ( Slot, P, Pc, &Branches ); break;
            case OP_NEWTABLE:  Ok = Lower_NewTable ( Slot, P, Pc ); break;
            case OP_EXTRAARG:  Ok = 1; break;  /* no-op: metadata trailer for NEWTABLE etc. */
            case OP_GETI:      Ok = Lower_GetI     ( Slot, P, Pc ); break;
            case OP_SETI:      Ok = Lower_SetI     ( Slot, P, Pc ); break;
            case OP_GETFIELD:  Ok = Lower_GetField ( Slot, P, Pc ); break;
            case OP_SETFIELD:  Ok = Lower_SetField ( Slot, P, Pc ); break;
            case OP_GETTABLE:  Ok = Lower_GetTable ( Slot, P, Pc ); break;
            case OP_SETTABLE:  Ok = Lower_SetTable ( Slot, P, Pc ); break;
            case OP_SETTABUP:  Ok = Lower_SetTabUp ( Slot, P, Pc ); break;
            case OP_LEN:       Ok = Lower_Len      ( Slot, P, Pc ); break;
            case OP_CONCAT:    Ok = Lower_Concat   ( Slot, P, Pc ); break;
            case OP_SETLIST:   Ok = Lower_SetList  ( Slot, P, Pc, &ExtraPc ); break;
            case OP_NOT:       Ok = Lower_NotOp    ( Slot, P, Pc ); break;
            case OP_UNM:       Ok = Lower_UnmOp    ( Slot, P, Pc ); break;
            case OP_BNOT:      Ok = Lower_BNotOp   ( Slot, P, Pc ); break;
            case OP_DIV:       Ok = Lower_DivOp    ( Slot, P, Pc ); break;
            case OP_MOD:       Ok = Lower_ModOp    ( Slot, P, Pc ); break;
            case OP_IDIV:      Ok = Lower_IDivOp   ( Slot, P, Pc ); break;
            case OP_POW:       Ok = Lower_PowOp    ( Slot, P, Pc ); break;
            case OP_ADDI:      Ok = Lower_AddI     ( Slot, P, Pc ); break;
            case OP_ADDK:      Ok = Lower_AddK     ( Slot, P, Pc ); break;
            case OP_SUBK:      Ok = Lower_SubK     ( Slot, P, Pc ); break;
            case OP_MULK:      Ok = Lower_MulK     ( Slot, P, Pc ); break;
            case OP_DIVK:      Ok = Lower_DivK     ( Slot, P, Pc ); break;
            case OP_MODK:      Ok = Lower_ModK     ( Slot, P, Pc ); break;
            case OP_IDIVK:     Ok = Lower_IDivK    ( Slot, P, Pc ); break;
            case OP_POWK:      Ok = Lower_PowK     ( Slot, P, Pc ); break;
            case OP_BAND:      Ok = Lower_BAnd     ( Slot, P, Pc ); break;
            case OP_BOR:       Ok = Lower_BOr      ( Slot, P, Pc ); break;
            case OP_BXOR:      Ok = Lower_BXor     ( Slot, P, Pc ); break;
            case OP_SHL:       Ok = Lower_Shl      ( Slot, P, Pc ); break;
            case OP_SHR:       Ok = Lower_Shr      ( Slot, P, Pc ); break;
            case OP_BANDK:     Ok = Lower_BAndK    ( Slot, P, Pc ); break;
            case OP_BORK:      Ok = Lower_BOrK     ( Slot, P, Pc ); break;
            case OP_BXORK:     Ok = Lower_BXorK    ( Slot, P, Pc ); break;
            case OP_SHRI:      Ok = Lower_ShrI     ( Slot, P, Pc ); break;
            case OP_SHLI:      Ok = Lower_ShlI     ( Slot, P, Pc ); break;
            case OP_LOADF:      Ok = Lower_LoadF      ( Slot, P, Pc ); break;
            case OP_LFALSESKIP: Ok = Lower_LFalseSkip ( Slot, P, Pc, &Branches, &ExtraPc ); break;
            case OP_LOADKX:     Ok = Lower_LoadKX     ( Slot, P, Pc, &ExtraPc ); break;
            case OP_SELF:       Ok = Lower_Self       ( Slot, P, Pc ); break;
            case OP_TBC:        Ok = Lower_Tbc        ( Slot, P, Pc ); break;
            case OP_CLOSE:      Ok = Lower_Close      ( Slot, P, Pc ); break;
            case OP_TFORPREP:   Ok = Lower_TForPrep   ( Slot, P, Pc, &Branches ); break;
            case OP_TFORCALL:   Ok = Lower_TForCall   ( Slot, P, Pc ); break;
            case OP_TFORLOOP:   Ok = Lower_TForLoop   ( Slot, P, Pc, &Branches ); break;
            default:
                fprintf( stderr, "[-] codegen: unhandled opcode %d at pc %d\n", Op, Pc );
                return 0;
        }
        if ( !Ok ) {
            fprintf( stderr, "[-] codegen: emit failed at pc %d (opcode %d, slot %zu/%zu bytes)\n",
                     Pc, Op, Slot->Used, Slot->Size );
            return 0;
        }
        Pc += ExtraPc;
    }

    if ( !BranchCtx_Resolve( &Branches, Slot ) ) return 0;

    /* Lay out the epilogue and resolve all RETURN jumps to its address. */
    EpilogOffset = Slot->Used;
    if ( !Patches_Resolve( &Patches, Slot, EpilogOffset ) ) return 0;
    if ( !EmitEpilogue( Slot ) ) {
        fprintf( stderr, "[-] codegen: epilogue failed\n" );
        return 0;
    }
    if ( OutPcToOffset != NULL ) {
        int Pc2 = 0;
        for ( Pc2 = 0; Pc2 < P->sizecode; Pc2++ ) {
            OutPcToOffset[ Pc2 ] = Branches.PcOffsets[ Pc2 ];
        }
    }
    return 1;
}

/*!
 * @brief
 *  Emit a Win64 call to Rt_PrepReturn( L, A, N ).
 *  RCX already holds L; we load RDX = A, R8 = N, then CALL.
 *  On return RAX = N (the helper's return value = nresults).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param A
 *  base register index of the first result
 *
 * @param N
 *  number of results to return
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int EmitCallRtPrep( PEXEC_MEM_SLOT_T Slot, int A, int N, int NParams1, PEPILOG_PATCHES_T Patches ) {
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )N ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )NParams1 ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_PrepReturn ) ) return 0;
    /* JMP to epilogue (rel32 — mid-function returns may be far from
       epilogue in functions with branches/loops; patched by Patches_Resolve) */
    size_t JmpOff = EmitX64_JmpRel32_Placeholder( Slot );
    if ( JmpOff == ( size_t )-1 ) return 0;
    return Patches_Add( Patches, JmpOff );
}

/* --- per-opcode lowering stubs (filled in by Tasks 11–13) --------------- */
/*!
 * @brief
 *  Lower OP_LOADI: R[A] = sBx (signed integer immediate).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_LOADI instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_LoadI( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    int         sBx = GETARG_sBx( Ins );

    /* mov rax, sBx (sign-extended to 64) */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, ( uint64_t )( int64_t )sBx ) ) return 0;
    /* write value to memory and cache reg if assigned */
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    /* mov dword [rdi + A*16 + 8], LUA_VNUMINT */
    if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}
/*!
 * @brief
 *  Lower OP_MOVE: R[A] = R[B] (16-byte TValue copy).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_MOVE instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_Move( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    /* value half: read from cache reg if assigned, else memory; write through */
    if ( !EmitLoadRaxFromLua( Slot, B ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    /* tag half: always read/write memory — tags are not cached */
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RDI, B * 16 + 8 ) )   return 0;
    if ( !EmitX64_MovRegToMem( Slot, X64_RDI, A * 16 + 8, X64_RAX ) )   return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_LOADK: R[A] = K[Bx] (16-byte TValue copy from constant pool).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_LOADK instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_LoadK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int Bx = GETARG_Bx( Ins );
    TValue *K = &P->k[ Bx ];   /* address known at compile time */
    /* mov r10, &K ; load value half then write through; tag half stays memory-only */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R10, ( uint64_t )( uintptr_t )K ) ) return 0;
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_R10, 0 ) )                    return 0;
    if ( !EmitWriteThroughRax( Slot, A ) )                                       return 0;
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_R10, 8 ) )                    return 0;
    if ( !EmitX64_MovRegToMem( Slot, X64_RDI, A * 16 + 8, X64_RAX ) )           return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_LOADFALSE: R[A] = false.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_LOADFALSE instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_LoadFalse( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    /* mov rax, 0 ; write through to memory and cache; tag stays memory-only */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, 0 ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VFALSE ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_LOADTRUE: R[A] = true.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_LOADTRUE instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_LoadTrue( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, 0 ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VTRUE ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_LOADNIL: R[A], R[A+1], ..., R[A+B] = nil.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_LOADNIL instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_LoadNil( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );  /* B = how many to nil out, inclusive */
    int I = { 0 };
    for ( I = 0; I <= B; I++ ) {
        if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, 0 ) ) return 0;
        if ( !EmitWriteThroughRax( Slot, A + I ) ) return 0;
        if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, ( A + I ) * 16 + 8, LUA_VNIL ) ) return 0;
        ClearKnownFfi( A + I );
    }
    return 1;
}

typedef enum _ARITH_OP { ARITH_ADD, ARITH_SUB, ARITH_MUL, ARITH_DIV } ARITH_OP_T;

/*!
 * @brief
 *  Emit the appropriate x64 arithmetic instruction for the integer fast
 *  path: "rax <op>= [rdi + Disp]". Generates SUB or IMUL byte sequences
 *  manually for op codes that the existing emitter library doesn't cover.
 */
static int EmitArithRax( PEXEC_MEM_SLOT_T Slot, ARITH_OP_T Op, int32_t Disp ) {
    if ( Op == ARITH_ADD ) {
        return EmitX64_AddMemToReg( Slot, X64_RAX, X64_RDI, Disp );
    }

    /* For SUB and IMUL, emit manually. ModR/M shape: mod{0,1,2} reg=000 rm=111. */
    unsigned char Bytes[ 8 ] = { 0 };
    int N = 0;

    Bytes[ N++ ] = 0x48;  /* REX.W */
    if ( Op == ARITH_SUB ) {
        Bytes[ N++ ] = 0x2B;
    } else if ( Op == ARITH_MUL ) {
        Bytes[ N++ ] = 0x0F;
        Bytes[ N++ ] = 0xAF;
    } else {
        return 0;
    }
    if ( Disp == 0 ) {
        Bytes[ N++ ] = ( unsigned char )( ( 0 << 6 ) | ( 0 << 3 ) | 7 );
    } else if ( Disp >= -128 && Disp <= 127 ) {
        Bytes[ N++ ] = ( unsigned char )( ( 1 << 6 ) | ( 0 << 3 ) | 7 );
        Bytes[ N++ ] = ( unsigned char )( ( int8_t )Disp );
    } else {
        Bytes[ N++ ] = ( unsigned char )( ( 2 << 6 ) | ( 0 << 3 ) | 7 );
        Bytes[ N++ ] = ( unsigned char )( Disp        & 0xFF );
        Bytes[ N++ ] = ( unsigned char )( ( Disp >> 8  ) & 0xFF );
        Bytes[ N++ ] = ( unsigned char )( ( Disp >> 16 ) & 0xFF );
        Bytes[ N++ ] = ( unsigned char )( ( Disp >> 24 ) & 0xFF );
    }
    return ExecMem_Append( Slot, Bytes, ( size_t )N );
}

/*!
 * @brief
 *  Emit "rax <op>= XSrc" (reg-reg form). Mirrors EmitArithRax but with a
 *  GPR source instead of a memory operand.
 *      ADD: 48 03 /r   (REX.W [+REX.B], opcode 03, ModR/M mod=11 reg=000 rm=Lo3(XSrc))
 *      SUB: 48 2B /r
 *      MUL: 48 0F AF /r (3-byte opcode)
 *
 *  Not yet wired into call sites — Task 7.5 will use this once cache reads
 *  are safe.
 */
static int EmitArithRaxRegReg( PEXEC_MEM_SLOT_T Slot, ARITH_OP_T Op, X64_GPR_T XSrc ) {
    int           IsHi  = ( ( int )XSrc >= 8 );
    unsigned      RexB  = IsHi ? 1u : 0u;
    unsigned char Rex   = ( unsigned char )( 0x48 | RexB );
    unsigned char ModRm = ( unsigned char )( ( 3u << 6 ) | ( 0u << 3 ) | ( ( unsigned )XSrc & 7u ) );

    if ( Op == ARITH_ADD ) {
        unsigned char Bytes[ ] = { Rex, 0x03, ModRm };
        return ExecMem_Append( Slot, Bytes, sizeof( Bytes ) );
    } else if ( Op == ARITH_SUB ) {
        unsigned char Bytes[ ] = { Rex, 0x2B, ModRm };
        return ExecMem_Append( Slot, Bytes, sizeof( Bytes ) );
    } else if ( Op == ARITH_MUL ) {
        unsigned char Bytes[ ] = { Rex, 0x0F, 0xAF, ModRm };
        return ExecMem_Append( Slot, Bytes, sizeof( Bytes ) );
    } else if ( Op == ARITH_DIV ) {
        /* div has no fast integer form; signal "use memory form". */
        return 0;
    }
    return 0;
}

/*!
 * @brief
 *  Emit "cmp rax, XSrc" (reg-reg form, opcode 48 39 /r mod=11).
 *  Not yet wired into call sites — Task 7.5 will use this in
 *  EmitCompareAndBranch's integer fast path once cache reads are safe.
 */
static int EmitCmpRaxRegReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T XSrc ) {
    /* CMP rax, XSrc   -- flags reflect rax - XSrc.
       Encoding: REX.W [+ REX.B if XSrc is R8..R15] 3B /r
                 ModR/M: mod=11, reg=000 (rax), rm = XSrc & 7
       Previously this emitted opcode 0x39 (CMP r/m, r) which inverted the
       operands -- flags ended up reflecting XSrc - rax instead. That made
       every cached-vs-cached integer compare yield the WRONG sign for JL/
       JGE/JLE/JG, which silently flipped while-loop conditions, if-tests,
       and (a<b) expressions whenever both operands lived in cache regs. */
    int           IsHi  = ( ( int )XSrc >= 8 );
    unsigned      RexB  = IsHi ? 1u : 0u;
    unsigned char Rex   = ( unsigned char )( 0x48 | RexB );
    unsigned char ModRm = ( unsigned char )( ( 3u << 6 ) | ( 0u << 3 ) | ( ( unsigned )XSrc & 7u ) );
    unsigned char Bytes[ ] = { Rex, 0x3B, ModRm };
    return ExecMem_Append( Slot, Bytes, sizeof( Bytes ) );
}

/*!
 * @brief
 *  Emit a typed-binary-op fast path with float and integer fast paths and a
 *  slow-path C helper fallback.
 *  Layout:
 *      [cmp B,flt] [jne >int_check] [cmp C,flt] [jne >int_check]
 *      [movsd xmm0,B][<op>sd xmm0,C][movsd A,xmm0][store flt tag][jmp >done]
 *    int_check:
 *      [cmp B,int] [jne >slow] [cmp C,int] [jne >slow]
 *      [load B][op C][store A][store int tag][jmp >done]
 *    slow:
 *      [mov rdx,A][mov r8,B][mov r9,C][call SlowHelper]
 *    done:
 *      (fall through to next op)
 *
 *  JNE/JMP displacements are placeholders, patched after the layout is
 *  known using captured slot cursor positions.
 */
static int EmitBinArith( PEXEC_MEM_SLOT_T Slot, int A, int B, int C,
                         ARITH_OP_T Op, void *SlowHelper ) {
    size_t JneFltBPatch    = { 0 };
    size_t JneFltCPatch    = { 0 };
    size_t JmpDoneFltPatch = { 0 };
    size_t IntCheckStart   = { 0 };
    size_t JneIntBPatch    = { 0 };
    size_t JneIntCPatch    = { 0 };
    size_t JmpDoneIntPatch = { 0 };
    size_t SlowStart       = { 0 };
    size_t DoneOffset      = { 0 };

    /* --- float fast path --- */

    /* CMP [rdi + B*16 + 8], LUA_VNUMFLT */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, B * 16 + 8, LUA_VNUMFLT ) ) return 0;
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    JneFltBPatch = Slot->Used - 1;

    /* CMP [rdi + C*16 + 8], LUA_VNUMFLT */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, C * 16 + 8, LUA_VNUMFLT ) ) return 0;
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    JneFltCPatch = Slot->Used - 1;

    /* float fast path body */
    if ( !EmitX64_MovsdMemToXmm0( Slot, X64_RDI, B * 16 ) ) return 0;
    {
        int OkFloat = 0;
        switch ( Op ) {
            case ARITH_ADD: OkFloat = EmitX64_AddsdMemToXmm0( Slot, X64_RDI, C * 16 ); break;
            case ARITH_SUB: OkFloat = EmitX64_SubsdMemToXmm0( Slot, X64_RDI, C * 16 ); break;
            case ARITH_MUL: OkFloat = EmitX64_MulsdMemToXmm0( Slot, X64_RDI, C * 16 ); break;
            case ARITH_DIV: OkFloat = EmitX64_DivsdMemToXmm0( Slot, X64_RDI, C * 16 ); break;
            default: return 0;
        }
        if ( !OkFloat ) return 0;
    }
    if ( !EmitX64_MovsdXmm0ToMem( Slot, X64_RDI, A * 16 ) ) return 0;
    if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VNUMFLT ) ) return 0;

    /* JMP to done — placeholder (float path). Use rel32 so the
       integer-path + slow-path bodies between us and DoneOffset can
       exceed 128 bytes without overflowing a rel8 displacement. */
    JmpDoneFltPatch = EmitX64_JmpRel32_Placeholder( Slot );
    if ( JmpDoneFltPatch == ( size_t )-1 ) return 0;

    /* int_check: patch float JNEs here */
    IntCheckStart = Slot->Used;

    /* --- integer fast path --- */

    /* CMP [rdi + B*16 + 8], LUA_VNUMINT */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, B * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    JneIntBPatch = Slot->Used - 1;

    /* CMP [rdi + C*16 + 8], LUA_VNUMINT */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, C * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    JneIntCPatch = Slot->Used - 1;

    /* integer fast path body (DIV has no integer fast path; fall through) */
    if ( Op != ARITH_DIV ) {
        /* load B via cache if assigned, else memory */
        if ( !EmitLoadRaxFromLua( Slot, B ) ) return 0;
        /* apply C via reg-reg form if C is cached, else memory form */
        {
            X64_GPR_T XC = { 0 };
            if ( g_CurrentRegAlloc != NULL &&
                 RegAlloc_IsCached( g_CurrentRegAlloc, C, &XC ) ) {
                if ( !EmitArithRaxRegReg( Slot, Op, XC ) ) return 0;
            } else {
                if ( !EmitArithRax( Slot, Op, C * 16 ) ) return 0;
            }
        }
        if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
        if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;

        /* JMP to done — placeholder (integer path). rel32 so the slow
           path can be arbitrarily long without overflowing. */
        JmpDoneIntPatch = EmitX64_JmpRel32_Placeholder( Slot );
        if ( JmpDoneIntPatch == ( size_t )-1 ) return 0;
    }

    /* slow: */
    SlowStart = Slot->Used;
    /* Restore L into RCX first (caller-saved; may be clobbered after prior calls). */
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, SlowHelper ) ) return 0;
    /* resync RDI + cache regs — slow helper runs luaO_arith which can
       call __add/__sub/__mul/etc metamethods. Those metamethods are
       Lua functions that may grow the stack, invalidating RDI. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;

    /* done: (fall through to next opcode's emission) */
    DoneOffset = Slot->Used;

    /* patch float JNEs to int_check */
    {
        int D = ( int )( IntCheckStart - ( JneFltBPatch + 1 ) );
        if ( D > 127 || D < -128 ) {
            fprintf( stderr, "[-] jit: float JNE-B out of rel8 range (%d)\n", D );
            return 0;
        }
        Slot->Code[ JneFltBPatch ] = ( unsigned char )( int8_t )D;
    }
    {
        int D = ( int )( IntCheckStart - ( JneFltCPatch + 1 ) );
        if ( D > 127 || D < -128 ) {
            fprintf( stderr, "[-] jit: float JNE-C out of rel8 range (%d)\n", D );
            return 0;
        }
        Slot->Code[ JneFltCPatch ] = ( unsigned char )( int8_t )D;
    }

    /* patch float JMP-done to DoneOffset (rel32) */
    if ( !EmitX64_PatchRel32( Slot, JmpDoneFltPatch, DoneOffset ) ) {
        fprintf( stderr, "[-] jit: float JMP-done rel32 patch failed\n" );
        return 0;
    }

    /* patch integer JNEs to slow */
    {
        int D = ( int )( SlowStart - ( JneIntBPatch + 1 ) );
        if ( D > 127 || D < -128 ) {
            fprintf( stderr, "[-] jit: int JNE-B out of rel8 range (%d)\n", D );
            return 0;
        }
        Slot->Code[ JneIntBPatch ] = ( unsigned char )( int8_t )D;
    }
    {
        int D = ( int )( SlowStart - ( JneIntCPatch + 1 ) );
        if ( D > 127 || D < -128 ) {
            fprintf( stderr, "[-] jit: int JNE-C out of rel8 range (%d)\n", D );
            return 0;
        }
        Slot->Code[ JneIntCPatch ] = ( unsigned char )( int8_t )D;
    }

    /* patch integer JMP-done (only when Op != ARITH_DIV) -- rel32 */
    if ( Op != ARITH_DIV ) {
        if ( !EmitX64_PatchRel32( Slot, JmpDoneIntPatch, DoneOffset ) ) {
            fprintf( stderr, "[-] jit: int JMP-done rel32 patch failed\n" );
            return 0;
        }
    }

    return 1;
}

extern int Rt_SubSlow( lua_State *L, int A, int B, int C );
extern int Rt_MulSlow( lua_State *L, int A, int B, int C );

static int Lower_Add( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitBinArith( Slot, A, B, C, ARITH_ADD, ( void * )Rt_AddSlow ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_Sub( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitBinArith( Slot, A, B, C, ARITH_SUB, ( void * )Rt_SubSlow ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_Mul( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitBinArith( Slot, A, B, C, ARITH_MUL, ( void * )Rt_MulSlow ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_CALL: call R[A] with B-1 args, expecting C-1 results.
 *  Delegates to Rt_Call which wraps upstream luaD_call.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_CALL instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_Call( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins     = P->code[ Pc ];
    int         A       = GETARG_A( Ins );
    int         B       = GETARG_B( Ins );
    int         C       = GETARG_C( Ins );
    /* NArgs = B - 1 (B == 0 means "varargs to L->top", we pass -1) */
    int         NArgs   = ( B == 0 ) ? -1 : ( B - 1 );
    int         NResults = C - 1;  /* C == 0 means "all results", encoded as -1 */

    /* if R[A] is a known FFI CFunc cdata, try the inline trampoline */
    if ( g_CurrentKnownFfi != NULL ) {
        PCData_T KnownFn = KnownFfi_Get( g_CurrentKnownFfi, A );
        if ( KnownFn != NULL && KnownFn != ( PCData_T )1 && KnownFn != ( PCData_T )2 ) {
            int InlineNArgs = B - 1;  /* OP_CALL: B = NArgs + 1 */
            if ( Lower_FfiCallInline( Slot, KnownFn, A, InlineNArgs ) ) {
                /* inline succeeded — skip Rt_Call; R[A] now holds the result */
                KnownFfi_Clear( g_CurrentKnownFfi, A );
                /* resync cache regs only — the inline FFI thunk is a
                   leaf C call that doesn't touch the Lua stack. */
                if ( !EmitReloadCacheAll( Slot ) ) return 0;
                return 1;
            }
        }
    }

    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A       ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )NArgs   ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )NResults ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_Call ) ) return 0;
    /* Rt_Call may trigger a stack reallocation (via checkstackGCp inside
       precallC for C callees, or Lua callees that grow their frame).
       Re-derive rdi from L->ci->func.p+1 to keep the register base current,
       then resync the cache registers. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Lower OP_RETURN: return R[A], ..., R[A+B-2] (B-1 results).
 *  When B == 1 this is equivalent to RETURN0; when B == 2 it is equivalent
 *  to RETURN1. Delegates to Rt_PrepReturn( L, A, B-1 ).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_RETURN instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
extern int Rt_Close( lua_State *L, int A );  /* close open upvalues from R[A] up */

static int Lower_Return( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PEPILOG_PATCHES_T Patches ) {
    Instruction Ins  = P->code[ Pc ];
    int         A    = GETARG_A( Ins );
    int         B    = GETARG_B( Ins );
    int         NRes = B - 1;  /* B==1 -> 0; B==2 -> 1; B==0 -> -1 (MULTRET);
                                  Rt_PrepReturn computes the count at runtime
                                  for the MULTRET case via L->top - (Base+A) */
    /* If the compiler set the k flag, this function created closures over its
       locals and we MUST close those upvalues before returning -- otherwise
       the closures' upvalue refs would point at freed stack memory. */
    if ( GETARG_k( Ins ) ) {
        if ( !EmitCall1ArgHelper( Slot, 0, ( void * )Rt_Close ) ) return 0;
    }
    /* C encodes (nparams + 1) for vararg functions, 0 otherwise. Rt_PrepReturn
       uses this to reverse OP_VARARGPREP's ci->func.p relocation so results
       land at the caller's expected slot. */
    int NParams1 = GETARG_C( Ins );
    return EmitCallRtPrep( Slot, A, NRes, NParams1, Patches );
}

/*!
 * @brief
 *  Lower OP_RETURN0: return 0 results.
 *  Calls Rt_PrepReturn( L, 0, 0 ) so L->top is adjusted;
 *  RAX = 0 on return (nresults).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction (unused)
 *
 * @param Pc
 *  index of the instruction (unused)
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_Return0( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PEPILOG_PATCHES_T Patches ) {
    Instruction Ins = P->code[ Pc ];
    if ( GETARG_k( Ins ) ) {
        if ( !EmitCall1ArgHelper( Slot, 0, ( void * )Rt_Close ) ) return 0;
    }
    /* Lua's compiler only emits OP_RETURN0/OP_RETURN1 for non-vararg
       functions (vararg always uses OP_RETURN with C = nparams + 1),
       so NParams1 is unconditionally 0 here. */
    return EmitCallRtPrep( Slot, 0, 0, 0, Patches );
}

/*!
 * @brief
 *  Lower OP_RETURN1: return 1 result from R[A].
 *  Calls Rt_PrepReturn( L, A, 1 ) so L->top is adjusted;
 *  RAX = 1 on return (nresults).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_RETURN1 instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_Return1( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PEPILOG_PATCHES_T Patches ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( GETARG_k( Ins ) ) {
        if ( !EmitCall1ArgHelper( Slot, 0, ( void * )Rt_Close ) ) return 0;
    }
    /* See Lower_Return0 -- OP_RETURN1 is non-vararg-only. */
    return EmitCallRtPrep( Slot, A, 1, 0, Patches );
}

extern int Rt_TailCall( lua_State *L, int A, int NArgs );

/*!
 * @brief
 *  Lower OP_TAILCALL A B C k: call R[A] with B-1 args; all results become
 *  our results. For v1 this is a Rt_TailCall (normal call + MULTRET) followed
 *  by a jump to the epilogue so the result count propagates correctly. True
 *  frame-reusing tailcalls are 2f+ work.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_TAILCALL instruction in P->code
 *
 * @param Patches
 *  epilogue-jump patch list; a new entry is added here
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_TailCall( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc,
                            PEPILOG_PATCHES_T Patches ) {
    Instruction Ins   = P->code[ Pc ];
    int         A     = GETARG_A( Ins );
    int         B     = GETARG_B( Ins );
    int         NArgs = ( B == 0 ) ? -1 : ( B - 1 );

    /* If the compiler set k, this function has open upvalues over its
       locals that MUST be closed before the tail call -- otherwise the
       tail call reuses our stack frame for the callee and the open
       upvalues end up pointing into freed/reused slots. Subsequent
       reads (e.g. when a coroutine.create'd closure is resumed) hit
       stale memory and corrupt the heap. Mirrors upstream lvm.c
       OP_TAILCALL: `if (TESTARG_k(i)) luaF_close(L, base, CLOSEKTOP, 1)`. */
    if ( GETARG_k( Ins ) ) {
        if ( !EmitCall1ArgHelper( Slot, 0, ( void * )Rt_Close ) ) return 0;
    }

    /* Call the helper. RAX gets the number of results from Rt_TailCall. */
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A     ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )NArgs ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_TailCall ) ) return 0;

    /* RAX = nresults from the tail-called function. JMP rel32 to epilogue
       (rel32 — see Patches_Resolve). */
    size_t JmpOff = EmitX64_JmpRel32_Placeholder( Slot );
    if ( JmpOff == ( size_t )-1 ) return 0;
    return Patches_Add( Patches, JmpOff );
}

/*!
 * @brief
 *  Lower OP_GETTABUP: R[A] = UpValue[B][K[C]:shortstring].
 *  Delegates to Rt_GetTabUp which uses luaH_getshortstr / luaV_finishget.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_GETTABUP instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_GetTabUp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_GetTabUp ) ) return 0;
    /* resync RDI + cache regs. Rt_GetTabUp may run a __index metamethod
       (e.g. ffi.C's symbol lookup, which allocates a cdata) that grows
       the Lua stack. Without re-deriving RDI we'd write all subsequent
       LOAD/MOVE ops to the OLD (freed) stack memory while ci->func.p
       points at the new stack -- the values are silently lost. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;

    /* detect _ENV.ffi pattern: mark R[A] with sentinel value 1 */
    if ( g_CurrentKnownFfi != NULL ) {
        TValue *Key = &P->k[ C ];
        if ( ttisstring( Key ) ) {
            TString    *Ts = tsvalue( Key );
            const char *S  = getstr( Ts );
            if ( S != NULL && strcmp( S, "ffi" ) == 0 ) {
                KnownFfi_Mark( g_CurrentKnownFfi, A, ( PCData_T )1 );
            } else {
                KnownFfi_Clear( g_CurrentKnownFfi, A );
            }
        } else {
            KnownFfi_Clear( g_CurrentKnownFfi, A );
        }
    }
    return 1;
}

/*!
 * @brief
 *  Lower OP_GETUPVAL: R[A] = UpValue[B]. 16-byte TValue copy.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_GETUPVAL instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_GetUpval( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_GetUpval ) ) return 0;
    /* resync cache regs only — Rt_GetUpval is a pure setobj2s; no
       allocation, no metamethod, so RDI stays valid. */
    if ( !EmitReloadCacheAll( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_SETUPVAL: UpValue[B] = R[A]. TValue copy with GC write-barrier.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_SETUPVAL instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_SetUpval( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_SetUpval ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Lower OP_JMP: unconditional jump by sJ (PC += sJ + 1).
 *  Emits a rel32 JMP placeholder. Backward jumps are patched immediately;
 *  forward jumps are queued in Branches and resolved after the opcode loop.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_JMP instruction in P->code
 *
 * @param Branches
 *  per-function branch context for deferred forward-jump patching
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_Jmp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches ) {
    Instruction Ins    = P->code[ Pc ];
    int         Offset = GETARG_sJ( Ins );
    int         Target = Pc + 1 + Offset;
    /* always use rel32 — forward or backward branches across the whole
       function should fit in int32. */
    size_t PatchOff = EmitX64_JmpRel32_Placeholder( Slot );
    if ( PatchOff == ( size_t )-1 ) return 0;
    if ( Target <= Pc ) {
        /* backward branch — target already emitted, patch immediately. */
        return EmitX64_PatchRel32( Slot, PatchOff, Branches->PcOffsets[ Target ] );
    }
    /* forward branch — defer until Resolve. */
    return BranchCtx_AddFwd( Branches, PatchOff, Target, 0 );
}

/*!
 * @brief
 *  Lower OP_CLOSURE: R[A] = new LClosure from P->p[Bx], upvalues bound.
 *  Delegates to Rt_NewClosure which mirrors upstream's pushclosure.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_CLOSURE instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_Closure( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int Bx = GETARG_Bx( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )Bx ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_NewClosure ) ) return 0;
    /* resync RDI + cache regs. Rt_NewClosure ends with luaC_checkGC which
       may relocate the Lua stack; without an RDI refresh the JIT body's
       writes to subsequent registers land in freed memory. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

extern int Rt_EqSlow   ( lua_State *L, int A, int B );
extern int Rt_LtSlow   ( lua_State *L, int A, int B );
extern int Rt_LeSlow   ( lua_State *L, int A, int B );
extern int Rt_ForPrep  ( lua_State *L, int A );
extern int Rt_ForLoop  ( lua_State *L, int A );
extern int Rt_NewTable ( lua_State *L, int A, int B, int C );
extern int Rt_GetI     ( lua_State *L, int A, int B, int C );
extern int Rt_SetI     ( lua_State *L, int A, int B, int Ck );
extern int Rt_GetField ( lua_State *L, int A, int B, int C );
extern int Rt_SetField ( lua_State *L, int A, int B, int Ck );
extern int Rt_GetTable ( lua_State *L, int A, int B, int C );
extern int Rt_SetTable ( lua_State *L, int A, int B, int Ck );
extern int Rt_SetTabUp ( lua_State *L, int A, int B, int Ck );
extern int Rt_Len      ( lua_State *L, int A, int B );
extern int Rt_Concat   ( lua_State *L, int A, int B );
extern int Rt_SetList  ( lua_State *L, int A, int B, int C );
extern int Rt_Vararg   ( lua_State *L, int A, int NRequired );

/*!
 * @brief
 *  Emit a fused comparison + conditional-branch for OP_EQ/LT/LE.
 *  The comparison op MUST be followed by an OP_JMP — we consume both.
 *  Layout:
 *      check A is integer, check B is integer (jump to slow on mismatch)
 *      mov rax, [rdi+A*16]
 *      cmp rax, [rdi+B*16]
 *      Jcc rel32 -> target    ; condition adjusted for k bit
 *      jmp done
 *    slow:
 *      mov rcx, rbx ; mov rdx, A ; mov r8, B
 *      call SlowHelper           ; eax = 0 or 1
 *      cmp eax, k
 *      je rel32 -> target
 *    done:
 *      (fall through)
 *
 * @param CcWhenTrue
 *  Jcc condition code (low nibble) when the comparison is "true":
 *  0x4 = JE, 0xC = JL, 0xE = JLE
 */

/*!
 * @brief
 *  Emit the tail of a comparison slow path. On entry the SlowHelper has just
 *  been called and left its boolean result (0/1) in EAX. That helper runs
 *  luaV_equalobj / luaV_lessthan / luaV_lessequal, which for non-number
 *  operands dispatch __eq/__lt/__le -- arbitrary Lua that can grow and
 *  RELOCATE the Lua stack (luaD_growstack -> luaD_reallocstack). After such a
 *  relocation RDI (= base, set once in the prologue) and every cached register
 *  point into the freed old stack, so they MUST be reloaded before any further
 *  [rdi+..]/cache access on EITHER successor path.
 *
 *  Ordering matters: the reload has to happen BEFORE the conditional branch,
 *  because the taken branch jumps to other JIT code that assumes the
 *  function-wide RDI/cache invariant holds. EmitReloadRdiAndCache clobbers
 *  RAX/RCX (and RDI + the cache pool R12-R15/RSI), so we first stash the
 *  helper result in R11D (a scratch GPR it does not touch), reload, then test
 *  the stashed value. This is the analog of the arithmetic slow path's reload
 *  and of the Lower_Close / Set-path reloads.
 */
static int EmitCompareSlowReloadAndBranch( PEXEC_MEM_SLOT_T Slot,
                                           PBRANCH_CTX_T Branches,
                                           int Pc, int TargetPc, int K,
                                           int InvertResult ) {
    /* if InvertResult, XOR eax,1 to flip the helper's 0/1 (83 F0 01) */
    if ( InvertResult ) {
        unsigned char XorBytes[ 3 ] = { 0x83, 0xF0, 0x01 };
        if ( !ExecMem_Append( Slot, XorBytes, sizeof( XorBytes ) ) ) return 0;
    }
    /* mov r11d, eax -- stash result across the reload (41 89 C3) */
    {
        unsigned char Mov[ 3 ] = { 0x41, 0x89, 0xC3 };
        if ( !ExecMem_Append( Slot, Mov, sizeof( Mov ) ) ) return 0;
    }
    /* a comparison metamethod may have relocated the Lua stack: re-derive
       RDI from L->ci->func.p and reload the register cache. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    /* CMP r11d, K  (41 83 FB ib) */
    {
        unsigned char Cmp[ 4 ] = { 0x41, 0x83, 0xFB, ( unsigned char )( int8_t )K };
        if ( !ExecMem_Append( Slot, Cmp, sizeof( Cmp ) ) ) return 0;
    }
    /* JE rel32 -> target (slow result == k means we should branch) */
    size_t JeSlowPatch = EmitX64_JccRel32_Placeholder( Slot, 0x4 /* JE */ );
    if ( JeSlowPatch == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        if ( !EmitX64_PatchRel32( Slot, JeSlowPatch, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        if ( !BranchCtx_AddFwd( Branches, JeSlowPatch, TargetPc, 0 ) ) return 0;
    }
    return 1;
}

static int EmitCompareAndBranch( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc,
                                  PBRANCH_CTX_T Branches, int *ExtraPc,
                                  void *SlowHelper, unsigned CcWhenTrue ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int K = GETARG_k( Ins );

    /* the next opcode MUST be OP_JMP */
    if ( Pc + 1 >= P->sizecode ) {
        fprintf( stderr, "[-] jit: comparison at end of proto with no following JMP\n" );
        return 0;
    }
    Instruction NextIns = P->code[ Pc + 1 ];
    if ( GET_OPCODE( NextIns ) != OP_JMP ) {
        fprintf( stderr, "[-] jit: comparison at pc %d not followed by JMP\n", Pc );
        return 0;
    }
    int JmpOffset = GETARG_sJ( NextIns );
    int TargetPc  = ( Pc + 1 ) + 1 + JmpOffset;

    /* CMP [rdi + A*16 + 8], LUA_VNUMINT */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
    /* JNE ->slow (placeholder) */
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    size_t JneAOff = Slot->Used - 1;

    /* CMP [rdi + B*16 + 8], LUA_VNUMINT */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, B * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    size_t JneBOff = Slot->Used - 1;

    /* rax = R[A] via cache if assigned, else memory */
    if ( !EmitLoadRaxFromLua( Slot, A ) ) return 0;

    /* cmp rax, R[B]: use reg-reg form if B is cached, else memory form */
    {
        X64_GPR_T XB = { 0 };
        if ( g_CurrentRegAlloc != NULL &&
             RegAlloc_IsCached( g_CurrentRegAlloc, B, &XB ) ) {
            if ( !EmitCmpRaxRegReg( Slot, XB ) ) return 0;
        } else {
            /* CMP rax, [rdi + B*16]
               REX.W=1, opcode 0x3B (CMP r64, r/m64), ModR/M for [rdi+disp] */
            int32_t       Disp  = B * 16;
            unsigned char Bytes[ 7 ] = { 0 };
            int           N     = 0;
            Bytes[ N++ ] = 0x48;   /* REX.W */
            Bytes[ N++ ] = 0x3B;   /* CMP r64, r/m64 */
            if ( Disp == 0 ) {
                /* mod=00 reg=000(rax) rm=111(rdi) */
                Bytes[ N++ ] = ( unsigned char )( ( 0 << 6 ) | ( 0 << 3 ) | 7 );
            } else if ( Disp >= -128 && Disp <= 127 ) {
                /* mod=01 reg=000(rax) rm=111(rdi) + disp8 */
                Bytes[ N++ ] = ( unsigned char )( ( 1 << 6 ) | ( 0 << 3 ) | 7 );
                Bytes[ N++ ] = ( unsigned char )( ( int8_t )Disp );
            } else {
                /* mod=10 reg=000(rax) rm=111(rdi) + disp32 */
                Bytes[ N++ ] = ( unsigned char )( ( 2 << 6 ) | ( 0 << 3 ) | 7 );
                Bytes[ N++ ] = ( unsigned char )( Disp         & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >>  8 ) & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >> 16 ) & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >> 24 ) & 0xFF );
            }
            if ( !ExecMem_Append( Slot, Bytes, ( size_t )N ) ) return 0;
        }
    }

    /* Jcc with adjusted condition: k==1 -> use CcWhenTrue; k==0 -> invert */
    unsigned      EffectiveCc = K ? CcWhenTrue : ( CcWhenTrue ^ 1 );
    size_t        JccPatch    = EmitX64_JccRel32_Placeholder( Slot, EffectiveCc );
    if ( JccPatch == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        if ( !EmitX64_PatchRel32( Slot, JccPatch, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        if ( !BranchCtx_AddFwd( Branches, JccPatch, TargetPc, 0 ) ) return 0;
    }

    /* JMP done (skips the slow path) */
    size_t JmpDoneOff = EmitX64_JmpRel8_Placeholder( Slot );
    if ( JmpDoneOff == ( size_t )-1 ) return 0;

    /* slow: patch the two integer-mismatch JNEs to land here */
    size_t SlowStart = Slot->Used;
    if ( !EmitX64_PatchRel8( Slot, JneAOff, SlowStart ) ) return 0;
    if ( !EmitX64_PatchRel8( Slot, JneBOff, SlowStart ) ) return 0;

    /* mov rcx, rbx (restore L) ; mov rdx, A ; mov r8, B ; call SlowHelper */
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, SlowHelper ) ) return 0;

    /* Stash result, reload RDI+cache (the helper may have run a comparison
       metamethod that relocated the stack), then test and branch. */
    if ( !EmitCompareSlowReloadAndBranch( Slot, Branches, Pc, TargetPc, K, 0 ) ) return 0;

    /* done: fall through to the opcode after the consumed OP_JMP */
    size_t DoneOff = Slot->Used;
    if ( !EmitX64_PatchRel8( Slot, JmpDoneOff, DoneOff ) ) return 0;

    *ExtraPc = 1;
    return 1;
}

static int Lower_Eq( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    return EmitCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, ( void * )Rt_EqSlow, 0x4 /* JE */ );
}

static int Lower_Lt( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    return EmitCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, ( void * )Rt_LtSlow, 0xC /* JL */ );
}

static int Lower_Le( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    return EmitCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, ( void * )Rt_LeSlow, 0xE /* JLE */ );
}

extern int Rt_EqISlow( lua_State *L, int A, int sB );
extern int Rt_LtISlow( lua_State *L, int A, int sB );
extern int Rt_OrderISlow( lua_State *L, int A, int RawIns );
extern int Rt_LeISlow( lua_State *L, int A, int sB );
extern int Rt_GtISlow( lua_State *L, int A, int sB );
extern int Rt_GeISlow( lua_State *L, int A, int sB );
extern int Rt_EqKSlow( lua_State *L, int A, int B );

/*!
 * @brief
 *  Fused immediate-comparison + JMP. Mirrors EmitCompareAndBranch but the
 *  second operand is a signed integer immediate (EQI/LTI/LEI/GTI/GEI) or a
 *  constant-pool index (EQK). Fast path:
 *      CMP [rdi+A*16+8], LUA_VNUMINT
 *      JNE >slow
 *      mov rax, sB_or_KI
 *      cmp [rdi+A*16], rax     ; R[A] - operand
 *      Jcc rel32 -> target
 *      JMP done
 *    slow:
 *      mov rcx, rbx ; mov rdx, A ; mov r8, B ; call SlowHelper
 *      [XOR eax,1 if InvertResult]
 *      cmp eax, K ; JE rel32 -> target
 *    done:
 *
 *  InvertResult lets GTI/GEI reuse the LE/LT helpers with sense flipped.
 *
 * @param B
 *  sB (signed immediate) for non-pool ops, or constant-pool index for EQK
 *
 * @param IsConstPool
 *  1 = EQK (K[B] must be integer for fast path), 0 = immediate sB
 *
 * @param CcWhenTrue
 *  Jcc condition code when comparison is logically true (before k/invert)
 *
 * @param InvertResult
 *  when 1, XOR the fast-path Jcc sense and the slow-path eax to implement
 *  GT/GE via LE/LT with flipped direction
 */
static int EmitImmCompareAndBranch( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc,
                                     PBRANCH_CTX_T Branches, int *ExtraPc,
                                     int A, int B,
                                     int IsConstPool, int SlowArg2,
                                     void *SlowHelper, unsigned CcWhenTrue,
                                     int InvertResult ) {
    Instruction Ins = P->code[ Pc ];
    int K = GETARG_k( Ins );

    if ( Pc + 1 >= P->sizecode || GET_OPCODE( P->code[ Pc + 1 ] ) != OP_JMP ) {
        fprintf( stderr, "[-] jit: imm-comparison at pc %d not followed by JMP\n", Pc );
        return 0;
    }
    int TargetPc = ( Pc + 1 ) + 1 + GETARG_sJ( P->code[ Pc + 1 ] );

    /* If this is EQK with a non-integer constant (nil, string, bool, float),
       there's no integer fast path. Skip straight to the runtime helper. */
    if ( IsConstPool && !ttisinteger( &P->k[ B ] ) ) {
        if ( !EmitRestoreL( Slot ) ) return 0;
        if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
        if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )SlowArg2 ) ) return 0;
        if ( !EmitX64_CallAbs( Slot, SlowHelper ) ) return 0;
        /* Rt_EqKSlow may invoke __eq (Lua, can relocate the stack): stash the
           result, reload RDI+cache, THEN test and branch -- so both the taken
           and fall-through successors see a valid RDI/cache. (The reload must
           precede the branch; doing it after, as before, left the taken path
           running on a stale base.) */
        if ( !EmitCompareSlowReloadAndBranch( Slot, Branches, Pc, TargetPc, K, InvertResult ) ) return 0;
        *ExtraPc = 1;
        return 1;
    }

    /* CMP [rdi + A*16 + 8], LUA_VNUMINT */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, A * 16 + 8, LUA_VNUMINT ) ) return 0;
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    size_t JneSlowPatch = Slot->Used - 1;

    if ( IsConstPool ) {
        /* Already checked above; K[B] is integer here. */
        TValue *KVal = &P->k[ B ];
        lua_Integer KI = ivalue( KVal );
        /* mov rax, KI */
        if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, ( uint64_t )( int64_t )KI ) ) return 0;
        /* CMP rax, [rdi+A*16]: 48 3B /r  reg=000(rax) rm=111(rdi) */
        {
            int32_t       Disp  = A * 16;
            unsigned char Bytes[ 7 ] = { 0 };
            int           N     = 0;
            Bytes[ N++ ] = 0x48;
            Bytes[ N++ ] = 0x3B;
            if ( Disp == 0 ) {
                Bytes[ N++ ] = ( unsigned char )( ( 0 << 6 ) | ( 0 << 3 ) | 7 );
            } else if ( Disp >= -128 && Disp <= 127 ) {
                Bytes[ N++ ] = ( unsigned char )( ( 1 << 6 ) | ( 0 << 3 ) | 7 );
                Bytes[ N++ ] = ( unsigned char )( ( int8_t )Disp );
            } else {
                Bytes[ N++ ] = ( unsigned char )( ( 2 << 6 ) | ( 0 << 3 ) | 7 );
                Bytes[ N++ ] = ( unsigned char )( Disp         & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >>  8 ) & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >> 16 ) & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >> 24 ) & 0xFF );
            }
            if ( !ExecMem_Append( Slot, Bytes, ( size_t )N ) ) return 0;
        }
    } else {
        /* immediate sB: mov rax, sB (sign-extended) ; CMP [rdi+A*16], rax
           CMP [rdi+A*16], rax = 48 39 /r  reg=000(rax) rm=111(rdi)
           flags reflect R[A] - rax, so JL fires when R[A] < sB. */
        if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, ( uint64_t )( int64_t )B ) ) return 0;
        {
            int32_t       Disp  = A * 16;
            unsigned char Bytes[ 7 ] = { 0 };
            int           N     = 0;
            Bytes[ N++ ] = 0x48;
            Bytes[ N++ ] = 0x39;
            if ( Disp == 0 ) {
                Bytes[ N++ ] = ( unsigned char )( ( 0 << 6 ) | ( 0 << 3 ) | 7 );
            } else if ( Disp >= -128 && Disp <= 127 ) {
                Bytes[ N++ ] = ( unsigned char )( ( 1 << 6 ) | ( 0 << 3 ) | 7 );
                Bytes[ N++ ] = ( unsigned char )( ( int8_t )Disp );
            } else {
                Bytes[ N++ ] = ( unsigned char )( ( 2 << 6 ) | ( 0 << 3 ) | 7 );
                Bytes[ N++ ] = ( unsigned char )( Disp         & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >>  8 ) & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >> 16 ) & 0xFF );
                Bytes[ N++ ] = ( unsigned char )( ( Disp >> 24 ) & 0xFF );
            }
            if ( !ExecMem_Append( Slot, Bytes, ( size_t )N ) ) return 0;
        }
    }

    /* Jcc with k-bit + InvertResult applied */
    unsigned EffectiveCc = CcWhenTrue;
    if ( InvertResult ) { EffectiveCc ^= 1; }  /* flip direction for GT/GE */
    if ( !K )           { EffectiveCc ^= 1; }  /* k=0: branch when comparison false */

    size_t JccPatch = EmitX64_JccRel32_Placeholder( Slot, EffectiveCc );
    if ( JccPatch == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        if ( !EmitX64_PatchRel32( Slot, JccPatch, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        if ( !BranchCtx_AddFwd( Branches, JccPatch, TargetPc, 0 ) ) return 0;
    }

    /* JMP done (skips slow path) */
    size_t JmpDoneOff = EmitX64_JmpRel8_Placeholder( Slot );
    if ( JmpDoneOff == ( size_t )-1 ) return 0;

    /* slow: */
    size_t SlowStart = Slot->Used;
    if ( !EmitX64_PatchRel8( Slot, JneSlowPatch, SlowStart ) ) return 0;
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )SlowArg2 ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, SlowHelper ) ) return 0;

    /* The slow helper (Rt_*ISlow/Rt_EqKSlow) calls luaV_equalobj/lessthan/
       lessequal, which can run a comparison metamethod that relocates the Lua
       stack. Stash the result, reload RDI+cache, then test and branch. */
    if ( !EmitCompareSlowReloadAndBranch( Slot, Branches, Pc, TargetPc, K, InvertResult ) ) return 0;

    /* done: */
    size_t DoneOff = Slot->Used;
    if ( !EmitX64_PatchRel8( Slot, JmpDoneOff, DoneOff ) ) return 0;

    *ExtraPc = 1;
    return 1;
}

static int Lower_Eqi( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int sB = GETARG_sB( Ins );
    /* equality: JE (0x4), no invert */
    return EmitImmCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, A, sB, 0, sB,
                                     ( void * )Rt_EqISlow, 0x4, 0 );
}

static int Lower_Lti( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int sB = GETARG_sB( Ins );
    /* CMP R[A]-sB; R[A] < sB -> JL (0xC) */
    /* slow path: Rt_OrderISlow decodes the raw word (sB + the float-immediate
       C flag + the opcode's swap), so an __lt/__le metamethod sees the operand
       exactly as lvm.c op_orderI passes it. */
    return EmitImmCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, A, sB, 0,
                                     ( int )P->code[ Pc ],
                                     ( void * )Rt_OrderISlow, 0xC, 0 );
}

static int Lower_Lei( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int sB = GETARG_sB( Ins );
    /* CMP R[A]-sB; R[A] <= sB -> JLE (0xE) */
    /* slow path: Rt_OrderISlow decodes the raw word (sB + the float-immediate
       C flag + the opcode's swap), so an __lt/__le metamethod sees the operand
       exactly as lvm.c op_orderI passes it. */
    return EmitImmCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, A, sB, 0,
                                     ( int )P->code[ Pc ],
                                     ( void * )Rt_OrderISlow, 0xE, 0 );
}

static int Lower_Gti( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int sB = GETARG_sB( Ins );
    /* R[A] > sB == sB < R[A]: swap operands (Rt_GtISlow), NOT !(R[A] <= sB),
       which is wrong for NaN. Fast int path JG (0xF); no result inversion. */
    /* slow path: Rt_OrderISlow decodes the raw word (sB + the float-immediate
       C flag + the opcode's swap), so an __lt/__le metamethod sees the operand
       exactly as lvm.c op_orderI passes it. */
    return EmitImmCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, A, sB, 0,
                                     ( int )P->code[ Pc ],
                                     ( void * )Rt_OrderISlow, 0xF, 0 );
}

static int Lower_Gei( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int sB = GETARG_sB( Ins );
    /* R[A] >= sB == sB <= R[A]: swap operands (Rt_GeISlow), NOT !(R[A] < sB),
       which is wrong for NaN. Fast int path JGE (0xD); no result inversion. */
    /* slow path: Rt_OrderISlow decodes the raw word (sB + the float-immediate
       C flag + the opcode's swap), so an __lt/__le metamethod sees the operand
       exactly as lvm.c op_orderI passes it. */
    return EmitImmCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, A, sB, 0,
                                     ( int )P->code[ Pc ],
                                     ( void * )Rt_OrderISlow, 0xD, 0 );
}

static int Lower_Eqk( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    return EmitImmCompareAndBranch( Slot, P, Pc, Branches, ExtraPc, A, B, 1, B,
                                     ( void * )Rt_EqKSlow, 0x4, 0 );
}

/*!
 * @brief
 *  Emit a truthy/falsy test on the TValue at [rdi + RegSlot*16]:
 *      mov eax, 1
 *      cmp dword [rdi + RegSlot*16 + 8], LUA_VNIL
 *      je  .set_falsy
 *      cmp dword [rdi + RegSlot*16 + 8], LUA_VFALSE
 *      jne .done
 *    .set_falsy:
 *      mov eax, 0
 *    .done:
 *
 *  After this sequence eax = 1 (truthy) or 0 (falsy).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param RegSlot
 *  Lua register index to test
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int EmitIsTruthyEax( PEXEC_MEM_SLOT_T Slot, int RegSlot ) {
    /* mov eax, 1 */
    unsigned char MovEax1[ ] = { 0xB8, 0x01, 0x00, 0x00, 0x00 };
    if ( !ExecMem_Append( Slot, MovEax1, sizeof( MovEax1 ) ) ) return 0;

    /* cmp dword [rdi + RegSlot*16 + 8], LUA_VNIL */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, RegSlot * 16 + 8, LUA_VNIL ) ) return 0;
    /* je .set_falsy (rel8 placeholder) */
    unsigned char JeBytes[ 2 ] = { 0x74, 0x00 };
    if ( !ExecMem_Append( Slot, JeBytes, sizeof( JeBytes ) ) ) return 0;
    size_t JeNilPatch = Slot->Used - 1;

    /* cmp dword [rdi + RegSlot*16 + 8], LUA_VFALSE */
    if ( !EmitX64_CmpMem8Imm8( Slot, X64_RDI, RegSlot * 16 + 8, LUA_VFALSE ) ) return 0;
    /* jne .done (rel8 placeholder) */
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    size_t JneFalsePatch = Slot->Used - 1;

    /* .set_falsy: mov eax, 0 */
    size_t SetFalsyStart = Slot->Used;
    unsigned char MovEax0[ ] = { 0xB8, 0x00, 0x00, 0x00, 0x00 };
    if ( !ExecMem_Append( Slot, MovEax0, sizeof( MovEax0 ) ) ) return 0;

    /* .done: (fall through) */
    size_t DoneOff = Slot->Used;

    if ( !EmitX64_PatchRel8( Slot, JeNilPatch,    SetFalsyStart ) ) return 0;
    if ( !EmitX64_PatchRel8( Slot, JneFalsePatch, DoneOff       ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Emit "cmp eax, K ; JE rel32 → TargetPc". Handles both backward
 *  (immediate patch) and forward (queued in Branches) targets.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param K
 *  immediate value to compare eax against
 *
 * @param TargetPc
 *  Lua PC the JE should land on
 *
 * @param Pc
 *  current Lua PC (used to determine backward vs. forward)
 *
 * @param Branches
 *  per-function branch context for deferred forward-jump patching
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int EmitCmpEaxAndBranch( PEXEC_MEM_SLOT_T Slot, int K, int TargetPc, int Pc,
                                 PBRANCH_CTX_T Branches ) {
    /* cmp eax, K  — 83 F8 ib */
    unsigned char Bytes[ 3 ] = { 0x83, 0xF8, ( unsigned char )( int8_t )K };
    if ( !ExecMem_Append( Slot, Bytes, sizeof( Bytes ) ) ) return 0;
    /* JE rel32 → TargetPc */
    size_t JeOff = EmitX64_JccRel32_Placeholder( Slot, 0x4 /* JE */ );
    if ( JeOff == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        return EmitX64_PatchRel32( Slot, JeOff, Branches->PcOffsets[ TargetPc ] );
    }
    return BranchCtx_AddFwd( Branches, JeOff, TargetPc, 0 );
}

/*!
 * @brief
 *  Lower OP_TEST A k: fused with the following OP_JMP.
 *  JMP fires when "R[A] is truthy" == k.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_TEST instruction in P->code
 *
 * @param Branches
 *  per-function branch context for deferred forward-jump patching
 *
 * @param ExtraPc
 *  set to 1 to consume the following OP_JMP
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_Test( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc,
                       PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int K = GETARG_k( Ins );

    if ( Pc + 1 >= P->sizecode || GET_OPCODE( P->code[ Pc + 1 ] ) != OP_JMP ) {
        fprintf( stderr, "[-] jit: OP_TEST at pc %d not followed by OP_JMP\n", Pc );
        return 0;
    }
    int TargetPc = ( Pc + 1 ) + 1 + GETARG_sJ( P->code[ Pc + 1 ] );

    if ( !EmitIsTruthyEax( Slot, A ) ) return 0;
    if ( !EmitCmpEaxAndBranch( Slot, K, TargetPc, Pc, Branches ) ) return 0;

    *ExtraPc = 1;
    return 1;
}

/*!
 * @brief
 *  Lower OP_TESTSET A B k: fused with the following OP_JMP.
 *  Tests R[B]; if "truthy == k", copies R[B] → R[A] then jumps.
 *  Otherwise falls through (no copy, no jump).
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_TESTSET instruction in P->code
 *
 * @param Branches
 *  per-function branch context for deferred forward-jump patching
 *
 * @param ExtraPc
 *  set to 1 to consume the following OP_JMP
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_TestSet( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc,
                          PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int K = GETARG_k( Ins );

    if ( Pc + 1 >= P->sizecode || GET_OPCODE( P->code[ Pc + 1 ] ) != OP_JMP ) {
        fprintf( stderr, "[-] jit: OP_TESTSET at pc %d not followed by OP_JMP\n", Pc );
        return 0;
    }
    int TargetPc = ( Pc + 1 ) + 1 + GETARG_sJ( P->code[ Pc + 1 ] );

    /* compute is_truthy on R[B] → eax */
    if ( !EmitIsTruthyEax( Slot, B ) ) return 0;

    /* cmp eax, K */
    {
        unsigned char Bytes[ 3 ] = { 0x83, 0xF8, ( unsigned char )( int8_t )K };
        if ( !ExecMem_Append( Slot, Bytes, sizeof( Bytes ) ) ) return 0;
    }
    /* jne .done — skip copy + jump when condition doesn't match */
    if ( !EmitX64_JneRel8( Slot, 0 ) ) return 0;
    size_t JnePatch = Slot->Used - 1;

    /* copy R[B] → R[A] (value half through cache if available; tag half memory-only) */
    if ( !EmitLoadRaxFromLua( Slot, B ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RDI, B * 16 + 8 ) ) return 0;
    if ( !EmitX64_MovRegToMem( Slot, X64_RDI, A * 16 + 8, X64_RAX ) ) return 0;

    /* jmp rel32 → TargetPc */
    size_t JmpOff = EmitX64_JmpRel32_Placeholder( Slot );
    if ( JmpOff == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        if ( !EmitX64_PatchRel32( Slot, JmpOff, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        if ( !BranchCtx_AddFwd( Branches, JmpOff, TargetPc, 0 ) ) return 0;
    }

    /* .done: patch the jne to land here */
    size_t DoneOff = Slot->Used;
    if ( !EmitX64_PatchRel8( Slot, JnePatch, DoneOff ) ) return 0;

    *ExtraPc = 1;
    return 1;
}

/*!
 * @brief
 *  Lower OP_FORPREP A Bx: call Rt_ForPrep(L, A). If it returns 1 (skip),
 *  jump forward to Pc + 1 + Bx + 1 (one past the matching FORLOOP).
 *  Otherwise fall through into the loop body.
 */
static int Lower_ForPrep( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches ) {
    Instruction Ins      = P->code[ Pc ];
    int         A        = GETARG_A( Ins );
    int         Bx       = GETARG_Bx( Ins );
    int         TargetPc = Pc + 1 + Bx + 1;  /* one past the FORLOOP */

    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_ForPrep ) ) return 0;
    /* resync cache regs only — Rt_ForPrep (int and float subcases) only
       coerces/writes stack slots, never allocates, and the immediately-
       following `test eax, eax` depends on the helper's return value still
       being in RAX. EmitReloadRdiAndCache would clobber RAX (it reads
       ci/func.p through it). */
    if ( !EmitReloadCacheAll( Slot ) ) return 0;
    /* test eax, eax */
    {
        unsigned char Bytes[ 2 ] = { 0x85, 0xC0 };
        if ( !ExecMem_Append( Slot, Bytes, 2 ) ) return 0;
    }
    /* JNE rel32 -> TargetPc (skip the body if helper returned non-zero) */
    size_t JccOff = EmitX64_JccRel32_Placeholder( Slot, 0x5 /* JNE */ );
    if ( JccOff == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        if ( !EmitX64_PatchRel32( Slot, JccOff, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        if ( !BranchCtx_AddFwd( Branches, JccOff, TargetPc, 0 ) ) return 0;
    }
    return 1;
}

/*!
 * @brief
 *  Lower OP_FORLOOP A Bx: call Rt_ForLoop(L, A). If it returns 1 (continue),
 *  jump back to Pc + 1 - Bx (the first body instruction).
 *  Otherwise fall through (loop done).
 */
static int Lower_ForLoop( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches ) {
    Instruction Ins      = P->code[ Pc ];
    int         A        = GETARG_A( Ins );
    int         Bx       = GETARG_Bx( Ins );
    int         TargetPc = Pc + 1 - Bx;  /* backward jump to first body instr */

    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_ForLoop ) ) return 0;
    /* resync cache regs only — Rt_ForLoop (int and float subcases) is plain
       arithmetic on stack slots (no metamethods, no allocation). RDI stays
       valid. */
    if ( !EmitReloadCacheAll( Slot ) ) return 0;
    /* test eax, eax */
    {
        unsigned char Bytes[ 2 ] = { 0x85, 0xC0 };
        if ( !ExecMem_Append( Slot, Bytes, 2 ) ) return 0;
    }
    /* JNE rel32 -> TargetPc (continue the loop) */
    size_t JccOff = EmitX64_JccRel32_Placeholder( Slot, 0x5 /* JNE */ );
    if ( JccOff == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        /* backward branch: target already in PcOffsets */
        if ( !EmitX64_PatchRel32( Slot, JccOff, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        /* shouldn't happen for FORLOOP, but handle defensively */
        if ( !BranchCtx_AddFwd( Branches, JccOff, TargetPc, 0 ) ) return 0;
    }
    return 1;
}

/*!
 * @brief
 *  Lower OP_NEWTABLE: R[A] = new empty table.
 *  B and C are raw size hints (array and hash respectively). Delegates to
 *  Rt_NewTable which calls luaH_new / luaH_resize / luaC_checkGC.
 *
 * @param Slot
 *  executable memory slot being written
 *
 * @param P
 *  Lua proto containing the instruction
 *
 * @param Pc
 *  index of the OP_NEWTABLE instruction in P->code
 *
 * @return
 *  1 on success, 0 on emission failure
 */
static int Lower_NewTable( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );   /* hash size, log2-encoded */
    int C = GETARG_C( Ins );   /* array size (low bits) */
    /* Decode the size hints like lvm.c OP_NEWTABLE so a constructor presizes
       its parts up front instead of rehashing/growing on every insert: B is
       log2(hashsize)+1, and when the k bit is set the trailing OP_EXTRAARG
       holds the high bits of the array size. (The EXTRAARG at Pc+1 stays an
       inert no-op in the dispatch loop.) Passing the raw B/C made record-shaped
       and >255-element array literals start under-sized. */
    if ( B > 0 ) { B = 1 << ( B - 1 ); }
    if ( GETARG_k( Ins ) && Pc + 1 < P->sizecode ) {
        C += GETARG_Ax( P->code[ Pc + 1 ] ) * ( MAXARG_C + 1 );
    }
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_NewTable ) ) return 0;
    /* resync RDI + cache regs. Rt_NewTable allocates which may trigger
       a GC step + stack realloc. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_GETI: R[A] = R[B][C]  (C is an immediate signed integer index).
 *  Delegates to Rt_GetI which tries luaV_fastgeti then luaV_finishget.
 */
static int Lower_GetI( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_GetI ) ) return 0;
    /* resync RDI + cache regs — Rt_GetI may run a __index metamethod
       (cdata indexing) that grows the Lua stack. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_SETI: R[A][B] = R[C] or K[C]  (B is immediate int index).
 *  Encodes C and k as Ck = k ? -C-1 : C. Delegates to Rt_SetI.
 */
static int Lower_SetI( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int B  = GETARG_B( Ins );
    int C  = GETARG_C( Ins );
    int K  = GETARG_k( Ins );
    int Ck = K ? -C - 1 : C;
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )Ck ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_SetI ) ) return 0;
    /* resync RDI + cache regs — Rt_SetI runs luaV_finishset, which on a
       __newindex metamethod calls luaD_call (arbitrary Lua) that can grow and
       RELOCATE the Lua stack. Without this, a following read of a cached local
       returns a stale value and a following [rdi+..] write lands in freed
       memory (use-after-free). Mirrors the GET twins and Lower_Close. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Lower OP_GETFIELD: R[A] = R[B][K[C]:string].
 *  Delegates to Rt_GetField which uses luaH_getshortstr / luaV_finishget.
 */
static int Lower_GetField( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_GetField ) ) return 0;
    /* resync RDI + cache regs. Rt_GetField may invoke a __index metamethod
       (especially for cdata), which can call checkstackGCp and reallocate
       the Lua stack. After realloc the prologue-captured RDI points into
       freed memory; subsequent writes (e.g. an inline FFI call right after
       ffi.C.GetCurrentProcessId) would land in garbage and silently corrupt
       state. EmitReloadRdiAndCache re-derives RDI from L->ci->func.p+16. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;

    /* detect ffi.C and ffi.C.<sym> patterns */
    if ( g_CurrentKnownFfi != NULL ) {
        static CData_T s_ShadowCache[ KNOWN_FFI_MAX_REGS ];
        PCData_T    BMarker = KnownFfi_Get( g_CurrentKnownFfi, B );
        TValue     *Key     = &P->k[ C ];
        const char *KeyStr  = NULL;
        if ( ttisstring( Key ) ) {
            KeyStr = getstr( tsvalue( Key ) );
        }

        if ( BMarker == ( PCData_T )1 && KeyStr != NULL && strcmp( KeyStr, "C" ) == 0 ) {
            /* R[B] = ffi global, K[C] = "C" → R[A] = ffi.C namespace (sentinel 2) */
            KnownFfi_Mark( g_CurrentKnownFfi, A, ( PCData_T )2 );
        } else if ( BMarker == ( PCData_T )2 && KeyStr != NULL ) {
            /* R[B] = ffi.C namespace, K[C] = symbol name → resolve and mark */
            PCType_T FuncT = Ctype_Lookup( KeyStr );
            if ( FuncT != NULL && FuncT->Kind == CT_FUNC ) {
                void *Addr = Ffi_LookupSymAcrossModules( KeyStr );
                if ( Addr != NULL ) {
                    s_ShadowCache[ A ].Type  = FuncT;
                    s_ShadowCache[ A ].Ptr   = Addr;
                    s_ShadowCache[ A ].Flags = 0;
                    KnownFfi_Mark( g_CurrentKnownFfi, A, &s_ShadowCache[ A ] );
                } else {
                    KnownFfi_Clear( g_CurrentKnownFfi, A );
                }
            } else {
                KnownFfi_Clear( g_CurrentKnownFfi, A );
            }
        } else {
            KnownFfi_Clear( g_CurrentKnownFfi, A );
        }
    }
    return 1;
}

/*!
 * @brief
 *  Lower OP_SETFIELD: R[A][K[B]] = R[C] or K[C].
 *  Encodes C and k as Ck = k ? -C-1 : C. Delegates to Rt_SetField.
 */
static int Lower_SetField( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int B  = GETARG_B( Ins );
    int C  = GETARG_C( Ins );
    int K  = GETARG_k( Ins );
    int Ck = K ? -C - 1 : C;
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )Ck ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_SetField ) ) return 0;
    /* resync RDI + cache regs — Rt_SetField -> luaV_finishset can run a
       __newindex metamethod (luaD_call) that relocates the Lua stack. See
       Lower_SetI for the use-after-free this prevents. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Lower OP_GETTABLE: R[A] = R[B][R[C]].
 *  Delegates to Rt_GetTable which tries fast-integer path then luaV_finishget.
 */
static int Lower_GetTable( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_GetTable ) ) return 0;
    /* resync RDI + cache regs — Rt_GetTable may run a __index metamethod
       that grows the Lua stack (see Lower_GetField for the full reasoning). */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_SETTABLE: R[A][R[B]] = R[C] or K[C].
 *  Encodes C and k as Ck = k ? -C-1 : C. Delegates to Rt_SetTable.
 */
static int Lower_SetTable( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int B  = GETARG_B( Ins );
    int C  = GETARG_C( Ins );
    int K  = GETARG_k( Ins );
    int Ck = K ? -C - 1 : C;
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )Ck ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_SetTable ) ) return 0;
    /* resync RDI + cache regs — Rt_SetTable -> luaV_finishset can run a
       __newindex metamethod (luaD_call) that relocates the Lua stack. See
       Lower_SetI for the use-after-free this prevents. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Lower OP_SETTABUP: UpValue[A][K[B]] = R[C] or K[C].
 *  Encodes C and k as Ck = k ? -C-1 : C. Delegates to Rt_SetTabUp.
 */
static int Lower_SetTabUp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A  = GETARG_A( Ins );
    int B  = GETARG_B( Ins );
    int C  = GETARG_C( Ins );
    int K  = GETARG_k( Ins );
    int Ck = K ? -C - 1 : C;
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B  ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )Ck ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_SetTabUp ) ) return 0;
    /* resync RDI + cache regs — Rt_SetTabUp -> luaV_finishset can run a
       __newindex metamethod (luaD_call) that relocates the Lua stack. See
       Lower_SetI for the use-after-free this prevents. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  Lower OP_LEN: R[A] = #R[B].
 *  Delegates to Rt_Len which calls luaV_objlen.
 */
static int Lower_Len( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_Len ) ) return 0;
    /* resync RDI + cache regs — luaV_objlen may run a __len metamethod
       (Lua function), which can grow the stack. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_CONCAT: R[A] = R[A] .. R[A+1] .. ... .. R[A+B-1] (B values).
 *  Delegates to Rt_Concat which sets L->top, calls luaV_concat, then copies
 *  the result back to R[A].
 */
static int Lower_Concat( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_Concat ) ) return 0;
    /* resync RDI + cache regs. Concat allocates strings and may run a
       __concat metamethod, both of which can grow the Lua stack. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  Lower OP_SETLIST A B C: populate R[A] (a table) with R[A+1..A+B].
 *  B=0 means "use multret": copy R[A+1..L->top-1] into the table — this
 *  is what Lua's compiler emits when a table constructor's last element
 *  is a function call or vararg, e.g. `{ string.byte(s, 1, 3) }`. The
 *  prior OP_CALL/OP_VARARG with multret leaves L->top at the end of
 *  the returned values, and Rt_SetList reads that to compute N.
 *  Delegates to Rt_SetList which resizes the array part and copies values.
 */
static int Lower_SetList( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    int K = GETARG_k( Ins );
    /* k=1 means the next instruction is OP_EXTRAARG whose Ax is the
       high bits of the starting index: real_C = C + Ax * (MAXARG_C + 1).
       Matches lvm.c's OP_SETLIST case. Needed for table literals with
       >MAXARG_C (511) elements in their array part. */
    if ( K ) {
        if ( Pc + 1 >= P->sizecode ) {
            fprintf( stderr, "[-] jit: SETLIST k=1 at pc %d not followed by EXTRAARG\n", Pc );
            return 0;
        }
        Instruction Extra = P->code[ Pc + 1 ];
        if ( GET_OPCODE( Extra ) != OP_EXTRAARG ) {
            fprintf( stderr, "[-] jit: SETLIST k=1 expected OP_EXTRAARG, got %d\n",
                     GET_OPCODE( Extra ) );
            return 0;
        }
        int Ax = GETARG_Ax( Extra );
        C += Ax * ( MAXARG_C + 1 );
        /* leave ExtraPc=0; the EXTRAARG at Pc+1 is handled as a no-op
           by the OP_EXTRAARG case in the outer dispatch */
    }
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_SetList ) ) return 0;
    /* luaH_resizearray inside Rt_SetList can trigger an emergency GC step;
       the GC may shrink the CallInfo chain but does not move the Lua stack.
       RDI (the register base) stays valid, so no reload needed. */
    return 1;
}

/*!
 * @brief
 *  Lower OP_VARARG A C: copy C-1 varargs into R[A..]. C==1 means zero results;
 *  C==0 means all available varargs. Delegates to Rt_Vararg which calls
 *  upstream luaT_getvarargs.
 */
static int Lower_Vararg( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins      = P->code[ Pc ];
    int         A        = GETARG_A( Ins );
    int         C        = GETARG_C( Ins );
    int         NRequired = C - 1;
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A        ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )NRequired ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_Vararg ) ) return 0;
    /* resync RDI + cache regs — Rt_Vararg's MULTRET path calls
       luaT_getvarargs which runs checkstackGCp; that can grow the
       Lua stack and invalidate RDI. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    return 1;
}

extern int Rt_NotOp ( lua_State *L, int A, int B );
extern int Rt_UnmOp ( lua_State *L, int A, int B );
extern int Rt_BNotOp( lua_State *L, int A, int B );

/*!
 * @brief
 *  Emit a Win64 CALL to a 2-argument runtime helper: helper(L, A, B).
 *  RCX = L (restored from RBX), RDX = A, R8 = B.
 */
static int EmitCall2ArgHelper( PEXEC_MEM_SLOT_T Slot, int A, int B, void *Helper ) {
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, Helper ) ) return 0;
    return 1;
}

static int Lower_NotOp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall2ArgHelper( Slot, A, GETARG_B( Ins ),
                              ( void * )Rt_NotOp ) ) return 0;
    /* resync cache regs only — `not` has no metamethod in Lua 5.4,
       Rt_NotOp is a pure setbtvalue/setbfvalue. RDI stays valid. */
    if ( !EmitReloadCacheAll( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_UnmOp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall2ArgHelper( Slot, A, GETARG_B( Ins ),
                              ( void * )Rt_UnmOp ) ) return 0;
    /* resync RDI + cache regs — luaO_arith(LUA_OPUNM) can fire __unm */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_BNotOp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall2ArgHelper( Slot, A, GETARG_B( Ins ),
                              ( void * )Rt_BNotOp ) ) return 0;
    /* resync RDI + cache regs — luaO_arith(LUA_OPBNOT) can fire __bnot */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

extern int Rt_DivOp ( lua_State *L, int A, int B, int C );
extern int Rt_ModOp ( lua_State *L, int A, int B, int C );
extern int Rt_IDivOp( lua_State *L, int A, int B, int C );
extern int Rt_PowOp ( lua_State *L, int A, int B, int C );

/*!
 * @brief
 *  Emit a Win64 CALL to a 3-argument runtime helper: helper(L, A, B, C).
 *  RCX = L (restored from RBX), RDX = A, R8 = B, R9 = C.
 */
static int EmitCall3ArgHelper( PEXEC_MEM_SLOT_T Slot, int A, int B, int C, void *Helper ) {
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )B ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R9,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, Helper ) ) return 0;
    return 1;
}

static int Lower_DivOp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int B = GETARG_B( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitBinArith( Slot, A, B, C, ARITH_DIV, ( void * )Rt_DivOp ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_ModOp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_ModOp ) ) return 0;
    /* resync RDI + cache regs — Rt_ModOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_IDivOp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_IDivOp ) ) return 0;
    /* resync RDI + cache regs — Rt_IDivOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_PowOp( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_PowOp ) ) return 0;
    /* resync RDI + cache regs — Rt_PowOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

extern int Rt_AddKOp ( lua_State *L, int A, int B, int C );
extern int Rt_SubKOp ( lua_State *L, int A, int B, int C );
extern int Rt_MulKOp ( lua_State *L, int A, int B, int C );
extern int Rt_DivKOp ( lua_State *L, int A, int B, int C );
extern int Rt_ModKOp ( lua_State *L, int A, int B, int C );
extern int Rt_IDivKOp( lua_State *L, int A, int B, int C );
extern int Rt_PowKOp ( lua_State *L, int A, int B, int C );
extern int Rt_BAndOp ( lua_State *L, int A, int B, int C );
extern int Rt_BOrOp  ( lua_State *L, int A, int B, int C );
extern int Rt_BXorOp ( lua_State *L, int A, int B, int C );
extern int Rt_ShlOp  ( lua_State *L, int A, int B, int C );
extern int Rt_ShrOp  ( lua_State *L, int A, int B, int C );
extern int Rt_BAndKOp( lua_State *L, int A, int B, int C );
extern int Rt_BOrKOp ( lua_State *L, int A, int B, int C );
extern int Rt_BXorKOp( lua_State *L, int A, int B, int C );
extern int Rt_ShrIOp ( lua_State *L, int A, int B, int sC );
extern int Rt_ShlIOp ( lua_State *L, int A, int B, int sC );
extern int Rt_AddIOp ( lua_State *L, int A, int B, int sC );
extern int Rt_ArithIK( lua_State *L, int A, int B, int MmIns );

/* Shared immediate/K arith lowering driven by the trailing OP_MMBINI/OP_MMBINK
   word: Rt_ArithIK reads the TRUE metamethod event, original operand, and
   operand order from it, so `x - 1` (ADDI x,-1 + MMBINI TM_SUB) dispatches
   __sub(x, 1) -- not __add(x, -1) -- and flipped commutative forms (`1 + x`,
   `2 * x`, `K & x`) hand the metamethod (K, x). The MMBIN* always follows
   (lcode.c finishbinexpval); if it somehow doesn't, fall back to the old
   per-opcode helper (only the raw numeric path can then occur). */
static int Lower_ArithIK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc,
                          int ArgC, void *Fallback ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    int         B   = GETARG_B( Ins );
    OpCode      Nx;
    if ( Pc + 1 < P->sizecode
         && ( ( Nx = GET_OPCODE( P->code[ Pc + 1 ] ) ) == OP_MMBINI
              || Nx == OP_MMBINK ) ) {
        if ( !EmitCall3ArgHelper( Slot, A, B, ( int )P->code[ Pc + 1 ],
                                  ( void * )Rt_ArithIK ) ) return 0;
    } else {
        if ( !EmitCall3ArgHelper( Slot, A, B, ArgC, Fallback ) ) return 0;
    }
    /* resync RDI + cache regs -- the metamethod path may call a Lua fn and
       grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_AddI( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_sC( Ins ), ( void * )Rt_AddIOp );
}

static int Lower_AddK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_AddKOp );
}

static int Lower_SubK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_SubKOp );
}

static int Lower_MulK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_MulKOp );
}

static int Lower_DivK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_DivKOp );
}

static int Lower_ModK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_ModKOp );
}

static int Lower_IDivK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_IDivKOp );
}

static int Lower_PowK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_PowKOp );
}

static int Lower_BAnd( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_BAndOp ) ) return 0;
    /* resync RDI + cache regs — Rt_BAndOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_BOr( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_BOrOp ) ) return 0;
    /* resync RDI + cache regs — Rt_BOrOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_BXor( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_BXorOp ) ) return 0;
    /* resync RDI + cache regs — Rt_BXorOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_Shl( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_ShlOp ) ) return 0;
    /* resync RDI + cache regs — Rt_ShlOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_Shr( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_ShrOp ) ) return 0;
    /* resync RDI + cache regs — Rt_ShrOp luaO_arith path may call a metamethod (Lua fn) and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_BAndK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_BAndKOp );
}

static int Lower_BOrK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_BOrKOp );
}

static int Lower_BXorK( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return Lower_ArithIK( Slot, P, Pc, GETARG_C( Ins ), ( void * )Rt_BXorKOp );
}

/* SHRI/SHLI share one helper (Rt_ShiftI) that reads the trailing OP_MMBINI for
   the true metamethod tag + corrected immediate, so a metatable'd `a << K`
   dispatches __shl(a, K) -- not __shr(a, -K). The MMBINI always follows
   (lcode.c finishbinexpval); if it somehow doesn't, fall back to the old
   per-opcode helper (only the integer fast path can then occur). */
static int Lower_ShiftI( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, void *Fallback ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    int         B   = GETARG_B( Ins );
    if ( Pc + 1 < P->sizecode && GET_OPCODE( P->code[ Pc + 1 ] ) == OP_MMBINI ) {
        if ( !EmitCall3ArgHelper( Slot, A, B, ( int )P->code[ Pc + 1 ],
                                  ( void * )Rt_ShiftI ) ) return 0;
    } else {
        if ( !EmitCall3ArgHelper( Slot, A, B, GETARG_sC( Ins ), Fallback ) ) return 0;
    }
    /* resync RDI + cache regs — the metamethod path may call a Lua fn and grow the stack */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

static int Lower_ShrI( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    return Lower_ShiftI( Slot, P, Pc, ( void * )Rt_ShrIOp );
}

static int Lower_ShlI( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    return Lower_ShiftI( Slot, P, Pc, ( void * )Rt_ShlIOp );
}

extern int Rt_Self( lua_State *L, int A, int B, int C );

#include <string.h>  /* memcpy for Lower_LoadF */

/*!
 * @brief
 *  OP_LOADF A sBx: R[A] = (lua_Number)sBx (load int as float).
 */
static int Lower_LoadF( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins      = P->code[ Pc ];
    int         A        = GETARG_A( Ins );
    int         sBx      = GETARG_sBx( Ins );
    /* convert int to double at compile time, store as 8-byte payload */
    lua_Number FloatVal  = ( lua_Number )sBx;
    uint64_t   AsBits   = { 0 };
    memcpy( &AsBits, &FloatVal, 8 );
    /* mov rax, AsBits ; write through to memory and cache; tag stays memory-only */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, AsBits ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VNUMFLT ) ) return 0;
    ClearKnownFfi( A );
    return 1;
}

/*!
 * @brief
 *  OP_LFALSESKIP A: R[A] = false; pc++. (Used in and/or short-circuit.)
 *  Inline emission: write LUA_VFALSE tag + advance ExtraPc by 1.
 */
/*!
 * @brief
 *  Lower OP_LFALSESKIP A: R[A] := false; pc++.
 *
 *  The "pc++" means the interpreter skips the next instruction (always
 *  OP_LOADTRUE) when falling through to the false case.  In the JIT,
 *  forward comparison branches (EQ/LT/…) target Pc+1 (LOADTRUE), so we
 *  must emit its code here and register its offset in BranchCtx.
 *
 *  Layout emitted:
 *      (false path, reached by fall-through from the prior comparison
 *       NOT taking its branch)
 *      mov rax, 0 ; write-through R[A] = 0 (value part)
 *      mov [rdi + A*16 + 8], LUA_VFALSE
 *      JMP skip                         ; skip the true code
 *  true_code:                           ← registered as PcOffsets[Pc+1]
 *      mov rax, 0 ; write-through R[A] = 0
 *      mov [rdi + A*16 + 8], LUA_VTRUE
 *  skip:
 *      (fall-through to next opcode)
 *
 *  ExtraPc=1 causes the outer loop to skip Pc+1 (LOADTRUE) so its code is
 *  not emitted a second time.
 */
static int Lower_LFalseSkip( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc,
                              PBRANCH_CTX_T Branches, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    ( void )P;

    /* false path: R[A] = false */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, 0 ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VFALSE ) ) return 0;

    /* JMP skip: jump over the true-code block */
    size_t JmpSkipOff = EmitX64_JmpRel8_Placeholder( Slot );
    if ( JmpSkipOff == ( size_t )-1 ) return 0;

    /* true_code: register this offset as Pc+1 (LOADTRUE target) */
    BranchCtx_RecordPc( Branches, Pc + 1, Slot->Used );

    /* R[A] = true */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, 0 ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, LUA_VTRUE ) ) return 0;

    /* skip: patch the JMP to land here */
    if ( !EmitX64_PatchRel8( Slot, JmpSkipOff, Slot->Used ) ) return 0;

    ClearKnownFfi( A );
    *ExtraPc = 1;  /* skip LOADTRUE in the outer loop */
    return 1;
}

/*!
 * @brief
 *  OP_LOADKX A: R[A] = K[Ax] where Ax is the next instruction's Ax field.
 */
static int Lower_LoadKX( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, int *ExtraPc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( Pc + 1 >= P->sizecode ) {
        fprintf( stderr, "[-] jit: LOADKX at pc %d not followed by EXTRAARG\n", Pc );
        return 0;
    }
    Instruction Extra = P->code[ Pc + 1 ];
    if ( GET_OPCODE( Extra ) != OP_EXTRAARG ) {
        fprintf( stderr, "[-] jit: LOADKX expected OP_EXTRAARG, got %d\n",
                 GET_OPCODE( Extra ) );
        return 0;
    }
    int     Ax = GETARG_Ax( Extra );
    TValue *K  = &P->k[ Ax ];
    /* load value half then write through; tag half stays memory-only */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R10, ( uint64_t )( uintptr_t )K ) ) return 0;
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_R10, 0 ) ) return 0;
    if ( !EmitWriteThroughRax( Slot, A ) ) return 0;
    if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_R10, 8 ) ) return 0;
    if ( !EmitX64_MovRegToMem( Slot, X64_RDI, A * 16 + 8, X64_RAX ) ) return 0;
    ClearKnownFfi( A );
    *ExtraPc = 1;  /* skip the EXTRAARG instruction */
    return 1;
}

/*!
 * @brief
 *  OP_SELF A B C: R[A+1] = R[B]; R[A] = R[B][K[C]:string].
 */
static int Lower_Self( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );
    if ( !EmitCall3ArgHelper( Slot, A, GETARG_B( Ins ), GETARG_C( Ins ),
                              ( void * )Rt_Self ) ) return 0;
    /* resync RDI + cache regs — Rt_Self may run __index as a Lua function
       (e.g. ffi.C's symbol lookup), which can grow the stack. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    ClearKnownFfi( A );
    ClearKnownFfi( A + 1 );
    return 1;
}

extern int Rt_Tbc        ( lua_State *L, int A );
extern int Rt_Close      ( lua_State *L, int A );
extern int Rt_VarargPrep ( lua_State *L, int A );

/*!
 * @brief
 *  Emit a Win64 call to a 1-arg helper: RCX = L, RDX = A.
 */
static int EmitCall1ArgHelper( PEXEC_MEM_SLOT_T Slot, int A, void *Helper ) {
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, Helper ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  OP_TBC A: mark R[A] as to-be-closed. Delegates to Rt_Tbc.
 */
static int Lower_Tbc( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    return EmitCall1ArgHelper( Slot, GETARG_A( Ins ), ( void * )Rt_Tbc );
}

/*!
 * @brief
 *  OP_CLOSE A: close all upvalues at or above R[A]. Delegates to Rt_Close.
 */
static int Lower_Close( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    /* Rt_Close runs __close metamethods -- arbitrary Lua that can mutate captured
       upvalues (which alias our stack slots) and reallocate the stack. Re-derive
       RDI and reload every cached register afterward; otherwise the next read of
       an __close-mutated upvalue uses a stale register copy (e.g. a <close> guard
       whose __close writes an enclosing local, read on the following line). */
    if ( !EmitCall1ArgHelper( Slot, GETARG_A( Ins ), ( void * )Rt_Close ) ) return 0;
    return EmitReloadRdiAndCache( Slot );
}

/*!
 * @brief
 *  OP_VARARGPREP A: call Rt_VarargPrep then re-anchor RDI and reload cache.
 *  luaT_adjustvarargs advances ci->func.p, so both RDI and all cache regs
 *  are stale after the call.
 */
static int Lower_VarargPrep( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int         A   = GETARG_A( Ins );

    /* call Rt_VarargPrep(L, A) */
    if ( !EmitCall1ArgHelper( Slot, A, ( void * )Rt_VarargPrep ) ) return 0;
    /* re-derive RDI from relocated ci->func.p, then reload all cache regs */
    return EmitReloadRdiAndCache( Slot );
}

extern int Rt_TForPrep( lua_State *L, int A );
extern int Rt_TForCall( lua_State *L, int A, int C );
extern int Rt_TForLoop( lua_State *L, int A );

/*!
 * @brief
 *  OP_TFORPREP A Bx: call Rt_TForPrep then jump forward by Bx to land
 *  at TFORCALL.
 */
static int Lower_TForPrep( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches ) {
    Instruction Ins      = P->code[ Pc ];
    int         A        = GETARG_A( Ins );
    int         Bx       = GETARG_Bx( Ins );
    int         TargetPc = Pc + 1 + Bx;  /* one past where pc would naturally advance */

    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_TForPrep ) ) return 0;
    /* resync RDI + cache regs — Rt_TForPrep calls luaF_newtbcupval which
       allocates an UpVal and may trigger emergency GC + stack realloc. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    /* JMP rel32 -> TargetPc (always forward in TFORPREP) */
    size_t JmpOff = EmitX64_JmpRel32_Placeholder( Slot );
    if ( JmpOff == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        if ( !EmitX64_PatchRel32( Slot, JmpOff, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        if ( !BranchCtx_AddFwd( Branches, JmpOff, TargetPc, 0 ) ) return 0;
    }
    return 1;
}

/*!
 * @brief
 *  OP_TFORCALL A C: just call Rt_TForCall. No branching.
 */
static int Lower_TForCall( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc ) {
    Instruction Ins = P->code[ Pc ];
    int A = GETARG_A( Ins );
    int C = GETARG_C( Ins );
    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_R8,  ( uint64_t )( int64_t )C ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_TForCall ) ) return 0;
    /* resync RDI + cache regs — Rt_TForCall invokes the iterator (Lua
       fn or C closure) via luaD_call, which can grow the stack. */
    if ( !EmitReloadRdiAndCache( Slot ) ) return 0;
    return 1;
}

/*!
 * @brief
 *  OP_TFORLOOP A Bx: call Rt_TForLoop. If RAX != 0, jump back by Bx
 *  (continue loop). Otherwise fall through.
 */
static int Lower_TForLoop( PEXEC_MEM_SLOT_T Slot, Proto *P, int Pc, PBRANCH_CTX_T Branches ) {
    Instruction Ins      = P->code[ Pc ];
    int         A        = GETARG_A( Ins );
    int         Bx       = GETARG_Bx( Ins );
    int         TargetPc = Pc + 1 - Bx;  /* backward to body start */

    if ( !EmitRestoreL( Slot ) ) return 0;
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RDX, ( uint64_t )( int64_t )A ) ) return 0;
    if ( !EmitX64_CallAbs( Slot, ( void * )Rt_TForLoop ) ) return 0;
    /* resync cache regs only — Rt_TForLoop is a single ttisnil check +
       setobjs2s copy; no metamethod, no allocation. RDI stays valid. */
    if ( !EmitReloadCacheAll( Slot ) ) return 0;
    /* test eax, eax */
    {
        unsigned char Bytes[ 2 ] = { 0x85, 0xC0 };
        if ( !ExecMem_Append( Slot, Bytes, 2 ) ) return 0;
    }
    /* JNE rel32 -> TargetPc (continue if RAX != 0) */
    size_t JccOff = EmitX64_JccRel32_Placeholder( Slot, 0x5 /* JNE */ );
    if ( JccOff == ( size_t )-1 ) return 0;
    if ( TargetPc <= Pc ) {
        if ( !EmitX64_PatchRel32( Slot, JccOff, Branches->PcOffsets[ TargetPc ] ) ) return 0;
    } else {
        if ( !BranchCtx_AddFwd( Branches, JccOff, TargetPc, 0 ) ) return 0;
    }
    return 1;
}
