/* test_jit_smoke.c -- compile + run a trivial Proto: arithmetic / return.
 *
 * Loads the inner function from a luaL_loadstring chunk, JIT-compiles it,
 * hooks luavm_jit_compile_hook so that lua_pcall drives it through the JIT,
 * and verifies the returned value.
 */
#include "test_harness.h"
#include "jit/dispatch.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lstate.h"
#include "lvm.h"

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

int main( void ) {
    TEST_BEGIN("jit_smoke");

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    luavm_jit_compile_hook = JitHook;

    /* -----------------------------------------------------------------
     * Test 1: simple integer arithmetic.
     * The inner function: local x=5; local y=3; return x+y  -> 8
     * ---------------------------------------------------------------- */
    CHECK( RunLua( L, "return (function() local x=5; local y=3; return x+y end)()" ) );
    CHECK_EQ_INT( lua_gettop( L ), 1 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 8 );
    lua_settop( L, 0 );

    /* -----------------------------------------------------------------
     * Test 2: return a constant integer directly.
     * ---------------------------------------------------------------- */
    CHECK( RunLua( L, "return (function() return 42 end)()" ) );
    CHECK_EQ_INT( lua_gettop( L ), 1 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 42 );
    lua_settop( L, 0 );

    /* -----------------------------------------------------------------
     * Test 3: multiple return values.
     * ---------------------------------------------------------------- */
    CHECK( RunLua( L, "return (function() return 10, 20, 30 end)()" ) );
    CHECK_EQ_INT( lua_gettop( L ), 3 );
    CHECK_EQ_INT( lua_tointeger( L, 1 ), 10 );
    CHECK_EQ_INT( lua_tointeger( L, 2 ), 20 );
    CHECK_EQ_INT( lua_tointeger( L, 3 ), 30 );
    lua_settop( L, 0 );

    /* -----------------------------------------------------------------
     * Test 4: subtraction.
     * ---------------------------------------------------------------- */
    CHECK( RunLua( L, "return (function() local a=100; local b=37; return a-b end)()" ) );
    CHECK_EQ_INT( lua_gettop( L ), 1 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 63 );
    lua_settop( L, 0 );

    /* -----------------------------------------------------------------
     * Test 5: Jit_Compile produces a non-NULL entry for a compilable chunk.
     * ---------------------------------------------------------------- */
    {
        int Rc = luaL_loadstring( L,
            "return (function() local x=5; local y=3; return x+y end)()" );
        CHECK_EQ_INT( Rc, LUA_OK );
        const LClosure *Outer = clLvalue( s2v( L->top.p - 1 ) );
        CHECK_MSG( Outer->p->sizep >= 1, "outer has at least one child proto" );
        Proto *Inner = Outer->p->p[0];
        JIT_FUNC_T Fn = Jit_Compile( L, Inner );
        CHECK_NOT_NULL( Fn );
        lua_settop( L, 0 );
    }

    lua_close( L );
    TEST_END();
}
