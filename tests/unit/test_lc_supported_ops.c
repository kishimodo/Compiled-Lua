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

    /* Plan 1 added arithmetic + control flow: these must now be ACCEPTED. */
    CHECK( Lc_CheckSupportedOps( ProtoOf( L, "local x = 1 + 2; return x" ), err, sizeof err ) == 1 );
    CHECK( Lc_CheckSupportedOps( ProtoOf( L,
            "local s=0 for i=1,10 do s=s+i end print(s)" ), err, sizeof err ) == 1 );
    CHECK( Lc_CheckSupportedOps( ProtoOf( L,
            "local x=5 if x>3 then print(1) else print(2) end" ), err, sizeof err ) == 1 );
    CHECK( Lc_CheckSupportedOps( ProtoOf( L,
            "local a=0xF0 print(a & 1, a | 2, ~a, a << 1)" ), err, sizeof err ) == 1 );

    /* Plan 2 added tables + global writes: a table constructor (OP_NEWTABLE /
       OP_SETLIST) and a global WRITE (OP_SETTABUP) must now be ACCEPTED. */
    CHECK( Lc_CheckSupportedOps( ProtoOf( L, "local t = {1,2,3}; return t" ), err, sizeof err ) == 1 );
    CHECK( Lc_CheckSupportedOps( ProtoOf( L, "g = 1" ), err, sizeof err ) == 1 );

    /* still beyond the current milestone: a closure (OP_CLOSURE) and a generic
       for over pairs (OP_TFORCALL/OP_TFORLOOP) must be REJECTED with a diagnostic. */
    CHECK( Lc_CheckSupportedOps( ProtoOf( L, "local function f() return 1 end return f" ), err, sizeof err ) == 0 );
    CHECK( err[0] != 0 );
    CHECK( Lc_CheckSupportedOps( ProtoOf( L,
            "local t={} for k,v in pairs(t) do print(k,v) end" ), err, sizeof err ) == 0 );

    lua_close( L );
    TEST_END();
}
