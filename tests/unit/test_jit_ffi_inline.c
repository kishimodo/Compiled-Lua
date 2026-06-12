/* test_jit_ffi_inline.c -- inlined FFI call from JIT'd code.
 *
 * Exercises the FFI inline-call fast path:
 *  1. Zero-arg call: GetCurrentProcessId() -> PID > 0.
 *  2. Three-arg integer call: MulDiv(100, 200, 4) = 5000.
 *  3. String-arg call: lstrlenA("hello") = 5 (falls back to Rt_Call).
 */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/ffi_lib.h"
#include "ffi/ffi_load.h"
#include "ffi/win_types.h"
#include "jit/dispatch.h"
#include "lvm.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

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
    TEST_BEGIN("jit_ffi_inline");

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    clua_dispatch_hook = JitHook;
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib( L );

    /* 1. GetCurrentProcessId() -- zero-arg inline */
    CHECK( RunLua( L,
        "ffi.cdef('DWORD GetCurrentProcessId(void);');"
        "return ffi.C.GetCurrentProcessId()" ) );
    {
        lua_Integer Pid = lua_tointeger( L, -1 );
        CHECK_MSG( Pid > 0, "GetCurrentProcessId() > 0" );
    }
    lua_pop( L, 1 );

    /* 2. MulDiv(100, 200, 4) = 5000 -- three integer args */
    CHECK( RunLua( L,
        "ffi.cdef('int MulDiv(int a, int b, int c);');"
        "return ffi.C.MulDiv(100, 200, 4)" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 5000 );
    lua_pop( L, 1 );

    /* 3. lstrlenA("hello") = 5 -- string arg (Rt_Call fallback) */
    CHECK( RunLua( L,
        "ffi.cdef('int lstrlenA(const char *s);');"
        "return ffi.C.lstrlenA('hello')" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 5 );
    lua_pop( L, 1 );

    Ctype_Shutdown();
    lua_close( L );
    TEST_END();
}
