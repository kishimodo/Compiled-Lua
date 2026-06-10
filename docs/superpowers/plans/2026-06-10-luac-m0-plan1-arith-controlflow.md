# LuaC M0 Follow-on Plan 1 — Arithmetic + Control Flow

> Builds on the green M0 epsilon slice (branch `luac-m0-epsilon`). Extends the
> IR-driven backend from the epsilon op set to arithmetic, loads, comparisons,
> branches, and numeric for-loops. **Gate: differential-green** (compile with
> `aotc`, diff stdout vs `luavm.exe -i`) across an arith/control-flow battery.

**Goal:** `aotc` correctly compiles programs using local variables, arithmetic
(`+ - * / // % ^`, bitwise, unary, concat, length), comparisons, `if/elseif/else`,
`while`/`repeat`, and numeric `for`.

**Architecture note — NO CFG rewrite.** v1's JIT lays bytecode out **linearly** and
patches branches by pc (`BranchCtx`); it does not build a control-flow graph. M0
does the same: keep lift single-block (instructions in bytecode order), and add to
codegen a `bc_pc → code-offset` table plus branch placeholder/patch. CFG + SSA stay
deferred to M1.

---

## Grounding-derived decisions (verified 2026-06-10)

### Runtime helper completeness
- **`Rt_AddSlow/SubSlow/MulSlow` are slow-path only** (assume int/float fastpath ran)
  → **NOT** safe to call unconditionally. **Action:** add complete `Rt_AddOp`,
  `Rt_SubOp`, `Rt_MulOp` to `src/jit/runtime.{c,h}` mirroring the existing complete
  `Rt_DivOp` (`luaO_arith(L, LUA_OPADD/SUB/MUL, s2v(Base+B), s2v(Base+C), Base+A)`).
- **Complete, call unconditionally:** `Rt_DivOp/ModOp/IDivOp/PowOp`,
  `Rt_*KOp` (ADDK…POWK, BAND/BOR/BXOR K), `Rt_AddIOp`, `Rt_BAndOp/BOrOp/BXorOp`,
  `Rt_ShlOp/ShrOp/ShlIOp/ShrIOp`, `Rt_UnmOp/BNotOp/NotOp`, `Rt_Len`, `Rt_Concat`,
  comparisons `Rt_EqSlow/LtSlow/LeSlow/EqKSlow/EqISlow/LtISlow/LeISlow/GtISlow/GeISlow`
  (return **0/1**). All `(L, A, B[, C])` register/const-index ABI, `RAX`=ret.

### Lowering table (M0 = one complete helper per dynamic op; inline for loads)
| Bytecode | Lowering | reload after? |
|---|---|---|
| `MOVE A B` | inline: copy 16-byte TValue `[RDI+B*16]`→`[RDI+A*16]` (value+tag halves) | no |
| `LOADI A sBx` | inline: `[RDI+A*16]=sBx` (val), tag dword `=LUA_VNUMINT(0x00)` | no |
| `LOADF A sBx` | inline: val = `(double)sBx` bits, tag `=LUA_VNUMFLT(0x11)` | no |
| `LOADK A Bx` | (epsilon, done) inline via runtime Proto `k` walk | no |
| `LOADKX`+`EXTRAARG` | inline: const idx = `GETARG_Ax(next)`; fuse, skip EXTRAARG | no |
| `LOADFALSE A` / `LOADTRUE A` | inline: val=0, tag `=LUA_VFALSE(0x01)`/`LUA_VTRUE(0x11)` | no |
| `LFALSESKIP A` | inline: R[A]=false, then skip next instr | no (skip) |
| `LOADNIL A B` | inline loop: R[A..A+B] = nil (tag `LUA_VNIL(0x00)`) | no |
| `ADD/SUB/MUL A B C` | `Rt_AddOp/SubOp/MulOp(L,A,B,C)` (NEW helpers) | yes |
| `DIV/MOD/IDIV/POW A B C` | `Rt_DivOp/ModOp/IDivOp/PowOp(L,A,B,C)` | yes |
| `ADDK/SUBK/MULK/DIVK/MODK/IDIVK/POWK` | `Rt_*KOp(L,A,B,C)` (C=const idx) | yes |
| `ADDI A B sC` | `Rt_AddIOp(L,A,B,sC)` | yes |
| `BAND/BOR/BXOR/SHL/SHR A B C` | `Rt_BAndOp/BOrOp/BXorOp/ShlOp/ShrOp(L,A,B,C)` | yes |
| `BANDK/BORK/BXORK` | `Rt_BAndKOp/BOrKOp/BXorKOp(L,A,B,C)` | yes |
| `SHRI/SHLI A B sC` | `Rt_ShrIOp/ShlIOp(L,A,B,sC)` | yes |
| `UNM/BNOT/NOT A B` | `Rt_UnmOp/BNotOp/NotOp(L,A,B)` | yes (UNM/BNOT), NOT no |
| `LEN A B` | `Rt_Len(L,A,B)` | yes |
| `CONCAT A B` | `Rt_Concat(L,A,B)` | yes |
| `SELF A B C` | `Rt_Self(L,A,B,C)` | yes |
| `MMBIN/MMBINI/MMBINK` | **no-op** (preceding arith helper already did metamethods) | — |
| `JMP sJ` | uncond jump to `pc+1+sJ` | — |
| `EQ/LT/LE A B k` | `Rt_EqSlow/LtSlow/LeSlow(L,A,B)`→eax; `cmp eax,k; jne (pc+2)` (skip next JMP) | yes (helper) then branch |
| `EQK A B k` | `Rt_EqKSlow(L,A,B)` (B=const idx); same branch | yes |
| `EQI/LTI/LEI/GTI/GEI A sB k` | `Rt_EqISlow/LtISlow/LeISlow/GtISlow/GeISlow(L,A,sB)`; same branch | yes |
| `TEST A k` | truthiness of R[A]; `if truthy != k` skip next (port v1 `Lower_Test`) | — |
| `TESTSET A B k` | `if truthy(R[B])==k` then R[A]=R[B] else skip next (port v1) | — |
| `FORPREP A Bx` | `Rt_ForPrep(L,A)`→eax; `test eax,eax; jne (pc+2+Bx)` (skip loop if eax≠0) | yes |
| `FORLOOP A Bx` | `Rt_ForLoop(L,A)`→eax; `test eax,eax; jne (pc+1-Bx)` (loop back if eax≠0) | yes |

