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
| 5 | Byte-identity/reproducibility gates, then `-Oz` lowering (imm32 helper args, selective prologue saves, outlined slow paths); make `-O2`/`-O3` honest | open | `-O2` is byte-identical to `-O1` today; `-O1` costs Rover ~13-15 KB over `-O0` |
| 6 | Optimizer verifier, codegen context isolation, deterministic IDs, build header-dependency tracking, parallel-safe build jobs | open | `lc_module_verify` returns `true` unconditionally; `codegen.c` still holds `g_lc_opt_level`, `g_res_*`, `g_savedpc_bias` |
| 7 | Split Rover solve/fetch/verify/install; real backtracking solver; bounded concurrent fetch and verification | open | `resolve_graph` still installs while resolving |
| 8 | Parallelize compiler-local work; overlap immutable archive-index loading; keep deterministic layout/publication barriers | blocked by 6 | needs codegen context isolation first |
| 9 | Incremental cache / build-server mode, UTF-16 long-path and process layer, full Windows fault matrix | open | audit sections "Windows stability" and "Test additions required" |

## Standing prerequisites

Independent of the order above, and each blocking a claim rather than a commit:

- **Precise feature-use analysis.** `lc_module_uses_debug`, `lc_module_uses_ffi`,
  and `lc_module_used_libs` still treat a matching string constant as feature
  use. Worth up to ~64 KB on a tiny program, but the string library is enabled
  by common field/table opcodes as well, so each gate must be remeasured after
  the one before it is made precise.
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
