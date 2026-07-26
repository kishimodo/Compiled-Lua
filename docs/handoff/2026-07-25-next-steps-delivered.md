# Handoff: the measured next-step slice — 2026-07-25

Branch: `codex/concurrency-size-stability`.
Supersedes: [`2026-07-25-concurrency-size-stability.md`](2026-07-25-concurrency-size-stability.md)
(still accurate for everything before this slice).

## State

Ten items, in the order they were done. Each landed as its own commit with its own
evidence; the roadmap's "current work in flight" table carries the per-row status.

| # | Work | Outcome |
|---|---|---|
| 1 | Record the session's measurements | [`benchmarks/helper-call-args.md`](../benchmarks/helper-call-args.md), [`archive-symbol-lookup.md`](../benchmarks/archive-symbol-lookup.md), harnesses in `tools/` |
| 2 | Archive lookup counters behind `CLUA_GC_DEBUG` | 25,114 archive queries and 41M name compares per link — a *fixed* per-link cost, identical for a 3-line probe and for Rover |
| 3 | Measure the `.pdata`/`.xdata` GC roots | **Negative result, recorded.** Frees 128 bytes of `.text`; hypothesis refuted |
| 4 | Pin the system `tar` | Fixed at the call site; PATH deliberately untouched |
| 5 | imm32 helper-call arguments | **-73,216 bytes** on Rover (-12% `.text`); `hello` unchanged |
| 6 | Index the archive symbol lookups | **-52% warm build** (Rover `-O1` 180 → 87 ms); output byte-identical |
| 7 | `-MMD -MP` header dependencies | The documented "wipe the objects first" trap is gone |
| 8 | Codegen context isolation | 6 mutable file-scope objects → **0**; all 18 byte-identity rows unchanged |
| 9 | Implement + wire `lc_module_verify` | Was `return true` with `verify_each` never read; now checked after every mutating pass group *and* before codegen at `-O0` |
| 10 | Make the `-O` contract honest | `-Os`/`-Oz`/`-Ofast`/`-O9` were silently becoming `-O0` or "everything"; now rejected, and the help text states what each level really runs |

Net effect on the two headline numbers: a warm Rover `-O1` build went from ~180 ms
to ~87 ms, and its binary from 743,424 to 670,208 bytes.

## Verified how

- Full suite after every code-touching item, via a wrapper that prepends
  `C:\Windows\System32` to `PATH` (see the `tar` note below). Final run recorded
  in the commit for item 10.
- `tools/check-byte-identity.py` — 18 rows (6 inputs × `-O0`/`-O1`/`-O2`) — for the
  two changes that must not alter output: the archive index and the codegen
  refactor. Both identical.
- `nm build/bin/obj/codegen/codegen.o` for item 8, because byte-identity is blind
  to state that is shared but reset between functions.
- **Every item was mutation-tested.** Each new test was shown to fail against the
  defect it exists to catch: a dropped `REX.R`, inverted armap precedence, a
  reintroduced codegen global, the old `return true` verifier, the old `atoi`
  `-O` parse, a removed `-include`. A test that has never failed is not evidence.

## Not done / not claimed

- **`-Oz` lowering** (roadmap row 5) is still open: selective callee-saved
  prologues and outlined slow paths. The imm32 change is *not* part of it — it
  was unconditional because it is not a tradeoff.
- **Thread safety.** Item 8 delivered state *isolation*, not thread safety. Still
  shared: the allocator, `LcBr_Resolve`'s `stderr` diagnostics, and
  `lc_codegen`'s output ordering. Named in
  [`benchmarks/codegen-context.md`](../benchmarks/codegen-context.md) so row 8
  starts from a list.
- **The `hello` floor.** 137,216 bytes, unexplained. The `.pdata` lead was
  measured and refuted; the runtime/CRT `.text` split is the next place to look.
- **The M2 passes** (monomorphize, ip_devirt, dead_global) are still stubs. Item
  10 made that visible and testable, not fixed.
- **`already_pulled`** in `pe_emit.c` still scans linearly and, on a realloc
  failure, returns "already pulled" — silently dropping a member the link needs.
  Deliberately left for its own commit: it changes behaviour under memory
  pressure.

## Next

Roadmap row 5's `-Oz` lowering is the largest remaining size lever, and it now has
a clean base: the byte-identity gate exists, `-O` parsing is strict so a new level
can be added safely, and codegen state is per-function so a size mode can be a
context field rather than another global.

For compile time, the archive index took the obvious win; what remains of a warm
build is PE writing and the front end, neither yet measured at this resolution.
