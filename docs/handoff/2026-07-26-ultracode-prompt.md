# The kickoff prompt for the platform + no-CRT arc

Paste the block in [§2](#2-the-prompt) to start the full development process. It
is written to be self-contained about *rules and order*, and to delegate all
*detail* to the plan documents, so it does not go stale as the plans evolve.

## 1. What this arc is

Three parallel tracks, one forced order inside each:

| Track | Plan | Gist |
|---|---|---|
| Tooling / language / reorg | [`docs/roadmaps/language-platform.md`](../roadmaps/language-platform.md) | split the multi-thousand-line files, then build the shared front end (`clua/src/fe/`), then linter, then LSP, then language features |
| CRT-free output | [`docs/roadmaps/no-crt.md`](../roadmaps/no-crt.md) | own libc in `clua/src/libc/`, `--crt=none`, `--freestanding` |
| Size / stability follow-ups | [`docs/roadmaps/concurrency-size-stability.md`](../roadmaps/concurrency-size-stability.md) | `-ffunction-sections` on the runtime is the real size lever |

Measured baselines the plans rest on:
[`docs/benchmarks/no-crt-baseline.md`](../benchmarks/no-crt-baseline.md) (libc
surface, where `hello.exe`'s 137,216 bytes actually are) and
[`docs/benchmarks/session-2026-07-25-ab.md`](../benchmarks/session-2026-07-25-ab.md)
(the previous arc's before/after).

## 2. The prompt

---

ultracode

Begin the platform + no-CRT development arc for CLua. **Read these before doing
anything, and treat them as the specification — I am deliberately not repeating
their content here:**

1. `CLAUDE.md` and `AGENTS.md` — the standing rules.
2. `docs/roadmaps/language-platform.md` — the tooling/language/reorg design and
   its execution order (Phases A–F, plus Phase B′).
3. `docs/roadmaps/no-crt.md` — the CRT-free output plan, items N0–N10.
4. `docs/roadmaps/concurrency-size-stability.md` — live status of the last arc.
5. `docs/benchmarks/no-crt-baseline.md` and `docs/benchmarks/README.md` — the
   measured baselines and the measurement protocol you must follow.
6. `docs/audits/2026-07-25-second-reviewer-challenge.md` — the failure modes a
   reviewer already caught me in; do not repeat them.

Work the order the roadmaps specify. Do not reorder to get an early win: the
ordering constraints are real and each is justified in place. Concretely — Phase A
enablers, then Phase B reorganisation **before** feature work lands on those
files, then the front end as the keystone, and the no-CRT track (Phase B′)
starting only after the `pe_emit.c` split.

**Non-negotiable invariants.** Every one of these has bitten this project before:

- The differential suite versus `clua-interp.exe` is the arbiter of correctness.
  **Never** weaken a comparison, loosen a tolerance, or edit interpreter
  semantics to make a diff pass. If our libm disagrees with `ucrtbase` in the
  last ulp, the answer is `no-crt.md` §4 (rebuild the oracle against the same
  libc), not a fuzzier diff.
- Output stays byte-reproducible. Run `tools/check-byte-identity.py` before and
  after every refactor; a file split is a *pure* refactor and must change zero
  bytes.
- No mutable file-scope state in `clua/src/codegen/`. `tools/test-codegen-no-globals.lua`
  enforces it. `--crt=` is a driver/linker concern and must not become a codegen
  input.
- Add or update a test in the matching `tests/` layer for every feature or fix,
  then run the full suite before calling anything done. Tests are auto-discovered
  — drop the file in the right folder.
- A known bug gets an XFAIL marker, never a workaround that makes the suite green.
- `-O2` currently emits the same bytes as `-O1`; `tools/test-olevel-contract.lua`
  pins that. If you make it untrue, update the contract deliberately.

**Measurement discipline.** No unmeasured size or speed claim. Anything claiming
an effect gets a `docs/benchmarks/` entry with its method, its ranges, and its
negative results — the last arc's runtime change was *zero* and saying so plainly
was the correct outcome. Specifically:

- A green tally is not evidence. `tools/run-tests.lua` counts a PASS with no
  output; assert the thing you changed was actually exercised. For `--crt=none`
  that means checking the import table, not the exit code.
- Build both arms fully before comparing. Stale objects in one arm silently
  invalidated a measurement in the last arc, and the fix (header dependency
  tracking, `clean-objs`) changed every emitted binary.
- Use min-of-N for runtime, medians with ranges for compile time, and state the
  jitter floor so a sub-noise result is not read as a win.

**Environment notes that cost real time if ignored:** the Windows-specific
gotchas — the `tar.exe` PATH shadowing that breaks `test-pkgmgr-foreign`, the
`cmd //c` MSYS mangling, backslash-eating heredocs, the stale-backend-object trap
after editing a backend header — are recorded in `CLAUDE.md` and in my project
memory. Check them before debugging an environment failure as if it were a code
bug.

**Reference material.** Reading `rust-analyzer`, `rustc_errors`, `clippy`,
`gopls`, `zig`, `zls` and `lua-language-server` is expected and encouraged for
design — the table in `language-platform.md` §8 says what to take from each. Clone
to **`D:\clua-refs\`, never `C:\`** (`C:` is tight and OneDrive-synced). Read for
design; **do not paste code.** If any snippet is ever adapted it needs its licence
header and an entry in `docs/fork-manifest.md`. Matching an interface convention
(`---@` annotations, LSP method names) is compatibility, not copying, and is
desirable.

**How to work.** Land small, independently green commits on a `claude/<task>`
worktree branch — one file move per commit so a bisect lands on one move. Update
the live status rows in the roadmap as items land rather than re-litigating the
design. Write a `docs/handoff/` entry when you stop. If a plan turns out to be
wrong once you are in the code, say so with the evidence and propose the
correction — the plans were written from measurement, but not from having built
the thing.

Start with `language-platform.md` Phase A, and tell me what you find before you
start Phase B — item A2 (whether `clua/src/compiler/pe_link.c` is dead and should
be deleted rather than reorganised) is a decision I want to see the evidence for.

---

## 3. Notes on using it

- The prompt ends by asking for a checkpoint after Phase A. That is deliberate:
  A2 is a delete-or-keep call on 1,548 lines, and Phase B's cost depends on it.
- If you would rather start on the no-CRT track directly, replace the last
  paragraph with: *"Start with `no-crt.md` items N0–N2. Do not implement any libc
  function until the N1 differential harness is green against `ucrtbase` itself."*
  N0–N2 are useful on their own and do not depend on the reorganisation, but see
  the Phase B′ gating note before going past N2.
- The `ultracode` keyword on line 1 is what opts into multi-agent orchestration
  for the session. Drop it for a single-agent run.
