# CLua changelog

## Unreleased

### rover

- **Official registry default** (Go/cargo-style DX): with no `--registry`
  flag, no `$ROVER_REGISTRY`, and no repo-relative dev registry
  (`rover\registry`, i.e. not run from a source checkout), rover now
  defaults to the official remote registry,
  `https://raw.githubusercontent.com/kishimodo/CLua-Packages/main`, over the
  existing curl-based remote path. Precedence: `--registry` >
  `$ROVER_REGISTRY` > `rover\registry` (source checkout) > official URL.
  (Previously the standalone fallback was `%CLUA_HOME%\registry` /
  `%LOCALAPPDATA%\clua\registry` — directories nothing populated.)
- **Foreign packages (Go-style)**: `rover install` and `rover add` accept
  `https://github.com/<owner>/<repo>` (optional `.git` / trailing slash) and
  the shorthand `github.com/<owner>/<repo>`. The repo is fetched as a
  codeload tarball (branch `main`, falling back to `master`) with the same
  external tools rover already uses (curl + the tar.exe shipped with
  Windows 10+), must carry an `init.lua` at its root (or a `package.lua`
  declaring `entry = "<relative file>"`), and installs flat into the store
  under the lower-cased repo name (allowlist-validated). The `.meta`
  manifest — and `rover.lock` via `add` — records
  `source = "github.com/<owner>/<repo>"`, marking the package FOREIGN:
  install, `verify`, and `list` all print a loud warning (foreign installs
  have **no registry integrity hash**; the install-time hashes still let
  `verify` catch later tampering). `rover install` in a project with a
  foreign lock pin verifies the installed content against the pin instead
  of re-resolving.
- Help text documents the official-registry default, the foreign install
  forms, and PR-based package verification
  (https://github.com/kishimodo/CLua-Packages).
- New suite `tools/test-pkgmgr-foreign.lua`: GitHub URL parsing + name
  derivation (via the `ROVER_PKG_TEST` hook), registry precedence incl. the
  official-URL fallback, and an offline foreign-install end-to-end through
  the `ROVER_FOREIGN_TARBALL` test hook (install/list/verify/add warnings,
  `entry` form, tamper detection, missing-init failure). No network access.

## v0.1.0 — 2026-06-12

The first release of **CLua**, an ahead-of-time compiler for the Lua 5.4
language targeting Windows x64, and **rover**, its package manager.

### The toolchain

- **`clua.exe`** — `clua build app.lua` → `app.exe` (`-O1` default),
  `clua run app.lua -- args`, `clua check`, `clua version`. Relocatable:
  finds its runtime libraries next to the executable or via `CLUA_HOME`;
  works from any directory. Intermediates go to `%TEMP%` and are cleaned.
- **`rover.exe`** — `init` / `add` / `install` / `update` / `remove` /
  `publish` / `verify` / `list` / `search`, with `rover.toml`/`rover.lock`
  project files, lockfile-reproducible installs, whole-tree Merkle
  integrity, semver ranges, and HMAC-signed remote registries. rover is
  itself a CLua-compiled closed-world program.
- The loop works end to end: `rover install <pkg>` → `require "<pkg>"` →
  `clua build` bundles the installed package into the exe.

### The compiled output

- Ordinary PE: native x64 code, standard sections — no bytecode blob, no
  in-binary VM, no JIT. A hello-world is ~177 KB, fully static.
- Emitted exes link a dedicated AOT runtime: no JIT compiler, no Lua
  front-end (`load`-family symbols are closed-world stubs), no FFI, no
  winpthread, and — for programs that never mention `debug` — no bytecode
  interpreter. Programs that use the debug library keep the interpreter and
  match the reference interpreter under `debug.sethook` exactly.
- The optimizer (`-O1`): static int/float type inference with tag-check
  elision, bare integer FORLOOP, loop-region register residency (R12–R15/RSI
  + xmm6–xmm10), interprocedural type propagation. Tight integer loops run
  ~17× the faithful boxed baseline. Soundness was adversarially validated
  across 13 attack rounds; the differential oracle (every program's output
  byte-compared against the reference interpreter at -O0 and -O1) is the
  arbiter, enforced by a 466-test suite.

### Closed world (by design)

`load`, `loadstring`, `dofile`, `string.dump`, and dynamic `require` are
compile errors. Code that evades the static scan gets an attributed runtime
error instead of an escape hatch (see `docs/known-bugs-2026-06-07.md` for
the three documented bounded divergences).

### Requirements & limitations

- Windows x64 only. A MinGW-w64 gcc on PATH (or `CLUA_GCC`) performs the
  final native link — the one external step (a self-contained PE writer is
  planned).
- The ~195 in-tree builtin packages (`json`, `hash`, …) do not yet bundle
  into compiled exes — requiring one is a loud compile error
  (rover-installed packages work). Planned (M4) alongside FFI-in-exes.
- Uncaught runtime errors print `clua: runtime error: <msg>` without a
  stack traceback (AOT-ERRBANNER-001); the message itself matches the
  reference interpreter.
