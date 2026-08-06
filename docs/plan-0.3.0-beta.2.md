# plan for 0.3.0-beta.2

overnight work plan. all facts here were checked against the current tree
(claude/speed-and-size @ 1afad55) and the six agent surveys run 2026-08-06.
follow the same rules when adding to this file: lowercase, ascii only, no em
dashes or smart quotes, no ai watermarks, no invented measurements.

## what this plan does

fix the two known limitations from the 0.3.0-beta.1 release notes, take the
next three compile time wins the linker survey found, land the parallel
codegen the invariant test has been ready for, and shrink or randomise the
runtime signature. write a real docs area, rewrite every markdown file in the
tree to sound like a person wrote it. every phase has a green suite as its
gate. every claim has a way to check it.

## the runtime-aot.a question, answered up front

two clua-emitted hello worlds share 99.9 percent of their bytes and one
identical run of 41,634 bytes. that run is runtime-aot.a plus the crt
imports, and it is why a two-line program weighs 93 kb. there are four ways
to move it. each is real, each has a tradeoff, and none of them removes lua
semantics from the emitted program.

1. shared runtime dll. `--shared-rt` already exists and links every
   compiled exe against clua-rt.dll. the exe drops to about 30 kb, the dll
   still ships next to it, and the total shipping bytes are the same or
   larger because the dll has its own pe headers. this is a
   deployment change, not a size win.
2. whole-program link time garbage collection of the runtime. today
   `runtime-aot.a` is dropped in as a static archive and `--gc-sections`
   already prunes function-scope sections that nothing calls. the archive
   is 172 kb; hello links about 74 kb of `.text` out of it. the remainder
   is dropped. the further win here is to run the pruner inside the
   compiler rather than at link time, so unused fields in shared structs
   go away too. estimated ceiling is around 15 to 25 kb off hello. real
   work but low risk.
3. signature randomisation without size reduction. hello is 99.9 percent
   the same as any other hello because the compiler emits sections in the
   same order and the linker packs them in the same order. randomise the
   function order (per compile, seeded from the hash of the input program
   plus a fresh nonce, so the same source still compiles to the same
   bytes when the nonce is fixed), and the 41 kb identical run drops to
   whatever the longest per-function body is. this does not reduce size.
   it removes the "detectable clua binary" property. useful for people
   worried about being fingerprinted; not useful for anyone counting kb.
4. native compile of a proven-static subset. this is the "what c does"
   idea. it is only sound for the intersection of lua and c: proven int
   or float locals, no dynamic tables, no growing strings, no
   metatables, no `require`, no closures over captured mutables. a
   program that fits in that box could go straight to native machine
   code with no lua runtime at all, and the smallest possible clua
   binary would be exactly a c binary. programs that use any part of
   dynamic lua (which is why people write lua) do not fit. the
   intersection has real users -- number-crunching kernels, hot loops
   embedded in larger programs -- but it is not the default case.

what this plan will implement, in order: (2), then (3) as an optional
flag, then a design note on (4) that a future arc can build. no changes
to (1); it works today.

## the two release-note limitations, resolved

both were listed as known limitations in the 0.3.0-beta.1 notes. both are
addressed below with the same rigour the earlier work used: measurements
first, then implementation, then a suite gate that a future regression
cannot slip past.

### table access at 0.80x the interpreter

the "inline table fast path" designed-and-costed handoff exists at
`docs/handoff/2026-07-29-inline-table-fastpath.md`. that file was deleted in
the cleanup; the design in it is still what to build. the agent survey
confirmed the sequence and the encoders needed. summary:

- inline `op_geti` fast path in codegen: check tag, bounds, load array
  slot, store to destination. slow path stays a call to `rt_getif`.
- same for `op_gettable` with an integer-tag test on the key first.
- special case for `op_getfield` (compile time constant string key):
  inline the shortstr hash lookup, since the interpreter is already
  inline at this point.
- setters (`op_seti`, `op_setfield`) keep the slow path for now. the gc
  barrier is the sticking point; inline it in a second slice if the
  first shows a measurable win.

encoders to add to `x64_emit.h`:

- `jberel8` (opcode 0x76)
- `jerel8` / `jzrel8` (opcode 0x74)
- `testmem8imm8` (f6 /0 ib)

honest size cost per site: about 30 to 45 bytes inline, replacing 12 bytes
of call. rover has roughly 100 table op sites; total .text cost around 2 to
4 kb. this is a size increase. gate it on `-o2` or higher so `-o1` stays the
size-conscious level.

the wall clock win is not measurable on this host at the current kernel
lengths (control kernel spreads 0.79 to 1.05x). the deterministic proxies
are: emitted `.text` load count per site drops from 5 dependent loads to 3,
and the call-return round trip is gone. those are the honest claims to make;
a wall-clock number will be believable only on a quieter box.

