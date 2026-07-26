# Handoff: concurrency, size, and Windows stability — 2026-07-25

Branch: `codex/concurrency-size-stability` at `7fec28f`, plus the shared-workspace
migration on top. Supersedes: none.

## State

The joint review is recorded in
[`../audits/2026-07-25-concurrency-size-stability-audit.md`](../audits/2026-07-25-concurrency-size-stability-audit.md)
and challenged in
[`../audits/2026-07-25-second-reviewer-challenge.md`](../audits/2026-07-25-second-reviewer-challenge.md).
Live status per deliverable is
[`../roadmaps/concurrency-size-stability.md`](../roadmaps/concurrency-size-stability.md);
rows 1-4 are done and rows 5-9 are open.

Proven, each with its evidence:

- correctness and security: `OP_SELF`'s `k` bit (`e11099a`), lockfile version
  traversal (`e11099a`), relocation width/range validation (`0ff2175`), and a
  fail-closed test harness (`a8ce8aa`);
- atomic compiler output publication (`ca29c16`, `ef3694e`) and transactional
  Rover store and locks (`ba74dba`, `2c067c8`);
- indexed linker symbol and contribution lookups (`092122b`) —
  [`../benchmarks/linker-index.md`](../benchmarks/linker-index.md);
- the `savedpc` base hoist (`9d3ded2`, authored as `f39a1bd`) —
  [`../benchmarks/codegen-savedpc.md`](../benchmarks/codegen-savedpc.md).

## Verified how

- Full fail-closed suite: `build\run-tests.bat` — 682 pass, 0 fail, 5 expected
  skips, 0 XFAIL, 0 XPASS on this branch. Read it together with the harness
  caveats in the audit: a green tally alone is not evidence.
- Differential fuzz smoke: 55 seeds across O1/O2/O3, zero divergence, zero
  oracle failures.
- Concurrency: 16 simultaneous builds (8 sharing one output path, 8 with
  distinct ones), all exit zero, all 9 published executables valid and sharing
  one SHA-256.
- Size and time: the tables in [`../benchmarks/README.md`](../benchmarks/README.md),
  warm, with the spread stated.
- The mutation evidence for `savedpc` pc-exactness, which is the part that would
  otherwise be taken on trust.

Environment trap, not a code fault: `test-pkgmgr-foreign` fails whenever a GNU
`tar.exe` precedes `C:\Windows\System32\tar.exe` on `PATH`, because GNU tar reads
a `C:\...` destination as a remote host. Prepend the system directory — never
replace `PATH`, or `powershell.exe` drops off it and the sysroot step dies.

## Not done / not claimed

- Rover claims no power-loss durability (no OS-level directory flush is
  reachable from Lua), no whole-directory atomicity for the legacy flat
  compatibility view, and no safe global GC across unrelated projects.
- `-O2` and `-O3` still do no work beyond `-O1`; the CLI default is `-O2`.
- `lc_module_verify` still returns `true` unconditionally, so `verify_each` is a
  safety control that only appears active.
- `clua/src/codegen/codegen.c` still holds per-compilation state in file-scope
  globals (`g_lc_opt_level`, `g_res_*`, and now `g_savedpc_bias`), which blocks
  per-function parallelism.
- The compile-time wins measured so far are small; the ~165 ms floor of a warm
  link-dominated build is archive parsing plus PE writing and is unaddressed.

## Next

Roadmap row 5: byte-identity gates first, then `-Oz` lowering (imm32 helper
arguments, selective callee-saved prologues, outlined slow paths), because it is
the largest remaining size lever that does not first require the codegen context
refactor in row 6. Row 8 is blocked on row 6 and should not be started before it.
