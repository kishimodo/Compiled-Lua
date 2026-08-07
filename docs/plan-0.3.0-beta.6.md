# plan for 0.3.0-beta.6

follow-on to beta.5. same style rules: lowercase, ascii only, no em dashes,
no smart quotes, no invented measurements, no ai watermarks.

## what this cycle does

four tracks. tracks D and E are lua++-style language sugar and static
typing. track F is compiler ergonomics (auto-defaults, config file,
parallel-by-default, output-kind detection). track G is optimization work
on top of the existing typeprop / codegen pipeline.

## track D: lua++ language sugar (all lifter or lexer)

nothing in track D touches the ir or the backend. every item lowers to
plain lua 5.4 bytecode before the lifter sees it, so byte-identity of any
program that does not use the new sugar is preserved.

### D1. compound assignment operators

    +=  -=  *=  /=  //=  %=  ^=  ..=  &=  |=  ~=(xor)  <<=  >>=

lifter rewrite: `x += y` becomes `x = x + y`. the lua++ set stops at
`..=`; we add the bitwise variants ourselves. no conflict with any current
lua 5.4 token because none of these compound forms parse today.

### D2. `++` and `--`, prefix and postfix

`i++` returns the old value; `++i` returns the new value. matches c.
scope is restricted to LOCAL variables: everything in lua is a reference
and pushing `++` through table fields, upvalues, or globals opens a
metatable / gc-barrier can of worms we do not want to open in a sugar
pass. table-field mutation stays explicit.

conflict: `--` is lua's line-comment prefix. resolution: the lexer
already tracks statement position; a `--` at column 0 of a statement or
immediately after a token that can end an expression is decrement, a
`--` after whitespace at start-of-statement or start-of-file is a
comment. same trick lua++ uses.

### D3. c-style comparison + logic

    !=   for  ~=
    !    for  not
    &&   for  and
    ||   for  or

sugar only. `!` and `!=` do not currently exist in lua's grammar so no
collision. `&&` and `||` also do not exist.

### D4. `/* ... */` block comments

