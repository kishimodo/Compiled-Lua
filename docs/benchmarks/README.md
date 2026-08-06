# Benchmarks: current baselines and how to reproduce them

Repository-relative measurement notes. Record the commit measured, the machine
conditions, and the run count on every new entry, so a later reader can tell a
real delta from desktop noise.

**The live table is [`size-and-speed-current.md`](size-and-speed-current.md).**
The rest of this file is standing methodology and historical baselines.

## A caveat on every SHA-256 recorded here

The header-dependency work exposed that **342 of 618 objects had never been
compiled with dependency tracking** and were stale — including the whole Lua core
and the AOT runtime archives. Running `clean-objs` plus a full build recompiled
them from current sources for the first time, which moved every emitted binary:
`print("hello")` lost 80 bytes of `.text` and 52 of `.rdata` despite having a
single user function, so the change is in the linked runtime, not in codegen.

Consequences for anyone reproducing these notes:

- the absolute SHA-256 values recorded in this directory predate that rebuild and
  will **not** reproduce; treat them as evidence of *reproducibility at the time*,
  not as fixed expectations;
- the **deltas** are unaffected, because each A/B compared two builds against the
  same runtime — only the compiler differed between the arms;
- the binaries shipped before the rebuild were partly built from out-of-date
  runtime objects. That is what the tracking work was for, and it turned out to
  be a live condition rather than a hypothetical one.

## Ground rules

- **State the commit, not the branch.** Branches move; a size table without a
  commit id is not a baseline.
- **Warm runs only, with a discarded warm-up.** A cold first run measures the
  filesystem cache, not the compiler.
- **Report the spread.** On this class of machine the run-to-run spread on a
  ~200 ms build is roughly +-25 ms, which is wider than several deltas that have
  been proposed as wins. A median without a spread invites overclaiming.
- **Check byte-reproducibility across the change.** Two builds of the same input
  at the same optimization level must share one SHA-256, before and after.
- **Whole-file size and `.text` size are different denominators.** Say which.
  A `.text` win can vanish in the whole-PE number because the PE file alignment
  is 512 bytes.

## Size baselines

Both tables are whole-file bytes, invoked from the repository root as
`clua build <src> -O<n>`. **Keep both.** The upper one is what the arc started
from; the lower one is what it ended at, and a later reader needs the pair to
check a delta rather than trust one.

### Baseline at `7fec28f` (start of the arc)

| Build | `-O0` | `-O1` | `-O2` |
|---|---:|---:|---:|
| `print("hello")` | 137,216 | 137,216 | 137,216 |
| `rover/src/rover.lua` | 724,480 | 739,328 | 739,328 |

`-O1` and `-O2` byte-identical, SHA-256
`e474660e25b1481c3c8ccbe9147e4c72e11b5e91964640152eba673ac0d21bde`.

### Current, re-measured at `7dc2b11` (2026-07-26)

| Build | `-O0` | `-O1` | `-O2` | | `.text` `-O0` | `.text` `-O1` |
|---|---:|---:|---:|---|---:|---:|
| `print("hello")` | 137,216 | 137,216 | 137,216 | | 114,736 | 114,736 |
| `rover/src/rover.lua` | 655,872 | 670,720 | 670,720 | | 521,726 | 536,446 |

`-O1` and `-O2` still byte-identical, SHA-256
`c7b3601d84008040f867810e2ae35d65c3e47e66b2e14dcd237ff7c1afb02fa5`, and a repeat
build reproduces it exactly.

**Same-invocation delta:** Rover `-O1` 739,328 → 670,720 = **−68,608 = −9.28%**;
`-O0` 724,480 → 655,872 = **−68,608 = −9.47%**. These have since moved further —
see [`size-and-speed-current.md`](size-and-speed-current.md) for the live rover
number.

One confound applies to the upper table and not the lower: 739,328 predates the
`clean-objs` rebuild described above, which changed every emitted binary. It is
the right *documented* starting point, but it is not bit-comparable to a
post-rebuild build; the `.text` deltas in the A/B document, whose arms were both
freshly built, are the stronger evidence.

**Caveat found while re-measuring:** whole-file size moves with the *length of
the source path*, because each of Rover's 97 Protos embeds it. Building the same
bytes as `rover.lua` from its own directory gives 723,456 / 738,304 — about 1 KB
smaller at both levels, purely from the shorter string. Always record the
invocation, and never compare a build made one way against a build made another:
that alone fabricates a ~1 KB "win".

