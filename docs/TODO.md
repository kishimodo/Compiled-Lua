# CLua — open TODOs (audited 2026-06-12)

Every `TODO`/stale marker in the tree was audited against what actually
shipped. Three buckets: **real open work**, **deliberately deferred** (with
the honest valuation from the optimizer status doc), and **stale markers**
(work done; comment outdated — cleaned where found).

## Real open work (roughly priority-ordered)

1. **M4: builtin-package bundling for compiled exes.** The ~195 in-tree
   packages don't link into AOT programs; `require "json"` is a loud compile
   error today (rover-installed packages bundle fine). The v1 pipeline's
   tree-shaken `_pkg_gen.o` link (`clua/src/compiler/pe_link.c`) is the
   reference implementation.
2. **M4: FFI in compiled exes.** `aot_entry.c` never opens the FFI (saves
   ~25 KB and keeps exes single-threaded). FFI-using packages are host-only
   until an opt-in (closed-world `require "ffi"`-scan anchored) init exists.
3. **M4: self-contained PE writer** — drop the MinGW gcc/ld dependency, the
   one external step left in a user build (~170 ms of the ~190 ms total).
4. **lvm strip, the remainder:** `luaV_execute` is now only a thin dispatch
   entry, and debug-free programs already link `lvm_nointerp.o`; direct
   native dispatch at the `luaD_call` boundary would remove the entry hop
   entirely (perf nicety, small).
5. **v1 JIT removal from the tree** once the behavioral test layers run
   against compiled exes (gated on item 1; the JIT-vs-interpreter
   differential still guards the shared `Rt_*` helpers until then).
6. **AOT-ERRBANNER-001 polish:** a traceback-printing message handler in
   `aot_entry.c` would narrow the uncaught-error divergence vs the oracle.
7. ~~**Shared `clua-rt.dll` option** for ~20–30 KB per-program exes (runtime
   ships once). Real export-surface engineering; valuable for many-tool
   workspaces.~~ **DONE 2026-06-12:** `clua build --shared-rt` links against
   `clua-rt.dll` (full runtime + Lua core, no front-end, full interpreter;
   `--export-all-symbols` + import lib, data hooks via auto-import
   pseudo-relocs; `protoinit_rt.o` stays per-exe). Hello-world ~30 KB.
   Static remains the default, byte-for-byte unchanged.
8. `coff_write.c`: function `.text` entries are concatenated tight (16-byte
   section alignment only); per-function alignment is a micro-polish noted
   in its header.
9. `ir.c` TODO(M0): arena-allocate IR objects (alloc-perf nicety; the
   compiler is link-bound today).

## Deliberately deferred (status doc has the honest valuations)

- `lc_pass_mem2reg`/`lc_analyze_dominators`/`lc_analyze_liveness`/`lc_pass_dce`/
  `lc_pass_const_fold` are intentional no-ops: M0 is the faithful boxed
  baseline, and the M1/M2 wins (typeinfer elision, residency, ip_typeprop)
  were built on the memory-form IR without SSA. Build SSA only when a
  consumer needs it.
- `lc_pass_unbox_locals`/`devirt_local`/`raw_table`/`inline_small` (M1),
  `monomorphize`/`ip_devirt`/`dead_global` (M2): no measured surface —
  table fastpaths already live in the `Rt_*` helpers; `CollectReachable`
  leaves no tree-unreachable functions.
- `lc_pass_escape`/`scalar_replace` (M3): workload-gated (build against a
  concrete table-as-struct hot loop); `barrier_elide` (M3): NO SURFACE —
  codegen emits no barriers (they live inside the runtime helpers).
- `lc_build_callgraph` stub: M2 ip_typeprop discovered call sites its own
  way; a general callgraph waits for a consumer (ip_devirt/dead_global).

## Stale markers cleaned this audit

- `aot_entry.c` "TODO(M0+): VEH, coroutine fiber init, FFI open" —
  coroutines DONE (fiber lib installed); VEH/FFI deliberately absent in AOT
  exes (see item 2 above). Header rewritten.
- `lift.c` "TODO(M1+): full opcode coverage" — DONE long ago (all 83
  opcodes; `supported_ops.c` is the gate). Markers left in place are about
  the *placeholder branch* shape, not missing coverage.
- `pe_write.{c,h}` + `protoinit_emit.{c,h}` skeletons — deleted (superseded
  by `coff_write.c` + the LCPB blob pipeline).
- Vendored `lua-5.4/` TODOs are upstream's, not ours — out of scope.
