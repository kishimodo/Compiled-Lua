/*!
 * @brief
 *  Per-signature thunk codegen. The emitted thunk is uniform-interface
 *  (void(*)(void *Fn, uint64_t *Args, uint64_t *Result)) but its body
 *  unrolls Win64 ABI placement for one specific signature.
 *
 *  Cache is keyed by ctype pointer (ctypes are interned, so identity
 *  comparison is sufficient).
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "ffi/ffi_thunk.h"
#include "jit/exec_mem.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define THUNK_MAX            512
#define THUNK_SLAB_BYTES   16384
#define THUNK_MAX_ARGS       16

typedef struct {
    PCType_T     FuncT;
    FFI_THUNK_T  Thunk;
} THUNK_CACHE_ENTRY_T;

static THUNK_CACHE_ENTRY_T g_Cache[ THUNK_MAX ];
static int                 g_CacheCount = 0;
static EXEC_MEM_SLOT_T     g_Slab       = { 0 };
static int                 g_SlabReady  = 0;

static int EnsureSlab( void ) {
    if ( g_SlabReady ) return 1;
    if ( !ExecMem_Reserve( THUNK_SLAB_BYTES, &g_Slab ) ) return 0;
    g_SlabReady = 1;
    return 1;
}

void Ffi_ResetThunkCache( void ) {
    g_CacheCount = 0;
    memset( g_Cache, 0, sizeof( g_Cache ) );
    if ( g_SlabReady ) {
        ExecMem_Release( &g_Slab );
        memset( &g_Slab, 0, sizeof( g_Slab ) );
        g_SlabReady = 0;
    }
}

static FFI_THUNK_T CacheFind( PCType_T FuncT ) {
    int I = 0;
    for ( I = 0; I < g_CacheCount; I++ ) {
        if ( g_Cache[ I ].FuncT == FuncT ) return g_Cache[ I ].Thunk;
    }
    return NULL;
}

static int IsIntLike( int Kind ) {
    return Kind == CT_INT  || Kind == CT_PTR  || Kind == CT_FUNCPTR ||
           Kind == CT_BOOL || Kind == CT_ENUM;
}

static int IsFloatLike( int Kind ) {
    return Kind == CT_FLOAT;
}

FFI_THUNK_T Ffi_GetSignatureThunk( PCType_T FuncT ) {
    /* Accept both CT_FUNC and CT_FUNCPTR -- the cdecl parser flattens
       NumParams/ParamTypes onto the CT_FUNCPTR (M7 fix), so the same
       fields work regardless of which kind we got. */
    if ( FuncT == NULL ) return NULL;
    if ( FuncT->Kind != CT_FUNC && FuncT->Kind != CT_FUNCPTR ) return NULL;
    if ( FuncT->NumParams < 0 || FuncT->NumParams > THUNK_MAX_ARGS ) return NULL;
    /* v1: variadic functions parse but aren't callable. The runtime caller
       (Ffi_GenericCall) raises a clear Lua error. */
    if ( FuncT->HasVararg ) return NULL;

    int I = 0;
    for ( I = 0; I < FuncT->NumParams; I++ ) {
        PCType_T PT = FuncT->ParamTypes[ I ];
        if ( PT == NULL ) return NULL;
        if ( !IsIntLike( PT->Kind ) && !IsFloatLike( PT->Kind ) ) return NULL;
    }
    PCType_T RT = FuncT->ElemType;
    if ( RT != NULL && RT->Kind != CT_VOID ) {
        if ( !IsIntLike( RT->Kind ) && !IsFloatLike( RT->Kind ) ) return NULL;
    }

    FFI_THUNK_T Existing = CacheFind( FuncT );
    if ( Existing != NULL ) return Existing;

    if ( g_CacheCount >= THUNK_MAX ) return NULL;
    if ( !EnsureSlab( ) )            return NULL;

    unsigned char Code[ 512 ] = { 0 };
    int P = 0;

    /* push rbp; mov rbp, rsp; push rbx */
    Code[ P++ ] = 0x55;
    Code[ P++ ] = 0x48; Code[ P++ ] = 0x89; Code[ P++ ] = 0xE5;
    Code[ P++ ] = 0x53;

    /* FrameB: 0x20 shadow + stack-arg area. Entry RSP%16==8 (caller's CALL
       pushed RA). After push rbp + push rbx (two 8-byte pushes), RSP%16
       remains 8. Win64 callees require RSP%16==0 immediately before the
       CALL that targets them, so ReserveB must be 8 mod 16 (sub rsp, 8-mod-16
       brings RSP%16 from 8 to 0). */
    int NStack   = FuncT->NumParams > 4 ? FuncT->NumParams - 4 : 0;
    int ReserveB = 0x20 + 8 * NStack;
    if ( ReserveB % 16 != 8 ) ReserveB += ( ( 8 - ReserveB % 16 + 16 ) % 16 );

    /* sub rsp, ReserveB -- 48 81 EC imm32 */
    Code[ P++ ] = 0x48; Code[ P++ ] = 0x81; Code[ P++ ] = 0xEC;
    memcpy( &Code[ P ], &ReserveB, 4 ); P += 4;

    /* mov r11, rcx -- 49 89 CB */
    Code[ P++ ] = 0x49; Code[ P++ ] = 0x89; Code[ P++ ] = 0xCB;
    /* mov r10, rdx -- 49 89 D2 */
    Code[ P++ ] = 0x49; Code[ P++ ] = 0x89; Code[ P++ ] = 0xD2;
    /* mov rbx, r8 -- 4C 89 C3 */
    Code[ P++ ] = 0x4C; Code[ P++ ] = 0x89; Code[ P++ ] = 0xC3;

    /* Stack args first (so we don't clobber rcx/rdx before r10 is read). */
    for ( I = 4; I < FuncT->NumParams; I++ ) {
        int Off = I * 8;
        /* mov rax, [r10 + Off]   49 8B 82 disp32 */
        Code[ P++ ] = 0x49; Code[ P++ ] = 0x8B; Code[ P++ ] = 0x82;
        memcpy( &Code[ P ], &Off, 4 ); P += 4;
        /* mov [rsp + StackOff], rax   48 89 84 24 disp32 */
        int StackOff = 0x20 + ( I - 4 ) * 8;
        Code[ P++ ] = 0x48; Code[ P++ ] = 0x89; Code[ P++ ] = 0x84; Code[ P++ ] = 0x24;
        memcpy( &Code[ P ], &StackOff, 4 ); P += 4;
    }

    /* Args 0..3 to registers. Per-position ModR/M for register destinations
       (mod=10, rm=r10 low3=2). */
    /*                                         RCX   RDX   R8    R9   */
    static const unsigned char IntRex  [ 4 ] = { 0x49, 0x49, 0x4D, 0x4D };
    static const unsigned char IntModRM[ 4 ] = { 0x8A, 0x92, 0x82, 0x8A };
    /*                                         xmm0  xmm1  xmm2  xmm3 */
    static const unsigned char XmmModRM[ 4 ] = { 0x82, 0x8A, 0x92, 0x9A };

    int Limit = FuncT->NumParams < 4 ? FuncT->NumParams : 4;
    for ( I = 0; I < Limit; I++ ) {
        int Off = I * 8;
        if ( IsFloatLike( FuncT->ParamTypes[ I ]->Kind ) ) {
            int Pfx = ( FuncT->ParamTypes[ I ]->Size == 4 ) ? 0xF3 : 0xF2;
            /* prefix REX.B 0F 10 ModR/M disp32 */
            Code[ P++ ] = ( unsigned char )Pfx;
            Code[ P++ ] = 0x41;        /* REX.B = 1 for r10 base */
            Code[ P++ ] = 0x0F; Code[ P++ ] = 0x10;
            Code[ P++ ] = XmmModRM[ I ];
            memcpy( &Code[ P ], &Off, 4 ); P += 4;
        } else {
            Code[ P++ ] = IntRex  [ I ];
            Code[ P++ ] = 0x8B;
            Code[ P++ ] = IntModRM[ I ];
            memcpy( &Code[ P ], &Off, 4 ); P += 4;
        }
    }

    /* call r11 -- 41 FF D3 */
    Code[ P++ ] = 0x41; Code[ P++ ] = 0xFF; Code[ P++ ] = 0xD3;

    /* Return packing into [rbx]. */
    if ( RT != NULL && RT->Kind != CT_VOID ) {
        if ( IsFloatLike( RT->Kind ) ) {
            /* movq rax, xmm0   66 48 0F 7E C0 */
            Code[ P++ ] = 0x66; Code[ P++ ] = 0x48; Code[ P++ ] = 0x0F;
            Code[ P++ ] = 0x7E; Code[ P++ ] = 0xC0;
        }
        /* mov [rbx], rax   48 89 03 */
        Code[ P++ ] = 0x48; Code[ P++ ] = 0x89; Code[ P++ ] = 0x03;
    }

    /* Epilogue: add rsp, ReserveB; pop rbx; pop rbp; ret. */
    Code[ P++ ] = 0x48; Code[ P++ ] = 0x81; Code[ P++ ] = 0xC4;
    memcpy( &Code[ P ], &ReserveB, 4 ); P += 4;
    Code[ P++ ] = 0x5B;
    Code[ P++ ] = 0x5D;
    Code[ P++ ] = 0xC3;

    if ( P > ( int )sizeof( Code ) ) return NULL;

    /* Round thunk size up to 16. */
    int ThunkSize = ( P + 15 ) & ~15;
    if ( ThunkSize > ( int )sizeof( Code ) ) return NULL;

    /* Place into slab. Same pattern as ffi_callback.c. */
    if ( g_Slab.Used + ( size_t )ThunkSize > g_Slab.Size ) return NULL;
    void *ThunkAddr = ( char * )g_Slab.Code + g_Slab.Used;

    if ( !g_Slab.Committed ) {
        if ( !ExecMem_Append( &g_Slab, Code, ( size_t )ThunkSize ) ) return NULL;
        if ( !ExecMem_Commit( &g_Slab ) )                            return NULL;
    } else {
        /* already RX -- flip RW, write, flip back, flush icache */
        DWORD OldProt = 0;
        if ( !VirtualProtect( g_Slab.Code, g_Slab.Size, PAGE_READWRITE, &OldProt ) ) return NULL;
        memcpy( ( char * )g_Slab.Code + g_Slab.Used, Code, ( size_t )ThunkSize );
        g_Slab.Used += ( size_t )ThunkSize;
        if ( !VirtualProtect( g_Slab.Code, g_Slab.Size, PAGE_EXECUTE_READ, &OldProt ) ) return NULL;
        FlushInstructionCache( GetCurrentProcess( ), g_Slab.Code, g_Slab.Size );
    }

    g_Cache[ g_CacheCount ].FuncT = FuncT;
    g_Cache[ g_CacheCount ].Thunk = ( FFI_THUNK_T )ThunkAddr;
    g_CacheCount++;
    return ( FFI_THUNK_T )ThunkAddr;
}
