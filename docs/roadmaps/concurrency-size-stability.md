# Roadmap: concurrency, size, compile time, and Windows stability

Status file. Any agent may update it; keep the wording agent-neutral and cite
evidence by commit and by a file under [`docs/audits/`](../audits/) or
[`docs/benchmarks/`](../benchmarks/) rather than by narrative claim.

Successor arc: [`language-platform.md`](language-platform.md) covers tooling
(linter, IntelliSense), language dynamism, ecosystem, and the codebase
reorganisation, with its own execution order.

Source review: [`docs/audits/2026-07-25-concurrency-size-stability-audit.md`](../audits/2026-07-25-concurrency-size-stability-audit.md)
and its challenge pass, [`docs/audits/2026-07-25-second-reviewer-challenge.md`](../audits/2026-07-25-second-reviewer-challenge.md).
Measured numbers: [`docs/benchmarks/`](../benchmarks/).

Conventions for editing this file:

- one row per deliverable, in the intended delivery order;
- `done` requires a commit id **and** a measurement or test named in the notes;
- `blocked` requires the blocking row's number;
- never mark a row `done` on the strength of a green tally alone — see the
  harness caveats in the audit.

## Delivery order

| # | Deliverable | Status | Evidence |
|---|---|---|---|
| 1 | Correctness/security: `OP_SELF` `k` bit, lockfile version traversal, relocation validation, fail-closed harness | done | `e11099a`, `0ff2175`, `a8ce8aa`; conformance `many_constants_self.lua`, `tests/unit/test_lc_pe_emit.c` |
| 2 | Atomic compiler output publication and transactional Rover store/locks | done | `ca29c16`, `ef3694e`, `ba74dba`, `2c067c8`; `tools/test-pkgmgr-transactions.lua`, 16-way concurrent build stress |
| 3 | Index the internal linker's symbol and contribution lookups | done | `092122b`; [`benchmarks/linker-index.md`](../benchmarks/linker-index.md) — real but small (-1.9% Rover, -4.6% hello); removes the scaling cliff |
| 4 | Hoist the `savedpc` base into the frame prologue | done | `9d3ded2` (from `f39a1bd`); [`benchmarks/codegen-savedpc.md`](../benchmarks/codegen-savedpc.md) — Rover `.text` -9%, whole PE -7.6% |
| 5 | Byte-identity/reproducibility gates, then `-Oz` lowering (selective prologue saves, outlined slow paths) | partly done: gates + `-O` honesty done, `-Oz` lowering open | `-O2` is byte-identical to `-O1` today; `-O1` costs Rover ~14 KB over `-O0`. **imm32 helper arguments moved out of this row** — measurement shows it is not a tradeoff and must not be gated behind `-Oz`; see the tracker below |
| 6 | Optimizer verifier, codegen context isolation, deterministic IDs, build header-dependency tracking, parallel-safe build jobs | mostly done | **verifier implemented and wired**; **codegen context isolation done** (6 globals -> 0, [`benchmarks/codegen-context.md`](../benchmarks/codegen-context.md)); **header-dependency tracking done**. Remaining: deterministic IDs and parallel-safe build jobs |
| 7 | Split Rover solve/fetch/verify/install; real backtracking solver; bounded concurrent fetch and verification | open | `resolve_graph` still installs while resolving |
| 8 | Parallelize compiler-local work; overlap immutable archive-index loading; keep deterministic layout/publication barriers | unblocked, open | codegen state is now isolated. Remaining shared surface before a worker pool: the allocator, `LcBr_Resolve`'s stderr diagnostics, and `lc_codegen`'s output ordering — see [`benchmarks/codegen-context.md`](../benchmarks/codegen-context.md) |
| 9 | Incremental cache / build-server mode, UTF-16 long-path and process layer, full Windows fault matrix | open | audit sections "Windows stability" and "Test additions required". **Deprioritised:** the archive-*parse* cache this row inherited from audit item 10 is worth only 7-8 ms; the lookup index below is the real linker win |

## Current work in flight (2026-07-25)

Measured ranking, in execution order. Statuses here are the live ones; the table
above stays as the strategic order.

