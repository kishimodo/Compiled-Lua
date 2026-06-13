/*!
 * @brief
 *  Fiber-based Lua coroutine library. See coro.h for design.
 *
 *  Per-coroutine state (CORO_T):
 *    Fiber:       Windows fiber HANDLE created with the requested stack
 *    L:           this coroutine's lua_State (a thread-of-thread of the
 *                 main lua_State)
 *    OwnerThread: OS thread that created this coroutine. Resuming from a
 *                 different OS thread is rejected (would corrupt the fiber
 *                 chain since fibers are bound to threads via SwitchToFiber)
 *    CallerFiber: fiber to switch back to on yield. Set per-resume.
 *    Status:      SUSPENDED / RUNNING / NORMAL / DEAD
 *    Started:     0 until first resume; 1 thereafter
 *    LuaRefSelf:  registry ref keeping our cdata alive while the fiber is
 *                 live (otherwise GC of the cdata would DeleteFiber while
 *                 the fiber is still suspended)
 *    HasError:    1 if the fiber's main call raised a Lua error. Stack top
 *                 holds the error message in that case.
 *
 *  "Current coroutine" tracking is per-OS-thread via thread-local storage
 *  (__declspec(thread)). FLS would NOT work here -- it's per-fiber, so
 *  switching to a coroutine's fiber would give us a different FLS value
 *  than the main fiber had, which is the opposite of what we want.
 */

#include "runtime/coro.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "lauxlib.h"
#include "lualib.h"
#include "ffi/veh.h"   /* g_CurrentJitFrame: the per-fiber JIT recovery frame */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CORO_METATABLE       "clua-interp.coro"

#define STATUS_SUSPENDED     0
#define STATUS_RUNNING       1
#define STATUS_NORMAL        2
#define STATUS_DEAD          3

#define DEFAULT_FIBER_STACK  ( 1u * 1024u * 1024u )

typedef struct {
    HANDLE      Fiber;
    lua_State  *L;
    DWORD       OwnerThread;
    HANDLE      CallerFiber;
    int         Status;
    int         Started;
    int         LuaRefSelf;
    int         HasError;
    PJIT_FRAME_T JitFrame;   /* this fiber's outermost JIT recovery frame */
} CORO_T, *PCORO_T;

/* MinGW gcc prefers `__thread`; MSVC prefers `__declspec(thread)`. Use the
   compiler-appropriate keyword so the variable is genuinely thread-local.
   LUAC_AOT_RUNTIME: a plain static instead — the AOT runtime is single-OS-
   thread by construction (fibers all run on the main thread; the FFI is
   never opened, so no foreign threads can enter Lua), and gcc's emulated
   TLS would otherwise drag libgcc emutls + ~23 KB of winpthread into every
   compiled exe. */
#if defined( LUAC_AOT_RUNTIME )
static                           PCORO_T g_CurrentCoroTls = NULL;
#elif defined( __GNUC__ )
static __thread                  PCORO_T g_CurrentCoroTls = NULL;
#else
static __declspec( thread )      PCORO_T g_CurrentCoroTls = NULL;
#endif

static const char *StatusName( int S ) {
    switch ( S ) {
        case STATUS_SUSPENDED: return "suspended";
        case STATUS_RUNNING:   return "running";
        case STATUS_NORMAL:    return "normal";
        case STATUS_DEAD:      return "dead";
        default:               return "?";
    }
}

static PCORO_T CurrentCoro( void ) {
    return g_CurrentCoroTls;
}

static void SetCurrentCoro( PCORO_T Co ) {
    g_CurrentCoroTls = Co;
}

void Coro_InitProcess( void ) {
    /* TLS storage allocated by the linker; no per-process init needed. */
}

void Coro_InitThreadAsFiber( void ) {
    if ( !IsThreadAFiber( ) ) {
        ConvertThreadToFiber( NULL );
    }
}

/*!
 * @brief
 *  Fiber entry. Co->L was preloaded by the first resume with
 *    [fn, arg1, arg2, ..., argN]
 *  We call fn(args). When fn returns or errors, mark Co dead and switch
 *  back to the caller permanently.
 */
static VOID WINAPI Coro_FiberEntry( LPVOID Param ) {
    PCORO_T Co  = ( PCORO_T )Param;
    int     NA  = lua_gettop( Co->L ) - 1;
    int     Rc  = lua_pcall( Co->L, NA, LUA_MULTRET, 0 );
    Co->Status   = STATUS_DEAD;
    Co->HasError = ( Rc != LUA_OK );
    SwitchToFiber( Co->CallerFiber );
    /* Unreachable. */
}

static PCORO_T CheckCoro( lua_State *L, int Idx ) {
    return ( PCORO_T )luaL_checkudata( L, Idx, CORO_METATABLE );
}

/* coroutine.create(fn [, opts]) -> coroutine
   opts.stack = N (bytes) overrides default 1 MiB fiber stack. */
