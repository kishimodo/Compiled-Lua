# Measured: the `claude/speed-and-size` arc

Everything here was built and run on this machine, 2026-07-26, branch
`claude/speed-and-size` off `1298fd7`. Read
[`open-world-and-speed.md`](open-world-and-speed.md) first for the baseline this
arc started from.

**Read the measurement caveat in §3 before quoting any speed number.** Size
numbers are exact and reproducible; speed numbers on this host currently are not.

---

## 1. Binary size

All at `-O1`, whole file and `.text`, internal linker, invoked from the repository
root.

| Target | `.text` before | `.text` after | file before | file after | file delta |
|---|---:|---:|---:|---:|---:|
| `print("hello")` | 114,736 | **74,342** | 137,216 | **93,184** | **−44,032 (−32.1%)** |
| `rover/src/rover.lua` | 536,446 | **462,436** | 670,720 | **593,920** | **−76,800 (−11.5%)** |
| `tools/bench-runtime.lua` | — | 132,138 | 205,824 | **164,864** | **−40,960 (−19.9%)** |

Output remains byte-reproducible across repeated builds, and `-O1` ≡ `-O2` still
holds.

### Where it came from

| Change | hello | rover | Notes |
|---|---:|---:|---|
| Route Lua's stdio to the UCRT (`95847cf`) | −40,448 | −40,448 | Near-constant; the dominant lever |
| Leaner RDI reload (`91a5452`) | ~0 | −33,664 `.text` | Scales with helper-call density |
| `aot_entry.o` size flags (`c87e2ce`) | −3,584 | −3,584 | Constant |

The stdio change is worth the same absolute amount everywhere because it removes a
fixed block of MinGW's static float conversion machinery. The RDI reload is worth
nothing on `hello` (four call sites) and 33 KB on Rover (~3,700 reload sites) —
the same shape as the earlier imm32 change.

### The `.text` attribution that made this findable

`hello.exe`'s 114,736 bytes of `.text`, before this arc, via `ld -Map`:

| Contributor | Bytes | Share |
|---|---:|---:|
| MinGW static glue (of which float conversion ~38,816) | 44,352 | 38.8% |
| Lua 5.4 core | 38,000 | 33.2% |
| CLua runtime (of which the `Rt_*` helpers are only 800) | 14,864 | 13.0% |
| `lauxlib` | 7,552 | 6.6% |
| `lbaselib` + `loadlib` | 8,400 | 7.3% |
| CRT import thunks | 968 | 0.8% |
| **The user's program** | **282** | **0.2%** |

The single most useful thing in this table is the last row. A hello-world binary
is not bloat around a small program — it is a Lua 5.4 implementation, and the
program is 0.2% of it.

**`-ffunction-sections` is NOT an available lever.** `docs/roadmaps/no-crt.md` §8
named it as the largest untapped reduction; that is refuted. `runtime-aot.a` and
`liblua54.a` already carry it (817 and 280 `.text` sections), the section GC
already marks per-section and already recovers ~20 KB, and the non-sectioned MinGW
members have only 2–17 mutually-referencing symbols each. Adding it to
`aot_entry.o` was worth 16 of that commit's 3,584 bytes; the rest is `-Os` plus
dropped unwind tables.

### Honest floor

~68–74 KB whole-exe for a faithful, statically-linked Lua 5.4. Not 20 KB, and not
reachable by removing the CRT — see §5. `--shared-rt` already goes lower today
(~31 KB exes against a ~252 KB DLL) if a sidecar DLL is acceptable.

---

## 2. What the stdio shim had to get right

Three fidelity gaps, two of which were only visible by probing.

**Signalling NaN.** MinGW prints `nan` for every NaN; the UCRT prints `-nan(ind)`
for a negative one and `nan(snan)` for a signalling one. `fabs()` is not
sufficient — it clears the sign bit but not the quiet bit, so signalling NaN still
diverges. Reachable from pure Lua with no arithmetic and no FFI:

```lua
string.unpack("<d", "\x01\x00\x00\x00\x00\x00\xf0\x7f")
```

