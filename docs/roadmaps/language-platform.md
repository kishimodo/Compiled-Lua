# Roadmap: CLua as a complete language platform

Design plan for the next major arc: tooling (linter, IntelliSense), language
dynamism, ecosystem, and the codebase reorganisation that has to happen alongside
it. Written 2026-07-26 against `8dd37e7`.

This is a **design document with an execution order**, not a status file. Per-item
status belongs in [`concurrency-size-stability.md`](concurrency-size-stability.md)
or a successor once items start landing.

---

## 0. What already exists (survey, not assumption)

Anything designed here has to extend these, not duplicate them:

| Capability | Where | State |
|---|---|---|
| Parser / module resolution | `clua/src/compiler/resolve.c` | Works, but **parses each module twice** and keeps no position-preserving tree |
| Diagnostic formatting | `clua/src/compiler/diag.c` (237 lines) | gcc-style `file:line:col: error:` + snippet + caret. Formatter only |
| **A real linter** | `clua/src/runtime/packages/lint/init.lua` (702 lines) | W001–W008, its **own lexer**, scope tracking, Levenshtein typo suggestions. Ships as a *runtime package*, not wired into the compiler |
| Type inference | `clua/src/opt/passes.c` (`ip_typeprop`) | Real, interprocedural. Nothing surfaces it to a user |
| FFI | `clua/src/ffi/` (14 modules) | `cdecl` lexer+parser, thunks, callbacks, marshalling, VEH, Win32 typedefs |
| Windows bindings | `clua/src/runtime/packages/windows/` (29 modules) | Large and hand-written; `auth.lua` alone is 4,913 lines |
| Package manager | `rover/src/rover.lua` (2,627 lines) | Transactional store, locks, semver, signed indexes. Single file, `cmd.exe`-driven |
| Packages | 195 total | Substantial stdlib already |
| Editor integration | — | **None.** No LSP, no `.vscode`, no `textDocument` anywhere |

**The central architectural problem:** three independent front ends. A linter and
IntelliSense cannot be built cheaply on top of that, and the two existing analysis
paths will drift. Fixing it is item 1 and everything else depends on it.

---

## 1. The shared front end (`clua/src/fe/`) — the keystone

Everything in this document is either blocked on this or made twice as expensive
without it.

**Build a lossless, error-tolerant syntax tree** — the `rust-analyzer`/`rowan`
model: every token, including trivia (whitespace, comments), is retained, and the
tree is reconstructible into the exact source bytes. This is what lets one library
serve a compiler (which wants a clean AST), a linter (which wants comments, for
suppression pragmas, and exact spans, for fix-its), and an LSP (which wants to
answer questions about a file that does not currently parse).

```
clua/src/fe/
  lexer.c/.h        one lexer, shared. Retires the lint package's private copy.
  cst.c/.h          lossless tree: kind, span, children, trivia. Arena-allocated.
  parse.c/.h        error-tolerant: on a syntax error, insert an ERROR node and
                    keep going, so a half-typed file still yields a usable tree.
  ast.c/.h          typed view over the CST for consumers that want structure
  symbols.c/.h      scopes, bindings, upvalue capture, module exports
  resolve_mod.c/.h  module graph (absorbs resolve.c's job, parsing ONCE)
  span.c/.h         byte offset <-> line/col, UTF-8 aware
  diag.c/.h         diagnostic model: code, severity, primary + secondary spans,
                    notes, and structured FIX-ITS (replacement spans)
```

Non-negotiables:

- **Parse once.** `resolve.c`'s double parse goes away; the CST is cached per file
  keyed by content hash.
- **Positions are UTF-8-aware from day one.** LSP speaks UTF-16 code units by
  default; getting this wrong later means every span in every feature is subtly
  wrong on non-ASCII files. Convert at the protocol boundary, store byte offsets
  internally.
- **The compiler must produce byte-identical output afterwards.**
  `tools/check-byte-identity.py` is the gate; this is a pure refactor of the front
  end, and the 18-row corpus must not move.
- **No mutable file-scope state**, per the existing invariant — an LSP is
  long-running and will eventually want to analyse files concurrently.

