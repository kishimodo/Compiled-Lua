# CLua open TODOs (audited 2026-06-12)

Every `TODO`/stale marker in the tree was audited against what actually
shipped. Three buckets: real open work, deliberately deferred (with the
honest valuation from the optimizer status doc), and stale markers (work
done; comment outdated, cleaned where found).

## real open work (roughly priority-ordered)

1. ~~M4: builtin-package bundling for compiled exes.~~ DONE
   2026-06-12: the driver compiles every required builtin's source
   (located via `Paths_BuiltinPackagesRoot`: repo checkout, exe-relative,
   `dist\lib\packages`, `CLUA_HOME`) and preload-registers it like any user
   module; dist ships the package sources. `imgui` (needs a native archive)
   stays a loud compile error. Guarded by `tests/differential/aot_builtinpkg`
   at O0/O1 plus the CLI suite.
2. ~~M4: FFI in compiled exes.~~ DONE 2026-06-12: opt-in by scan.
   Programs referencing `ffi`/`bit` (require scan or the conservative
   constant scan, covering the `_G.ffi` idiom) get the `Clua_OpenFfi` anchor
   force-pulled via `-Wl,--undefined`; `aot_entry` weak-calls it (callback
   dispatch state included). FFI-free exes keep zero FFI bytes. Guarded by
   `tests/differential/aot_ffi` plus the compiled behavioral layer.
3. ~~M4: self-contained PE writer.~~ DONE 2026-06-13, now the
   default, gcc-free. The built-in COFF-to-PE64 linker
   (`clua/src/link/{coff_read,ar_read,pe_emit}.c`, `LcPe_Link`) links a
   runnable console PE with no external toolchain. It does the GNU-archive
   symbol-index fixpoint (first-definition-wins; explicit objects shadow
   archive members), COMDAT select-any dedup, weak externals (a weak
   undefined ref does not pull archives; a weak symbol with no def resolves
   to absolute 0/NULL), COMMON into .bss, all seven AMD64 relocs
   (ADDR64/32/32NB, REL32 + REL32_1..5, SECREL, SECTION), $-suffix
   grouped+sorted sections, `--gc-sections` dead-code elimination
   (mark/sweep to a fixpoint, KEEP-by-name for
   ctor/dtor/CRT/tls/pdata/xdata/pseudo-reloc lists), the MinGW CRT
   assembled from a sysroot snapshot (crt2/crtbegin/crtend plus the ucrt
   mixed archive: dlltool long-member imports synthesized per-DLL with the
   real export name from `.idata$6`, code sections force-routed to .text,
   TLS directory from `_tls_used`, `__ImageBase` synthesized), base relocs
   (DIR64) plus import directory plus IAT built from scratch. The default
   was flipped: `LuacLink_LinkProgram` resolves
   `--ld=gcc`/`--ld=internal` -> `CLUA_LD` -> internal-when-sysroot-present,
   falling back to gcc with a one-line note when the sysroot is absent. gcc
   is now optional (only `--ld=gcc`, `--shared-rt`, cold-tree entry
   compile). `rover.exe` builds via the internal default; `build-luac.bat`
   builds the sysroot before rover. Sysroot via
   `make -f build/Makefile.luac sysroot` -> `build/bin/sysroot` (and
   `dist/lib/sysroot`); discovered exe-relative. Escape hatch:
   `--no-gc-sections-internal`. Tests: `tests/unit/test_lc_pe_emit.c` plus
   the `--ld=internal` section in `tools/test-clua-cli.lua`. The entire
   suite passes under the new default (499/0), and again with
   `CLUA_LD=internal` forced. Size parity reached: a hello exe is 180,736 B
   (internal+gc) vs 181,248 B (gcc), section sizes within tens of bytes.
4. ~~lvm strip, the remainder.~~ DONE 2026-06-12: native dispatch
   happens directly in `ldo.c`'s `ccall` (hook-gated; the oracle path is
   untouched), so the `luaV_execute` entry hop is gone; debug-free programs
   already link `lvm_nointerp.o`.
5. ~~v1 JIT removal from the tree once the behavioral test layers run
   against compiled exes.~~ DONE 2026-06-12: the v1 JIT compiler
   (jit/codegen, codegen_ffi, emit_x64, regalloc) is gone; `jit/dispatch.c`
   is cache-only and `jit/runtime.c` (the `Rt_*` AOT runtime helpers) is
   lookup-only. clua-interp always interprets (`-i` is a no-op). The
   behavioral, differential, conformance and fuzz layers all run
   aotc-compiled exes against the interpreter oracle, which guards the
   shared `Rt_*` helpers directly.
