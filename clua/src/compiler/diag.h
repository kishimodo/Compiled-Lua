/* diag.h -- compiler diagnostics: gcc/clang-style error formatting (file:line:col
 * + source line + caret) and an advisory lint pass (warnings/info), so broken
 * code fails to compile with a clear, located message and questionable-but-valid
 * code compiles with warnings. */
#ifndef CLUA_COMPILER_DIAG_H
#define CLUA_COMPILER_DIAG_H

#include <stddef.h>

typedef struct _DIAG_OPTS {
    int Warnings;          /* run the lint pass at all (default 1; -w turns off) */
    int WarningsAsErrors;  /* --Werror: a lint finding fails the build           */
    int Color;             /* legacy; the current printer routes color through
                              LcDiag_SetColorMode / LcDiag_ShouldColor.          */
} DIAG_OPTS_T, *PDIAG_OPTS_T;

/* Print a gcc/clang-style diagnostic for a Lua loader/compile error. RawLuaErr
 * is the message from lua_tostring after a failed luaL_loadfile/loadbuffer
 * (e.g. "main.lua:5: '=' expected near 'foo'"). SourcePath is the real .lua
 * file (used for the snippet). PrefixLines is the number of newline-terminated
 * lines prepended before compilation (pass 0 for normal use).
 * Writes to stderr. */
void Diag_PrintCompileError( const char *SourcePath, const char *RawLuaErr,
                             int PrefixLines, const DIAG_OPTS_T *Opts );

/* Run the advisory lint pass on a source file and print warning/info (and, under
 * --Werror, error) diagnostics. LintSource is the lint package's Lua source, or
 * NULL to skip (e.g. when it couldn't be located -- warnings are then simply
 * unavailable; errors are unaffected). Returns the total number of findings
 * emitted; the caller fails the build only when --Werror and this is > 0. */
int Diag_RunLint( const char *SourcePath, const char *LintSource,
                  const DIAG_OPTS_T *Opts );

/* Read a whole file into a malloc'd NUL-terminated buffer (caller frees), or
 * NULL on failure. Helper for loading the lint source / source snippets. */
char *Diag_SlurpFile( const char *Path, size_t *OutLen );

#endif /* CLUA_COMPILER_DIAG_H */
