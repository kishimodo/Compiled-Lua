# Internal linker: archive symbol resolution

Measured 2026-07-25 against the tree's own `ar_read.o` at `7fec28f`, so this
times the shipped code rather than a reimplementation, and re-measured with
in-linker counters at `37c84e2`. Reproduce with `tools/bench-armap.c` and with
`CLUA_GC_DEBUG=1` (see below).

## Why this exists

The linker-index work in `092122b` indexed `gsym_find` and the contribution
lookups and delivered only -1.9% on a Rover build. Its write-up concluded that
"the remaining ~165 ms of a link-dominated build is spent parsing the 13.9 MB CRT
sysroot and writing the PE, not resolving symbols", and pointed at an archive
*parse* cache as the next target.

That conclusion was wrong about where the time goes, and this note records the
measurement that corrects it.

## What the sysroot actually contains

`build/bin/sysroot`, the ten archives the internal linker consumes:

| Archive | Bytes | armap symbols | Members |
|---|---:|---:|---:|
| `libmingw32.a` | 38,672 | 84 | 31 |
| `libgcc.a` | 6,822,456 | 829 | 289 |
| `libmoldname.a` | 516 | 0 | 1 |
| `libmingwex.a` | 483,786 | 511 | 291 |
| `libmsvcrt.a` | 2,067,820 | 5,202 | 2,638 |
| `libadvapi32.a` | 694,266 | 1,760 | 881 |
| `libshell32.a` | 306,596 | 793 | 389 |
| `libuser32.a` | 756,526 | 1,962 | 983 |
| `libkernel32.a` | 1,372,126 | 3,432 | 1,759 |
| `libucrt.a` | 2,067,820 | 5,202 | 2,638 |
| **total** | **~14 MB** | **19,775** | **9,900** |

## Measured: the parse is cheap, the lookups are not

`LcAr_Open` on all ten archives, warm — this reads all 14 MB and builds the
member and symbol tables:

| Operation | Time |
|---|---:|
| `LcAr_Open` x10 (14 MB) | **7-8 ms** |

`LcAr_MemberDefining`, the linear `strcmp` walk of the armap, with the query mix
weighted toward the late archives the way a real link is (most CRT symbols
resolve in `libmsvcrt`/`libucrt`/`libkernel32`, so the earlier armaps get scanned
in full first):

| Lookups | Total | Per lookup |
|---:|---:|---:|
| 500 | 17 ms | 34 us |
| 1,000 | 35 ms | 35 us |
| 1,500 | 46-51 ms | 31-34 us |
| 3,000 | 97 ms | 32 us |

Linear in the query count, at **~33 us per symbol resolution**.

## Why it costs that much

Two nested linear scans, neither touched by `092122b`:

- `LcAr_MemberDefining` (`clua/src/link/ar_read.c`) walks the archive's whole
  symbol index comparing strings;
- on a hit it calls `LcAr_MemberByHdrOff`, which linearly scans that archive's
  members — up to 2,638 of them;
- `resolve_fixpoint` (`clua/src/link/pe_emit.c`) calls it per unresolved symbol
  per archive in order, and its outer `while (changed)` loop **restarts from
  symbol index 0** whenever anything was pulled, so every still-unresolved symbol
  is re-scanned once per fixpoint round.

## Measured: what a real link actually does

The estimate above left one open variable — how many lookups a real link
performs. `CLUA_GC_DEBUG` now counts them, so it is no longer an estimate:

| Build | Archive queries | Name compares | Compares/query | Fixpoint rounds |
|---|---:|---:|---:|---:|
| `print("hello")` `-O1` | 19,111 | **31,224,382** | 1,633 | 183 |
| 3-line table probe `-O1` | 25,114 | **41,058,508** | 1,634 | 236 |
| `rover/src/rover.lua` `-O1` | 25,114 | **41,058,508** | 1,634 | 236 |

Read the unit carefully: **one query is one `(symbol, archive)` pair**, not one
symbol resolution. A resolution asks each of the 12 archives in turn until one
answers, so resolutions are roughly `queries / 12` — about 2,000, which is what
the earlier estimate guessed. Dividing compares by resolutions instead of by
queries overstates the per-scan cost by an order of magnitude, and the report
labels itself to prevent exactly that mistake.

Three things fall out of these numbers:

**The cost is a fixed per-link tax, not proportional to program size.** A
three-line probe and the 2,555-line Rover produce *identical* counts, because
archive resolution is driven by the runtime/CRT closure rather than by user code.
`hello` differs only because it enables fewer libraries. So this is not a win
that scales with program size — it is a win every build gets, including the
smallest ones.

**98% of queries are misses.** Only 465 of 25,114 queries find a defining
member; the other 24,649 scan an archive's whole index and return nothing. A miss
is the worst case of a linear scan and the best case of a hash.

**The fixpoint restart multiplies the work.** 236 rounds, because the loop
breaks out and restarts from symbol index 0 after every pull.

## Estimated saving

The harness below resolves 1,500 symbols in 46-52 ms while comparing ≈25.8M
armap entries, which puts a single failed `strcmp` at **~1.9 ns** — most compares
reject on the first character. Applying that to the measured counts:

| Build | Compares | Estimated time | Median build | Share |
|---|---:|---:|---:|---:|
| `print("hello")` `-O1` | 31.2M | ~59 ms | 153 ms | **~39%** |
| `rover/src/rover.lua` `-O1` | 41.1M | ~78 ms | 180 ms | **~43%** |

A hash index replaces ~1,634 string compares per query with a single probe, so
close to all of that is recoverable. An archive *parse* cache, by contrast, is
chasing 7-8 ms.

**A measurement trap worth recording.** The first version of these counters
incremented inside the compare loop. At 41 million compares per link that cost
~35 ms on Rover and ~6 ms on `hello` — so the instrumentation inflated the very
denominator it was being used to divide into, and it slowed every build for a
diagnostic almost nobody enables. Counting after each loop from its exit index
(`i + 1` on a match, `n` on a miss) is exactly equivalent — it reproduces the
same 25,114 / 41,058,508 / 236 — and costs three additions per query instead of
one per compare. The medians above are from the fixed version. If you instrument
a hot loop, measure the instrumented build against the clean one before quoting
any share of total time.

Reproduce the counts with:

```sh
CLUA_GC_DEBUG=1 clua build rover/src/rover.lua -O1 -o out.exe
```

`tools/test-link-stats.lua` asserts the report is self-consistent and that
enabling it does not change a single output byte.

## Determinism constraint on any fix

`LcAr_MemberDefining` returns the **first** armap entry, in index order, whose
name matches, and an armap may list one symbol name against more than one
member. Any index must therefore preserve first-insertion-wins precedence.
Inverting it changes which member is pulled, which changes output bytes — so the
byte-identity assertion in `tests/unit/test_lc_link_symindex.c` is the gate that
matters, and it must be extended to cover duplicate symbol names specifically.

## Reproducing

`tools/bench-armap.c` links against the tree's own `ar_read.o`:

```sh
gcc -std=c99 -O2 -I clua/src -o bench-armap.exe \
    tools/bench-armap.c build/bin/obj/link/ar_read.o
./bench-armap.exe build/bin/sysroot 1500
```

Numbers are wall-clock on a single machine under normal desktop load. The
per-lookup figure is stable across query counts, which is the property that
matters here; the absolute milliseconds are not a controlled benchmark. The
*counts* from `CLUA_GC_DEBUG` are exact and machine-independent — prefer them,
and treat the derived milliseconds as the softer half of the claim.