6. ~~AOT-ERRBANNER-001 polish.~~ DONE 2026-06-12: `aot_entry.c`
   installs a traceback message handler under the entry call; uncaught
   errors now print the full `stack traceback:` like the oracle (only the
   banner prefix still differs, inherently).
7. ~~Shared `clua-rt.dll` option for ~20 to 30 KB per-program exes (runtime
   ships once). Real export-surface engineering; valuable for many-tool
   workspaces.~~ DONE 2026-06-12: `clua build --shared-rt` links against
   `clua-rt.dll` (full runtime + Lua core, no front-end, full interpreter;
   `--export-all-symbols` plus import lib, data hooks via auto-import
   pseudo-relocs; `protoinit_rt.o` stays per-exe). Hello-world ~30 KB.
   Static remains the default, byte-for-byte unchanged.
8. ~~`coff_write.c` per-function alignment.~~ DONE 2026-06-12: every
   function starts on a 16-byte boundary (0xCC padding), verified via the
   emitted symbol Values.
9. ~~`ir.c` arena allocation.~~ DONE 2026-06-12: chunked 64 KB bump
   arena owned by `LcModule`; nodes and grow-by-copy arrays live in it,
   `lc_module_free` drops the chunk chain with no per-node walk.

## deliberately deferred (status doc has the honest valuations)

- `lc_pass_mem2reg`/`lc_analyze_dominators`/`lc_analyze_liveness`/`lc_pass_dce`/
  `lc_pass_const_fold` are intentional no-ops: M0 is the faithful boxed
  baseline, and the M1/M2 wins (typeinfer elision, residency, ip_typeprop)
  were built on the memory-form IR without SSA. Build SSA only when a
  consumer needs it.
- `lc_pass_unbox_locals`/`devirt_local`/`raw_table`/`inline_small` (M1),
  `monomorphize`/`ip_devirt`/`dead_global` (M2): no measured surface. Table
  fastpaths already live in the `Rt_*` helpers; `CollectReachable` leaves
  no tree-unreachable functions.
- `lc_pass_escape`/`scalar_replace` (M3): slice 1 shipped 2026-06-13
  (v0.2.0-beta.6, `clua/src/opt/passes.c`).
  Intra-procedural: a `NEWTABLE` whose home register never escapes and is
  touched only by constant-key field ops, with no GC safepoint in its live
  range (the reserved above-`L->top` slots can't survive a call/GC), is
  replaced by plain stack slots. About 38x on an alloc-heavy struct-in-loop
  (per-iteration heap alloc plus `Rt_GetField`/`Rt_SetField` removed),
  checksums byte-identical. Validated: full suite green at O0 through O3
  plus ~300 adversarial repros (one back-edge GC-safety miscompile found
  and fixed). But current real-code surface is about zero: 0/86 candidates
  in rover, 0/182 in the conformance corpus fire. Real Lua tables escape,
  are called-around, or interleave field access with arithmetic. The
  mechanism is proven; broad surface is slice 2: interprocedural escape
  plus GC-safe slot placement (so a table whose live range crosses a call
  can fire). `barrier_elide` (M3): no surface, codegen emits no barriers
  (they live inside the runtime helpers).
- `lc_build_callgraph` stub: M2 ip_typeprop discovered call sites its own
  way; a general callgraph waits for a consumer (ip_devirt/dead_global).

## stale markers cleaned this audit

- `aot_entry.c` "TODO(M0+): VEH, coroutine fiber init, FFI open":
  coroutines done (fiber lib installed); VEH/FFI deliberately absent in AOT
  exes (see item 2 above). Header rewritten.
- `lift.c` "TODO(M1+): full opcode coverage": done long ago (all 83
  opcodes; `supported_ops.c` is the gate). Markers left in place are about
  the placeholder branch shape, not missing coverage.
- `pe_write.{c,h}` plus `protoinit_emit.{c,h}` skeletons: deleted
  (superseded by `coff_write.c` plus the LCPB blob pipeline).
- Vendored `lua-5.4/` TODOs are upstream's, not ours, out of scope.
