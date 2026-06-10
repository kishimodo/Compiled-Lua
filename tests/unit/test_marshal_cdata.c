/* test_marshal_cdata.c -- marshalling cdata args/returns.
 * Exercises the cdata paths in Marshal_LuaToC. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/marshal.h"

#include "lua.h"
#include "lauxlib.h"

#include <stdint.h>
#include <string.h>

int main( void ) {
    TEST_BEGIN( "marshal_cdata" );

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    Ctype_Init( );
    Cdata_RegisterMetatable( L );

    PCType_T IntT   = Ctype_Lookup( "int" );
    PCType_T ShortT = Ctype_Lookup( "short" );
    CHECK_NOT_NULL( IntT );
    CHECK_NOT_NULL( ShortT );

    /* void* */
    PCType_T VoidPtr = Ctype_New( );
    VoidPtr->Kind     = CT_PTR;
    VoidPtr->Size     = 8;
    VoidPtr->Align    = 8;
    VoidPtr->ElemType = Ctype_Lookup( "void" );

    /* --- cdata int -> C int (matching kind + size) --- */
    {
        PCData_T Cd = FfiNewCData( L, IntT );
        CHECK_NOT_NULL( Cd );
        Cd->I64 = 0x12345678LL;
        int32_t Out = 0;
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, IntT, &Out ), 4 );
        CHECK_EQ_INT( Out, 0x12345678 );
        lua_pop( L, 1 );
    }

    /* --- cdata int -> C short (same kind, width truncation) --- */
    {
        PCData_T Cd = FfiNewCData( L, IntT );
        CHECK_NOT_NULL( Cd );
        Cd->I64 = 0xABCD;
        int16_t Out2 = 0;
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, ShortT, &Out2 ), 2 );
        CHECK_EQ_INT( (unsigned short)Out2, 0xABCD );
        lua_pop( L, 1 );
    }

    /* --- cdata void* -> C void* (pointer to pointer) --- */
    {
        PCData_T Cd = FfiNewCData( L, VoidPtr );
        CHECK_NOT_NULL( Cd );
        Cd->Ptr = (void *)(uintptr_t)0xCAFEBABE;
        void *PtrOut = NULL;
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, VoidPtr, &PtrOut ), 8 );
        CHECK( PtrOut == (void *)(uintptr_t)0xCAFEBABE );
        lua_pop( L, 1 );
    }

    /* --- cdata typed pointer -> void* (any pointer accepted as void*) --- */
    {
        PCType_T IntPtr = Ctype_New( );
        IntPtr->Kind     = CT_PTR;
        IntPtr->Size     = 8;
        IntPtr->Align    = 8;
        IntPtr->ElemType = IntT;
        PCData_T Cd = FfiNewCData( L, IntPtr );
        CHECK_NOT_NULL( Cd );
        Cd->Ptr = (void *)(uintptr_t)0xDEADBEEF;
        void *PtrOut = NULL;
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, VoidPtr, &PtrOut ), 8 );
        CHECK( PtrOut == (void *)(uintptr_t)0xDEADBEEF );
        lua_pop( L, 1 );
    }

    /* --- cdata struct -> matching struct (inline payload copy) --- */
    {
        PCType_T SCt = Ctype_New( );
        SCt->Kind  = CT_STRUCT;
        SCt->Size  = 16;
        SCt->Align = 8;
        PCData_T Cd = FfiNewCData( L, SCt );
        CHECK_NOT_NULL( Cd );
        Cd->Inline[  0 ] = 0xAA;
        Cd->Inline[ 15 ] = 0xBB;
        uint8_t Buf[ 16 ] = { 0 };
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, SCt, Buf ), 16 );
        CHECK_EQ_INT( Buf[  0 ], 0xAA );
        CHECK_EQ_INT( Buf[ 15 ], 0xBB );
        lua_pop( L, 1 );
    }

    /* --- cdata of mismatched kind (int -> ptr) -> 0 and error pushed --- */
    {
        PCData_T Cd = FfiNewCData( L, IntT );
        CHECK_NOT_NULL( Cd );
        void *PtrGarbage = NULL;
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, VoidPtr, &PtrGarbage ), 0 );
        lua_pop( L, 1 );   /* cdata */
        lua_pop( L, 1 );   /* error message from marshal */
    }

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
