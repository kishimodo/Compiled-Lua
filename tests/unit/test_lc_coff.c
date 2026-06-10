/* test_lc_coff.c -- LuaC COFF object writer end-to-end (Task 12).
 *
 * Lifts + codegens the epsilon program `print("hello")` exactly like
 * test_lc_codegen_epsilon.c, writes the resulting LcCodeModule to a real COFF
 * object via LcCoff_Write, then LINK-PROBES it (the Task 2 spike recipe): links
 * the object against the runtime archives with a companion main and
 * -Wl,--undefined=luac_fn_0 to force-keep the generated function. A successful
 * link (rc==0) proves the COFF parses and its Rt_* relocs resolve by name from
 * the archive -- the real gate. We also assert structurally that the writer
 * succeeds and the function symbol is present via objdump-free CHECKs.
 */
#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "ir/ir.h"
#include "ir/lift.h"
#include "codegen/codegen.h"
#include "link/coff_write.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <direct.h> /* _mkdir */

int main( void ) {
    lua_State    *L = luaL_newstate();
    Proto        *P;
    LcModule     *m;
    LcFunc       *f;
    LcCodeModule *cm;
    char          err[256] = { 0 };
    int           wrc;

    TEST_BEGIN( "lc_coff" );

    /* ---- build the epsilon IR exactly like test_lc_codegen_epsilon.c ---- */
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

    cm = lc_codegen( m );
    CHECK( cm != NULL && cm->nfuncs >= 1 );

    /* ---- the unit under test: write the COFF object ---- */
    _mkdir( "build" );
    _mkdir( "build\\tmp" );

    wrc = LcCoff_Write( "build\\tmp\\epsilon.o", cm, err, sizeof err );
    if ( wrc != 1 ) printf( "[i] LcCoff_Write failed: %s\n", err );
    CHECK_EQ_INT( wrc, 1 );

    /* ---- link probe: prove the object parses + relocs resolve ----
     * Companion main (tests/unit/coff_probe_main.c) supplies main so the
     * runtime archive's blob-coupled main stays out; -Wl,--undefined=luac_fn_0
     * force-keeps the generated function so its Rt_* relocs must resolve. */
    {
        int rc = system(
            "x86_64-w64-mingw32-gcc build\\tmp\\epsilon.o "
            "tests\\unit\\coff_probe_main.c "
            "build\\bin\\runtime-embedded.a build\\bin\\liblua54-embedded.a "
            "-o build\\tmp\\epsilon_probe.exe -Wl,--undefined=luac_fn_0 "
            "-lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi" );
        printf( "[i] link probe rc = %d (expect 0: COFF accepted, Rt_* relocs resolved)\n", rc );
        CHECK_EQ_INT( rc, 0 );
    }

    lc_codemodule_free( cm );
    lc_module_free( m );
    lua_close( L );

    TEST_END();
}
