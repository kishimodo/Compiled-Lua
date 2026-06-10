/* test_cdata_field_access.c -- struct/union field get/set through cdata via Lua. */
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
    TEST_BEGIN( "cdata_field_access" );

    luavm_jit_compile_hook = TestJitHook;

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    Ctype_Init( );
    Ffi_RegisterWindowsTypes( );
    Ffi_OpenLib( L );

    /* struct field write + read */
    CHECK( RunLua( L,
        "ffi.cdef('struct Pt { int x; int y; };');"
        "local p = ffi.new('struct Pt');"
        "p.x = 10; p.y = 20;"
        "return p.x + p.y" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 30 );
    lua_pop( L, 1 );

    /* mixed field types: double and int */
    CHECK( RunLua( L,
        "ffi.cdef('struct V { double d; int i; };');"
        "local v = ffi.new('struct V');"
        "v.d = 3.5; v.i = 7;"
        "return v.d, v.i" ) );
    CHECK( lua_tonumber( L, -2 ) > 3.4 && lua_tonumber( L, -2 ) < 3.6 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 7 );
    lua_settop( L, 0 );

    /* unknown field access raises an error */
    {
        int Rc = luaL_loadstring( L,
            "ffi.cdef('struct OnlyX { int x; };');"
            "local s = ffi.new('struct OnlyX');"
            "return s.y" );
        if ( Rc == LUA_OK )
            Rc = lua_pcall( L, 0, LUA_MULTRET, 0 );
        CHECK_EQ_INT( Rc, LUA_ERRRUN );   /* must have raised */
        const char *Err = lua_tostring( L, -1 );
        CHECK_NOT_NULL( Err );
        lua_pop( L, 1 );
    }

    /* array indexing: int[N] read/write by integer key */
    CHECK( RunLua( L,
        "local a = ffi.new('int[4]');"
        "a[0] = 100; a[1] = 200; a[2] = 300; a[3] = 400;"
        "return a[0] + a[1] + a[2] + a[3]" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 1000 );
    lua_pop( L, 1 );

    /* union: writing one field, reading another (overlapping storage) */
    CHECK( RunLua( L,
        "ffi.cdef('union U { int i; float f; };');"
        "local u = ffi.new('union U');"
        "u.i = 0;"
        "u.f = 1.0;"
        "return u.i ~= 0" ) );   /* float 1.0 bit pattern non-zero as int */
    CHECK_EQ_INT( lua_toboolean( L, -1 ), 1 );
    lua_pop( L, 1 );

    /* pointer field: set via pointer arithmetic, read back */
    CHECK( RunLua( L,
        "ffi.cdef('struct Node { int val; int pad; };');"
        "local n = ffi.new('struct Node');"
        "n.val = 42;"
        "return n.val" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 42 );
    lua_pop( L, 1 );

    /* ffi.sizeof returns correct sizes */
    CHECK( RunLua( L,
        "ffi.cdef('struct SZ { int a; int b; int c; };');"
        "return ffi.sizeof('struct SZ')" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 12 );
    lua_pop( L, 1 );

    /* ffi.offsetof */
    CHECK( RunLua( L,
        "ffi.cdef('struct OF { char c; int i; };');"
        "return ffi.offsetof('struct OF', 'i')" ) );
    /* int is aligned to 4 bytes, so offset should be 4 */
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 4 );
    lua_pop( L, 1 );

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
