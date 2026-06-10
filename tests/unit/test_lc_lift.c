#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "ir/ir.h"
#include "ir/lift.h"

static int has_op( LcFunc *f, LcOpcode op ) {
    uint32_t bi;
    LcInst *in;
    for ( bi = 0; bi < f->nblocks; bi++ )
        for ( in = f->blocks[bi]->first; in; in = in->next )
            if ( in->op == op ) return 1;
    return 0;
}

int main( void ) {
    lua_State *L = luaL_newstate();
    Proto *P;
    LcModule *m;
    LcFunc *f;

    TEST_BEGIN( "lc_lift" );

    /* The epsilon program: print("hello"). luaL_loadstring leaves a closure on
    ** the stack; its Proto must stay alive for the duration of lifting. */
    CHECK( luaL_loadstring( L, "print(\"hello\")" ) == LUA_OK );
    P = ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
    CHECK( P != NULL );
    CHECK( P->sizecode > 0 );

    m = lc_module_new();
    CHECK( m != NULL );
    f = lc_func_new( m, P );
    CHECK( f != NULL );

    lc_lift_func( f );

    /* M0 produces a single pre-SSA basic block. */
    CHECK( f->is_ssa == 0 );
    CHECK( f->nblocks >= 1 );

    /* The epsilon op set must be present. */
    CHECK( has_op( f, LC_OP_GLOBAL_GET ) );   /* GETTABUP _ENV["print"] */
    CHECK( has_op( f, LC_OP_CONST ) );        /* LOADK "hello"          */
    CHECK( has_op( f, LC_OP_CALL ) );         /* CALL print(...)        */
    CHECK( has_op( f, LC_OP_RETURN ) );       /* RETURN0 / RETURN       */

    lc_module_free( m );
    lua_close( L );

    TEST_END();
}
