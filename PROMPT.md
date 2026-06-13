# LuaC — Build Specification & Implementation Prompt

> **LuaC** = **Lua** **C**ompiled: a *true ahead-of-time native compiler* for
> Lua 5.4. Where a bytecode-embedding compiler ships Lua **bytecode** in the
> output and runs it with an in-binary VM, LuaC
> lowers Lua 5.4 to **native x64 machine code at compile time** and emits an
> ordinary Windows PE — standard sections, no bytecode blob, no in-binary VM, no
> loader stub. The only thing linked alongside your code is a runtime *library*
> (GC, tables, strings, metatables, coroutines, FFI), exactly the way a
> GCC-compiled C program statically links the CRT/libc.

---

## 0. How to use this document

This file is two things at once:

1. **A kickoff prompt** (§1) you can hand to a capable coding agent to *start*
   implementing LuaC. It is self-contained: it states the mission, the
   invariants, and the first milestone.
2. **A complete build specification** (§2–§16) the agent consults as it works:
   the locked decisions, the exact files forked from v1, the IR design, every
   optimization pass, the runtime helper surface (with real symbol names and
   file:line citations into v1), codegen, PE emission, FFI rules, packages,
   testing, and a phased milestone plan.

The folder you are reading already contains: the **reused v1 source** (front-end,
runtime core, FFI, ~195 packages, build, tests) copied verbatim, and **skeleton
headers** for the new backend (`src/ir`, `src/opt`, `src/codegen`, `src/link`,
`src/driver`). Your job is to fill in the new backend and rewire the linker.

---

## 1. KICKOFF PROMPT (hand this to the implementer)

