/*!
 * @brief
 *  FFI callback registry + stub codegen + dispatcher.
 *  Each callback gets a per-signature x64 trampoline that copies its native
 *  arguments (from RCX/RDX/R8/R9 + XMM0..XMM3 for floats + [rbp+0x10+...]
 *  for stack args) into a uniform uint64_t ArgBuf[N], loads the stub id
 *  into ECX and a pointer to ArgBuf into RDX, then calls Callback_Dispatch.
 *  For CT_FLOAT returns, the stub does `movq xmm0, rax` before ret.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "ffi/ffi_callback.h"
#include "ffi/ctype.h"
#include "ffi/marshal.h"
#include "jit/exec_mem.h"

#include "lauxlib.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define FFI_CALLBACK_MAX  256   /* hard cap; bump if real demand emerges */

typedef struct {
    int        InUse;
    int        LuaRef;       /* luaL_ref into LUA_REGISTRYINDEX */
    PCType_T   FuncType;     /* the CT_FUNC ctype (signature) */
    void      *StubAddr;     /* points into g_StubSlab */
} CALLBACK_SLOT_T;

static CALLBACK_SLOT_T g_Callbacks[ FFI_CALLBACK_MAX ];
static EXEC_MEM_SLOT_T g_StubSlab    = { 0 };
static int             g_StubSlabReady = { 0 };
/* Lua state used by the dispatcher. v1 single-threaded — plain global. */
static lua_State      *g_DispatchL   = NULL;

void Ffi_SetDispatchL( lua_State *L ) {
    g_DispatchL = L;
}

/*!
 * @brief
 *  Initialise the stub slab on first use. 256 stubs x ~64 bytes each =
 *  16 KiB worst case; reserve one page.
 */
static int EnsureStubSlab( void ) {
    if ( g_StubSlabReady ) return 1;
    if ( !ExecMem_Reserve( 16384, &g_StubSlab ) ) return 0;
    g_StubSlabReady = 1;
    return 1;
}