new tests: extend `tests/differential/aot_tables_index.lua` with metatable
and barrier cases. add a linked-code assertion (like
`tools/test-stdlib-anchor-split.lua`) that verifies the inline sequence
appears in the emitted exe for a fixture built at `-o2` and does not appear
at `-o1`.

### -o1 and -o2 and -o3 emit identical bytes

the survey confirmed why: every pass gated at -o2 or above is either a stub
or fires zero times on the fixtures in the tree.

the plan is not to implement every stub. it is to implement the two that
have real surface, and to move the "wall clock" work (the inline table
fast paths above) behind the -o2 gate so -o2 finally means something.

passes to implement:

- `lc_pass_dead_global` (passes.c:679). removes reachability-dead
  functions and globals. an interprocedural reachability fixpoint,
  starting from the entry proto. this fires on real programs. estimated
  size win on rover: 5 to 20 kb; estimated on hello: zero (nothing to
  drop).
- `lc_pass_escape` slice 2 (interprocedural escape). slice 1 shipped and
  fires 0 out of 86 candidates on rover. the reason is measured: real
  tables escape via closure upvalue or field mutation. slice 2 tracks
  escape across calls using the call graph `lc_build_callgraph` will
  produce for the previous pass. combined effect is what unlocks scalar
  replacement on real code.

passes to explicitly not implement, because the survey found zero
surface:

- `lc_pass_barrier_elide` (codegen emits no barriers today).
- `lc_pass_monomorphize` (dispatch is already inline in codegen fast paths).

behaviour of the -o levels after this arc:

- `-o0`: no optimisation. size-optimised, easy to debug.
- `-o1`: type inference + tag-check elision + residency + interprocedural
  type propagation. what -o1 does today.
- `-o2`: -o1 plus the inline table fast paths, plus dead global
  elimination.
- `-o3`: -o2 plus escape analysis slice 2 plus scalar replacement.

## compile time, three next wins

the survey found three low-difficulty linker wins that together take about
20 to 52 ms off a 180 ms rover link, or 11 to 29 percent. all three can be
done in sequence with no interaction.

1. section gc symbol cache (`clua/src/link/pe_emit.c` around line 1128).
   the mark phase re-resolves symbols via `gsym_find`. cache the
   (obj, section) to (defined_obj, defined_section) mapping into a side
   table during the resolve fixpoint and read it in the mark phase.
   estimated 8 to 12 ms.
2. archive classification pre-pass (`archive_head_map` around line 378).
   classify all 12 archives once before the resolve fixpoint runs. today
   the classification lookup happens per symbol query. estimated 8 to 18
   ms.
3. relocation output-section cache. `secrel` and `section` relocations
   loop over all output sections to find where their target landed;
   store the output section index on `gsym` during `resolve_addrs` and
   read it in `apply_relocations`. estimated 4 to 12 ms.

fourth win, larger and separate: fixpoint restart amortisation. today the
resolve fixpoint restarts at archive index zero after every member pull.
hello does 236 rounds. queue the pulls for a round, resolve the whole batch
per pass, and the early-archive scan cost stops multiplying. estimated 5 to
10 ms. moderate difficulty, correctness sensitive; do this last with a
before-and-after byte-identity check.

## parallel codegen

the invariant test `tools/test-codegen-no-globals.lua` has been enforcing
zero mutable file-scope state in `clua/src/codegen/` for the whole arc.
that was the precondition. the driver iterates `m->funcs[i]` in
`lc_codegen` and each iteration is now provably independent.

implementation: a small win32 thread pool. `createthread` per worker, a
counter semaphore for work items, `waitformultipleobjects` at the join
point. about 50 lines. `-j n` on the command line (default `n` equals
the count from `getsysteminfo`), env var `clua_jobs` overrides.

honest speedup ceiling: 1.2 to 1.4x on rover, on an 8-core machine. the
link is single threaded and dominates the budget. hello has one
function, so the ceiling there is 1.0x. this is worth doing for large
programs, not small ones.

correctness risk: real. a race that produces a subtly wrong instruction
byte will pass the byte-identity gate on the runs where the race did not
fire. mitigation: run the full differential suite five times with `-j`
before shipping, and one time with `-j 1` to prove the option is a no-op
at n=1.

## runtime shrink and signature randomisation

phase (2) from the runtime section above.

- move runtime-aot.a members through the same `lc_module_used_libs`
  scan the stdlib anchors already go through, but at object granularity
  instead of at library granularity. anything the emitted program does
  not reach gets pruned before the archive is even parsed by the
  linker. estimated 10 to 20 kb off hello.
- introduce a per-function section randomisation for the runtime, off
  by default, on with `--randomize-layout` or `-o3`. seeded from a hash
  of the source plus an optional nonce so byte-identity is still
  reproducible when the nonce is fixed. removes the 41 kb identical
  run between two hellos.
