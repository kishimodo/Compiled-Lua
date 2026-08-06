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

typedef struct LcDriverOptions {
  const char  *input;        /* root .lua file                              */
  const char  *output;       /* .exe / .dll path                            */
  int          opt_level;    /* -O0..-O3                                     */
  bool         emit_dll;
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
  const char **force_pkgs;   /* -L forced packages                          */
  int          nforce_pkgs;
} LcDriverOptions;

/* Returns process exit code. */
int lc_drive(const LcDriverOptions *opt);

#endif /* LUAC_AOTC_H */