> You are implementing **LuaC**, an ahead-of-time optimizing compiler for Lua 5.4
> targeting Windows x64. The Lua front-end
> (lexer/parser/bytecode compiler), the runtime core (GC, tables, strings,
> metatables, coroutines), and the Windows FFI are already present and reused
> **unchanged**. You are building the middle and back end: **Lua bytecode → SSA IR
> → whole-program optimization → native x64 → standard PE.**
>
> **The one inviolable rule:** the compiled program must behave *identically* to
> the same script run under the stock Lua 5.4 interpreter, for every input. LuaC
> optimizes only where a closed-world proof guarantees the optimization is sound;
> everywhere else it emits the same dynamic, boxed, metatable-aware operations the
> interpreter uses (by calling the runtime helpers `Rt_*` / `luaV_*` / `luaH_*`).
> Correctness first, speed second. A differential test harness (compile with LuaC,
> run the same script under v1's `-i` interpreter, diff stdout) is the arbiter.
>
> **Scope (closed world):** the whole program is known at compile time. `load`,
> `loadstring`, `dofile`, `string.dump`, and `require` of non-bundled modules are
> **rejected at compile time** — they would require shipping a compiler in the
> output, defeating pure AOT. This is what makes whole-program analysis sound.
>
> **Start with Milestone M0 (see §15): a *faithful, unoptimized* native baseline.**
> Lower every bytecode op to its generic, boxed runtime-helper form — no type
> inference, no unboxing — but emit it as native code in `.text` with no
> interpreter loop. Get a trivial script (`print("hello"); for i=1,10 do
> print(i*i) end`) compiling to a real `.exe` that passes the differential test.
> Only then layer on the optimizer (M1→M3). Do not chase performance before M0 is
> green across the existing test suite.
>
> Read §2 (decisions), §4 (layout), §5 (pipeline), then the section for whatever
> milestone you are on. Every claim about v1 below is cited `file:line`; open the
> real file before you rely on it.

---

## 2. Locked design decisions

These were decided deliberately. Do not relitigate them mid-build.

| # | Decision | Consequence |
|---|----------|-------------|
| 1 | **Closed-world pure AOT.** No runtime code loading. | Output contains *zero* bytecode VM. `load`/`loadstring`/`dofile`/`string.dump`/dynamic `require` are compile errors. The whole call graph is known. |
| 2 | **Fresh whole-program optimizing backend.** Not the v1 JIT, not transpile-to-C. | New SSA IR + passes + instruction selection. Reuse only the low-level `emit_x64` encoder and `regalloc` from v1's JIT. |
| 3 | **Whole-program, interprocedural** optimization is the end goal. | The IR carries a complete call graph and an interprocedural type-propagation fixpoint. Delivered last, but the IR is designed for it from day one. |
| 4 | **100% Lua 5.4 fidelity via *sound-conservative* optimization.** | No speculation, no deopt machinery, no "strict dialect." Optimize only where provable; otherwise emit the dynamic path. FFI/C edges are conservative barriers. |
| 5 | **Clean fork in this `LuaC/` folder.** v1 stays frozen as the reference/differential oracle. | Duplication is accepted; the two trees evolve independently. v1's `clua-interp.exe -i` is the correctness oracle. |

---

## 3. What "no shim, no BS, regular binary" means precisely

A compiled LuaC `.exe` has only standard sections:

| Section | Contents |
|---|---|
| `.text` | Native x64 for **every** Lua function in the program + the runtime library code |
| `.rdata` | Constant pool: interned string bytes, float/int literals, intrinsic tables, import name strings |
| `.data` | Initialized mutable globals (seed of the global Lua state) |
| `.bss` | Zero-initialized globals |
| `.pdata` | `RUNTIME_FUNCTION` entries — one per function that establishes a frame |
| `.xdata` | `UNWIND_INFO` blobs referenced by `.pdata` (SEH unwind for `pcall`/FFI/coroutines) |
| `.idata` | Import directory (kernel32, advapi32, …; FFI loads its own libs at runtime) |
| `.reloc` | Base relocations (omit only if you commit to a fixed image base) |

**No** `.clua-interp`/payload section, **no** appended overlay past the last section,
**no** embedded bytecode blob (`g_LuaBlob` is gone), **no** in-binary module
searcher. The user's program ships as *code*, not *data*. This is the entire
point of the fork.

> Honesty note: "no runtime" in the literal sense is impossible for any dynamic
> language — `malloc`, a GC, hash tables, and metatable dispatch must live
> somewhere. They live in the statically-linked runtime *library*, precisely as
> libc lives inside a GCC binary. That is **not** a shim; a shim is an interpreter
> that re-reads an embedded program at startup, which is exactly what we delete.

---

## 4. Repository layout & fork manifest

The grounded, file-level copy manifest is in
[`docs/fork-manifest.md`](docs/fork-manifest.md) (generated from the v1 audit).
Summary of actions:

```
LuaC/
  lua-5.4/src/          COPY AS-IS  — upstream Lua front-end + core data structures
  src/
    compiler/           COPY AS-IS  — front-end driver: lua_compile, resolve (require-scan),
                                       paths, diag.  These are reused verbatim.
    compiler/pe_link.c  COPY+REWRITE — becomes the native linker (see §12); drop blob path
    ffi/                COPY AS-IS  — the whole Windows FFI; becomes a runtime lib + a barrier
    runtime/            COPY+STRIP  — keep coro, runtime_init; DROP embedded_loader, blob_reader
    jit/emit_x64.*      COPY+ADAPT  → src/codegen/x64_emit.*  (add RIP-relative + relocations)
    jit/regalloc.*      COPY+ADAPT  → src/codegen/regalloc.*
    jit/runtime.*       COPY AS-IS  → the Rt_* helper layer becomes part of the runtime lib
    jit/codegen.c       REFERENCE   — study its per-opcode lowering; do NOT copy (IR-driven now)
    jit/exec_mem.*      DROP        — replaced by PE section emission + relocations
    jit/dispatch.*      DROP        — no on-demand compilation; whole program compiled at once

    ir/        NEW   — bytecode → SSA IR (ir.h, ir.c, lift.h, lift.c)         [skeletons present]
    opt/       NEW   — optimization passes (passes.h + one .c per pass)        [skeleton present]
    codegen/   NEW   — IR → relocatable x64 + unwind info (codegen.h/.c)       [skeleton present]
    link/      NEW   — standard PE writer (pe_write.h/.c)                       [skeleton present]
    driver/    NEW   — aotc.exe: frontend → lift → opt → codegen → link        [skeleton present]

  src/runtime/packages/  COPY AS-IS — ~195 packages; pure-Lua ones get AOT-compiled into the program
  build/                 COPY+ADAPT — Makefile.luac: build runtime lib once, codegen user objs, link
  tests/                 COPY+ADAPT — reuse the 5-layer suite; ADD the AOT-vs-interpreter differential
  docs/                  fork-manifest.md, this PROMPT.md
```

**DROPPED entirely** (blob model): `src/compiler/blob.c`,
`src/common/blob_format.h`, `src/runtime/embedded_loader.{c,h}`,
`src/runtime/blob_reader.{c,h}`. They are archived (not deleted) as
`*_v1_archive.*` so their logic stays readable, but nothing links them.

---

## 5. End-to-end pipeline

```
 root.lua + bundled packages
        │
        ▼
 [front-end]  src/compiler/lua_compile.c : LuaCompile_File  → Lua 5.4 bytecode (Proto trees)
 [resolve]    src/compiler/resolve.c     : Resolve_Walk     → CLOSED set of reachable modules
        │     (this is what makes the world closed; it already exists in v1, reused verbatim)
        ▼
 [lift]       src/ir/lift.c   : bytecode → per-function SSA IR + whole-program call graph
        │     (faithful, generic, boxed — NO optimization here)
        ▼
 [opt]        src/opt/*.c     : analyses → M0 cleanup → M1 local → M2 interprocedural → M3 memory
        │     (sound-conservative; FFI edges & LC_T_ANY values are cut points)
        ▼
 [codegen]    src/codegen/codegen.c : optimized IR → relocatable x64 + .pdata/.xdata + GC stackmaps
        │     (reuses emit_x64 encoder + regalloc; typed ops inline, generic ops call Rt_*/luaV_*)
        ▼
 [link]       src/link/pe_write.c : user code objs + runtime library → standard PE (no blob)
        │
        ▼
 a normal Windows x64 .exe / .dll
```

The driver wiring this is `src/driver/` (entry `lc_drive`, see
[`src/driver/aotc.h`](src/driver/aotc.h)). It mirrors v1's `src/compiler/main.c`
but swaps "embed blob" for "codegen + native link."

---

## 6. Front-end (reused verbatim)

**Do not modify the front-end.** Copy as-is and call into it.

- **Compile entry:** `LuaCompile_File` (`src/compiler/lua_compile.c:44-80`) wraps
  `luaL_loadfile` + `lua_dump`; returns malloc'd bytecode in `Result->Bytes`.
- **Closed-world discovery:** `Resolve_Walk`
  (`src/compiler/resolve.c:288-428`) statically scans bytecode for
  `require"literal"` (a `GETTABUP` of `_ENV.require` followed by `LOADK`),
  recursively compiles every reachable module, registers builtin packages for
  tree-shaking, and returns `RESOLVE_RESULT_T` (`src/compiler/resolve.h:22-37`):
  `Modules[]` (entry is `Modules[0]`), `Count`, `WarnCount`, `BuiltinPackages[]`.
  - **The whole-program boundary is exactly `RESOLVE_RESULT_T.Modules` + the
    builtin packages it pulls in.** Dynamic `require(variable)` currently only
    increments `WarnCount`; in LuaC it must become a **hard error** unless the
    target is statically resolvable (closed-world requirement).
- **The IR consumes `Proto`** (`lua-5.4/src/lobject.h:550-573`): `code`
  (`Instruction[]`), `k` (constant `TValue[]`), `p` (nested `Proto[]`),
  `upvalues` (`Upvaldesc[]`), `numparams`, `is_vararg`, `maxstacksize`. Decode
  instructions with the `lopcodes.h` macros (`GET_OPCODE`, `GETARG_A/B/C/Bx/sBx`).
- **Diagnostics:** reuse `Diag_*` (`src/compiler/diag.c`) for gcc/clang-style
  errors. New backend errors (e.g., "load() not permitted in AOT") go through it.

### Lift gotchas (the differential test *will* catch these)

1. **`_ENV` / globals.** Every function has implicit upvalue `_ENV`. A global read
   `print` is `GETTABUP A B C` with `B`=upvalue 0 (`_ENV`), `C`=const `"print"`.
   Lower globals as `_ENV` table ops. Whole-program analysis may later prove
   `_ENV` fields constant and devirtualize; until then treat as a normal table.
2. **Varargs.** `is_vararg` functions use `OP_VARARG`; manage the vararg count
   separately. `LUA_MULTRET` propagation must match the interpreter exactly.
3. **Int vs float constants.** `OP_LOADI` (immediate int), `OP_LOADF` (float),
   `OP_LOADK` (any `TValue` from `k[]`). Constant folding is valid only with
   matching subtypes. Preserve 5.4 int/float rules precisely.
4. **`OP_LOADKX` + `OP_EXTRAARG` fusion** and `OP_NEWTABLE` size hints: fuse the
   instruction pairs when lifting.
5. **Closures.** `OP_CLOSURE A Bx` builds a closure from nested `p[Bx]`; emit code
   to bind upvalues from the enclosing frame at the closure-creation point. Nested
   Protos are compile-time references, not runtime allocations.
6. **`OP_MMBIN` metamethod fallbacks.** Arithmetic ops are followed by `OP_MMBIN`;
   if both operands are provably numbers, the optimizer drops the metamethod path,
   otherwise the generic helper handles it.
7. **To-be-closed variables** (`OP_TBC`, `__close`) and their scope-exit ordering.
8. **String interning / pointer stability.** Intern every literal via
   `luaS_new`/`luaS_newlstr`; short-string pointer equality is the basis of field
   lookup. Bake interned `TString*` constants into `.rdata`.

---

## 7. The IR (see [`src/ir/ir.h`](src/ir/ir.h))

SSA form. One `LcModule` for the whole closed program; one `LcFunc` per Proto;
`LcBlock` CFG; `LcInst` in SSA with explicit `phi`. Read `ir.h` — it is the
normative interface. Key elements:

- **Type lattice** `LcType` (`LC_T_BOTTOM … LC_T_ANY`). Carries: `known_proto`
  (for monomorphic calls → direct call/inline), `table_shape` (for field-offset
  specialization & dead-field elimination), and constant value for int/float.
  `LC_T_ANY` is the boxed `TValue` fallback — always correct, never optimized.
  Unboxing is legal **only** for `LC_T_INT`/`LC_T_FLT`/`LC_T_BOOL`.
- **Opcodes** `LcOpcode`: each dynamic op has a **generic** form (e.g.
  `LC_OP_ARITH`, `LC_OP_TABLE_GET`, `LC_OP_CALL`) and a **typed** form the
  optimizer rewrites it into when operand types are proven (`LC_OP_IARITH`,
  `LC_OP_RAWGET`, `LC_OP_CALL_DIRECT`). Codegen lowers generic → `Rt_*`/`luaV_*`
  helper calls (identical to the interpreter), typed → inline machine code.
- **Effects** `LcEffect` bitset (`PURE`, `READS_HEAP`, `WRITES_HEAP`, `MAY_THROW`,
  `CALLS_LUA`, `FFI_BARRIER`). Drives DCE, code motion, barrier placement, and
  where analyses must stop.

The **TValue representation** the lattice mirrors (`lua-5.4/src/lobject.h:49-69`):
tagged union `{ Value value_; lu_byte tt_; }`, `Value` is an 8-byte union (`gc`,
`p`, `f`, `i`=`lua_Integer`=`long long`, `n`=`lua_Number`=`double`). Tag bits 0-3
= base type, 4-5 = variant (`LUA_VNUMINT` vs `LUA_VNUMFLT`, `LUA_VSHRSTR` vs
`LUA_VLNGSTR`), bit 6 = collectable. **The tag (`tt_`) and value are separate
fields; never write one without the other** — use `setobj`-style stores, and use
**8-bit** CMP for tag checks (the 7 padding bytes after `tt_` are uninitialized;
a 32-bit compare reads garbage — see codegen gotcha in §11).

---

## 8. Lift: bytecode → IR

`src/ir/lift.c`. Per function: rebuild the CFG from bytecode jump targets, run
standard SSA construction (dominance-frontier phi insertion) over Lua register
slots (Lua bytecode is register-based), then map each opcode to its **generic** IR
op. No optimization here — fidelity only. The full opcode→IR table lives in
[`src/ir/lift.h`](src/ir/lift.h); representative mappings:

| Bytecode | IR (generic) |
|---|---|
| `OP_ADD/SUB/MUL/DIV/MOD/IDIV/POW` | `LC_OP_ARITH` (+ sub-op) |
| `OP_BAND/BOR/BXOR/SHL/SHR` | `LC_OP_BITWISE` |
| `OP_EQ/LT/LE` (+ `OP_EQK/EQI/LTI/…`) | `LC_OP_CMP` |
| `OP_GETTABLE/GETFIELD/GETI` | `LC_OP_TABLE_GET` |
| `OP_SETTABLE/SETFIELD/SETI` | `LC_OP_TABLE_SET` |
| `OP_GETUPVAL/SETUPVAL` | `LC_OP_UPVAL_GET/SET` |
| `OP_GETTABUP _ENV` / `OP_SETTABUP` | `LC_OP_GLOBAL_GET/SET` |
| `OP_NEWTABLE` (+EXTRAARG) | `LC_OP_NEWTABLE` (size hints) |
| `OP_CALL/TAILCALL` | `LC_OP_CALL/TAILCALL` (callee resolved in opt) |
| `OP_CLOSURE` | `LC_OP_CLOSURE` (records captured upvalues) |
| `OP_FORPREP/FORLOOP` | `LC_OP_FORPREP_*/FORLOOP_*` (subtype refined in opt) |
| `OP_TFORCALL/TFORLOOP` | `LC_OP_TFORCALL/TFORLOOP` |
| `OP_CONCAT` | `LC_OP_CONCAT` |
| `OP_LEN/UNM/NOT/BNOT` | `LC_OP_LEN/UNM/NOT/…` |
| `OP_RETURN/RETURN0/RETURN1` | `LC_OP_RETURN` |
| `OP_VARARG` | `LC_OP_VARARG` |

Record call-graph edges as you lift `LC_OP_CALL`; mark any call whose callee is an
FFI cdata / C function as an **`LC_FX_FFI_BARRIER`** edge (sentinel callee in the
call graph). `pcall`/`xpcall` regions become `LC_OP_PCALL_BEGIN/END` pairs (they
delimit `.pdata` unwind scopes and constrain escape analysis).

---

## 9. The optimizer (see [`src/opt/passes.h`](src/opt/passes.h))

**Governing principle — sound-conservative.** In a closed world with no `load`,
analysis can be provably correct. Every pass fires only when the whole-program
proof holds; otherwise the value stays `LC_T_ANY` and codegen emits the generic
dynamic path. There is **no deopt** and **no guard-and-fallback** — if we can't
prove it, we don't specialize it. This is what keeps 100% fidelity.

**Pipeline order:** analyses → M0 → M1 (local) → M2 (interprocedural) → M3
(memory) → lowering-prep. Run `lc_module_verify` between passes in debug builds.

### Analyses
- `lc_analyze_dominators`, `lc_analyze_liveness` (per function)
- `lc_build_callgraph` (module): complete except FFI/unknown sentinels

### M0 — faithful baseline (correctness; removes only interp + dispatch overhead)
- `lc_pass_mem2reg` (registers→SSA), `lc_pass_dce` (effect-aware),
  `lc_pass_const_fold`. After M0 every op is still generic/boxed but native.

### M1 — per-function (local) specialization
- `lc_pass_local_typeinfer` — intra-function lattice fixpoint.
- `lc_pass_specialize_arith` — `ARITH`→`IARITH`/`FARITH`; drop `MMBIN` path when
  both operands proven numbers. **Reproduce 5.4 arithmetic exactly**: int+int→int
  (wrapping), any-float→float, `//` floor div, `%` per `luaV_mod`/`luaV_modf`,
  bitwise integer-only, string→number coercion via `luaV_tonumber_`.
- `lc_pass_unbox_locals` — keep proven scalars in raw GPR/XMM; re-box on writes to
  `TValue` slots or escaping uses.
- `lc_pass_devirt_local` — known local/closure callee → `LC_OP_CALL_DIRECT`.
- `lc_pass_raw_table` — `TABLE_GET/SET`→`RAWGET/RAWSET` when the table provably has
  no relevant metamethod (see metatable soundness below).
- `lc_pass_inline_small` — inline tiny leaf callees.

### M2 — whole-program (interprocedural)
- `lc_pass_ip_typeprop` — propagate arg/return types across the call graph to a
  fixpoint; FFI edges and `LC_T_ANY` are cut points (contribute `ANY`).
- `lc_pass_monomorphize` — clone polymorphic functions per concrete arg-type
  context; keep a generic fallback clone for `ANY` call sites.
- `lc_pass_ip_devirt` — whole-program devirtualization (unique-callee → direct).
- `lc_pass_dead_global` — drop unused globals/fields/functions.

### M3 — memory optimization
- `lc_pass_escape` — escape analysis (coroutine capture, `pcall`, FFI all force
  escape).
- `lc_pass_scalar_replace` — explode non-escaping short-lived tables into scalars.
- `lc_pass_barrier_elide` — drop GC write-barriers proven unnecessary (see below).

### Lowering-prep (always)
- `lc_pass_lower` — canonicalize to codegen-ready ops.
- `lc_pass_safepoints` — insert GC safepoints on loop back-edges + before
  throw-capable ops.

### Soundness rules you must not violate
- **Metatables are dynamic.** `setmetatable` can add `__index`/`__newindex` at
  runtime. Only emit `RAWGET/RAWSET` (or skip a metamethod path) when
  whole-program analysis proves no metatable with that event can reach this object
  — otherwise keep the generic `luaT_*` dispatch. When unsure, **don't specialize.**
- **GC write barriers are mandatory.** Any store of a collectable value into a
  table/userdata/closure-upvalue must call `luaC_barrier`/`luaC_barrierback`
  (`lgc.h:179-186`) unless `lc_pass_barrier_elide` *proved* no black→white edge can
  form. Missing a barrier is a silent heap-corruption bug the differential test may
  not catch — treat barrier elision as the highest-risk pass and gate it behind a
  proof, defaulting to "emit the barrier."
- **FFI edges are total barriers.** See §13.
- **NaN, `-0.0`, int/float equality** follow `luaV_equalobj`/`luaV_lessthan` — do
  not lower `==`/`<` to raw machine compares unless both operands are proven the
  same unboxed numeric subtype *and* you replicate the IEEE/Lua edge cases.

---

## 10. The runtime library (statically linked — the "libc")

LuaC links the v1 runtime core **unchanged** as a static library, minus the
interpreter loop. Generated native code *calls into* these. Exact surface
(file:line into v1):

**Tables** (`ltable.h`): `luaH_new`, `luaH_get`, `luaH_set`, `luaH_getint`,
`luaH_setint`, `luaH_getshortstr` (interned-string fast path).
**Strings** (`lstring.h`): `luaS_new`, `luaS_newlstr` (intern at runtime;
literals pre-interned into `.rdata`).
**Metamethods** (`ltm.h`): `luaT_gettm`, `luaT_gettmbyobj`, `luaT_callTM`
(generic `__index`/`__newindex`/operator dispatch).
**GC barriers** (`lgc.h:179-186`): `luaC_barrier`, `luaC_barrierback`, impls
`luaC_barrier_`/`luaC_barrierback_` (`lgc.c:208-240`). **Critical — call from
generated stores.**
**Arith/compare/coerce semantics** (`lvm.h`, kept from a *stripped* `lvm.c`):
`luaV_tonumber_`, `luaV_tointeger`, `luaV_tointegerns`, `luaV_idiv`, `luaV_mod`,
`luaV_modf`, `luaV_shiftl`, `luaV_lessthan`, `luaV_lessequal`, `luaV_equalobj`,
`luaV_concat`, `luaV_objlen`, `luaV_finishget`, `luaV_finishset`.
**Calls/errors** (`ldo.h`): `luaD_call`, `luaD_callnoyield`, `luaD_throw`.
**Closures/upvalues** (`lfunc.h`): `luaF_newLclosure`, `luaF_findupval`,
`luaF_closeupval`.
**Slow-path helpers** (`src/jit/runtime.h` → `src/runtime/lua_rt.h`, copy as-is):
the `Rt_*` family — `Rt_AddSlow`, `Rt_Call`, `Rt_GetI`, `Rt_SetField`,
`Rt_GetField`, `Rt_GetTable`, `Rt_SetTable`, `Rt_Len`, `Rt_Concat`,
`Rt_ForPrep`/`Rt_ForLoop`, `Rt_GetUpval`/`Rt_SetUpval`, `Rt_NewClosure`, vararg/
iterator ops. Win64 ABI: `RCX`=`lua_State*`, `RDX`/`R8`/`R9`=operands, `RAX`=ret.
**Coroutines** (`src/runtime/coro.h`): `Coro_InitThreadAsFiber` (call before first
`coroutine.create` per OS thread), `Coro_OpenLib`. Windows fibers; 1 MiB default
fiber stack.

**STRIP from `lvm.c`** (`copy-and-strip` → `lvm_semantics.c`): the interpreter
loop `luaV_execute` and the opcode dispatch. Keep all the `luaV_*` semantic
helpers above. The stub `luaV_execute` may remain for ABI/link but is never
called. **DROP** `lundump`-driven loading paths from the output (no bytecode is
loaded at runtime).

### Runtime gotchas (from v1 audit — preserve exactly)
- Tag/value atomicity; 8-bit tag compares; string interning for pointer-equality
  field lookup; `__index`/`__newindex` chains bounded by `MAXTAGLOOP=2000`
  (`lvm.c:49`); weak tables; finalizer (`__gc`) re-entrancy during any GC phase;
  `pairs` iteration order is not stable across GC/mutation; upvalue closing on
  scope exit (`luaF_closeupval`) or you get use-after-free; `luaV_concat` may
  allocate/GC so keep stack roots valid across it; generational vs incremental GC
  barrier rules.

---

## 11. Codegen: IR → relocatable x64 (see [`src/codegen/codegen.h`](src/codegen/codegen.h))

**Reuse** from v1's JIT (copy + adapt):
- `emit_x64.*` (`src/jit/emit_x64.h`) — the instruction encoder: `EmitX64_*`
  (MOV imm64/mem/reg, CMP, ADD, conditional/uncond branches with rel8/rel32
  placeholder + `EmitX64_PatchRel8/32`, PUSH/POP, SUB/ADD RSP, indirect CALL,
  SSE2 scalar-double). Correct ModRM/SIB/REX handling already done.
- `regalloc.*` (`src/jit/regalloc.h`) — `RegAlloc_Analyse` assigns the hottest Lua
  registers to callee-saved GPRs (R12–R15, RSI) as cache slots; `RegAlloc_IsCached`
  drives load/store selection.

**New for AOT** (the v1 JIT never needed these — this is the bulk of the work):
1. **Relocations instead of baked imm64.** v1 emits `MOV RAX, imm64=&Rt_AddSlow;
   CALL RAX` (`emit_x64` `EmitX64_CallAbs`). LuaC emits the same bytes but records
   an `LcReloc{kind=HELPER, offset, target}` and leaves a placeholder; the linker
   patches it. Every helper call, every direct call to another LuaC function, and
   every constant-pool reference becomes a reloc.
2. **RIP-relative addressing** for `.rdata` constants (`LEA reg, [RIP+disp32]`)
   instead of absolute immediates — position-independent code.
3. **`.pdata`/`.xdata` unwind info.** Win64 requires `UNWIND_INFO` for any function
   that establishes a frame, so `pcall` longjmp, FFI faults, and coroutine switches
   unwind correctly. Emit a `RUNTIME_FUNCTION` + `UNWIND_INFO` per function
   describing the prologue (which callee-saved regs pushed, frame size).
4. **GC stack maps + safepoints.** The interpreter knew the stack layout; native
   code must describe, at each safepoint, which frame slots hold live references,
   so the collector can mark them. Emit a side-table (not in `.text`).

**Lowering:** typed IR ops → inline instructions; generic IR ops → `CALL` to the
`Rt_*`/`luaV_*` helper (semantics identical to the interpreter). Study v1's
`codegen.c` `EmitBinArith` (float-fastpath / int-fastpath / slow-helper triple
branch) as the *template*, but use the IR's proven type to emit only the needed
arm.

### Codegen gotchas (audited from v1 — these crash if wrong)
- **8-bit tag CMP**, never 32-bit (padding after `tt_` is uninitialized).
- **Shadow space**: reserve 32 bytes (`SUB RSP,0x20`) before any call; mandatory
  in Win64.
- **RSP alignment**: `RSP % 16 == 0` at the point of a `CALL` into a helper/C.
- **Reload `RDI` + cache regs after stack-relocating helpers.** Helpers that may
  grow the Lua stack (anything that re-enters Lua) invalidate the base pointer and
  cached registers; v1 emits `EmitReloadRdiAndCache`. Leaf helpers (pure C, no Lua
  re-entry) can skip the reload — closed-world analysis can classify them.
- **Write-through coherency**: cache reg and memory slot kept in sync; memory is
  source of truth after a reload.
- **`savedpc` updates** before throw-capable ops for `luaG_traceback` line
  accuracy (`codegen.c:253-261`).
- **Branch displacement sizing** (rel8 vs rel32); compute distances after lowering,
  then patch.
- **RBP/R13 and RSP/R12 addressing special-cases** (mod-bias and SIB) — already
  handled in `emit_x64`; preserve when adapting.

---

## 12. PE emission (see [`src/link/pe_write.h`](src/link/pe_write.h))

v1's `pe_link.c` (`PeLink_Bundle`, `1258-1549`) embeds the bytecode blob as a C
const array (`MakeBlobCObject`, `341-397`) and links `blob.o + runtime.a +
liblua54.a` with MinGW. **LuaC replaces the blob path** and links *generated
native code objects* instead.

**Two viable strategies** (skeleton targets A; keep B as a fallback):

- **A — self-contained writer.** Lay out sections, resolve `LcReloc`s against the
  runtime library symbol table, emit `.text/.rdata/.data/.bss/.pdata/.xdata/
  .reloc/.idata` directly. No external toolchain. Most in the spirit of decision
  #2 (fresh backend).
- **B — emit COFF + delegate to MinGW `ld`.** Emit one COFF object per function
  (`lc_emit_coff`) and let the MinGW `ld` already in the toolchain link against
  the prebuilt runtime lib. Less linker code; gets `.pdata`/`.reloc`/import-table
  handling for free. Good bring-up path; can graduate to A later.

**Keep from `pe_link.c`** (copy-and-strip → `pe_link_v2.c`):
`ComposeObjectCompileFlags`, `ComposeLinkLineFlags`, `PostLinkPatchPE`,
`VerifyPeCharacteristics`. **Rewrite** `LinkBlobWithRuntime` → link user/native +
package objects + `runtime-embedded.a`. **Remove** `MakeBlobCObject` and all
blob/`PE_OUT_OBJ`/`PE_OUT_LIB`/`PE_OUT_BLOB` paths (LuaC emits only `EXE`/`DLL`).
**`PostLinkPatchPE` must now preserve `.pdata`/`.xdata`** (load-bearing for
unwinding — do not randomize/strip them).

**Native DLL embedding** (`native_loader.c`) is retained/adapted for FFI packages
that ship a real DLL: keep `Native_Bootstrap` + SHA-256-verified extraction; drop
the blob-reader coupling.

**Build:** `build/Makefile.luac` — compile the runtime + `liblua54` **once** into
`runtime-embedded.a` (reuse `EMBEDDED_RT_CFLAGS`), then per program: front-end →
lift → opt → codegen → object(s) → link. Packages build to **native** objects
(`packages_native.mk`) instead of embedded-bytecode `.o`s.

---

## 13. FFI as a conservative optimization barrier

The whole FFI (`src/ffi/*`) is copied as-is and linked as a runtime lib. But every
FFI **edge** stops the optimizer cold, because C can re-enter Lua (callbacks),
hold references, and mutate arbitrary state.

- **`ffi.C.sym(...)` calls** lower to `LC_OP_CALL_FFI` → `Ffi_GenericCall`
  (`src/ffi/ffi_call.h:25`). Across this node: **stop** type propagation (args/
  return untyped to Lua), **stop** escape analysis (assume every globally/stack-
  reachable Lua object may be read or mutated), **stop** devirtualization (the
  thunk address from `Ffi_GetSignatureThunk` is a runtime value; the C pointer may
  be hooked), **stop** CSE/code-motion across it (assume full clobber). Mark the
  node `LC_FX_FFI_BARRIER | LC_FX_WRITES_HEAP | LC_FX_CALLS_LUA | LC_FX_MAY_THROW`.
- **Callbacks** (`Ffi_AllocCallback` + `Callback_Dispatch`): treat the dispatch as
  an external re-entry with unknown Lua state — every reference may be mutated/
  collected between call and return.
- **Symbol addresses are not compile-time constants** (`GetProcAddress`,
  per-namespace cache) — never emit a relocation to a C symbol resolved at runtime.
- **Variadic C functions are rejected** (`ffi_call.c:38-41`); surface as a compile
  or runtime error, matching v1.
- The runtime lib must export: `Ffi_GenericCall`, `Marshal_LuaToC`,
  `Marshal_CToLua`, `Ffi_GetSignatureThunk`, `Ffi_AllocCallback`,
  `Callback_Dispatch`, `Ffi_ResolveSymbol`, `Ctype_Lookup`, `FfiNewCData`,
  `Cdata_Storage`, plus the cdata metamethods. (Thunks/stubs are still generated
  into an executable slab at runtime — that's the FFI's own mechanism, not the
  user program's code; it does not reintroduce a bytecode VM.)

Preserve the audited FFI gotchas (RSP alignment in thunks, the >4-arg callback
stack-slot fix at `ffi_callback.c:140-159`, float-return `movq` reinterpret,
borrowed-cdata parent lifetime, forward-decl in-place completion, atomics
fallback for non-exported `Interlocked*`).

---

## 14. Packages & testing

**Packages.** The ~195 packages under `src/runtime/packages/` are copied as-is.
Pure-Lua packages (e.g. `json`, `base64`) are part of the closed world and get
**AOT-compiled into the program** like user code. FFI-wrapper packages (e.g.
`windows`) cross the FFI barrier. Package discovery/bundling
(`build/gen/packages.mk`, `_builtin_packages.h`, `tools/build-package-catalog.lua`)
is adapted to produce **native** package objects (`packages_native.mk`) rather
than embedded-bytecode objects. Packages needing an absent external DLL still
`SKIP` at test time.

**Testing — reuse the 5-layer auto-discovered suite** (CLAUDE.md is authoritative)
and add the killer layer for an optimizing compiler:

- **C unit** (`tests/unit/test_*.c`): add tests for the IR builder, each opt pass
  (assert the lattice/rewrite), the x64 emitter relocations, the PE writer
  sections, unwind-info correctness.
- **Lua behavioral** (`tests/lua/*.lua`): run under LuaC-compiled native.
- **Package** (`tests/packages/test_*.lua`): round-trip each builtin package.
- **Differential — the AOT oracle** (`tests/differential/*.lua`): a deterministic
  script that *prints*; the runner compiles it with **LuaC (native)** and runs the
  same script under **v1 `clua-interp.exe -i` (interpreter)** and **diffs stdout**. This
  is how you prove the optimizing AOT preserves Lua 5.4 semantics. Every optimizer
  bug surfaces here. Make this the gate for every milestone. v1 is the frozen
  oracle — never "fix" a differential failure by changing v1.
- **XFAIL discipline** (CLAUDE.md): a test asserts *correct* behavior; a known
  unfixed bug is marked `XFAIL`, not worked around, so it flips to `XPASS` when
  fixed.

`build\run-tests.bat` builds the products and runs every layer with one tally.

---

## 15. Phased milestones (honest effort)

This is a months-long compiler project. Deliver in strict order; each milestone is
independently testable against the differential oracle. **Do not start a milestone
before the prior one is green across the full suite.**

- **M0 — Faithful native baseline.** Front-end + lift + *generic* codegen (every op
  → `Rt_*`/`luaV_*` helper, all boxed, no type opt) + native PE link. No
  interpreter loop in the output. Differential-green on `tests/lua` + a handful of
  new differential scripts (arithmetic, tables, closures, string ops, numeric/
  generic for, `pcall`, simple coroutines, one pure-Lua package). **This proves the
  whole pipeline end-to-end.** Biggest, highest-value milestone.
- **M1 — Local optimization.** SSA cleanup (mem2reg/DCE/const-fold) + per-function
  type inference, scalar unboxing, arith specialization, raw-table fast paths,
  small-callee inlining. Differential-green unchanged; measurable speedup on
  numeric loops. Add per-pass unit tests.
- **M2 — Whole-program.** Interprocedural type propagation, monomorphization,
  whole-program devirtualization, dead-global/function elimination. The call graph
  + FFI barriers must be airtight. Differential-green unchanged.
- **M3 — Memory optimization.** Escape analysis, scalar replacement of
  non-escaping tables, GC-barrier elision (highest-risk; gate behind proofs).
  Differential-green unchanged; reduced allocation/GC pressure.
- **M4 — Polish.** Debug info (`.pdb`/DWARF), `-O` levels, size tuning,
  section-name options, DLL output, broader package coverage, the full ~195-package
  test sweep.

Performance is a non-goal until M0 is correct. "It runs fast but the differential
test is red" is a failure.

---

## 16. Definition of done (per change) & working agreement

- Every feature/pass ships with a test in the matching layer; run
  `build\run-tests.bat` and report the real tally before calling it done
  (CLAUDE.md testing discipline).
- The differential oracle is the arbiter of correctness; a red diff blocks merge.
- Known, unfixed bugs are `XFAIL`-marked and visible, never hidden.
- Don't modify the front-end or the runtime *semantics*; if you think you must,
  you're probably about to break fidelity — stop and reconsider.
- Sound-conservative always wins ties: when you can't prove an optimization, emit
  the generic dynamic path. A slow correct binary beats a fast wrong one.

---

### Appendix A — provenance

This spec was grounded in a file-level audit of the codebase (front-end,
runtime core, FFI, JIT/codegen, PE link,
packages/tests). The raw grounded manifest (every copy/strip/drop action, every
key interface with `file:line`, and the per-subsystem gotcha lists) is in
[`docs/fork-manifest.md`](docs/fork-manifest.md). When a claim here is terse, that
file has the detail.
