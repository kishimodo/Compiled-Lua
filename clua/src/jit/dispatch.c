#include "jit/dispatch.h"
#include "jit/exec_mem.h"   /* JIT_CACHE_ENTRY_T embeds EXEC_MEM_SLOT_T */
/* Cache-only dispatch: this file maps Proto* -> pre-registered native entry
** points (AOT bodies registered at startup by LuacProgram_BuildEntry via
** Jit_RegisterCompiled). The v1 JIT compile path was removed when the JIT
** compiler left the tree -- CLua is AOT; the only execution engines are
** compiled native bodies and the reference bytecode interpreter.
**
** Thread model: the cache is process-global by default -- the main thread
** populates it once at startup, then only reads it. A native OS-thread worker
** (thread.spawn native path) builds its OWN Protos in its OWN lua_State, so it
** installs a private thread-local cache (Jit_WorkerCacheBegin/End). Because
** each thread then touches only its own cache, register/lookup need no locks,
** the global 1024-entry table can't be overflowed by many workers, and a
** program that never spawns a worker pays nothing (the g_WorkerThreadsExist
** gate keeps the hot path identical to before). */

#include "ffi/veh.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lopcodes.h"
#include "ldebug.h"
#include "lobject.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* simple linear cache; never evicted within its lifetime */
typedef struct _JIT_CACHE_ENTRY {
    Proto           *P;
    JIT_FUNC_T       Entry;
    EXEC_MEM_SLOT_T  Slot;
    size_t          *PcToOffset;   /* malloc'd: sizecode entries; NULL if not retained */
    int              PcCount;      /* P->sizecode at registration time */
    int              FuncId;       /* protoblob index (stable across states); -1 unknown */
} JIT_CACHE_ENTRY_T, *PJIT_CACHE_ENTRY_T;

/* Open-addressing Proto* -> cache-index map so lookup is O(1) instead of an
   O(Count) linear scan. Lookup runs on the per-call hot path (Rt_Call does
   Jit_LookupCached on every native-to-native call, and the tail-call drive loop
   looks up per iteration). Power-of-two size > 2*JIT_CACHE_MAX keeps the load
   factor <= 0.5; the cache is never evicted, so linear probing needs no
   tombstones. -1 = empty. */
#define JIT_CACHE_MAX 1024
#define JIT_HASH_SIZE 2048

typedef struct _JIT_CACHE {
    JIT_CACHE_ENTRY_T Entries[ JIT_CACHE_MAX ];
    size_t            Count;
    int32_t           Hash[ JIT_HASH_SIZE ];
    int               HashReady;
} JIT_CACHE_T;

/* The default (main-thread) cache. Workers get their own heap-allocated one. */
static JIT_CACHE_T g_GlobalCache;

/* TLS slot holding the current thread's worker cache (NULL => use global).
   g_WorkerThreadsExist flips to 1 the first time any worker installs a cache;
   until then the hot path skips the TLS read entirely. */
static DWORD         g_TlsSlot            = TLS_OUT_OF_INDEXES;
static volatile LONG g_WorkerThreadsExist = 0;

void Jit_InitWorkerTls( void ) {
    if ( g_TlsSlot == TLS_OUT_OF_INDEXES ) {
        g_TlsSlot = TlsAlloc( );   /* called once on the main thread at startup */
    }
}

static JIT_CACHE_T *CurrentCache( void ) {
    if ( g_WorkerThreadsExist && g_TlsSlot != TLS_OUT_OF_INDEXES ) {
        JIT_CACHE_T *C = ( JIT_CACHE_T * )TlsGetValue( g_TlsSlot );
        if ( C != NULL ) return C;
    }
    return &g_GlobalCache;
}

void *Jit_WorkerCacheBegin( void ) {
    if ( g_TlsSlot == TLS_OUT_OF_INDEXES ) return NULL;   /* InitWorkerTls not done */
    JIT_CACHE_T *C = ( JIT_CACHE_T * )calloc( 1, sizeof( JIT_CACHE_T ) );
    if ( C == NULL ) return NULL;
    memset( C->Hash, 0xFF, sizeof( C->Hash ) );           /* all -1 */
    C->HashReady = 1;
    TlsSetValue( g_TlsSlot, C );
    InterlockedExchange( &g_WorkerThreadsExist, 1 );
    return C;
}

void Jit_WorkerCacheEnd( void ) {
    if ( g_TlsSlot == TLS_OUT_OF_INDEXES ) return;
    JIT_CACHE_T *C = ( JIT_CACHE_T * )TlsGetValue( g_TlsSlot );
    if ( C != NULL ) {
        free( C );
        TlsSetValue( g_TlsSlot, NULL );
    }
}

static size_t HashProto( Proto *P ) {
    uintptr_t X = ( uintptr_t )P >> 4;          /* drop allocator alignment bits */
    X *= 0x9E3779B97F4A7C15u;                    /* Fibonacci hashing multiplier */
    return ( size_t )( X >> ( 64 - 11 ) );       /* top 11 bits -> [0, 2048) */
}

static void CacheHashInsert( JIT_CACHE_T *C, int32_t Index, Proto *P ) {
    if ( !C->HashReady ) {
        memset( C->Hash, 0xFF, sizeof( C->Hash ) );  /* all -1 */
        C->HashReady = 1;
    }
    size_t Mask = JIT_HASH_SIZE - 1;
    size_t H    = HashProto( P );
    for ( size_t Probe = 0; Probe < JIT_HASH_SIZE; Probe++ ) {
        size_t S = ( H + Probe ) & Mask;
        if ( C->Hash[ S ] < 0 ) { C->Hash[ S ] = Index; return; }
    }
}

