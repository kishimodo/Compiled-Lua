/*!
 * @brief
 *  Scaffolding binary: load a raw .luac file and execute it via the
 *  upstream Lua interpreter. Removed in Plan 2 once the JIT replaces lvm.c.
 */

#include "common/version.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <stdio.h>
#include <stdlib.h>

int main( int Argc, char **Argv ) {
    lua_State *L = { 0 };
    int Rc = { 0 };

    if ( Argc < 2 ) {
        printf( "[*] LuaVM runluac v%s\n", LUAVM_VERSION_STRING );
        printf( "[_] usage: runluac.exe <input.luac> [args...]\n" );
        return EXIT_FAILURE;
    }

    L = luaL_newstate( );
    if ( L == NULL ) {
        printf( "[-] luaL_newstate failed\n" );
        return EXIT_FAILURE;
    }
    luaL_openlibs( L );

    Rc = luaL_loadfile( L, Argv[ 1 ] );
    if ( Rc != LUA_OK ) {
        printf( "[-] load failed :: %s\n", lua_tostring( L, -1 ) );
        lua_close( L );
        return EXIT_FAILURE;
    }
    Rc = lua_pcall( L, 0, 0, 0 );
    if ( Rc != LUA_OK ) {
        printf( "[-] run failed :: %s\n", lua_tostring( L, -1 ) );
        lua_close( L );
        return EXIT_FAILURE;
    }

    lua_close( L );
    return EXIT_SUCCESS;
}