no collision (lua's long comment is `--[[ ... ]]`, which stays valid).
lexer patch only.

### D5. numeric literal upgrades

    0b0101         binary
    0o755          octal
    1_000_000      digit separator (works in hex, binary, octal, decimal)

lua 5.4 already has `0x` for hex; the separator extends to that too.
lexer patch only.

### D6. `continue` keyword

lifter rewrite: `continue` becomes `goto continue` and the containing
loop grows an implicit `::continue::` label just before its end. lua 5.4
already supports the goto form; the sugar is a one-line ast transform.

### D7. c-style `for (init; cond; step) { body }`

lifter detects the paren after `for` and rewrites to
`do init; while cond do body; step end end`. lua's numeric `for i = 1, N`
stays valid because it never has a paren.

body braces `{ }` around the loop body are ALSO handled here: a lifter
that already understands paren-form for can accept `{ }` as an
alternative block delimiter inside the sugar. `{ }` OUTSIDE that context
still means table constructor.

### D8. `//` line comments (deferred, pragma-guarded)

collides with lua's integer division. decision deferred to the merge that
lands D7 because it is the same lexer surface. three options on the
table:

  a. no `//` comments; `//` stays integer division only.
  b. file-level pragma `--!c-comments` at line 1 enables `//` for the
     rest of the file. lua++'s choice.
  c. heuristic: `//` is a comment when it starts a line or is preceded
     by whitespace and followed by whitespace or end-of-line; otherwise
     it is integer division. never wrong for real code but the
     backtracking makes error messages worse when a user writes
     `x = a //b` intending division.

pick (b) unless there is a reason not to; a one-line pragma is honest
and cheap.

## track E: static typing (grammar first, semantics later)

we accept the syntax and store the annotations on the ast. nothing in
the optimizer or codegen consumes them YET. the point of landing the
grammar first is that user code can start carrying type information
without any behavior change, and a later pass can lift the constraints
into typeprop for real perf wins without reparsing.

### E1. annotations on locals, params, returns

    local x: number = 5
    function add(a: number, b: number): number
      return a + b
    end
    local t: {x: number, y: number} = {x = 1, y = 2}

grammar: `:` `type` after each name in a `local` binding, in each
parameter of a `function`, and after the parameter list for the return
type. multiple return values use `:` `(t1, t2)`.

### E2. optional field marker `?`

    local point: {x: number, y: number, label?: string} = ...

`label?: string` means the field may be nil. purely informational for
now (permits nil in the type check that does not exist yet); at the
grammar layer it just sets a flag on the field node.

### E3. array type syntax `T[]`

    local xs: number[] = {1, 2, 3}

square brackets ONLY. no angle-bracket `Array<T>` form (angle brackets
are already `<` and `>` operators, and lua++ picked `<T>` for interface
generics we are explicitly skipping). `T[]` is unambiguous because `[`
in a type position never means index.

### E4. type aliases

    type Point = {x: number, y: number}
    type Handler = (string, number) => boolean
    local p: Point = ...

`type Name = ...` at statement position. purely a naming shortcut; the
alias is resolved before codegen sees it.

### E5. function types as first-class values

    local h: (number, number) => number = function(a, b) return a + b end

the `=>` return arrow (borrowed from lorraine) marks a function type.
this DOES need a new ir type node so the alias in E4 and the annotation
in E1 can carry a function type. still purely informational at codegen
time; the codegen path for a value carrying a function type is
byte-identical to the current path for an untyped function value.

### E6. later: hook types into typeprop

not in this cycle. once E1-E5 land, a follow-up cycle adds a pass that
walks the annotated ast and pins the corresponding ir slots to the
declared types, feeding typeprop with facts it currently has to infer.
that is where the real perf win lives.

## track F: compiler ergonomics (real-compiler defaults)

the compiler should feel like `cargo build`, `go build`, `zig build-exe`
one-liners, not like an old make invocation. defaults matter more than
flags.

### F1. `-j` defaults to all cores, always

per the codebase memory the default is already `CPU count clamped to
module function count`. this cycle documents that in the help text
(users still ask), and audits every subcommand (`build`, `check`, `run`,
`test`) to make sure none of them silently defaults to `-j 1`. resolve
and typeprop stay sequential for now (parallelizing them is track G4).

### F2. output-kind detection from source

today the driver defaults to `--output=exe` and requires
`--output=dll` / `--output=obj` / `--output=lib` for other kinds. after
this cycle the driver picks the kind from the source itself and only
falls back to `--output=` if the user explicitly overrides:

  - source has `_exports = { ... }` at module scope -> DLL
  - source has `--!obj` or `--!lib` pragma at line 1 -> OBJ / LIB
  - anything else -> EXE (the current default)

the driver still honors an explicit `--output=<kind>` (which wins) and
still honors `-shared` (dll shorthand). the detection is purely a
better default.

### F3. config file support: `clua.toml`

per-project config that supplies compiler defaults so a user does not
have to remember flags. TOML because the rest of the toolchain
ecosystem (rover, cargo, ruff, pyproject) uses it, it parses without a
schema, and it is line-oriented so diffs read well.

layout:
```toml
[build]
optimization = "O2"        # -O0 .. -O3
output = "exe"             # override auto-detection
strip = "all"              # none | debug | all
jobs = 0                   # 0 = all cores
debug = false              # -g / --debug
cache = true               # persistent per-function cache
shared-rt = false          # link against clua-rt.dll
color = "auto"             # auto | always | never

[diagnostics]
format = "text"            # text | json
werror = false             # promote all warnings to errors
warn = ["unused", "shadow"]  # -W categories to enable

[resource]
product-name = "MyApp"
product-version = "1.2.3"
company-name = "Acme"
copyright = "(c) 2026 Acme"
manifest = "assets/app.manifest"
icon = "assets/app.ico"

[explain]
target-triple = "x86_64-pc-windows-msvc"

[[bundle]]
package = "sqlite"
```

precedence, lowest to highest: builtin defaults, `clua.toml` in the
project root (walked up from cwd like git), env vars (`CLUA_*`),
command-line flags. every CLI flag has a config-file equivalent; the
mapping is mechanical (`-Onnn` -> `optimization = "Onnn"`, etc).

discovery: `clua` walks from cwd upward looking for `clua.toml` (stops
at a `.git` directory or filesystem root, same walk as git config).
found files are merged root-to-leaf (nearest wins on conflict).

### F4. sensible defaults audit

audit every flag with a default value and record whether the default is
what a user with no flags actually wants. examples where the default is
already correct: `-O2`, `-j all cores`, `--strip=all`, `--color=auto`.
examples that need review: whether `--emit=<mode>` should default to
`bytecode` on stderr for `clua check`, whether `-g` should be the
default for `clua run`, whether `--diagnostics-format` should sniff
`$TERM_PROGRAM` for editor sessions and switch to json without asking.

document every default and its rationale in `docs/defaults.md`. one
line per flag.

## track G: optimization (compile-time and run-time)

everything in G improves either how fast the compiler runs or how fast
the emitted binary runs. all items are additive; none of them changes
the ir shape user code sees.

### G1. parallel resolve

resolve currently walks one module at a time. after this pass, once the
entry module has been parsed and its `require` set is known, resolve
farms independent module compilations across the same worker pool
codegen uses. shared cache dir is already thread-safe (per the memory
notes on the anchor split).

### G2. parallel typeprop / optimization passes

`ip_typeprop` is the real perf pass; today it runs sequentially over
every reachable function. after this pass, per-function optimization
runs on the worker pool. typeprop's inter-procedural facts are collected
in a shared, mutex-guarded table.

### G3. cache the resolved+lifted ir

we already cache codegen output per function. the resolve + lift
phases are the SECOND largest cost on a warm build. keying the cache
on `(source content hash, compiler version, flags-that-affect-lift)`
lets a warm rebuild skip resolve + lift entirely for unchanged modules.

### G4. incremental link

when only one module changed and the codegen cache hit for every
function, the resulting .o is byte-identical for the unchanged
modules. the link phase then only needs to relink; skip the ProtoInit
regeneration when the module-set is unchanged.

### G5. constant loop unrolling

`for i = 1, N do body end` with `N` a compile-time constant `<= 8`
unrolls into `body` `N` times, letting typeprop and the peephole see
straight-line code. the ir already knows about numeric for-loops so
this is a peephole in the optimizer, not a codegen change.

### G6. auto-vectorization of pure-arithmetic loops

a loop body that is (a) numeric-for with a compile-time step of 1, (b)
contains only arithmetic on integer or number registers, and (c)
touches no globals / no calls / no metatables, is a candidate for
sse2 emission (four integers or two doubles per iteration). first
target is the tight `for i = 1, N do sum = sum + a[i] end` kernel
that every benchmark uses.

### G7. small-function inlining

when `ip_typeprop` has proven a callee's signature and the callee body
is `<= 16` ir instructions, inline the callee at the call site. saves
the Rt_Call trampoline and unlocks further typeprop across the join.
guard with a `@noinline` attribute for cases where the user wants the
symbol kept.

### G8. escape analysis + stack-allocated tables

when a table constructor's result never escapes its function (never
returned, never stored in an upvalue, never captured by a closure),
allocate its storage on the native frame instead of via `luaH_new` +
`luaC_barrier`. currently a hot loop that allocates a fresh table per
iteration is dominated by gc work; escape-allocated tables move that
to a single stack bump.

