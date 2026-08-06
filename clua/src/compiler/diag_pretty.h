/* diag_pretty.h -- structured file:line:col diagnostic formatter.
 *
 * Renders diagnostics in the clang/rustc shape:
 *
 *   error[E001]: syntax error near '='
 *      --> foo.lua:12:5
 *      |
 *   12 | local x =
 *      |         ^
 *
 * Color is opt-in: LcDiag_ShouldColor() honors NO_COLOR, CLICOLOR_FORCE, the
 * caller-supplied color mode (--color=auto|always|never), and — on Windows —
 * probes GetConsoleMode/ENABLE_VIRTUAL_TERMINAL_PROCESSING before emitting
 * ANSI escapes. When color is disabled the output is plain ASCII, safe for
 * pipes and log files.
 */
#ifndef CLUA_COMPILER_DIAG_PRETTY_H
#define CLUA_COMPILER_DIAG_PRETTY_H

#include <stdio.h>

typedef enum _LC_DIAG_COLOR_MODE {
    LCDIAG_COLOR_AUTO   = 0,  /* isatty + NO_COLOR / CLICOLOR_FORCE probes */
    LCDIAG_COLOR_ALWAYS = 1,  /* --color=always */
    LCDIAG_COLOR_NEVER  = 2   /* --color=never */
} LC_DIAG_COLOR_MODE_T;

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
 * category text ("error", "warning", "note"). Line/Col are 1-based. */
void LcDiag_PrintError( FILE       *Out,
                        const char *File,
                        int         Line,
                        int         Col,
                        const char *Category,
                        const char *Msg,
                        const char *SourceLine );

#endif /* CLUA_COMPILER_DIAG_PRETTY_H */
