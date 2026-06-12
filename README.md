# CLua (LuaC) — Lua 5.4, Ahead-of-Time Compiled

**CLua** is an ahead-of-time optimizing compiler for the Lua 5.4 language,
targeting Windows x64. **`clua.exe`** compiles a Lua program to **native x64
machine code at build time** and emits an ordinary PE — standard sections, no
bytecode blob, no in-binary VM, no JIT. Your program ships as *code*, like a
GCC-compiled C program (which links libc); CLua links a runtime *library*
(GC, tables, strings, metatables, coroutines, FFI) the same way.

```
clua build app.lua            ->  app.exe   (optimized, -O1 default)
clua run app.lua -- arg1      compile + run in one step
clua check app.lua            front-end + closed-world check only
```

**`rover.exe`** is the package manager (init / add / install / publish, with
lockfiles, Merkle integrity and signed registries) — and it is itself a
CLua-compiled closed-world program, the largest fidelity fixture in the tree.

The pipeline is in-memory, rustc-style: front-end, optimizer, codegen and the
COFF object (including the serialized ProtoInit blob — no generated C) all
happen inside `clua.exe`; the only external step is one native link. A
hello-world builds in ~190 ms and weighs **~194 KB** stripped — the emitted
exe links a dedicated `runtime-aot.a` carrying **no JIT compiler, no Lua
front-end** (`load`-family symbols are closed-world stubs), **no FFI** (the
AOT entry never opens it) and **no winpthread** (no emulated TLS), with
`--gc-sections` dropping everything unreferenced. What remains is the
language itself: the Lua core + full stdlib + GC + the AOT runtime helpers.

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
cmd /c "build\build-luac.bat"             # builds everything: clua.exe, rover.exe,
                                          # aotc.exe, runtime-aot.a, oracle luavm.exe
build\bin\luavm.exe tools\run-tests.lua   # full auto-discovered suite
```

Compile a program (works from any directory — `clua.exe` finds its runtime
libraries relative to itself, or via `CLUA_HOME`):

```
build\bin\clua.exe build program.lua          # -> program.exe (-O1 default)
build\bin\clua.exe run program.lua -- args    # compile + run
```

`aotc.exe` is the low-level driver the test infrastructure uses (same
pipeline, flag-compatible with the original CLI: `-O0` default, `-o out.exe`).
For a shippable user layout run `make -f build/Makefile.luac dist` from
`build-luac.bat`'s environment — it produces `dist\` with `clua.exe`,
`rover.exe`, `lib\` and a README; the only external requirement on a user
machine is a MinGW-w64 gcc on PATH (or `CLUA_GCC`) for the final link.

- Build spec & implementation prompt: [`PROMPT.md`](PROMPT.md)
- Working notes & testing discipline: [`CLAUDE.md`](CLAUDE.md)
- Fork manifest (what was inherited from v1): [`docs/fork-manifest.md`](docs/fork-manifest.md)
- Known bugs / bounded divergences: [`docs/known-bugs-2026-06-07.md`](docs/known-bugs-2026-06-07.md)

## Roadmap

- **M4**: builtin-package bundling for compiled exes, shipped-runtime
  `lvm.c` strip (the `luaV_execute` interpreter loop, ~15 KB, is still the
  AOT dispatch trampoline), self-contained PE writer (drop the MinGW `ld`
  dependency — the last external step).
- **Toolchain slimming**: emitted exes already exclude the JIT compiler
  (`runtime-aot.a`) and the Lua front-end (closed-world stubs). The v1 JIT
  inside this repo is oracle infrastructure only; once the behavioral test
  layers run against compiled exes, it can be removed from the tree too
  (the interpreter stays — it *is* the oracle).
- **Workload-gated**: scalar replacement of non-escaping tables (see the
  status doc for the honest valuation).