static PJIT_CACHE_ENTRY_T CacheFindIn( JIT_CACHE_T *C, Proto *P ) {
    if ( !C->HashReady ) { return NULL; }       /* nothing registered yet */
    size_t Mask = JIT_HASH_SIZE - 1;
    size_t H    = HashProto( P );
    for ( size_t Probe = 0; Probe < JIT_HASH_SIZE; Probe++ ) {
        int32_t Slot = C->Hash[ ( H + Probe ) & Mask ];
        if ( Slot < 0 ) { return NULL; }                        /* empty -> absent */
        if ( C->Entries[ Slot ].P == P ) { return &C->Entries[ Slot ]; }
    }
    return NULL;
}

JIT_FUNC_T Jit_LookupCached( Proto *P ) {
    PJIT_CACHE_ENTRY_T E = CacheFindIn( CurrentCache( ), P );
    return E != NULL ? E->Entry : NULL;
}

static int RegisterIn( JIT_CACHE_T *C, Proto *P, JIT_FUNC_T Entry, int FuncId ) {
    if ( P == NULL || Entry == NULL ) { return 0; }
    if ( CacheFindIn( C, P ) != NULL ) { return 1; }     /* idempotent */
    if ( C->Count >= JIT_CACHE_MAX ) {
        fprintf( stderr, "[-] jit: cache full (aot register)\n" );
        return 0;
    }
    JIT_CACHE_ENTRY_T *Slot = &C->Entries[ C->Count ];
    memset( Slot, 0, sizeof( *Slot ) );
    Slot->P          = P;
    Slot->Entry      = Entry;          /* points into the PE .text, not exec-mem */
    Slot->PcToOffset = NULL;           /* no pc-map for AOT bodies (M0) */
    Slot->PcCount    = P->sizecode;
    Slot->FuncId     = FuncId;
    CacheHashInsert( C, ( int32_t )C->Count, P );
    C->Count++;
    return 1;
}

int Jit_RegisterCompiled( Proto *P, JIT_FUNC_T Entry ) {
    return RegisterIn( CurrentCache( ), P, Entry, -1 );
}

int Jit_RegisterCompiledId( Proto *P, JIT_FUNC_T Entry, int FuncId ) {
    return RegisterIn( CurrentCache( ), P, Entry, FuncId );
}

int Jit_ProtoFuncId( Proto *P ) {
    PJIT_CACHE_ENTRY_T E = CacheFindIn( CurrentCache( ), P );
    return E != NULL ? E->FuncId : -1;
}

Proto *Jit_ResolveFuncId( int FuncId ) {
    JIT_CACHE_T *C = CurrentCache( );
    size_t I;
    if ( FuncId < 0 ) return NULL;
    for ( I = 0; I < C->Count; I++ ) {
        if ( C->Entries[ I ].FuncId == FuncId ) return C->Entries[ I ].P;
    }
    return NULL;
}

int Jit_TrampolineEntry( lua_State *L, int ( *Fn )( lua_State * ) ) {
    /* Only the outermost JIT entry installs a trampoline frame. Nested
       entries (e.g. pcall → callee → ...) skip the setjmp setup so they
       can't interfere with Lua's own pcall protection: if Lua's error
       mechanism longjmps over a nested trampoline frame, g_CurrentJitFrame
       would be left dangling. One setjmp boundary at the outermost frame
       is sufficient — VEH recovery longjmps directly to it. */
    if ( Veh_GetJitFrame( ) != NULL ) {
        return Fn( L );
    }

    JIT_FRAME_T Frame = { 0 };
    Frame.Prev       = NULL;
    Frame.PrevLuaTop = ( void * )L->top.p;
    Veh_SetJitFrame( &Frame );

    int Result = 0;
    if ( setjmp( Frame.RecoveryJmp ) == 0 ) {
        Result = Fn( L );
    } else {
        /* VEH longjmped here -- a JIT'd function faulted. */
        L->top.p = ( StkId )Frame.PrevLuaTop;
        Veh_SetJitFrame( NULL );
        luaL_error( L, "%s", Frame.FaultMessage );
        /* unreachable */
    }

    Veh_SetJitFrame( NULL );
    return Result;
}

void *Jit_DebugGetPcAddress( Proto *P, int Pc ) {
    if ( P == NULL ) return NULL;
    PJIT_CACHE_ENTRY_T E = CacheFindIn( CurrentCache( ), P );
    if ( E == NULL || E->PcToOffset == NULL ) return NULL;
    if ( Pc < 0 || Pc >= E->PcCount ) return NULL;
    size_t Off = E->PcToOffset[ Pc ];
    if ( Off == 0 && Pc > 0 ) return NULL;  /* not emitted */
    return ( void * )( ( unsigned char * )E->Slot.Code + Off );
}

int Jit_LookupSourceLine( void *Rip, const char **OutSource, int *OutLine ) {
    if ( Rip == NULL || OutSource == NULL || OutLine == NULL ) return 0;
    uintptr_t R = ( uintptr_t )Rip;
    JIT_CACHE_T *C = CurrentCache( );
    size_t I = 0;
    for ( I = 0; I < C->Count; I++ ) {
        PJIT_CACHE_ENTRY_T E = &C->Entries[ I ];
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
