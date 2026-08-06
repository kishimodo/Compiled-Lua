#include "compiler/diag_pretty.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <io.h>
#  include <windows.h>
#  ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#    define ENABLE_VIRTUAL_TERMINAL_PROCESSING 0x0004
#  endif
#else
#  include <unistd.h>
#endif

/* Process-wide color mode. LCDIAG_COLOR_AUTO is the default; the CLI overrides
 * it via LcDiag_SetColorMode() before the first diagnostic is emitted. */
static LC_DIAG_COLOR_MODE_T g_ColorMode = LCDIAG_COLOR_AUTO;

/* True once we've tried to enable ENABLE_VIRTUAL_TERMINAL_PROCESSING on the
 * process's stderr/stdout consoles. GetConsoleMode is a syscall; do it once. */
static int g_VtProbed = 0;

static int Fd( FILE *F ) {
#ifdef _WIN32
    return _fileno( F );
#else
    return fileno( F );
#endif
}

static int IsTty( FILE *F ) {
    if ( F == NULL ) { return 0; }
#ifdef _WIN32
    return _isatty( Fd( F ) );
#else
    return isatty( Fd( F ) );
#endif
}

/* On Windows 10+, GetConsoleMode + SetConsoleMode|ENABLE_VIRTUAL_TERMINAL_PROCESSING
 * turns an ANSI escape sequence into actual color. Older consoles / redirected
 * handles simply return FALSE from GetConsoleMode; that's the signal that ANSI
 * won't be rendered, and callers fall back to plain ASCII. */
static int EnableVtOn( FILE *F ) {
#ifdef _WIN32
    if ( F == NULL ) { return 0; }
    if ( !IsTty( F ) ) { return 0; }
    HANDLE H = ( HANDLE )_get_osfhandle( Fd( F ) );
    if ( H == INVALID_HANDLE_VALUE || H == NULL ) { return 0; }
    DWORD Mode = 0;
    if ( !GetConsoleMode( H, &Mode ) ) { return 0; }
    if ( Mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING ) { return 1; }
    if ( !SetConsoleMode( H, Mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING ) ) { return 0; }
    return 1;
#else
    return IsTty( F );
#endif
}

void LcDiag_SetColorMode( LC_DIAG_COLOR_MODE_T Mode ) {
    g_ColorMode = Mode;
    /* Probe VT once so the first diagnostic already has color enabled. Do it
     * on both stderr and stdout — most callers use stderr but tests capture
     * either. GetConsoleMode fails silently on redirected pipes. */
    if ( !g_VtProbed && Mode != LCDIAG_COLOR_NEVER ) {
        EnableVtOn( stderr );
        EnableVtOn( stdout );
        g_VtProbed = 1;
    }
}

int LcDiag_ParseColorMode( const char *Value, LC_DIAG_COLOR_MODE_T *Out ) {
    if ( Value == NULL || Out == NULL ) { return 0; }
    if ( strcmp( Value, "auto"   ) == 0 ) { *Out = LCDIAG_COLOR_AUTO;   return 1; }
    if ( strcmp( Value, "always" ) == 0 ) { *Out = LCDIAG_COLOR_ALWAYS; return 1; }
    if ( strcmp( Value, "never"  ) == 0 ) { *Out = LCDIAG_COLOR_NEVER;  return 1; }
    return 0;
}

int LcDiag_ShouldColor( FILE *Out ) {
    /* Explicit CLI wins over everything. */
    if ( g_ColorMode == LCDIAG_COLOR_NEVER  ) { return 0; }
    if ( g_ColorMode == LCDIAG_COLOR_ALWAYS ) { return 1; }
    /* Auto-detect: NO_COLOR (any value) disables per https://no-color.org.
     * CLICOLOR_FORCE (any non-empty value) forces color even off a TTY, to
     * match the widely-adopted BSD `colortest` convention -- letting scripts
     * pipe colored output into a pager without --color=always plumbing. */
    if ( getenv( "NO_COLOR" ) != NULL ) { return 0; }
    {
        const char *Force = getenv( "CLICOLOR_FORCE" );
        if ( Force != NULL && Force[ 0 ] != '\0' ) { return 1; }
    }
    /* Auto: only if stderr is a real console AND (on Windows) the console
     * driver understands ANSI. Handles the "redirected to a file" case: the
     * process must not print ANSI escapes into log files or test-runner
     * captures, since those get counted as garbage characters by naive
     * assertions. */
    if ( !IsTty( Out ) ) { return 0; }
#ifdef _WIN32
    /* EnableVtOn returns 1 both when VT is now enabled AND when it was
     * already on. If it fails (older console host), fall back to no color. */
    return EnableVtOn( Out );
#else
    return 1;
#endif
}

/* ---- ANSI palette --------------------------------------------------------
 * Only the sequences the printer actually uses. Each helper returns the empty
 * string when color is off, so the caller can safely concatenate without any
 * branching in the fprintf calls. */
