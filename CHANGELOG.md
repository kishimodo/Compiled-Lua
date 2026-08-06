# CLua changelog

All notable changes are recorded here. The format follows Keep a Changelog and
the project uses semantic versioning. `clua version` reports the current string;
it is rewritten only by `tools/bump-version.ps1`, which keeps the single source
of truth -- `clua/src/common/version.h` -- and this file in step.

## [Unreleased]

### Changed

- **Compile time roughly halved.** The internal linker now indexes each archive's
  symbol map and member table (lazily built, per archive) instead of walking them
  linearly. A Rover build resolved 25,114 archive queries with **41 million string
  compares**; that is now 21,537. Warm `-O1` medians: Rover 187 -> 86 ms,
  `print("hello")` 153 -> 73 ms, and the win is a fixed per-link saving so a
  three-line program benefits as much as Rover. Output is byte-identical.
- **Emitted binaries about 9% smaller.** Helper-call arguments are loaded as
  32-bit immediates (`xor`/`mov r32,imm32`/sign-extending `mov r64,imm32` chosen by
  the value's sign) rather than 64-bit ones. Two figures, because they answer
  different questions and must not be spliced: the change *itself* saves **73,216
  bytes of Rover's `.text` (-12.0%)**, measured against a fixed source in a
  single-tree A/B; across the whole release the **net** `.text` saving is **69,248
  bytes (-11.4%)**, and whole-file Rover `-O1` falls 739,328 -> 670,720 (-9.28%).
  The 3,968-byte difference is not a regression: Rover's own source grew by about
  50 lines in the same period (the `tar` pin), so part of the codegen win is spent
  carrying new code. Unconditional at every `-O` level, because it is not a
  size/speed tradeoff. `print("hello")` does not change at all: its 137,216 bytes
  are runtime and CRT, so the win scales with user code volume, not with the
  compiler.
- **Runtime speed of generated code is unchanged**, measured and stated rather
  than assumed (`docs/benchmarks/session-2026-07-25-ab.md`). Neither change
  targeted runtime.
- **`-O` levels are now honest.** `-Ofast`, `-Os`, `-Oz`, `-O9` and `-O-1` were
  silently accepted and mapped to `-O0` or "everything"; they are now rejected with
  a message and a nonzero exit. `clua help` states per level what actually runs,
  including plainly that **`-O2` emits the same bytes as `-O1`** because the three
  passes it gates are unimplemented.

### Added

- Header dependency tracking (`-MMD -MP`) in both makefiles, retiring the
  documented "wipe `build/bin/obj` before editing a header" step -- a trap that
  could make a stale object produce a silently empty binary. This exposed that
  342 of 618 objects, including the whole Lua core and the runtime archives, had
  been stale; a full rebuild changed every emitted binary. Also adds
  `make -f build/Makefile clean-objs`.
- The optimizer's IR verifier is implemented and actually invoked.
  `lc_module_verify` previously returned `true` unconditionally while
  `LcPassConfig.verify_each` was set by the driver and never read. It now runs
  after each mutating pass group and unconditionally before codegen at every `-O`
  level.
- Archive-resolution accounting under `CLUA_GC_DEBUG`, reported per link.
- Benchmark harnesses: `tools/bench-runtime.lua`, `check-byte-identity.py`,
  `count-imm-sites.py`, `bench-armap.c`.
- Shared agent workspace: reviews, roadmaps, benchmarks and handoffs live in
  `docs/` with paths derived from Git at run time (`tools/agent-coordination/`).

### Fixed

- **Rover pins `%SystemRoot%\System32\tar.exe`** instead of resolving `tar` from
  `PATH`. A GNU tar earlier on `PATH` read the absolute archive argument as its
  `hostname:file` remote syntax and failed the install. It also refuses to extract
  at all when `$SystemRoot` carries shell metacharacters, rather than falling back
  to a less trusted extractor for an untrusted archive.
- Code generation keeps no mutable file-scope state (six objects -> zero), which
  unblocks per-function parallel codegen. Emitted output is byte-identical.
- **`windows.ToWide`/`FromWide` failed on any string longer than their fixed
  scratch buffers** (2048 WCHARs / 4096 bytes): `MultiByteToWideChar` /
  `WideCharToMultiByte` return 0 on insufficient buffer, which these helpers raise
  as "conversion failed". Both now ask the API for the required size and convert
  into an exactly sized buffer -- the standard Win32 two-call idiom, which also
  allocates *less* than before for short strings. Windows allows 32,767 characters
  per environment variable, so no fixed size was ever correct. A source comment
  claimed the sizing call had to be avoided because it desynchronised the FFI
  marshaller; that note blamed "the JIT codegen path" and is stale (there is no
  JIT in the tree), and the same idiom was already in production in
  `dotnet/init.lua`. Re-tested directly with a 6,000-character round trip.
  Found because `test_env` failed only under `build\run-tests.bat`, whose
  prepended toolchain directories push this machine's `PATH` to 4,218 bytes so the
  `PATH=...` entry overflowed by 127 bytes; under a plain shell the same `PATH` is
  4,084 bytes and every run passed, which is why this looked environment-dependent
  rather than broken. `tests/packages/test_env.lua` now builds 2,100/4,200/6,000-
  character values itself, so coverage no longer depends on the ambient `PATH`
  length -- verified to fail against the old implementation in both helpers.

### Internal

- `docs/roadmaps/concurrency-size-stability.md` tracks per-deliverable status;
  `docs/benchmarks/` records every measurement with its method, including one
  **negative** result (unrooting `.pdata`/`.xdata` frees 128 bytes of `.text`, so
  the resurrection hypothesis is refuted and the idea should not be re-proposed).
- `docs/roadmaps/no-crt.md` plans CRT-free output (`--crt=none`), with the measured
  dependency surface in `docs/benchmarks/no-crt-baseline.md`: of 552 external
  symbols, **100** are a genuine libc dependency (93 UCRT imports plus 7 static
  mingw). Two findings shape the plan -- `libmingwex.a` provides none of the
  transcendentals, so an own libm is unavoidable and the oracle must be rebuilt
  against the same libc; and the Lua core already avoids CRT `setjmp` via
  `__builtin_setjmp`. Recorded up front: the CRT is **already** outside our
  binaries (they import `api-ms-win-crt-*`), so `--crt=none` is a
  self-containment and determinism feature and a net **size increase** -- the size
  lever is `-ffunction-sections` on the runtime instead.
- `docs/handoff/2026-07-26-ultracode-prompt.md` holds the kickoff prompt for the
  platform + no-CRT arc, delegating detail to the roadmaps so it cannot go stale.

## [0.2.0-beta.6] - 2026-06-13

### Added

- **`-O3` escape analysis + scalar replacement (slice 1).** The first M3 memory
  pass with real measured surface. A `NEWTABLE` whose home register never
  escapes its function and is touched only by constant-key field ops
  (`t.x` / `t[1]`) -- and whose live range holds no GC safepoint -- is replaced
  by plain stack slots instead of a heap table (`lc_pass_scalar_replace`,
  `clua/src/opt/passes.c`). The per-iteration heap allocation and the
  `Rt_GetField`/`Rt_SetField` helper calls vanish: **~38x on an alloc-heavy
  struct-in-loop** (`struct_loop` 5.7s -> 0.149s at n=2e7), every result
  byte-identical to the interpreter. The rewrite reuses existing opcodes
  (`MOVE`/`LOADK`/`LOADNIL`), so codegen is unchanged and the differential oracle
  covers every emitted byte. Soundness keystone: a non-escaping fresh table can
  never gain a metatable (`setmetatable` is a call = an escape), so constant-key
  raw get/set is exactly one scalar slot per key.

  Validated at O0+O1+O2+O3 (suite 655/0) plus an adversarial attack round
  (~300 repros across escape / aliasing / closure-capture / metatable / shape /
  nil-keys / register-reuse / control-flow / GC); it found one real O3-only
  miscompile -- a backward `goto` re-reading a field after a GC whose pc was
  textually past the last read, clobbering the reserved above-`L->top` slot --
  now fixed (the live-range check follows back-edges) and pinned by
  `tests/differential/aot_scalar_replace.lua`. Benchmark harness:
  `tools/bench-optimizer.lua`.

  **Honest scope:** the win is large but the firing window is narrow -- it fires
  0/86 candidates in rover and 0/182 in the conformance corpus, because real
  Lua tables escape, are called-around, or interleave field reads with
  arithmetic (any of which puts a GC safepoint in the live range, which must
  bail). This is the proven mechanism; broad real-code surface is slice 2
  (GC-safe slot placement + interprocedural escape). It is default-on at `-O3`
  only -- the `clua` default is `-O2`, so default builds are unaffected -- and
  costs nothing when it does not fire.

## [0.2.0-beta.5] - 2026-06-13

### Changed

- **`clua build` now defaults to `-O2` (whole-program optimization).** The
  default optimization level moves from `-O1` to `-O2`, matching the release
  convention of a C compiler. `-O1` ran only the M1 local passes (local type
  inference, arith specialization, local unboxing/devirtualization, small-call
  inlining); `-O2` additionally runs the M2 *interprocedural* passes across the
  whole closed-world program -- monomorphization, interprocedural
  devirtualization, and dead-global elimination. A closed-world AOT compiler
  sees the entire program, so whole-program optimization is sound and is exactly
  where CLua should sit by default. `-O0` and `-O1` remain available, and `-O3`
  (the M3 memory passes -- escape analysis, scalar replacement, GC-barrier
  elision) stays opt-in for callers who want maximum. `aotc` (the low-level
  driver) keeps its `-O0` default; only the user-facing `clua` default moved.

### Added

- **The differential + conformance oracle now runs at every selectable `-O`
  level (`O0+O1+O2+O3`), not just `O0+O1`.** Every compiled differential and
  conformance test must now match the reference interpreter byte-for-byte at all
  four levels, so an optimizer or codegen divergence at `-O2` or `-O3` is a hard
  suite failure rather than an unvalidated blind spot. This is what makes the
  `-O2` default safe to ship -- and it permanently gates `-O3` too. The change
  added 146 compiled-vs-interpreter checks (505 -> 651), all green.

## [0.2.0-beta.4] - 2026-06-13

### Changed

- **Smaller exes: unenforced CET instrumentation is no longer emitted.** The
  runtime and Lua core were compiled with `-fcf-protection=full`, which makes
  GCC plant an `endbr64` landing pad at the head of every function (plus a
  `.note.gnu.property` marker). Those pads are only ever checked when the PE
  load-config advertises CET -- and CLua's load-config is empty, so they were
  never enforced: pure dead weight. Switching the shipped runtime + core to
  `-fcf-protection=none` strips ~283 pads from a `print` hello-world (298 -> 15)
  and ~497 from rover (514 -> 17); the residual handful live in MinGW's
  prebuilt CRT startup objects, which we link verbatim. hello drops 139 KB ->
  137 KB, rover 689 KB -> 687 KB. `-fstack-protector-strong` stays -- it is
  real, near-free stack-smash protection. This was the one remaining non-pulling
  flag: the size/optimizer set was already the C/Rust release shape (`-Os`,
  `--gc-sections` with `-ffunction-sections`/`-fdata-sections`,
  `-fno-(asynchronous-)unwind-tables`, `-fmerge-all-constants`, `-s` strip).

### Fixed

- `rover.exe` now lists `runtime-aot.a` as a make prerequisite, so a
  runtime/core rebuild (e.g. a CFLAGS change) relinks rover -- previously a
  stale rover could ship linked against the old runtime.

## [0.2.0-beta.3] - 2026-06-13

### Changed

- **Leaner exes: the standard library is opened selectively, and the dispatch
  cache is right-sized.** Two size wins with no capability or behavior change --
  a `print` hello-world drops from 189 KB / 77 KB .bss to 139 KB / 3 KB .bss.
  - `luaL_openlibs` opened the WHOLE stdlib unconditionally, forcing every
    `luaopen_*` (and its archive member -- `lstrlib.o` alone is 16 KB) into the
    exe even for a program that uses none of them. The AOT entry now opens base
    + package + coroutine always, and each optional library (string / table /
    math / io / os / utf8 / debug) only when a compile-time scan
    (`lc_module_used_libs`, opt/passes.c) sees the program reference it -- via
    weak anchors (runtime/stdlib_anchors.c) that the driver force-undefs, so
    `--gc-sections` drops the rest. string is special (it backs the string
    metatable): it is kept whenever the program indexes a value or does
    metamethod arithmetic (the `"10" + 1` coercion path), so it matches the
    reference interpreter exactly. A hello-world sheds ~41 KB of .text. Works on
    the internal linker, gcc, and `--shared-rt`.
  - The dispatch cache was a fixed 1024-entry static array -- ~72 KB of .bss per
    exe, plus a hard 1024-function ceiling. It is now a heap array grown
    geometrically and sized to the program, so a small program reserves a few
    hundred bytes and the function ceiling is gone. Per-worker-thread caches
    (native threads) grow the same way.

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
