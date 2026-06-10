/* test_marshal_primitives.c -- Marshal_LuaToC / Marshal_CToLua for
 * ints/floats/bool/pointers. Exercises src/ffi/marshal.c. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/marshal.h"

#include "lua.h"
#include "lauxlib.h"

#include <stdint.h>
#include <string.h>

int main( void ) {
    TEST_BEGIN( "marshal_primitives" );

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    Ctype_Init( );
    Cdata_RegisterMetatable( L );

    PCType_T IntT    = Ctype_Lookup( "int" );
    PCType_T ShortT  = Ctype_Lookup( "short" );
    PCType_T CharT   = Ctype_Lookup( "char" );
    PCType_T DoubleT = Ctype_Lookup( "double" );
    PCType_T FloatT  = Ctype_Lookup( "float" );
    PCType_T VoidT   = Ctype_Lookup( "void" );
    PCType_T UIntT   = Ctype_Lookup( "unsigned int" );
    CHECK_NOT_NULL( IntT );
    CHECK_NOT_NULL( ShortT );
    CHECK_NOT_NULL( CharT );
    CHECK_NOT_NULL( DoubleT );
    CHECK_NOT_NULL( FloatT );
    CHECK_NOT_NULL( VoidT );
    CHECK_NOT_NULL( UIntT );

    /* void* type */
    PCType_T VoidPtr = Ctype_New( );
    VoidPtr->Kind     = CT_PTR;
    VoidPtr->Size     = 8;
    VoidPtr->Align    = 8;
    VoidPtr->ElemType = VoidT;

    /* --- LuaToC: nil -> pointer = NULL --- */
    {
        void *Ptr = (void *)(uintptr_t)0xdeadbeef;
        lua_pushnil( L );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, VoidPtr, &Ptr ), 8 );
        CHECK_NULL( Ptr );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: boolean true/false -> int --- */
    {
        int B = -1;
        lua_pushboolean( L, 1 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, IntT, &B ), 4 );
        CHECK_EQ_INT( B, 1 );
        lua_pop( L, 1 );

        B = -1;
        lua_pushboolean( L, 0 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, IntT, &B ), 4 );
        CHECK_EQ_INT( B, 0 );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: integer -> int --- */
    {
        int32_t I32 = 0;
        lua_pushinteger( L, 42 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, IntT, &I32 ), 4 );
        CHECK_EQ_INT( I32, 42 );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: integer -> short --- */
    {
        int16_t I16 = 0;
        lua_pushinteger( L, 32767 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, ShortT, &I16 ), 2 );
        CHECK_EQ_INT( I16, 32767 );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: integer -> char (truncation) --- */
    {
        int8_t I8 = 0;
        lua_pushinteger( L, 0x1234 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, CharT, &I8 ), 1 );
        CHECK_EQ_INT( (uint8_t)I8, 0x34 );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: number -> double --- */
    {
        double D = 0.0;
        lua_pushnumber( L, 3.14159 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, DoubleT, &D ), 8 );
        CHECK( D > 3.14 && D < 3.15 );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: number -> float --- */
    {
        float F = 0.0f;
        lua_pushnumber( L, 2.5 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, FloatT, &F ), 4 );
        CHECK( F > 2.49f && F < 2.51f );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: number -> int (truncation toward zero) --- */
    {
        int32_t II = 0;
        lua_pushnumber( L, 7.9 );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, IntT, &II ), 4 );
        CHECK_EQ_INT( II, 7 );
        lua_pop( L, 1 );
    }

    /* --- LuaToC: type mismatch (string -> int) returns 0, pushes error --- */
    {
        int32_t Garbage = 99;
        lua_pushstring( L, "not a number" );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, IntT, &Garbage ), 0 );
        CHECK( lua_isstring( L, -1 ) );    /* error message on top */
        lua_pop( L, 2 );                   /* pop error + original string */
    }

    /* --- CToLua: void pushes nothing --- */
    {
        int Top = lua_gettop( L );
        CHECK_EQ_INT( Marshal_CToLua( L, VoidT, NULL ), 0 );
        CHECK_EQ_INT( lua_gettop( L ), Top );
    }

    /* --- CToLua: int -> lua integer --- */
    {
        int32_t Cv = 99;
        CHECK_EQ_INT( Marshal_CToLua( L, IntT, &Cv ), 1 );
        CHECK( lua_isinteger( L, -1 ) );
        CHECK_EQ_INT( lua_tointeger( L, -1 ), 99 );
        lua_pop( L, 1 );
    }

    /* --- CToLua: short -> lua integer --- */
    {
        int16_t Cs = -1234;
        CHECK_EQ_INT( Marshal_CToLua( L, ShortT, &Cs ), 1 );
        CHECK_EQ_INT( lua_tointeger( L, -1 ), -1234 );
        lua_pop( L, 1 );
    }

    /* --- CToLua: unsigned int (zero-extended) --- */
    {
        uint32_t Cu = 0xFFFFFFFFU;
        CHECK_EQ_INT( Marshal_CToLua( L, UIntT, &Cu ), 1 );
        CHECK_EQ_INT( lua_tointeger( L, -1 ), (lua_Integer)0xFFFFFFFFLL );
        lua_pop( L, 1 );
    }

    /* --- CToLua: float -> lua number --- */
    {
        float Cf = 3.5f;
        CHECK_EQ_INT( Marshal_CToLua( L, FloatT, &Cf ), 1 );
        CHECK( lua_isnumber( L, -1 ) );
        CHECK( lua_tonumber( L, -1 ) > 3.4 && lua_tonumber( L, -1 ) < 3.6 );
        lua_pop( L, 1 );
    }

    /* --- CToLua: double -> lua number --- */
    {
        double Cd = 2.71828;
        CHECK_EQ_INT( Marshal_CToLua( L, DoubleT, &Cd ), 1 );
        CHECK( lua_tonumber( L, -1 ) > 2.71 && lua_tonumber( L, -1 ) < 2.72 );
        lua_pop( L, 1 );
    }

    /* --- CToLua: pointer -> cdata --- */
    {
        void *CPtr = (void *)(uintptr_t)0xCAFEBABE;
        CHECK_EQ_INT( Marshal_CToLua( L, VoidPtr, &CPtr ), 1 );
        CHECK( FfiIsCData( L, -1 ) );
        PCData_T Cd = FfiGetCData( L, -1 );
        CHECK_NOT_NULL( Cd );
        CHECK( Cd->Ptr == (void *)(uintptr_t)0xCAFEBABE );
        lua_pop( L, 1 );
    }

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
