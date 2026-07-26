# Roadmap: concurrency, size, compile time, and Windows stability

Status file. Any agent may update it; keep the wording agent-neutral and cite
evidence by commit and by a file under [`docs/audits/`](../audits/) or
[`docs/benchmarks/`](../benchmarks/) rather than by narrative claim.

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
| 5 | Byte-identity/reproducibility gates, then `-Oz` lowering (selective prologue saves, outlined slow paths); make `-O2`/`-O3` honest | open | `-O2` is byte-identical to `-O1` today; `-O1` costs Rover ~14 KB over `-O0`. **imm32 helper arguments moved out of this row** — measurement shows it is not a tradeoff and must not be gated behind `-Oz`; see the tracker below |
| 6 | Optimizer verifier, codegen context isolation, deterministic IDs, build header-dependency tracking, parallel-safe build jobs | open | `lc_module_verify` returns `true` unconditionally; `codegen.c` still holds `g_lc_opt_level`, `g_res_*`, `g_savedpc_bias` |
| 7 | Split Rover solve/fetch/verify/install; real backtracking solver; bounded concurrent fetch and verification | open | `resolve_graph` still installs while resolving |
| 8 | Parallelize compiler-local work; overlap immutable archive-index loading; keep deterministic layout/publication barriers | blocked by 6 | needs codegen context isolation first |
| 9 | Incremental cache / build-server mode, UTF-16 long-path and process layer, full Windows fault matrix | open | audit sections "Windows stability" and "Test additions required". **Deprioritised:** the archive-*parse* cache this row inherited from audit item 10 is worth only 7-8 ms; the lookup index below is the real linker win |

## Current work in flight (2026-07-25)

Measured ranking, in execution order. Statuses here are the live ones; the table
above stays as the strategic order.

| Step | Work | Status | Measured basis |
|---|---|---|---|
| 1 | Record this session's measurements in `docs/benchmarks/` | done | [`helper-call-args.md`](../benchmarks/helper-call-args.md), [`archive-symbol-lookup.md`](../benchmarks/archive-symbol-lookup.md), harnesses `tools/count-imm-sites.py` and `tools/bench-armap.c` |
| 2 | Archive symbol-lookup counter behind `CLUA_GC_DEBUG` | done | `04abf0a` — 19,111-25,114 archive queries and 31-41M name compares per link, a fixed per-link tax independent of program size |
| 3 | Measure the `.pdata`/`.xdata` rooting cost | done, negative | [`link-gc-unwind-roots.md`](../benchmarks/link-gc-unwind-roots.md) — unrooting frees 128 bytes of `.text`, total ~3 KB. Hypothesis refuted; the `hello` floor needs a different lead |
| 4 | Pin the system `tar` in the test runner | open | environment fault that makes a green suite look broken |
| 5 | **imm32 helper-call arguments** | open | **-73,124 bytes** = 12.4% of Rover's `.text`; 4,724 sites, 0 immediates needing >32 bits, every `Rt_*` param is `int` |
| 6 | **Hash the archive symbol index** | open | **~33 us per lookup** over 19,775 entries; parse is only 7-8 ms |
| 7 | `-MMD -MP` header dependencies | open | removes the documented stale-object trap that yields silent empty-output binaries |
| 8 | Codegen context isolation | open | row 6 prerequisite; must follow step 5, same file |
| 9 | Implement `lc_module_verify` | open | a safety control that only appears active |
| 10 | Make `-O2`/`-O3` honest | open | `-O1` and `-O2` share SHA-256 `e474660e…0d21bde` |

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
- **Pin the system `tar`** in the test runner. GNU `tar.exe` ahead of
  `C:\Windows\System32\tar.exe` on `PATH` reads a `C:\...` destination as a
  remote host and fails `test-pkgmgr-foreign`. Environment fault, not a code
  regression, but it is a trap left in place.

## Invariants every slice must preserve

1. byte-identical behavior against `clua-interp.exe` (the differential suite is
   the arbiter, never edited to make a diff pass);
2. deterministic output, byte-identical across repeated runs and across future
   job counts;
3. a green full suite from `build\run-tests.bat`, read together with the
   harness caveats in the audit;
4. no new file-scope mutable state in `clua/src/codegen/` — row 6 exists to
   drain that list, not to grow it.
