#include "jit/dispatch.h"
#include "jit/exec_mem.h"   /* JIT_CACHE_ENTRY_T embeds EXEC_MEM_SLOT_T */
/* Cache-only dispatch: this file maps Proto* -> pre-registered native entry
** points (AOT bodies registered at startup by LuacProgram_BuildEntry via
** Jit_RegisterCompiled). The v1 JIT compile path was removed when the JIT
** compiler left the tree -- CLua is AOT; the only execution engines are
** compiled native bodies and the reference bytecode interpreter. */

#include "ffi/veh.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lopcodes.h"
#include "ldebug.h"
#include "lobject.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* simple linear cache; process-wide and never evicted */
typedef struct _JIT_CACHE_ENTRY {
    Proto           *P;
    JIT_FUNC_T       Entry;
    EXEC_MEM_SLOT_T  Slot;
    size_t          *PcToOffset;   /* malloc'd: sizecode entries; NULL if not retained */
    int              PcCount;      /* P->sizecode at registration time */
} JIT_CACHE_ENTRY_T, *PJIT_CACHE_ENTRY_T;

#define JIT_CACHE_MAX 1024
static JIT_CACHE_ENTRY_T g_Cache[ JIT_CACHE_MAX ] = { 0 };
static size_t            g_CacheCount             = { 0 };

/* Open-addressing Proto* -> cache-index map so CacheFind is O(1) instead of an
   O(g_CacheCount) linear scan. CacheFind runs on the per-call hot path (Rt_Call
   does Jit_LookupCached on every native-to-native call, and the tail-call drive
   loop looks up per iteration), so with N registered protos the old scan made
   call overhead grow with program size. Power-of-two size > 2*JIT_CACHE_MAX
   keeps the load factor <= 0.5; the cache is never evicted (no removal path
   anywhere in src/jit), so linear probing needs no tombstones. -1 = empty. */
#define JIT_HASH_SIZE 2048
static int32_t g_CacheHash[ JIT_HASH_SIZE ];
static int     g_CacheHashReady = 0;

static size_t HashProto( Proto *P ) {
    uintptr_t X = ( uintptr_t )P >> 4;          /* drop allocator alignment bits */
    X *= 0x9E3779B97F4A7C15u;                    /* Fibonacci hashing multiplier */
    return ( size_t )( X >> ( 64 - 11 ) );       /* top 11 bits -> [0, 2048) */
}

static void CacheHashInsert( int32_t Index, Proto *P ) {
    if ( !g_CacheHashReady ) {
        memset( g_CacheHash, 0xFF, sizeof( g_CacheHash ) );  /* all -1 */
        g_CacheHashReady = 1;
    }
    size_t Mask = JIT_HASH_SIZE - 1;
    size_t H    = HashProto( P );
    for ( size_t Probe = 0; Probe < JIT_HASH_SIZE; Probe++ ) {
        size_t S = ( H + Probe ) & Mask;
        if ( g_CacheHash[ S ] < 0 ) { g_CacheHash[ S ] = Index; return; }
    }
}

static PJIT_CACHE_ENTRY_T CacheFind( Proto *P ) {
    if ( !g_CacheHashReady ) { return NULL; }   /* nothing compiled yet */
    size_t Mask = JIT_HASH_SIZE - 1;
    size_t H    = HashProto( P );
    for ( size_t Probe = 0; Probe < JIT_HASH_SIZE; Probe++ ) {
        int32_t Slot = g_CacheHash[ ( H + Probe ) & Mask ];
        if ( Slot < 0 ) { return NULL; }                       /* empty -> absent */
        if ( g_Cache[ Slot ].P == P ) { return &g_Cache[ Slot ]; }
    }
    return NULL;
}

JIT_FUNC_T Jit_LookupCached( Proto *P ) {
    PJIT_CACHE_ENTRY_T E = CacheFind( P );
    return E != NULL ? E->Entry : NULL;
}

