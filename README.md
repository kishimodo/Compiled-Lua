# CLua (LuaC) — Lua 5.4, Ahead-of-Time Compiled

**CLua** is an ahead-of-time optimizing compiler for the Lua 5.4 language,
targeting Windows x64. **`clua.exe`** compiles a Lua program to **native x64
machine code at build time** and emits an ordinary PE — standard sections, no
bytecode blob, no in-binary VM, no JIT. Your program ships as *code*, like a
GCC-compiled C program (which links libc); CLua links a runtime *library*
(GC, tables, strings, metatables, coroutines, FFI) the same way.

```
clua build app.lua            ->  app.exe   (optimized, -O2 default)
clua run app.lua -- arg1      compile + run in one step
clua check app.lua            front-end + closed-world check only
```

**`rover.exe`** is the package manager (init / add / install / publish, with
lockfiles, Merkle integrity and signed registries) — and it is itself a
CLua-compiled closed-world program, the largest fidelity fixture in the tree.
Outside a source checkout (and with no `--registry`/`$ROVER_REGISTRY`), rover
resolves packages from the **official registry**,
<https://raw.githubusercontent.com/kishimodo/CLua-Packages/main/packages>. It can also
install **foreign packages** straight from GitHub, Go-style —
`rover install github.com/<owner>/<repo>` (or the full https URL) — which are
NOT verified and carry no registry integrity hash, so rover warns loudly on
install/verify/list. To get a package verified and listed in the official
registry, open a Pull Request at
<https://github.com/kishimodo/CLua-Packages> (submissions are reviewed and
accepted or denied).

The pipeline is in-memory, rustc-style: front-end, optimizer, codegen and the
COFF object (including the serialized ProtoInit blob — no generated C) all
happen inside `clua.exe`; the only external step is one native link. A
hello-world builds in ~190 ms and weighs **~182 KB** stripped — the emitted
exe links a dedicated `runtime-aot.a` carrying **no JIT, no Lua
front-end** (`load`-family symbols are closed-world stubs), **no FFI**
unless the program references `ffi`/`bit` (opt-in link anchor), **no
winpthread** (no emulated TLS), and — for
programs that never mention `debug` — **no bytecode interpreter** (debug
hooks are the only thing that can reach it; programs that use the debug
library keep it and behave exactly like the oracle under `debug.sethook`).
`--gc-sections` drops everything unreferenced. What remains is the language
itself: the Lua core + full stdlib + GC + the AOT runtime helpers.

CLua has exactly two execution engines: the compiled native exe (the
product) and a reference bytecode interpreter that exists only as the
**differential test oracle**. There is no JIT anywhere in the tree. Every
compiled program must match `clua-interp.exe -i` byte-for-byte (the
interpreter always interprets; `-i` is accepted as a no-op), and the suite
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
  `clua-interp.exe -i` (the embedded reference interpreter). A red diff blocks
  everything.

## Build & test

From PowerShell:

```
cmd /c "build\build-luac.bat"             # builds everything: clua.exe, rover.exe,
                                          # aotc.exe, runtime-aot.a, oracle clua-interp.exe
build\bin\clua-interp.exe tools\run-tests.lua   # full auto-discovered suite
```

Compile a program (works from any directory — `clua.exe` finds its runtime
libraries relative to itself, or via `CLUA_HOME`):

```
build\bin\clua.exe build program.lua          # -> program.exe (-O2 default)
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
- Known bugs / bounded divergences: [`docs/known-bugs-2026-06-07.md`](docs/known-bugs-2026-06-07.md)

## Roadmap

- **M4**: builtin-package bundling for compiled exes, self-contained PE
  writer (drop the MinGW `ld` dependency — the last external step). The
  interpreter strip is DONE for debug-free programs (`lvm_nointerp.o`,
  AOT-NODEBUG-001); `luaV_execute` itself is now a thin native-dispatch
  entry (`clua_dispatch_hook`), not an interpreter.
- **Toolchain slimming**: emitted exes exclude any JIT (there is none in the
  tree) and the Lua front-end (closed-world stubs). The behavioral,
  differential, conformance and fuzz layers all run aotc-compiled exes
  against the interpreter (the interpreter stays — it *is* the oracle).
- **Workload-gated**: scalar replacement of non-escaping tables (see the
  status doc for the honest valuation).
