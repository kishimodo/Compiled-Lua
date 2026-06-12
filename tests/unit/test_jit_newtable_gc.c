/* test_jit_newtable_gc.c -- OP_NEWTABLE / OP_SETLIST / OP_CLOSURE under
 * aggressive GC pressure.
 *
 * Pre-fix: Rt_NewTable and Rt_NewClosure called luaC_checkGC before setting
 * L->top.p past the freshly-written slot, so the new object could be swept
 * before it was rooted.  Fix: L->top.p is bumped first.
 *
 * We force the situation by setting an aggressive GC pause/stepmul and
 * pre-loading garbage so checkGC triggers a sweep.
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

/* OP_NEWTABLE + SETFIELD hot path under GC */
static const char *kNewTableGc =
    "collectgarbage('collect')\n"
    "collectgarbage('setpause', 50)\n"
    "collectgarbage('setstepmul', 100000)\n"
    "local trash = {}\n"
    "for i = 1, 5000 do trash[i] = { i = i } end\n"
    "trash = nil\n"
    "local function MakeW(n) return function() return n end end\n"
    "local W1, W2, W3 = MakeW(1), MakeW(2), MakeW(3)\n"
    "local tasks = {}\n"
    "local function Push(fn)\n"
    "    local co = coroutine.create(fn)\n"
    "    tasks[#tasks + 1] = { co = co, wakeup = 0 }\n"
    "end\n"
    "Push(W1); Push(W2); Push(W3)\n"
    "assert(#tasks == 3)\n"
    "for i, t in ipairs(tasks) do\n"
    "    assert(type(t) == 'table')\n"
    "    assert(t.wakeup == 0)\n"
    "    assert(t.co ~= nil)\n"
    "end\n"
    "return #tasks\n";

/* OP_SETLIST (numeric constructor) under GC */
static const char *kSetListGc =
    "collectgarbage('collect')\n"
    "collectgarbage('setpause', 50)\n"
    "collectgarbage('setstepmul', 100000)\n"
    "local trash = {}\n"
    "for i = 1, 5000 do trash[i] = { i = i } end\n"
    "trash = nil\n"
    "local function Make()\n"
    "    return { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 }\n"
    "end\n"
    "local results = {}\n"
    "for i = 1, 20 do results[i] = Make() end\n"
    "for i, t in ipairs(results) do\n"
    "    assert(type(t) == 'table')\n"
    "    assert(#t == 10)\n"
    "    assert(t[5] == 50)\n"
    "    assert(t[10] == 100)\n"
    "end\n"
    "return #results\n";

/* OP_CLOSURE under GC */
static const char *kNewClosureGc =
    "collectgarbage('collect')\n"
    "collectgarbage('setpause', 50)\n"
    "collectgarbage('setstepmul', 100000)\n"
    "local trash = {}\n"
    "for i = 1, 5000 do trash[i] = { i = i } end\n"
    "trash = nil\n"
    "local function Body(n) return function() return n * 2 end end\n"
    "local closures = {}\n"
    "for i = 1, 50 do closures[i] = Body(i) end\n"
    "for i, c in ipairs(closures) do\n"
    "    assert(type(c) == 'function')\n"
    "    assert(c() == i * 2)\n"
    "end\n"
    "return #closures\n";

int main( void ) {
    TEST_BEGIN("jit_newtable_gc");

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    clua_dispatch_hook = JitHook;
    Ffi_SetDispatchL( L );
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib( L );

    /* Rt_NewTable under GC pressure */
    CHECK( RunLua( L, kNewTableGc ) );
    CHECK_EQ_INT( (int)lua_tointeger( L, -1 ), 3 );
    lua_settop( L, 0 );

    /* Rt_SetList under GC pressure */
    CHECK( RunLua( L, kSetListGc ) );
    CHECK_EQ_INT( (int)lua_tointeger( L, -1 ), 20 );
    lua_settop( L, 0 );

    /* Rt_NewClosure under GC pressure */
    CHECK( RunLua( L, kNewClosureGc ) );
    CHECK_EQ_INT( (int)lua_tointeger( L, -1 ), 50 );
    lua_settop( L, 0 );

    Ctype_Shutdown();
    lua_close( L );
    TEST_END();
}
