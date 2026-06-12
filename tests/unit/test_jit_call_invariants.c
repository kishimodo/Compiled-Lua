/* test_jit_call_invariants.c -- call frame / stack invariants across JIT calls.
 *
 * Regression tests for Rt_Call / Rt_Self invariants:
 *  1. Missing fixed arguments are nil-padded (not stale stack values).
 *  2. SELF dispatch through __index works (Bug 3: Rt_Self must follow
 *     __index chain, not just check Slot == NULL).
 *  3. CI chain length is stable across many same-depth calls
 *     (Rt_Call reuses spare CI nodes, Bug 4).
 */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/ffi_lib.h"
#include "ffi/ffi_load.h"
#include "ffi/ffi_callback.h"
#include "ffi/win_types.h"
#include "jit/dispatch.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lstate.h"
#include "lvm.h"

#include <string.h>

static void *JitHook( lua_State *L, void *Proto ) {
    return (void *)Jit_Compile( L, (struct Proto *)Proto );
}

static int RunLua( lua_State *L, const char *Src ) {
    if ( luaL_loadstring( L, Src ) != LUA_OK ) {
        printf( "[-] load: %s\n", lua_tostring( L, -1 ) );
        return 0;
    }
    if ( lua_pcall( L, 0, LUA_MULTRET, 0 ) != LUA_OK ) {
        printf( "[-] run: %s\n", lua_tostring( L, -1 ) );
        return 0;
    }
    return 1;
}

/* ---------- Bug 1: nil-pad missing fixed arguments -------------------- */
static const char *kNilPad =
    "local function poisoner() return 'POISON_A', 'POISON_B', 'POISON_C' end\n"
    "local _, _, _ = poisoner()\n"
    "local function target(a, b, c) return a, b, c end\n"
    "local a, b, c = target('x', 'y')\n"
    "return a, b, c\n";

/* ---------- Bug 3: SELF through __index ------------------------------- */
static const char *kSelfViaIndex =
    "local methods = { greet = function(self) return 'hello' end }\n"
    "local mt = { __index = methods }\n"
    "local obj = setmetatable({}, mt)\n"
    "return obj:greet()\n";

/* ---------- Bug 4: CI chain stable across many calls ------------------ */
static int CountCi( lua_State *L ) {
    int N = 0;
    CallInfo *Ci = L->ci;
    while ( Ci ) { N++; Ci = Ci->next; }
    lua_pushinteger( L, N );
    return 1;
}

static const char *kCiStable =
    "local function leaf() return 1 end\n"
    "local function recur(n)\n"
    "    if n == 0 then return leaf() end\n"
    "    return recur(n - 1) + 0\n"
    "end\n"
    "for i = 1, 5 do recur(20) end\n"
    "local before = _G.__count_ci()\n"
    "for i = 1, 1000 do recur(20) end\n"
    "local after = _G.__count_ci()\n"
    "return before, after\n";

int main( void ) {
    TEST_BEGIN("jit_call_invariants");

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    clua_dispatch_hook = JitHook;
    Ffi_SetDispatchL( L );
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib( L );

    /* ---- Bug 1 ---- */
    CHECK( RunLua( L, kNilPad ) );
    CHECK_EQ_INT( lua_gettop( L ), 3 );
    CHECK_MSG( lua_isstring( L, -3 ) && strcmp( lua_tostring( L, -3 ), "x" ) == 0,
               "a = 'x'" );
    CHECK_MSG( lua_isstring( L, -2 ) && strcmp( lua_tostring( L, -2 ), "y" ) == 0,
               "b = 'y'" );
    CHECK_MSG( lua_isnil( L, -1 ), "c = nil (not stale POISON_C)" );
    lua_settop( L, 0 );

    /* ---- Bug 3 ---- */
    CHECK( RunLua( L, kSelfViaIndex ) );
    CHECK_MSG( lua_isstring( L, -1 ), "SELF returned a string" );
    CHECK_MSG( strcmp( lua_tostring( L, -1 ), "hello" ) == 0,
               "method dispatched via __index -> 'hello'" );
    lua_settop( L, 0 );

    /* ---- Bug 4 ---- */
    lua_pushcfunction( L, CountCi );
    lua_setglobal( L, "__count_ci" );
    CHECK( RunLua( L, kCiStable ) );
    {
        lua_Integer Before = lua_tointeger( L, -2 );
        lua_Integer After  = lua_tointeger( L, -1 );
        printf( "[*] CI chain: before=%lld after=%lld\n",
                (long long)Before, (long long)After );
        CHECK_MSG( Before > 0, "warmup produced a CI chain" );
        CHECK_MSG( After <= Before + 32,
                   "CI chain stable across 1000 calls (pre-fix grew by ~20000)" );
    }
    lua_settop( L, 0 );

    Ctype_Shutdown();
    lua_close( L );
    TEST_END();
}
