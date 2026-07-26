# Codegen: hoisting the `savedpc` base into the frame prologue

Change: authored as `f39a1bd`, integrated as `9d3ded2` in
`clua/src/codegen/codegen.c` and `clua/src/codegen/x64_emit.{c,h}`. Measured and
mutation-tested 2026-07-25.

## What it does

`emit_store_savedpc` used to re-walk `L -> ci -> func -> LClosure -> Proto ->
code` (five loads, an add, and a store: 29 bytes) before every throw-capable op.
Four of the five loads are frame-invariant, so the prologue now caches
`Proto.code + bias` in **RBP** and each site collapses to

```asm
mov rax, [rbx + ci]      ; reload ci -- the only frame-variant part
lea r11, [rbp + disp]    ; disp8 where the bias allows, else disp32
mov [rax + savedpc], r11
```

12 bytes with `disp8`, 15 with `disp32`. The bias is
`lc_savedpc_bias_for(sizecode) = 4 * ((sizecode + 1) / 2)` when `sizecode > 31`
and `0` otherwise, which centers the displacement window on zero so most sites
reach the shorter encoding.

## Why it is safe — re-verified, do not re-derive

- **RBP was the only free callee-saved GPR.** `RBX` holds `L`, `RDI` the register
  base, and `R12`-`R15` plus `RSI` are the M1 residency cache. One prologue site
  and three epilogue sites (return, tailcall, fallthrough) push and pop it.
- **The cached value points into the heap**, at the `Proto.code` array, not at
  the Lua stack. That is exactly why a stack reallocation forces an `RDI` reload
  but can never invalidate `RBP`.
- `Proto.code` is grown only by `lcode.c`/`lparser.c` and allocated only by
  `lundump.c`, all absent in closed-world AOT (`protoinit_rt` builds Protos at
  startup). It is freed only by `luaF_freeproto`, and a live frame keeps the
  `LClosure` GC-reachable.
- **Native bodies are only ever entered at their entry point** — `ldo.c` (ccall)
  and `lvm.c` (`luaV_execute`) both call the compiled body immediately after
  `L->ci` is set. Nothing resumes a native frame mid-stream.
- `OP_TAILCALL` rebinds `ci`, but `lower_tailcall` emits the epilogue
  immediately, so no `savedpc` site can execute against a rebound `ci`.
- **Debug hooks never see a native frame:** both dispatch sites gate on
  `L->hookmask == 0` and otherwise fall back to the bytecode interpreter.
- The VEH recovery trampoline restores `RBP` from `_JUMP_BUFFER` offset +24 as an
  ordinary callee-saved register. Nothing in the tree walks an `RBP`
  frame-pointer chain, and AOT functions emit no unwind data at all
  (`cf->unwind == NULL`), before or after this change.
- **Frame arithmetic:** 7 pushes with a `0x20` reserve became 8 pushes with
  `0x28`. Eight pushes (64 bytes) plus the return address (8) is 72, so the
  reserve had to grow for `RSP` to stay 16-aligned at helper calls, with and
  without the xmm6-10 spill area. The spill slots became 8-mod-16, which is
  correct because the emitter uses `MOVUPS`, not `MOVAPS` — a micro-perf detail,
  not a correctness one.
- **Encoding trap:** an `RBP`/`R13` base with `disp == 0` must use `mod=01` with
  a zero `disp8`, never `mod=00`, which means RIP-relative. `EmitMemOp` already
  handled this; a unit assertion now pins it.
- The bias is a pure size knob. `lc_savedpc_bias_for` returning `0` for every
  function would still be correct, just larger.

## Measured result

`.text` bytes, baseline `0e63dd5` against the integrated change:

| Build | `.text` before | `.text` after | Delta |
|---|---:|---:|---:|
| `hello` `-O0`/`-O1` | 114,864 | 114,800 | -64 (-0.06%) |
| `rover` `-O0` | 651,070 | 590,910 | -60,160 (-9.24%) |
| `rover` `-O1` | 665,918 | 605,694 | -60,224 (-9.04%) |

Whole-file bytes:

| Target | `-O0` before | `-O0` after | `-O1` before | `-O1` after |
|---|---:|---:|---:|---:|
| `print("hello")` | 137,216 | 137,216 | 137,216 | 137,216 |
| `rover/src/rover.lua` | 784,384 | 724,480 | 799,232 | 738,816 |

Rover loses 59,904 bytes at `-O0` (-7.64%) and 60,416 at `-O1` (-7.56%); `-O2`
stays byte-identical to `-O1`.

A later re-measurement at `7fec28f` reproduced the `-O0` figure exactly but got
739,328 rather than 738,816 at `-O1`, because whole-file size moves with the
length of the source path string — see the caveat in [`README.md`](README.md).
The delta is unaffected as long as both arms use one invocation form.

**`hello` does not move at all**, and that is the expected result rather than a
disappointment: a trivial program has almost no throw-capable user ops, so its
binary is dominated by runtime and CRT bytes this change does not touch, and the
512-byte PE file alignment absorbs the 64-byte `.text` win. This is a win
proportional to user code volume, not a fixed-overhead win.

Output stays byte-reproducible: two Rover builds at `-O1` share SHA-256
`1dfa6f9fe76cbc0ff38341536960549c3b5ce3ac97f68f4262da7ef7cdf70ae9`, across three
full toolchain rebuilds.

## Tests, and proof that they bite

- `tests/unit/test_lc_codegen_frame.c` — push/pop order, the `0x28` reserve,
  `POP RBP` first, and the `LEA` `disp8`/`disp32`/`RBP`-with-`disp0` encodings.
- `tests/differential/aot_savedpc_precision.lua` — pins **pc-exactness**, not
  line-exactness, because `ldebug`'s `varinfo` decodes the instruction *at*
  `savedpc` to name the operand. It covers a zero-bias body, a nonzero-bias
  body, sites past the `disp8` window at each end, and two throw sites sharing
  one source line.
- Mutation-verified, not merely asserted: changing the store site from `pc + 1`
  to `pc + 2` makes the compiled binary report `field 'deeper'` where the
  interpreter reports `field 'deep'`, failing at O0/O1/O2. Skewing the prologue
  bias by `+4` while leaving the sites alone fails only in the nonzero-bias
  function, exactly as designed — while a bias change applied *consistently* to
  both prologue and sites is undetectable, because it genuinely is a no-op.

## Limits

- Same-line throw sites are discriminated only through the operand **name** in
  the error text.
- `g_savedpc_bias` is one more file-scope per-function global in `codegen.c`. It
  adds to, and does not fix, the reentrancy blocker on roadmap row 6, and it must
  be set before the prologue is emitted.
- The `Proto.k` half of the hoist is **not** done — constant lowering still
  re-walks to the constant table, and no free callee-saved register remains.

## Reproducing

Only three files change, so use the single-object A/B recipe in
[`README.md`](README.md) with
`clua/src/codegen/{codegen.c,x64_emit.c,x64_emit.h}`. Delete
`build/bin/obj/{ir,opt,codegen,link,driver}` between arms: the Makefile does not
track header dependencies, and a stale `lift.o` silently produces empty-output
binaries.
