/* test_lc_codegen_epsilon.c -- LuaC AOT codegen, epsilon op set.
 *
 * Lifts the epsilon program `print("hello")` to memory-form IR (the same way
 * test_lc_lift.c does) and runs lc_codegen over it, then asserts STRUCTURE of
 * the emitted function body (not execution — end-to-end correctness is the
 * differential gate's job in Task 17):
 *   - a compiled module with >= 1 function exists,
 *   - the first function's body is non-trivial and opens with the prologue
 *     PUSH RDI (0x57),
 *   - its symbol name is "luac_fn_0",
 *   - the body records name-keyed REL32 relocs that call the expected runtime
 *     helpers (Rt_GetTabUp for the _ENV["print"] read, Rt_Call for the call).
 */
#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "ir/ir.h"
#include "ir/lift.h"
#include "codegen/codegen.h"

#include <string.h>

int main( void ) {
    lua_State    *L = luaL_newstate();
    Proto        *P;
    LcModule     *m;
    LcFunc       *f;
    LcCodeModule *cm;

    TEST_BEGIN( "lc_codegen_epsilon" );

    /* Build the epsilon IR exactly like test_lc_lift.c. The closure's Proto
       must stay alive (it does — the closure is on L's stack) for codegen. */
    CHECK( luaL_loadstring( L, "print(\"hello\")" ) == LUA_OK );
    P = ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
    CHECK( P != NULL );
    CHECK( P->sizecode > 0 );

    m = lc_module_new();
    CHECK( m != NULL );
    f = lc_func_new( m, P );
    CHECK( f != NULL );
    m->entry = f;
    lc_lift_func( f );

    /* ---- the unit under test ---- */
    cm = lc_codegen( m );
    CHECK( cm != NULL && cm->nfuncs >= 1 );

    LcCompiledFunc *f0 = &cm->funcs[0];
    CHECK( f0->code_len > 8 );                 /* prologue + body + epilogue */
    CHECK( f0->code[0] == 0x57 );              /* PUSH RDI (prologue start)  */
    CHECK( strcmp( f0->name, "luac_fn_0" ) == 0 );

    /* the body must call the expected runtime helpers by name */
    int    saw_gettabup = 0, saw_call = 0;
    size_t r;
    for ( r = 0; r < f0->nrelocs; r++ ) {
        if ( strcmp( f0->relocs[r].symbol, "Rt_GetTabUp" ) == 0 ) saw_gettabup = 1;
        if ( strcmp( f0->relocs[r].symbol, "Rt_Call"     ) == 0 ) saw_call     = 1;
    }
    CHECK( saw_gettabup && saw_call );

    lc_codemodule_free( cm );
    lc_module_free( m );
    lua_close( L );

    TEST_END();
}