static int LuaFn_Create( lua_State *L ) {
    luaL_checktype( L, 1, LUA_TFUNCTION );

    size_t StackBytes = DEFAULT_FIBER_STACK;
    if ( lua_istable( L, 2 ) ) {
        lua_getfield( L, 2, "stack" );
        if ( lua_isinteger( L, -1 ) ) {
            lua_Integer N = lua_tointeger( L, -1 );
            if ( N > 0 ) StackBytes = ( size_t )N;
        }
        lua_pop( L, 1 );
    }

    Coro_InitProcess( );
    Coro_InitThreadAsFiber( );

    PCORO_T Co = ( PCORO_T )lua_newuserdatauv( L, sizeof( CORO_T ), 1 );
    memset( Co, 0, sizeof( *Co ) );
    Co->Status      = STATUS_SUSPENDED;
    Co->LuaRefSelf  = LUA_NOREF;
    Co->OwnerThread = GetCurrentThreadId( );

    luaL_getmetatable( L, CORO_METATABLE );
    lua_setmetatable( L, -2 );

    /* New Lua thread (shares global state). Stash it as the cdata's user
       value 1 so it can't be GC'd before us. */
    Co->L = lua_newthread( L );
    lua_setiuservalue( L, -2, 1 );

    /* Push fn from L onto Co->L for the fiber entry. */
    lua_pushvalue( L, 1 );
    lua_xmove( L, Co->L, 1 );

    /* Anchor ourselves in registry so we survive across resumes. */
    lua_pushvalue( L, -1 );
    Co->LuaRefSelf = luaL_ref( L, LUA_REGISTRYINDEX );

    Co->Fiber = CreateFiber( StackBytes, Coro_FiberEntry, Co );
    if ( Co->Fiber == NULL ) {
        luaL_unref( L, LUA_REGISTRYINDEX, Co->LuaRefSelf );
        Co->LuaRefSelf = LUA_NOREF;
        return luaL_error( L, "coroutine.create: CreateFiber failed (err=%lu)",
                           ( unsigned long )GetLastError( ) );
    }
    return 1;
}

/* coroutine.resume(co, ...) -> bool, results... */
static int LuaFn_Resume( lua_State *L ) {
    PCORO_T Co = CheckCoro( L, 1 );

    if ( Co->OwnerThread != GetCurrentThreadId( ) ) {
        lua_pushboolean( L, 0 );
        lua_pushstring( L, "cannot resume coroutine across OS threads" );
        return 2;
    }
    if ( Co->Status != STATUS_SUSPENDED ) {
        lua_pushboolean( L, 0 );
        lua_pushfstring( L, "cannot resume %s coroutine", StatusName( Co->Status ) );
        return 2;
    }

    int NArgs = lua_gettop( L ) - 1;
    lua_xmove( L, Co->L, NArgs );

    PCORO_T Prev = CurrentCoro( );
    if ( Prev != NULL ) Prev->Status = STATUS_NORMAL;
    SetCurrentCoro( Co );
    Co->CallerFiber = GetCurrentFiber( );
    Co->Status      = STATUS_RUNNING;
    Co->Started     = 1;

    /* g_CurrentJitFrame is the outermost JIT recovery frame for the CURRENTLY
       RUNNING fiber, and Jit_TrampolineEntry installs a frame only when it is
       NULL. Coroutines run on their own fiber stacks, so each fiber needs its
       OWN outermost frame: hand the coroutine its saved frame (NULL on first
       resume, so its first JIT call installs a fresh frame on the coroutine
       stack) and restore ours when it switches back. Without this, a hardware
       fault inside a coroutine's JIT code would longjmp into the resumer's
       recovery frame -- a jmp_buf captured on a different (suspended) fiber
       stack -- and corrupt both stacks. */
    PJIT_FRAME_T SavedJitFrame = g_CurrentJitFrame;
    g_CurrentJitFrame          = Co->JitFrame;

    SwitchToFiber( Co->Fiber );

    Co->JitFrame      = g_CurrentJitFrame;   /* save whatever the coroutine left */
    g_CurrentJitFrame = SavedJitFrame;       /* restore our own fiber's frame */

    SetCurrentCoro( Prev );
    if ( Prev != NULL ) Prev->Status = STATUS_RUNNING;

    int NRes = lua_gettop( Co->L );

    if ( Co->Status == STATUS_DEAD && Co->HasError ) {
        lua_pushboolean( L, 0 );
        lua_xmove( Co->L, L, 1 );
        lua_settop( Co->L, 0 );
        return 2;
    }

    lua_pushboolean( L, 1 );
    lua_xmove( Co->L, L, NRes );
    return 1 + NRes;
}

/* coroutine.yield(...) -> resume args */
static int LuaFn_Yield( lua_State *L ) {
    PCORO_T Co = CurrentCoro( );
    if ( Co == NULL || Co->L != L ) {
        return luaL_error( L, "attempt to yield from outside a coroutine" );
    }
    Co->Status = STATUS_SUSPENDED;
    SwitchToFiber( Co->CallerFiber );
    Co->Status = STATUS_RUNNING;
    return lua_gettop( L );
}

