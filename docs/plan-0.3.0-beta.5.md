# plan for 0.3.0-beta.5

everything a mainstream compiler ships that clua does not, plus what a
mainstream windows binary carries that clua's output does not. same style
rules as the earlier plans: lowercase, ascii only, no em dashes.

## what this cycle does

three tracks, in priority order.

track A, compiler user-experience gaps. mostly diagnostic and build-system
plumbing that lets a user coming from gcc / clang / msvc / rustc feel at
home.

track B, output binary hardening. today a clua-emitted hello.exe is missing
things every professional windows binary carries: no version-info resource,
no manifest, no icon, no LOAD_CONFIG directory, no Control Flow Guard, no
stack cookies, no DEBUG directory pointing at a pdb. these are all one-time
plumbing wins, not per-program.

track C, deeper language and toolchain work that a future arc can grow.

## track A0: developer error experience (crucial)

diagnostics that make it obvious what went wrong, where, and why. clua
already prints file:line:col with a caret (colored diag from beta.3), and
warns on unused locals (from beta.4). that's the floor. what a developer
coming from Python (PEP 657 fine-grained tracebacks), C++ (clang's
`-fdiagnostics-show-caret`), or Zig (dedicated compile-error notes with
context) expects is more.

### A0.1 multi-line context and secondary spans

