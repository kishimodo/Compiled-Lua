/*
** compdb.h -- compile_commands.json emitter for the CLua driver.
**
** clang tooling (clangd, clang-tidy, run-clang-tidy, cquery, ccls) and editors
** (VS Code C/C++, Neovim's LSP config, JetBrains CLion) all read a
** compile_commands.json file rooted at the workspace: an array of
** {directory, file, arguments} objects, one per translation unit compiled.
** For a Lua source-to-native compiler the analogue is one entry per `clua
** build <input>` invocation, describing the input .lua and the exact argv the
** user passed. Emitting it lets editors offer jump-to-definition, hover
** documentation and warnings for CLua-built sources without a manual
** integration step.
**
** Two modes:
**   --emit-compdb=<path>          overwrite: single-element array
**   --emit-compdb-append=<path>   append: parse the existing array (if any),
**                                 append the new entry, rewrite atomically.
**
** The append mode is what a build system uses to accumulate one entry per
** target across many `clua build` invocations without a wrapper script.
*/
#ifndef LUAC_DRIVER_COMPDB_H
#define LUAC_DRIVER_COMPDB_H

#ifdef __cplusplus
extern "C" {
#endif

/* Write / append a compile_commands.json entry describing the current
** invocation. Returns 0 on success, non-zero on I/O or OOM failure.
**
**   path    destination file. Overwritten (append==0) or read+rewritten
**           (append!=0). The parent directory must exist; this function does
**           not mkdir.
**   argc    argv length (>= 1). argv[0] is preserved verbatim in "arguments"
**           so the entry records exactly how the tool was invoked.
**   argv    argv pointer array; every element is JSON-escaped.
**   cwd     absolute path of the current working directory (goes into
**           "directory"). If NULL the entry omits "directory", which no
**           consumer accepts -- callers should always supply this.
**   input   input source path (goes into "file"). If NULL the entry uses
**           "" -- again, no consumer will accept that, but the field is
**           preserved for the error path in the driver.
**   append  0 to overwrite (single-entry array), non-zero to append to an
**           existing array.
*/
int LcCompdb_Write( const char        *path,
                    int                argc,
                    const char *const *argv,
                    const char        *cwd,
                    const char        *input,
                    int                append );

#ifdef __cplusplus
}
#endif

#endif /* LUAC_DRIVER_COMPDB_H */
