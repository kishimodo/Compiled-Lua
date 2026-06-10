/* test_cdata_borrowed.c -- borrowed cdata: CDATA_FLAG_BORROWED anchoring a
 * parent via uservalue. Tests nested struct write-through, array-of-structs,
 * three-level nesting, GC anchoring, pointer deref, and float-index gate. */
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
    TEST_BEGIN( "cdata_borrowed" );

    luavm_jit_compile_hook = TestJitHook;

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );
    Ctype_Init( );
    Ffi_RegisterWindowsTypes( );
    Ffi_OpenLib( L );

    /* 1. Nested struct field write-through: s.pt.x = 10 must persist. */
    CHECK( RunLua( L,
        "ffi.cdef('struct Pt { int x; int y; };')\n"
        "ffi.cdef('struct Box { struct Pt pt; int z; };')\n"
        "local s = ffi.new('struct Box')\n"
        "s.pt.x = 10\n"
        "s.pt.y = 20\n"
        "s.z = 30\n"
        "return s.pt.x, s.pt.y, s.z\n" ) );
    CHECK_EQ_INT( lua_tointeger( L, -3 ), 10 );
    CHECK_EQ_INT( lua_tointeger( L, -2 ), 20 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 30 );
    lua_settop( L, 0 );

    /* 2. Array of structs: arr[i].field = v writes through. */
    CHECK( RunLua( L,
        "ffi.cdef('struct P2 { int x; int y; };')\n"
        "local arr = ffi.new('struct P2[4]')\n"
        "for i = 0, 3 do arr[i].x = i * 10; arr[i].y = i * 100 end\n"
        "return arr[0].x, arr[2].x, arr[3].y\n" ) );
    CHECK_EQ_INT( lua_tointeger( L, -3 ),   0 );
    CHECK_EQ_INT( lua_tointeger( L, -2 ),  20 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 300 );
    lua_settop( L, 0 );

    /* 3. Three-level nesting: c.b.a.v = 42 reaches the storage. */
    CHECK( RunLua( L,
        "ffi.cdef('struct A1 { int v; };')\n"
        "ffi.cdef('struct B1 { struct A1 a; };')\n"
        "ffi.cdef('struct C1 { struct B1 b; };')\n"
        "local c = ffi.new('struct C1')\n"
        "c.b.a.v = 42\n"
        "return c.b.a.v\n" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 42 );
    lua_settop( L, 0 );

    /* 4. Parent lifetime: borrowed sub-cdata anchors parent across GC. */
    CHECK( RunLua( L,
        "ffi.cdef('struct Q { int x; int y; };')\n"
        "ffi.cdef('struct R { struct Q q; };')\n"
        "local function make()\n"
        "    local r = ffi.new('struct R')\n"
        "    r.q.x = 1234\n"
        "    r.q.y = 5678\n"
        "    return r.q\n"
        "end\n"
        "local q = make()\n"
        "collectgarbage('collect')\n"
        "collectgarbage('collect')\n"
        "return q.x, q.y\n" ) );
    CHECK_EQ_INT( lua_tointeger( L, -2 ), 1234 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 5678 );
    lua_settop( L, 0 );

    /* 5. Pointer auto-deref + nested borrowed write-through. */
    CHECK( RunLua( L,
        "ffi.cdef('struct S5 { int x; int y; };')\n"
        "ffi.cdef('struct T5 { struct S5 s; };')\n"
        "local t = ffi.new('struct T5')\n"
        "local pt = ffi.cast('struct T5*', t)\n"
        "pt.s.x = 99\n"
        "pt.s.y = -7\n"
        "return t.s.x, t.s.y\n" ) );
    CHECK_EQ_INT( lua_tointeger( L, -2 ),  99 );
    CHECK_EQ_INT( lua_tointeger( L, -1 ),  -7 );
    lua_settop( L, 0 );

    /* 6. Whole-number-float index accepted (e.g. a[1.0]). */
    CHECK( RunLua( L,
        "local a = ffi.new('int[4]')\n"
        "for i = 0, 3 do a[i] = 100 + i end\n"
        "return a[1.0] + a[2.0]\n" ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 101 + 102 );
    lua_settop( L, 0 );

    /* 7. Fractional index must be rejected. */
    {
        int Rc = luaL_loadstring( L,
            "local a = ffi.new('int[4]')\n"
            "return a[1.5]\n" );
        if ( Rc == LUA_OK )
            Rc = lua_pcall( L, 0, LUA_MULTRET, 0 );
        CHECK_EQ_INT( Rc, LUA_ERRRUN );
        const char *Err = lua_tostring( L, -1 );
        CHECK_NOT_NULL( Err );
        lua_settop( L, 0 );
    }

    /* 8. Direct C-level FfiNewBorrowedCData: flag and pointer set correctly. */
    {
        PCType_T IntT = Ctype_Lookup( "int" );
        CHECK_NOT_NULL( IntT );

        /* allocate a parent int cdata */
        PCData_T Parent = FfiNewCData( L, IntT );
        CHECK_NOT_NULL( Parent );
        int ParentIdx = lua_gettop( L );   /* index of parent on stack */
        Parent->I64 = 0x5A5A5A5A;

        /* borrow into the parent's storage */
        int32_t *ParentStorage = (int32_t *)Cdata_Storage( Parent );
        PCData_T Borrow = FfiNewBorrowedCData( L, IntT, ParentStorage, ParentIdx );
        CHECK_NOT_NULL( Borrow );
        CHECK( ( Borrow->Flags & CDATA_FLAG_BORROWED ) != 0 );
        CHECK( Borrow->Ptr == (void *)ParentStorage );
        /* borrowed storage reads same value as parent */
        CHECK_EQ_INT( *(int32_t *)Cdata_Storage( Borrow ), 0x5A5A5A5A );
        lua_settop( L, 0 );
    }

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
