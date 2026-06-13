# CLua changelog

## Unreleased

### clua

- **Built-in COFF→PE64 linker — opt-in, no external toolchain.** A new
  self-contained linker (`clua/src/link/{coff_read,ar_read,pe_emit}.c`,
  `LcPe_Link`) reads the codegen object + the CLua runtime/Lua archives + a
  snapshot of the MinGW CRT and emits a runnable stripped console PE directly,
  replacing the gcc/ld subprocess. Implements the input set's full link
  semantics: GNU-archive symbol-index pull to a fixpoint (first-definition-wins;
  explicit objects shadow archive members so `aot_entry.o`'s closed-world stubs
  hide the Lua parser), COMDAT select-any dedup, weak externals, COMMON into
  `.bss`, all seven AMD64 relocations (ADDR64/ADDR32/ADDR32NB, REL32 +
  REL32_1..5, SECREL, SECTION), `$`-suffix grouped/sorted sections, per-DLL
  import directory + IAT + jmp thunks SYNTHESIZED from dlltool long members
  (real export name read from `.idata$6`, so moldname aliases like
  `__set_app_type`→`_set_app_type` resolve), the TLS data directory from
  `_tls_used`, base relocations (DIR64), and `__ImageBase`. The mixed `libucrt.a`
  (import stubs for a dozen `api-ms-win-crt-*.dll` plus real objects like
  `ucrt_fprintf.o`) is handled by per-member classification + a normalized
  head-symbol→DLL map. Opt-in behind `clua build --ld=internal` and
  `CLUA_LD=internal` (flag wins; default + fallback stay gcc). Sysroot snapshot
  via `make -f build/Makefile.luac sysroot` → `build/bin/sysroot` and
  `dist/lib/sysroot`, discovered relocatably next to the runtime archives.
  The full suite passes with `CLUA_LD=internal` forced (499/0). Link time
  drops from ~132 ms to ~76 ms (no gcc subprocess). Validated by
  `tests/unit/test_lc_pe_emit.c` and a `--ld=internal` section in
  `tools/test-clua-cli.lua`. Known gap: no `--gc-sections`, so internal exes
  run ~50 KB larger than gcc's (235 KB vs 187 KB hello), behavior identical.

- **Atomics work in compiled programs (ATOMIC-INTERLOCKED-SYMS-001).** x64
  `Interlocked*` are compiler intrinsics with no exported symbol;
  `clua/src/ffi/ffi_atomics.c` supplies built-in machine-code thunks (GCC
  `__atomic` SEQ_CST builtins → LOCK-prefixed x64 forms) and the FFI symbol
  resolver binds `ffi.C.Interlocked*` to them. The whole concurrency cluster
  (`atomic`, `queue`, `semaphore`, `event`, `mutex`, `channel`) now compiles
  AOT and matches the interpreter byte-for-byte — pinned by
  `tests/differential/aot_concurrency.lua` at O0+O1. (`pool`/`thread` stay
  host-only: they `string.dump` worker functions, which the closed world
  forbids.)

- **No JIT: CLua is purely AOT.** The only execution engines are compiled
  native exes and the reference bytecode interpreter (`clua-interp.exe`, the
  differential oracle — `-i` is a no-op; clua-interp always interprets).
  `clua/src/jit/` carries only the dispatch cache (`dispatch.c`, register +
  lookup), the `Rt_*` AOT runtime helpers (`jit/runtime.c`, lookup-only) and
  W^X exec memory for FFI thunks (`exec_mem.c`); the `LUAC_AOT_RUNTIME` macro
  remains only for coro.c's no-emutls TLS choice in `runtime-aot.a`. The
  bytecode-embedding `compiler.exe`'s blob exes execute through the
  interpreter (no dispatch hook). The test layers migrated with it: Lua
  behavioral tests run under
  the interpreter AND as aotc-compiled exes; the differential and
  conformance layers diff aotc-compiled PEs (at both `-O0` and `-O1`)
  against `clua-interp.exe -i`; the fuzz smoke compiles each seed at `-O1`; the
  package layer diffs the compiled exe's stdout against an `-i` source run.
- **Fix: interpreter OP_EQK register corruption on `cdata == nil/constant`.**
  The LuaJIT-compat exception in `clua_Interpret`'s OP_EQK (full userdata may
  compare via `__eq`) called `luaV_equalobj` without `Protect`, so the
  metamethod call wrote its frame at a stale `L->top.p` inside the live
  register window — `cd ~= nil` as a call argument overwrote the callee
  register ("attempt to call a boolean value"). Now runs under `Protect`
  exactly like OP_EQ. Pre-existing (verified against the previous HEAD);
  exposed the moment the migrated suite first ran `tests/lua` and the
  package exes through the interpreter. Regression pinned by
  `tests/lua/test_cdata_eq_register.lua`.
- **Fix: FFI callbacks in compiled exes.** `Clua_OpenFfi` (the opt-in FFI
  anchor) never registered the callback-dispatch `lua_State`, so a
  `ffi.cast`'d Lua callback invoked from C silently returned 0 in every
  AOT-compiled exe. It now calls `Ffi_SetDispatchL(L)` as the runtime
  bring-up requires (exposed by compiling `tests/lua/test_ffi_callback_args.lua`
  in the migrated behavioral layer).
- **Opt-in shared runtime: `clua build --shared-rt`** (also on `aotc`). Links
  the program against a new `clua-rt.dll` (the full AOT runtime + Lua core,
  built once, shipped in `lib\`) instead of the static archives, dropping a
  hello-world from ~186 KB to ~30 KB — for workspaces with many small tools,
  the runtime ships once instead of per-exe. The exe needs `clua-rt.dll`
  beside it (or on PATH) at run time. Composition mirrors a static exe's
  link: no Lua front-end (the closed-world stubs moved to
  `clua/src/runtime/closed_world_stubs.c`, textually included by
  `aot_entry.c` so static links are unchanged, and compiled standalone into
  the DLL), no legacy blob-boot objects, and the FULL interpreter (debug-using
  programs share the same DLL, so `lvm_nointerp` does not apply).
  `protoinit_rt.o` links into each exe (it reads `luac_protoblob`/
  `luac_fn_table` from the user object — a DLL cannot import from its host).
  **Static linking stays the default and is byte-for-byte unaffected.**
  `dist\lib\` now ships `clua-rt.dll` + `libclua-rt.dll.a` + `protoinit_rt.o`.

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
