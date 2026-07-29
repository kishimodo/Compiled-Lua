# Current size and speed, `claude/speed-and-size`

The live numbers. Re-measured 2026-07-29 at `1501e5f`, warm tree, `-O1`, invoked
from the repository root. Supersedes the per-change figures scattered across the
other documents in this directory — those record how each step was measured, this
records where the tree actually is.

## Size

| Target | `.text` | whole file |
|---|---:|---:|
| `print("hello")` | 74,822 | **93,696** |
| `local a,b=2,3 local c=a+b print(c)` | 113,300 | **141,824** |
| `tools/bench-runtime.lua` | 129,588 | 161,792 |
| `rover/src/rover.lua` | 461,348 | **592,896** |

Against the start of this arc: **hello −32%** (137,216 → 93,696), **rover −12%**
(670,720 → 592,896).

> The rover row was **462,900 / 594,432** here until `1501e5f`. That was not a
> regression since fixed — it was a stale-object misread: `x64_emit.c` and
> `build/bin/obj/codegen/x64_emit.o` carried the *same* mtime, so `make` treated
> the object as current and kept linking the pre-imm8 encoder. Any figure in this
> directory dated before `1501e5f` may share the error. Before trusting a size
> number, confirm the object is newer than its source — equal is not newer.

### `hello` is not a representative number

A single `a + b` costs **48,128 bytes**. The chain is exact and measured:

1. `a + b` emits `ADD` followed by `MMBIN ; __add` — Lua's metamethod fallback,
   emitted after every arithmetic op.
2. `lc_module_used_libs` (`opt/passes.c`) sets `LCLIB_STRING` for any
   `OP_MMBIN`/`MMBINI`/`MMBINK`/`GETFIELD`/`GETI`/`GETTABLE`/`SELF`.
3. `runtime/stdlib_anchors.c` is **one translation unit holding all seven
   anchors**, so force-undefining one pulls all seven libraries.

Verified by which registration tables appear in the binary:

```
print("hello")                       ->  (none)
local a,b=2,3 local c=a+b print(c)   ->  string table math os io utf8 debug
```

So **~142 KB is the realistic floor today**, not 93 KB, and splitting the anchors
is worth ~40 KB on essentially every real program. It is blocked on making the
used-libs mask sound — after the split,
`local n = "o".."s"; print(package.loaded[n])` silently returns `nil`.

### What got it here

| Change | Effect |
|---|---|
| Lua stdio routed to the UCRT (`95847cf`) | −40,448 B, near-constant |
| Leaner RDI reload (`91a5452`) | −33,664 B rover `.text` |
| `aot_entry.o` size flags (`c87e2ce`) | −3,584 B |
| imm8 `SUB`/`ADD rsp` (`efca0b2`) | −4,134 B rover `.text` |
| `L->top` hoist out of the table helpers (`1501e5f`) | 1.11× on field access |

### For scale, same machine

| | Size | Runtime dependency |
|---|---:|---|
| C hello (`gcc -O2 -s`) | 14,848 | kernel32 + UCRT apisets |
| **CLua hello** | **93,696** | kernel32 + UCRT apisets |
| Rust hello (`-O`) | 125,440 | + `VCRUNTIME140.dll` |
| Go hello (`-s -w`) | 1,586,176 | — |

CLua's binary is smaller than Rust's and depends on strictly less. None of these
require an install; all four statically link a runtime *library*. Rust's hello
carries 87,299 bytes of `.text` and its panic/allocator machinery is visible in
`strings`. "No runtime" means no separately-installed VM, not "no code besides
yours" — and CLua qualifies: `luaV_execute` appears **0 times** in the binary,
there is no parser and no bytecode blob.

## Speed

Min-of-9, interpreter and compiled interleaved inside each iteration.

| Kernel | Interpreter | Compiled | Ratio |
|---|---:|---:|---:|
| Integer arithmetic | 319 ms | 132 ms | **2.41× faster** |
| Array indexing | 158 ms | 164 ms | 0.96× |
| Function calls | 294 ms | 303 ms | 0.97× |
| Table field r/w | 239 ms | 297 ms | **0.80× — slower** |

Table access losing to the interpreter is the least defensible number in the
project. The cause is measured: nearly every non-arithmetic op lowers to a call
into an `Rt_*` helper, and 58% of the instructions emitted for Rover are
helper-call glue. Two fixes are designed and quantified but unimplemented —
inlining the `GETI`/`SETI` array fast path (13× ceiling on a 30M-read loop) and the
`GETFIELD` fast path (2.38× on the op).

**Do not quote these ratios to better than ±15%.** Fifteen consecutive runs of one
unchanged binary spread 43% on this host. Only comparisons with both arms
interleaved inside each iteration are trustworthy; a before/after pair taken
minutes apart is not, and produced a phantom 2× regression earlier in this arc.

### The silent 1.3–1.5× cliff

`no_proofs` (`passes.c:183`) disables tag-check elision and unboxed residency when
a module merely *contains the string* `"debug"`, or reads `_G`, or — because
`lcode` spills global access past 255 constants — has more than 255 constants and
touches a global. **`rover/src/rover.lua` itself trips it.** A diagnostic now says
so (`ca33373`); the gate is still conservative because narrowing it soundly needs a
dataflow query Lua 5.4's opcode tables do not expose.

## Reproducing

```powershell
.\build\bin\clua.exe build <src> -O1 -o out.exe   # then objdump -h for .text
python tools\check-byte-identity.py <label>       # reproducibility, 18 rows
```

For speed, build both arms from source — `Makefile.luac` pulls backend objects
with `$(wildcard)` and will relink a stale one — then alternate the arms **inside**
each iteration and report min-of-N with the spread.

Staleness has bitten this arc four times and the last one silently corrupted the
size table above, so check rather than assume:

```bash
find clua/src -name '*.c' | while read c; do
  o=build/bin/obj/$(echo "$c" | sed 's|clua/src/||; s|\.c$|.o|')
  [ -f "$o" ] && [ ! "$o" -nt "$c" ] && echo "STALE $o"
done
```

`-nt` is strictly-newer, which is the test `make` itself applies: an A/B that
`cp`s one arm's source into place can land on the same whole second as the
object built from the other arm, and then nothing rebuilds. `touch` the source
before every arm.