- write the design note for phase (4) native compile. do not implement.

## every compiler output type

the user asked for full dll support and every output type any compiler
would have. today clua produces one thing: an exe. this is the plan for
the rest, ordered by real usefulness for the shape of programs people
actually write in lua.

- dll. shared library output. the compiler already knows how to emit a pe
  and to link against dlls; the missing pieces are the export directory,
  a `dllmain` shim, and the driver plumbing. plan:
  - `clua build foo.lua --output=dll -o foo.dll` (also accept `-shared`).
  - a source-level export marker so the user can choose which functions
    become c-visible entrypoints. two forms, both sound in closed-world
    lua: (a) a special table `_exports = { name1 = fn1, name2 = fn2 }`
    written at module scope; the compiler notices it and emits an export
    for each entry, and (b) a doc comment `-- @export name` above a
    function statement. (a) is the primary path; (b) is convenience.
  - a `dllmain` shim in `runtime/aot_entry_dll.c` that calls
    `Rt_ModuleInit` on `dll_process_attach` and `Rt_ModuleFini` on
    detach. the shim carries no lua-visible side effects.
  - the pe emitter grows an export-table branch: `image_directory_entry_export`
    filled with the sorted name table + ordinal table + rva table. the
    file characteristics get `image_file_dll`; the subsystem stays
    windows console (or gets a `--subsystem` flag if a windows-gui build
    ever wants it).
  - exports get c-visible names (e.g. `luac_export_foo`), plus a
    `.def`-style alias table on disk so a c consumer can just
    `#include "foo.h"` and link against the import lib.
  - an accompanying `.lib` (import library) generated with dlltool from
    the `.def`, so consumers can `link foo.lib` in msvc or `-lfoo` in
    gcc. this is the same shape microsoft ships every dll under.
- static archive. `--output=lib`, `-o foo.lib` (or `.a` under gcc
  conventions). less useful for lua than for c: a lua static archive
  cannot be self-contained the way a c one can (still needs a runtime),
  and combining two lua static archives collides on shared symbols. mark
  this "designed, not built" for the arc; it can wait for a real user
  request.
- coff object. `--output=obj`, `-o foo.obj`. aotc already writes a coff
  object internally on the way to the exe; expose it directly. useful
  for people linking clua-generated code into a larger c or c++ program
  via the platform linker. tests: emit foo.obj, link it against a small
  c driver, run the result and diff against the interpreter.
- assembly dump. `--emit=asm`, or `--dump=asm`, output goes to the `-o`
  path or stdout when `-o -`. text form of the emitted x64, with a
  header per lua function and comments showing the source line. reuses
  the same encoders in reverse: given a byte pattern, print its mnemonic
  and operands. this is a debug aid, not a build target; do not try to
  round-trip.
- ir dump. `--emit=ir`, prints the `lcmodule` after every pass in a
  human-readable form. for compiler development only; the format is
  loose and not stable.
- bytecode dump. `--emit=bytecode`. the raw lua 5.4 bytecode from the
  front-end, before lifting. useful for confirming what the parser saw.
  cheap to add since the lua vm already has `luac -l` semantics we can
  copy.

driver flag design:
- `--output=<kind>` where `<kind>` is one of `exe`, `dll`, `lib`, `obj`.
  default `exe`. the file suffix on `-o` is a hint but not authoritative;
  `--output=dll -o mylib` still produces a real dll named `mylib`.
- `--emit=<what>` where `<what>` is `bin` (default), `asm`, `ir`,
  `bytecode`. distinct from `--output` because emit is diagnostic; you
  can `--emit=asm --output=exe` to write the exe and print asm to
  stderr.
- `--subsystem=<name>` for `console` (default) or `windows`. only makes
  sense for exe output; ignored otherwise.

what this does not do:
- no cross-compilation. windows x64 only, same as today.
- no linux `.so` output. same as today.
- no mach-o output. same as today.
- no com dll registration hooks. that is a per-user concern; users who
  want it can call the appropriate self-registration api from their
  export.
- no .pdb output. debugging happens through the differential oracle
  today; `.pdb` would be a whole subsystem on its own.

## humanise every markdown file

the user constraint: lowercase, human punctuation, only things
available on a keyboard, no em dashes, no smart quotes, no emoji, no
ai watermarks, only genuine information.

- every `.md` in the tree gets rewritten to that style. no em dashes
  (rewrite the sentence, do not just replace the dash), no smart
  quotes, no ellipsis character (use three dots), no bullet character
  (use a hyphen).
- no phrases that read like an ai wrote them: no "let me know if you
  have questions", no "i hope this helps", no "as of my last
  training", no "great question", no "certainly".
