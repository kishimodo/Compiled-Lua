# Handoff: inlining the table fast path

State at `529430f`. The glue around table access has been trimmed as far as it
goes; what remains is inlining the *lookup*, which is a different and larger
change. This records the design so the next session starts from a plan rather
than from the disassembler.

## What is already done, and why it was not enough

| Change | Effect |
|---|---|
| `1501e5f` | `L->top` sync moved off the fast path in all nine helpers |
| `c632d5c` | frame base passed in, not re-derived — 2 fewer loads, −9,216 B rover |

Both trim the *call*. Neither touches the fact that a table read is still a
call. Table field r/w measured **0.80×** the reference interpreter before these
landed, and the remaining gap is structural: `t.x` costs a `CALL`, a hash
lookup, and a return, where the interpreter costs a dispatch and the same hash
lookup. To beat it, the lookup has to happen inline.

## The design

For `OP_GETI` (constant integer key `C`), mirroring `luaV_fastgeti`
(`lvm.h:93-101`). The existing model to copy is `lower_arith_fast`
(`codegen.c:1320`) — same shape: inline test, `jne` to a slow-path helper call,
join.

```
  cmp   byte [rdi + B*16 + 8], ctb(LUA_VTABLE)   ; 69 = 5 | (1<<6)
  jne   slow
  mov   rax, [rdi + B*16]                        ; Table*  (== the GCObject)
  cmp   dword [rax + offsetof(Table, alimit)], C-1
  jbe   slow                                     ; need (C-1) < alimit, unsigned
  mov   rdx, [rax + offsetof(Table, array)]
  test  byte [rdx + (C-1)*16 + 8], 0x0F          ; isempty -> (tag & 0x0F) == 0
  jz    slow
  movups xmm0, [rdx + (C-1)*16]                  ; 16-byte TValue copy
  movups [rdi + A*16], xmm0
  jmp   done
slow:
  <LcCg_EmitHelperCallFrame "Rt_GetIF">
done:
```

### Details that are easy to get wrong

- **`isempty` is not a byte compare.** `isempty(v)` is `ttisnil(v)`, which is
  `novariant(tt) == LUA_TNIL` — i.e. `(tag & 0x0F) == 0`. `LUA_VEMPTY` is
  `makevariant(LUA_TNIL, 1)` = 16 and `LUA_VABSTKEY` = 32, so testing for a
  single tag value silently misses two of the three nil variants. Use
  `test byte, 0x0F` / `jz`.
- **`ttistable` needs the collectable bit.** `ctb(LUA_VTABLE)` = `5 | (1<<6)` =
  69, not 5.
- **`C == 0` must not take the inline path.** `l_castS2U(0) - 1u` is
  `0xFFFFFFFF`, which the unsigned compare handles correctly but always sends
  to the slow path — so emit the plain call and save ~45 bytes.
- **Derive the offsets with `offsetof`, never a literal.** `codegen.c` already
  includes `lobject.h`. A baked-in constant turns a future `Table` layout change
  into a silent miscompile rather than a build error.

Every constant above was verified against the headers in this tree rather than
recalled — use these only to cross-check what `offsetof` gives you:

```
ctb(LUA_VTABLE)          = 69
LUA_VNIL / VEMPTY / VABSTKEY = 0 / 16 / 32     <- all three are (tag & 0x0F) == 0
offsetof(Table, alimit)  = 12
offsetof(Table, array)   = 16
sizeof(TValue)           = 16  (== sizeof(StackValue), so the *16 strides hold)
```
- **`alimit` is a hint, not the array size.** Using it directly as the bound is
  exactly what `luaV_fastgeti` does, so copying that is correct; do not "fix" it
  to `luaH_realasize`.

### Encoder gaps

Everything needed exists in `x64_emit.h` with arbitrary base registers —
`MovMemToReg`, `CmpMem32Imm32`, `CmpMem8Imm8`, `MovupsLoadXmm`/`MovupsStoreXmm`,
`JneRel8`, `PatchRel8`, `JmpRel32_Placeholder` — except three:

- `JbeRel8` (`0x76`)
- `JeRel8` / `JzRel8` (`0x74`)
- `TestMem8Imm8` (`F6 /0 ib`)

Add them next to `JneRel8` and extend `tests/unit/test_lc_x64_emit.c`.

## The cost, and the decision that has to be made first

The inline sequence is **~45–55 bytes** against **12** for the call it replaces.
That is a real size regression on a project whose owner has asked repeatedly for
smaller binaries, so decide the policy before writing the encoder:

- `-O1` is the size-conscious level and should probably keep the call.
- `-O2`/`-O3` are currently **byte-identical to `-O1`** — `clua help` says so per
  level. Making `-O2` mean "spend size on speed" would give it a real meaning
  for the first time. Note `-O2` is the *default*, so this enlarges the default
  binary unless the default moves to `-O1`.

## Expect the benefit to be narrower than it looks

`OP_GETI` only covers a **constant** integer key. `a[i]` in a loop — the case in
`build/tmp/bench/long/array.lua`, and the one that actually matters — is
`OP_GETTABLE`, whose key is a register. Inlining that needs an integer-tag test
on the key before the array probe, so it is a strictly bigger sequence. Do
`GETI` first as the simpler proof, but do not expect the array benchmark to move
until `GETTABLE` follows.

## Measure it on a quieter machine, or not at all

This host cannot resolve a 10% effect: a control kernel that cannot possibly be
affected by the change under test came out **0.79×–1.05×** across a 13-rep
order-alternating run on 2-second kernels. The full protocol and the traps
(fixed A-then-B ordering biases by 5%; equal source/object mtimes make `make`
skip the rebuild entirely) are in
[`docs/benchmarks/size-and-speed-current.md`](../benchmarks/size-and-speed-current.md).

Run `python tools/check-object-freshness.py` before trusting any arm — that
check exists because a stale object silently corrupted the size table earlier in
this arc.
