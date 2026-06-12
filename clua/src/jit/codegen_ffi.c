/*!
 * @brief
 *  KnownFfi side table + Lower_FfiCallInline. The inline path dispatches
 *  through the per-signature thunk (Ffi_GetSignatureThunk) so it inherits
 *  the same 16-arg / float / double support as Ffi_GenericCall, while
 *  staying register-passed and skipping the Rt_Call detour.
 */

#include "jit/codegen_ffi.h"
#include "jit/emit_x64.h"
#include "ffi/cdata.h"
#include "ffi/ctype.h"
#include "ffi/ffi_thunk.h"

#include "lua.h"
#include "lobject.h"
#include "lstate.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

void KnownFfi_Reset( PKNOWN_FFI_T K ) {
    if ( K == NULL ) return;
    memset( K, 0, sizeof( *K ) );
}

void KnownFfi_Mark( PKNOWN_FFI_T K, int Reg, PCData_T Cd ) {
    if ( K == NULL || Reg < 0 || Reg >= KNOWN_FFI_MAX_REGS ) return;
    K->Known[ Reg ] = Cd;
}

void KnownFfi_Clear( PKNOWN_FFI_T K, int Reg ) {
    if ( K == NULL || Reg < 0 || Reg >= KNOWN_FFI_MAX_REGS ) return;
    K->Known[ Reg ] = NULL;
}

PCData_T KnownFfi_Get( PKNOWN_FFI_T K, int Reg ) {
    if ( K == NULL || Reg < 0 || Reg >= KNOWN_FFI_MAX_REGS ) return NULL;
    return K->Known[ Reg ];
}

