/*
** main.c — aotc.exe entry. The AOT analogue of v1 src/compiler/main.c.
** See aotc.h and ../../PROMPT.md §5 (pipeline). STUB: wire for Milestone M0.
**
** Pipeline:  front-end + resolve (reused)  ->  lift  ->  optimize  ->  codegen  ->  link
*/
#include "aotc.h"

#include "../ir/lift.h"
#include "../ir/ir.h"
#include "../opt/passes.h"
#include "../codegen/codegen.h"
#include "../link/pe_write.h"

#include <stdio.h>
#include <string.h>

/* Reused v1 front-end (copy-as-is from src/compiler/). Declared here loosely;
** include the real resolve.h / lua_compile.h when wiring M0. */
/* #include "../compiler/resolve.h" */
/* #include "../compiler/lua_compile.h" */

int lc_drive(const LcDriverOptions *opt) {
  if (!opt || !opt->input || !opt->output) return 2;

  /* 1. CLOSED-WORLD DISCOVERY (reused).
  **    RESOLVE_RESULT_T r; Resolve_Walk(opt->input, &resolveOpts, &r);
  **    Reject dynamic require()/load() here: closed world required.
  **    Build the reachable Proto set by lundump-ing each r.Modules[i].Bytes.
  */

  /* 2. LIFT to IR.
  **    LcModule *m = lc_lift_program(entryProto, reachable, nreachable);
  */
  LcModule *m = NULL; /* TODO(M0) */

  /* 3. OPTIMIZE. */
  LcPassConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.opt_level       = opt->opt_level;
  cfg.interprocedural = (opt->opt_level >= 2);
  cfg.escape_analysis = (opt->opt_level >= 3);
  cfg.verify_each     = true;
  if (m && !lc_optimize(m, &cfg)) { fprintf(stderr, "aotc: optimizer failed\n"); return 1; }

  /* 4. CODEGEN. */
  LcCodeModule *cm = m ? lc_codegen(m) : NULL;

  /* 5. LINK to a standard PE. */
  LcLinkOptions link;
  memset(&link, 0, sizeof(link));
  link.kind        = opt->emit_dll ? LC_OUT_DLL : LC_OUT_EXE;
  link.out_path    = opt->output;
  link.image_base  = 0x140000000ULL;
  link.emit_reloc  = true;
  link.runtime_lib = "build/runtime-embedded.a";

  char err[256] = {0};
  if (!cm || !lc_write_pe(cm, &link, err, sizeof(err))) {
    fprintf(stderr, "aotc: link failed: %s\n", err[0] ? err : "(not implemented)");
    lc_codemodule_free(cm);
    lc_module_free(m);
    return 1;
  }

  lc_codemodule_free(cm);
  lc_module_free(m);
  return 0;
}

#ifdef LUAC_AOTC_STANDALONE
int main(int argc, char **argv) {
  /* TODO(M0): parse argv -> LcDriverOptions (input, -o output, -O<n>, --dll, -L pkg). */
  (void)argc; (void)argv;
  LcDriverOptions opt;
  memset(&opt, 0, sizeof(opt));
  fprintf(stderr, "aotc (LuaC): not yet implemented — see PROMPT.md\n");
  return lc_drive(&opt);
}
#endif
