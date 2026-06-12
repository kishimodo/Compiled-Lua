/*!
 * @brief
 *  Static require walker. Compiles the entry module, scans the bytecode
 *  for `require("...")` calls with constant string arguments, recursively
 *  resolves each dependency. Dynamic `require(var)` calls emit a warning.
 */

#ifndef LUAVM_COMPILER_RESOLVE_H
#define LUAVM_COMPILER_RESOLVE_H

#include <stddef.h>
#include "compiler/paths.h"
#include "compiler/diag.h"

typedef struct _RESOLVED_MODULE {
    char          *Name;       /* malloc'd dotted module name */
    char          *Path;       /* malloc'd resolved file path */
    unsigned char *Bytes;      /* malloc'd compiled bytecode */
    size_t         BytesLen;
} RESOLVED_MODULE_T, *PRESOLVED_MODULE_T;

typedef struct _RESOLVE_RESULT {
    PRESOLVED_MODULE_T Modules; /* malloc'd array, Modules[0] = entry */
    size_t             Count;
    size_t             WarnCount;
    /* Builtin-package flags. Their bytes live in runtime archives but
       aren't added to Modules; the compiler still tracks them so it
       can (a) pull in matching native archives like imgui.a and
       (b) emit packages_refs.c per build naming only the ones the
       program actually requires (binary tree-shaking -- see
       docs/packages.md). */
    int                RequiresImgui;
    /* Required builtin packages: dotted-name strings, malloc'd.
       Populated by Resolve_Walk in the order they were first seen. */
    char             **BuiltinPackages;
    size_t             BuiltinPackageCount;
} RESOLVE_RESULT_T, *PRESOLVE_RESULT_T;

typedef struct _RESOLVE_OPTS {
    PPATHS_OPTS_T PathsOpts;
    int           Strip;        /* --strip: drop debug info from final bytecode */
    /* -L/--link: package/module names to bundle even though the static scan
       can't see them (dynamic require(var), conditional require). Each is
       injected into the resolve worklists exactly as a discovered require. */
    const char  **ForceLink;
    size_t        ForceLinkCount;
    /* Diagnostics options for rich compile-error formatting (color, etc.).
       NULL falls back to a plain located error. */
    const DIAG_OPTS_T *Diag;
} RESOLVE_OPTS_T, *PRESOLVE_OPTS_T;

int Resolve_Walk( const char *EntryPath, PRESOLVE_OPTS_T Opts, PRESOLVE_RESULT_T Out );

void Resolve_FreeResult( PRESOLVE_RESULT_T R );

#endif /* LUAVM_COMPILER_RESOLVE_H */
