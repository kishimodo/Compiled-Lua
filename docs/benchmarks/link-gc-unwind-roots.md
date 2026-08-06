# section GC: what the `.pdata`/`.xdata` roots actually hold live

Result: negligible, and the hypothesis behind it is refuted. Recorded so the
idea is not proposed again.

Measured 2026-07-25 at `04abf0a`, with a temporary env-gated edit to
`gc_keep_by_name` in `clua/src/link/pe_emit.c` that was reverted afterwards
(`git diff --exit-code HEAD` clean; the gate is not in the tree).

## the hypothesis

`gc_keep_by_name` roots `.pdata` and `.xdata` unconditionally, with the
comment "they are reached by the loader / CRT startup walkers ... They are
tiny." The second-reviewer audit challenged that, arguing the relocations
inside a `.pdata` section point at the functions it describes, so rooting it
would mark those CRT `.text` sections live through the MARK worklist and
defeat section GC for every function carrying unwind data. Since
`print("hello")` is 137,216 bytes and did not move at all for the `savedpc`
hoist, this was the only identified lead that could reduce the fixed floor.

## method

One line, gated on an environment variable so a single `clua.exe` emits both
arms and the gate-off arm can be proved identical to the shipped compiler:

```c
static int gc_keep_by_name( const char *n ) {
    if ( getenv( "CLUA_GC_UNROOT_UNWIND" ) &&
         ( strncmp( n, ".pdata", 6 ) == 0 || strncmp( n, ".xdata", 6 ) == 0 ) )
        return 0;
    ...
```

Arm A (gate unset) reproduced Rover `-O1` at SHA-256
`e474660e25b1481c3c8ccbe9147e4c72e11b5e91964640152eba673ac0d21bde`,
byte-identical to the pre-edit compiler, so the gate is inert and arm A is
the real baseline.

## result

Whole-file bytes:

| Build | A: rooted | B: unrooted | Delta |
|---|---:|---:|---:|
| `print("hello")` `-O0` | 137,216 | 134,144 | -3,072 (-2.24%) |
| `print("hello")` `-O1` | 137,216 | 134,144 | -3,072 (-2.24%) |
| `rover/src/rover.lua` `-O0` | 724,480 | 721,408 | -3,072 (-0.42%) |
| `rover/src/rover.lua` `-O1` | 739,328 | 735,744 | -3,584 (-0.48%) |

Section attribution, the reason whole-file size alone would have misled:

| Section | A: hello | B: hello | A: rover | B: rover |
|---|---:|---:|---:|---:|
| `.text` | 0x1c0c0 | 0x1c040 | 0x93e6e | 0x93dee |
| `.rdata` | 0x2cfc | 0x2cd0 | 0x1d51c | 0x1d4f0 |
| `.pdata` | 0x600 | absent | 0x600 | absent |
| `.xdata` | 0x5e8 | absent | 0x5e8 | absent |

`.text` falls by 128 bytes. That is the whole resurrection effect.

Section GC tally for `hello -O1`: `kept 656, dropped 338 (21,152 B)` becomes
`kept 581, dropped 413 (24,332 B)`, 75 more sections dropped, worth 3,180
bytes.

Two arithmetic notes, recorded because this document's entire value is its
numbers:

- The 3,180 does not fully decompose. The section table above loses
  1,536 (`.pdata`) + 1,512 (`.xdata`) + 128 (`.text`) + 44 (`.rdata`) = 3,220,
  which is 40 bytes more than the tally moved. The 40 bytes are unattributed;
  they are immaterial to the -3 KB conclusion, but the gap is real and should
  not be smoothed over by anyone re-deriving these figures.
- The arm-A tally is 21,152 B; today's tree reports 21,104 B for the same
  build (`kept 656, dropped 338`, the section counts are identical). The
  48-byte difference is the `clean-objs` rebuild described in
  [`README.md`](README.md), which changed every emitted binary. Arm A's
  absolute figures are pre-rebuild; the delta between the two arms is what
  this measurement rests on, and it is unaffected.

## why the hypothesis was wrong

The mechanism requires a `.pdata` section to be the only thing keeping some
`.text` alive. It almost never is, because the CRT is not compiled with
`-ffunction-sections`: `objdump -h` over the sysroot archives shows one
`.text` per object member (`libmsvcrt.a`: 2,638 `.text` in 2,638 members;
`libkernel32.a`: 1,759 in 1,759). Archive member selection happens before GC,
so a member is only present because a symbol it defines was needed, and with
a single `.text` per object, that `.text` is genuinely live on its own. GC
granularity is already per-object, so there is no per-function dead code for
`.pdata` to resurrect.

Note also that `.pdata`/`.xdata` are the same size in `hello` and in Rover
(1,536 and 1,512 bytes). They describe runtime and CRT functions; AOT-compiled
Lua functions emit no unwind data at all (`cf->unwind == NULL`). Their cost
is therefore fixed and small, exactly as the original comment said.

## decision

Do not pursue this. 3 KB is 0.4% of Rover, and buying it means shipping
binaries with no SEH unwind data, which would put the FFI VEH recovery path
and any structured exception handling at risk for a rounding error. The arm-B
binaries do run (`hello` prints, `rover --version` works), but that proves
nothing: unwind data only matters when something actually unwinds, so a
passing smoke test is not evidence of correctness here.

The earlier claim that rooting these sections "resurrects the CRT functions
they describe" is withdrawn: the measurement disproves it. The fixed 137 KB
floor remains unexplained and needs a different lead. The `.rdata`/`.text`
split of the runtime itself is the next place to look, not the unwind tables.