today a diagnostic shows one source line. real diagnostics show:
- 2 lines before + 2 lines after the primary line for context
- a secondary span pointing at a related location ("this because of
  this earlier declaration")
- a distinct arrow/color for the secondary

target shape (matches rustc / zig):
```
error[E0308]: type mismatch: expected number, got string
   --> app.lua:42:11
    |
 40 | local sum = 0
 41 | for _, v in ipairs(xs) do
 42 |   sum = sum + v
    |         ^^^^^^^  cannot add a string to a number
    |
note: `xs` was declared here
   --> app.lua:12:1
    |
 12 | local xs = {"one", "two", "three"}
    | ^^^^^^^^   this table's elements are strings
    |
help: convert v to a number: `sum + tonumber(v)`
```

impl in `clua/src/compiler/diag_pretty.c`:
- new `LcDiag_Report` that takes an array of `LcDiagSpan` (each with
  file/line/col_start/col_end + label + severity)
- primary span rendered with `^^^` (multi-char range), color from
  severity
- each secondary span rendered as a `note:` block with its own header
  and pipe-column
- optional `help:` line at the end for a fix suggestion

### A0.2 "did you mean" suggestions

on an undefined global (`pritn(...)` calling nonexistent `pritn`),
suggest close matches from the known symbols in scope. tiny edit
distance via damerau-levenshtein against locals, upvalues, and the
env-known-globals list (all `luaopen_*` functions + basic library
names + declared exports).

```
error: undefined global 'pritn'
  --> app.lua:5:1
   |
 5 | pritn("hello")
   | ^^^^^  no such name
   |
help: did you mean `print`?
```

edit distance <=2 for names >=4 chars, otherwise no suggestion (avoid
noisy false positives). implementation lives in a new
`clua/src/compiler/diag_suggest.c`.

### A0.3 "what could be causing" contextual hints

when a specific error is well-understood, attach a fixed help message
that goes beyond the raw parser output. examples:

- `unexpected symbol near '='`: "did you mean `==` for equality? `=`
  is assignment, `==` is comparison."
- `attempt to call a nil value 'X'`: "'X' is not defined in this
  scope. If it's from a module, did you `require` it?"
- `'end' expected (to close 'function' at line N) near '<eof>'`:
  "a function opened at line N was never closed. Common causes: a
  missing `end`, a stray `return` inside a block, or a `local
  function` that grew past a `then` without a matching `end`."

new file `clua/src/compiler/diag_hints.c` with a table:
```c
static const LcDiagHint hints[] = {
  { LC_ERR_PARSE_EQ_NEAR, "did you mean `==` for equality?..." },
  { LC_ERR_CALL_NIL, "..." },
  ...
};
```

the parser output is pattern-matched to an LC_ERR_* code, and the
matching hint is appended to the diagnostic.

### A0.4 continuation notes

if an error cascades (parsing a broken function keeps producing
errors), emit ONE primary + the cascade as `note: this error may be a
consequence of the earlier problem`. today parsing usually aborts on
the first error; when A1 (multi-error reporting) lands, use the
cascade-detection heuristic (errors within 3 lines of a previous
error) to group.

### A0.5 error index

every diagnostic has a stable code (E001, E002, W001, ...) that
`clua explain <code>` resolves to a longer explanation with an
example of the error and its fix. see A4 for the mechanism.

### A0.6 real-time errors: `clua check --watch`

the LSP is a whole subsystem. a smaller shape that covers the same
UX intent: `clua check --watch <path>` re-runs the check on file
modification and re-prints diagnostics.

impl: `ReadDirectoryChangesW` watches the source directory, on any
`.lua` change re-runs `clua check` and re-prints the diagnostics. emits
one report per change; if the same file has errors on two consecutive
runs, only re-print differences.

editor integration: any editor that shells out to a command on save
already works; this makes the command a persistent process. flag
`--json` on top so an editor can consume machine-readable output
without parsing color codes.

### A0.7 JSON diagnostic output

`--diagnostics-format=json` emits one JSON object per diagnostic on
stderr, one per line. schema matches rustc's:
```
{"severity":"error","code":"E0308","message":"...",
 "spans":[{"file":"app.lua","line":42,"col":11,"line_end":42,
           "col_end":18,"label":"cannot add...","is_primary":true}],
 "children":[{"severity":"note",...}]}
```

editors, LSP shims, and build systems that want structured output can
consume this.

### A0.8 severity levels

today: `error`, `warning`, `note`. add:
- `help`: actionable suggestion (like the "did you mean" above)
- `hint`: less actionable (about style, not correctness)

order in the output: error > warning > note > help > hint. each with
its own color under `--color=always`.

### A0.9 error recovery quality

when multi-error reporting lands (A1), the parser needs recovery
points. common in gcc / clang: recover at statement boundaries (`;`,
newline in a block-context), at closing brackets, and after specific
keywords (`end`, `then`, `do`). for lua the recovery points are:
- statement boundary (newline at block scope, `;`, or a keyword that
  starts a new statement)
- `end` (closes a block; skip to next `end` if the current one is
  misplaced)
- `then` / `do` / `else` / `elseif`

new file `clua/src/compiler/parse_recover.c` that owns the recovery
logic; wraps `luaY_parser` with a try-continue loop.

### A0.10 error test suite

`tests/errors/*.lua` fixtures each with a comment header saying what
error is expected, at which line, with which hint. the runner
compiles each with `clua check --diagnostics-format=json`, parses
the output, and asserts the expected spans/hints/codes appear.
around 30 fixtures for the common error classes.

## track A: compiler user-experience gaps

### A1. multi-error reporting

today the front end stops at the first error. rebuild, get the next one,
rebuild, get the next one. every real compiler collects all errors and
prints them together. reason clua doesn't yet: `luaL_loadfile` calls into
lua's parser which raises the first error and returns.

fix: catch the error, record it, feed the parser a synthetic recovery point
(skip to next statement boundary), re-invoke the parser at the recovery
point, repeat until eof. for the arc, a simpler shape: parse each require'd
module independently in `resolve.c` (already done); collect all errors from
all modules rather than stopping at the first module that fails.

### A2. depfile output

`-MD -MF foo.d` in gcc terms. writes a make-style dependency file
describing the current .lua and every module it require's. every build
system that manages incremental rebuilds needs this.

output shape:
```
foo.exe: foo.lua app/lib.lua app/util.lua
```

flag: `--emit-depfile=<path>` and `-MD` alias. default off.

### A3. response files

`clua @args.txt` reads args.txt and expands each line as an argument.
windows has an 8 KB command-line cap; a project with a hundred `-L <pkg>`
force-links hits it. every compiler that runs on windows accepts response
files.

parse rule: any argv entry starting with `@` is a path; open the file,
split on any whitespace (or use one arg per line), splice into argv in
place. nested `@` allowed once (no recursion).

### A4. `clua explain <code>` error database

error codes exist (E001 etc), no explanation database. `rustc --explain
E0308` prints a long-form explanation with examples of the error and how
to fix it. add `clua explain <code>` that reads from `docs/errors/<code>.md`.

### A5. doc-comment extraction

`--- @param x number description` comments on lua functions could
populate the docs site. today `tools/gen-package-docs.lua` scans for a
`--[[doc ... ]]` fence at the top of each package's init.lua. extend to
also read ldoc-style tags:
- `--- @param NAME TYPE description`
- `--- @return TYPE description`
- `--- @throws ERRORTYPE description`
- `--- @field NAME TYPE description` (for module tables)

emit one markdown page per lua module into `docs/site/api/`.

### A6. `--emit=ast`

adds an ast-dump mode to the existing bytecode/ir/asm emit modes. dumps
lua's parser output before it goes to bytecode. useful for anyone
writing lua tooling or a linter.

### A7. `--print-<name>` diagnostic prints

gcc has `--print-file-name`, `--print-libgcc-file-name`,
`--print-target-triple`, `--print-search-dirs`. build systems key on
these to find compiler-provided files. add:
- `--print-target-triple` -> `x86_64-pc-windows-msvc`
- `--print-search-dirs` -> resolved CLUA_HOME, package search paths,
  sysroot location
- `--print-runtime-path` -> path to runtime-aot.a
- `--print-package-path` -> path to bundled packages dir

### A8. `-Werror=<cat>` for every warning category

framework exists; only `-Wunused` is a category. add:
- `-Wshadow`: local shadows an outer-scope name of the same name
- `-Wunreachable`: code after `return` / `break` / `error()`
- `-Wredundant-assign`: local is assigned twice with no read between
- `-Wdeprecated`: user-declared via `--- @deprecated` in comments

each is a small walk over the Proto's DebugInfo + code. all rely on the
`LcWarn_Scan*` pattern the `warn_unused.c` file established.

### A9. `-fanalyzer` static analysis warnings

deeper analysis:
- `-Wanalyzer-always-false`: `if false then ...`, `while nil do ...`
- `-Wanalyzer-nil-deref`: reading a field of a value proven nil
- `-Wanalyzer-out-of-scope-return`: returning a `local` upvalue past
  its scope (rare in lua but happens with `<close>`)

these need dataflow. gate behind `-fanalyzer` explicitly because the
runtime cost of the pass is non-trivial.

### A10. `clua bug-report` helper

collects `clua version`, target triple, all env vars starting with
CLUA_, the .gitattributes and .gitignore states, the last commit,
optionally a minimal reproducer. writes to a single markdown file
users can paste into a github issue.

### A11. attributes: `@hot`, `@cold`, `@inline`, `@noreturn`

user hints via annotations in comments above functions:
```lua
--- @hot
--- @inline
local function fast_path(x, y)
  return x + y
end
```

the resolver/lifter reads these and attaches to LcFunc:
- `@hot`: keep the function's proofs even if the module trips
  `no_proofs`, prioritize its slots for register residency
- `@cold`: skip proofs, emit smallest possible code, section
  `.text$cold` so linker groups them at the end
- `@inline`: hint the (currently-stub) `inline_small` pass
- `@noreturn`: elide the epilogue after a call to it

first shipping subset: `@hot` and `@noreturn` only. others come with
the passes that consume them.

### A12. coverage instrumentation (`--coverage`)

`-fprofile-arcs` equivalent. emits a counter per basic block; the
counters are written to `<exe>.gcov`-style file at process exit.
consumed by a small `tools/coverage-report.lua` that prints per-line
hit counts.

### A13. profiling instrumentation (`-pg`)

emits an entry-hook call at every function prologue that records the
function name and a timestamp. dumped as a `<exe>.prof` file at
process exit. consumed by a small viewer or by `gprof` (if the format
is compatible).

## track B: output binary hardening

these are all one-time PE-emitter changes. every binary emitted becomes
more windows-native.

### B1. version-info resource

every professional windows exe has a VS_VERSION_INFO resource carrying:
`FileVersion`, `ProductVersion`, `FileDescription`, `ProductName`,
`CompanyName`, `LegalCopyright`, `InternalName`, `OriginalFilename`.
shows in file explorer's properties dialog, in task manager, and in
the file's tooltip.

fill from a project-level file (`clua.toml` or similar; defaults if
absent). new pe section `.rsrc` carrying an RT_VERSION resource entry.

### B2. manifest resource

every windows 10+ exe should have an XML manifest declaring:
- supported windows versions (10, 11)
- DPI awareness (per-monitor v2 recommended)
- long-path awareness (opt-in past 260 characters)
- common controls version (6.0 for modern widgets)
- UTF-8 code page (windows 10 1903+)

without a manifest, windows applies compatibility shims that WILL
change behavior (dpi virtualization, path length limits, code page
translations). the manifest gets stored as an RT_MANIFEST resource
in `.rsrc` next to the version info. default template lives at
`build/dist-manifest.xml`.

### B3. application icon

`--icon=<path>` embeds an .ico file as an RT_GROUP_ICON + RT_ICON
resource. shows in file explorer, taskbar, alt-tab. default is a
built-in clua icon so exes are visually distinguishable from generic
console programs.

### B4. LOAD_CONFIG directory

required for every windows binary that wants CFG. contains:
- security cookie address (for `/GS` stack cookie protection)
- SE handler table (32-bit only, skip)
- CFG check function pointer table
- CFG dispatch check function
- CFG function table
- GuardFlags with the CET / CFG bits set

emit an `_load_config_used` section that pe_emit places in the
LOAD_CONFIG directory entry.

### B5. Control Flow Guard (CFG)

`/guard:cf` in msvc terms. adds a bitmap of valid indirect-call
targets and a check function that verifies the target before every
indirect call. the JIT-less compiled clua binary has only
compile-time-known call targets, so the bitmap is easy to build.

three parts:
1. compiler: emit calls to `_guard_check_icall_fptr` before every
   indirect call (there is none in AOT-compiled Lua; the runtime
   helpers might have some).
2. linker: build the CFG function table bitmap, set the GuardCFEnabled
   bit in LOAD_CONFIG.
3. header: set `IMAGE_DLLCHARACTERISTICS_GUARD_CF` in DllCharacteristics.

### B6. stack cookies (`/GS`)

msvc's `/GS` inserts a canary in the stack frame of any function that
takes a buffer of local storage; on return, the canary is checked and
the process aborts if the value changed. protects against stack
buffer overflows.

AOT-compiled lua functions do not have local buffers (values live on
the lua stack, not the native stack). the runtime helpers do. add the
`/GS`-equivalent instrumentation to the runtime's Rt_* helpers via a
compile flag when the runtime is built.

### B7. DEBUG directory pointing at a pdb

right now `-g` writes a custom `.clualn` section. add a proper
DEBUG_DIRECTORY entry with a CV_INFO_PDB70 record naming an external
`.pdb`. windows debuggers key on this to find the pdb by GUID. the
`.pdb` itself is a separate arc; this is the wiring so that when the
pdb lands, exes point at it.

### B8. delay-load imports

`__declspec(dllimport)` + delay-load thunks let a DLL be loaded on
first use rather than at process start. useful for optional
dependencies (like the FFI stdlib DLLs when no ffi call ever fires).

wire via `--delayload=DLLNAME` flag; the pe emitter generates the
delay-load descriptor and thunks.

### B9. bound imports

pre-compute IAT slot values against known DLL versions to skip the
loader's fixup pass. small startup win (a few ms). obsoleted by ASLR
in practice but occasionally still requested; do this only if the
flag is set.

### B10. `--strip=<mode>`

- `--strip=none`: keep every symbol
- `--strip=debug`: drop `.clualn`, `.debug*`, keep names for the
  export table
- `--strip=all`: drop everything the loader does not need (default
  today)

## track C: bigger follow-ups

### C1. real .pdb debug info

a proper `.pdb` needs the MSF (Multi-Stream File) container format,
type stream (TPI), id stream (IPI), module stream (DBI), and
per-module symbol + line-info substreams. weeks of work; needs its
own arc. the wiring in B7 above is the placeholder.

### C2. static analysis expansion

A9's `-fanalyzer` starts small. real static analysis (like clang's
`-fanalyzer`) does interprocedural taint tracking, symbolic execution
of small paths, and uses a summary language for library functions.
huge project; drops into a separate `clua-analyzer` binary.

