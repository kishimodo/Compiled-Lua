/* test_cdata_metamethods.c -- cdata arithmetic incl array->pointer decay
 * `arr+n`, comparison __eq, __index/__newindex on struct fields via Lua. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/ffi_lib.h"
#include "ffi/win_types.h"
#include "jit/dispatch.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lvm.h"

#include <string.h>

static void *TestJitHook( lua_State *L, void *Proto ) {
    return (void *)Jit_Compile( L, (struct Proto *)Proto );
}

static int RunLua( lua_State *L, const char *Src ) {
    if ( luaL_loadstring( L, Src ) != LUA_OK ) {
        fprintf( stderr, "[-] load: %s\n", lua_tostring( L, -1 ) );
        lua_pop( L, 1 );
        return 0;
    }
    if ( lua_pcall( L, 0, LUA_MULTRET, 0 ) != LUA_OK ) {
        fprintf( stderr, "[-] run: %s\n", lua_tostring( L, -1 ) );
        lua_pop( L, 1 );
        return 0;
    }
    return 1;
}

int main( void ) {
    TEST_BEGIN( "cdata_metamethods" );

    clua_dispatch_hook = TestJitHook;

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    Ctype_Init( );
    Ffi_RegisterWindowsTypes( );
    Ffi_OpenLib( L );

    /* __tostring on a pointer cdata contains "cdata" and the hex value */
    CHECK( RunLua( L, "return tostring(ffi.cast('void*', 0xDEADBEEF))" ) );
    {
        const char *S = lua_tostring( L, -1 );
        CHECK_NOT_NULL( S );
        CHECK( strstr( S, "cdata" ) != NULL );
        CHECK( strstr( S, "DEADBEEF" ) != NULL || strstr( S, "deadbeef" ) != NULL );
    }
    lua_pop( L, 1 );

    /* __tostring on an integer cdata */
    CHECK( RunLua( L, "return tostring(ffi.new('long long'))" ) );
    {
        const char *S = lua_tostring( L, -1 );
        CHECK_NOT_NULL( S );
        CHECK( strstr( S, "cdata" ) != NULL );
    }
    lua_pop( L, 1 );

    /* __eq: same-valued pointers compare equal */
    CHECK( RunLua( L,
        "local a = ffi.cast('void*', 0x1000);"
        "local b = ffi.cast('void*', 0x1000);"
        "return a == b" ) );
    CHECK_EQ_INT( lua_toboolean( L, -1 ), 1 );
    lua_pop( L, 1 );

    /* __eq: different-valued pointers compare unequal */
    CHECK( RunLua( L,
        "local a = ffi.cast('void*', 0x1000);"
        "local b = ffi.cast('void*', 0x2000);"
        "return a == b" ) );
    CHECK_EQ_INT( lua_toboolean( L, -1 ), 0 );
    lua_pop( L, 1 );

    /* __eq: integer cdata same value equals */
    CHECK( RunLua( L,
        "local a = ffi.new('int', 42);"
        "local b = ffi.new('int', 42);"
        "return a == b" ) );
    CHECK_EQ_INT( lua_toboolean( L, -1 ), 1 );
    lua_pop( L, 1 );

    /* __eq: integer cdata different value */
    CHECK( RunLua( L,
        "local a = ffi.new('int', 1);"
        "local b = ffi.new('int', 2);"
        "return a == b" ) );
    CHECK_EQ_INT( lua_toboolean( L, -1 ), 0 );
    lua_pop( L, 1 );

    /* __add: pointer arithmetic (arr+n) — array->pointer decay */
    CHECK( RunLua( L,
        "local a = ffi.new('int[4]');"
        "a[0] = 10; a[1] = 20; a[2] = 30; a[3] = 40;"
        "local p = a + 2;"           /* decay int[4] -> int*, advance by 2 */
        "return p[0]" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 30 );
    lua_pop( L, 1 );

    /* __add: n + ptr (commutative) */
    CHECK( RunLua( L,
        "local a = ffi.new('int[4]');"
        "a[0] = 5; a[1] = 6; a[2] = 7; a[3] = 8;"
        "local p = 1 + a;"
        "return p[0]" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 6 );
    lua_pop( L, 1 );

    /* __sub: ptr - integer offset */
    CHECK( RunLua( L,
        "local a = ffi.new('int[4]');"
        "a[0] = 100; a[1] = 200; a[2] = 300; a[3] = 400;"
        "local p = a + 3;"
        "local q = p - 1;"
        "return q[0]" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 300 );
    lua_pop( L, 1 );

    /* __index: struct field read */
    CHECK( RunLua( L,
        "ffi.cdef('struct MM { int x; int y; };');"
        "local s = ffi.new('struct MM');"
        "s.x = 7; s.y = 13;"
        "return s.x + s.y" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 20 );
    lua_pop( L, 1 );

    /* __newindex: struct field write */
    CHECK( RunLua( L,
        "ffi.cdef('struct MM2 { double d; int i; };');"
        "local v = ffi.new('struct MM2');"
        "v.d = 1.5; v.i = 99;"
        "return v.d, v.i" ) );
    CHECK( lua_tonumber( L, -2 ) > 1.4 && lua_tonumber( L, -2 ) < 1.6 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 99 );
    lua_settop( L, 0 );

    /* __index on array: integer indexing */
    CHECK( RunLua( L,
        "local a = ffi.new('int[3]');"
        "a[0] = 111; a[1] = 222; a[2] = 333;"
        "return a[0], a[1], a[2]" ) );
    CHECK_EQ_INT( lua_tointeger( L, -3 ), 111 );
    CHECK_EQ_INT( lua_tointeger( L, -2 ), 222 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 333 );
    lua_settop( L, 0 );

    /* __add: whole-number float offset (arr + 1.0) */
    CHECK( RunLua( L,
        "local a = ffi.new('int[4]');"
        "a[0] = 10; a[1] = 20;"
        "local p = a + 1.0;"
        "return p[0]" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 20 );
    lua_pop( L, 1 );

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