int Lower_FfiCallInline( PEXEC_MEM_SLOT_T Slot, PCData_T FnCd, int A, int NArgs ) {
    if ( FnCd == NULL || FnCd->Type == NULL || FnCd->Ptr == NULL ) return 0;
    PCType_T FuncT = FnCd->Type;
    if ( FuncT->Kind != CT_FUNC ) return 0;
    if ( ( int )FuncT->NumParams != NArgs ) return 0;
    if ( NArgs > 16 ) return 0;

    FFI_THUNK_T Thunk = Ffi_GetSignatureThunk( FuncT );
    if ( Thunk == NULL ) return 0;

    /* v1 JIT-inline still only handles int-like-from-stack-slot args. Float
       args go through the generic dispatch path (which also uses the thunk).
       The JIT stores integer args in TValue.value_.i; a Lua-level float arg
       lives in TValue.value_.n and would need conversion to the CT_FLOAT bit
       pattern at the JIT site. Deferred to a follow-up. */
    int I = { 0 };
    for ( I = 0; I < NArgs; I++ ) {
        PCType_T PT = FuncT->ParamTypes[ I ];
        if ( PT == NULL ) return 0;
        /* v1.1: inline path only handles params whose 8-byte TValue.value
           half equals the value to pass. For CT_INT/BOOL/ENUM that's the
           integer. For CT_PTR/FUNCPTR the value half is a Lua GC pointer
           (TString* / Udata*), NOT the target pointer -- needs Marshal_LuaToC
           which the inline path can't call inline. Reject pointers; the
           generic dispatcher (Ffi_GenericCall via thunk) handles them
           correctly with Marshal_LuaToC. */
        if ( PT->Kind != CT_INT && PT->Kind != CT_BOOL && PT->Kind != CT_ENUM ) {
            return 0;
        }
    }
    PCType_T RT         = FuncT->ElemType;
    int      RetIsFloat = ( RT != NULL && RT->Kind == CT_FLOAT );
    if ( RT != NULL && RT->Kind != CT_VOID &&
         RT->Kind != CT_INT && RT->Kind != CT_BOOL && RT->Kind != CT_ENUM &&
         !RetIsFloat ) {
        return 0;
    }

    /* Inline FFI: int-like args only (CT_INT/BOOL/ENUM). Pointer params and
       any other kind fall through to the generic dispatcher in Ffi_GenericCall
       which marshals correctly via Marshal_LuaToC. */
    /* Stack layout (after sub rsp, FrameB):
         [rsp + 0x00 .. 0x1F]   shadow space for callee
         [rsp + 0x20 .. 0x9F]   Args[16] (16 * 8 = 128 bytes)
         [rsp + 0xA0]           Result (8 bytes)
       FrameB = 0xA0 + 8 = 0xA8, round up to 0xB0 (multiple of 16). */
    int ArgsBaseOff = 0x20;
    int ResultOff   = 0xA0;
    int FrameB      = 0xB0;

    if ( !EmitX64_SubRspImm( Slot, FrameB ) ) return 0;

    /* Marshal each arg: mov rax, [rdi + (A+1+i)*16]; mov [rsp + ArgsBaseOff + i*8], rax */
    for ( I = 0; I < NArgs; I++ ) {
        int FromOffset = ( A + 1 + I ) * 16;
        if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RDI, FromOffset ) ) return 0;
        if ( !EmitX64_MovRegToMem( Slot, X64_RSP, ArgsBaseOff + I * 8, X64_RAX ) ) return 0;
    }

    /* Set up thunk args: RCX = Fn, RDX = &Args, R8 = &Result */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RCX, ( uint64_t )( uintptr_t )FnCd->Ptr ) ) return 0;
    /* lea rdx, [rsp + ArgsBaseOff]   48 8D 94 24 disp32 */
    {
        unsigned char Lea[ 8 ] = { 0x48, 0x8D, 0x94, 0x24, 0, 0, 0, 0 };
        memcpy( &Lea[ 4 ], &ArgsBaseOff, 4 );
        if ( !ExecMem_Append( Slot, Lea, 8 ) ) return 0;
    }
    /* lea r8, [rsp + ResultOff]   4C 8D 84 24 disp32 */
    {
        unsigned char Lea[ 8 ] = { 0x4C, 0x8D, 0x84, 0x24, 0, 0, 0, 0 };
        memcpy( &Lea[ 4 ], &ResultOff, 4 );
        if ( !ExecMem_Append( Slot, Lea, 8 ) ) return 0;
    }
    /* call thunk (absolute via rax inside EmitX64_CallAbs) */
    if ( !EmitX64_CallAbs( Slot, ( void * )Thunk ) ) return 0;

    /* Load the result back into R[A]. */
    int Nres = 0;
    if ( RT != NULL && RT->Kind != CT_VOID ) {
        if ( !EmitX64_MovMemToReg( Slot, X64_RAX, X64_RSP, ResultOff ) ) return 0;
        if ( !EmitX64_MovRegToMem( Slot, X64_RDI, A * 16, X64_RAX ) ) return 0;
        /* int-like return -> LUA_VNUMINT; float-like -> LUA_VNUMFLT. */
        int Tag = RetIsFloat ? LUA_VNUMFLT : LUA_VNUMINT;
        if ( !EmitX64_MovImm32ToMem( Slot, X64_RDI, A * 16 + 8, Tag ) ) return 0;
        Nres = 1;
    }

    if ( !EmitX64_AddRspImm( Slot, FrameB ) ) return 0;

    /* Set L->top.p = RDI + (A + Nres) * 16 (= &R[A + Nres]). The generic
       Rt_Call path normally does this inside luaD_poscall. Without it, a
       chained call like `tonumber(ffi.C.Foo())` -- where the outer
       OP_CALL uses MULTRET-arg semantics (B=0) and reads NArgs from
       L->top - func - 1 -- sees a stale higher L->top and passes
       extra phantom args to the outer callee. */
    {
        int Disp = ( A + Nres ) * 16;
        /* lea rax, [rdi + disp32]   48 8D 87 disp32 */
        unsigned char Lea[ 7 ] = { 0x48, 0x8D, 0x87, 0, 0, 0, 0 };
        memcpy( &Lea[ 3 ], &Disp, 4 );
        if ( !ExecMem_Append( Slot, Lea, 7 ) ) return 0;
        /* mov [rbx + offsetof(lua_State, top)], rax   48 89 83 disp32 */
        int TopOff = ( int )offsetof( struct lua_State, top );
        unsigned char Mov[ 7 ] = { 0x48, 0x89, 0x83, 0, 0, 0, 0 };
        memcpy( &Mov[ 3 ], &TopOff, 4 );
        if ( !ExecMem_Append( Slot, Mov, 7 ) ) return 0;
    }
    return 1;
}
