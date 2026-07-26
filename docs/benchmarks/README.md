# Benchmarks: current baselines and how to reproduce them

Shared, repository-relative measurement notes. Any agent may add a file here;
record the commit measured, the machine conditions, and the run count, so a
later reader can tell a real delta from desktop noise.

Reproduce every path in this directory from the worktree you are standing in:

```powershell
python tools/agent-coordination/repo-paths.py --get benchmarks_dir
```

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

## Current size baseline

Re-measured at `7fec28f`, whole-file bytes, invoked from the repository root as
`clua build rover/src/rover.lua -O<n>`:

| Build | `-O0` | `-O1` | `-O2` |
|---|---:|---:|---:|
| `print("hello")` | 137,216 | 137,216 | 137,216 |
| `rover/src/rover.lua` | 724,480 | 739,328 | 739,328 |

`-O1` and `-O2` are byte-identical here, SHA-256
`e474660e25b1481c3c8ccbe9147e4c72e11b5e91964640152eba673ac0d21bde`, and a repeat
build reproduces it exactly.

**Caveat found while re-measuring:** whole-file size moves with the *length of
the source path*, because each of Rover's 97 Protos embeds it. Building the same
bytes as `rover.lua` from its own directory gives 723,456 / 738,304 — about 1 KB
smaller at both levels, purely from the shorter string. The `savedpc` note's
`-O1` figure of 738,816 sits between the two, so it was taken with a third
invocation form. Always record the invocation, and never compare a build made one
way against a build made another: that alone fabricates a ~1 KB "win".

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
| `clua check` | ~14 ms |
| `-O0` | ~177 ms |
| `-O1` | ~172 ms |
| `-O2` | ~170-230 ms |
| `-O3` | ~207 ms |

The front-end check is a small fraction of a warm build, so the build is
link-dominated. The remaining floor is archive parsing (a 13.9 MB CRT sysroot)
plus PE writing, not symbol resolution.

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
2. delete the affected backend objects — `build/bin/obj/{ir,opt,codegen,link,driver}`
   — because the Makefile does not track header dependencies and a stale object
   silently produces an empty-output binary;
3. `cmd /c "build\build-luac.bat"`, measure, then `git checkout HEAD -- <files>`
   and repeat.

For a single-object change (for example `clua/src/link/pe_emit.c`) it is enough
to recompile that one object with the flags from the build log and relink
`clua.exe` from the existing `build/bin/obj/**` list.

## Files

- [`linker-index.md`](linker-index.md) — symbol/contribution indexing (`092122b`).
- [`codegen-savedpc.md`](codegen-savedpc.md) — `savedpc` base hoist (`9d3ded2`).
