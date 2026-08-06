# measured: the open-world cost, and where compiled code actually loses

Measured 2026-07-26 on `codex/concurrency-size-stability` at `aea0acd`. Every
number here was produced by building and running something, not estimated.
The two questions were: what does un-restricting `load`/`dofile`/`require`
cost, and why is compiled output slower than the reference interpreter on
ordinary code.

---

## 1. speed versus the reference interpreter

Compiled `-O1`, min-of-5 wall clock, kernels written to avoid accidentally
disabling the type proofs (see section 2, this matters more than anything
else here).

| Kernel | Interpreter | Compiled | Ratio |
|---|---:|---:|---:|
| Integer arithmetic (20M iterations) | 250 ms | 107 ms | 2.34x faster |
| Array indexing (`a[i]` sum, 8M) | 119 ms | 110 ms | 1.08x, break-even |
| Function calls (8M) | 203 ms | 231 ms | 0.87x, slower |
| Table field read/write (8M) | 179 ms | 225 ms | 0.79x, slower |

The losses are real and reproducible, not a measurement artefact. They
persist with clean kernels that keep every proof enabled.

### why the losses happen

Nearly every non-arithmetic operation is lowered to a call into an `Rt_*`
runtime helper (`LcCg_EmitHelperCall3` is the only shim; Rover has 4,724
such sites). The interpreter pays one dispatch per opcode; compiled code pays
argument setup, a `savedpc` store, a call, and result handling. For a table
field read that is more work than the interpreter's inline path, so compiled
output loses.

Arithmetic wins because it lowers to real inline instructions and the type
proofs let the tag checks be elided.

The single highest-value optimisation is therefore inlining the hot helper
fast paths. Check the array part bounds inline, or probe one hash node
inline, and only call the helper on the slow path. That should convert 0.79x
and 0.87x into wins without touching semantics.

---

## 2. `no_proofs` is a silent 1.3x to 1.5x performance cliff

`clua/src/opt/passes.c:183`:

```c
bool no_proofs = lc_module_uses_debug(m) || lc_module_reflects_globals(m);
```

`lc_module_uses_debug` scans every Proto's constants for the string
`"debug"`. `lc_module_reflects_globals` trips on `OP_GETUPVAL` of `_ENV` or
`GETTABUP _ENV "_G"/"_ENV"`. When either fires, tag-check elision and
unboxed register residency are both disabled module-wide.

Same 20M arithmetic kernel, identical except for one added line:

| Variant | min-of-5 | Cost |
|---|---:|---:|
| Clean | 107 ms | - |
| `local _ = _G` added | 141 ms | 1.32x |
| `local _ = "debug"` added | 159 ms | 1.49x |

A user writing ordinary Lua can lose a third to half of their arithmetic
performance by mentioning `"debug"` in a string, with no diagnostic. That is
a usability bug, not just a perf note: the trigger is invisible, the cost is
large, and the analysis is a constant scan rather than a real reachability
test. It also invalidated an earlier measurement in this session: a
benchmark reading globals through `os.getenv` reported arithmetic at 1.80x
when the true figure with proofs active is 2.34x.

At minimum this needs to be visible (a `-Wproofs-disabled` style warning
naming the Proto and constant that tripped it). Better, it needs to be
precise: a string constant is not a use of the `debug` library.

---

## 3. un-restricting `load` / `dofile` / `require`

### it is four stub bodies away from working

`lparser.o`, `lcode.o`, `llex.o`, `lundump.o` and `ldump.o` are already
compiled into every shipped archive (`ar t build/bin/liblua54-embedded.a`).
They are kept out of the executable only because `aot_entry.o` defines the
trigger symbols first on the link line, the stub bodies in
`clua/src/runtime/closed_world_stubs.c`, textually `#include`d at
`clua/src/runtime/aot_entry.c:152`:

- `luaY_parser` -> `luaD_throw(LUA_ERRSYNTAX)`
- `luaU_undump` -> throw
- `luaU_dump` -> return 1
- `luaX_init` -> no-op

Deleting only that `#include` and linking the full `lvm.o` instead of
`lvm_nointerp.o` makes `load()`, `dofile()` and dynamic `require()` work end
to end on an unmodified clua-produced object, including the on-disk package
searcher, which is already linked. This was verified by building it.

### the size ladder (hello, `print("hello")`)

All rows relinked with one `gcc`/`ld` invocation so they are comparable.
(`clua.exe`'s internal linker produces 137,216 for the same source, 512
bytes less, one PE file-alignment block.)

| Variant | Bytes | Delta vs closed |
|---|---:|---:|
| Closed world (today) | 137,728 | - |
| + full `lvm.o` (interpreter loop only) | 156,160 | +18,432 |
| + parser only | 169,984 | +32,256 |
| + parser + interpreter | 188,416 | +50,688 |
| Closed world + all 7 stdlibs | 184,832 | +47,104 |
| Full open world | 235,008 | +97,280 (+70.6%) |
| + FFI reachable | 270,336 | +132,608 (+96.3%) |

