# CLua — open TODOs (audited 2026-06-12)

Every `TODO`/stale marker in the tree was audited against what actually
shipped. Three buckets: **real open work**, **deliberately deferred** (with
the honest valuation from the optimizer status doc), and **stale markers**
(work done; comment outdated — cleaned where found).

## Real open work (roughly priority-ordered)

1. ~~**M4: builtin-package bundling for compiled exes.**~~ **DONE
   2026-06-12:** the driver compiles every required builtin's source
   (located via `Paths_BuiltinPackagesRoot`: repo checkout, exe-relative,
   `dist\lib\packages`, `CLUA_HOME`) and preload-registers it like any user
   module; dist ships the package sources. `imgui` (needs a native archive)
   stays a loud compile error. Guarded by `tests/differential/aot_builtinpkg`
   at O0/O1 + the CLI suite.
2. ~~**M4: FFI in compiled exes.**~~ **DONE 2026-06-12:** opt-in by scan —
   programs referencing `ffi`/`bit` (require scan or the conservative
   constant scan, covering the `_G.ffi` idiom) get the `Clua_OpenFfi` anchor
   force-pulled via `-Wl,--undefined`; `aot_entry` weak-calls it (callback
   dispatch state included). FFI-free exes keep zero FFI bytes. Guarded by
   `tests/differential/aot_ffi` + the compiled behavioral layer.
3. **M4: self-contained PE writer — THE ONE REMAINING ITEM.** Drop the
   MinGW gcc/ld dependency (~170 ms of a ~190 ms build, and the only
   external tool a user machine needs). DESIGNED: `clua/src/link/pe_emit.h`
   specifies the full COFF→PE64 link semantics required (archive index
   fixpoint with first-definition-wins, COMDAT, weak externals, COMMON,
   the seven AMD64 reloc types, $-sorted grouped sections with ld-script
   synthesis for the MinGW CRT, long + short import members, .pdata sort,
   TLS, base relocs). Implementation plan: `LcPe_Link` behind
   `--ld=internal` / `CLUA_LD`, sysroot snapshot of the CRT pieces shipped
   in `dist\lib\sysroot`, default flips only when the full suite passes
   with the internal linker forced.
4. ~~**lvm strip, the remainder.**~~ **DONE 2026-06-12:** native dispatch
   happens directly in `ldo.c`'s `ccall` (hook-gated; the oracle path is
   untouched), so the `luaV_execute` entry hop is gone; debug-free programs
   already link `lvm_nointerp.o`.
5. ~~**v1 JIT removal from the tree** once the behavioral test layers run
   against compiled exes.~~ **DONE 2026-06-12:** the v1 JIT compiler
   (jit/codegen, codegen_ffi, emit_x64, regalloc) is gone; `jit/dispatch.c`
   is cache-only and `jit/runtime.c` (the `Rt_*` AOT runtime helpers) is
   lookup-only. clua-interp always interprets (`-i` is a no-op). The behavioral,
   differential, conformance and fuzz layers all run aotc-compiled exes
   against the interpreter oracle, which guards the shared `Rt_*` helpers
   directly.
6. ~~**AOT-ERRBANNER-001 polish.**~~ **DONE 2026-06-12:** `aot_entry.c`
   installs a traceback message handler under the entry call; uncaught
   errors now print the full `stack traceback:` like the oracle (only the
   banner prefix still differs, inherently).
7. ~~**Shared `clua-rt.dll` option** for ~20–30 KB per-program exes (runtime
   ships once). Real export-surface engineering; valuable for many-tool
   workspaces.~~ **DONE 2026-06-12:** `clua build --shared-rt` links against
   `clua-rt.dll` (full runtime + Lua core, no front-end, full interpreter;
   `--export-all-symbols` + import lib, data hooks via auto-import
   pseudo-relocs; `protoinit_rt.o` stays per-exe). Hello-world ~30 KB.
   Static remains the default, byte-for-byte unchanged.
8. ~~`coff_write.c` per-function alignment.~~ **DONE 2026-06-12:** every
   function starts on a 16-byte boundary (0xCC padding), verified via the
   emitted symbol Values.
9. ~~`ir.c` arena allocation.~~ **DONE 2026-06-12:** chunked 64 KB bump
   arena owned by `LcModule`; nodes and grow-by-copy arrays live in it,
   `lc_module_free` drops the chunk chain with no per-node walk.

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
