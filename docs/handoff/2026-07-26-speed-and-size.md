# Handoff: `claude/speed-and-size`

Branch off `1298fd7`. Tree green at every commit; suite **720 pass / 0 fail / 2
skip, exit 0**. Both remaining skips are closed-world `load()` cases.

Measurements: [`session-2026-07-26-speed-and-size.md`](../benchmarks/session-2026-07-26-speed-and-size.md)
and [`open-world-and-speed.md`](../benchmarks/open-world-and-speed.md). Read those
before re-deriving anything.

## What landed

| Commit | What |
|---|---|
| `68ba9b6` | Retired both FFI skips (`SYSTEM_INFO`/`MEMORYSTATUSEX`), which exposed and fixed an **infinite loop** in `memory_info.working_set_detail` |
| `933ae67` | Deep recursion is a catchable `stack overflow` instead of a silent `0xC00000FD` crash |
| `41ae262` | Removed a subagent probe that could disable the soundness gate via an env var |
| `91a5452` | Leaner RDI reload: **−33,664 B** of rover `.text` |
| `95847cf` | Lua's stdio routed to the UCRT: **−40,448 B** on every emitted PE |
| `c87e2ce` | `aot_entry.o` built with the runtime's size flags: −3,584 B |
| `08744f5` | `lua_checkstack` fast-arm inline + dispatch memo: **1.24×** on calls |
| `c9948bb` | `coroutine.close` now runs pending `__close` handlers |
| `ca33373` | Diagnostic when type proofs are disabled; recorded that **Rover trips it** |
| `c7bfb39` | Closed-world ban enforced in chunks with >255 constants |

Net size, `-O1`: `hello` 137,216 → **93,184** (−32.1%); `rover` 670,720 →
**593,920** (−11.5%).

## Corrections to the prompt that started this arc

Four premises were wrong. Do not act on them:

1. **`-ffunction-sections` is not an available lever.** Already enabled (817 and
   280 `.text` sections); the GC already recovers ~20 KB. Worth 16 bytes on
   `aot_entry.o`.
2. **"The Makefiles already glob" is false.** One level only, and
   `tools/run-tests.lua:213-218` hardcodes nine obj directories for
   `libcluatest.a`. Creating `link/pe/` breaks unit-test linking in a way that
   blames the test. Phase 4 is bigger than costed.
3. **`ip_typeprop` is real and codegen consumes it.** Its defect is marking every
   table-read and call result `UNK`.
4. **A `GcMap` lifetime bug does not exist** — that came from a wrong note in a
   memory file. `contrib_map_build` frees the *previous* allocation and rebuilds.

## Next, in the order I would take it

1. **Inline the `OP_GETI`/`OP_SETI` array fast path.** The highest
   ratio-per-line-of-work item still open: tag check, unsigned `idx-1 < alimit`
   bounds check, emptiness check, two-word move, fall through to `Rt_GetI`/`Rt_SetI`.
   Measured ceiling on a 30M-read loop is 199 ms → 15.2 ms; a realistic ~17-instruction
   lowering should land 50–70 ms.
2. **Inline `OP_GETFIELD`/`OP_SETFIELD`**: tag check, then **CALL**
   `luaH_getshortstr` — do *not* inline the hash probe, measured gain from that is
   zero (100–105 ms vs 102 ms). Worth 2.38× on the op. For SETFIELD keep
   `luaV_finishfastset`'s barrier; a missing `luaC_barrierback` is a GC crash.
3. **Narrow `no_proofs` properly** (see below). Rover itself is losing its proofs.
4. Phase 3 Tier 1: bundle `dofile("literal")` and enumerable `require`.
5. Phase 4 reorganisation, with the build-glob work done first.

## Traps worth inheriting

**`no_proofs` needs a real dataflow pass, not a pattern match.** I attempted the
narrowing twice and was wrong about the emitted shape both times — first checking
`GETFIELD`/`SETFIELD` (never occurs; the key is in a register), then bailing on any
unrecognised instruction (never survived the `LOADI` between the `GETUPVAL` and the
`SETTABLE`). Lua 5.4 dropped 5.3's per-operand `OpArgMask`, so the opcode tables
cannot answer "does this instruction read register A". Being permissive here is a
**miscompile** — tag-check elision on a module that can reach `debug.setlocal`. The
verified bytecode shape is in the benchmarks document.

**The same >255-constant spill was a live security hole in the closed-world check**,
and closing it took three attempts, each caught by the test rather than by
reasoning. If you touch that scanner, keep `tools/test-closed-world.lua`'s
both-sizes pairing: every banned construct compiled in a small chunk *and* one
padded past 255 constants. A test using only small chunks is what let it through.

**`git add -A` is unsafe while subagents have been running.** It swept a probe into
`933ae67`, and then the commit that removed it swept a *second* probe in the same
way. Diff every file you did not personally edit.

**`Makefile.luac` pulls backend objects with `$(wildcard obj/*/*.o)`,** not as
dependencies. Relinking `clua.exe` does **not** recompile a backend `.c`. My first
A/B of the RDI reload reported *zero* difference for exactly this reason — the trap
produces a null result, not an error. Build `obj/<dir>/<file>.o` explicitly in both
arms.

**This host is too noisy for absolute speed ratios.** Fifteen runs of one unchanged
binary spread **43%**. Interleave every arm *inside* each iteration, or the drift
reads as a regression — it briefly showed a 7% loss on `field` that does not exist.

**A reference Lua 5.4 is one gcc command** and it is the highest-value test layer
still missing:

```sh
gcc -O2 -std=gnu99 -DLUA_USE_WINDOWS -I lua-5.4/src -o lua54.exe \
    $(ls lua-5.4/src/*.c | grep -v lua.c) -lm      # add luac by excluding lua.c instead
```

47% of the suite is CLua-vs-CLua stdout diffs, so a defect in the shared core or a
reimplemented library passes silently on both sides. That is what hid the
`coroutine.close` bug — and `tests/conformance/coroutines.lua:115` even carried the
correct expected value in a comment while passing with the wrong one. A `tests/oracle/`
layer diffing `clua-interp.exe` against that binary would close the blind spot.

## Deliberately not done

- **Splitting `stdlib_anchors.c`** (~40 KB): fidelity-breaking until the used-libs
  mask is sound. After the split, `local n="o".."s"; print(package.loaded[n])`
  silently returns `nil`. Wrong answer, exit 0, and a per-library differential test
  cannot catch it because naming the library literally is what trips the mask.
- **`--crt=none`**: backwards as a size lever. The whole import table is 4,330
  bytes; the 41 KB win came from importing *more* from the UCRT.
- **Runtime `load()`**: impossible under both constraints (no interpreter in
  output, no JIT). Compile-time resolution is the answer.