void *Ffi_AllocCallback( lua_State *L, PCType_T CallbackType ) {
    if ( CallbackType == NULL || CallbackType->Kind != CT_FUNCPTR ) {
        lua_pop( L, 1 );
        return NULL;
    }
    /* Param shape lives on CT_FUNCPTR (M7 fix); return type on ElemType. */
    PCType_T FuncT = CallbackType;
    if ( FuncT->NumParams < 0 || FuncT->NumParams > 16 ) {
        lua_pop( L, 1 ); return NULL;
    }

    int I = { 0 };
    for ( I = 0; I < FuncT->NumParams; I++ ) {
        PCType_T PT = FuncT->ParamTypes[ I ];
        if ( PT == NULL ) { lua_pop( L, 1 ); return NULL; }
        if ( PT->Kind != CT_INT && PT->Kind != CT_PTR && PT->Kind != CT_FUNCPTR &&
             PT->Kind != CT_BOOL && PT->Kind != CT_ENUM && PT->Kind != CT_FLOAT ) {
            lua_pop( L, 1 ); return NULL;
        }
    }
    PCType_T RT = FuncT->ElemType;
    int RetIsFloat = ( RT != NULL && RT->Kind == CT_FLOAT );
    if ( RT != NULL && RT->Kind != CT_VOID &&
         RT->Kind != CT_INT && RT->Kind != CT_BOOL && RT->Kind != CT_ENUM &&
         RT->Kind != CT_PTR && RT->Kind != CT_FUNCPTR && !RetIsFloat ) {
        lua_pop( L, 1 ); return NULL;
    }

    if ( !EnsureStubSlab( ) ) { lua_pop( L, 1 ); return NULL; }

    int SlotId = -1;
    for ( I = 0; I < FFI_CALLBACK_MAX; I++ ) {
        if ( !g_Callbacks[ I ].InUse ) { SlotId = I; break; }
    }
    if ( SlotId < 0 ) { lua_pop( L, 1 ); return NULL; }

    /* Emit stub bytes. Worst-case for 16 args ~ 250 bytes; use 384 for safety. */
    unsigned char Stub[ 384 ] = { 0 };
    int P = 0;

    /* push rbp; mov rbp, rsp */
    Stub[ P++ ] = 0x55;
    Stub[ P++ ] = 0x48; Stub[ P++ ] = 0x89; Stub[ P++ ] = 0xE5;

    /* FrameB = 0x20 (shadow) + N*8 (ArgBuf), padded to a multiple of 16.
       Entry RSP%16==8; after push rbp %16==0; sub by mult of 16 keeps %16==0
       at the call -- correct Win64 alignment. */
    int N      = FuncT->NumParams;
    int FrameB = 0x20 + N * 8;
    if ( FrameB % 16 != 0 ) FrameB += ( 16 - FrameB % 16 );

    /* sub rsp, FrameB -- 48 81 EC imm32 */
    Stub[ P++ ] = 0x48; Stub[ P++ ] = 0x81; Stub[ P++ ] = 0xEC;
    memcpy( &Stub[ P ], &FrameB, 4 ); P += 4;

    int ArgBufOff = 0x20;

    /* Per-position int-store ModR/M (mod=10, rm=4 SIB, reg=arg-reg).
       MOV [rsp+disp32], <reg>. */
    /* RCX = reg field 1, RDX = reg field 2, R8 = reg field 0 + REX.R, R9 = reg field 1 + REX.R */
    static const unsigned char IntRex   [ 4 ] = { 0x48, 0x48, 0x4C, 0x4C };
    static const unsigned char IntModRM [ 4 ] = { 0x8C, 0x94, 0x84, 0x8C };
    /* MOVSS/MOVSD [rsp+disp32], xmm[i] -- prefix 0F 11 ModR/M SIB disp32.
       ModR/M with mod=10, rm=4 (SIB), reg=xmm[i]: */
    static const unsigned char XmmModRM [ 4 ] = { 0x84, 0x8C, 0x94, 0x9C };

    for ( I = 0; I < N; I++ ) {
        int Off = ArgBufOff + I * 8;
        if ( I < 4 ) {
            if ( FuncT->ParamTypes[ I ]->Kind == CT_FLOAT ) {
                int Pfx = ( FuncT->ParamTypes[ I ]->Size == 4 ) ? 0xF3 : 0xF2;
                Stub[ P++ ] = ( unsigned char )Pfx;
                Stub[ P++ ] = 0x0F; Stub[ P++ ] = 0x11;
                Stub[ P++ ] = XmmModRM[ I ];
                Stub[ P++ ] = 0x24;     /* SIB: scale=0, index=4 (none), base=4 (RSP) */
                memcpy( &Stub[ P ], &Off, 4 ); P += 4;
            } else {
                Stub[ P++ ] = IntRex  [ I ];
                Stub[ P++ ] = 0x89;
                Stub[ P++ ] = IntModRM[ I ];
                Stub[ P++ ] = 0x24;
                memcpy( &Stub[ P ], &Off, 4 ); P += 4;
            }
        } else {
            /* Stack args (Win64): the caller placed arg index >= 4 ABOVE the
               32-byte home/shadow space, not inside it. After `push rbp;
               mov rbp, rsp`:
                 [rbp+0x00]       = saved rbp
                 [rbp+0x08]       = return address
                 [rbp+0x10..0x2F] = 32-byte home space (the spill area the caller
                                    reserves for the REGISTER args 0-3)
                 [rbp+0x30]       = arg index 4 (the first STACK argument)
               So arg i (i >= 4) lives at [rbp + 0x30 + (i-4)*8]. The earlier
               0x10 offset read the home slots (uninitialized) instead of the
               real arguments, so callbacks with > 4 args saw garbage for args
               4+. */
            int CallerOff = 0x30 + ( I - 4 ) * 8;
            /* mov rax, [rbp + CallerOff]  48 8B 85 disp32 */
            Stub[ P++ ] = 0x48; Stub[ P++ ] = 0x8B; Stub[ P++ ] = 0x85;
            memcpy( &Stub[ P ], &CallerOff, 4 ); P += 4;
            /* mov [rsp + Off], rax  48 89 84 24 disp32 */
            Stub[ P++ ] = 0x48; Stub[ P++ ] = 0x89; Stub[ P++ ] = 0x84; Stub[ P++ ] = 0x24;
            memcpy( &Stub[ P ], &Off, 4 ); P += 4;
        }
    }

    /* mov ecx, SlotId   B9 imm32 */
    Stub[ P++ ] = 0xB9;
    memcpy( &Stub[ P ], &SlotId, 4 ); P += 4;
    /* lea rdx, [rsp + ArgBufOff]   48 8D 94 24 disp32 */
    Stub[ P++ ] = 0x48; Stub[ P++ ] = 0x8D; Stub[ P++ ] = 0x94; Stub[ P++ ] = 0x24;
    memcpy( &Stub[ P ], &ArgBufOff, 4 ); P += 4;
    /* mov rax, IMM_DISPATCH   48 B8 imm64 */
    Stub[ P++ ] = 0x48; Stub[ P++ ] = 0xB8;
    {
        uint64_t Fn = ( uint64_t )( uintptr_t )Callback_Dispatch;
        memcpy( &Stub[ P ], &Fn, 8 );
        P += 8;
    }
    /* call rax   FF D0 */
    Stub[ P++ ] = 0xFF; Stub[ P++ ] = 0xD0;

    /* If float return: movq xmm0, rax   66 48 0F 6E C0 */
    if ( RetIsFloat ) {
        Stub[ P++ ] = 0x66; Stub[ P++ ] = 0x48; Stub[ P++ ] = 0x0F;
        Stub[ P++ ] = 0x6E; Stub[ P++ ] = 0xC0;
    }

    /* add rsp, FrameB; pop rbp; ret */
    Stub[ P++ ] = 0x48; Stub[ P++ ] = 0x81; Stub[ P++ ] = 0xC4;
    memcpy( &Stub[ P ], &FrameB, 4 ); P += 4;
    Stub[ P++ ] = 0x5D;
    Stub[ P++ ] = 0xC3;

    /* Round stub size up to 16 for cleanliness. */
    int StubSize = ( P + 15 ) & ~15;
    if ( StubSize > ( int )sizeof( Stub ) ) { lua_pop( L, 1 ); return NULL; }

    if ( g_StubSlab.Used + ( size_t )StubSize > g_StubSlab.Size ) {
        lua_pop( L, 1 ); return NULL;
    }
    void *StubAddr = ( char * )g_StubSlab.Code + g_StubSlab.Used;

    if ( !g_StubSlab.Committed ) {
        if ( !ExecMem_Append( &g_StubSlab, Stub, ( size_t )StubSize ) ) { lua_pop( L, 1 ); return NULL; }
        if ( !ExecMem_Commit( &g_StubSlab ) ) { lua_pop( L, 1 ); return NULL; }
    } else {
        DWORD OldProt = 0;
        if ( !VirtualProtect( g_StubSlab.Code, g_StubSlab.Size, PAGE_READWRITE, &OldProt ) ) {
            lua_pop( L, 1 ); return NULL;
        }
        memcpy( ( char * )g_StubSlab.Code + g_StubSlab.Used, Stub, ( size_t )StubSize );
        g_StubSlab.Used += ( size_t )StubSize;
        if ( !VirtualProtect( g_StubSlab.Code, g_StubSlab.Size, PAGE_EXECUTE_READ, &OldProt ) ) {
            lua_pop( L, 1 ); return NULL;
        }
        FlushInstructionCache( GetCurrentProcess( ), g_StubSlab.Code, g_StubSlab.Size );
    }

    int Ref = luaL_ref( L, LUA_REGISTRYINDEX );
    g_Callbacks[ SlotId ].InUse    = 1;
    g_Callbacks[ SlotId ].LuaRef   = Ref;
    g_Callbacks[ SlotId ].FuncType = FuncT;
    g_Callbacks[ SlotId ].StubAddr = StubAddr;
    return StubAddr;
}

