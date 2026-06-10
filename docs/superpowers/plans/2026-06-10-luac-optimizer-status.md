# LuaC Optimizer (M1–M3) — Status & Design

> The optimizer is the project's "optimizing compiler" identity (PROMPT §9) and
> the bulk of a months-long effort. This records what is **built + differential-
> green** today and the **sound-conservative design** for the rest, so it can be
> finished incrementally with the differential oracle as the gate.

## Governing principle (PROMPT §9)
Sound-conservative: a pass fires only where a closed-world proof holds; otherwise
the value stays `LC_T_ANY` and codegen emits the generic boxed path. **No deopt, no
guard-and-fallback.** The differential test (`aotc` vs `luavm.exe -i`) is the arbiter
— every increment must stay byte-identical. M0 codegen is faithful memory-form/boxed.

## Built today (differential-green)
- **`-O` plumbing** end-to-end: driver sets `m->opt_level`; `lc_codegen` reads it;
  `-O0` = the faithful boxed baseline (unchanged), `-O1+` enables typed fastpaths.
- **M1 arith fastpath (`lower_arith_fast`, codegen.c).** ADD/SUB/MUL lower to v1's
  proven `EmitBinArith` triple-path: a runtime tag-check selects an **inline integer
  arm** (native wrapping `add`/`sub`/`imul`), an **inline float arm** (SSE
  `addsd`/`subsd`/`mulsd`), or falls to the **complete `Rt_*Op` helper** (mixed /
  string-coercion / metamethod). **Sound by construction** — it dynamically
  dispatches on operand tags, so only genuine int+int / float+float take the inline
  path; no static type proof needed, so no miscompile risk (encoding bugs are caught
  by the differential). Result: **~1.34× on a 30M-iter numeric loop**, byte-identical
  to the interpreter across the corpus at `-O1`.

This proves the optimizer pipeline end-to-end and is a genuine, correct speedup.

## Remaining — designed, sound-conservative, not yet built

### Rest of M1 (per-function)
- **Compare fastpath**: inline int/float `EQ/LT/LE/LTI/...` + the paired `JMP`
  (v1 `EmitCompareAndBranch`); same tag-check + helper-fallback shape as arith.
- **K/I-variant + bitwise fastpaths**: `ADDK/ADDI/SHL/...` analogously.
- **Static type inference + unboxing** (the deeper M1): a forward dataflow fixpoint
  over the IR (meet at branch joins) proving register types from `LOADI/LOADF`/const/
  `FORLOOP`/arith results; then **elide the runtime tag-check** and keep proven
  scalars in raw GPR/XMM across a region, re-boxing only at `TValue`-slot stores /
  escapes. Higher value (no per-op check, true unboxing) but needs an airtight
  dataflow — gate hard behind the proof; default to the checked fastpath when unsure.
- **`lc_pass_raw_table`** (`TABLE_GET/SET`→`RAWGET/RAWSET` when no relevant metatable
  can reach the object — requires the metatable-reachability proof in §9), and
  **`lc_pass_devirt_local`** (known local/closure callee → direct call) +
  **`lc_pass_inline_small`** (inline tiny leaf callees).

### M2 (whole-program / interprocedural)
- `lc_build_callgraph` (complete except FFI/unknown sentinels — the lift already
  records call edges), `lc_pass_ip_typeprop` (arg/return type fixpoint across the
  graph; FFI edges + `LC_T_ANY` are cut points), `lc_pass_monomorphize` (clone
  polymorphic functions per concrete arg-type context, keep an `ANY` fallback clone),
  `lc_pass_ip_devirt` (unique-callee → direct), `lc_pass_dead_global` (drop unused
  globals/fields/functions). The IR carries the call graph for this from day one.

### M3 (memory)
- `lc_pass_escape` (coroutine capture / `pcall` / FFI all force escape),
  `lc_pass_scalar_replace` (explode non-escaping short-lived tables into scalars),
  `lc_pass_barrier_elide` (drop GC write-barriers only where a black→white edge is
  *proved* impossible — the highest-risk pass; default to emitting the barrier).

### Prereq for the deeper passes — SSA
The deeper M1 unboxing + all of M2/M3 want real SSA. `lc_pass_mem2reg` (registers→SSA
via dominance-frontier phi insertion) was deferred from M0 (decision M0-A: the boxed
baseline gains nothing from SSA). It is the first step before static type inference,
escape analysis, and interprocedural propagation. The IR (`ir.h`) is already SSA-shaped
(`LcValue` defs, `LC_OP_PHI`, the `LcType` lattice with `known_proto`/`table_shape`),
so mem2reg + the passes build on the existing structures.

## How to continue
Each pass is its own brainstorm→plan→execute slice, added behind `-O<n>`, verified
differential-green across the full corpus (+ the fuzzer) before the next. Build the
checked fastpaths first (low risk, immediate wins), then mem2reg, then static
unboxing, then interprocedural, then memory — newest/riskiest last, each gated on the
sound-conservative proof.
