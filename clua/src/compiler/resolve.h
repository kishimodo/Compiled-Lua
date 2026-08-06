/*!
 * @brief
 *  Static require walker. Compiles the entry module, scans the bytecode
 *  for `require("...")` calls with constant string arguments, recursively
 *  resolves each dependency. Dynamic `require(var)` calls emit a warning.
 */

#ifndef CLUA_COMPILER_RESOLVE_H
#define CLUA_COMPILER_RESOLVE_H

#include <stddef.h>
#include "compiler/paths.h"
#include "compiler/diag.h"

typedef struct _RESOLVED_MODULE {
    char          *Name;       /* malloc'd dotted module name */
    char          *Path;       /* malloc'd resolved file path */
    unsigned char *Bytes;      /* malloc'd compiled bytecode */
    size_t         BytesLen;
} RESOLVED_MODULE_T, *PRESOLVED_MODULE_T;

/* One DLL export discovered by the module-scope scan. `Name` is the export
   name (the key in `_exports = { name = fn, ... }`); the compiler pipeline
   resolves it to a function body downstream. Malloc'd, freed by
   Resolve_FreeResult. */
typedef struct _RESOLVED_EXPORT {
    char *Name;
} RESOLVED_EXPORT_T, *PRESOLVED_EXPORT_T;

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
    /* The program references the runtime-provided `ffi`/`bit` globals: the
       AOT driver links the FFI initialization anchor so compiled exes open
       the library at startup (v1 hosts always open it). */
    int                RequiresFfi;
    /* Required builtin packages: dotted-name strings, malloc'd.
       Populated by Resolve_Walk in the order they were first seen. */
    char             **BuiltinPackages;
    size_t             BuiltinPackageCount;
    /* DLL exports discovered by the module-scope `_exports = {...}` scan on
       the entry module. Populated whether or not the driver requested a DLL:
       an exe build simply ignores them, and a `_exports` table in an exe is
       inert (nothing walks it at run time). */
    PRESOLVED_EXPORT_T Exports;
    size_t             ExportCount;
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

/* AOT driver only: compile every BuiltinPackages[] source (located under
   Paths_BuiltinPackagesRoot) and append each as an ordinary module so the
   backend AOT-compiles + preload-registers it like any user module. v1
   compiler.exe keeps its archive-based path and never calls this. Returns 0
   with a message in Err when a package source cannot be found/compiled. */
int Resolve_AppendBuiltinModules( PRESOLVE_RESULT_T Out, PRESOLVE_OPTS_T Opts,
                                  char *Err, size_t ErrLen );

void Resolve_FreeResult( PRESOLVE_RESULT_T R );

#endif /* CLUA_COMPILER_RESOLVE_H */
