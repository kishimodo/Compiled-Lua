#include "compiler/lua_compile.h"

#include "lua.h"
#include "lauxlib.h"

#include <stdlib.h>
#include <string.h>

typedef struct _DUMP_BUF {
    unsigned char *Bytes;
    size_t         Len;
    size_t         Cap;
} DUMP_BUF_T, *PDUMP_BUF_T;

static int DumpWriter( lua_State *L, const void *P, size_t Sz, void *Ud ) {
    PDUMP_BUF_T B = ( PDUMP_BUF_T )Ud;
    ( void )L;
    if ( B->Len + Sz > B->Cap ) {
        size_t NewCap = B->Cap == 0 ? 4096 : B->Cap * 2;
        while ( NewCap < B->Len + Sz ) {
            NewCap *= 2;
        }
        unsigned char *N = ( unsigned char * )realloc( B->Bytes, NewCap );
        if ( N == NULL ) { return 1; /* non-zero = error per lua_Writer contract */ }
        B->Bytes = N;
        B->Cap   = NewCap;
    }
    memcpy( B->Bytes + B->Len, P, Sz );
    B->Len += Sz;
    return 0;
}

static char *DupErr( const char *Msg ) {
    size_t L = { 0 };
    char  *D = { 0 };
    if ( Msg == NULL ) { return NULL; }
    L = strlen( Msg );
    D = ( char * )malloc( L + 1 );
    if ( D == NULL ) { return NULL; }
    memcpy( D, Msg, L + 1 );
    return D;
}

int LuaCompile_File( const char *SourcePath, int Strip, PLUA_COMPILE_RESULT_T Result ) {
    lua_State *L = { 0 };
    DUMP_BUF_T Buf = { 0 };
    int Rc = { 0 };

    if ( SourcePath == NULL || Result == NULL ) {
        return 0;
    }
    memset( Result, 0, sizeof( *Result ) );

    L = luaL_newstate( );
    if ( L == NULL ) {
        Result->ErrMsg = DupErr( "luaL_newstate failed" );
        return 0;
    }

    Rc = luaL_loadfile( L, SourcePath );
    if ( Rc != LUA_OK ) {
        Result->ErrMsg = DupErr( lua_tostring( L, -1 ) );
        lua_close( L );
        return 0;
    }

    /* strip != 0 mirrors luac -s: line info, locvars, upvalue names
       and the source path are all dropped from the dumped Protos. */
    Rc = lua_dump( L, DumpWriter, &Buf, Strip ? 1 : 0 );
    if ( Rc != 0 ) {
        free( Buf.Bytes );
        Result->ErrMsg = DupErr( "lua_dump failed" );
        lua_close( L );
        return 0;
    }

    lua_close( L );
    Result->Bytes    = Buf.Bytes;
    Result->BytesLen = Buf.Len;
    return 1;
}

void LuaCompile_FreeResult( PLUA_COMPILE_RESULT_T Result ) {
    if ( Result == NULL ) { return; }
    free( Result->Bytes );
    free( Result->ErrMsg );
    Result->Bytes    = NULL;
    Result->BytesLen = 0;
    Result->ErrMsg   = NULL;
}