int Jit_RegisterCompiled( Proto *P, JIT_FUNC_T Entry ) {
    if ( P == NULL || Entry == NULL ) { return 0; }
    if ( CacheFind( P ) != NULL ) { return 1; }          /* idempotent */
    if ( g_CacheCount >= JIT_CACHE_MAX ) {
        fprintf( stderr, "[-] jit: cache full (aot register)\n" );
        return 0;
    }
    JIT_CACHE_ENTRY_T *Slot = &g_Cache[ g_CacheCount ];
    memset( Slot, 0, sizeof( *Slot ) );
    Slot->P          = P;
    Slot->Entry      = Entry;          /* points into the PE .text, not exec-mem */
    Slot->PcToOffset = NULL;           /* no pc-map for AOT bodies (M0) */
    Slot->PcCount    = P->sizecode;
    CacheHashInsert( ( int32_t )g_CacheCount, P );
    g_CacheCount++;
    return 1;
}

int Jit_TrampolineEntry( lua_State *L, int ( *Fn )( lua_State * ) ) {
    /* Only the outermost JIT entry installs a trampoline frame. Nested
       entries (e.g. pcall → callee → ...) skip the setjmp setup so they
       can't interfere with Lua's own pcall protection: if Lua's error
       mechanism longjmps over a nested trampoline frame, g_CurrentJitFrame
       would be left dangling. One setjmp boundary at the outermost frame
       is sufficient — VEH recovery longjmps directly to it. */
    if ( g_CurrentJitFrame != NULL ) {
        return Fn( L );
    }

    JIT_FRAME_T Frame = { 0 };
    Frame.Prev       = NULL;
    Frame.PrevLuaTop = ( void * )L->top.p;
    g_CurrentJitFrame = &Frame;

    int Result = 0;
    if ( setjmp( Frame.RecoveryJmp ) == 0 ) {
        Result = Fn( L );
    } else {
        /* VEH longjmped here -- a JIT'd function faulted. */
        L->top.p = ( StkId )Frame.PrevLuaTop;
        g_CurrentJitFrame = NULL;
        luaL_error( L, "%s", Frame.FaultMessage );
        /* unreachable */
    }

    g_CurrentJitFrame = NULL;
    return Result;
}

void *Jit_DebugGetPcAddress( Proto *P, int Pc ) {
    if ( P == NULL ) return NULL;
    PJIT_CACHE_ENTRY_T E = CacheFind( P );
    if ( E == NULL || E->PcToOffset == NULL ) return NULL;
    if ( Pc < 0 || Pc >= E->PcCount ) return NULL;
    size_t Off = E->PcToOffset[ Pc ];
    if ( Off == 0 && Pc > 0 ) return NULL;  /* not emitted */
    return ( void * )( ( unsigned char * )E->Slot.Code + Off );
}

int Jit_LookupSourceLine( void *Rip, const char **OutSource, int *OutLine ) {
    if ( Rip == NULL || OutSource == NULL || OutLine == NULL ) return 0;
    uintptr_t R = ( uintptr_t )Rip;
    size_t I = 0;
    for ( I = 0; I < g_CacheCount; I++ ) {
        PJIT_CACHE_ENTRY_T E = &g_Cache[ I ];
        uintptr_t S = ( uintptr_t )E->Slot.Code;
        if ( R < S || R >= S + E->Slot.Used ) continue;
        if ( E->PcToOffset == NULL || E->PcCount <= 0 || E->P == NULL ) return 0;

        size_t Off = ( size_t )( R - S );
        /* Find the largest PC whose offset is <= Off. PcToOffset is
           non-decreasing for straight-line code; for control-flow we still
           pick the largest predecessor — Lua's lineinfo handles that. */
        int BestPc = -1;
        size_t BestOff = 0;
        int Pc = 0;
        for ( Pc = 0; Pc < E->PcCount; Pc++ ) {
            size_t Po = E->PcToOffset[ Pc ];
            if ( Po == 0 && Pc > 0 ) continue;  /* not emitted (e.g. dead opcode) */
            if ( Po <= Off && Po >= BestOff ) {
                BestPc  = Pc;
                BestOff = Po;
            }
        }
        if ( BestPc < 0 ) return 0;

        int Line = luaG_getfuncline( E->P, BestPc );
        const char *Src = NULL;
        if ( E->P->source != NULL ) {
            Src = getstr( E->P->source );
        }
        if ( Src == NULL || Line <= 0 ) return 0;
        *OutSource = Src;
        *OutLine   = Line;
        return 1;
    }
    return 0;
}