Per-object `.text`: `lparser.o` 16,576; `lcode.o` 12,160; `llex.o` 6,528;
`lundump.o` 3,072; `ldump.o` 1,888. Interpreter loop alone 18,496 (`lvm.o`
22,528 vs `lvm_nointerp.o`'s 21 `.text$*` sections summing to 4,032).

The tax is near-constant ~50 KB, so it is brutal on small programs and cheap
on large ones: rover goes 675,328 -> 724,992, only +7.35%.

### the speed consequence is the opposite of what you would guess

Loaded code runs interpreted, permanently, since native codegen at run time
is a JIT and forbidden. Measured inside one open-world exe, the same source
as an AOT body versus `load()`ed:

| Kernel | AOT | Loaded | |
|---|---:|---:|---|
| Integer arithmetic | 0.0150 s | 0.0360 s | 2.40x slower |
| Table field access | 0.0580 s | 0.0360 s | 0.62x, faster |
| Function calls | 0.0870 s | 0.0770 s | 0.89x, faster |

Loaded code being faster on table and call work is a direct consequence of
section 1: CLua's AOT output currently loses those cases to the interpreter.

The real casualty is not the interpreter, it is losing the proofs. Open world
forces `no_proofs` module-wide (section 4), which costs 2.5x on the one
kernel where CLua beats the interpreter: 0.0060 s -> 0.0150 s. Floats barely
move (0.0440 -> 0.0460).

> Net: an open-world CLua executable is slower than the reference
> interpreter on essentially every kernel measured. "No restrictions" and
> "faster than the interpreter" are in direct conflict unless the proofs can
> be preserved.

Startup is unaffected (30 runs of hello: closed 893 ms, open 861 ms, noise),
and `load()` itself is fast: 400 compiles of a 29,351-byte chunk in 0.308 s
= 0.77 ms each, 36 MB/s. The parser is not a runtime bottleneck.

---

## 4. what open world makes unsound

Two guards at `passes.c:183` do not catch loaded code, because a legitimate
`load(...)` call is `GETTABUP _ENV "load"` which trips neither:

- Type proofs. A loaded chunk's `_ENV` is the host globals table, so it can
  call any AOT function with arbitrarily typed arguments, and reach
  `debug.setlocal`/`setupvalue`. Proofs feed tag-check elision at
  `clua/src/codegen/codegen.c:660, 853-858, 1257, 1842-1858`.
- Unboxed register residency (`codegen.c:1728-1795`) is worse than a
  wrong-type error: codegen keeps integer-proven locals in registers across
  whole loop regions, so a `debug.setlocal` from loaded code writes a stack
  slot the running native code is not reading. A silently ignored write, not
  a fault.
- Stdlib pruning. `lc_module_used_libs` (`passes.c:57-95`) prunes libraries
  by string-constant scan, so loaded code calling `string.format` in a
  program that never names `"string"` gets `nil`. All 7 must be linked:
  +47,104 bytes.

### a real memory-safety hazard, not just a fidelity one

`clua/src/jit/dispatch.c:159-199` caches native bodies keyed by raw `Proto*`,
with no invalidation path (`grep -n "Unregister|Invalidate|Remove|Evict"`
finds nothing). Module Protos are rooted only by their `package.preload`
closures (`protoinit_rt.c:326-351`). Drop a preload root, let the GC free
the Proto, then `load()` a chunk whose fresh Proto lands on the same address,
and the cache hits a stale entry and dispatches the wrong native body.

In the closed world nothing can allocate a Proto after startup, so a
dangling key can never be re-matched. That is exactly the invariant `load()`
destroys. This must be fixed before any open-world mode ships: pin every
blob-built Proto with one `luaL_ref` beside the preload registration, or
give the cache a removal path.

---

## 5. recommendation

Tier 1: extend compile-time resolution. Zero binary cost, full AOT speed,
every proof still sound. This removes most real reasons users hit the
restriction:

- `dofile("literal")` -> bundle the file like `require "literal"` already is.
  `resolve.c:84-141` and `:320-410` already do the transitive scan;
  `closed_world.c:19` merely bans it with no bundling alternative.
- `require(<enumerable expression>)`, meaning `require(cond and "a" or "b")`,
  `require(t[k])` over a constant table, bundle every candidate, resolve
  from `package.preload` at run time. `closed_world.c:28-33` today demands
  the very next opcode be `OP_LOADK`.
- `load(<constant-foldable string>)` -> compile the string at build time.

The enumeration must be conservative: if the candidate set cannot be proven
finite, keep the current compile error rather than guessing.

Tier 2: an opt-in `--open-world` flag, paying ~50 KB + ~47 KB and the proof
loss only for programs that ask. Skip `Lc_CheckClosedWorld` (`main.c:209`);
force `no_interp=0, used_libs=ALL, require_ffi=1` (`main.c:343-348`); ship a
second prebuilt `aot_entry_open.o` in `dist\lib`; force `no_proofs` at
`passes.c:183`.

Caveat: the default linker is the internal one (`pe_link_v2.c:322-331`) and
only the `gcc`/`ld` path was validated. The internal linker would have to
extract `lparser.o`/`lcode.o`/`llex.o` with their
`.rdata$.refptr.luaP_opmodes` and `.refptr.luai_ctype_` COMDATs. Make
`--open-world` imply `--ld=gcc` until a differential test covers the
internal path.

Do not pursue runtime native compilation. It is a JIT, it is forbidden, and
the ceiling is absolute: the only two engines that can exist in the binary
are pre-compiled native bodies and the bytecode interpreter.

Bonus: open world un-skips the two `load()`-only behavioral tests
(`tools/run-tests.lua:265-268`) and removes the closed-world evasion
divergence where `_G["lo".."ad"]` raises a stub error instead of parsing.