Why not skip straight to the LSP on top of the existing parser: because the
existing parser throws on the first syntax error, and an editor's most common state
is "the file does not parse yet". Error tolerance is not an add-on.

---

## 2. Linter (`clua lint`)

The existing lint package already has the hard part — scope tracking and useful
checks. The work is to **move it onto the shared front end** and give it the
infrastructure a real linter needs.

### Architecture

- **Rule registry** in C, one entry per rule: stable code, name, category,
  default severity, short + long description, and whether it offers a fix-it.
  Keep W001–W008 exactly as they are — they are already documented and tested.
- **Rules run over the CST**, not a private lexer. Two rule shapes: syntactic
  (pattern over the tree) and semantic (needs the symbol table or the optimizer's
  type facts).
- **Severity levels**: `error` / `warning` / `info` / `hint`, configurable per
  rule, with `--deny`, `--warn`, `--allow` overriding (Rust's model, which is
  strictly better than a single `-Werror` switch).

### Suppression

Comment pragmas, because CLua has no attribute syntax:

```lua
---@clua allow W004                 -- next statement
---@clua allow W004 "loop is intentional"   -- with a required reason
--[[@clua allow-file W012 ]]        -- whole file
```

Design rules learned from other linters: an unused suppression is itself a
warning (`W900: suppression has no effect`), otherwise suppressions accumulate
forever; and a suppression with a reason string is the form to encourage in docs.

### Configuration

A `[lint]` section in the existing `rover.toml` rather than a new file — one
project file is a feature. Rule sets by name (`minimal`, `default`, `strict`,
`pedantic`) so a project picks a level, then adjusts.

### Output

- Human: reuse `diag.c`'s existing gcc-style formatter with the caret.
- `--json`: stable schema for editors and CI. This is also how the LSP consumes
  the linter, so it is not optional.
- `--fix` / `--fix-dry-run`: apply non-overlapping fix-its, print a diff for the
  rest. Never apply a fix that changes behaviour.

### Rules worth adding beyond the current eight

Grouped by what makes them *possible* in CLua specifically:

**Closed-world checks** (unique to CLua — these are compile errors, so catching
them early in the editor is a large quality-of-life win):
- `load`/`loadstring`/`dofile`/`string.dump` use, with the reason;
- dynamic `require(expr)`, with the `-L` remedy in the message;
- a `require` of a package not in `rover.lock`.

**Type-inference-backed** (needs the optimizer's facts — nothing in the Lua
ecosystem can do these):
- a comparison that is always true/false given inferred types;
- arithmetic on a value inferred non-numeric;
- a call whose argument count cannot match any reachable definition;
- a table field read that no reachable write ever sets.

**Performance lints** (CLua compiles AOT, so these have teeth):
- a `"debug"` string literal that silently disables optimizer proofs module-wide
  — currently a documented footgun with no warning;
- a library-name string literal that trips the feature scan and grows the binary
  (measured at up to 47 KB — see `docs/benchmarks/README.md`);
- string concatenation in a loop where `table.concat` applies.

**Correctness**: shadowed locals; unreachable code after `return`; unbalanced
`pcall` returns ignored; integer/float division confusion (`/` vs `//`);
`os.exit` inside a library module.

---

## 3. IntelliSense (`clua-lsp.exe`)

A separate executable speaking LSP over stdio, linking the same `fe/` library.
Separate binary, not a `clua` subcommand: it is long-running and stateful, and a
crash in it must not be a crash in the compiler.

### Phasing (each phase independently useful)

**Phase 1 — the 80%.** `initialize`/`shutdown`, `textDocument/didOpen|didChange|
didClose` (full-document sync first), `publishDiagnostics` (compiler errors +
lints), `hover` (declaration + inferred type), `definition`, `documentSymbol`,
`completion` for locals, globals, package members and `require` paths.

**Phase 2 — the polish.** `signatureHelp`, `references`, `rename` (needs the
symbol table to be trustworthy), `workspaceSymbol`, `semanticTokens` (correct
highlighting for free), `formatting`.

**Phase 3 — the differentiators.**
- **Inlay type hints from real inference.** `ip_typeprop` already proves types
  interprocedurally. Showing `local x --[[: integer]]` is something no Lua
  language server can do, because they guess and CLua *knows*.
