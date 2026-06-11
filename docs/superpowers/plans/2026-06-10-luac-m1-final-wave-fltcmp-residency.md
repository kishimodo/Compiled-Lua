# M1 final wave — FLT compare elision + loop-region register residency

> Closes out the deferred M1 items from
> [2026-06-10-luac-optimizer-status.md](2026-06-10-luac-optimizer-status.md).
> Gate per increment: full differential corpus byte-identical at -O0/-O1, suite
> green, adversarial attack round clean.

## Wave 1 — FLT compare elision (ucomisd)

Both-proven-FLT comparisons elide to bare SSE compares with exact Lua NaN
semantics (every comparison with NaN is false; `ucomisd` unordered sets
ZF=PF=CF=1, so CF-based conditions give false-on-NaN for free):

| op            | emit                                  | NaN result |
|---------------|---------------------------------------|------------|
| `a < b`       | `ucomisd b, a` ; `seta`  (b > a)      | false ✓    |
| `a <= b`      | `ucomisd b, a` ; `setae` (b >= a)     | false ✓    |
| `a == b`      | `ucomisd a, b` ; `sete & setnp`       | false ✓    |
| LTI/LEI/GTI/GEI vs imm (reg proven FLT) | imm as double bits via rax→xmm, same forms | false ✓ |

Constants come from the instruction (sB int imm — never NaN). EQI/EQK keep the
helper. New emitters: `UcomisdXmm0Xmm1`, `UcomisdXmm0Mem`. Inference flags
(`LC_KNOWN_*_FLT`) are already annotated on all compare ops.

## Wave 2 — loop-region register residency (INT, GPRs)

The current elision still pays a TValue load + store + tag-store per op. The
prologue already saves R12–R15 + RSI as the reserved M1 cache registers; this
wave puts proven-int slots in them across innermost FORLOOP regions.

**Region** = `[T, P]` for each `OP_FORLOOP` at pc `P` targeting `T`. Qualify
only when ALL hold (sound-conservative; anything else → region rejected, boxed
path unchanged):
1. No nested loop inside (no FORLOOP/TFORLOOP/backward branch within `(T,P)`).
2. Control containment: no branch inside `[T,P]` targets outside (no break /
   goto-out), and no branch outside targets inside `(T,P]` (entry only by
   fall-in at `T`).
3. Loop control slots A..A+3 proven INT (init+step int ⇒ the existing
   inference rule) — the FORLOOP lowers to the BARE integer form (no tag
   check, no helper arm).
4. Every instruction in the body is **frame-blind**: fully-elided arith /
   compare (proven INT both operands, or wave-1 FLT for compares between
   non-resident slots), MOVE between proven-int slots, LOADI, JMP within
   region. Any helper-calling op (incl. checked fastpaths with fallback
   arms), CALL, table/upvalue access, etc. → reject. (Spill-around
   observation points is a designed v2, not built.)

**Residents**: slots accessed in the region that are proven INT at every
region pc and not closure-captured; top 5 by access count get R12–R15, RSI.
Non-chosen slots keep memory form (mixed reg/mem operands are fine — the
whitelist already guarantees the frame is never observed inside the region).

**Protocol**: fill residents from slots at region entry (`T`, reached only by
FORPREP fall-in); spill (value + INT tag) on the FORLOOP fall-through exit
before `P+1`'s label is recorded — the zero-trip FORPREP branch targets `P+1`,
so it skips both fill and spill and the frame is simply untouched. No GC, no
error, no observation can occur inside (no helpers run), so stale slots are
never seen; tags stay INT regardless.

**Codegen**: lowerings keep their shapes; only slot access points consult the
residency map (operand fill `mov rax, rN` instead of the slot load; dest
write-back `mov rN, rax` instead of store+tag). FLT/XMM residency is NOT in
scope (xmm6+ are callee-saved on Win64 but unsaved by our prologue; needs
prologue + unwind work — documented deferral).

## Explicitly out of scope (with reasons, per the status doc)
- M2 interprocedural: low marginal value here (proto tree already minimal,
  calls already route through the cached dispatch).
- M3 escape/scalar-replace/barrier-elide: highest risk, needs allocation-site
  analysis through helpers; revisit only with a concrete workload.
- Spill-around observation points + XMM residency: the designed follow-ups if
  real kernels demand them.
