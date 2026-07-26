# Internal linker: symbol and contribution indexing

Change: `092122b`, in `clua/src/link/pe_emit.c`. Measured 2026-07-25, warm, on
the audit machine. Cross-reviewed independently before integration.

## What the change does — reviewed and correct

- `gsym_find` is an open-addressed FNV-1a table. Slots hold a **symbol index
  plus one** (`0` is the empty sentinel), not a `GSym *`. That is what makes it
  safe against the `realloc` inside `gsym_intern`. The table doubles from 512
  whenever the load factor would reach 0.7, so capacity stays a power of two and
  a probe loop can never run full.
- The `(object, section)` to contribution lookup in `sym_rva` and
  `reloc_target_rva` reuses the pre-existing `GcMap`, now owned by the `Linker`
  and rebuilt at the only two points that mutate the contribution array: after
  `collect_contribs` and after `layout_sections`' insertion sort. `gc_sections`
  only flips the `dropped` flag, which the map does not key on, so no third
  rebuild point exists.
- The index is *equivalent* to the scan it replaces because `collect_contribs`
  emits at most one contribution per `(object, section)` in a single pass, so
  the map's unique answer is exactly the old "first non-dropped linear match".
  The dropped-COMDAT fallthrough is preserved in both callers.
- The commit also fixes a latent allocation bug: the old `gsym_intern` bumped
  `nsyms` and then assigned `_strdup(name)`, so an allocation failure left a
  `NULL` name that the next `gsym_find` would `strcmp`. The name is now
  duplicated before the array grows, and freed if the grow fails.

## Measured result

Two `clua.exe` binaries built from identical objects differing only in
`pe_emit.o`. One discarded warm-up, then measured runs:

| Build | parent `7f02bd3` median | `092122b` median | Delta |
|---|---:|---:|---:|
| `rover/src/rover.lua` `-O1` (n=9) | 206 ms | 202 ms | -4 ms (-1.9%) |
| `print("hello")` `-O1` (n=11) | 173 ms | 165 ms | -8 ms (-4.6%) |

Output is byte-identical across the change: `rover.exe` from the parent, from
`092122b`, and from a repeat run of `092122b` all share SHA-256
`d9860cac8ba2250a36d8adca4f11fb6e7874973f39dcaa90d81fe1889b805c2f`.

## Honest limits

The win is real but small, and the earlier "quadratic internal-linker paths"
framing overstated the present cost:

- `CLUA_GC_DEBUG=1` on a `hello` build reports only **994 contributions**
  (656 kept, 338 dropped), so the replaced scans covered roughly a thousand
  entries, not a pathological set;
- the run-to-run spread of about +-25 ms is **wider than the Rover delta**;
- the remaining ~165 ms of a link-dominated build is elsewhere.

The change removes a scaling cliff and is a prerequisite for larger inputs and
for any future linker threading. It is not the source of a large wall-clock win
today.

**Where "elsewhere" actually is — corrected 2026-07-25.** This note originally
attributed the remaining time to parsing the 13.9 MB CRT sysroot and named an
archive-index cache as the next target. Measurement says otherwise: reading and
indexing all ten archives takes **7-8 ms**, whereas the *archive symbol* lookups
this commit never touched cost **~33 us each** over a 19,775-entry linear scan.
`092122b` indexed `gsym_find` and the contribution map; `LcAr_MemberDefining` in
`ar_read.c` is still a linear `strcmp` walk, with a nested linear member scan on
every hit, called per unresolved symbol per archive and restarted on every
fixpoint round. See [`archive-symbol-lookup.md`](archive-symbol-lookup.md). The
parse cache is chasing 8 ms; the armap index is worth tens.

## Regression cover

`tests/unit/test_lc_link_symindex.c` links a synthetic COFF carrying 4000
`EXTERNAL` symbols, which forces five rehash rounds with real probe collisions,
asserts the one genuine `REL32` still resolves through the grown table, and
asserts two independent links of the same input are byte-identical so hash
iteration order cannot leak into output. It skips cleanly when the sysroot is
absent.

## Reproducing

See the single-object A/B recipe in [`README.md`](README.md); this change is
confined to `pe_emit.o`, so no full rebuild is needed.

```sh
tools/bench-link.sh build/bin/clua.exe rover/src/rover.lua 9 -O1
```
