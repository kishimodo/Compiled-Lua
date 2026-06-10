# LuaC M0 Follow-on Plan 4 — pcall / coroutine / package

> Builds on green Plans 1–3 (the full Lua 5.4 op set is differential-green:
> arith, control flow, tables, closures, recursion, generic-for, varargs, tail
> calls). Plan 4 addresses the three runtime features.

## Status summary

| Feature | State |
|---|---|
| **pcall / xpcall** | ✅ **Works** — error catching, success results, multi-value returns all differential-green. (pcall is a `CALL` to a builtin; native AOT errors `longjmp` back to the protected frame correctly with MinGW's `setjmp`/`longjmp` — no `.pdata` needed for the error path.) |
| **Error-message position** | ✅ **Fixed** (P4.2, LUAC-001) — `source:line:` prefixes match the interpreter, including through recursion. Residual **LUAC-002** below. |
| **coroutines** | ✅ **Fixed** (P4.1) — `Coro_OpenLib` (fiber-based) in the AOT entry; create/resume/yield/wrap/status + yield across native call frames all differential-green. |
| **package `require`** | ⚠️ **Partial** — see below. Differential-green via disk fallback; self-contained bundling is M4-scoped. |

## P4.1 — Coroutines (DONE)
The AOT entry (`src/runtime/aot_entry.c`) now calls `Coro_OpenLib(L)` after
`luaL_openlibs` (mirroring v1's `RuntimeMain`), replacing the stock setjmp-based
coroutine lib with the Windows-fiber implementation so native AOT code can yield
across call frames. `Coro_InitProcess`/`Coro_InitThreadAsFiber` are lazy (inside
`Coro_OpenLib`/`coroutine.create`). Regression: `tests/differential/aot_coroutine.lua`.

## P4.2 — Error-message fidelity (DONE; LUAC-001 fixed)
Two pieces:
- **Codegen** (`codegen.c`): `emit_store_savedpc` writes `ci->u.l.savedpc =
  P->code + (pc+1)` (recovering `P->code` at runtime via `ci→func→closure→Proto→code`)
  before every throw-capable op (`op_needs_savedpc`, mirroring v1's set). So
  `pcRel(savedpc,P) == pc` and `luaG_getfuncline` resolves the right line.
- **ProtoInit** (`protoinit_emit.c`): reconstructs `source`, `linedefined`,
  `lastlinedefined`, `lineinfo`, `abslineinfo` verbatim from the compile-time Proto.
Runtime errors now print `source:line: message` matching `luavm.exe -i`. Regression:
`tests/differential/aot_errors.lua`.

### LUAC-002 (documented residual) — variable-name annotations
The interpreter annotates some errors with the operand name, e.g.
`attempt to index a nil value (field 'x')`. The `(field 'x')` / `(local 'y')` /
`(global 'z')` suffix comes from `getobjname`, which inspects the **real `code[]`
bytecode at the error pc + `locvars`**. LuaC keeps `code[]` a 1-instruction stub
(and omits `locvars`) to preserve the **no-embedded-bytecode** design property
(PROMPT §3). So the *location* (`source:line:`) is correct but the trailing
name annotation is omitted. Fixing it would require shipping the per-function
bytecode + locvars as data — a deliberate trade-off deferred (it only affects the
parenthetical hint in some error strings, not the location or the caught value).

## P4.3 — package `require` (partial; bundling is M4)
Precise gap analysis (probed 2026-06-10):
- **Local/user modules** (`require "siblingfile"`): `Resolve_Walk` resolves them
  into `res.Modules[]`, and the driver compiles them in (a `require"mymod"` program
  reports "2 modules"). At runtime `require` currently finds the module via Lua's
  stock **disk search + interpreter fallback** (the same path `luavm.exe -i` takes),
  so it is **differential-green** — but **not self-contained** (depends on the
  `.lua` on disk; the compiled-in copy is unused).
- **Builtin packages** (`require "base64"` etc.): `Resolve_Walk` lists them in
  `res.BuiltinPackages[]` (tree-shaking metadata), **not** `res.Modules[]`, so they
  are **not compiled into the program at all**. v1 embeds them as separate package
  objects via `build/gen/packages.mk` + the embedded loader.

**True self-contained package support = the PROMPT §14 / M4 subsystem.** It needs:
1. Register each compiled `res.Modules[i>0]` main-chunk closure in `package.preload[name]`
   at startup (the contained next step — modules are already compiled; thread the
   module names from the driver into the ProtoInit emitter, build a closure with
   `_ENV` bound, `package.preload[name] = closure`). Makes local `require`
   self-contained.
2. Adapt package discovery/bundling (`packages.mk`, `_builtin_packages.h`,
   `tools/build-package-catalog.lua`) to compile each required builtin package's
   source into the program as native objects + register it in `package.preload`
   (PROMPT §14 → "native package objects").
3. **Test oracle:** not `aotc`-vs-`luavm -i` (the interpreter can't bundle). Use
   either `luavm.exe` with `LUA_PATH` pointing at `src/runtime/packages` running the
   same script, or v1 `compiler.exe`-built exe vs `aotc`-built exe, with the package
   source absent from disk to prove self-containment.

This is left as the documented remaining subsystem (its own brainstorm→plan→execute
cycle), consistent with the original milestone plan placing broad package coverage in M4.

## Net result of Plans 1–4
`aotc` compiles the **full Lua 5.4 language** to a native PE that is differential-green
vs the interpreter: arithmetic, all control flow, tables/metatables/OOP, closures,
upvalues, recursion, generic & numeric `for`, varargs, tail calls, `pcall`/`xpcall`
with correct error positions, and fiber-based coroutines. Remaining: self-contained
package bundling (M4) and the optimizer milestones M1–M3.