### G9. -Oz size-optimized mode

today `-O2` and `-O3` chase speed; `-Oz` currently doesn't exist
(rejected). add a real `-Oz` that (i) picks the smallest of each
equivalent codegen sequence, (ii) turns on `--strip=all`, (iii)
suppresses debug/lineinfo sections unconditionally, (iv) forces
`--shared-rt` if the runtime dll is discoverable.

### G10. profile-guided optimization (design only this cycle)

design note: how a two-pass build works. pass 1 emits an instrumented
binary that writes a profile file at exit. pass 2 reads the profile
and uses hot-function counts to bias inlining decisions (G7),
loop-body layout, and register allocation priority. implementation is
punted to a future cycle; the design note fixes the profile format
and the pass-1 instrumentation hooks so we do not paint ourselves
into a corner.

### G11. loop-invariant code motion (LICM)

hoist expressions out of loops when typeprop has proven their inputs
do not change across iterations. small ir pass; runs after G7 so
inlined callees are visible to the hoister.

### G12. common subexpression elimination (CSE)

hash-cons pure expressions per basic block so `t.x + t.x` computes
`t.x` once. medium; needs a purity lattice on the ir (loads without
metatable side effects are pure; calls generally are not without
typeprop help).

### G13. strength reduction (peephole)

    x * 2         becomes  x + x
    x * (2^n)     becomes  x << n
    x / (2^n)     becomes  x >> n  (unsigned)  or  arithmetic shift
    x % (2^n)     becomes  x & (2^n - 1)
    x * 3         becomes  (x << 1) + x       (lea on x64)

