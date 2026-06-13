# Escape Analysis + Scalar Replacement for CLua -O3 (slice 1)

> Make `-O3` "earn it" with a benchmark-proven, differential-green win.
> Target: the one M3 pass with real measured upside -- replace a provably
> non-escaping, constant-key, metatable-free table with plain stack slots, so a
> hot loop does zero heap allocation and zero `Rt_GetField`/`Rt_SetField` helper
> calls. Estimated 10-40% on table-as-struct hot loops.

## Status of the world (why this is the target)

A six-pass deep audit (2026-06-13) found every M2/M3 optimizer pass is an empty
stub (`{ (void)m; }`); they run at their `-O` level but do nothing -- which is
why `-O1`/`-O2`/`-O3` emit byte-identical code today. The architecture
deliberately puts every table fastpath (`luaV_fastget`) and GC write barrier
*inside* the `Rt_*` runtime helpers, so most M2/M3 passes have nowhere to bite:

| Pass | Can ever earn it? | Why |
|---|---|---|
| monomorphize (O2) | No | dispatch is `Proto*` -> one entry point |
| ip_devirt (O2) | Barely (1-3%) | needs callgraph + `CALL_DIRECT` codegen + SSA |
| dead_global (O2) | No | `CollectReachable` already prunes; globals are runtime `_ENV` |
| escape (O3) | No alone | barriers/fastget already in helpers |
| **scalar_replace (O3)** | **Yes (10-40%)** | removes the alloc + helper calls outright |
| barrier_elide (O3) | No | codegen emits no barriers to elide |

Scalar replacement is the only pass whose win is not already captured by the
runtime helpers, because it removes the table object itself.

## Locked decisions

- **Success bar: both, staged.** Slice 1 is accepted when (a) an authored
  benchmark shows a real, repeatable speedup at `-O3` vs `-O1` on the
  table-as-struct hot loop, and (b) the differential oracle stays byte-identical
  at O0-O3. Then we measure real-code fire-frequency (rover + conformance) and
  widen scope in slice 2. Real-code coverage is a follow-up metric, not a slice-1
  gate.
- **Scope: intra-procedural only.** A candidate table passed to *any* call is a
  bail. No inliner dependency (`lc_pass_inline_small` is also a stub; building it
  + widening escape to flow-through-inlined-callees is slice 2).
- **Approach: IR-to-IR rewrite on the memory-form IR, reusing existing
  opcodes.** No SSA, no new codegen. This fits the grain of the only optimizer
  passes that actually work today (`local_typeinfer` / `ip_typeprop`, both
  memory-form, no SSA).

## Architecture and placement

Two passes at `-O3` (both already invoked from `lc_optimize`,
`clua/src/opt/passes.c` lines 184-187), splitting analysis from rewrite so slice
2 upgrades only the analysis:

- `lc_pass_escape(LcModule*)` -- the **analysis**. Per function, finds each
  `OP_NEWTABLE` whose result register is a scalar-replacement **candidate** and
  records it (the home register, the distinct keys, the reserved slot mapping).
- `lc_pass_scalar_replace(LcModule*)` -- the **rewrite**. Consumes candidates,
  performs the IR rewrite and frame growth.

Candidates are carried between the two passes via a per-function side table
owned by the pass (not persisted in the IR); see Implementation notes.

The IR is memory-form: each `LcInst` carries `bc_op` (the original Lua 5.4
opcode) and decoded `a`/`b`/`c` operands, and codegen dispatches on `bc_op`. The
rewrite therefore works by changing `bc_op` + `a`/`b`/`c` on existing
instructions, never by introducing new IR shapes.

## The analysis (candidate test) -- `lc_pass_escape`

For an `OP_NEWTABLE` writing register `A` at instruction `P` in function `F`,
the table is a candidate **iff all** of:

1. **Single home definition.** `A` is defined (written as a destination) by
   exactly one static instruction in `F` -- this `OP_NEWTABLE`. (Field writes
   `OP_SETFIELD`/`OP_SETI` mutate the table *object*, not register `A`, so they
   are not definitions of `A`.) A second writer of `A` = register reuse = bail.
   This makes reaching-definition trivial: every read of `A` reaches from `P`.
