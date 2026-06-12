#include "runtime/embedded_loader.h"

#include "lua.h"
#include "lauxlib.h"

#include <string.h>

static const char k_RegistryKey[ ] = "LUAVM_BLOB_READER";

static int Searcher( lua_State *L ) {
    BLOB_LOOKUP_T Found = { 0 };
    const char    *Name = luaL_checkstring( L, 1 );
    PBLOB_READER_T Reader = { 0 };
    char           Chunkname[ 256 ] = { 0 };
    int            Rc = { 0 };

    lua_getfield( L, LUA_REGISTRYINDEX, k_RegistryKey );
    Reader = ( PBLOB_READER_T )lua_touserdata( L, -1 );
    lua_pop( L, 1 );
    if ( Reader == NULL ) {
        lua_pushliteral( L, "embedded loader not initialised" );
        return 1;
    }

    if ( !BlobReader_Find( Reader, Name, &Found ) ) {
        lua_pushfstring( L, "\n\tno embedded module '%s'", Name );
        return 1;
    }

    snprintf( Chunkname, sizeof( Chunkname ), "@embedded:%s", Name );
    Rc = luaL_loadbufferx( L,
                           ( const char * )Found.Bytes,
                           Found.BytesLen,
                           Chunkname,
                           "b" );
    if ( Rc != LUA_OK ) {
        return lua_error( L );
    }
    /* loader returns the chunk + a "loader data" arg (here, the module name) */
    lua_pushstring( L, Name );
    return 2;
}

void EmbeddedLoader_Install( lua_State *L, PBLOB_READER_T Reader ) {
    /* stash reader in registry */
    lua_pushlightuserdata( L, ( void * )Reader );
    lua_setfield( L, LUA_REGISTRYINDEX, k_RegistryKey );

    /* package.searchers[#searchers + 1] = Searcher  -- append last */
    lua_getglobal( L, "package" );
    lua_getfield( L, -1, "searchers" );
    lua_pushcfunction( L, Searcher );
    lua_rawseti( L, -2, ( int )lua_rawlen( L, -2 ) + 1 );
    lua_pop( L, 2 );
}
