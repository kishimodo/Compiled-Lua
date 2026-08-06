# plan for 0.3.0-beta.3

follow the same rules as the beta.2 plan: lowercase, ascii only, no em dashes
or smart quotes, no ai watermarks, no invented measurements. every phase has a
green suite as its gate.

## what this cycle does

finish the six items from beta.2 that landed partially. then add the
compiler features a user coming from clang / gcc / msvc would look for and
not find.

## partials to complete

### 1. auto-trigger .def under --output=dll

status: `--emit-def=<path>` works; the .def writer, the CLI flags, and the
tests are in the tree. missing: when the user says `--output=dll` without
`--emit-def`, we still don't write a .def. the auto-derive path was wired to
the older `emit_dll` bool that no longer fires under `--output=dll`.

fix: in the driver, after a successful DLL link, call `LuacLink_EmitDllDef`
if `emit_def_path` is null and `output_kind == LC_OUTPUT_DLL`. use
`LcEmit_DeriveDefPath(output_path)` for the default name (foo.dll ->
foo.def). also thread the real export list from `RESOLVE_RESULT_T` into the
call (today it emits a placeholder `{clua_run}`).

test: extend `tools/test-dll-importlib.lua` to build `--output=dll` alone
and assert foo.def appears next to foo.dll with the actual exports.

### 2. --output=obj and --output=lib

status: the round 4 agent produced a full implementation. it conflicted
with the DLL merge because both extended the `LcOutputKind` enum. deferred.

fix: manually merge by extending `LcOutputKind` to four values:

```
LC_OUTPUT_EXE = 0,   // default
LC_OUTPUT_DLL = 1,   // Windows DLL
LC_OUTPUT_OBJ = 2,   // raw COFF .o, no link
LC_OUTPUT_LIB = 3,   // GNU-form ar archive wrapping the same .o
```

then bring the OBJ/LIB paths in from the worktree branch, adapting the
enum values. `--shared-rt` stays rejected on OBJ/LIB (no link). `clua run`
only accepts EXE.

test: `tools/test-static-output.lua` from the worktree; port to the new
enum values.

### 3. DLL export signatures beyond (double, double) -> double

status: `Rt_DllExportDispatch` today hard-codes the (double, double) ->
double C ABI. Lua's `add(a, b) = a + b` maps cleanly, but int arguments,
string arguments, and pointer arguments do not.

fix: two dispatchers, both callable from generated trampolines:

```c
int64_t Rt_DllExportDispatch_ii_i(int64_t a, int64_t b, int32_t ord);
const char *Rt_DllExportDispatch_s_s(const char *s, int32_t ord);
```

signature detection: an optional `_export_types` companion table read
alongside `_exports`:

```lua
_exports      = { add = function(a,b) return a+b end,
                  greet = function(name) return "hi, "..name end }
_export_types = { add = "ii_i", greet = "s_s" }
```

if `_export_types` is missing, default to `dd_d` as today so nothing
regresses. resolve.c already scans `_exports`; extend to also collect
`_export_types` into `RESOLVED_EXPORT_T.abi_shape`. the trampoline emitter
picks the right dispatcher based on `abi_shape`.

test: extend `tools/test-dll-output.lua` with an `ii_i` and `s_s` export;
call each via the ffi package; assert the round trip.

### 4. dead_global codegen wire-up

status: reachability pass is on the branch, marks zero functions dead on
real programs because `OP_CLOSURE` from a parent keeps every child
"reachable" even when nothing calls it.

fix: add a small constant-folding pass that removes `if false then ... end`
and `while false do ... end` blocks BEFORE the reachability sweep. Lua's
front end does not do this (it emits `OP_JMP` past the block regardless),
so IR-level folding is what unlocks dead_global on any test case a user
would write.

pragmatic scope: fold the exact three shapes `if false`, `if nil`, and
`while false`. Do not attempt general constant folding.

test: a fixture with `local function used() end; local function dead()
end; if false then dead() end; used()`. assert -O2 binary lacks any bytes
from `dead`.

### 5. coro anchor prune

status: agent implementation conflicts with DLL structural changes in
`pe_link_v2.c`. Deferred in beta.2.

fix: land it on top of the current pe_link_v2.c shape. The change is
straightforward now that the DLL work is settled: add a `require_coro`
parameter to `LinkInternal` and `LinkStaticGcc`, thread it through from
the driver via `lc_module_uses_coroutine`, force-undef `Coro_OpenLib` when
true.

test: `tools/test-coro-anchor.lua` from the worktree.

### 6. real content in the docs site placeholder pages

