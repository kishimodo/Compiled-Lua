# Session A/B: `7fec28f` vs the delivered slice

The whole-session before/after, measured 2026-07-25 with **both arms freshly and
fully built** from their own worktrees. That matters: it removes the stale-runtime
confound described in [`README.md`](README.md), so these are the numbers to quote
rather than the per-commit figures recorded during the work.

Method: baseline worktree at `7fec28f`, `build-luac.bat` run to completion in each
tree, same invocations, same machine, warm.

## Binary size

| Target | file before | file after | delta | | `.text` before | `.text` after | delta |
|---|---:|---:|---:|---|---:|---:|---:|
| `print("hello")` `-O1` | 137,216 | 137,216 | **0** | | 114,800 | 114,736 | -0.06% |
| runtime benchmark `-O1` | 207,872 | 205,824 | **-0.99%** | | 172,110 | 170,254 | -1.08% |
| `rover/src/rover.lua` `-O1` | 738,816 | 670,720 | **-9.22%** | | 605,694 | 536,446 | **-11.43%** |
| `rover/src/rover.lua` `-O0` | 724,480 | 655,872 | **-9.47%** | | 590,910 | 521,726 | **-11.71%** |

Rover's figure is if anything *understated*: `rover/src/rover.lua` grew by ~50
lines during the session (the `tar` pin), so part of the codegen win is spent
carrying new source.

The size win scales with user-code volume, which is why the three targets differ
so much: Rover has 4,724 helper-call sites, the benchmark a few hundred, `hello`
four. `hello` does not move at all — its 137,216 bytes are runtime and CRT, and
the 64-byte `.text` saving disappears inside the 512-byte PE file alignment.

## Compile time

Median of 9 warm runs after a discarded warm-up, `-O1`:

| Target | before | after | change |
|---|---:|---:|---:|
| `print("hello")` | 153 ms (146-157) | **73 ms** (70-79) | **-52%** |
| runtime benchmark | 174 ms (171-177) | **74 ms** (72-84) | **-57%** |
| `rover/src/rover.lua` | 187 ms (185-210) | **86 ms** (83-98) | **-54%** |

Ranges are min-max across the 9 runs; the arms do not overlap, so unlike the
runtime figures below this is comfortably outside noise.

Almost all of it is the archive symbol index — see
[`archive-symbol-lookup.md`](archive-symbol-lookup.md). The cost removed was a
fixed per-link tax (41 million string compares), which is why a three-line program
improves as much as Rover.

## Runtime speed of the generated code: unchanged

This is the one that had **not** been measured until asked for, and the honest
answer is that there is no measurable change.

`tools/bench-runtime.lua`, weighted toward what the codegen changes touched
(helper-call arguments appear in every table, global, upvalue and call op), plus
integer and float arithmetic, array indexing, metamethod dispatch and string
building. 13 interleaved runs per arm at `BENCH_N=8` (~250 ms per run):

| Estimator | before | after | change |
|---|---:|---:|---:|
| min of 13 | 251.4 ms | 250.9 ms | **-0.18%** |
| 25th percentile | 256.1 ms | 257.0 ms | +0.37% |
| median | 262.9 ms | 266.3 ms | +1.30% |

Floor jitter (min to p25) is 4.7-6.1 ms, about 2%, so every estimator sits inside
the noise: **runtime performance is unchanged.** Both binaries print the same
checksum, and both match the interpreter.

That is the *expected* result, not a disappointment. The imm32 change executes the
same number of instructions with shorter encodings, so it was never a speed
change; the archive index is compile-time only. Nothing in this slice targeted
runtime, and nothing regressed it.

Two honest caveats on the method: a shorter benchmark (38 ms) could not resolve
1% against process-start jitter at all — the workload had to be scaled up before
the numbers meant anything — and min-of-N is used because interference is
one-sided (nothing makes a process faster than its uncontended time). Resolving a
sub-1% runtime effect would need a quiet machine or instruction-count measurement
rather than wall-clock.

## Correctness held throughout

- full suite **697 pass / 0 fail / 5 expected skips / 0 XFAIL / 0 XPASS**;
- output byte-reproducible: all 18 rows of `tools/check-byte-identity.py` identical
  across two consecutive runs;
- `-O1` and `-O2` still byte-identical, which is what `tools/test-olevel-contract.lua`
  pins;
- the benchmark's checksum agrees between the interpreter, the baseline build and
  the current build.

## Reproducing

```powershell
.\tools\agent-coordination\new-worktree.ps1 base session-baseline -StartPoint 7fec28f
# build both trees with build\build-luac.bat, then:
bash tools/bench-link.sh ./build/bin/clua.exe rover/src/rover.lua 9 -O1   # compile time
python tools/check-byte-identity.py <label>                               # size + hashes
# runtime: compile tools/bench-runtime.lua in each tree and time the exes,
# interleaved, comparing minima.
```
