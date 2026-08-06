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

/* Process-wide diagnostic format. Text is the default; the CLI overrides via
 * LcDiag_SetFormat() before the resolve pass runs (i.e. before any diagnostic
 * has had a chance to fire). */
static LC_DIAG_FORMAT_T g_DiagFormat = LC_DIAG_TEXT;

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

void LcDiag_SetFormat( LC_DIAG_FORMAT_T Mode ) {
    g_DiagFormat = Mode;
}

LC_DIAG_FORMAT_T LcDiag_GetFormat( void ) {
    return g_DiagFormat;
}

int LcDiag_ParseFormat( const char *Value, LC_DIAG_FORMAT_T *Out ) {
    if ( Value == NULL || Out == NULL ) { return 0; }
    if ( strcmp( Value, "text" ) == 0 ) { *Out = LC_DIAG_TEXT; return 1; }
    if ( strcmp( Value, "json" ) == 0 ) { *Out = LC_DIAG_JSON; return 1; }
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
static const char *C_BoldGrnSeq ( int C ) { return C ? "\x1b[1;32m" : ""; }
static const char *C_BoldBluSeq ( int C ) { return C ? "\x1b[1;34m" : ""; }
static const char *C_BoldWhtSeq ( int C ) { return C ? "\x1b[1;37m" : ""; }

/* Pick the category color. "warning" and its bracketed variants (e.g.
 * "warning[Wunused]" from the -W scanner) paint yellow; "note" and "help"
 * paint cyan (they're advisory follow-ups to a primary error, not a new
 * error themselves); every other value paints as an error (bold red) --
 * so a typoed or unknown category is loud rather than silently dim. */
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
    /* "help" is the follow-up category used by the diag_suggest "did you
     * mean" pass -- rendered in the same cyan as "note" because it's an
     * advisory suggestion beneath the primary error, not a new error. */
    if ( strncmp( Category, "help", 4 ) == 0 &&
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

/* ==== multi-span report ==================================================
 *
 * LcDiag_Report groups spans by file, reads each file once (cached), and
 * prints a rustc/zig-style block per group with 2 lines of context above and
 * below the primary line. Notes are grouped, help/hint appear at the end.
 *
 * The caller owns all pointers; we do not free anything they gave us.
 * Internal caches are freed before return.
 * ======================================================================= */

/* Severity -> textual label used in the header. */
static const char *SeverityLabel( LcSeverity S ) {
    switch ( S ) {
        case LCSEV_ERROR:   return "error";
        case LCSEV_WARNING: return "warning";
        case LCSEV_NOTE:    return "note";
        case LCSEV_HELP:    return "help";
        case LCSEV_HINT:    return "hint";
    }
    return "error";
}

/* Severity -> bold ANSI color per the spec (red / yellow / cyan / green / blue). */
static const char *SeverityColor( LcSeverity S, int C ) {
    switch ( S ) {
        case LCSEV_ERROR:   return C_BoldRedSeq( C );
        case LCSEV_WARNING: return C_BoldYelSeq( C );
        case LCSEV_NOTE:    return C_BoldCynSeq( C );
        case LCSEV_HELP:    return C_BoldGrnSeq( C );
        case LCSEV_HINT:    return C_BoldBluSeq( C );
    }
    return C_BoldRedSeq( C );
}

/* File slurp cache. A single Report typically references 1-3 files; a
 * linear array is smaller and cache-friendlier than a hash. Path pointers
 * come from the caller and outlive the Report call, so we key by pointer
 * equality first, then by string content -- that catches the common case
 * (same span array reuses the same const string) without a strcmp per
 * lookup. */
typedef struct {
    const char *path;
    char       *text;   /* malloc'd, owned by the cache. NULL if unreadable. */
    int         nlines; /* newline count + 1 */
} FileCacheEntry;

typedef struct {
    FileCacheEntry *ents;
    int             n;
    int             cap;
} FileCache;

static char *SlurpFile( const char *Path ) {
    FILE  *F;
    long   N;
    char  *Buf;
    size_t Got;
    if ( Path == NULL ) { return NULL; }
    F = fopen( Path, "rb" );
    if ( F == NULL ) { return NULL; }
    if ( fseek( F, 0, SEEK_END ) != 0 ) { fclose( F ); return NULL; }
    N = ftell( F );
    if ( N < 0 )                       { fclose( F ); return NULL; }
    if ( fseek( F, 0, SEEK_SET ) != 0 ) { fclose( F ); return NULL; }
    Buf = ( char * )malloc( ( size_t )N + 1 );
    if ( Buf == NULL )                 { fclose( F ); return NULL; }
    Got = fread( Buf, 1, ( size_t )N, F );
    fclose( F );
    if ( Got != ( size_t )N )          { free( Buf ); return NULL; }
    Buf[ N ] = '\0';
    return Buf;
}

/* Count 1-based lines. A trailing `\n` does NOT start a new line -- so
 * "a\nb\n" has 2 lines, not 3. That matches what a user sees in the editor
 * and prevents the snippet from printing a phantom empty line below the
 * last real line. */
static int CountLines( const char *Text ) {
    int         Count = 0;
    const char *P     = Text;
    if ( Text == NULL || *Text == '\0' ) { return 0; }
    Count = 1;
    for ( ; *P != '\0'; P++ ) {
        if ( *P == '\n' && P[ 1 ] != '\0' ) { Count++; }
    }
    return Count;
}

/* Look up or slurp Path. Returns the cache entry (never NULL; text may be
 * NULL if the file is unreadable). */
static FileCacheEntry *FileCache_Get( FileCache *FC, const char *Path ) {
    int I;
    for ( I = 0; I < FC->n; I++ ) {
        if ( FC->ents[ I ].path == Path ) { return &FC->ents[ I ]; }
    }
    for ( I = 0; I < FC->n; I++ ) {
        if ( Path && FC->ents[ I ].path &&
             strcmp( FC->ents[ I ].path, Path ) == 0 ) {
            return &FC->ents[ I ];
        }
    }
    if ( FC->n == FC->cap ) {
        int NewCap = FC->cap ? FC->cap * 2 : 4;
        FileCacheEntry *P = ( FileCacheEntry * )realloc(
            FC->ents, ( size_t )NewCap * sizeof( *P ) );
        if ( P == NULL ) { return NULL; }
        FC->ents = P;
        FC->cap  = NewCap;
    }
    FC->ents[ FC->n ].path   = Path;
    FC->ents[ FC->n ].text   = SlurpFile( Path );
    FC->ents[ FC->n ].nlines = CountLines( FC->ents[ FC->n ].text );
    return &FC->ents[ FC->n++ ];
}

static void FileCache_Free( FileCache *FC ) {
    int I;
    for ( I = 0; I < FC->n; I++ ) { free( FC->ents[ I ].text ); }
    free( FC->ents );
    FC->ents = NULL;
    FC->n = FC->cap = 0;
}

/* Copy 1-based line `Line` of Text into Out (without its newline). Returns the
 * line length, or -1 if the line doesn't exist. Matches diag.c/GetSourceLine
 * behavior (\r converted to space so it doesn't mangle the caret column). */
static int LineOf( const char *Text, int Line, char *Out, size_t OutSize ) {
    int         Cur = 1;
    const char *P   = Text;
    size_t      I   = 0;
    if ( Text == NULL || Line < 1 || OutSize == 0 ) { return -1; }
    while ( Cur < Line && *P != '\0' ) {
        if ( *P == '\n' ) { Cur++; }
        P++;
    }
    if ( Cur != Line ) { return -1; }
    while ( P[ I ] != '\0' && P[ I ] != '\n' && I + 1 < OutSize ) {
        Out[ I ] = ( P[ I ] == '\r' ) ? ' ' : P[ I ];
        I++;
    }
    Out[ I ] = '\0';
    return ( int )I;
}

/* Walk every span (top + notes) and return the widest line-number's digit
 * count, so the whole report shares one gutter. Rustc does the same -- it
 * keeps the "|" pipe column stable across snippet blocks. */
static int MaxGutter( const LcDiagSpan *Spans, int NS,
                      const LcDiagNote *Notes, int NN ) {
    int MaxLine = 1;
    int I, J;
    for ( I = 0; I < NS; I++ ) {
        int L = Spans[ I ].line;
        if ( L + 2 > MaxLine ) { MaxLine = L + 2; }
    }
    for ( J = 0; J < NN; J++ ) {
        for ( I = 0; I < Notes[ J ].nspans; I++ ) {
            int L = Notes[ J ].spans[ I ].line;
            if ( L + 2 > MaxLine ) { MaxLine = L + 2; }
        }
    }
    return DigitsOf( MaxLine );
}

/* Print the caret row for one span: pad columns 1..(col_start-1) preserving
 * tabs, then N carets for the highlighted range, then the label (if any).
 * Primary spans use '^' in Sev's color, secondaries use '-' in blue. */
static void PrintCaretRow( FILE *Out, int Gutter, const char *ArrowColor,
                           const char *Reset, const char *SpanColor,
                           const LcDiagSpan *S, const char *LineText ) {
    int  Start = S->col_start > 0 ? S->col_start : 1;
    int  End   = S->col_end   > 0 ? S->col_end   : Start;
    int  LineLen = LineText ? ( int )strlen( LineText ) : 0;
    char Glyph = S->is_primary ? '^' : '-';
    int  I;

    if ( Start > LineLen + 1 ) { Start = LineLen + 1; }
    if ( End   < Start        ) { End   = Start;      }
    if ( End   > LineLen + 1  ) { End   = LineLen + 1;}

    fprintf( Out, "%*s %s|%s ", Gutter, "", ArrowColor, Reset );
    for ( I = 1; I < Start; I++ ) {
        char Ch = ( LineText && I - 1 < LineLen ) ? LineText[ I - 1 ] : ' ';
        fputc( Ch == '\t' ? '\t' : ' ', Out );
    }
    fputs( SpanColor, Out );
    for ( I = Start; I <= End; I++ ) { fputc( Glyph, Out ); }
    fputs( Reset, Out );
    if ( S->label != NULL && S->label[ 0 ] != '\0' ) {
        fprintf( Out, "  %s%s%s", SpanColor, S->label, Reset );
    }
    fputc( '\n', Out );
}

/* Print one snippet block for a single span: 2 context lines above, the
 * primary line, the caret row, 2 context lines below. Uses the file cache
 * so multiple spans in the same file don't re-slurp. */
static void PrintSnippetBlock( FILE *Out, int Gutter,
                               const char *ArrowColor, const char *Reset,
                               const char *SpanColor, const LcDiagSpan *S,
                               FileCache *FC ) {
    FileCacheEntry *E = FileCache_Get( FC, S->file );
    char LineBuf[ 1024 ];
    int  StartLine = S->line - 2;
    int  EndLine   = S->line + 2;
    int  L;

    if ( E == NULL || E->text == NULL || S->line < 1 ) {
        /* No source available -- still emit the empty pipe rows so the
         * caret column is visually anchored, but with no snippet. */
        fprintf( Out, "%*s %s|%s\n", Gutter, "", ArrowColor, Reset );
        return;
    }
    if ( StartLine < 1        ) { StartLine = 1; }
    if ( EndLine   > E->nlines ) { EndLine   = E->nlines; }

    fprintf( Out, "%*s %s|%s\n", Gutter, "", ArrowColor, Reset );
    for ( L = StartLine; L <= EndLine; L++ ) {
        int Len = LineOf( E->text, L, LineBuf, sizeof( LineBuf ) );
        if ( Len < 0 ) { continue; }
        fprintf( Out, "%s%*d%s %s|%s %s\n",
                 ArrowColor, Gutter, L, Reset,
                 ArrowColor, Reset, LineBuf );
        if ( L == S->line ) {
            PrintCaretRow( Out, Gutter, ArrowColor, Reset, SpanColor,
                           S, LineBuf );
        }
    }
    fprintf( Out, "%*s %s|%s\n", Gutter, "", ArrowColor, Reset );
}

/* Print the arrow (`-->`) row. When col info is missing we degrade like the
 * legacy printer: `file:line`, or bare `file`. */
static void PrintArrow( FILE *Out, int Gutter, const char *ArrowColor,
                        const char *Reset, const LcDiagSpan *S ) {
    const char *File = ( S->file && S->file[ 0 ] ) ? S->file : "<source>";
    if ( S->line > 0 && S->col_start > 0 ) {
        fprintf( Out, "%*s%s-->%s %s:%d:%d\n",
                 Gutter, "", ArrowColor, Reset, File, S->line, S->col_start );
    } else if ( S->line > 0 ) {
        fprintf( Out, "%*s%s-->%s %s:%d\n",
                 Gutter, "", ArrowColor, Reset, File, S->line );
    } else {
        fprintf( Out, "%*s%s-->%s %s\n",
                 Gutter, "", ArrowColor, Reset, File );
    }
}

/* Print the header line: `<sev>[<code>]: <msg>` with the sev + optional
 * bracketed code painted in the severity color, message uncolored. */
static void PrintHeader( FILE *Out, int Color, LcSeverity Sev,
                         const char *Code, const char *Msg ) {
    const char *SevColor = SeverityColor( Sev, Color );
    const char *Reset    = C_ResetSeq   ( Color );
    const char *Label    = SeverityLabel( Sev );
    const char *ShownMsg = Msg ? Msg : "(no message)";
    if ( Code && Code[ 0 ] ) {
        fprintf( Out, "%s%s[%s]%s: %s\n", SevColor, Label, Code, Reset, ShownMsg );
    } else {
        fprintf( Out, "%s%s%s: %s\n", SevColor, Label, Reset, ShownMsg );
    }
}

/* Emit one severity group (primary block, or a note). Handles the case where
 * there is no span at all (a bare `help:` with just a message and no file). */
static void PrintGroup( FILE *Out, int Color, int Gutter, LcSeverity Sev,
                        const char *Code, const char *Msg,
                        const LcDiagSpan *Spans, int NSpans,
                        FileCache *FC ) {
    const char *Reset      = C_ResetSeq   ( Color );
    const char *ArrowColor = C_BoldBluSeq ( Color );
    const char *SevColor   = SeverityColor( Sev, Color );
    int         I;

    PrintHeader( Out, Color, Sev, Code, Msg );
    if ( NSpans <= 0 || Spans == NULL ) { return; }

    /* Find the primary span for the arrow header; fall back to spans[0].
     * Rustc points the arrow at the primary regardless of order in the
     * span array. */
    int Arrow = 0;
    for ( I = 0; I < NSpans; I++ ) {
        if ( Spans[ I ].is_primary ) { Arrow = I; break; }
    }
    PrintArrow( Out, Gutter, ArrowColor, Reset, &Spans[ Arrow ] );

    /* One snippet block per span. In the common case (one primary + a few
     * secondaries in different files) this is the right layout; when two
     * spans point at adjacent lines in the same file the reader still sees
     * the overlap because we always emit 2 lines of context on each side. */
    for ( I = 0; I < NSpans; I++ ) {
        const char *SpanColor = Spans[ I ].is_primary ? SevColor : ArrowColor;
        PrintSnippetBlock( Out, Gutter, ArrowColor, Reset, SpanColor,
                           &Spans[ I ], FC );
    }
}

void LcDiag_Report( FILE             *Out,
                    LcSeverity        Sev,
                    const char       *Code,
                    const char       *Msg,
                    const LcDiagSpan *Spans,
                    int               NSpans,
                    const LcDiagNote *Notes,
                    int               NNotes,
                    const char       *Help ) {
    if ( Out == NULL ) { return; }
    int       Color  = LcDiag_ShouldColor( Out );
    int       Gutter = MaxGutter( Spans, NSpans, Notes, NNotes );
    FileCache FC     = { NULL, 0, 0 };
    int       I;

    PrintGroup( Out, Color, Gutter, Sev, Code, Msg, Spans, NSpans, &FC );

    for ( I = 0; I < NNotes; I++ ) {
        PrintGroup( Out, Color, Gutter, Notes[ I ].sev, NULL,
                    Notes[ I ].msg, Notes[ I ].spans, Notes[ I ].nspans,
                    &FC );
    }

    if ( Help != NULL && Help[ 0 ] != '\0' ) {
        const char *Reset    = C_ResetSeq   ( Color );
        const char *HelpCol  = SeverityColor( LCSEV_HELP, Color );
        fprintf( Out, "%s%s%s: %s\n", HelpCol, "help", Reset, Help );
    }

    FileCache_Free( &FC );
    fflush( Out );
}
