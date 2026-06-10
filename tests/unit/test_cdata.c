/* test_cdata.c -- ffi.new / cdata allocation, sizeof, indexing arrays/pointers,
 * integer round-trip. Exercises src/ffi/cdata.c without the JIT layer. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <string.h>
#include <stdint.h>

int main( void ) {
    TEST_BEGIN( "cdata" );

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    luaL_openlibs( L );

    Ctype_Init( );
    Cdata_RegisterMetatable( L );

    /* --- scalar int cdata allocation --- */
    PCType_T IntT = Ctype_Lookup( "int" );
    CHECK_NOT_NULL( IntT );

    PCData_T Cd = FfiNewCData( L, IntT );
    CHECK_NOT_NULL( Cd );
    CHECK( Cd->Type == IntT );
    CHECK( ( Cd->Flags & CDATA_FLAG_OWNS_MEMORY ) != 0 );
    CHECK( ( Cd->Flags & CDATA_FLAG_IS_TYPEOF ) == 0 );
    CHECK_EQ_INT( Cd->I64, 0 );   /* zero-initialised */

    /* detection on the stack */
    CHECK( FfiIsCData( L, -1 ) );
    CHECK( FfiGetCData( L, -1 ) == Cd );

    /* non-cdata values must NOT be detected */
    lua_pushinteger( L, 99 );
    CHECK( !FfiIsCData( L, -1 ) );
    CHECK_NULL( FfiGetCData( L, -1 ) );
    lua_pop( L, 1 );

    lua_pushstring( L, "hello" );
    CHECK( !FfiIsCData( L, -1 ) );
    lua_pop( L, 1 );

    lua_pushnil( L );
    CHECK( !FfiIsCData( L, -1 ) );
    lua_pop( L, 1 );

    /* integer round-trip */
    Cd->I64 = 0x12345678LL;
    CHECK_EQ_INT( Cd->I64, 0x12345678LL );

    lua_pop( L, 1 );   /* pop int cdata */

    /* --- double cdata --- */
    PCType_T DoubleT = Ctype_Lookup( "double" );
    CHECK_NOT_NULL( DoubleT );
    PCData_T CdD = FfiNewCData( L, DoubleT );
    CHECK_NOT_NULL( CdD );
    CdD->F64 = 3.14;
    CHECK( CdD->F64 > 3.13 && CdD->F64 < 3.15 );
    lua_pop( L, 1 );

    /* --- pointer cdata --- */
    PCType_T IntPtr = Ctype_PointerTo( IntT );
    CHECK_NOT_NULL( IntPtr );
    CHECK_EQ_INT( IntPtr->Kind, CT_PTR );
    CHECK_EQ_INT( (int)IntPtr->Size, 8 );

    PCData_T CdP = FfiNewCData( L, IntPtr );
    CHECK_NOT_NULL( CdP );
    CdP->Ptr = (void *)(uintptr_t)0xDEADBEEF;
    CHECK( CdP->Ptr == (void *)(uintptr_t)0xDEADBEEF );
    CHECK_EQ_INT( CdP->Flags & CDATA_FLAG_OWNS_MEMORY, CDATA_FLAG_OWNS_MEMORY );
    lua_pop( L, 1 );

    /* --- struct cdata (inline payload) --- */
    PCType_T SCt = Ctype_New( );
    SCt->Kind = CT_STRUCT;
    SCt->Size = 16;
    SCt->Align = 8;

    PCData_T SCd = FfiNewCData( L, SCt );
    CHECK_NOT_NULL( SCd );
    CHECK( SCd->Type == SCt );

    /* inline payload zero-initialised */
    int AllZero = 1;
    int i;
    for ( i = 0; i < 16; i++ ) {
        if ( SCd->Inline[ i ] != 0 ) { AllZero = 0; break; }
    }
    CHECK( AllZero );

    /* write and read back bytes via Cdata_Storage */
    void *St = Cdata_Storage( SCd );
    CHECK_NOT_NULL( St );
    ( (uint8_t *)St )[ 0 ] = 0xAB;
    ( (uint8_t *)St )[ 15 ] = 0xCD;
    CHECK_EQ_INT( SCd->Inline[ 0 ],  0xAB );
    CHECK_EQ_INT( SCd->Inline[ 15 ], 0xCD );
    lua_pop( L, 1 );

    /* --- FfiNewCDataN for VLA --- */
    PCType_T ArrT = Ctype_New( );
    ArrT->Kind    = CT_ARRAY;
    ArrT->Size    = 0;   /* flex */
    ArrT->Align   = 4;
    ArrT->IsFlex  = 1;
    ArrT->ElemType = IntT;
    ArrT->ArrayLen = -1;

    PCData_T VlaCd = FfiNewCDataN( L, ArrT, 4 * 4 );
    CHECK_NOT_NULL( VlaCd );
    /* write via storage */
    int32_t *Ints = (int32_t *)Cdata_Storage( VlaCd );
    Ints[ 0 ] = 10; Ints[ 1 ] = 20; Ints[ 2 ] = 30; Ints[ 3 ] = 40;
    CHECK_EQ_INT( Ints[ 0 ], 10 );
    CHECK_EQ_INT( Ints[ 3 ], 40 );
    lua_pop( L, 1 );

    /* --- GC round: pop everything, collect, no crash --- */
    lua_gc( L, LUA_GCCOLLECT, 0 );

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
