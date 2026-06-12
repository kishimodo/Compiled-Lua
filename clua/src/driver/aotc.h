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
  const char **force_pkgs;   /* -L forced packages                          */
  int          nforce_pkgs;
} LcDriverOptions;

/* Returns process exit code. */
int lc_drive(const LcDriverOptions *opt);

#endif /* LUAC_AOTC_H */
