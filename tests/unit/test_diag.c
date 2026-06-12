/* test_diag.c -- compiler diagnostics: Diag_SlurpFile and Diag_RunLint.
 * New test (no old version in git). Exercises src/compiler/diag.c. */
#include "test_harness.h"
#include "compiler/diag.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Path to the lint package source that ships with CLua. */
#define LINT_SRC_PATH "clua/src/runtime/packages/lint/init.lua"

/* Scratch directory for temporary test files. */
#define TMP_DIR "build/bin/tests"

static void WriteFile( const char *Path, const char *Content ) {
    FILE *F = fopen( Path, "wb" );
    if ( F ) {
        fwrite( Content, 1, strlen( Content ), F );
        fclose( F );
    }
}

int main( void ) {
    TEST_BEGIN( "diag" );

    /* -------------------------------------------------------------------
     * Diag_SlurpFile: read a known file and verify the content round-trips.
     * ------------------------------------------------------------------- */

    const char *TmpPath = TMP_DIR "/diag_tmp.lua";
    const char *TmpContent = "-- hello\nlocal x = 1\nreturn x\n";
    WriteFile( TmpPath, TmpContent );

    size_t Len = 0;
    char *Slurped = Diag_SlurpFile( TmpPath, &Len );
    CHECK_NOT_NULL( Slurped );
    CHECK_EQ_INT( (int)Len, (int)strlen( TmpContent ) );
    CHECK_EQ_STR( Slurped, TmpContent );
    free( Slurped );

    /* Slurping a missing file returns NULL. */
    CHECK_NULL( Diag_SlurpFile( TMP_DIR "/does_not_exist_xyz.lua", &Len ) );

    /* NULL path returns NULL. */
    CHECK_NULL( Diag_SlurpFile( NULL, &Len ) );

    /* OutLen may be NULL (no crash). */
    char *S2 = Diag_SlurpFile( TmpPath, NULL );
    CHECK_NOT_NULL( S2 );
    free( S2 );

    /* -------------------------------------------------------------------
     * Diag_RunLint: exercise the lint pass against a real source file.
     * Load the lint package from its well-known path.
     * ------------------------------------------------------------------- */

    size_t LintLen = 0;
    char *LintSrc = Diag_SlurpFile( LINT_SRC_PATH, &LintLen );
    CHECK_NOT_NULL( LintSrc );   /* if this fails the lint source is missing */

    DIAG_OPTS_T Opts = { 0 };
    Opts.Warnings        = 1;
    Opts.WarningsAsErrors = 0;
    Opts.Color           = 0;

    /* Source with an unused local -> expect >= 1 finding. */
    const char *BadSrc = "local unused_var = 42\nreturn 0\n";
    const char *BadPath = TMP_DIR "/diag_bad.lua";
    WriteFile( BadPath, BadSrc );
    int Findings = Diag_RunLint( BadPath, LintSrc, &Opts );
    CHECK( Findings > 0 );

    /* Clean source -> expect 0 findings. */
    const char *CleanSrc = "local x = 1\nreturn x\n";
    const char *CleanPath = TMP_DIR "/diag_clean.lua";
    WriteFile( CleanPath, CleanSrc );
    int CleanFindings = Diag_RunLint( CleanPath, LintSrc, &Opts );
    CHECK_EQ_INT( CleanFindings, 0 );

    /* With Warnings = 0, lint is skipped -> always returns 0. */
    DIAG_OPTS_T NoWarn = { 0 };
    NoWarn.Warnings = 0;
    CHECK_EQ_INT( Diag_RunLint( BadPath, LintSrc, &NoWarn ), 0 );

    /* NULL LintSource -> returns 0 (lint unavailable). */
    CHECK_EQ_INT( Diag_RunLint( BadPath, NULL, &Opts ), 0 );

    /* NULL SourcePath -> returns 0. */
    CHECK_EQ_INT( Diag_RunLint( NULL, LintSrc, &Opts ), 0 );

    /* NULL Opts -> returns 0. */
    CHECK_EQ_INT( Diag_RunLint( BadPath, LintSrc, NULL ), 0 );

    free( LintSrc );
    TEST_END();
}