- section headers can stay in title case where they are actually
  proper nouns (`clua`, `lua`, `windows`), otherwise lowercase.
- git commit messages from here on follow the same rules.
- add a gate: `tools/test-doc-style.lua` runs a regex over every
  tracked `.md` and fails the suite on any of: em dash, en dash, smart
  quote, ellipsis character, bullet character, "as an ai", "i hope",
  "great question", "certainly".

## real documentation area

pattern: mkdocs with the material theme, sourced from
`docs/site/`. reason: mkdocs builds a static html tree that github pages
can serve directly, no server needed. the material theme has search, code
copy, dark mode, and it is widely known so contributors will not have to
learn a new tool.

the structure to build:

- `docs/site/index.md`: what clua is, in three paragraphs.
- `docs/site/getting-started/`: install, first program, common
  commands.
- `docs/site/language/`: what closed-world lua means, what the compile
  errors look like, which lua 5.4 features are supported (all of them,
  minus load and friends).
- `docs/site/cli/`: every `clua` and `rover` subcommand with all flags,
  the way `windows` documents an api function. syntax, parameters,
  return value, examples, remarks, related commands. one page per
  subcommand.
- `docs/site/packages/`: one page per built-in package, generated from
  the header of each `init.lua`. the 195 packages in
  `kishimodo/clua-packages`.
- `docs/site/ffi/`: how to declare c types, call dlls, write
  callbacks, marshal structs.
- `docs/site/perf/`: what closed-world buys you, when each `-o` level
  helps, when it does not, and what the `no_proofs` gate is.
- `docs/site/internals/`: for contributors. the ir, the pass pipeline,
  the codegen frame abi, the linker.
- `docs/site/release-notes/`: rendered from `changelog.md`.

new tools:

- `tools/gen-package-docs.lua`: scans `clua/src/runtime/packages/*/init.lua`
  for a doc header (a top comment block with a specific fence) and
  emits `docs/site/packages/<name>.md`. any package without a doc
  header is a hard error on the site build.
- `tools/gen-cli-docs.lua`: parses `clua help` and `rover help` output
  and produces the cli reference pages.
- `.github/workflows/docs.yml`: builds and deploys to
  github pages on every push to main.

the humanisation rules apply to the site content too.

## ordering and dependencies

phase 1, safe warmups. these can land in any order and do not depend
on each other.

- humanise the existing markdown files.
- add the doc style gate `tools/test-doc-style.lua`.
- close the three stale xfail markers the survey found (test_event,
  test_mutex, test_semaphore).

phase 2, compile time wins. these can land in parallel with each other
but each has its own byte-identity gate.

- linker win 1: section gc symbol cache.
- linker win 2: archive classification pre-pass.
- linker win 3: relocation output-section cache.
- parallel codegen with `-j n` and env `clua_jobs`. run the full
  differential suite five times with `-j` before shipping.

phase 3, size wins.

- runtime-aot.a per-object pruning through `lc_module_used_libs`.
- optional signature randomisation behind `--randomize-layout`.

phase 4, wall-clock speed wins.

- add the three x64 encoders.
- inline `op_geti` fast path, gated on `-o2`.
- inline `op_gettable` fast path, gated on `-o2`.
- inline `op_getfield` fast path with shortstr hash, gated on `-o2`.
- extend `tests/differential/aot_tables_index.lua` and add
  `tools/test-inline-table-fastpath.lua`.

phase 5, -o level meaning.

- implement `lc_pass_dead_global`.
- implement `lc_pass_escape` slice 2 with interprocedural summary.

phase 6, documentation area.

- add mkdocs config, material theme.
- set up `.github/workflows/docs.yml` for github pages.
- write `tools/gen-package-docs.lua` and header the 195 packages that
  need one.
- write the getting started, closed world, ffi, and perf sections by
  hand.

phase 7, release.

- bump to 0.3.0-beta.2.
- rebuild dist and release zip.
- write release notes in the humanised style.
- gh release create with the artifact.

## gates that must stay green

before every commit, the full suite must pass. before each phase merge,
also:

- byte-identity 18 out of 18 for the standard corpus.
- `tools/check-object-freshness.py` reports zero stale.
- differential suite green across `-o0` through `-o3`.

if a change moves emitted bytes, the size and speed doc gets updated in
the same commit, with the honest measurement recipe from
`docs/benchmarks/size-and-speed-current.md`.

## what this plan does not do

- it does not add a lua jit. clua is aot only and that stays.
- it does not add a linux port. the tree is windows x64 by design.
- it does not add cross-compilation.
- it does not add a repl. the interpreter binary exists for the
  differential oracle only.
- it does not implement the barrier elision pass or the
  monomorphisation pass, because the surface is zero.
- it does not touch phase (1) shared dll or phase (4) native subset
  compile. those are out of scope for this arc.
