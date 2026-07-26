# Second-reviewer challenge pass — 2026-07-25 (read-only)

A challenge pass over
[`2026-07-25-concurrency-size-stability-audit.md`](2026-07-25-concurrency-size-stability-audit.md),
performed by an independent reviewer whose job was to disagree with it. Every
item below was re-verified against source directly, not accepted from a
delegated search. Line numbers are as of `7f02bd3` and drift with later commits;
treat them as starting points, not addresses.

Items marked *(fixed)* were repaired on `codex/concurrency-size-stability`; see
[`../roadmaps/concurrency-size-stability.md`](../roadmaps/concurrency-size-stability.md)
for current status.

## P0 confirmed defects

1. **`OP_SELF` drops the `k` bit, a miscompile.** *(fixed)*
   `ir/lift.c:367-372` falls into `default:`; `codegen/codegen.c:1525` and
   `jit/runtime.c:1484` use `p->k[C]` unconditionally. Lua 5.4's `codeABRK`
   emits `k=0` with `C` as a *register* when the method-name constant index
   exceeds `MAXARG_C` (255). The fix mirrors the `Ck` encoding at
   `lift.c:304-312` plus `DecodeCk`, which was already correct in `Rt_SetTabUp`.
   No test in the tree had more than 256 constants in one function.
2. **`rover.lock`'s `version` field is a path-traversal, hence code-execution,
   primitive.** *(fixed)* `compiler/paths.c:151-159` accepted any bytes between
   quotes; `FormatVersionedInitPath` `memcpy`s them into a require path, and
   `runtime/clua_interp_main.c:299-304` does the same and then `loadfile()`s the
   result. The value was validated on write but never on read. Separately,
   `paths.c:149`'s `strstr(P, "version")` was unbounded by the entry's braces.
3. **The test harness could report a false green.** *(fixed)*
   `tools/run-tests.lua:131` turned a crash or timeout into a SKIP whenever any
   skip marker had been printed, and `:141-144` counted PASS with no output and
   no marker at all. The stale-`lift.o` empty-binary failure that `CLAUDE.md`
   warns about would have read as all-PASS on the compiled layer.

## P1 confirmed

- **`-O2`/`-O3` are no-ops** (`opt/passes.c:574-594`, `:200-206`), yet `clua.exe`
  defaults to `-O2` and advertises interprocedural work that does not run.
- **The `-O1` size cost is codegen, not the optimizer.** It comes from the
  `g_lc_opt_level >= 1` multi-arm fastpaths in `codegen.c` (~+83 bytes per
  *unproven* arithmetic site), not from `inline_small`, which is a stub. This is
  why `-Oz` belongs at the codegen gate, and why it can end up smaller than
  `-O0`.
- **`emit_store_savedpc` was the largest single code-volume item** — roughly 30
  bytes before ~70% of opcodes, 19 of them frame-invariant, estimated at 80-90 KB
  of Rover's `.text`. *(fixed; see [`../benchmarks/codegen-savedpc.md`](../benchmarks/codegen-savedpc.md),
  which measured -60 KB, inside that estimate.)*
- **Linker linear scans:** `gsym_find`, `reloc_target_rva`, `sym_rva`, the
  `resolve_fixpoint` restart, `LcAr_MemberDefining` in `ar_read.c`, `pool_add` in
  `coff_read.c`, and the `layout_sections` insertion sort. *(the first three
  fixed; see [`../benchmarks/linker-index.md`](../benchmarks/linker-index.md))*
- **Linker latent wrong-code:** an empty bounds-check body, unchecked `REL32`
  truncation, and `ADDR32` ImageBase truncation with a `DIR64`-typed base
  relocation because `RelocSite` carried no type field. *(fixed in `0ff2175`)*
- **`.pdata`/`.xdata` are unconditionally rooted** in `gc_sections`, which
  resurrects the CRT functions they describe. Still open, and a size item.
- **Rover:** `list_files` compared an absolute `dir /b /s` line against a
  possibly-relative prefix, so `publish` against the default relative
  `REPO_REGISTRY` silently emitted `init.lua`-only hashes and an empty file list.
  `tree_hash` excluded version-shaped directory names on every call.
  `read_lock`'s corrupt signal was discarded by `add`, `update`, `gc`, and
  `verify`. The index signature was checked at one call site only, while
  `available_versions` drove version selection unverified. `resolve_graph`
  installs while resolving, with no backtracking and `pairs()` iteration order.
  *(all but `resolve_graph` fixed)*
- **Environment variables reach `cmd.exe` unvalidated:** `CLUA_HOME` and
  `LOCALAPPDATA` in `rover.lua`, `TEMP` in two places, and `CLUA_GCC` in
  `pe_link_v2.c`. `ROVER_REGISTRY` *is* gated — the inconsistency is the finding.

## Corrections to the first audit

The point of a challenge pass is the disagreements, so they are stated plainly:

- **"Output publication is not atomic" targeted the wrong layer.**
  `link/pe_link_v2.c:73-177` already staged, replaced, and retried. The real
  gaps were a 260 ms retry budget, a `MAX_PATH` guard 14 bytes too loose, orphan
  `clu*.tmp` files, and the legacy `compiler/pe_link.c` path. *(narrowed and
  fixed accordingly)*
- **AOT output was already byte-reproducible.** The correct response was to bank
  it with a test, not to "fix" it.
- **The size direction is mixed, not monotone.** A `"debug"` literal sets
  `no_proofs`, which disables optimizer proofs and therefore makes binaries
  *smaller*. And `lc_module_used_libs` force-enables `LCLIB_STRING` for any
  `GETFIELD`/`SELF`/`MMBIN`, so `lstrlib` is effectively unconditional. Any
  isolated size claim for precise feature analysis must be remeasured after each
  gate is made precise.
- **Delivery order:** compile time is link-dominated (a ~14 ms check against a
  ~170 ms build), so the linker's linear scans had to precede any threading work.
  That ordering held, but the measured payoff was small — see the linker note.
