# LuaC M0 — Faithful Native Baseline: Vertical-Slice Design

**Status:** Approved design (2026-06-09). Next step: implementation plan (`writing-plans`).
**Scope:** Milestone **M0** only — a faithful, *unoptimized* AOT path from a `.lua` file
to a standard Windows x64 PE that passes the differential oracle. No type inference,
no unboxing, no interprocedural analysis (those are M1–M3).

This spec is the grounded, decision-resolved companion to [`PROMPT.md`](../../../PROMPT.md)
§5–§15. Where PROMPT.md states the ideal, this records what is *actually* in the tree
(verified 2026-06-09) and the two architecture decisions taken for M0.

---

## 1. Goal & definition of done

Lower **every** Lua 5.4 bytecode op to its **generic, boxed** runtime-helper form
(`Rt_*` / `luaV_*`), emit it as **native x64 in `.text`** (no interpreter loop, no
JIT-at-runtime, no bytecode blob), link a **standard PE**, and match `luavm.exe -i`
stdout exactly on the M0 differential set.

**Done when:** `aotc.exe foo.lua -o foo.exe` produces a PE that is differential-green on:
`print` epsilon → arithmetic → tables → closures → string ops → numeric `for` →
generic `for` → `pcall` → a simple coroutine → one pure-Lua package; plus C-unit tests
for the COFF writer and the unwind blob. Performance is explicitly a non-goal.

---

## 2. Locked decisions

Inherited from PROMPT.md §2 (closed-world pure AOT; fresh backend reusing only
`emit_x64`+`regalloc`; 100% fidelity via sound-conservative; v1 frozen as oracle),
**plus** the two M0 decisions taken on 2026-06-09:

| # | Decision | Rationale |
|---|----------|-----------|
| M0-A | **Memory-form IR for M0; defer SSA to M1.** Lift produces a non-SSA IR (Lua locals as frame slots; each op carries its bytecode operands). `lc_pass_mem2reg` (dominance-frontier SSA construction) is implemented at **M1**, where the optimizer consumes it. | The boxed M0 baseline gains nothing from SSA — every `Rt_*` helper operates on the Lua stack frame by register index, exactly like v1's proven `codegen.c`. Forcing SSA now is complex, bug-prone work with zero M0 benefit that the differential test can't even exercise. |
| M0-B | **Strategy B for PE emission:** codegen emits raw x64 + an `LcReloc` table; a small COFF object writer wraps each function; **MinGW `ld`** links against the existing runtime archives. | `.pdata`/`.xdata`/`.reloc`/`.idata` come out correct *for free* from `ld` (Win64 unwind info is mandatory and very error-prone by hand). ~50 LOC of link plumbing + a ~200–400 LOC COFF writer, vs ~500–1000 LOC + high risk for a hand-written PE. PROMPT.md §12 explicitly endorses "bring up on B." Strategy A (self-contained PE writer) is deferred to M4. |

---

## 3. Ground truth (verified 2026-06-09)

What the tree actually contains today (the fork-manifest's strip/copy actions are
**planned, not yet performed**):

**Reusable as-is:**
- **Front-end** — `Resolve_Walk` (`src/compiler/resolve.c:288-428`) → `RESOLVE_RESULT_T`
  (`resolve.h:22-37`): `Modules[0]`=entry (named `"main"`), each module carries **dumped
  bytecode** `Bytes`/`BytesLen` (not a `Proto*`), plus `BuiltinPackages[]` and `WarnCount`.
  Reused verbatim.
- **Runtime archives already build and exist:** `build/bin/runtime-embedded.a` (~226 KB)
  and `build/bin/liblua54-embedded.a` (~414 KB). They export the full `Rt_*` family
  (~71 helpers, Win64 ABI `RCX=L, RDX/R8/R9=A/B/C`, all taking register/constant
  **indices**) plus `luaV_*`/`luaH_*`/`luaT_*`/`luaC_*`/`luaF_*`/`luaD_*`. **M0 links
  against these unchanged.** They are the *full v1 runtime* (interpreter + JIT + FFI +
  coro); the unused interpreter/JIT code is dead in an AOT binary and can be
  `--gc-sections`-stripped later — it does **not** reintroduce a VM (no bytecode is
  shipped or executed).
