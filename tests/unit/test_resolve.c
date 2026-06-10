/* test_resolve.c -- require-scan resolver: Resolve_Walk on a small source tree.
 * Exercises src/compiler/resolve.c. */
#include "test_harness.h"
#include "compiler/resolve.h"
#include "compiler/paths.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void WriteFile( const char *Path, const char *Content ) {
    FILE *F = fopen( Path, "wb" );
    if ( F ) {
        fwrite( Content, 1, strlen( Content ), F );
        fclose( F );
    }
}

int main( void ) {
    TEST_BEGIN( "resolve" );

    /* Create a small scratch project under build/bin/tests/resolve_fixture. */
    system( "rmdir /S /Q build\\bin\\tests\\resolve_fixture 2>nul" );
    system( "mkdir build\\bin\\tests\\resolve_fixture\\lang 2>nul" );

    WriteFile( "build/bin/tests/resolve_fixture/main.lua",
        "local g  = require('greet')\n"
        "local en = require('lang.en')\n"
        "g.say(en.hello)\n" );

    WriteFile( "build/bin/tests/resolve_fixture/greet.lua",
        "return { say = function(s) print(s) end }\n" );

    WriteFile( "build/bin/tests/resolve_fixture/lang/en.lua",
        "return { hello = 'hello' }\n" );

    PATHS_OPTS_T Paths = { 0 };
    Paths.BasePath    = "build/bin/tests/resolve_fixture";
    Paths.IncludeDirs = NULL;

    RESOLVE_OPTS_T Opts = { 0 };
    Opts.PathsOpts = &Paths;

    RESOLVE_RESULT_T R = { 0 };
    CHECK_EQ_INT(
        Resolve_Walk( "build/bin/tests/resolve_fixture/main.lua", &Opts, &R ),
        1 );

    /* Should have found exactly 3 modules: main + greet + lang.en. */
    CHECK_EQ_INT( (int)R.Count, 3 );

    /* Entry module is always at index 0 and named "main". */
    CHECK_NOT_NULL( R.Modules );
    CHECK_EQ_STR( R.Modules[0].Name, "main" );

    /* Verify greet and lang.en are present (in any order among [1..2]). */
    int FoundGreet = 0, FoundEn = 0;
    for ( size_t I = 1; I < R.Count; I++ ) {
        if ( strcmp( R.Modules[I].Name, "greet" )   == 0 ) FoundGreet = 1;
        if ( strcmp( R.Modules[I].Name, "lang.en" ) == 0 ) FoundEn    = 1;
    }
    CHECK_EQ_INT( FoundGreet, 1 );
    CHECK_EQ_INT( FoundEn,    1 );

    /* Every resolved module has bytecode. */
    for ( size_t I = 0; I < R.Count; I++ ) {
        CHECK_NOT_NULL( R.Modules[I].Bytes );
        CHECK( R.Modules[I].BytesLen > 0 );
    }

    Resolve_FreeResult( &R );

    /* Walking a nonexistent entry file returns 0. */
    RESOLVE_RESULT_T R2 = { 0 };
    CHECK_EQ_INT(
        Resolve_Walk( "build/bin/tests/resolve_fixture/nonexistent.lua", &Opts, &R2 ),
        0 );

    TEST_END();
}
