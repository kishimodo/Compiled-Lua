/* test_marshal_strings.c -- Lua string to char* and wchar_t* marshalling,
 * and wchar UTF-8 transcode. Exercises src/ffi/marshal.c string paths. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/marshal.h"

#include "lua.h"
#include "lauxlib.h"

#include <string.h>
#include <wchar.h>
#include <stdint.h>

int main( void ) {
    TEST_BEGIN( "marshal_strings" );

    lua_State *L = luaL_newstate( );
    CHECK_NOT_NULL( L );
    Ctype_Init( );

    /* char* pointer type */
    PCType_T CharT = Ctype_Lookup( "char" );
    CHECK_NOT_NULL( CharT );
    PCType_T LpcStr = Ctype_New( );
    LpcStr->Kind     = CT_PTR;
    LpcStr->Size     = 8;
    LpcStr->Align    = 8;
    LpcStr->ElemType = CharT;

    /* wchar_t pointer type */
    PCType_T WcharT = Ctype_New( );
    WcharT->Kind    = CT_INT;
    WcharT->Size    = 2;
    WcharT->Align   = 2;
    WcharT->IsSigned = 0;
    PCType_T LpcWstr = Ctype_New( );
    LpcWstr->Kind     = CT_PTR;
    LpcWstr->Size     = 8;
    LpcWstr->Align    = 8;
    LpcWstr->ElemType = WcharT;

    /* --- Lua string -> char* (direct pointer into Lua string) --- */
    {
        const char *S = NULL;
        lua_pushstring( L, "hello world" );
        int Top = lua_gettop( L );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, LpcStr, &S ), 8 );
        CHECK_NOT_NULL( S );
        CHECK_EQ_STR( S, "hello world" );
        CHECK_EQ_INT( lua_gettop( L ), Top );   /* no extra pushes for char* */
        lua_pop( L, 1 );
    }

    /* --- Lua string -> wchar_t* (UTF-8 -> UTF-16, scratch userdata pushed) --- */
    {
        const wchar_t *W = NULL;
        lua_pushstring( L, "hello" );
        int Top = lua_gettop( L );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, LpcWstr, &W ), 8 );
        CHECK_NOT_NULL( W );
        CHECK( W[ 0 ] == L'h' );
        CHECK( W[ 1 ] == L'e' );
        CHECK( W[ 2 ] == L'l' );
        CHECK( W[ 3 ] == L'l' );
        CHECK( W[ 4 ] == L'o' );
        CHECK( W[ 5 ] == 0 );
        /* marshal pushed one extra scratch userdata to own the buffer */
        CHECK_EQ_INT( lua_gettop( L ), Top + 1 );
        lua_pop( L, 2 );   /* scratch userdata + original string */
    }

    /* --- UTF-8 multibyte (é = 0xC3 0xA9) -> UTF-16 --- */
    {
        const wchar_t *W = NULL;
        lua_pushstring( L, "h\xc3\xa9llo" );   /* "héllo" */
        int Top = lua_gettop( L );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, LpcWstr, &W ), 8 );
        CHECK_NOT_NULL( W );
        CHECK( W[ 0 ] == L'h' );
        CHECK( W[ 1 ] == 0xe9 );   /* U+00E9 LATIN SMALL LETTER E WITH ACUTE */
        CHECK( W[ 2 ] == L'l' );
        CHECK_EQ_INT( lua_gettop( L ), Top + 1 );
        lua_pop( L, 2 );
    }

    /* --- empty string -> char* (null terminator only) --- */
    {
        const char *S = NULL;
        lua_pushstring( L, "" );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, LpcStr, &S ), 8 );
        CHECK_NOT_NULL( S );
        CHECK_EQ_INT( (int)strlen( S ), 0 );
        lua_pop( L, 1 );
    }

    /* --- empty string -> wchar_t* --- */
    {
        const wchar_t *W = NULL;
        lua_pushstring( L, "" );
        int Top = lua_gettop( L );
        CHECK_EQ_INT( Marshal_LuaToC( L, -1, LpcWstr, &W ), 8 );
        CHECK_NOT_NULL( W );
        CHECK( W[ 0 ] == 0 );
        CHECK_EQ_INT( lua_gettop( L ), Top + 1 );
        lua_pop( L, 2 );
    }

    Ctype_Shutdown( );
    lua_close( L );
    TEST_END( );
}
