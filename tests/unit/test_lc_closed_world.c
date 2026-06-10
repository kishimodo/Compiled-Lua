#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "driver/closed_world.h"

static Proto *ProtoOf( lua_State *L, const char *src ) {
    luaL_loadstring( L, src );                      /* pushes a closure */
    return ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
}

int main( void ) {
    lua_State *L = luaL_newstate();
    char err[256];

    TEST_BEGIN( "lc_closed_world" );

    /* static require("json") must be allowed */
    CHECK( Lc_CheckClosedWorld( ProtoOf( L, "local t = require('json'); return t" ), err, sizeof err ) == 1 );

    /* load() must be rejected */
    CHECK( Lc_CheckClosedWorld( ProtoOf( L, "return load('return 1')" ),            err, sizeof err ) == 0 );

    /* dofile() must be rejected */
    CHECK( Lc_CheckClosedWorld( ProtoOf( L, "dofile('x.lua')" ),                    err, sizeof err ) == 0 );

    lua_close( L );
    TEST_END();
}