/* coroutine.status(co) -> string */
static int LuaFn_Status( lua_State *L ) {
    PCORO_T Co = CheckCoro( L, 1 );
    lua_pushstring( L, StatusName( Co->Status ) );
    return 1;
}

/* coroutine.running() -> coroutine|nil, isMain */
static int LuaFn_Running( lua_State *L ) {
    PCORO_T Co = CurrentCoro( );
    if ( Co == NULL ) {
        lua_pushnil( L );
        lua_pushboolean( L, 1 );
    } else {
        lua_rawgeti( L, LUA_REGISTRYINDEX, Co->LuaRefSelf );
        lua_pushboolean( L, 0 );
    }
    return 2;
}

/* coroutine.isyieldable([co]) -> bool */
static int LuaFn_IsYieldable( lua_State *L ) {
    if ( lua_gettop( L ) >= 1 ) {
        PCORO_T Co = CheckCoro( L, 1 );
        lua_pushboolean( L, Co->Status == STATUS_RUNNING ||
                            Co->Status == STATUS_NORMAL );
    } else {
        lua_pushboolean( L, CurrentCoro( ) != NULL );
    }
    return 1;
}

/* coroutine.close(co) -> true | nil, msg */
static int LuaFn_Close( lua_State *L ) {
    PCORO_T Co = CheckCoro( L, 1 );
    if ( Co->Status == STATUS_RUNNING || Co->Status == STATUS_NORMAL ) {
        lua_pushnil( L );
        lua_pushstring( L, "cannot close a running coroutine" );
        return 2;
    }
    if ( Co->Fiber != NULL ) {
        DeleteFiber( Co->Fiber );
        Co->Fiber = NULL;
    }
    Co->Status = STATUS_DEAD;
    lua_pushboolean( L, 1 );
    return 1;
}

/* coroutine.wrap(fn) -> function */
static int LuaFn_WrapCall( lua_State *L );

static int LuaFn_Wrap( lua_State *L ) {
    luaL_checktype( L, 1, LUA_TFUNCTION );
    LuaFn_Create( L );  /* leaves coroutine cdata on top */
    lua_pushcclosure( L, LuaFn_WrapCall, 1 );
    return 1;
}

static int LuaFn_WrapCall( lua_State *L ) {
    /* Push the coroutine cdata (upvalue 1) and move it to slot 1 so the stack
       is [co, arg1..argN] -- what LuaFn_Resume expects. */
    lua_pushvalue( L, lua_upvalueindex( 1 ) );
    lua_insert( L, 1 );
    /* LuaFn_Resume CONSUMES the args (via lua_xmove into the coroutine) and
       then pushes (bool, results...). So on return the stack is exactly
       [co(1), bool(2), results(3..)] regardless of the original arg count --
       co stays at slot 1 (xmove pops from the top, not the bottom). */
    LuaFn_Resume( L );
    if ( !lua_toboolean( L, 2 ) ) {
        /* error path: [co, false, errmsg] -> raise errmsg (top of stack) */
        lua_remove( L, 2 );                 /* drop the false */
        return lua_error( L );              /* uses top of stack as msg */
    }
    /* strip co (slot 1) and bool (now slot 1 after the first remove), leaving
       only the results. */
    int Results = lua_gettop( L ) - 2;
    lua_remove( L, 1 );                     /* co */
    lua_remove( L, 1 );                     /* bool */
    return Results;
}

/* __gc */
static int Coro_Gc( lua_State *L ) {
    PCORO_T Co = ( PCORO_T )lua_touserdata( L, 1 );
    if ( Co == NULL ) return 0;
    if ( Co->Fiber != NULL ) {
        DeleteFiber( Co->Fiber );
        Co->Fiber = NULL;
    }
    if ( Co->LuaRefSelf != LUA_NOREF ) {
        luaL_unref( L, LUA_REGISTRYINDEX, Co->LuaRefSelf );
        Co->LuaRefSelf = LUA_NOREF;
    }
    return 0;
}

static const luaL_Reg g_CoroFuncs[ ] = {
    { "create",      LuaFn_Create      },
    { "resume",      LuaFn_Resume      },
    { "yield",       LuaFn_Yield       },
    { "status",      LuaFn_Status      },
    { "running",     LuaFn_Running     },
    { "wrap",        LuaFn_Wrap        },
    { "isyieldable", LuaFn_IsYieldable },
    { "close",       LuaFn_Close       },
    { NULL,          NULL              }
};

void Coro_OpenLib( lua_State *L ) {
    Coro_InitProcess( );

    if ( luaL_newmetatable( L, CORO_METATABLE ) ) {
        lua_pushcfunction( L, Coro_Gc );
        lua_setfield( L, -2, "__gc" );
    }
    lua_pop( L, 1 );

    luaL_newlib( L, g_CoroFuncs );
    lua_setglobal( L, "coroutine" );
}