### C3. LTO across DLL boundaries

we do intra-module + cross-module (via require) reachability. lto
across a `--shared-rt` DLL boundary would need summaries the runtime
publishes to the driver. useful for a many-tool workspace.

### C4. .gitattributes for git-archive parity

`git archive HEAD -o release.zip` should produce a subset of the
official release zip (missing built binaries but with source and
docs). requires a `.gitattributes` with `export-ignore` on
build-only paths, and a small tool that verifies parity.

### C5. incremental cache expansion

today the cache is per-function COFF. extend to per-module (so a
module that re-parses to the same bytecode skips lift + optimize
too). requires a lift-output hash.

### C6. reproducibility gate in CI

we have byte-identity across `-j` values. extend to: same commit +
same env = same binary bytes across two independent machines. needs
a CI matrix.

### C7. `-Werror=<cat>` for every future category

frame is there; each new category adds one line.

### C8. distribution formats

- MSI installer (for admin/system-wide install)
- winget manifest
- Chocolatey / scoop packages
- MSIX / Windows Store package

## ordering

phase 0 (crucial, developer error experience, first):
- A0.1 multi-line context + secondary spans
- A0.2 "did you mean" suggestions
- A0.3 contextual hints for the top 20 error patterns
- A0.7 JSON diagnostic output
- A0.10 error test suite (30 fixtures)

phase A1 (all in parallel, small scope):
- A2 depfile output
- A3 response files
- A6 --emit=ast
- A7 --print-<name> flags
- A10 clua bug-report
- B10 --strip=<mode>

phase A2 (all in parallel, medium):
- A1 multi-error reporting
- A4 clua explain <code>
- A5 doc-comment extraction
- A8 -Wshadow, -Wunreachable, -Wredundant-assign
- A11 @hot + @noreturn attributes
- A12 --coverage
- A13 -pg

phase B (parallel, all touch pe_emit.c):
- B1 version-info resource
- B2 manifest resource
- B3 --icon
- B4 LOAD_CONFIG directory
- B5 CFG
- B6 stack cookies for the runtime
- B7 DEBUG directory pointing at pdb
- B8 delay-load
- B9 bound imports

phase C: deferred, design notes only.

## gates

every phase's merge must keep the suite green. every binary-emitter
change (track B) must preserve byte-identity of `-O0` and `-O1` output
UNLESS the change is inherently to add new PE content (in which case
the byte-identity gate updates to include the new content).