Canonicalising the whole bit pattern to `0x7ff8000000000000` is exactly right,
because the target implementation cannot distinguish NaNs either — and it is 64
bytes *smaller* than the `fabs` version, since dropping `isnan`/`fabs` drops the
libm references.

**`%p` needs zero-fill handling, not just case.** MinGW writes 16 lowercase digits
for a plain `%p`, but **minimal** hex space-padded once a width is present:

| format | oracle (MinGW) | case-only shim would give |
|---|---|---|
| `%p` | `000000000072cb70` | `00000000014FFF50` |
| `%-20p` | `6ed330              ` | `00000000014FFF50    ` |

Lua's own `checkformat` rejects `%08p`, `%.4p`, `%#p`, `%+p`, `% p` and `%020p`
before they reach the formatter, which bounds the shapes to reproduce to exactly
those two.

**Archive ordering on the gcc path.** `runtime-aot.a` is scanned before
`liblua54.a`, and `ld` extracts a member only for an already-undefined symbol — at
that point nothing has referenced `__mingw_sprintf`, because the reference is in
`lobject.o` which has not been pulled. So the shim was skipped and libmingwex
satisfied it later, leaving `--ld=gcc` builds 40,960 bytes larger than internal
ones. `tools/test-clua-cli.lua` caught it as a size-parity failure. Fixed with
three `-Wl,--undefined=` flags; the internal linker needed nothing because
`resolve_fixpoint` re-scans until the undefined set settles. Reordering the
archives cannot work — `runtime-aot.a`'s helpers call into the Lua core, so no
single ordering satisfies both directions.

---

## 3. Speed — and why the numbers here are ranged

### The reliable measurement: interleaved A/B

All arms alternate **within each iteration**, so systematic drift affects them
equally. Min of 9:

| kernel | before | B1 only | B1+B2 | net |
|---|---:|---:|---:|---:|
| function calls | 283 ms | 232 ms | **228 ms** | **1.24×** |
| table field r/w | 258 ms | 241 ms | **229 ms** | **1.13×** |
| array indexing | 133 ms | 122 ms | 125 ms | **1.06×** |

B1 is the `lua_checkstack` no-growth inline; B2 is the dispatch memo plus forcing
`CurrentCache`/`CacheFindIn` inline.

### The caveat, stated plainly

**This host is too noisy to pin absolute ratios against the interpreter.** Fifteen
consecutive runs of one *unchanged* binary spread **43%**:

```
field: min 270  p25 281  median 298  max 388
call:  min 249  p25 264  median 291  max 329
```

A two-arm comparison taken separately from the three-arm one disagreed with it —
the same "before" binary measured 273 ms in one run and 283 ms in the other — and
that drift briefly read as a 7% *regression* on field that does not exist. Any
vs-interpreter ratio in this document or in commit messages on this branch should
be read as **±15%** until it is re-taken on a quiet machine, or replaced by
instruction counting rather than wall clock.

### A claim that did not reproduce

The design note motivating §3 predicted **1.41×** on a 40M-call kernel from B1+B2.
Measured here it is **1.24×** on calls. Recorded so the larger figure is not
carried forward.

### The `no_proofs` gate is worse than "a silent cliff" — it hits Rover

`passes.c` disables `ip_typeprop` (and therefore tag-check elision and unboxed
register residency) when a module either carries the string constant `"debug"` or
reaches a global through `_ENV` in a register. Measured cost on an identical
20M-iteration integer loop:

| trigger | before | after | penalty |
|---|---:|---:|---:|
| one extra constant vs 300 constants + a global | 103 ms | 152 ms | **1.48×** |
| adding `local _ = "debug"` | 107 ms | 159 ms | 1.49× |
| adding `local _ = _G` | 107 ms | 141 ms | 1.32× |

**`rover/src/rover.lua` trips it.** The project's own flagship program compiles
with proofs off, because it has more than 255 constants and touches a global — so
`lcode` spills the access to `GETUPVAL _ENV` + `LOADK` + `GETTABLE`, which
`lc_module_reflects_globals` cannot distinguish from real reflection. That is also
why an earlier analysis found Rover resolving only 5 of its 1,054 call sites.

