# CLua changelog

All notable changes are recorded here. The format follows Keep a Changelog and
the project uses semantic versioning. `clua version` reports the current string;
it is rewritten only by `tools/bump-version.ps1`, which keeps the single source
of truth -- `clua/src/common/version.h` -- and this file in step.

## [Unreleased]

## [0.2.0-beta.2] - 2026-06-13

### Added

- **Native OS threads -- `thread.spawn` runs workers on real OS threads.** A
  compiled program can now spawn a "shippable" worker function (one that
  captures no upvalues) onto a real OS thread, where it runs in its own
  `lua_State` at native speed. The function is identified across states by its
  compile-time function-id (the protoblob record index), so nothing is
  serialized as bytecode -- it works in a closed world with no `string.dump` /
  `load`. Arguments and results cross the thread boundary through a small C
  serializer (nil / boolean / number / string / table). A function that captures
  upvalues, or any non-AOT build (the interpreter), transparently runs the
  worker cooperatively instead, so results are identical either way -- pinned by
  `tests/differential/aot_native_thread.lua` at O0+O1. Validated under load (300
  concurrent workers, GC active, byte-exact results).

  This required making the AOT runtime reentrant across OS threads: the dispatch
  cache is now per-worker-thread (a private TLS cache, so no locks and no
  overflow of the shared table), and the JIT recovery frame, tail-call drive
  flag, and current-coroutine pointer became thread-local -- all via Win32 TLS
  rather than `__thread`, which would pull gcc's emutls (and winpthread) into
  every exe. Three concurrency bugs were found and fixed: workers are created
  with `_beginthreadex`, not `CreateThread` (which skips CRT per-thread init and
  corrupts the heap under load); the worker now roots its entry proto tree so the
  GC cannot sweep a user function it will resolve by id; and the per-thread
  runtime state above is isolated. The FFI is intentionally not opened on workers
  (its callback dispatch is a single shared state), so a native worker must be
  ffi-free; worker construction is serialized for now, while the work itself runs
  fully in parallel.

### Changed

- `pool` and `thread` shed their last vestigial real-threading scaffolding: the
  thread package is rewritten around the native path with a cooperative
  fallback, and `pool` documents that it dispatches inline pending a
  cross-`lua_State` task channel.

## [0.2.0-beta.1] - 2026-06-13

The first beta. The toolchain is now self-contained (a built-in COFF->PE64
linker, no gcc needed out of the box), the JIT is gone entirely, and the last
peripheral correctness gaps are closed.

### Fixed

- **All five remaining package XFAILs are fixed** at the root -- they were
  peripheral FFI / OS-API quirks:
  - `network_info` routing decode (NET-ROUTE-002): the `MIB_IPFORWARD_ROW2` /
    `SOCKADDR_INET` cdefs are now byte-exact with the platform ABI
    (`SOCKADDR_INET` forced to size 28 / align 4, and the four route booleans
    are 1-byte `BOOLEAN`, not 4-byte `BOOL`), so the row stride matches and every
    `Table[i]` decodes correctly instead of drifting into garbage.
  - `xpress` tiny inputs (XPRESS-SMALL-001): XPRESS and LZNT1 cannot represent an
    input below their minimum block, so inputs under a safe floor are stored
    verbatim and still round-trip -- the decision is a pure function of format +
    original size, so decompress recovers them with no marker.
  - `secret.wipe(buf)` with no length (SECRET-WIPE-DEFAULTLEN-001): `ffi.sizeof`
    now reports the real length of a variable-length-array cdata, so the
    documented default actually zeroes the buffer.
  - `property.string` length bounds (PROP-STRLEN-001): the character picker used
    two independent random indices, producing variable-length slices that broke
    the `[min_len, max_len]` contract; it now picks a single index.
- **`ffi.sizeof` on a variable-length array** returns the allocated byte size
  rather than 0, matching LuaJIT (benefits every VLA caller, not just `secret`).
- **Uncaught-error banner (AOT-ERRBANNER-001)** -- a compiled program prints
  `<progname>: <message>` followed by a stack traceback, the same shape the
  reference interpreter uses; the name token is the exe's own basename, which is
  correct (a standalone program is not the compiler).
- **Debug-reflection soundness (AOT-DEBUGREFLECT-001)** -- at `-O1` the
  proof-producing type inference is disabled for any module that materializes
  the global environment as a value (`_ENV[expr]`, `_G[k]`, `pairs(_G)`),
  closing the path by which a dynamically fetched `debug.setlocal` could falsify
  a static type proof. Plain global reads and local table indexing are
  unaffected, so ordinary hot loops keep their proofs.