- **Code actions** driven by linter fix-its.
- **Incremental reparse** (range sync + reuse of unchanged subtrees) once files
  get big enough to need it — measure before building it.
- **Inline binary-size feedback**: a codelens on a `require` showing what it costs
  the binary. Directly enabled by the feature-scan measurements.

### Client

A thin VS Code extension in `editors/vscode/`: syntax grammar, LSP client, and
tasks for `clua build`/`run`/`check`. Keep it thin — all intelligence server-side
so other editors get it free.

---

## 4. Dynamism, without breaking the closed world

The tension to design around: **CLua is closed-world by contract** — no `load`, no
dynamic `require` — and that is what makes AOT compilation, dead-code elimination
and the type proofs possible. So "more dynamic" has to mean *expressive at compile
time* plus *one honest runtime escape hatch*, rather than quietly reintroducing an
interpreter.

### 4a. Bindings generation (biggest immediate win)

`clua/src/runtime/packages/windows/` is 29 hand-written modules; `auth.lua` is
4,913 lines. Hand-maintaining the Win32 surface does not scale, and
`tools/winmd-gen/` already proves metadata ingestion works.

**`clua bindgen`** — take Windows metadata (`.winmd`) or C headers and emit typed
CLua packages with `ffi.cdef` declarations, doc comments from the metadata, and
correct `HANDLE`/`BOOL`/pointer typedefs. This is `windows-rs`'s model, and it is
the difference between "supports some of Win32" and "supports Win32".

Same machinery serves third-party C libraries: point `bindgen` at a header, get a
package. Also worth generating: an `ffi.cdef` **cache** keyed by header hash, so
declaration parsing is not repeated per build.

### 4b. `comptime` (Zig's idea, and CLua already needs it)

An explicit compile-time evaluation form:

```lua
local TABLE = comptime build_lookup_table(256)   -- evaluated at compile time,
                                                 -- emitted as a constant
```

Why it fits: the optimizer already has constant folding and a `monomorphize` pass
that is a **stub**. `comptime` gives generic containers a real implementation
strategy (specialise per type at compile time) and lets libraries compute tables
without runtime cost. It is also the honest answer to "I want to generate code" in
a closed world.

### 4c. Structural interfaces (Go's idea) → real devirtualisation

Declare a method set; check it structurally at compile time:

```lua
---@interface Reader
---@method read(n: integer): string

local function consume(r --[[: Reader]]) return r:read(64) end
```

Why it fits: `ip_devirt` is also a **stub**. Knowing a call site's method set
statically is exactly what lets it become a direct call. This buys both
expressiveness and speed, and gives the LSP real completion inside such functions.

### 4d. Error handling (Rust's idea, library-first)

A `result` package with `Ok`/`Err`, plus a linter rule (`W9xx: Result discarded`)
that makes ignoring an error a warning. Syntax sugar (`?`-style propagation) only
if the library form proves itself first — a language change is much harder to undo
than a package.

### 4e. Concurrency (Go's idea, partly present)

`async`, `channel`, `thread`, `mutex`, `semaphore` packages already exist. What is
missing is a coherent story: one scheduler, `select` over channels, structured
cancellation, and a documented threading model for the runtime (which today is
single-threaded per `lua_State`). Design before adding surface.

### 4f. The one honest escape hatch: a plugin ABI

For genuine runtime extensibility, do **not** reintroduce `load`. Instead:
`clua build --emit-plugin` produces a DLL exporting a small stable C ABI; a host
program loads it through the existing FFI. The main program stays closed-world and
fully optimised; extensibility is explicit, typed, and versioned. This is the
Rust/Zig answer (`cdylib`) and it keeps every existing guarantee.

---

## 5. Ecosystem (rover)

- **Real solver.** `resolve_graph` still installs while resolving, with no
  backtracking and `pairs()` iteration order. Split solve → fetch → verify →
  install; add backtracking; make the plan deterministic.
