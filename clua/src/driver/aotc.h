/*
** aotc.h — LuaC compiler driver (the `aotc.exe` entry).
**
** Orchestrates the full pipeline. This is the AOT analogue of v1's
** src/compiler/main.c, but instead of "compile to bytecode + embed blob" it is
** "compile to native + link a normal PE".
*/
#ifndef LUAC_AOTC_H
#define LUAC_AOTC_H

#include <stdbool.h>
#include <stddef.h>   /* NULL, for lc_parse_opt_level below */

#include "../compiler/warn_unused.h"   /* LcWarnFlags: -W / -Wall / -Werror  */

/* Parse a `-O<n>` argument strictly. Returns false for anything not supported
** instead of letting it become a level nobody asked for.
**
** Both drivers used `atoi( arg + 2 )`, which silently maps `-Ofast`, `-Os` and
** `-Oz` to 0 -- so a user asking for a size-optimised build got the faithful
** boxed baseline and no warning -- and maps `-O9` to "every level enabled" and
** `-O-1` to a negative level. A wrong -O silently changes the generated code,
** which is exactly the class of thing that must not be guessed at.
**
** Adding a level (`-Os`/`-Oz`, roadmap row 5) means extending BOTH this table
** and the help text in clua_main.c. */
static inline bool lc_parse_opt_level( const char *arg, int *out ) {
  if ( arg == NULL || arg[0] != '-' || arg[1] != 'O' ) return false;
  if ( arg[2] == '\0' ) { *out = 1; return true; }   /* bare -O == -O1 */
  if ( arg[3] != '\0' ) return false;                /* -O2x, -Ofast   */
  if ( arg[2] < '0' || arg[2] > '3' ) return false;  /* -O4, -Os, -Oz  */
  *out = arg[2] - '0';
  return true;
}

/* --emit=<mode> selector. Diagnostic dumps that the driver writes to a
** file or stdout. LC_EMIT_NONE (0) means the driver behaves exactly as
** before -- no dump, ordinary binary output.
**
** The mode is orthogonal to the binary output. Concrete semantics:
**   `clua build foo.lua --emit=X`                 dump to stdout, no binary
**   `clua build foo.lua --emit=X -o foo.exe`      dump to stdout AND foo.exe
**   `clua build foo.lua --emit=X --emit-only -o foo.txt`
**                                                  dump to foo.txt, no binary
**   `clua build foo.lua --emit=X --emit-only -o -` dump to stdout, no binary
** With --emit-only the -o path is repurposed as the dump destination.
*/
typedef enum {
  LC_EMIT_NONE = 0,
  LC_EMIT_BYTECODE,   /* raw Lua 5.4 bytecode per Proto (like luac -l)     */
  LC_EMIT_IR,         /* the LcModule after the optimizer, before codegen  */
  LC_EMIT_ASM,        /* emitted x64 machine code as an assembly listing   */
  LC_EMIT_AST         /* front-end Proto tree (types + nesting) as a tree  */
} LcEmitMode;

/* --strip=<mode> selector. Controls how aggressively the internal linker
** removes debug/symbol information from the emitted PE:
**   none  -- keep every symbol; grows the exe, useful for debugging
**   debug -- drop the .clualn / .debug* sections (what happens without -g)
**   all   -- drop everything the loader does not need (default when -g is
**            off; a bare `-g` build promotes the default to `none` so the
**            requested debug section is not immediately stripped again)
** Byte-identity of a default build is preserved because the default (`all`)
** matches the behavior every previous build already produced. Callers that
** want to distinguish "user asked for --strip=all" from "driver defaulted
** to all" test `strip_mode_explicit` alongside `strip_mode`. */
typedef enum {
  LC_STRIP_ALL   = 0,   /* default; drop debug info + COFF symbol table    */
  LC_STRIP_DEBUG = 1,   /* drop .clualn / .debug* only                     */
  LC_STRIP_NONE  = 2    /* keep every symbol                                */
} LcStripMode;

/* --output=<kind> selector. exe (default) matches every existing test; dll
** flips IMAGE_FILE_DLL, emits an export directory, and pulls aot_entry_dll.o
** instead of aot_entry.o. `obj` and `lib` short-circuit the pipeline BEFORE
** linking: `obj` publishes the codegen COFF as the final artifact, and `lib`
** wraps that same COFF in a single-member GNU-form ar archive. Neither pulls
** aot_entry / the runtime, and neither is affected by --shared-rt (there is no
** link step to affect). Add more kinds (e.g. sys, driver) by extending the enum
** plus the two switches in pe_link_v2.c / pe_emit.c that consume it. */
typedef enum LcOutputKind {
  LC_OUTPUT_EXE = 0,
  LC_OUTPUT_DLL = 1,
  LC_OUTPUT_OBJ = 2,
  LC_OUTPUT_LIB = 3
} LcOutputKind;

