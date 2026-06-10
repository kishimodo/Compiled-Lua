# LuaC M0 Follow-on Plan 3 — Closures, Upvalues, Generic-for (+ C2/C3 fixes)

> Builds on green Plans 1-2. Adds user-defined functions, closures/upvalues,
> varargs consumption, generic `for in`, to-be-closed vars; fixes review items
> C2 (RETURN k-flag / distinct forms) and C3 (ProtoInit nested-proto double-build).
> **Gate: differential-green** vs `luavm.exe -i`.

## Grounding (verified 2026-06-10)
- **AOT→AOT calls work:** `Rt_Call` (runtime.c:143) sets up the callee CallInfo and
  invokes the cached native body (`Jit_LookupCached(Cl->p)`) directly. So once
  `CLOSURE` builds a user function (ProtoInit registered its body), calling it runs
  native. Recursion, mutual calls, higher-order functions all work.
- **`Rt_NewClosure(L,A,Bx)`** creates the closure for `Outer->p->p[Bx]` and binds
  upvalues per `Upvaldesc` (instack→`luaF_findupval(Base+idx)`, else→`Outer->upvals[idx]`).

## Lowering recipes (M0 = one complete helper per op)
| Bytecode | Lowering | reload? |
|---|---|---|
| `CLOSURE A Bx` | `Rt_NewClosure(L,A,Bx)` | yes |
| `GETUPVAL A B` | `Rt_GetUpval(L,A,B)` | no (leaf) |
| `SETUPVAL A B` | `Rt_SetUpval(L,A,B)` | no (barrier only) |
| `VARARG A C` | `Rt_Vararg(L,A, C==0?-1:(C-1))` | yes |
| `TFORPREP A Bx` | `Rt_TForPrep(L,A)`; then **uncond JMP** to `pc+1+Bx` | yes |
| `TFORCALL A C` | `Rt_TForCall(L,A,C)` | yes |
| `TFORLOOP A Bx` | `Rt_TForLoop(L,A)`→eax; `test eax,eax; jne (pc+1-Bx)` (loop back if eax≠0) | yes |
| `TBC A` | `Rt_Tbc(L,A)` | yes |
| `CLOSE A` | `Rt_Close(L,A)` | yes |

Generic-for layout: `[TFORPREP][body…][TFORCALL][TFORLOOP]`; TFORPREP jumps fwd to
TFORCALL; TFORLOOP jumps back to body start. Slots R[A]=iter, A+1=state, A+2=control,
A+3=tbc, A+4..=results.

## C2 — RETURN forms + k-flag (FIX)
Lift must carry the RETURN **k-flag** (`GETARG_k`) on the instruction (add a flag bit
to `LcInst`, e.g. `flags |= LC_IFLAG_RET_CLOSE`, set by lift; or a small field). Codegen
`lower_return` dispatches on `bc_op` AND honors k:
- if k set → emit `Rt_Close(L, 0)` (close upvalues/run __close) **before** the return.
- `OP_RETURN0` → `Rt_PrepReturn(L, 0, 0, 0)`
- `OP_RETURN1` → `Rt_PrepReturn(L, A, 1, 0)`
- `OP_RETURN  A B` → `Rt_PrepReturn(L, A, B-1, GETARG_C)` (B==0 → MULTRET -1)
then epilogue+RET. (Current code reads `b-1`/`c` for ALL three — wrong for RETURN0/1.)

## C3 — ProtoInit build-roots-only (FIX)
`protoinit_emit.c`: each `ProtoInit_<i>` already recursively builds its `p[]` children
(`P->p[c] = ProtoInit_<child>(L)`). So `LuacProgram_BuildEntry` must call `ProtoInit_<i>`
**only for top-level roots** (Protos NOT nested in any other reachable Proto's `p[]`),
not every i — else nested children are built twice (2× cache slots, unanchored dup).
Compute the root set in the emitter (mark every Proto appearing in a parent's `p[]` as
nested; roots = the rest, which includes the entry + any required-module main chunks),
emit `BuildEntry` to build each root once and return the entry's Proto.

## Tasks
- **P3 (one cohesive subagent):** lift + codegen for CLOSURE/GETUPVAL/SETUPVAL/VARARG/
  TFORPREP/TFORCALL/TFORLOOP/TBC/CLOSE; C2 (RETURN forms + k-flag + Rt_Close); C3
  (protoinit roots-only); extend `supported_ops.c`. Self-validate differentials:
  function def+call, recursion (factorial/fib), counter closure (upvalue mutate),
  higher-order (map-like), `for k,v in pairs(t)` and `ipairs`, varargs (`select`,
  `{...}`), nested closures, `<close>` tbc. Each byte-identical to `luavm.exe -i`.
- Commit + add `tests/differential/aot_closures*.lua`, `aot_genericfor.lua`. Run the
  full suite (no new FAIL beyond ~140; all `aot_*` differentials green). Update the
  `supported_ops` unit test.