- **Workspaces**: multi-package repos with a shared lockfile (Cargo's model).
- **`rover add pkg@^1.2`** with semver ranges rather than pinned adds.
- **Index caching** per command — the same registry index is currently fetched
  repeatedly.
- **`rover doc`**: generate docs from doc comments; the LSP and the docs then share
  one source of truth.
- **Publishing**: move from shared-secret HMAC to signed, expiring metadata with
  key rotation and rollback protection (already named in the earlier audit).
- **Reproducible foreign installs**: record an immutable commit/tree digest, since
  GitHub installs currently follow branch heads.

---

## 6. Codebase reorganisation

Multi-thousand-line files, ordered by how much pain they cause:

| File | Lines | Becomes |
|---|---:|---|
| `clua/src/codegen/codegen.c` | 2,228 | `codegen/` → `frame.c`, `savedpc.c`, `residency.c`, `lower_arith.c`, `lower_table.c`, `lower_call.c`, `lower_control.c`, `lower_const.c`, `emit_fn.c`, `cg_internal.h` |
| `clua/src/link/pe_emit.c` | 2,227 | `link/pe/` → `symbols.c`, `contribs.c`, `gc.c`, `layout.c`, `reloc.c`, `imports.c`, `headers.c`, `write.c`, `resolve.c`, `pe_internal.h` |
| `clua/src/compiler/pe_link.c` | 1,548 | legacy path — **delete** if the internal linker fully supersedes it; do not reorganise dead code |
| `clua/src/jit/runtime.c` | 1,513 | `runtime/rt/` grouped by op family: `rt_arith.c`, `rt_table.c`, `rt_call.c`, `rt_upval.c`, `rt_loop.c`, `rt_meta.c` |
| `clua/src/opt/passes.c` | 1,323 | `opt/` one file per pass + `pass_registry.c` (also where `--print-passes` belongs) |
| `rover/src/rover.lua` | 2,627 | `rover/src/` modules; the compiler bundles static `require` already |
| `windows/auth.lua`, `debug.lua`, … | 3.5–4.9k each | split per API family — or largely **generated** once `bindgen` exists, which is why bindgen comes first |
| `imgui/bindings.lua` | 4,372 | already generated by `tools/gen-imgui-bindings.py` — leave it |

### Rules that make splitting safe rather than scary

1. **Byte-identical output is the gate.** Every split is a pure refactor; run
   `tools/check-byte-identity.py` before and after. This is exactly how the
   codegen-context refactor was validated, and it worked.
2. **One `*_internal.h` per folder** holding the shared struct that used to be
   file-local. Do not export it beyond the folder.
3. **`nm` check per folder**, generalising `tools/test-codegen-no-globals.lua`:
   splitting a file tends to promote `static` helpers to external linkage. Assert
   the exported symbol set does not grow.
4. **The Makefile already globs**, so adding files needs no build edit — but header
   dependency tracking must stay green (`tools/test-build-header-deps.lua`).
5. **Split along the seams that already exist.** `pe_emit.c` has clear phase
   boundaries (resolve → collect → gc → layout → relocate → write); `codegen.c`
   splits per lowering family. Do not invent new abstractions during a move.
6. **One file per commit**, so a bisect lands on one move.

---

## 7. Execution order, and why this order

The ordering constraint that matters: **the front end is upstream of the linter and
the LSP, and the reorganisation of `codegen`/`link` is independent of both.** So the
two tracks can proceed in parallel, but within each track the order is forced.

### Phase A — enablers (small, unblocks measurement of everything after)

1. Generalise the guard tests: `nm`-based no-new-globals check per folder, and
   extend the byte-identity corpus with a larger program.
2. Delete `clua/src/compiler/pe_link.c` if the internal linker supersedes it.
   Reorganising or maintaining dead code is pure cost. **Decide before splitting.**
3. `--print-passes` (already designed, previously scoped out) — it makes the
   optimizer legible before anyone reorganises it.

### Phase B — reorganisation (do it BEFORE the feature work lands on these files)

4. Split `link/pe_emit.c` → `link/pe/`.
5. Split `codegen/codegen.c` → per-family files. (Easier now: `LcCgCtx`/`LcCgFnCtx`
   already removed the file-scope state that would have made this painful.)
6. Split `opt/passes.c` per pass; split `jit/runtime.c` by op family.
7. Split `rover/src/rover.lua` into modules.

Rationale: every later item touches codegen or the linker. Splitting first means
feature commits are small and reviewable; splitting later means a merge across a
moved file for every feature in flight.

### Phase C — the front end (the keystone)

8. `fe/lexer.c` + `fe/cst.c` + `fe/span.c`, with the lexer replacing the lint
   package's private copy.
9. `fe/parse.c` error-tolerant parser; `fe/ast.c`.
10. `fe/symbols.c`; then `fe/resolve_mod.c` absorbing `resolve.c` and **parsing
    once**. Gate: byte-identical output, and the front-end share of compile time
    measured before/after.

### Phase D — linter (needs C; small once the front end exists)

11. Rule registry + diagnostic model with fix-its; port W001–W008 onto the CST.
12. Suppression pragmas + `[lint]` config + rule sets.
13. `--json` output and `--fix`.
14. The new rule families, cheapest first: closed-world → correctness →
    performance → type-inference-backed (last, because it needs D and the
    optimizer's facts plumbed out).

### Phase E — IntelliSense (needs C and D)

15. `clua-lsp.exe` skeleton: JSON-RPC, document store, full-document sync,
    `publishDiagnostics` from the compiler + linter.
16. Hover, definition, documentSymbol, completion.
17. VS Code client in `editors/vscode/`.
18. Phase 2 LSP features; then inlay type hints from `ip_typeprop`.

### Phase F — language and ecosystem (needs the tooling to make it usable)

19. `clua bindgen` → regenerate the Windows packages (retires ~25k hand-written
    lines and makes item 6's package splitting mostly moot).
20. `comptime`, then use it to implement `monomorphize` for real.
21. Structural interfaces, then use them to implement `ip_devirt` for real.
22. `result` package + discarded-Result lint; concurrency model; plugin ABI.
23. Rover: solver split, workspaces, index caching, `rover doc`, signing.

**Why F is last:** language features without a linter and IntelliSense are hard to
adopt and easy to misuse. Tooling first makes every subsequent feature land better
— and `bindgen` specifically deletes more code than it adds, which is the best kind
of first feature.

---

## 8. Reference material from other compilers

Reading other implementations is the fastest way to avoid known-bad designs. Clone
to **`D:\clua-refs\`** (207 GB free there; `C:` is tight and OneDrive-synced, which
makes large clones slow and noisy).

| Project | Read it for | License |
|---|---|---|
| `rust-analyzer` | LSP architecture, `rowan` lossless CST, salsa-style incremental queries, code-action model | MIT / Apache-2.0 |
| `rustc` (`rustc_errors`) | diagnostic model: multi-span, notes, structured suggestions, lint levels | MIT / Apache-2.0 |
| `clippy` | lint registry, categories, `#[allow]` semantics, unused-suppression handling | MIT / Apache-2.0 |
| `gopls` | workspace/multi-module handling, cancellation, memory discipline in a long-running server | BSD-3-Clause |
| `zig` | `comptime` semantics, self-hosted backend structure, error-set design | MIT |
| `zls` | a compact LSP in a non-GC language — closest structural analogue to a CLua LSP in C | MIT |
| `lua-language-server` | Lua-specific UX: completion in a dynamically typed language, `---@` annotation conventions worth matching | MIT |

**Licensing discipline — this matters.** Read for *design*, do not paste code.
CLua's own licence and provenance stay clean only if these remain references. If
any snippet is ever adapted, it needs its licence header and an entry in
`docs/fork-manifest.md`, which already exists for exactly this purpose. Matching an
existing convention (`---@` annotations, LSP method names) is interface
compatibility, not copying, and is actively desirable.

---

## 9. What this plan deliberately does not do

- **No JIT, ever.** Nothing here weakens AOT. `comptime` runs in the compiler; the
  plugin ABI is explicit and typed.
- **No `load`.** The closed world is the source of the optimisation guarantees.
- **No new front end per feature.** If an item wants its own parser, that is a
  signal the shared front end is missing something — fix it there.
- **No "rewrite in X".** The C backend works, is measured, and is byte-reproducible.
- **No unmeasured performance claims.** Every item that claims a size or speed
  effect gets an entry in `docs/benchmarks/` with its method, per the rules already
  in that directory.
