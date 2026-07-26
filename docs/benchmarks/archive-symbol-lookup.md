# Internal linker: archive symbol resolution

Measured 2026-07-25 at `7fec28f` against the tree's own `ar_read.o`, so this
times the shipped code rather than a reimplementation. Reproduce with
`tools/bench-armap.c` (see the bottom of this file).

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

## What it implies

A hash index would take the per-lookup cost to roughly nothing, the same way
`gsym_find` did. On a warm ~170 ms Rover build the saving is bounded by the
number of lookups a real link performs:

| Lookups per link | Saving | Share of a ~170 ms build |
|---:|---:|---:|
| 1,000 | ~35 ms | ~20% |
| 3,000 | ~97 ms | ~57% |

**The open uncertainty is that lookup count**, and it is the reason this note
does not claim a single figure. A `hello` build reports 994 contributions
(656 kept, 338 dropped), which bounds the pulled-object count but not the number
of symbol queries — the fixpoint restart means queries can exceed distinct
undefined symbols by the round count. Counting the calls behind `CLUA_GC_DEBUG`
settles it and should precede the fix.

An archive *parse* cache, by contrast, is chasing 7-8 ms.

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
matters here; the absolute milliseconds are not a controlled benchmark.