2. **Every reader is an allowed constant-key field op.** Each instruction that
   reads `A` must be one of:
   - `OP_GETFIELD  d, A, K`  (K = string constant)   -- read  `d = A.K`
   - `OP_GETI      d, A, K`  (K = int immediate)      -- read  `d = A[K]`
   - `OP_SETFIELD  A, K, v`  (K = string constant)    -- write `A.K = v`
   - `OP_SETI      A, K, v`  (K = int immediate)       -- write `A[K] = v`
   with `A` in the table-operand position. **Anything else is a hard bail**:
   `OP_MOVE` of `A` (aliasing), `OP_SELF`, `OP_GETTABLE`/`OP_SETTABLE` (variable
   key), `OP_LEN`, `OP_CONCAT`, `OP_EQ`/`LT`/`LE` (identity), `OP_TEST`/`TESTSET`,
   `OP_SETLIST`, `OP_SETUPVAL`/`OP_SETTABUP` (store to upvalue/global),
   `OP_RETURN`/`OP_TAILCALL`/`OP_CALL` with `A` in the value range, or `A` used as
   a call's function.
3. **Not closure-captured.** No child `Proto` of `F` captures register `A` as an
   `instack` upvalue (scan child protos' upvalue descriptors). A captured slot
   can be mutated to any type / observed elsewhere.
4. **Bounded key set.** The distinct constant keys touching `A` number <= `N`
   (initial `N = 8`); otherwise bail (keeps frame growth bounded; struct-like use
   is well under this).

Record: `{ home_reg = A, newtable_pc = P, keys[] (distinct, ordered),
slot_base }` where `slot_base` is the first reserved stack slot.

## The rewrite -- `lc_pass_scalar_replace`

Per candidate:

1. **Reserve slots.** Grow the function's frame by `nkeys` slots: assign
   `slot[key_i] = slot_base + i`, where `slot_base = old maxstacksize`, and set
   `maxstacksize += nkeys`. Dedicated slots, never aliased with any existing
   register -> zero liveness/regalloc conflict by construction. (Frame size is
   the v1 `Proto.maxstacksize`, carried into the ProtoInit blob; the rewrite
   bumps it on `F->source` and the blob serializer must reflect the bump --
   verified during build.)
2. **`OP_NEWTABLE A`** -> **`OP_LOADNIL`** over `[slot_base, slot_base+nkeys)`.
   A read of an as-yet-unset key then yields `nil`, exactly as a real table
   would. In a loop the `NEWTABLE` is re-executed each iteration, so the slots
   are re-`nil`'d each iteration -- the per-iteration heap allocation is gone.
3. **`OP_SETFIELD/SETI A, k, v`** -> **`OP_MOVE slot[k] <- v`**.
4. **`OP_GETFIELD/GETI d, A, k`** -> **`OP_MOVE d <- slot[k]`**.

Codegen already lowers `OP_MOVE` and `OP_LOADNIL`, so **no codegen change** --
every emitted instruction is one the differential oracle already exercises. The
removed cost: `Rt_NewTable` (heap alloc + `luaC_checkGC`), and per-access
`Rt_GetField`/`Rt_SetField` (hash lookup + `luaC_barrierback`). `local_typeinfer`
can subsequently prove the slots primitive and elide tag-checks on them.

## Soundness model

The correctness keystone: **a `NEWTABLE` result that never escapes can never
acquire a metatable.** The only attachment points -- `setmetatable` /
`debug.setmetatable` -- are function calls, which are escapes and already bail
(condition 2). No metatable => pure *raw* get/set semantics => a finite set of
constant keys is *exactly* one scalar slot each (`__index`/`__newindex` cannot
exist). Therefore:

- **Reads** of any key (set or unset) match a real raw table: unset -> `nil`
  (slots `LOADNIL`'d at birth); set -> last stored value.
- **`x.k = nil`** matches: slot stores `nil`; a later read yields `nil`, exactly
  as raw-removing a key then reading it does. Soundness depends on never
  observing *shape* (`#t`, `next`, `pairs`) -- all of which bail.
- **Loop reuse** is sound because the home register's sole definition is the
  `NEWTABLE`, re-`nil`'ing the slots each iteration; values never leak across
  iterations.

The entire correctness burden reduces to one obligation: **the bail set must be
exhaustive over every Lua 5.4 opcode that can read register `A`'s identity or
observe its shape.** That obligation is discharged by enumeration (below) plus
the differential oracle and an adversarial attack round.

### The bail set (exhaustive enumeration)

Built by walking the Lua 5.4 `OpCode` enum and classifying each op's relation to
register `A`: ALLOWED (the four const-key field ops), IGNORE (cannot reference
`A`), or BAIL. The implementation asserts on any unclassified opcode so a future
opcode cannot silently fall through. Notable BAILs: `MOVE`, `SELF`, `GETTABLE`,
`SETTABLE`, `GETTABUP`/`SETTABUP` (when `A` is the value), `SETLIST`, `LEN`,
`CONCAT`, `EQ`/`LT`/`LE`/`EQK`/`EQI`/`LTI`/..., `TEST`/`TESTSET`, `CALL`/
`TAILCALL`/`RETURN`/`RETURN1` (when `A` is in the value range or the callee),
`SETUPVAL`, `CLOSURE` (when it captures `A`), `VARARG` (when it overwrites `A`),
the `FOR`/`TFOR` family (when `A` is a control slot).

## Measurement and validation

- **Benchmark (the "earn it" proof).** A deterministic Lua program with a
  non-escaping const-key table mutated in a hot loop, plus a no-table scalar
  baseline. A new bench harness (`tools/bench-optimizer.lua`) compiles it at
  `-O1` and `-O3`, runs each K times, and reports wall-clock + speedup. Wall-clock
  is machine-dependent, so this is a reported metric, NOT a pass/fail suite gate.
- **Correctness gate (automatic).** `tests/differential/aot_scalar_replace.lua`
  -- a deterministic program that exercises set/get/unset/loop-reuse/int+string
  keys and *prints* results. The existing O0-O3 differential matrix compiles and
  diffs it against `clua-interp.exe -i`. The broad conformance corpus (already
  run at O3) catches anything the targeted test misses. Byte-identical or it
  fails.
- **Adversarial validation (the soundness round).** An attack workflow modeled on
  the existing `typeinfer-soundness-attack`: fan out agents that each try to
  break the scalar-replacement proof from a distinct angle -- aliasing via
  `MOVE`/`SELF`, closure capture of the table, metatable attachment through an
  escape the bail set missed, shape observation (`#t`/`pairs`), nil-set removal
  semantics, register reuse across scopes, mixed int/string keys, GC pressure
  mid-loop, multi-result clobbers. Each generates a real Lua repro, compiles at
  `-O3`, diffs vs the interpreter, and independently re-verifies any mismatch.
  Confirmed miscompiles are fixed + regression-tested before slice 1 is done.
- **Real-code fire-frequency (staged metric).** `lc_pass_escape` counts candidate
  tables; a dry run over rover + the conformance corpus reports how many fire.
  This sizes slice 2 (how much the intra-only restriction costs in practice).

## Staged plan

- **Slice 1 (this spec).** Intra-procedural escape + scalar replacement,
  `GETFIELD`/`SETFIELD`/`GETI`/`SETI` constant keys, single-definition home
  register, <= N keys, no escape. Benchmark-proven + differential-green +
  adversarially validated. Default-on at `-O3` only (the new `clua` default is
  `-O2`, so this does not change default builds).
- **Slice 2 (future).** Build `lc_pass_inline_small`; widen escape to
  flow-through-inlined-callees; handle aliasing (`MOVE`) via a small union-find;
  consider `OP_SELF` method receivers.

## Risks

- **Soundness (highest).** A missing bail opcode -> wrong output or, if the table
  is later treated as scalar while still aliased, heap inconsistency. Mitigations:
  exhaustive enumeration with an assert-on-unclassified default, the O0-O3
  differential oracle, the adversarial round, and the single-home-definition rule
  that keeps reaching-defs trivial.
- **Frame growth.** `maxstacksize` bump must reach the ProtoInit blob and the GC
  stack-scan range, with the reserved slots `LOADNIL`'d before any read.
  Mitigation: verify the blob serializer reads the bumped value; GC-stress the
  benchmark.
- **Win may be modest** if `Rt_NewTable` is cheap or loop-local tables are rare.
  Mitigation: the staged success bar -- benchmark first, claim only what is
  measured; the fire-frequency scan tells us how much real code benefits.

## Files touched

- `clua/src/opt/passes.c` -- implement `lc_pass_escape` (candidate analysis) and
  `lc_pass_scalar_replace` (rewrite) + the opcode classifier.
- `clua/src/opt/passes.h` -- candidate struct / any shared decls.
- `clua/src/ir/*` -- only if a frame-growth helper is needed; no new opcodes.
- `tests/differential/aot_scalar_replace.lua` -- new soundness test.
- `tools/bench-optimizer.lua` -- new benchmark harness.
- `docs/TODO.md`, `docs/superpowers/plans/2026-06-10-luac-optimizer-status.md` --
  update M3 status from "no surface" to "slice 1 shipped".
- `CHANGELOG.md` + version bump on completion.

## Measured outcome (slice 1, shipped 2026-06-13, v0.2.0-beta.6)

Built as designed (`lc_pass_scalar_replace` in `clua/src/opt/passes.c`; analysis
folded in for the intra-procedural slice, `lc_pass_escape` left as the slice-2
interprocedural home). One design point the build forced that the spec did not
foresee: the reserved slots sit at the TOP of the frame, ABOVE `L->top` during
any nested call, so GC's atomic phase (`lgc.c traversethread` nils
`[L->top, stack_end)`) clobbers them across a call. So the live range
`(nt_pc, last_pc]` must additionally be **GC-safepoint-free** (no call/alloc/
unproven-arith), and a backward branch may not re-enter it without re-running
the home `NEWTABLE` (which re-nils the slots) -- the latter found by the
adversarial round (a `goto` re-reading a field after a GC whose pc was textually
past `last_pc`).

- **Correctness:** full suite green at O0+O1+O2+O3 (655/0), plus ~300 adversarial
  repros across escape / aliasing / closure-capture / metatable / shape /
  nil-keys / register-reuse / control-flow / GC. One real O3-only miscompile
  (the back-edge case) was found and fixed; the re-attack (143 loop/goto repros)
  then found zero.
- **Win when it fires:** ~38x on an alloc-heavy struct-in-loop
  (`struct_loop` 5.7s -> 0.149s, `point_loop` 7.9s -> 0.210s at n=2e7), every
  checksum byte-identical, approaching the table-free baseline (0.04s). The
  per-iteration heap allocation and the `Rt_GetField`/`Rt_SetField` helper calls
  are gone.
- **Real-code surface: ~zero.** 0/86 candidate `NEWTABLE`s in rover and 0/182 in
  the conformance corpus fire. Real Lua tables escape, are called-around, or
  interleave field reads with arithmetic, so the GC-safepoint-free + batched-read
  + non-escape + dedicated-register window is essentially never all met. This
  CONFIRMS (and quantifies) the original "no measured surface" assessment: the
  mechanism is real and large, but only on a narrow shape.

**Slice 2 was investigated and DECLINED on the data (2026-06-13).** A bail-reason
breakdown over rover + the conformance corpus (658 candidate `NEWTABLE`s, via
`SR_DEBUG=1`) shows the GC-safepoint bail I expected to be the binding constraint
is only ~7 cases. The real distribution:

- **~280 (~43%) are not structs at all** -- `nokeys` (no constant-key access),
  `SETLIST` list-constructors, variable-key `GETTABLE`/`SETTABLE`, `#t`. Scalar
  replacement is fundamentally inapplicable: these are dicts/arrays, not records.
- **~100 are register reuse** -- the home register is rewritten later in the
  function (`MOVE`/`LOADI`/`LOADK`/`NEWTABLE`/`VARARG`/`FOR*`). Addressable only
  by a real CFG + liveness/reaching-defs (the project deliberately has no SSA/CFG).
- **~80 genuinely escape** -- `CALL`/`RETURN`/`SELF`/stored-into-another-table/
  `SETUPVAL`. Addressable only by interprocedural escape analysis (`lc_build_callgraph`
  is a stub).
- **~7 GC-safepoint**, **1 back-edge**.

Crucially, **none of the addressable candidates are in hot per-iteration
allocation loops** -- they are scattered one-shot tables in cold/setup code. The
38x win only materializes when a table is allocated every iteration of a tight
loop, a shape real Lua code (rover, the corpus) essentially never has. So a full
slice 2 (CFG + liveness + interprocedural escape, weeks of high-risk work) would
raise the *fire count* but not measurably the *runtime* of any real program.

Conclusion: scalar replacement's real-world runtime surface is fundamentally
tiny, and slice 2 is not worth its cost. Slice 1 ships as a sound, validated,
default-on-at-`-O3` mechanism that costs nothing when it does not fire (`-O2` is
the user default). The escape-analysis scaffolding (`lc_pass_escape`) remains
for a future consumer; the higher-value optimizer work is extending the `-O1`
type-inference elision, which actually fires on real code.
