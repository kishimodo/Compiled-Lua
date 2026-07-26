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

*Pre-change:* `mov rdx/r8/r9, imm64` was emitted at **no other site in the
backend** — every other `X64Emit_MovImm64ToReg` call targets `RAX`. So the
30-byte triple `48 BA <imm64> 49 B8 <imm64> 49 B9 <imm64>` identified a helper
call site uniquely, and two independent matchers (triple-only, and one anchored
on the surrounding `mov rcx,rbx` … `call rel32`) both found the same count:

| Build | Helper-call sites | Bytes spent on argument loads |
|---|---:|---:|
| `rover/src/rover.lua` (`-O0` and `-O1`, identical counts) | 4,724 | 141,720 |
| `print("hello")` | 4 | 120 |

Reproduce with `tools/count-imm-sites.py <exe>`. **Post-change the scanner is
only approximate** — the new encodings make the anchored shape as short as 12
bytes, so it collides with unrelated CRT bytes and reports 4,758 for Rover where
4,724 is the truth (+0.7%). Take the authoritative figure from the measured
`.text` delta, not from the scanner.

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

`R8` and `R9` require `REX.B` (`41 B8` / `41 B9`), and the zero form needs
`REX.R` **as well**, because it names the destination in both the `reg` and `rm`
fields: `45 31 C0` is `xor r8d,r8d`, while `41 31 C0` is `xor r8d,eax` — not zero,
and *smaller* than correct code, so a size measurement would cheerfully report
the broken version as an even bigger win.

## Implemented

Landed unconditionally — not behind `-Os`/`-Oz`, because there is no tradeoff to
gate. `X64Emit_MovImm32ToReg` picks one of three encodings by the value's sign:

| Tier | Encoding | RDX | R8 | R9 |
|---|---|---|---|---|
| `Imm == 0` | `XOR r32, r32` (`31 /r`) | `31 D2` | `45 31 C0` | `45 31 C9` |
| `Imm > 0` | `MOV r32, imm32` (`B8+rd id`) | `BA id` | `41 B8 id` | `41 B9 id` |
| `Imm < 0` | `MOV r64, imm32` sign-extended (`REX.W C7 /0 id`) | `48 C7 C2 id` | `49 C7 C0 id` | `49 C7 C1 id` |

The negative tier deliberately keeps `REX.W` and spends 7 bytes rather than the
6-byte zero-extending form. `mov r32, imm32` would leave
`0x00000000FFFFFFFF` where the old `imm64` form left `0xFFFFFFFFFFFFFFFF`. Every
`Rt_*` helper takes `int`, so the shorter form would in fact be ABI-legal — but
paying one byte on 365 of 14,274 immediates converts the change from "legal
because of how the callee reads it" into "the register is bit-identical", which
needs no argument at all.

### Measured

A/B on one tree: the three codegen files stashed and rebuilt for the "before"
arm, restored and rebuilt for "after", same invocation both times. This isolates
the change — comparing against the older recorded baseline instead would have
folded in Rover's source growth from the `tar` pin and understated the win by
about 4 KB.

| Build | file before | file after | delta | `.text` before | `.text` after | delta |
|---|---:|---:|---:|---:|---:|---:|
| `rover` `-O0` | 729,088 | 655,872 | **-73,216 (-10.04%)** | 594,478 | 521,326 | **-73,152 (-12.31%)** |
| `rover` `-O1` | 743,424 | 670,208 | **-73,216 (-9.85%)** | 609,262 | 536,046 | **-73,216 (-12.02%)** |
| `print("hello")` `-O1` | 137,216 | 137,216 | 0 | 114,880 | 114,816 | -64 |

The prediction from the pre-implementation count was **73,124 bytes**; the
measured figure is **73,216**, within 92 bytes (0.13%). Tier distribution over
Rover's argument slots: 3,935 zero, 9,974 positive, 365 negative. `hello` does
not move, as predicted — 4 call sites, and the 512-byte PE alignment absorbs them.

Output stays reproducible: two `-O1` builds of Rover share SHA-256
`4c2b5a77d4ad567d…`, and `-O2` is byte-identical to `-O1`.

### Verified

- `tests/unit/test_lc_x64emit.c` asserts the exact bytes for all nine
  (register × tier) combinations plus `INT32_MIN`, and that no relocation is
  emitted. `tests/unit/test_lc_codegen_frame.c` asserts the complete byte stream
  of three whole shim calls, including the reloc offset.
- `tests/differential/aot_helper_arg_encoding.lua` drives every register through
  every tier against the interpreter oracle: multret `NArgs`/`NResults` of -1,
  `Rt_Vararg`/`Rt_PrepReturn` negative counts, the lift's negative `Ck` constant
  keys (`SETFIELD`/`SETI`/`SETTABUP`/`OP_SELF`), a 300-element `SETLIST` for a
  large positive, and packed metamethod instruction words through `Rt_ArithIK`,
  `Rt_ShiftI` and `Rt_OrderISlow`. Matches at O0, O1, O2 and O3.
- **Mutation-verified:** dropping `REX.R` from the zero tier makes the compiled
  binary segfault at O0 and O1, so the differential test demonstrably bites.
- **Tier coverage of the differential fixture, measured** rather than assumed, by
  scanning its own compiled binary for the anchored shim shape (260 call sites):

  | argument | zero | positive | negative |
  |---|---:|---:|---:|
  | `a` (RDX) | 41 | 219 | **0** |
  | `b` (R8) | 94 | 135 | 31 |
  | `c` (R9) | 141 | 95 | 24 |

  So eight of the nine (register × tier) combinations are exercised end-to-end
  against the interpreter. The ninth, RDX-negative, is **unreachable from
  codegen** — argument `a` is always a register index or `0` — and is covered by
  the exact-byte unit test only. A naive unanchored byte count suggests otherwise
  (`48 C7 C2` is also an ordinary CRT encoding, and appears 3 times); the anchored
  count is the one to trust.

### Not done here

The 322 `mov rax, imm64 0` sequences (2,576 bytes in Rover) are a separate
commit. The safety argument differs in kind: inside the shim EFLAGS is provably
dead because a `CALL` always follows, whereas at those sites it needs the
stronger claim that no lowering leaves EFLAGS live across a bytecode-instruction
boundary. That deserves its own reasoning and its own bisect point.
