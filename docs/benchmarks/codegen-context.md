# codegen: draining the file-scope mutable state

A pure refactor, so the interesting numbers are the ones that did not move.
Verified 2026-07-25.

## what changed

`clua/src/codegen/codegen.c` kept per-compilation and per-function state in six
file-scope objects:

| Global | Lifetime | Now |
|---|---|---|
| `g_lc_opt_level` | per compilation | `LcCgCtx.opt_level` (read-only after setup) |
| `g_savedpc_bias` | per function | `LcCgFrame.savedpc_bias` |
| `g_res_fn_xmm` | per function | `LcCgFrame.save_xmm` |
| `g_res_regions` | per function | `LcCgFnCtx.res_regions` |
| `g_res_n` | per function | `LcCgFnCtx.res_n` |
| `g_res_cur` | per function | `LcCgFnCtx.res_cur` |

`LcCgCtx` and `LcCgFrame` are public (`codegen.h`) because the prologue and
epilogue are public and must be handed the same frame descriptor. `LcCgFnCtx`
is file-private; it is threaded through `LcBranchCtx.fn` where a function
already receives a branch context, and as an explicit first parameter where it
does not.

Two details that are easy to get wrong:

- `res_cur` must be initialised to `-1`, not left to a `memset`. Zero means
  "region 0 is live", which would emit residency spills for a region that
  never started. `lc_cg_fn_init` sets it explicitly and says why.
- The savedpc bias must be fixed before the prologue runs. The prologue's
  `LEA RBP, [RBP + bias]` and every site's `4*(pc+1) - bias` only cancel if
  both use one value, so `lc_cg_fn_init` computes it and `res_analyze`, which
  fills in `save_xmm`, runs before the prologue reads the frame.

## two gates, because one is not enough

Byte-identity. All 18 rows of `tools/check-byte-identity.py` (six inputs by
`-O0`/`-O1`/`-O2`) are identical before and after, including the three
residency differential cases and the savedpc-precision case that exercise
exactly the state being moved. Rover `-O1` stays `20218e0332e736fb...`.

Structural. Byte-identity is blind to the failure that matters here: a
global faithfully reset at the top of each function emits identical bytes when
functions are compiled one at a time, and only breaks when two are compiled at
once. So the acceptance test is the symbol table:

```
nm build/bin/obj/codegen/codegen.o | grep -E "^[0-9a-f]+ [bBdD] "
```

went from six named entries (`g_lc_opt_level`, `g_res_cur`, `g_res_fn_xmm`,
`g_res_n`, `g_res_regions`, `g_savedpc_bias`) to zero, leaving only the
`.bss`/`.data` section markers.

`tools/test-codegen-no-globals.lua` runs that check over all four codegen
objects in the normal suite, so the invariant is enforced rather than achieved
once. Mutation-verified: adding a global that is written and read fails it
while the byte-identity gate stays green, which is the whole point. A
write-only global is dead code that gcc eliminates, so it is invisible to the
check and also harmless; the test proves "no load-bearing mutable global", not
"no `static` keyword", and says so.

## what this does and does not deliver

It delivers state isolation: a per-function worker can now own an `LcCgFnCtx`
and a `const LcCgCtx *`, and nothing in `clua/src/codegen/` is shared behind
its back.

It does not deliver thread safety. Still shared, and still to be dealt with
before row 8 of the roadmap:

- the allocator (`malloc`/`realloc`/`free` throughout);
- the `fprintf(stderr, ...)` diagnostics in `LcBr_Resolve`, which a parallel
  run must route through a per-worker sink and merge in a stable order, or
  the diagnostics themselves become non-deterministic output;
- `lc_codegen`'s output ordering, which is currently the loop index and would
  need to stay the module order regardless of completion order.

## a trap found while building the gate

The first version of `check-byte-identity.py` generated its `hello.lua` into a
fresh `mkdtemp` directory. Because every Proto embeds its source path, the
output bytes changed on every run, and the tool reported a divergence for a
tree that had not changed. It disagreed with itself across two consecutive
runs while agreeing on the five fixed-path inputs. Inputs to a byte-identity
check must live at stable paths. The tool now uses `build/tmp/byteid/` and
self-tests clean.