peephole in the x64 emitter. free; only applies when typeprop
confirmed integer-typed operands.

### G14. tail-call elimination for direct recursion

`return f(x - 1)` reuses the current native frame instead of pushing
a new one. only fires when the callee is the same function (direct
self-recursion) and no metamethod could intercept. saves the Rt_Call
trampoline and a stack frame per iteration; unbounded recursion
becomes a plain loop.

### G15. polymorphic inline caches for `.field` access

first hit on `t.field` records the table's shape (its metatable
identity + array size + hash size). subsequent hits check the shape
in ~3 ins and jump straight to the stored slot offset, skipping
`luaH_get`. medium; new ir slot for the cache and a runtime helper
to compute + compare a shape id.

### G16. AVX2 / AVX-512 kernels beyond G6's SSE2

same trigger conditions as G6 with wider vectors. guarded by a one-
time cpuid probe at binary startup that picks the widest ISA the host
supports; the AOT emits all three variants and the entry-point dispatch
picks one. baseline x64 stays supported.

### G17. branch-prediction hints (front-end inferred)

ir gains a `cold` bit on branches. the front end sets it when a branch
body contains only `assert(false)`, `error(...)`, or `return` (and
nothing else). the x64 emitter uses the `2e` / `3e` prefix bytes to
hint the CPU which side is likely.

### G18. devirtualize known method calls (make ip_devirt real)

`obj:method(x)` where typeprop has pinned `obj`'s metatable to a known
literal, and that metatable's `method` slot is a known function,
compiles to a direct call to the resolved body. this is the "ip_devirt
pass" listed as a stub in the current changelog; making it real is
what turns `-O2` into something -O1 does not do.

### G19. bump allocator for AST + IR

every ast node is currently a `malloc`. per-compilation arena
allocated in 64 KB chunks and freed at end. ~15% wall-clock win on a
large module and eliminates a whole class of leak. medium refactor
(every `free` site becomes a no-op; every allocation swaps).

### G20. persistent typeprop facts across builds

G3 caches the ir; this caches the typeprop lattice AND the ip_devirt
proofs. warm rebuild of an unchanged module skips typeprop AND
codegen (already cached), so the only work left is link.

### G21. build daemon: `clua daemon`

long-lived process that keeps the compiler warm and serves builds
over a local named pipe (windows) or unix socket. rebuild latency
drops from `cold clua.exe startup` to `IR cache lookup + link`. every
subcommand transparently connects to the daemon if it is running.
medium; needs an rpc layer and process supervision.

### G22. watch mode: `clua watch`

daemon plus a `ReadDirectoryChangesW` filesystem watcher. recompiles
on save and prints only the DIFF of new diagnostics (not the full
error list every time). free once G21 lands.

### G23. distributed build cache