- **Codegen substrate** — `src/jit/emit_x64.{h,c}` (~95% reusable; growable byte buffer,
  rel8/rel32 placeholders + patchers, `EmitX64_CallAbs` = `MOV RAX,imm64; CALL RAX`) and
  `src/jit/regalloc.{h,c}` (use-count cache-slot allocation over Proto registers).
- **Codegen template (study, don't copy)** — `src/jit/codegen.c` (~3165 lines): the exact
  frame ABI (`RBX`=L, `RDI`=frame base `ci->func+16`, Lua reg N at `[RDI+N*16]`, tag at
  `+8`, **8-bit tag compares**), prologue/epilogue (push `RDI,RBX,R12-R15,RSI`; `SUB
  RSP,0x20`; 96-byte frame), `EmitReloadRdiAndCache`, `savedpc` writes before
  throw-capable ops.
- **Link path** — `pe_link.c`'s `LinkBlobWithRuntime` + `ComposeObjectCompileFlags` +
  `ComposeLinkLineFlags` + `PostLinkPatchPE` + `VerifyPeCharacteristics` are reusable
  almost verbatim.

**Stub / not-yet-done (M0 must build):**
- `src/ir/{ir.c,lift.c}`, `src/opt/passes.c`, `src/codegen/codegen.c`, `src/link/pe_write.c`,
  `src/driver/main.c` — all stubs (`lc_module_new`/`lc_module_free`/`lc_type_is_unboxable`
  and the `lc_optimize` dispatcher loop are the only real code).
- `lvm.c` still contains `luaV_execute` (no `lvm_semantics.c` yet) — **not needed for M0**
  (we link the existing archive; stripping is an M4 cleanup).
- `emit_x64`/`regalloc` are still only in `src/jit/` — **copy** into `src/codegen/` as
  `x64_emit.*`/`regalloc.*`.
- `Rt_*` still in `src/jit/runtime.{h,c}` — fine; the archive already contains them.
- No `build/Makefile.luac`, no `aotc.exe` target.

**Closed-world gaps in v1 (M0 must close):** `Resolve_Walk` only **warns** (`WarnCount++`,
`resolve.c:104-110`) on dynamic `require(variable)`; it does **not** detect
`load`/`loadstring`/`dofile`/`string.dump` at all. M0 must turn all of these into hard
compile errors.

---

## 4. End-to-end pipeline (`aotc.exe`)

```
argv ─▶ LcDriverOptions
  │
  ▼  Resolve_Walk (reused) ─▶ RESOLVE_RESULT_T          ── closed-world gate ──▶ Diag hard error
  │     Modules[0]=entry; each = dumped bytecode Bytes      (dynamic require / load / dofile / string.dump)
  ▼  luaU_undump(Bytes) per module ─▶ Proto* trees (collect entry + all nested p[] recursively)
  ▼  lc_lift_program(entry, reachable[], n) ─▶ LcModule (memory-form; generic/boxed; NO phi)
  ▼  lc_optimize(cfg{opt_level=0}) ─▶ no-op            (mem2reg/dce/const-fold are real no-ops at M0)
  ▼  lc_codegen(LcModule) ─▶ LcCodeModule              (raw x64 bytes + LcReloc + UNWIND_INFO + ProtoInit per fn)
  ▼  lc_emit_coff(LcCodeModule) ─▶ user.o              (one COFF: .text/.rdata, symbols, relocs)
  ▼  LuacLink(user.o, aot_entry.o, archives, opts) ─▶ MinGW ld ─▶ standard PE
  ▼  differential test: aotc-compiled .exe  vs  luavm.exe -i   (diff stdout)
```

`lc_optimize` runs at `opt_level=0` for M0: the dispatcher is real, every pass is a
correctness-preserving no-op (the value lattice stays `LC_T_ANY`, so codegen always
emits the generic boxed path). M1 turns the passes on.

---

## 5. The crux — constants & Protos at runtime without a bytecode blob

The boxed `Rt_*` helpers recover constants **by index into `P->k[]`** (e.g.
`Rt_GetField(L,A,B,C)` = `R[A]=R[B][K[C]]`), via `ci->func → LClosure → Proto`. So each
compiled function still needs a **live `Proto` at runtime** — but only its *metadata +
constants*, **not** its executable `code[]` (native `.text` replaces that; `code[]` ships
empty/stub). No bytecode is undumped at runtime; `g_LuaBlob` does not exist.

**Model (reuses v1's own JIT-dispatch field):**

1. **Compile time**, codegen emits per function:
   - the native body `luac_fn_<id>` in `.text`;
   - a native **`ProtoInit_<id>()`** that, at startup, reconstructs that `Proto` —
     allocate via `luaF_newproto`; **intern each string constant** with
     `luaS_newlstr` over bytes in `.rdata` (runtime interning is required because
     short-string field lookup is pointer-equality based); populate `k[]` (numbers as
     static `TValue`, strings as the interned `TString*`), `upvalues[]`, and `p[]`
     (pointers to nested Protos); and set the Proto's **native-entry pointer** to
     `&luac_fn_<id>`.
2. **Runtime:** the AOT entry runs every `ProtoInit_*` (children before parents so `p[]`
   links resolve), **registers each `(Proto*, native-entry)` pair into the JIT dispatch
   side-cache**, builds the entry closure over the entry Proto, and calls it.

**Dispatch mechanism (verified 2026-06-09).** v1 dispatch is **not** a field on `Proto`
(`lobject.h:550-573` has none) — it is a process-wide side-cache in `src/jit/dispatch.c`
(`g_Cache[]` + an O(1) `Proto*`-hash), read by `Jit_LookupCached(Proto*) → JIT_FUNC_T`
(`= int(*)(lua_State*)`), which the call path (`Rt_Call`, `runtime.c:87`) already consults
before falling back. **M0 reuses this unchanged**: add one small, semantics-free function
`Jit_RegisterCompiled(Proto*, JIT_FUNC_T)` to `dispatch.c` that inserts an
externally-supplied entry into `g_Cache`/`g_CacheHash` (mirroring the tail of
`Jit_Compile`, minus the codegen). `ProtoInit_*` calls it at startup. No change to the
call path; no JIT present in the output. `AnchorProto`-style GC pinning still applies
(keep Protos alive). **Caveat to fix:** v1 codegen bakes `savedpc = &P->code[pc+1]` as an
absolute pointer (`codegen.c:253-261`); for AOT the Proto is heap-built at startup, so its
`code[]` address isn't a compile-time constant — savedpc must be set runtime-relative (or
via a helper). M0 impact is limited to error-traceback line numbers (stderr), not stdout,
so the differential test tolerates a deferred fix, but the plan tracks it.

---

## 6. Components & responsibilities

| Component | File(s) | Responsibility | Reuse |
|---|---|---|---|
| **Driver** | `src/driver/main.c` + arg parse | mirror v1 `main.c` minus blob; undump modules; run lift→opt→codegen→coff→link; map `LcDriverOptions`→`LcLinkOptions` | v1 `main.c` flow |
| **Closed-world gate** | `src/driver/` (or `resolve` consumer) | reject `WarnCount>0`; scan Protos for global `load`/`loadstring`/`dofile` and `GETFIELD "dump"` on `string` → `Diag_*` hard error | `Diag_*` |
| **IR memory-form** | `src/ir/{ir.h,ir.c,lift.c}` | extend `LcInst` to carry bytecode operands (`bc_a/bc_b/bc_c`, `bc_pc`) for the pre-SSA form; CFG from jump targets; one generic op per bytecode; fuse `LOADKX`/`NEWTABLE`+`EXTRAARG`; record call-graph edges (FFI sentinel callee); `pcall`/`xpcall`→`PCALL_BEGIN/END` | `lopcodes.h` macros |
| **Codegen** | `src/codegen/{x64_emit.*,regalloc.*,codegen.c}` | copy `emit_x64`→`x64_emit`, `regalloc`; per generic op emit `CALL Rt_*/luaV_*` over the `[RDI+N*16]` frame (mirror v1, slow-path arm only); **+1 RIP-relative `LEA` emitter**; record `LcReloc` instead of baking `imm64`; emit per-fn `UNWIND_INFO`; emit `ProtoInit_*` constructors | `emit_x64`, `regalloc`, `codegen.c` as template |
| **COFF writer** | `src/link/coff_write.{h,c}` | emit **one** COFF object for the whole module: `.text`/`.rdata` sections, symbol table (`luac_fn_*` + `ProtoInit_*` defined; `Rt_*`/`luaV_*` external), COFF relocations from `LcReloc` — intra-module calls + `ProtoInit`/`.rdata` refs are local relocs, `Rt_*`/`luaV_*` are external | new |
| **Linker glue** | `src/link/pe_link_v2.c` (strip from `pe_link.c`) | `LuacLink_LinkUserObject(userObj, pkgObjs[], n, out, opts)`: reuse `LinkBlobWithRuntime`/`ComposeLinkLineFlags`; swap `blob.o`→user `.o` + `aot_entry.o`; **preserve `.pdata`/`.xdata`** (no strip/randomize) | `pe_link.c` |
| **AOT entry** | `src/runtime/aot_entry.c` (strip from `runtime_init.c`) | `luaL_newstate` + `luaL_openlibs` + `Coro_OpenLib` + FFI init; run all `ProtoInit_*`; build entry closure; set up its `CallInfo`; invoke native entry under `luaD_rawrunprotected`; install message handler | `runtime_init.c` minus blob/loader |
| **Build** | `build/Makefile.luac` | build `aotc.exe`; per-program: codegen→coff→link against the existing archives; (re)build archives via existing targets | `build/Makefile` |

The `LcCodeModule`/`LcCompiledFunc`/`LcReloc`/`LcLinkOptions`/`LcDriverOptions` shapes
already exist in the headers (`codegen.h`, `pe_write.h`, `aotc.h`) and are honored as-is.

---

## 7. IR memory-form (M0 detail)

`ir.h` is currently strict-SSA (`LcInst.args : LcValue**`, mandatory `LC_OP_PHI`, verifier
checks SSA dominance). **Extension for M0 (small, deliberate, additive):**

- `LcInst` gains a pre-SSA operand carrier: the originating bytecode `A/B/C` (and `Bx/sBx`)
  fields, so codegen can emit `Rt_*` calls directly from decoded ops without SSA values.
- A function/module flag marks IR as **pre-SSA** (`is_ssa = false` after lift). The verifier
  runs in **pre-SSA mode** (skip single-def/dominance/phi-arity checks; still check CFG
  well-formedness, effect consistency, and "no `LC_OP_CALL_FFI` marked PURE").
- `lc_pass_mem2reg` (M1) flips `is_ssa = true`, introducing `LcValue` defs + phis. M0 never
  calls it.

Lift is fidelity-only (no folding/typing). It honors the §6 PROMPT gotchas: `_ENV` is
upvalue 0 → globals lower to `LC_OP_GLOBAL_GET/SET`; int (`LOADI`)/float (`LOADF`)/`LOADK`
constants kept distinct; `OP_CLOSURE` records captured upvalues; `OP_MMBIN` kept as the
generic fallback (no number-proof at M0); varargs/`LUA_MULTRET` tracked; `OP_TBC`/`__close`
ordering preserved.

---

## 8. Codegen (M0 detail)

Per generic op, emit the **slow-path arm only** of v1's triple-path template — i.e. set up
Win64 args (`MOV RCX,RBX` restore L; `RDX/R8/R9` = operands) and `CALL` the helper, then
`EmitReloadRdiAndCache` after any stack-relocating helper. Constants are passed as the
helper expects (index into `k[]`); the live Proto (§5) backs them. `savedpc` is written
before throw-capable ops.

**New vs v1 JIT (the AOT delta):**
1. **Relocations instead of baked `imm64`.** Every helper/sibling-function address and every
   `.rdata` reference records an `LcReloc{kind, offset, target, addend, width}`; the encoded
   bytes carry a placeholder; the COFF writer turns it into a COFF relocation.
2. **RIP-relative `.rdata` loads.** Add `EmitX64_LeaRipRelative(buf, dst, disp32)`
   (`48 8D /r [RIP+disp32]`, ~15 LOC) for position-independent constant references.
3. **`UNWIND_INFO` per framed function** — describe the prologue (7 pushed callee-saved regs:
   `RBX,RDI,R12-R15,RSI`; 96-byte frame). Emitted into the COFF so `ld` lays down
   `.pdata`/`.xdata`.
4. **GC stack maps / safepoints** — *minimal at M0*: because every live Lua value lives in
   the on-frame `TValue` slots (`[RDI+N*16]`) that the collector already scans via the Lua
   stack, M0 does **not** need a separate stack-map side-table. (Real stack maps arrive with
   M1 unboxing, when live refs start living in raw registers.) Safepoints on loop back-edges
   are inserted by `lc_pass_safepoints` if needed for GC progress; for M0 the helper calls
   already poll GC.

---

## 9. Error handling & fidelity

- **Closed-world violations** → compile errors via `Diag_*` (gcc/clang-style), e.g.
  `error: load() is not permitted in an AOT-compiled program (closed world)`.
- **Everything else is delegated to the same helpers the interpreter uses**, so runtime
  behavior is identical *by construction* — M0 introduces no new semantics, only a new
  *dispatch* (native call vs interpreter loop). NaN/`-0.0`/int-float equality, metatable
  chains, string coercion, GC barriers, etc. all live inside the unchanged `Rt_*`/`luaV_*`
  helpers.

---

## 10. Testing

The **AOT differential oracle** (`tests/differential/*.lua`) is the M0 gate: compile with
`aotc` (native), run the same script under `luavm.exe -i` (interpreter), **diff stdout**.
v1 is the frozen oracle — never "fix" a red diff by changing v1.

- **First slice (epsilon):** `print("hello")` — exercises Proto construction + string
  interning + `_ENV` global get + call + return + the entry/bootstrap + COFF emit + link +
  differential, end-to-end, with the fewest moving parts.
- **M0 set (in order):** epsilon → arithmetic (int/float/wrap/`//`/`%`) → tables
  (`new`/get/set, array+hash) → closures/upvalues → string ops/`concat`/`len` → numeric
  `for` → generic `for` (`pairs`/`ipairs`) → `pcall`/`xpcall` → one simple coroutine → one
  pure-Lua package (e.g. `json` or `base64`).
- **C-unit** (`tests/unit/test_*.c`): COFF writer (section/symbol/reloc correctness against a
  golden object), `UNWIND_INFO` blob shape, the RIP-relative emitter bytes.
- **XFAIL discipline** (CLAUDE.md): a known unfixed bug is `XFAIL`-marked and visible, never
  worked around.

`build\run-tests.bat` builds the products and runs every layer with one tally.

---

## 11. De-risk order (spikes first)

Before building the full slice, prove the three highest-risk unknowns in isolation:

1. **Dispatch spike** — confirm `Jit_RegisterCompiled` + `Jit_LookupCached` route a call to
   an externally-supplied native entry with no JIT present (write a tiny C harness that
   hand-builds a Proto, registers a C function as its entry, and calls it via `Rt_Call`).
   *(Mechanism already located — `src/jit/dispatch.c` `g_Cache`/`Jit_LookupCached`; the
   spike confirms registration + invocation end-to-end.)*
2. **CallInfo spike** — replicate the exact `CallInfo`/`L->top` setup v1's JIT trampoline
   does before invoking a native entry; confirm a trivial native body can read its args and
   return results.
3. **COFF+link spike** — hand-author a minimal COFF `.o` with one function that does a
   `Rt_*` reloc, link it against `runtime-embedded.a` + a stub entry, and run it. Proves the
   COFF writer's target format + the `ld` link line before codegen depends on them.

Only once these are green does the epsilon slice get wired through the real pipeline.

---

## 12. Risks & unknowns

- **Bootstrap rework** (`runtime_init.c` is blob+JIT coupled) is the most involved
  non-codegen piece — the AOT entry must reproduce state setup + `CallInfo` + protected
  invocation without the blob path. Spikes 1–2 de-risk it.
- **String interning at startup** must complete before any compiled function runs (field
  lookup is pointer-equality). `ProtoInit_*` ordering (children-before-parents) matters.
- **`.pdata`/`.xdata` correctness** — relying on `ld`, but the per-function `UNWIND_INFO`
  must accurately describe the prologue or `pcall`/coroutine unwinding corrupts. C-unit
  test the blob.
- **Multi-value/`LUA_MULTRET`** propagation through calls/varargs/returns must match the
  interpreter exactly — historically a JIT bug source (cf. v1 `JIT-VARARG-001`). The
  differential `for`/`pcall`/vararg scripts target this.

---

## 13. Out of scope (later milestones)

Type inference, unboxing, arith/raw-table specialization, devirtualization, inlining (M1);
interprocedural type-prop, monomorphization, dead-global elimination (M2); escape analysis,
scalar replacement, GC-barrier elision (M3); strategy-A self-contained PE writer, `.pdb`/
DWARF debug info, `-O` levels, DLL output, the full ~195-package sweep, and stripping
`lvm.c`→`lvm_semantics.c` / moving `Rt_*`→`lua_rt.*` (M4 cleanup).
