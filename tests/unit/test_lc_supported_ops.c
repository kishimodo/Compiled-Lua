#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "driver/supported_ops.h"

static Proto *ProtoOf( lua_State *L, const char *src ) {
    luaL_loadstring( L, src );                      /* pushes a closure */
    return ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
}

int main( void ) {
    lua_State *L = luaL_newstate();
    char err[256];

    TEST_BEGIN( "lc_supported_ops" );

    /* epsilon-supported program: must pass the gate */
    CHECK( Lc_CheckSupportedOps( ProtoOf( L, "print(\"hello\")" ), err, sizeof err ) == 1 );

    /* arithmetic uses OP_ADD / OP_LOADI: must be rejected */
    CHECK( Lc_CheckSupportedOps( ProtoOf( L, "local x = 1 + 2; return x" ), err, sizeof err ) == 0 );

    /* a non-empty error message must have been produced */
    CHECK( err[0] != 0 );

    lua_close( L );
    TEST_END();
}
