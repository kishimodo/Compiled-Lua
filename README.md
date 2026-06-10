# LuaC — Lua 5.4, Compiled (LuaVM 2.0)

**LuaC** is an ahead-of-time (AOT) optimizing compiler for the Lua 5.4 language,
targeting Windows x64. It is a clean fork of **LuaVM v1**.

The difference in one line:

> **v1** compiles your Lua to **bytecode**, embeds it in the `.exe`, and runs it
> with an in-binary JIT/interpreter. **LuaC** compiles your Lua to **native x64
> machine code** at build time and emits an ordinary PE — standard sections, no
> bytecode blob, no in-binary VM. Your program ships as *code*, like a
> GCC-compiled C program (which links libc); LuaC links a runtime *library* (GC,
> tables, strings, metatables, coroutines, FFI) the same way.

## Status

**Design + scaffold stage.** This folder contains:

- the **reused v1 source** (front-end, runtime core, FFI, ~195 packages, build,
  tests), copied verbatim as the foundation;
- **skeleton headers** for the new backend — [`src/ir`](src/ir),
  [`src/opt`](src/opt), [`src/codegen`](src/codegen), [`src/link`](src/link),
  [`src/driver`](src/driver);
- the full build spec & implementation prompt in [`PROMPT.md`](PROMPT.md);
- the grounded file-level fork manifest in
  [`docs/fork-manifest.md`](docs/fork-manifest.md).

The optimizing backend itself is **not yet implemented** — `PROMPT.md` §15 lays
out the phased milestones (M0 faithful native baseline → M1 local opt → M2
whole-program → M3 memory opt → M4 polish).

## Read these first

1. [`PROMPT.md`](PROMPT.md) — the mission, the 5 locked decisions, the pipeline,
   the IR, every optimization pass, the runtime surface, codegen, PE emission,
   FFI rules, packages, testing, and the milestone plan. **Start here.**
2. [`docs/fork-manifest.md`](docs/fork-manifest.md) — per-file copy/strip/drop
   actions and the audited gotchas, grounded in v1 with `file:line` citations.
3. [`src/ir/ir.h`](src/ir/ir.h) — the SSA IR and type lattice (the normative
   interface for the whole backend).

## The pipeline

```
root.lua ─▶ front-end (reused) ─▶ Lua bytecode ─▶ lift ─▶ SSA IR
         ─▶ whole-program optimizer ─▶ x64 codegen (+ unwind, relocations)
         ─▶ native PE linker ─▶ standard .exe / .dll
```

## Non-negotiables

- **Closed world.** The whole program is known at compile time. `load`,
  `loadstring`, `dofile`, `string.dump`, and dynamic `require` are **compile
  errors** — they would require shipping a compiler in the output.
- **100% Lua 5.4 fidelity.** Optimize only where a closed-world proof makes it
  sound; otherwise emit the same dynamic, boxed, metatable-aware operations the
  interpreter uses. No speculation, no deopt, no dialect.
- **The differential oracle is the arbiter.** Every script must produce identical
  stdout whether compiled by LuaC (native) or run under v1's `luavm.exe -i`
  (interpreter). A red diff blocks merge.

## Build & test

LuaC reuses v1's build/test machinery (see [`CLAUDE.md`](CLAUDE.md)). Once the
backend exists, the AOT driver builds via `build/Makefile.luac` and the
auto-discovered 5-layer suite (including the new AOT-vs-interpreter differential
layer) runs via `build\run-tests.bat`.