codegen `.co` files are already keyed by content hash. add an
`CLUA_CACHE_URL=https://cache.example.com` env var; the driver
consults the remote before compiling and posts new entries after.
zero code change for the local hit path; small addition for the
http fetch/post. auth is a bearer token from `CLUA_CACHE_TOKEN`.

## track H: first-class subcommands (real-compiler ergonomics)

each item is a proper `clua <verb>` subcommand, not a flag. every one
of these already has 80%+ of its guts elsewhere in the tree; this
track pulls them out into stable, documented user-facing surfaces.

### H1. `clua fmt`

canonical formatter, like `gofmt` / `rustfmt` / `zig fmt`. NO config,
NO options, one style. reuses the parser; new pretty-printer emits
back to source. small.

### H2. `clua lint`

runs only the diagnostic passes, not the codegen. all `-W` categories
land here as their own gated pass. much faster than a full build; ci
friendly. reuses the existing warn framework.

### H3. `clua fix`

applies the machine-fixable suggestions that lint / diag prints.
every "did you mean" and every `-Wunused` becomes a mechanical
rewrite. the fixer edits source in place unless `--dry-run` is set.
medium.

### H4. `clua repl`

interactive REPL. each statement compiles to native and executes
in-process against a persistent lua state. massive UX win for
exploration; needs a dispatch shim into the AOT runtime so newly
codegen'd bodies can be called from an already-running process.
medium.

### H5. `clua doc`

generates a browsable HTML tree (with search + per-package index)
from the ldoc-tag comments beta.5 added. reuses the extractor; new
html renderer. small.

### H6. `clua test`

first-class test runner. auto-discover `test_*.lua`, compile each
in isolation, run in worker pool, colored PASS/FAIL/SKIP summary,
`--filter=<pat>`, `--parallel`, `--failfast`. replaces the ad-hoc
`tools/run-tests.lua`. medium (largely lift-and-shift).

### H7. `clua bench`

benchmark harness. `bench_*.lua` files export functions named
`bench_*`; the runner compiles them with `-O2`, runs a warmup, then
timed iterations, reports ns/op with a variance band. hooks into
G10 (PGO) later. small.

### H8. `clua lsp` -- language server

