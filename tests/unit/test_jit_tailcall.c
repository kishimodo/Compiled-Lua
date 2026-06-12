/* test_jit_tailcall.c -- tail-call returns correct value (audit-fix regression).
 *
 * The classic bug: a value-returning tail call (OP_TAILCALL) corrupts
 * the result -- typically the caller reads stale stack memory and sees
 * nil instead of the table/string/integer the callee returned.
 *
 * Root cause (fixed in Rt_TailCall): the helper was not propagating the
 * callee's results back to the *caller's* base registers before returning,
 * so the JIT epilogue read from the wrong stack window.
 *
 * We exercise:
 *  1. Deep tail recursion returning an integer -- the recursion terminates
 *     via a base case and the final integer propagates through every tail frame.
 *  2. Tail call returning a table -- the table must not be nil/GC'd.
 *  3. Tail call returning multiple values -- all values intact.
 *  4. Tail call returning a string -- string content preserved.
 *  5. Mutual tail call (a -> b -> a -> ...) returning a non-nil integer.
 */
#include "test_harness.h"
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

/* -----------------------------------------------------------------------
 * 1. Deep tail recursion returning an integer.
 *    f(0) = 99; f(n) = f(n-1) tail-calls until base.
 *    Without the fix, the returned integer is corrupted or nil.
 * -------------------------------------------------------------------- */
static const char *kDeepTailInt =
    "local function f(n)\n"
    "    if n == 0 then return 99 end\n"
    "    return f(n - 1)\n"
    "end\n"
    "return f(50)\n";

/* -----------------------------------------------------------------------
 * 2. Tail call returning a table.
 *    Without the fix, the result slot is nil (table was GC'd or pointer
 *    was read from the wrong register window).
 * -------------------------------------------------------------------- */
static const char *kTailCallTable =
    "local function make_table()\n"
    "    return { answer = 42, name = 'lua' }\n"
    "end\n"
    "local function get_it()\n"
    "    return make_table()\n"
    "end\n"
    "local t = get_it()\n"
    "return type(t), t.answer, t.name\n";

/* -----------------------------------------------------------------------
 * 3. Tail call returning multiple values.
 * -------------------------------------------------------------------- */
static const char *kTailCallMulti =
    "local function inner()\n"
    "    return 10, 20, 30\n"
    "end\n"
    "local function outer()\n"
    "    return inner()\n"
    "end\n"
    "return outer()\n";

/* -----------------------------------------------------------------------
 * 4. Tail call returning a string.
 * -------------------------------------------------------------------- */
static const char *kTailCallStr =
    "local function inner()\n"
    "    return 'hello_from_tail'\n"
    "end\n"
    "local function outer()\n"
    "    return inner()\n"
    "end\n"
    "return outer()\n";

/* -----------------------------------------------------------------------
 * 5. Mutual tail call: even(n) / odd(n) bouncing, returns 1 when n=0.
 *    Tests that multiple layers of tail calls all preserve the result.
 * -------------------------------------------------------------------- */
static const char *kMutualTail =
    "local even, odd\n"
    "even = function(n)\n"
    "    if n == 0 then return 1 end\n"
    "    return odd(n - 1)\n"
    "end\n"
    "odd = function(n)\n"
    "    if n == 0 then return 0 end\n"
    "    return even(n - 1)\n"
    "end\n"
    "return even(20)\n";

int main( void ) {
    TEST_BEGIN("jit_tailcall");

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    clua_dispatch_hook = JitHook;

    /* 1. Deep tail recursion -> integer */
    CHECK( RunLua( L, kDeepTailInt ) );
    CHECK_EQ_INT( lua_gettop( L ), 1 );
    CHECK_MSG( !lua_isnil( L, -1 ), "tail-call result is not nil" );
    CHECK_EQ_INT( (int)lua_tointeger( L, -1 ), 99 );
    lua_settop( L, 0 );

    /* 2. Tail call -> table */
    CHECK( RunLua( L, kTailCallTable ) );
    CHECK_EQ_INT( lua_gettop( L ), 3 );
    /* first return is type(t) */
    CHECK_MSG( lua_isstring( L, 1 ) &&
               strcmp( lua_tostring( L, 1 ), "table" ) == 0,
               "type(t) == 'table'" );
    /* second return is t.answer */
    CHECK_EQ_INT( (int)lua_tointeger( L, 2 ), 42 );
    /* third return is t.name */
    CHECK_MSG( lua_isstring( L, 3 ) &&
               strcmp( lua_tostring( L, 3 ), "lua" ) == 0,
               "t.name == 'lua'" );
    lua_settop( L, 0 );

    /* 3. Tail call -> multiple values */
    CHECK( RunLua( L, kTailCallMulti ) );
    CHECK_EQ_INT( lua_gettop( L ), 3 );
    CHECK_EQ_INT( (int)lua_tointeger( L, 1 ), 10 );
    CHECK_EQ_INT( (int)lua_tointeger( L, 2 ), 20 );
    CHECK_EQ_INT( (int)lua_tointeger( L, 3 ), 30 );
    lua_settop( L, 0 );

    /* 4. Tail call -> string */
    CHECK( RunLua( L, kTailCallStr ) );
    CHECK_EQ_INT( lua_gettop( L ), 1 );
    CHECK_MSG( lua_isstring( L, -1 ) &&
               strcmp( lua_tostring( L, -1 ), "hello_from_tail" ) == 0,
               "tail-call string result intact" );
    lua_settop( L, 0 );

    /* 5. Mutual tail calls -> 1 */
    CHECK( RunLua( L, kMutualTail ) );
    CHECK_EQ_INT( lua_gettop( L ), 1 );
    CHECK_EQ_INT( (int)lua_tointeger( L, -1 ), 1 );
    lua_settop( L, 0 );

    lua_close( L );
    TEST_END();
}
