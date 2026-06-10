/* test_paths.c -- compiler path helpers: Paths_ModuleNameToFilePath,
 * Paths_IsStorePath. Exercises src/compiler/paths.c. */
#include "test_harness.h"
#include "compiler/paths.h"

#include <string.h>

int main( void ) {
    TEST_BEGIN( "paths" );

    char Out[512] = { 0 };
    PATHS_OPTS_T Opts = { 0 };

    /* Simple module name with a base path. */
    Opts.BasePath   = "./lua";
    Opts.IncludeDirs = NULL;
    CHECK_EQ_INT( Paths_ModuleNameToFilePath( "foo", &Opts, Out, sizeof( Out ) ), 1 );
    CHECK_EQ_STR( Out, "./lua/foo.lua" );

    /* Dotted module name -> dots become directory separators. */
    CHECK_EQ_INT( Paths_ModuleNameToFilePath( "lang.en", &Opts, Out, sizeof( Out ) ), 1 );
    CHECK_EQ_STR( Out, "./lua/lang/en.lua" );

    /* Deeper nesting. */
    CHECK_EQ_INT( Paths_ModuleNameToFilePath( "a.b.c", &Opts, Out, sizeof( Out ) ), 1 );
    CHECK_EQ_STR( Out, "./lua/a/b/c.lua" );

    /* Empty module name is rejected. */
    CHECK_EQ_INT( Paths_ModuleNameToFilePath( "", &Opts, Out, sizeof( Out ) ), 0 );

    /* NULL module name is rejected. */
    CHECK_EQ_INT( Paths_ModuleNameToFilePath( NULL, &Opts, Out, sizeof( Out ) ), 0 );

    /* Output buffer too small to hold result is rejected. */
    CHECK_EQ_INT( Paths_ModuleNameToFilePath( "foo", &Opts, Out, 3 ), 0 );

    /* Paths_IsStorePath: a path under the store prefix returns 1. */
    /* A plain relative path like "./lua/foo.lua" is not a store path. */
    CHECK_EQ_INT( Paths_IsStorePath( "./lua/foo.lua" ), 0 );

    TEST_END();
}
