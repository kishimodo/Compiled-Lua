# LuaC Optimizer (M1–M3) — Status & Design

> The optimizer is the project's "optimizing compiler" identity (PROMPT §9). This
> records what is **built + differential-green + adversarially validated** today
> and the **sound-conservative design** for the rest, so it can be finished
> incrementally with the differential oracle (and an adversarial attack harness)
> as the gate.

## Governing principle (PROMPT §9)
Sound-conservative: a pass fires only where a closed-world proof holds; otherwise
the value stays unknown and codegen emits the generic boxed path. **No deopt, no
guard-and-fallback.** The differential test (`aotc` vs `luavm.exe -i`) is the
arbiter — every increment stays byte-identical. `-O0` = the faithful boxed
baseline; `-O1+` enables the typed fastpaths and the proof-driven elisions.

## Built today (differential-green at -O0 and -O1; suite PASS 429 FAIL 0)

### Checked fastpaths (JIT-parity; sound by construction — runtime tag-dispatch)
A runtime tag-check selects an inline arm and falls back to the **complete** boxed
helper, so no static proof is needed (only genuine int+int / float+float take the
inline path). Covers:
- **arith** ADD/SUB/MUL reg-reg (inline int `add/sub/imul` + float `addsd/subsd/
  mulsd`), and the **immediate / K-constant** forms ADDI / ADDK / SUBK / MULK
  (int-immediate baked inline; sign-extension preserves the exact 64-bit value);
- **comparisons** EQ/LT/LE/EQI/LTI/LEI/GTI/GEI — inline integer compare + branch,
  helper fallback for float/string/metamethods (int-only, so no NaN concerns);
- **bitwise** BAND/BOR/BXOR reg-reg + BANDK/BORK/BXORK (inline `and/or/xor`,
  helper for non-integer / metamethod operands).

### Static type inference + tag-check elision (the AOT value-add — `lc_pass_local_typeinfer`)
A **forward dataflow fixpoint** over the IR (meet at branch joins, over the bc_pc
CFG) proves which registers hold a primitive **integer / float** on *every*
reaching path. Where both operands of an arith/compare op are proven primitive,
codegen emits the **bare** instruction with **no tag-check, no float arm, no
helper** — the unboxed-ish fast path the JIT can't afford to prove at runtime.
- INT elision: arith (reg-reg + immediate/K), comparisons → **~6× on a tight
  integer loop** (3323ms → 556ms).
- FLT elision: reg-reg ADD/SUB/MUL → **~3.6× on a reg-reg float loop**
  (1771ms → 495ms).

**Soundness is the whole game** (no runtime guard backs the elision). The proof is
conservative by construction:
- A value is proven a primitive number **only when the producing op cannot run a
  metamethod** — i.e. its operands are themselves proven primitives (integers/
  floats carry no per-value metatable). `#t` (→ UNKNOWN, `__len` returns any
  type), bitwise (→ INT *iff* operands proven INT, else `__band`/… can return
  anything), `/`/`^` (operand-conditional) are all gated accordingly.
- **Upvalue aliasing**: any register captured `instack` by a nested closure is
  forced to UNKNOWN — the closure can mutate the aliased stack slot to any type
  via `OP_SETUPVAL`, which the intra-procedural pass can't track.
- CALL/VARARG/SELF/TFORCALL/LOADNIL results, and every unmodeled op, clobber to
  UNKNOWN.

### Adversarial validation (the reason to trust the elision)
A 9-lens **attack workflow** (`typeinfer-soundness-attack`) fans out agents that
each try to *break* the proof from a distinct angle (branch-merge, for-loops,
multi-result clobbers, opcode modeling, int/float semantics, bitwise, CFG engine,
closures/upvalues, stdlib returns), generate real Lua repros, compile at `-O1`,
diff vs the interpreter, and independently re-verify every claimed mismatch. It
**found two real `-O1` miscompiles** that the corpus missed and that are now fixed
+ regression-tested (`tests/differential/aot_mt_typeinfer.lua`,
`aot_float_typeinfer.lua`):
1. `#t` / bitwise results assumed integer (metamethod could return float/string);
2. an int loop-var captured + mutated to a float through a closure.
A third, strengthened round reported **zero** confirmed mismatches. It also
incidentally surfaced a *pre-existing* (`-O0`-too) bug: `SHRI`/`SHLI` lowering
called the per-opcode helper that hardcodes the wrong TM, so a metatable'd `a<<K`
(compiled to `SHRI a,a,-K`) dispatched `__shr` and errored — fixed by routing to
`Rt_ShiftI`, which reads the trailing `MMBINI`.

