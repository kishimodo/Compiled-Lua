/* test_lc_protoinit.c -- LuaC AOT ProtoInit C-emitter (Task 13).
 *
 * Lifts the epsilon program `print("hello")` to an LcModule (same way
 * test_lc_codegen_epsilon.c does), runs LcEmitProtoInitC over it, then asserts
 * that the GENERATED C:
 *   - compiles cleanly (gcc -c) against the real Lua + dispatch headers, and
 *   - defines the expected symbols ProtoInit_0 and LuacProgram_BuildEntry.
 *
 * The generated .c references luac_fn_0 as `extern` — unresolved at -c time;
 * that's fine, it's bound at final link (Task 15). We only compile, not link.
 */
#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "ir/ir.h"
#include "ir/lift.h"
#include "codegen/protoinit_emit.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Read a whole text file into a malloc'd NUL-terminated buffer (or NULL). */
static char *slurp( const char *path ) {
    FILE *f = fopen( path, "rb" );
    if ( !f ) return NULL;
    fseek( f, 0, SEEK_END );
    long n = ftell( f );
    if ( n < 0 ) { fclose( f ); return NULL; }
    fseek( f, 0, SEEK_SET );
    char *buf = ( char * )malloc( ( size_t )n + 1 );
    if ( !buf ) { fclose( f ); return NULL; }
    size_t got = fread( buf, 1, ( size_t )n, f );
    buf[got] = '\0';
    fclose( f );
    return buf;
}

int main( void ) {
    lua_State *L = luaL_newstate();
    Proto     *P;
    LcModule  *m;
    LcFunc    *f;
    char       err[256] = { 0 };

    TEST_BEGIN( "lc_protoinit" );

    /* ---- build the epsilon IR exactly like the codegen epsilon test ---- */
    CHECK( luaL_loadstring( L, "print(\"hello\")" ) == LUA_OK );
    P = ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
    CHECK( P != NULL );

    m = lc_module_new();
    CHECK( m != NULL );
    f = lc_func_new( m, P );
    CHECK( f != NULL );
    m->entry = f;
    lc_lift_func( f );

    /* ---- the unit under test: emit the ProtoInit C ---- */
    system( "if not exist build\\tmp mkdir build\\tmp" );
    int ok = LcEmitProtoInitC( "build/tmp/protoinit.c", m, err, sizeof( err ) );
    if ( !ok ) fprintf( stderr, "LcEmitProtoInitC err: %s\n", err );
    CHECK( ok == 1 );

    /* ---- compile the generated C against the real headers ---- */
    int rc = system( "x86_64-w64-mingw32-gcc -std=c99 -I./src -I./lua-5.4/src "
                     "-I./build/gen -DLUAVM_TARGET_WINDOWS_X64=1 "
                     "-c build\\tmp\\protoinit.c -o build\\tmp\\protoinit.o" );
    CHECK( rc == 0 ); /* generated C compiles cleanly against the real headers */

    int rc2 = system( "nm build\\tmp\\protoinit.o > build\\tmp\\pi_syms.txt" );
    CHECK( rc2 == 0 );

    /* ---- the object must define the expected symbols ---- */
    char *syms = slurp( "build/tmp/pi_syms.txt" );
    CHECK( syms != NULL );
    if ( syms ) {
        CHECK( strstr( syms, "LuacProgram_BuildEntry" ) != NULL );
        CHECK( strstr( syms, "ProtoInit_0" ) != NULL );
        free( syms );
    }

    lc_module_free( m );
    lua_close( L );

    TEST_END();
}