| Step | Work | Status | Measured basis |
|---|---|---|---|
| 1 | Record this session's measurements in `docs/benchmarks/` | done | **[`session-2026-07-25-ab.md`](../benchmarks/session-2026-07-25-ab.md) is the deliverable** — whole-session A/B across all three number classes (size, compile time, **runtime speed**), both arms freshly built. Per-change: [`helper-call-args.md`](../benchmarks/helper-call-args.md), [`archive-symbol-lookup.md`](../benchmarks/archive-symbol-lookup.md), [`codegen-context.md`](../benchmarks/codegen-context.md), [`link-gc-unwind-roots.md`](../benchmarks/link-gc-unwind-roots.md). Harnesses `tools/count-imm-sites.py`, `tools/bench-armap.c`, `tools/bench-runtime.lua`, `tools/check-byte-identity.py` |
| 2 | Archive symbol-lookup counter behind `CLUA_GC_DEBUG` | done | `04abf0a` — 19,111-25,114 archive queries and 31-41M name compares per link, a fixed per-link tax independent of program size |
| 3 | Measure the `.pdata`/`.xdata` rooting cost | done, negative | [`link-gc-unwind-roots.md`](../benchmarks/link-gc-unwind-roots.md) — unrooting frees 128 bytes of `.text`, total ~3 KB. Hypothesis refuted; the `hello` floor needs a different lead |
| 4 | Pin the system `tar` (**at Rover's call site, not in the test runner** — the original phrasing misdirected: immunity came from removing the dependency, and `build/*.bat` mutates no `PATH`) | done | `rover/src/rover.lua` `tar_exe()` pins `%SystemRoot%\System32\tar.exe`; case C7 puts a hostile `tar` first on `PATH` and asserts the install still succeeds *and* the hostile binary was never invoked. Mutation-verified: reverting the pin makes C7 fail with the fake tar invoked. Also verified against the shipped AOT `rover.exe`, and the hostile-`SystemRoot` path fails closed |
| 5 | **imm32 helper-call arguments** | done | **-73,216 bytes** measured (-12.0% of Rover's `.text`, -9.9% whole file), against a 73,124 prediction; hello unchanged. Unconditional, not behind `-Oz`. [`helper-call-args.md`](../benchmarks/helper-call-args.md) |
| 6 | **Hash the archive symbol index** | done | **-52% warm build** (rover -O1 180->87 ms, hello 153->76 ms); 41,058,508 name compares -> 21,537 with every resolution count bit-identical; output byte-identical. [`archive-symbol-lookup.md`](../benchmarks/archive-symbol-lookup.md) |
| 7 | `-MMD -MP` header dependencies | done | touching `ir.h` rebuilds 7 objects including `lift.o`; a struct-layout change in `ar_read.h` rebuilds both objects sharing its `sizeof`, where before it rebuilt neither. `tools/test-build-header-deps.lua` |
| 8 | Codegen context isolation | done | 6 mutable file-scope objects -> 0 (`nm`), all 18 byte-identity rows unchanged. [`codegen-context.md`](../benchmarks/codegen-context.md); gated by `tools/test-codegen-no-globals.lua` |
| 9 | Implement `lc_module_verify` | done | structural checks on the memory form, invoked after every mutating pass group **and** unconditionally before codegen (the `-O0` gap). `tests/unit/test_lc_ir_verify.c`: **55 checks** (44 at `8ae7d3f`; `8b868a1` added more and swept unasserted `if` guards), of which **21 assert a rejection** and so fail against the old `err[0]='\0'; return true` |
| 10 | Make `-O2`/`-O3` honest | done | **`-O3` is narrower than "narrow": on `rover/src/rover.lua` it emits BYTE-IDENTICAL output to `-O2`** (measured 2026-07-26, both 670,720 bytes, same SHA-256), so its one real pass (`scalar_replace`) does nothing on the largest real program in the tree. It does fire on a small fixture (512 bytes smaller), which `tools/test-olevel-contract.lua` now pins. Plus strict `-O` parsing in both drivers (`-Os`/`-Oz`/`-Ofast`/`-O9` were silently becoming `-O0` or "everything"), per-level help text stating what each actually runs, and `tools/test-olevel-contract.lua` — whose `-O1 == -O2` assertion keeps the claim true rather than merely written down |

## Measured outcome of the arc

Kept here, not only in `docs/benchmarks/`, because a roadmap that records what was
attempted but not what it achieved is where numbers evaporate. Full method,
ranges and caveats in
[`session-2026-07-25-ab.md`](../benchmarks/session-2026-07-25-ab.md); current
absolute sizes in [`README.md`](../benchmarks/README.md).

| Dimension | Result |
|---|---|
| **Binary size** | Rover `-O1` 739,328 → 670,720 whole-file (**−9.28%** same-invocation), `.text` 605,694 → 536,446 (**−11.43%**). `print("hello")` **unchanged at 137,216** — its bytes are runtime and CRT, so it does not move with user code |
| **Compile time** | Warm `-O1` medians: Rover 187 → **86 ms**, hello 153 → **73 ms**, benchmark 174 → **74 ms** (**−52…−57%**). Arms do not overlap. Nearly all of it is the archive symbol index, a fixed per-link saving |
| **Runtime speed** | **Unchanged.** min-of-13 251.4 → 250.9 ms (−0.18%), p25 +0.37%, median +1.30% — every estimator inside the 4.7–6.1 ms (~2%) jitter floor. This is the *expected* result: imm32 executes the same instructions with shorter encodings, and the archive index is compile-time only. Nothing in the arc targeted runtime and nothing regressed it |
| **Correctness** | 697 pass / 0 fail / 5 expected skips; all 18 byte-identity rows reproducible; `-O1` ≡ `-O2` still pinned |

The runtime figure is the one that had *not* been measured until it was asked for.
It is recorded as a null result with the jitter floor quantified, because a
sub-noise number reported as a win is worse than no number. Resolving a sub-1%
runtime effect would need a quiet machine or instruction counting rather than
wall clock — see the method caveats in the A/B document.

## Standing prerequisites

Independent of the order above, and each blocking a claim rather than a commit:

- **Precise feature-use analysis.** `lc_module_uses_debug`, `lc_module_uses_ffi`,
  and `lc_module_used_libs` still treat a matching string constant as feature
  use. This is correct work, but its size value has been **deflated to roughly
  zero for real programs**: `lc_module_used_libs` force-enables `LCLIB_STRING`
  for any `GETFIELD`/`GETI`/`GETTABLE`/`SELF`/`MMBIN*`, so `lstrlib` is
  effectively unconditional, and a `"debug"` literal sets `no_proofs`, which
  makes binaries *smaller*. The "up to 64 KB" figure applies only to minimal
  programs that name a library as data and never use it.
- **Proto metadata profiles.** Default developer-grade fidelity stays; add
  `-gline` and `-g0` explicitly rather than silently stripping.
- **Store-level Rover safety.** Content-addressed store plus project links, so
  one project's `remove`/`gc` cannot delete another project's pinned version.
  Durability and whole-directory atomicity of the legacy flat view remain
  unclaimed on purpose.
- **Remove developer-machine path defaults** from `build/*.bat`; discover the
  toolchain from `PATH` or an explicit toolchain file.
- ~~**Pin the system `tar`** in the test runner.~~ **Done.** Rover pins
  `%SystemRoot%\System32\tar.exe` at the one call site that extracts a foreign
  tarball, and `tools/test-pkgmgr-foreign.lua` case C7 puts a hostile `tar` first
  on `PATH`, then asserts the install still succeeds *and* that the hostile
  binary was never invoked. `PATH` was deliberately **not** mutated in
  `build/*.bat`: immunity came from removing the dependency, and a blanket
  `System32` prepend would re-resolve `find`/`sort`/`curl`/`bash` for the whole
  build to serve zero remaining callers. The separate "remove developer-machine
  path defaults" bullet above is still open.

## Invariants every slice must preserve

1. byte-identical behavior against `clua-interp.exe` (the differential suite is
   the arbiter, never edited to make a diff pass);
2. deterministic output, byte-identical across repeated runs and across future
   job counts;
3. a green full suite from `build\run-tests.bat`, read together with the
   harness caveats in the audit;
4. no new file-scope mutable state in `clua/src/codegen/` — the list is now
   empty and `tools/test-codegen-no-globals.lua` keeps it that way. Put
   per-compilation values in `LcCgCtx` and per-function values in `LcCgFnCtx`.