### Changed

- **`pool` and `thread` compile under AOT.** Both previously referenced
  `string.dump`/`load` to ship a worker function to another lua_State -- a
  closed-world violation that made any program requiring them fail to compile.
  Real OS threading was never wired up (the native bootstrap does not exist), so
  both now run their actual behavior -- cooperative for `thread`, inline for
  `pool` -- without the dead bytecode round-trip. Native OS threads remain a
  documented future step (resolve the worker through its compile-time
  function-id and bring the worker state up from the proto registry).
- **Version tracking.** `clua/src/common/version.h` is the single source of
  truth; `clua version` reads it, the release zip derives its name from it, and
  `tools/bump-version.ps1` is the only thing that moves it.

### clua

- **The built-in linker is now the DEFAULT -- gcc is optional.** `clua build`
  links with its own COFF->PE64 linker (`LcPe_Link`) whenever the CRT sysroot
  ships next to the runtime archives (`lib\sysroot`, built into every dist and
  the repo `build\bin\sysroot`), so a fresh install needs NO MinGW gcc. The
  resolution order is: `--ld=gcc`/`--ld=internal` flag -> `CLUA_LD=gcc|internal`
  -> default internal-when-sysroot-present, falling back to gcc with a one-line
  note if the sysroot is absent (a bare repo that hasn't run `make sysroot`).
  gcc stays a fully-supported fallback (`--ld=gcc`) and is still used for
  `--shared-rt` and the cold-tree `aot_entry.c` compile. `rover.exe` is now
  itself built via the internal default. `build-luac.bat` builds the sysroot
  before `rover`. The whole suite passes under the new default (499/0).

- **`--gc-sections` in the built-in linker -- size parity with gcc.** `LcPe_Link`
  now sweeps unreachable function/data sections before RVA assignment, exactly
  like ld's `--gc-sections` (the runtime/Lua archives are `-ffunction-sections`,
  Lua also `-fdata-sections`). Mark/sweep over the contribution graph: roots are
  the user object, the entry/force-undef/`_tls_used` anchors, and the KEEP-by-name
  sections the loader/CRT walk rather than relocate (`.ctors`/`.dtors`, `.CRT`
  init arrays, `.tls`, `.pdata`/`.xdata`, the pseudo-reloc list); a section goes
  live when a live section relocates into it (fixpoint). Two ld-fidelity fixes
  the sweep required: a weak UNDEFINED reference no longer drives archive
  extraction (so an FFI-free program leaves the whole FFI cluster unpulled
  instead of dragging it in via `aot_entry`'s weak `Clua_OpenFfi` call; `-u`
  roots still force the pull), and a weak symbol with no real definition now
  resolves to a genuine absolute 0 (NULL) -- ADDR64/ADDR32 to it write the bare
  value with no `image_base` and no base reloc, so `&weak_undef == NULL`. A
  hello exe is 180,736 B (internal) vs 181,248 B (gcc); section sizes match to
  within tens of bytes. Escape hatch: `--no-gc-sections-internal`.

- **Built-in COFF->PE64 linker -- no external toolchain.** A new
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
  `__set_app_type`->`_set_app_type` resolve), the TLS data directory from
  `_tls_used`, base relocations (DIR64), and `__ImageBase`. The mixed `libucrt.a`
  (import stubs for a dozen `api-ms-win-crt-*.dll` plus real objects like
  `ucrt_fprintf.o`) is handled by per-member classification + a normalized
  head-symbol->DLL map. Sysroot snapshot via `make -f build/Makefile.luac
  sysroot` -> `build/bin/sysroot` and `dist/lib/sysroot`, discovered relocatably
  next to the runtime archives. Link time drops from ~132 ms to ~76 ms (no gcc
  subprocess). Validated by `tests/unit/test_lc_pe_emit.c` and a `--ld=internal`
  section in `tools/test-clua-cli.lua`. (Landed opt-in behind `--ld=internal`;
  see the two entries above for `--gc-sections` and the default flip that made
  it gcc-free out of the box.)