### Branch semantics (Lua 5.4)
A comparison (`EQ/LT/LE/EQK/EQI/LTI/LEI/GTI/GEI`) is **always followed by `OP_JMP`**.
Literal semantics: `if (result != k) pc++` (skip the JMP), else execute the JMP.
So codegen: helper→`eax` (0/1); `cmp eax, k`; **`jne` to `pc+2`** (skip the JMP) when
`result != k`; fall through to the JMP (at `pc+1`) when `result == k`. The JMP lowers
independently as an unconditional jump to its target `(pc+1)+1+sJ`. `k = GETARG_k`.
`JMP` target = `pc+1+GETARG_sJ`. `FORPREP` target = `pc+2+Bx` (fwd). `FORLOOP` target
= `pc+1-Bx` (back).

---

## IR contract extension
Add `int bc_op;` to `LcInst` (the originating Lua opcode). Lift sets it; M0 codegen
dispatches on `bc_op` to pick the exact helper / inline sequence (the coarse `LcInst.op`
category stays for future opt passes). For branch ops, carry the **resolved target pc**
in `inst->c` (JMP/FORPREP/FORLOOP) and the **k-bit** in `inst->c` for comparisons
(comparisons skip to `bc_pc+2`, a value codegen derives, so `c` is free for k). Lift
computes targets from `sJ`/`Bx` so codegen only needs the bc_pc→offset map.

## Codegen branch infrastructure (port v1 `BranchCtx`, keyed by bc_pc)
- A per-function `size_t PcOffset[sizecode]` recorded as each instruction is emitted
  (record `in->bc_pc → buf.used` **before** lowering the instruction).
- A deferred-patch list `{ patch_site_offset, target_bc_pc, is_rel8 }`.
- Branch ops emit a `Jcc`/`JMP rel32` **placeholder** (reuse `X64Emit_*Rel32_Placeholder`
  / add `X64Emit_JccRel32_Placeholder` if missing) and either patch immediately
  (backward target already recorded) or defer (forward).
- After the instruction loop, resolve all deferred patches: `disp = PcOffset[target] -
  (patch_site + 4)`. (`X64Emit_PatchRel32` already does the math from patch-site to target.)
- The epilogue is still inlined at each `RETURN` (multiple returns OK).

---

## Tasks

- **P1.1 — Runtime helpers.** Add complete `Rt_AddOp/Rt_SubOp/Rt_MulOp` to
  `src/jit/runtime.{c,h}` (mirror `Rt_DivOp`). Rebuild. (Test: differential covers it.)
- **P1.2 — Lift + codegen + gate (the bulk).** Add `bc_op` to `LcInst`; extend lift to
  map every Plan-1 bytecode op → IR carrying operands + resolved branch targets + k-bit
  (single block, bytecode order; fuse `LOADKX`+`EXTRAARG`; emit the trailing `MMBIN*` as
  a benign op the codegen no-ops). Add the bc_pc→offset table + branch placeholder/patch
  to codegen; implement every Plan-1 lowering per the table (inline loads, helper calls,
  comparison+JMP branch, FORPREP/FORLOOP). Extend `supported_ops.c` to allow the Plan-1
  set. Self-validate with smoke differentials: an arithmetic expression, `if/else`, a
  numeric `for` sum, a `while` loop, a comparison chain — each compiled by `aotc` and
  byte-diffed vs `luavm.exe -i`.
- **P1.3 — Differential battery + green gate.** Add `tests/differential/aot_*.lua`
  covering: int/float arith + wrapping + `//`/`%`/`^`, mixed int/float, string→number
  coercion, bitwise, unary, concat, length, all comparisons (incl. NaN, int/float eq),
  `and`/`or`/`not`, nested `if`, `while`, `repeat`, numeric `for` (up/down/step, zero-trip,
  float bounds). Run each through the suite's AOT differential phase; fix any miscompile
  (the gate is byte-identical stdout vs the interpreter). Report the green tally.

Each task ends by running `cmd /c "build\run-tests.bat"` (FAIL must not exceed the
pre-existing ~140 baseline + be honest about any new differential reds).
