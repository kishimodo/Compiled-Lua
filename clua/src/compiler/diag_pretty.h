/* diag_pretty.h -- structured file:line:col diagnostic formatter.
 *
 * Renders diagnostics in the clang/rustc/zig shape. A single-span error still
 * comes out as:
 *
 *   error[E001]: syntax error near '='
 *      --> foo.lua:12:5
 *      |
 *   12 | local x =
 *      |         ^
 *
 * Multi-span reports (via LcDiag_Report) add 2 lines of context above and
 * below each span's primary line, secondary spans, and grouped notes/help/
 * hint diagnostics. Color is opt-in: LcDiag_ShouldColor() honors NO_COLOR,
 * CLICOLOR_FORCE, the caller-supplied color mode (--color=auto|always|never),
 * and -- on Windows -- probes GetConsoleMode/ENABLE_VIRTUAL_TERMINAL_PROCESSING
 * before emitting ANSI escapes. When color is disabled the output is plain
 * ASCII, safe for pipes and log files.
 */
#ifndef CLUA_COMPILER_DIAG_PRETTY_H
#define CLUA_COMPILER_DIAG_PRETTY_H

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum _LC_DIAG_COLOR_MODE {
    LCDIAG_COLOR_AUTO   = 0,  /* isatty + NO_COLOR / CLICOLOR_FORCE probes */
    LCDIAG_COLOR_ALWAYS = 1,  /* --color=always */
    LCDIAG_COLOR_NEVER  = 2   /* --color=never */
} LC_DIAG_COLOR_MODE_T;

/* Severity levels for the extended report. Mirrors rustc/zig -- the primary
 * diagnostic is one of {error, warning}, and each secondary "note" grouped
 * under it may itself be a {note, help, hint} (rustc collapses help under
 * note; we keep them distinct because zig and some linters distinguish
 * `help:` from `hint:`). */
typedef enum _LC_SEVERITY {
    LCSEV_ERROR   = 0,
    LCSEV_WARNING = 1,
    LCSEV_NOTE    = 2,
    LCSEV_HELP    = 3,
    LCSEV_HINT    = 4
} LcSeverity;

/* One highlighted range in a source file. col_start and col_end are 1-based
 * columns; col_end is inclusive of the last highlighted byte -- an empty
 * range (col_end < col_start) prints a single '^'. `label` may be NULL, in
 * which case only the caret is drawn. `is_primary` picks the caret glyph:
 * primary spans use '^' in the category color, secondary spans use '-' in
 * blue (matching rustc). */
typedef struct _LC_DIAG_SPAN {
    const char *file;
    int         line;
    int         col_start;
    int         col_end;
    const char *label;
    int         is_primary; /* bool; 1 for the primary span */
} LcDiagSpan;

/* A secondary diagnostic grouped under the primary. Same shape as the top-
 * level report but with its own severity + spans (and no nested notes). */
typedef struct _LC_DIAG_NOTE {
    LcSeverity        sev;
    const char       *msg;
    const LcDiagSpan *spans;
    int               nspans;
} LcDiagNote;

/* Set the process-wide color mode (default LCDIAG_COLOR_AUTO). Also enables
 * ENABLE_VIRTUAL_TERMINAL_PROCESSING on the current console when color is
 * requested/possible, so the ANSI escapes render as color rather than as
 * literal `ESC[1;31m` characters. Safe to call more than once. */
void LcDiag_SetColorMode( LC_DIAG_COLOR_MODE_T Mode );

/* Parse a --color=<mode> argument. Returns 1 with *Out set on success,
 * 0 for an unknown value (caller reports the error). */
int  LcDiag_ParseColorMode( const char *Value, LC_DIAG_COLOR_MODE_T *Out );

/* 1 if color should be emitted to Out under the current mode, 0 otherwise. */
int  LcDiag_ShouldColor( FILE *Out );

/* Emit one diagnostic in the clang/rustc shape. SourceLine may be NULL, in
 * which case the snippet + caret rows are omitted. `Category` is the free-form
 * category text ("error", "warning", "note"). Line/Col are 1-based.
 * Preserved verbatim for single-span callers -- this is the historical shim
 * whose stderr byte layout is asserted by existing tests. */
void LcDiag_PrintError( FILE       *Out,
                        const char *File,
                        int         Line,
                        int         Col,
                        const char *Category,
                        const char *Msg,
                        const char *SourceLine );

/* Emit a structured multi-span report with grouped notes. Reads the source
 * file(s) referenced by the spans (caching one slurp per file) to render
 * 2 context lines above and below each primary line. `code` may be NULL
 * (omitted), else it prints as `error[code]:`. `help` may be NULL, else it
 * appends a trailing `help: <text>` block. `notes` are printed in order,
 * each with its own header and spans.
 *
 * The line-number gutter auto-sizes to fit the largest line number in the
 * whole report (primary + notes). */
void LcDiag_Report( FILE             *Out,
                    LcSeverity        Sev,
                    const char       *Code,
                    const char       *Msg,
                    const LcDiagSpan *Spans,
                    int               NSpans,
                    const LcDiagNote *Notes,
                    int               NNotes,
                    const char       *Help );

#ifdef __cplusplus
}
#endif

#endif /* CLUA_COMPILER_DIAG_PRETTY_H */