Read alongside:

- `-O2` is byte-identical to `-O1`, which is the standing evidence that the
  higher `-O` levels do no additional work;
- `-O1` costs Rover ~14 KB over `-O0` (multi-arm codegen fastpaths, not any
  higher-level optimization);
- Rover's earlier growth from 689,152 to 799,232 bytes was **source** growth
  (`rover/src/rover.lua` went 1,972 to 2,555 lines with the transactional store
  work), not a codegen regression. The table above is post-`savedpc`-hoist.

Feature-scan false positives, measured on a tiny program — a data string
currently looks like a library use:

| Source | Output size |
|---|---:|
| `print("hello")` | 137,216 |
| `print("bit")` | 173,056 |
| `print("debug")` | 201,216 |
| a harmless `"string"`/`"table"`/`"math"`/`"io"`/`"os"`/`"utf8"` literal | 184,320 |

## Current compile-time baseline

Warm medians compiling `rover/src/rover.lua` with the internal linker:

| Configuration | Wall time |
|---|---:|
| `clua check` | ~14 ms (~52 ms including process start) |
| `-O1`, before the archive index | ~180 ms (median, n=9, at `bc1ea8f`) |
| `-O1`, **current** | **~87 ms** (median, n=9, range 83-90) |

`print("hello")` at `-O1` went from ~153 ms to **~76 ms** (median, n=11). A tiny
program still costs almost as much as Rover, because the link is dominated by the
fixed runtime/CRT closure rather than by user code — halving that fixed cost is
what the archive index did.

The front-end check is a small fraction of a warm build, so the build is
link-dominated.

**Corrected 2026-07-25, then fixed:** the earlier claim that the remaining floor
is "archive parsing plus PE writing, not symbol resolution" was wrong. Reading and
indexing all ten CRT archives (14 MB) measures 7-8 ms, while archive *symbol
resolution* was 41 million string compares per link — about 43% of a warm build.
Indexing it halved the build. See
[`archive-symbol-lookup.md`](archive-symbol-lookup.md).

## Harnesses

- `tools/bench-link.sh <clua.exe> <script.lua> <runs> [-O1]` — warm min/median/max
  in milliseconds, one discarded warm-up.
- `tools/bench-optimizer.lua` — optimizer-level comparison.
- `.text` size: `objdump -h <exe>`. MinGW binutils in `CLUA_MINGW_BIN` are
  **unprefixed** (`objdump.exe`, `size.exe`, `nm.exe`); there is no
  `x86_64-w64-mingw32-objdump.exe`.

### Single-object A/B without two clean trees

When a change touches few files, rebuild only those objects instead of two full
trees:

1. `git checkout <baseline-ref> -- <the changed files>`;
2. `cmd /c "build\build-luac.bat"`, measure, then `git checkout HEAD -- <files>`
   and repeat.

Header dependencies are tracked, so step 2 no longer needs the manual object wipe
this recipe used to require — editing a header rebuilds its dependents. Use
`make -f build/Makefile clean-objs` if you want a deliberately clean arm; it
removes objects and fragments together.

For a single-object change (for example `clua/src/link/pe_emit.c`) it is enough
to recompile that one object with the flags from the build log and relink
`clua.exe` from the existing `build/bin/obj/**` list.

## Files

Implemented changes:

- [`linker-index.md`](linker-index.md) — symbol/contribution indexing (`092122b`).
- [`codegen-savedpc.md`](codegen-savedpc.md) — `savedpc` base hoist (`9d3ded2`).
- [`helper-call-args.md`](helper-call-args.md) — imm32 helper-call arguments:
  **-73,216 bytes** on Rover, -12% of `.text`, `hello` unchanged.
- [`archive-symbol-lookup.md`](archive-symbol-lookup.md) — per-archive armap and
  member indexes: **-52% warm build time**, output byte-identical.
- [`codegen-context.md`](codegen-context.md) — codegen's six mutable file-scope
  objects drained to zero; a pure refactor, so the evidence is what did not move.

Measured and rejected:

- [`link-gc-unwind-roots.md`](link-gc-unwind-roots.md) — unrooting
  `.pdata`/`.xdata` frees 128 bytes of `.text`; the resurrection hypothesis is
  refuted and the idea is not worth pursuing.

Harnesses live in `tools/`: `bench-link.sh`, `bench-optimizer.lua`,
`bench-armap.c`, `count-imm-sites.py`, `check-byte-identity.py`,
`bench-runtime.lua`.