static const char *C_ResetSeq   ( int C ) { return C ? "\x1b[0m"    : ""; }
static const char *C_BoldRedSeq ( int C ) { return C ? "\x1b[1;31m" : ""; }
static const char *C_BoldYelSeq ( int C ) { return C ? "\x1b[1;33m" : ""; }
static const char *C_BoldCynSeq ( int C ) { return C ? "\x1b[1;36m" : ""; }
static const char *C_BoldBluSeq ( int C ) { return C ? "\x1b[1;34m" : ""; }
static const char *C_BoldWhtSeq ( int C ) { return C ? "\x1b[1;37m" : ""; }

/* Pick the category color. "warning" and its bracketed variants (e.g.
 * "warning[Wunused]" from the -W scanner) paint yellow; "note" cyan; every
 * other value paints as an error (bold red) -- so a typoed or unknown
 * category is loud rather than silently dim. */
static const char *CategoryColor( const char *Category, int C ) {
    if ( Category == NULL ) { return C_BoldRedSeq( C ); }
    if ( strncmp( Category, "warning", 7 ) == 0 &&
         ( Category[ 7 ] == '\0' || Category[ 7 ] == '[' ) ) {
        return C_BoldYelSeq( C );
    }
    if ( strncmp( Category, "note", 4 ) == 0 &&
         ( Category[ 4 ] == '\0' || Category[ 4 ] == '[' ) ) {
        return C_BoldCynSeq( C );
    }
    return C_BoldRedSeq( C );
}

/* Count decimal digits so the gutter is wide enough for the biggest line
 * number we're about to print. Minimum 2 for a stable 2-column gutter on
 * short files (matches rustc). */
static int DigitsOf( int N ) {
    int D = 1;
    if ( N < 0 ) { N = -N; }
    while ( N >= 10 ) { N /= 10; D++; }
    return D < 2 ? 2 : D;
}

/* Column is 1-based, tabs count as one column (a source-line printer that
 * expanded tabs would need to advance the caret in step; we keep it simple
 * and treat every byte as one column, which matches how Lua's own error
 * strings compute columns from the lexer). Guards against a runaway caret
 * when the input reports Col > line length. */
static int ClampCaret( int Col, const char *Line ) {
    int Max = Line ? ( int )strlen( Line ) + 1 : 1;
    if ( Col < 1   ) { return 1;   }
    if ( Col > Max ) { return Max; }
    return Col;
}

void LcDiag_PrintError( FILE       *Out,
                        const char *File,
                        int         Line,
                        int         Col,
                        const char *Category,
                        const char *Msg,
                        const char *SourceLine ) {
    if ( Out == NULL ) { return; }

    int         C          = LcDiag_ShouldColor( Out );
    const char *Reset      = C_ResetSeq   ( C );
    const char *CatColor   = CategoryColor( Category, C );
    const char *ArrowColor = C_BoldBluSeq ( C );
    const char *CaretColor = C_BoldWhtSeq ( C );
    const char *ShownFile  = File     ? File     : "<source>";
    const char *ShownCat   = Category ? Category : "error";
    const char *ShownMsg   = Msg      ? Msg      : "(no message)";
    int         Gutter     = DigitsOf( Line > 0 ? Line : 1 );

    /* Header:  error: syntax error near '='                                 */
    fprintf( Out, "%s%s%s: %s\n", CatColor, ShownCat, Reset, ShownMsg );

    /* Location. When Line/Col are unknown (== 0) we still emit the arrow row
     * with just the file name -- less noisy than printing "1:1" as a guess. */
    if ( Line > 0 && Col > 0 ) {
        fprintf( Out, "%*s%s-->%s %s:%d:%d\n",
                 Gutter, "", ArrowColor, Reset, ShownFile, Line, Col );
    } else if ( Line > 0 ) {
        fprintf( Out, "%*s%s-->%s %s:%d\n",
                 Gutter, "", ArrowColor, Reset, ShownFile, Line );
    } else {
        fprintf( Out, "%*s%s-->%s %s\n",
                 Gutter, "", ArrowColor, Reset, ShownFile );
    }

    if ( SourceLine != NULL && Line > 0 ) {
        /* Blank gutter row (rustc-style spacing between arrow + source).    */
        fprintf( Out, "%*s %s|%s\n",
                 Gutter, "", ArrowColor, Reset );

        /* Source snippet:  12 | local x =                                   */
        fprintf( Out, "%*d %s|%s %s\n",
                 Gutter, Line > 0 ? Line : 1,
                 ArrowColor, Reset, SourceLine );

        /* Caret row:              |         ^                                */
        int Caret = ClampCaret( Col, SourceLine );
        fprintf( Out, "%*s %s|%s ", Gutter, "", ArrowColor, Reset );
        for ( int I = 1; I < Caret; I++ ) {
            /* Preserve tab stops so the caret lines up with the source. */
            char Ch = SourceLine[ I - 1 ];
            fputc( Ch == '\t' ? '\t' : ' ', Out );
        }
        fprintf( Out, "%s^%s\n", CaretColor, Reset );
    }
    fflush( Out );
}