speaks LSP over stdio. every diagnostic already emitted in JSON
(beta.5's `--diagnostics-format=json`) maps to `textDocument/
publishDiagnostics`. also implements `hover`, `definition`,
`references`, `completion` (using the resolve + typeprop facts).
the SINGLE biggest UX lever we can pull: one binary covers VS Code,
Neovim, JetBrains, Zed, Sublime, Helix. medium-to-large but every
component reuses existing code.

## track I: binary and distribution

### I1. cross-compilation to `x86_64-pc-windows-msvc`

today the AOT emits MinGW-ABI COFF that links only against MinGW-ld.
adding an MSVC target triple emits objects with the MSVC ABI (COMDAT
select-any handling, `__chkstk`, `__security_cookie` shape, MSVC
name mangling for statics) so downstream MSVC-linked programs can
consume clua-emitted `.obj` / `.lib`. medium.

### I2. WASM output: `--target=wasm32-wasi`

new backend that emits WebAssembly modules. shares the ir; new
codegen produces WASM instead of x64. wasi runtime imports substitute
for the win32 runtime imports. large. Linux backend is explicitly
NOT in scope; wasm covers the "run in a browser or wasm runtime"
use case without a new native abi.

### I3. reproducible-build verification: `clua verify <exe>`

we already emit deterministic bytes. new subcommand re-runs the
build from source and diffs the produced binary against the shipped
`<exe>`. exit code 0 = bit-identical; nonzero = shows the differing
bytes with a small hex window. free once we commit to the deterministic
invariant (which we do; the memory notes call this out).

### I4. self-compression `--compress`

optional wrapper that shrinks the emitted PE by ~50-70% on
script-heavy programs. CONSTRAINTS the user specified, non-negotiable:

  - CRT-FREE decompressor stub. only native win32 (`VirtualAlloc`,
    `VirtualProtect`, `LoadLibraryA`, `GetProcAddress`, plus the
    ntdll ldr-walk if we want fully static). no libc, no msvcrt,
    no ucrtbase, no MinGW crt0.
  - NO magic-string / no header signature that AV heuristics can
    latch onto. UPX is flagged by AV because (a) many malware families
    ship UPX-packed, and (b) UPX writes literal "UPX0" / "UPX1"
    section names and a fixed 8-byte stub prologue that Yara rules
    match on. our packer MUST:
      * use ordinary section names (`.text`, `.rdata`) for the
        compressed payload, not a distinctive tag
      * randomize the stub layout per build (no fixed prologue
        signature)
      * link the stub as normal code so it looks like a small
        clua binary from the outside
      * NOT modify the PE optional header in any way that would
        make it stop looking like a normal AOT-emitted clua exe
  - deterministic bytes (same source + same compressor version +
    same seed = same compressed bytes). the randomized stub layout
    uses a seed derived from the file content, not a fresh rng,
    so `clua verify` (I3) still works.
  - compression algorithm: LZMA2 or Zstd. leaning zstd (dictionary
    optional, smaller stub, well-documented format).

medium: LZ decompressor in ~2 KB of hand-audited C, plus a driver
subcommand to run compression at the end of the link step. do NOT
shell out to `upx.exe`.

### I5. real PDB output

we already emit `.clualn` (native offset -> lua line map). a PDB
emitter puts the same information in the Microsoft PDB format that
Visual Studio, WinDbg, x64dbg, and PerfView consume natively. large;
this is a new backend for debug info (PDB is a documented but
non-trivial container: MSF header, DBI stream, TPI, IPI, symbol
records, line records).

### I6. split debug info

write `.clualn` (and future PDB from I5) to a sibling `<exe>.dbg`
file instead of embedding in the exe. shipped binary shrinks;
symbols stay available for post-mortem debugging (the on-disk PDB
still gets found by the standard windows debug-info lookup rules).
small once I5 emitter is factored.

## track J: diagnostics and tooling extras

### J1. machine-readable lint suppression

    local unused = 42  -- clua: allow(unused, reason="pending removal")

suppresses `-Wunused` for that line only, with a mandatory `reason`
string. `clua audit-suppressions` prints every suppression in the
project so reviewers can see (and challenge) them all. small; reuses
the warn framework.

### J2. diagnostic groups `--warn=<group>`

    --warn=correctness   correctness-adjacent lints (unused, shadow, ...)
    --warn=style         style lints (naming, unused imports, ...)
    --warn=performance   performance lints (redundant assign, ...)

toggles whole families in one flag. mirrors clippy / rustc lint
levels. cheap once we have >~10 categories.

### J3. `clua explain --auto-fix`

extends the explain database (beta.5) with suggested rewrites. every
diagnostic that has a canonical fix gets one; `clua fix` (H3) applies
them. reuses the explain infrastructure.

### J4. `--pedantic`

single flag that enables every warning at the loudest severity and
every stricter diagnostic. one line for CI. trivial.

### J5. deprecation warnings

    --- @deprecated "use foo() instead"
    function old_bar() ... end

marks a function deprecated at declaration; call sites get a
`-Wdeprecated` warning quoting the message. `--deprecated=<mode>`
and `deprecated = "warn"` in `clua.toml` control severity. sugar
over the existing warn framework.

## track K: vscode-clua editor extension

ship a single vscode marketplace extension `vscode-clua`. base is a
fork of `sumneko/vscode-lua` (MIT-licensed) with our tmLanguage grammar
extended for tracks D and E. we do NOT re-use sumneko's LSP; ours plugs
in through H8 (`clua lsp`) once that lands. until then the extension is
grammar + snippets + tasks only, no language server.

file extension: `.clua` as PRIMARY. `.lua` support is opt-in only via
`"files.associations": {"*.lua": "clua"}` in the user's settings, so
we never silently steal a filetype from the base sumneko extension a
user may already have installed.

### K1. base fork + tmLanguage grammar

fork sumneko/vscode-lua at a pinned commit, rebrand as `vscode-clua`,
extend the tmLanguage grammar to cover:
- new compound operators: `+= -= *= /= //= %= ^= ..= &= |= ~= <<= >>=`
- prefix / postfix `++` `--` (with the same context resolution the
  lexer uses for the `--` comment conflict)
- new tokens: `!= ! && || ?? ?. |> => ->`
- numeric prefixes `0b` / `0o` and digit-separator `_`
- block comments `/* */`
- pragma-gated `//` line comments (grammar reads `firstLineMatch`
  for `--!c-comments` and switches the `//` scope from operator to
  comment for the rest of the file)
- new keywords: `type enum continue switch case default`
- type-annotation context: `: name`, `?: name`, `T[]`, `(A, B) => C`
  (best-effort in tmLanguage; H8 semantic tokens refine later)
- type alias RHS: `type X = ...` scopes the whole RHS as a type context

### K2. snippets

ship the standard set out of the box:
- `for i in 1..N` -> `for i = 1, N do\n  $0\nend`
- `function name(args)` -> `function ${1:name}(${2:args})\n  $0\nend`
- `type Point` -> `type ${1:Point} = { ${2:x: number, y: number} }`
- `switch (x)` -> `switch (${1:x}) {\n  case ${2:a}: $0\n  default: break\n}`
- `local x, y =` -> `local ${1:x}, ${2:y} = $0` (upgrades to
  destructuring `local {x, y} = ...` when destructuring lands)
- one snippet per common lua idiom (`if`, `while`, `for k, v in pairs`,
  `for i, v in ipairs`, `pcall`, `require`, etc)

### K3. bracket + auto-close pairs

configured in `language-configuration.json`:
- `{}` `[]` `()` `""` `''` — the usual set
- `[[ ]]` — lua long strings (already in sumneko)
- `/* */` — new for us

### K4. comment toggling

- default line comment: `--`
- when the file's line 1 has `--!c-comments`: `//`
- block comment: `/* */`

vscode's `commentToggle` uses `language-configuration.json`'s `comments`
key; we set both `lineComment` and `blockComment`. the pragma-aware
switch between `--` and `//` needs a bit more: register a command that
inspects the current file's first line and calls the ordinary
`editor.action.commentLine` with the right prefix. cheap.

### K5. icon

ship a dedicated `.clua` file icon (a colored file glyph with the
clua wordmark) via the `iconThemes` contribution point so file explorer
and tabs distinguish `.clua` from `.lua` at a glance.

### K6. task provider (parses `clua.toml`)

extension implements `vscode.TaskProvider` for the `clua` task type.
when a `clua.toml` is found at workspace root, register these tasks
automatically:
- `clua build` (bound to `ctrl-shift-b` by default)
- `clua test`
- `clua bench`
- `clua fmt`
- `clua lint`
- `clua check`

each task inherits flags from `clua.toml` and prompts the user for
optional args (`--filter=` on test, etc). output pane pipes through
the standard vscode `TaskRun` mechanism so problems get parsed by the
`$clua` matcher (which reads the standard `--> file:line:col` shape
we emit).

### K7. lsp client wiring (needs H8)

once `clua lsp` (H8) lands, the extension activates a
`LanguageClient` on `.clua` files:
- diagnostics via `textDocument/publishDiagnostics` (already the
  shape our JSON diagnostics emit)
- `hover`, `definition`, `references`, `completion`, `rename`,
  `formatting` (routes to `clua fmt`)

### K8. semantic tokens (needs H8)

`clua lsp` emits `textDocument/semanticTokens` frames; the tmLanguage
grammar is the fast-path fallback for the first ~50ms before the
server is up. semantic tokens colour:
- unused locals (grey)
- deprecated calls (strikethrough / dim red)
- typed identifiers (distinct scope from untyped)
- function parameters vs locals vs globals

### K9. debugger adapter `vscode-clua-debug` (deferred, needs I5)

once real pdb output (I5) lands, wire a debug adapter that speaks the
Debug Adapter Protocol on top of the pdb + the runtime's stack
introspection. deferred to a future cycle; noted here so the extension
manifest reserves the `debuggers` contribution point up front.

### K10. tree-sitter grammar (deferred)

portable to neovim, zed, helix, github semantic. not in this cycle.
sketch the grammar shape when K1's tmLanguage stabilises so a future
arc can port cleanly.

## ordering

phase D (all in parallel, small):
- D1 compound assignment
- D2 ++/-- on local variables
- D3 !=/!/&&/||
- D4 /* */
- D5 0b/0o/digit separators
- D6 continue

phase D-late (needs D done):
- D7 c-style for (;;) with `{ }` body
- D8 // line comments (pragma-gated)

phase E (grammar-only; can start alongside phase D):
- E1 annotations on locals / params / returns
- E2 optional field marker
- E3 T[] array type
- E4 type aliases
- E5 function types as first-class values

phase F (independent of D and E):
- F1 -j-default audit + docs
- F2 output-kind detection from source
- F3 clua.toml
- F4 defaults audit + docs/defaults.md

phase G-early (independent):
- G1 parallel resolve
- G2 parallel optimization
- G3 cache resolved+lifted ir
- G4 incremental link
- G19 bump allocator for AST + IR

phase G-mid (needs G-early):
- G5 constant loop unrolling
- G6 sse2 vectorization for numeric kernels
- G11 LICM
- G12 CSE
- G13 strength reduction (peephole)
- G17 branch-prediction hints
- G18 devirtualize known method calls (real ip_devirt)

phase G-late (needs typeprop annotations and/or G-mid):
- G7 small-function inlining
- G8 escape analysis + stack tables
- G14 tail-call elimination for direct recursion
- G15 polymorphic inline caches for .field
- G16 AVX2 / AVX-512 kernels
- G20 persistent typeprop facts across builds
- G21 build daemon: `clua daemon`
- G22 watch mode: `clua watch` (needs G21)
- G23 distributed build cache
- G9 -Oz
- G10 pgo design note

phase H (subcommands, mostly independent):
- H1 clua fmt
- H2 clua lint
- H3 clua fix (needs J3 for auto-fix payloads)
- H4 clua repl
- H5 clua doc
- H6 clua test
- H7 clua bench
- H8 clua lsp (biggest single UX lever)

phase I (binary / distribution, independent):
- I1 cross-compile to x86_64-pc-windows-msvc
- I2 WASM (--target=wasm32-wasi)
- I3 reproducible-build verify: clua verify
- I4 self-compression --compress (CRT-free stub, no header signature,
     deterministic, zstd payload)
- I5 real PDB output
- I6 split debug info (needs I5)

phase J (diagnostics extras, small, can land alongside track A of any cycle):
- J1 machine-readable lint suppression
- J2 diagnostic groups --warn=<group>
- J3 clua explain --auto-fix
- J4 --pedantic
- J5 deprecation warnings

phase K (vscode-clua extension, needs D + E for full grammar):
- K1 base fork + tmLanguage grammar
- K2 snippets
- K3 bracket + auto-close pairs
- K4 comment toggling (with pragma-aware line-comment switch)
- K5 file icon
- K6 task provider parsing clua.toml
- K7 lsp client wiring (needs H8)
- K8 semantic tokens (needs H8)
- K9 debugger adapter (deferred, needs I5)
- K10 tree-sitter grammar (deferred)

## gates

every phase's merge keeps the suite green. every language-sugar item
(track D) has an accompanying test in `tools/test-lang-<name>.lua` that
proves the sugar lowers to bytecode identical to the hand-written lua
equivalent. every optimization (track G) has an accompanying differential
test that proves the optimized output computes the same result as the
unoptimized one on the fuzz corpus.

the `--output=` auto-detection (F2) does not change output BYTES for any
program that used to compile fine with the default; it only changes which
default kind is picked. an existing `--output=exe` on the command line
still wins. no byte-identity regression.
