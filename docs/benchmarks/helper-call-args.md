# Codegen: helper-call argument materialisation

Measured 2026-07-25 at `7fec28f`, by counting instruction encodings in the
emitted binaries. This is a static count, not a timing, so it is exact rather
than a median.

## The observation

`LcCg_EmitHelperCall3` (`clua/src/codegen/codegen.c`) loads three integer
arguments before every runtime-helper call:

```c
X64Emit_MovImm64ToReg( B, X64_RDX, (uint64_t)(int64_t)a );   /* 48 BA + imm64 */
X64Emit_MovImm64ToReg( B, X64_R8,  (uint64_t)(int64_t)b );   /* 49 B8 + imm64 */
X64Emit_MovImm64ToReg( B, X64_R9,  (uint64_t)(int64_t)c );   /* 49 B9 + imm64 */
```

Ten bytes each, thirty bytes per call site, to pass what are almost always small
Lua bytecode operand fields.

## Counting the sites exactly

`mov rdx/r8/r9, imm64` is emitted at **no other site in the backend** — every
other `X64Emit_MovImm64ToReg` call targets `RAX`. So the 30-byte triple
`48 BA <imm64> 49 B8 <imm64> 49 B9 <imm64>` identifies a helper call site
uniquely, and scanning the emitted image for it counts sites exactly:

| Build | Helper-call sites | Bytes spent on argument loads |
|---|---:|---:|
| `rover/src/rover.lua` (`-O0` and `-O1`, identical counts) | 4,724 | 141,720 |
| `print("hello")` | 4 | 120 |

Reproduce with `tools/count-imm-sites.py <exe>`.

## What the immediates actually contain

Of the 14,172 immediates across Rover's sites:

- **none require more than 32 bits** — the observed range is `[-245, 295633071]`;
- a large fraction are exactly zero: 247 in argument `a`, 1,155 in `b`, and
  2,502 in `c`.

Every `Rt_*` helper reachable through this path takes `int` parameters — checked
across all 18 signatures in `clua/src/jit/runtime.h` — so the callee reads only
`EDX`/`R8D`/`R9D` and the upper 32 bits are never observed.

## Predicted saving

| Encoding | RDX | R8/R9 | Rover saving |
|---|---:|---:|---:|
| `mov r32, imm32` + `xor r32, r32` for zeros | 5 / 2 | 6 / 3 | **73,124 bytes** |
| `mov r64, imm32` sign-extended (conservative) | 7 | 7 | 58,379 bytes |

73,124 bytes is **12.4% of Rover's 590,910-byte `.text`** and about 10% of the
whole 724,480-byte file — larger than the `savedpc` hoist, which removed 60,160.

A further 2,552 bytes sit in 319 `mov rax, imm64 0` sequences (from the
`X64Emit_MovImm64ToReg( B, X64_RAX, 0 )` sites in `codegen.c`), each replaceable
by a two-byte `xor eax, eax`.

## Two things worth stating plainly

**`print("hello")` will not move.** Four sites, 120 bytes, inside a 512-byte PE
alignment block. Like the `savedpc` hoist, this is a win proportional to user
code volume, not a reduction of the fixed floor.

**This is not a size/speed tradeoff**, so it does not belong behind `-Os`/`-Oz`.
A shorter immediate encoding costs nothing at run time and reduces instruction
fetch. Gating it behind an optimization level would be inventing a choice that
does not exist.

## The hazard that must be tested, not assumed

`R8` and `R9` require `REX.B` (`41 B8` / `41 B9`). An emitter that omits the
prefix writes `EAX`/`ECX` instead, silently passing a wrong argument — and a size
measurement would cheerfully report the broken version as an even bigger win.
Any implementation must assert the exact byte sequence for all three destination
registers in a unit test, and must be run through the differential suite at O0,
O1, O2 and O3.