typedef struct LcDriverOptions {
  const char  *input;        /* root .lua file                              */
  const char  *output;       /* .exe / .dll path                            */
  int          opt_level;    /* -O0..-O3                                     */
  bool         emit_dll;     /* legacy shim: set by --dll / --output=dll /
                                -shared for callers that still branch on it.
                                New code reads output_kind.                   */
  int          output_kind;  /* LC_OUTPUT_EXE (default) or LC_OUTPUT_DLL     */
  bool         keep_ir;      /* dump IR for inspection (-S style)           */
  bool         check_only;   /* stop after resolve + closed-world + op scan */
  bool         keep_temps;   /* keep the intermediate .o (default: delete)  */
  bool         shared_rt;    /* link against clua-rt.dll instead of the
                                static archives (--shared-rt; small exe,
                                needs the DLL beside it at run time)       */
  int          ld_internal;  /* link with the built-in COFF->PE linker
                                instead of gcc/ld: -1 = unset (env decides),
                                0 = force gcc, 1 = force internal           */
  bool         no_gc_sections; /* --no-gc-sections-internal: disable the
                                built-in linker's dead-code elimination
                                (debug escape; default off = gc enabled)    */
  int          jobs;         /* -j <N>: parallel per-function codegen workers.
                                0 = decide from env CLUA_JOBS then CPU count,
                                1 = sequential (no threads), N>1 = pool of N.
                                Byte-identity across values of jobs is a hard
                                gate (tools/test-parallel-codegen.lua).       */
  const char  *emit_def_path;/* --emit-def=<path>: write a .DEF module-
                                definition file listing the DLL's exports
                                next to the .dll. NULL = auto-derive
                                (<dll basename>.def beside the DLL) when
                                emit_dll is true; otherwise no .def is
                                written. Ignored for .exe builds. Both
                                MSVC (link /def) and MinGW dlltool consume
                                the .def to produce the matching .lib /
                                .dll.a import archive.                     */
  const char **force_pkgs;   /* -L forced packages                          */
  int          nforce_pkgs;
  LcEmitMode   emit_mode;    /* --emit=bytecode|ir|asm; LC_EMIT_NONE = off  */
  bool         emit_only;    /* --emit-only: suppress binary even if -o set */
  const char  *compdb_path;  /* --emit-compdb=<path> / --emit-compdb-append=<path>:
                                write (or extend) a compile_commands.json
                                file. clangd / VS Code / ccls read it. See
                                clua/src/driver/compdb.h.                     */
  bool         compdb_append;/* 0 = --emit-compdb (overwrite), 1 = append.   */
  int          drv_argc;     /* argv verbatim into the compdb arguments      */
  const char *const *drv_argv;
  bool         verbose;      /* -v / --verbose: per-phase wall-clock timings
                                on stderr at the end of the build. Off = zero
                                overhead (QPC only runs when set).            */
  LcWarnFlags  warn;         /* -W / -Wno- / -Wall / -Werror[=cat]. When a
                                category is set, the driver runs the matching
                                scanner after the front end; a promoted hit
                                becomes a hard error.                        */
  bool         debug_line_info; /* -g / --debug: emit a .clualn (native-off ->
                                Lua source line) section for post-mortem
                                tooling. Off by default; adds bytes.         */
  bool         no_cache;     /* --no-cache / CLUA_NO_CACHE=1: disable the per-
                                function compilation cache (both read + write)
                                for this invocation. Default is caching on.   */
  const char  *cache_dir;    /* --cache-dir=<path>: override the default cache
                                dir (%LOCALAPPDATA%\clua\cache or
                                $XDG_CACHE_HOME/clua). NULL = use the default. */
  const char  *depfile_path; /* --emit-depfile=<path> / -MD: write a make-
                                style dependency file listing every module
                                the resolver walked. NULL = no depfile. */
  int          strip_mode;   /* --strip=none|debug|all: LcStripMode. Default
                                is LC_STRIP_ALL, preserving byte-identity of
                                every existing build. */
  bool         strip_mode_explicit; /* true iff the user passed --strip=<x>.
                                When false, the driver quietly upgrades the
                                default to STRIP_NONE if -g / debug_line_info
                                was requested, so the emitted .clualn is not
                                immediately stripped again. */

  /* --------------------------------------------------------------------- */
  /*  .rsrc section content: VS_VERSION_INFO, RT_MANIFEST, RT_GROUP_ICON.  */
  /*                                                                       */
  /*  When any of these is non-default, the internal linker emits an       */
  /*  .rsrc section carrying the requested resources so Windows populates  */
  /*  the file's "Details" tab, applies the manifest at load, and shows a  */
  /*  custom icon in Explorer. Defaults keep the pre-.rsrc byte-shape:     */
  /*  emit_versioninfo / emit_manifest default to TRUE for exe builds      */
  /*  (see main.c / clua_main.c), but the caller-side driver structs are   */
  /*  zero-initialised, so an explicit `--no-versioninfo` / `--no-manifest`*/
  /*  is not needed to keep old byte layouts in the general case.          */
  bool         emit_versioninfo;    /* embed VS_VERSION_INFO                   */
  bool         emit_manifest;       /* embed RT_MANIFEST                       */
  const char  *product_name;        /* --product-name=<str>                    */
  const char  *product_version;     /* --product-version=<str>                 */
  const char  *file_description;    /* --file-description=<str>                */
  const char  *company_name;        /* --company-name=<str>                    */
  const char  *legal_copyright;     /* --copyright=<str>                       */
  const char  *manifest_path;       /* --manifest=<path>: user-supplied XML    */
  const char  *icon_path;           /* --icon=<path>: .ico embedded            */
} LcDriverOptions;

/* Returns process exit code. */
int lc_drive(const LcDriverOptions *opt);

#endif /* LUAC_AOTC_H */