int Ffi_FreeCallback( lua_State *L, void *StubAddr ) {
    int I = { 0 };
    for ( I = 0; I < FFI_CALLBACK_MAX; I++ ) {
        if ( g_Callbacks[ I ].InUse && g_Callbacks[ I ].StubAddr == StubAddr ) {
            luaL_unref( L, LUA_REGISTRYINDEX, g_Callbacks[ I ].LuaRef );
            g_Callbacks[ I ].InUse = 0;
            g_Callbacks[ I ].LuaRef = LUA_NOREF;
            g_Callbacks[ I ].FuncType = NULL;
            g_Callbacks[ I ].StubAddr = NULL;
            return 1;
        }
    }
    return 0;
}

int Ffi_SetCallback( lua_State *L, void *StubAddr ) {
    int I = { 0 };
    for ( I = 0; I < FFI_CALLBACK_MAX; I++ ) {
        if ( g_Callbacks[ I ].InUse && g_Callbacks[ I ].StubAddr == StubAddr ) {
            luaL_unref( L, LUA_REGISTRYINDEX, g_Callbacks[ I ].LuaRef );
            g_Callbacks[ I ].LuaRef = luaL_ref( L, LUA_REGISTRYINDEX );
            return 1;
        }
    }
    lua_pop( L, 1 );
    return 0;
}

int64_t Callback_Dispatch( int StubId, uint64_t *ArgBuf ) {
    if ( g_DispatchL == NULL ) return 0;
    if ( StubId < 0 || StubId >= FFI_CALLBACK_MAX ) return 0;
    if ( !g_Callbacks[ StubId ].InUse ) return 0;

    lua_State *L = g_DispatchL;
    PCType_T   FuncT = g_Callbacks[ StubId ].FuncType;
    int        Ref   = g_Callbacks[ StubId ].LuaRef;

    lua_rawgeti( L, LUA_REGISTRYINDEX, Ref );
    if ( !lua_isfunction( L, -1 ) ) { lua_pop( L, 1 ); return 0; }

    int I = { 0 };
    for ( I = 0; I < FuncT->NumParams; I++ ) {
        Marshal_CToLua( L, FuncT->ParamTypes[ I ], &ArgBuf[ I ] );
    }

    int Status = lua_pcall( L, FuncT->NumParams, 1, 0 );
    if ( Status != LUA_OK ) {
        fprintf( stderr, "[-] callback %d raised: %s\n",
                 StubId, lua_tostring( L, -1 ) );
        lua_pop( L, 1 );
        return 0;
    }

    PCType_T RT = FuncT->ElemType;
    int64_t  Result = 0;
    if ( RT != NULL && RT->Kind != CT_VOID ) {
        if ( Marshal_LuaToC( L, -1, RT, &Result ) == 0 ) {
            fprintf( stderr, "[-] callback %d return marshal failed: %s\n",
                     StubId, lua_tostring( L, -1 ) );
            lua_pop( L, 1 );
        }
    }
    lua_pop( L, 1 );
    return Result;
}