Verified emission, from `luac -l` on a 300-constant chunk:

```
310  [2]  GETUPVAL  1 0            ; _ENV        <- small file emits instead:
311  [2]  LOADK     2 "GlobalAcc"                ;  SETTABUP 0 1 2 ; _ENV "GlobalAcc"
312  [2]  LOADI     3 0
313  [2]  SETTABLE  1 2 3
```

A diagnostic now names which of the two causes fired (`CLUA_QUIET_PROOFS=1`
silences it). The gate itself is **deliberately still conservative.** Two
structural approximations were attempted and both were wrong about the emitted
shape — the first checked for `GETFIELD`/`SETFIELD` (never occurs; the key is in a
register), the second bailed on any unrecognised instruction and so never fired
past the first `LOADI`. Narrowing it soundly needs a real "does this instruction
read register A" query, which Lua 5.4's opcode tables do not expose — 5.4 dropped
5.3's per-operand `OpArgMask`. Being permissive here is a **miscompile**, not a
slow binary, so it waits for a proper dataflow pass rather than a third guess.

Blast radius measured: 4 of 59 differential tests, 1 of the first 60 packages, and
Rover.

### The honest ceiling

Roughly **1.5–3× over the interpreter on general Lua, 3–5× on array-numeric code,
and near-C only for an annotated subset.** A perfectly inlined `t.x` read is about
12 cycles against ~1 for a C struct field; closing that needs shape guards plus
recompilation, i.e. a JIT, which is forbidden. The two legitimate sources of the
type information that *would* unlock it are `ip_typeprop` and optional `---@`
annotations.

### Where the remaining time goes

58% of instructions emitted for Rover are helper-call glue — 4,772 call shims,
3,746 RDI reloads (now cheaper), 2,260 savedpc stores. The interpreter's entire
computed-goto dispatch is 8 instructions; the glue around one `GETFIELD` is 21
before `Rt_GetField`'s own 41-instruction body. Inlining the field fast path is
measured at 2.38× on the op. One explicit non-lever: inlining the *hash probe*
measured **zero** gain (100–105 ms vs 102 ms) — inline the tag check and call
`luaH_getshortstr`.

---

## 4. Correctness work in the same arc

- **Deep recursion no longer crashes.** A compiled binary died with an unhandled
  `STATUS_STACK_OVERFLOW` (0xC00000FD), silent and not catchable, between depth
  9,000 and 15,000. Now a catchable `stack overflow` byte-identical to the oracle.
  The native frame costs **292 bytes** (measured: 16 MB reserve / 57,344 frames),
  and that size is invariant in the user program because Lua registers live on the
  heap-allocated Lua stack addressed through RDI.
- **An infinite loop in `memory_info.working_set_detail`**, exposed by retiring a
  skip. Progress was compared against the base `VirtualQuery` returned rather than
  the address queried; at the top of the x64 user address space those differ and
  `addr` froze at `0x7fffffff0000` for 400,000 iterations.
- **`windows.ToWide`/`FromWide` fixed-buffer failure** (see the earlier arc).

Suite went 699 pass / 0 fail / 4 skip → **715 pass / 0 fail / 2 skip**. Both
remaining skips are closed-world `load()` cases.

---

## 5. Two things not to re-propose

- **`--crt=none` is backwards as a size lever.** The whole import table is 4,330
  bytes; the 41 KB win came from importing *more* from the UCRT, not less. See
  `no-crt.md` §0.
- **Splitting `stdlib_anchors.c` is fidelity-breaking as specified.** It is worth
  ~40 KB on any real program, but the used-libs mask must be made sound *first*:
  after the split, `local n = "o".."s"; print(package.loaded[n])` silently returns
  `nil` where it returns a table today. That is a wrong answer with exit 0, and a
  per-library differential test cannot catch it, because naming the library
  literally is exactly what trips the mask.

## Reproducing

```powershell
# size
.\build\bin\clua.exe build build\tmp\hello.lua -O1 -o h.exe   # then objdump -h
# speed: build both arms, then alternate them INSIDE each iteration
# and report min-of-N plus the spread, per docs/benchmarks/README.md
```
