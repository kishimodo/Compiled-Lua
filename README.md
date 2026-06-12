# CLua (LuaC) — Lua 5.4, Ahead-of-Time Compiled

**CLua** is an ahead-of-time optimizing compiler for the Lua 5.4 language,
targeting Windows x64. `aotc.exe` compiles a Lua program to **native x64
machine code at build time** and emits an ordinary PE — standard sections, no
bytecode blob, no in-binary VM, no JIT. Your program ships as *code*, like a
GCC-compiled C program (which links libc); CLua links a runtime *library*
(GC, tables, strings, metatables, coroutines, FFI) the same way.

This is a standalone project, separated from its origin (**LuaVM**, the
JIT-based v1, which lives in its own repository). The v1 interpreter and JIT
sources are still carried *inside this repo* — not as the product, but as the
**differential test oracle**: every compiled program must match
`luavm.exe -i` (the reference interpreter) byte-for-byte, and the suite
enforces that across the whole corpus at both `-O0` and `-O1`.

## Status

**M0 + the optimizer (M1, plus the valuable parts of M2) are complete and
adversarially validated.** The full Lua 5.4 language compiles to a native PE
that matches the reference interpreter byte-for-byte. The optimizer is real:

- **Checked fastpaths** — runtime tag-dispatch arith/compare/bitwise with
  complete helper fallbacks (sound by construction).
- **Static type inference + tag-check elision** — a forward dataflow fixpoint
  proves registers integer/float on every path; proven operands compile to
  bare machine instructions with no tag checks and no helpers.
- **Bare integer FORLOOP** — proven-integral loops drop the per-iteration
  helper call, the step tag-check, and the float arm.
- **Loop-region register residency** — proven-int slots live in R12–R15/RSI
  and proven-float slots in xmm6–xmm10 across qualified loop regions, with
  entry-type gates and spill-around observation points (helper ops inside the
  loop spill the frame first; registers stay authoritative — no refill).
- **Interprocedural type propagation** — tracked local helper functions get
  parameter types from their call sites and return-type summaries back, so
  proofs (and residency) extend across calls.

Representative numbers vs the faithful boxed baseline (`-O0`): tight integer
loop **17.3×** (~3.7 cycles/iteration), float accumulator **14×** (at the
addsd latency floor), branchy integer kernel **7×+**.

Soundness is enforced by a standing 13-lens **adversarial attack harness**
(differential vs the interpreter, with independent re-verification of every
claimed mismatch). Across 13 rounds it found 10 real bugs — every one fixed
and regression-pinned. See
[`docs/superpowers/plans/2026-06-10-luac-optimizer-status.md`](docs/superpowers/plans/2026-06-10-luac-optimizer-status.md)
for the complete record, including what was deliberately *not* built and why.

## Non-negotiables

- **Closed world.** The whole program is known at compile time. `load`,
  `loadstring`, `dofile`, `string.dump`, and dynamic `require` are **compile
  errors** — they would require shipping a compiler in the output.
- **100% Lua 5.4 fidelity.** Optimize only where a closed-world proof makes it
  sound; otherwise emit the same dynamic, boxed, metatable-aware operations
  the interpreter uses. No speculation, no deopt, no dialect.
- **The differential oracle is the arbiter.** Every script must produce
  identical stdout whether compiled by CLua (native) or run under
  `luavm.exe -i` (the embedded reference interpreter). A red diff blocks
  everything.

## Build & test

From PowerShell:

```
cmd /c "build\build-luac.bat"             # builds everything incl. aotc.exe
build\bin\luavm.exe tools\run-tests.lua   # full auto-discovered suite
```

Compile a program:

```
build\bin\aotc.exe -O1 program.lua -o program.exe
```

- Build spec & implementation prompt: [`PROMPT.md`](PROMPT.md)
- Working notes & testing discipline: [`CLAUDE.md`](CLAUDE.md)
- Fork manifest (what was inherited from v1): [`docs/fork-manifest.md`](docs/fork-manifest.md)
- Known bugs / bounded divergences: [`docs/known-bugs-2026-06-07.md`](docs/known-bugs-2026-06-07.md)

## Roadmap

- **M4**: builtin-package bundling for compiled exes, shipped-runtime
  `lvm.c` strip, self-contained PE writer (drop the MinGW `ld` dependency).
- **Toolchain slimming**: the v1 JIT compiler inside this repo is oracle
  infrastructure only; once the behavioral test layers run against compiled
  exes, the JIT can be removed (the interpreter stays — it *is* the oracle).
- **Workload-gated**: scalar replacement of non-escaping tables (see the
  status doc for the honest valuation).