status: `docs/site/ffi/overview.md`, `docs/site/internals/overview.md`,
`docs/site/packages/index.md` are one-line placeholders.

fix: write real content for each. ffi covers the c-type DSL, DLL loading,
callback trampolines. internals covers the IR, pass pipeline, codegen
frame ABI, linker. packages/index enumerates the 195 packages by category
with one-line descriptions (extracted from `--[[doc ...]]` fences once the
generator runs; for now, hand-populate the top 20 most-used ones).

## missing compiler features (add)

### 7. compilation database (compile_commands.json)

standard tool integration format. `clang`, `msvc`, `gcc` and every editor
LSP consumes it. one entry per compiled object.

output shape:

```json
[
  {"directory": "/path/to/repo",
   "file": "app.lua",
   "arguments": ["clua.exe", "build", "app.lua", "-O2", "-o", "app.exe"]}
]
```

add `--emit-compdb=<path>` to write one, and `--emit-compdb-append` to
append (for multi-file builds). Default off.

### 8. colored + structured error diagnostics

today `clua check` on a syntax error prints a bare line. Real compilers
print:

```
error: syntax error near '=' at foo.lua:12:5
   |
12 | local x =
   |          ^
```

fix: front-end lex/parse errors go through a diagnostic formatter that
prints file:line:col, a caret at the column, the offending source line,
and a diagnostic category. Colored under a TTY (respect `NO_COLOR`).

### 9. -v / --verbose (pipeline breakdown)

`clua build -v foo.lua` prints per-phase wall clock:

```
[resolve] 3 ms  (1 module, 0 packages)
[lift]    2 ms
[optimize] 5 ms (-O2)
[codegen] 15 ms (1 function, -j 1)
[link]    50 ms (12 archives, 3 objects)
total: 75 ms
```

no new phase work; just measure and print. useful for anyone tuning a big
build or writing a bug report about slow builds.

### 10. incremental compilation

today every `clua build` reruns the whole pipeline. for iteration on a
large program that is wasteful.

fix: cache the per-function COFF object bodies by content hash of the
IR-post-optimize (or of the Proto's bytecode as a coarser proxy). key on
`(proto_hash, opt_level)`. Store in `%LOCALAPPDATA%/clua/cache/`. On the
next build, functions whose Proto did not change get their compiled
bodies read from disk instead of regenerated.

honest scope: this is a big feature. For beta.3, ship the CACHE READ
side only (per-module cache with content hash), leaving cache POPULATION
to happen naturally when a build completes successfully. Add `--no-cache`
to disable.

if this is too much for the arc, ship a design note + reserve
`%LOCALAPPDATA%/clua/cache/` as the location so a future arc can populate.

### 11. -W flags framework

a `-Werror` / `-Wunused` / `-Wshadow` framework. real compilers make it
easy to reject specific warning categories.

for beta.3: add the framework (parse `-W<name>` and `-Werror`), even if
only two warning categories exist today. Categories to seed:

- `-Wunused`: warn when a local is set and never read.
- `-Wshadow`: warn when a local shadows an outer scope local of the same
  name.

both are cheap to compute during the parser/resolve phase.

### 12. progress indicator for big builds

today `clua build rover.lua` prints one summary line at the end. For a
large program (say, ten thousand functions), the wait is silent.

fix: on any build with more than 100 functions, print a progress bar
sampled every 100 ms. On a TTY, use `\r` overwrite. On a non-TTY, print
one line per 10% completion.

## ordering

phase A (partial completions, parallel-safe):

- 1. .def auto-trigger
- 2. obj/lib merge
- 3. DLL signature broadening
- 5. coro anchor prune
- 6. docs content

phase B (new features, parallel-safe):

- 7. compilation database
- 8. colored diagnostics
- 9. -v verbose
- 11. -W flags framework
- 12. progress indicator

phase C (bigger, land last):

- 4. dead_global with constant-fold-branches
- 10. incremental compilation cache

phase D (release):

- bump to 0.3.0-beta.3
- rebuild dist, tag, GitHub release

## what stays deferred

- pdb debug info. Real feature, real work, one arc on its own.
- linux .so / macOS .dylib. Out of scope for this compiler.
- lto across modules. Framework partly there via ip_typeprop; a real LTO
  pipeline is another arc.
- op_getfield inline fast path. Design note landed; win is small and
  requires the ltable Node layout to be pinned.
- op_seti / op_setfield inline. GC barrier is the sticking point.
- monomorphize, ip_devirt, barrier_elide passes. Zero surface on real
  code, per the round 3 survey.
