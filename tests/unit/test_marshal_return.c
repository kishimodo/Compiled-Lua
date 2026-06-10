/* test_marshal_return.c -- return-value marshalling: Marshal_CToLua for each
 * C return kind (void, int, short, uint, i64, u64, float, ptr, struct). */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/marshal.h"

#include "lua.h"
#include "lauxlib.h"

#include <stdint.h>
#include <string.h>

int main( void ) {
    TEST_BEGIN( "marshal_return" );

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    Ctype_Init( );
    Cdata_RegisterMetatable( L );

    PCType_T VoidT  = Ctype_Lookup( "void" );
    PCType_T IntT   = Ctype_Lookup( "int" );
    PCType_T ShortT = Ctype_Lookup( "short" );
    PCType_T UIntT  = Ctype_Lookup( "unsigned int" );
    PCType_T I64T   = Ctype_Lookup( "long long" );
    PCType_T U64T   = Ctype_Lookup( "unsigned long long" );
    PCType_T FloatT = Ctype_Lookup( "float" );
    PCType_T DblT   = Ctype_Lookup( "double" );
    CHECK_NOT_NULL( VoidT );
    CHECK_NOT_NULL( IntT );
    CHECK_NOT_NULL( ShortT );
    CHECK_NOT_NULL( UIntT );
    CHECK_NOT_NULL( I64T );
    CHECK_NOT_NULL( U64T );
    CHECK_NOT_NULL( FloatT );
    CHECK_NOT_NULL( DblT );

    PCType_T VoidPtr = Ctype_New( );
    VoidPtr->Kind     = CT_PTR;
    VoidPtr->Size     = 8;
    VoidPtr->Align    = 8;
    VoidPtr->ElemType = VoidT;

    /* --- void -> 0 pushes --- */
    {
        int Top = lua_gettop( L );
        CHECK_EQ_INT( Marshal_CToLua( L, VoidT, NULL ), 0 );
        CHECK_EQ_INT( lua_gettop( L ), Top );
    }

    /* --- int -> lua_Integer --- */
    {
        int32_t I = 42;
        CHECK_EQ_INT( Marshal_CToLua( L, IntT, &I ), 1 );
        CHECK( lua_isinteger( L, -1 ) );
        CHECK_EQ_INT( lua_tointeger( L, -1 ), 42 );
        lua_pop( L, 1 );
    }

    /* --- short -> lua_Integer --- */
    {
        int16_t S = -1234;
        CHECK_EQ_INT( Marshal_CToLua( L, ShortT, &S ), 1 );
        CHECK_EQ_INT( lua_tointeger( L, -1 ), -1234 );
        lua_pop( L, 1 );
    }

    /* --- unsigned int (zero-extended) -> lua_Integer --- */
    {
        uint32_t U = 0xFFFFFFFFU;
        CHECK_EQ_INT( Marshal_CToLua( L, UIntT, &U ), 1 );
        CHECK_EQ_INT( lua_tointeger( L, -1 ), (lua_Integer)0xFFFFFFFFLL );
        lua_pop( L, 1 );
    }

    /* --- signed int64 -> lua_Integer (exact) --- */
    {
        int64_t I64 = (int64_t)0x123456789ABCDEF0LL;
        CHECK_EQ_INT( Marshal_CToLua( L, I64T, &I64 ), 1 );
        CHECK( lua_isinteger( L, -1 ) );
        CHECK_EQ_INT( lua_tointeger( L, -1 ), (lua_Integer)0x123456789ABCDEF0LL );
        lua_pop( L, 1 );
    }

    /* --- unsigned int64 (> INT64_MAX) -> cdata to preserve unsigned semantics --- */
    {
        uint64_t U64 = 0x8000000000000001ULL;
        CHECK_EQ_INT( Marshal_CToLua( L, U64T, &U64 ), 1 );
        PCData_T Cd = FfiGetCData( L, -1 );
        CHECK_NOT_NULL( Cd );
        CHECK( Cd->Type == U64T );
        CHECK_EQ_INT( (uint64_t)Cd->I64, (int64_t)0x8000000000000001ULL );
        lua_pop( L, 1 );
    }

    /* --- float -> lua_Number --- */
    {
        float F = 3.5f;
        CHECK_EQ_INT( Marshal_CToLua( L, FloatT, &F ), 1 );
        CHECK( lua_isnumber( L, -1 ) );
        CHECK( lua_tonumber( L, -1 ) > 3.4 && lua_tonumber( L, -1 ) < 3.6 );
        lua_pop( L, 1 );
    }

    /* --- double -> lua_Number --- */
    {
        double D = 2.71828;
        CHECK_EQ_INT( Marshal_CToLua( L, DblT, &D ), 1 );
        CHECK( lua_tonumber( L, -1 ) > 2.71 && lua_tonumber( L, -1 ) < 2.72 );
        lua_pop( L, 1 );
    }

    /* --- pointer -> cdata (pointer kind) --- */
    {
        void *Ptr = (void *)(uintptr_t)0xDEADBEEFC0FFEE00ULL;
        CHECK_EQ_INT( Marshal_CToLua( L, VoidPtr, &Ptr ), 1 );
        PCData_T Cd = FfiGetCData( L, -1 );
        CHECK_NOT_NULL( Cd );
        CHECK( Cd->Type == VoidPtr );
        CHECK( Cd->Ptr == (void *)(uintptr_t)0xDEADBEEFC0FFEE00ULL );
        lua_pop( L, 1 );
    }

    /* --- small struct -> cdata with inline payload --- */
    {
        PCType_T SCt = Ctype_New( );
        SCt->Kind  = CT_STRUCT;
        SCt->Size  = 8;
        SCt->Align = 8;
        uint8_t Src[ 8 ] = { 1, 2, 3, 4, 5, 6, 7, 8 };
        CHECK_EQ_INT( Marshal_CToLua( L, SCt, Src ), 1 );
        PCData_T Cd = FfiGetCData( L, -1 );
        CHECK_NOT_NULL( Cd );
        CHECK( Cd->Type == SCt );
        CHECK( memcmp( Cd->Inline, Src, 8 ) == 0 );
        lua_pop( L, 1 );
    }

    /* --- null pointer -> cdata with .Ptr == NULL --- */
    {
        void *Null = NULL;
        CHECK_EQ_INT( Marshal_CToLua( L, VoidPtr, &Null ), 1 );
        PCData_T Cd = FfiGetCData( L, -1 );
        CHECK_NOT_NULL( Cd );
        CHECK_NULL( Cd->Ptr );
        lua_pop( L, 1 );
    }

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