## Completed since (2026-06-10, the "final wave" — all differential-green + attack-validated)

- **Inline integer FORLOOP** (`851682e`) → **bare integer FORLOOP** (`8de3a4f`):
  the integer-loop proof (index+step INT; count integral by FORPREP semantics, so
  unknown limits qualify) drops the per-iteration helper call, then the step
  tag-check and float arm entirely. ~6.5× alone.
- **Float-K arm** (`e29f78d`): ADDK/SUBK/MULK/DIVK with proven-FLT R[B] + any
  numeric K → bare SSE with compile-time K bits; reg-reg DIV FLT÷FLT → divsd.
  Plus the **ADDI float arm** (`8de3a4f`): `f + 1` / `f - 1` (sC-range ints are
  ADDI, not ADDK) → addsd of the possibly-negated imm, exact `-0.0 - 0` identity.
- **FLT compare elision** (`d57920b`): both-proven-float compares → bare ucomisd
  (CF-based conditions are false-on-NaN for free; EQ requires ZF&&!PF); imm forms
  convert the statically-int immediate at compile time. Float while-loop 4.5×.
- **Loop-region register residency** (`8de3a4f`): up to five proven-int slots
  live in the prologue-reserved cache registers R12–R15/RSI across qualified
  innermost FORLOOP regions (every body op frame-blind/fully-elided; fills once
  at entry before the back-edge label, spills value+INT-tag once at the
  fall-through exit; zero-trip skips both; no helper can run inside, so the
  stale frame is never observable). Tight int loop **9.3×** (~2 cycles/iter),
  branchy int kernel **7.1×**. This achieved the unboxing win on the memory-form
  IR — no SSA needed for the loop-region scope.

## Remaining — designed, sound-conservative, not built (honest valuations)

### Residency follow-ups (build only if a real workload demands them)
- **Spill-around observation points**: allow helper-calling ops inside residency
  regions by spilling residents before / refilling after each one. Extends
  residency to loops with table writes or calls; costs spill traffic exactly
  where the loop is already paying a helper call, so the marginal win is small.
- **XMM residency for floats**: xmm6+ are callee-saved on Win64 but the prologue
  doesn't save them — needs prologue + unwind-info work before float
  accumulators can live in registers.

### `lc_pass_raw_table`, `lc_pass_devirt_local`, `lc_pass_inline_small`
Table get/set already match v1 (the fast path lives inside `Rt_GetI`/
`Rt_GetField` via `luaV_fastgeti`); there is no codegen-level table win here.

### SSA (`lc_pass_mem2reg`)
No longer blocks residency (done region-scoped without it). Still the
foundation for *general* (cross-region, cross-call) residency and the
interprocedural passes — build it when M2 is actually wanted.

### M2 (whole-program / interprocedural) — SSA-gated, lower marginal value here
`lc_build_callgraph`, `lc_pass_ip_typeprop`, `lc_pass_monomorphize`,
`lc_pass_ip_devirt`, `lc_pass_dead_global`. Caveat for this architecture: the
driver's `CollectReachable` already walks the full proto tree, so there are no
tree-unreachable functions; a dead-function pass needs call/escape analysis for
any value, and calls already route through the cached `Proto*→entry` dispatch.

### M3 (memory) — SSA-gated, highest risk
`lc_pass_escape` (coroutine capture / `pcall` / FFI force escape),
`lc_pass_scalar_replace`, `lc_pass_barrier_elide` (drop a GC write-barrier only
where a black→white edge is *proved* impossible; default to emitting the barrier).

## How to continue
Each pass is its own brainstorm→plan→execute slice behind `-O<n>`, verified
differential-green across the full corpus **and** clean through the adversarial
attack workflow before the next. Build the cheap fastpaths first (float-K arm),
then mem2reg, then register-residency unboxing, then interprocedural, then memory
— newest/riskiest last, each gated on the sound-conservative proof. The attack
harness (`workflows/scripts/typeinfer-soundness-attack-*.js`) should be re-run
after any change to the proof or an elision.