- **Atomics work in compiled programs (ATOMIC-INTERLOCKED-SYMS-001).** x64
  `Interlocked*` are compiler intrinsics with no exported symbol;
  `clua/src/ffi/ffi_atomics.c` supplies built-in machine-code thunks (GCC
  `__atomic` SEQ_CST builtins -> LOCK-prefixed x64 forms) and the FFI symbol
  resolver binds `ffi.C.Interlocked*` to them. The whole concurrency cluster
  (`atomic`, `queue`, `semaphore`, `event`, `mutex`, `channel`) now compiles
  AOT and matches the interpreter byte-for-byte -- pinned by
  `tests/differential/aot_concurrency.lua` at O0+O1. (`pool` and `thread` now
  compile AOT too -- see the 0.2.0-beta.1 "Changed" notes above.)

- **No JIT: CLua is purely AOT.** The only execution engines are compiled
  native exes and the reference bytecode interpreter (`clua-interp.exe`, the
  differential oracle -- `-i` is a no-op; clua-interp always interprets).
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
  register window -- `cd ~= nil` as a call argument overwrote the callee
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
  hello-world from ~186 KB to ~30 KB -- for workspaces with many small tools,
  the runtime ships once instead of per-exe. The exe needs `clua-rt.dll`
  beside it (or on PATH) at run time. Composition mirrors a static exe's
  link: no Lua front-end (the closed-world stubs moved to
  `clua/src/runtime/closed_world_stubs.c`, textually included by
  `aot_entry.c` so static links are unchanged, and compiled standalone into
  the DLL), no legacy blob-boot objects, and the FULL interpreter (debug-using
  programs share the same DLL, so `lvm_nointerp` does not apply).
  `protoinit_rt.o` links into each exe (it reads `luac_protoblob`/
  `luac_fn_table` from the user object -- a DLL cannot import from its host).
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
  `%LOCALAPPDATA%\clua\registry` -- directories nothing populated.)
- **Foreign packages (Go-style)**: `rover install` and `rover add` accept
  `https://github.com/<owner>/<repo>` (optional `.git` / trailing slash) and
  the shorthand `github.com/<owner>/<repo>`. The repo is fetched as a
  codeload tarball (branch `main`, falling back to `master`) with the same
  external tools rover already uses (curl + the tar.exe shipped with
  Windows 10+), must carry an `init.lua` at its root (or a `package.lua`
  declaring `entry = "<relative file>"`), and installs flat into the store
  under the lower-cased repo name (allowlist-validated). The `.meta`
  manifest -- and `rover.lock` via `add` -- records
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

## v0.1.0 -- 2026-06-12

The first release of **CLua**, an ahead-of-time compiler for the Lua 5.4
language targeting Windows x64, and **rover**, its package manager.

### The toolchain

- **`clua.exe`** -- `clua build app.lua` -> `app.exe` (`-O1` default),
  `clua run app.lua -- args`, `clua check`, `clua version`. Relocatable:
  finds its runtime libraries next to the executable or via `CLUA_HOME`;
  works from any directory. Intermediates go to `%TEMP%` and are cleaned.
- **`rover.exe`** -- `init` / `add` / `install` / `update` / `remove` /
  `publish` / `verify` / `list` / `search`, with `rover.toml`/`rover.lock`
  project files, lockfile-reproducible installs, whole-tree Merkle
  integrity, semver ranges, and HMAC-signed remote registries. rover is
  itself a CLua-compiled closed-world program.
- The loop works end to end: `rover install <pkg>` -> `require "<pkg>"` ->
  `clua build` bundles the installed package into the exe.

### The compiled output

- Ordinary PE: native x64 code, standard sections -- no bytecode blob, no
  in-binary VM, no JIT. A hello-world is ~177 KB, fully static.
- Emitted exes link a dedicated AOT runtime: no JIT compiler, no Lua
  front-end (`load`-family symbols are closed-world stubs), no FFI, no
  winpthread, and -- for programs that never mention `debug` -- no bytecode
  interpreter. Programs that use the debug library keep the interpreter and
  match the reference interpreter under `debug.sethook` exactly.
- The optimizer (`-O1`): static int/float type inference with tag-check
  elision, bare integer FORLOOP, loop-region register residency (R12-R15/RSI
  + xmm6-xmm10), interprocedural type propagation. Tight integer loops run
  ~17x the faithful boxed baseline. Soundness was adversarially validated
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
  final native link -- the one external step (a self-contained PE writer is
  planned).
- The ~195 in-tree builtin packages (`json`, `hash`, ...) do not yet bundle
  into compiled exes -- requiring one is a loud compile error
  (rover-installed packages work). Planned (M4) alongside FFI-in-exes.
- Uncaught runtime errors print `clua: runtime error: <msg>` without a
  stack traceback (AOT-ERRBANNER-001); the message itself matches the
  reference interpreter.
