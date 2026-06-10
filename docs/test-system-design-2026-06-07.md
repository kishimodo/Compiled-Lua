# LuaVM Test System — Design (2026-06-07)

Status: approved, implementing. Supersedes the deleted `tests/` tree and the
~50 hand-written C-unit Makefile rules (which broke the build the moment a file
went missing). Replaces them with an **auto-discovering, single-command** suite
where adding or deleting a test can never break the build.

## Goal

1. Recreate full test coverage (FFI / JIT / compiler internals + Lua-level
   behavior), written **fresh** (not restored from git history).
2. Establish a repeatable workflow: change a feature/function/system → drop a
   matching test file in → run one command → get an accurate pass/fail tally.
3. Robustness by construction: the build/Makefile never references an individual
   test file, so a missing/added test is a non-event.

## Layout (everything auto-discovered by glob)

```
tests/
  unit/          test_*.c     C unit tests for internals (link against the core archive)
  unit/test_harness.h         shared ASSERT/CHECK macros + PASS/FAIL reporting
  lua/           *.lua        behavioral: run under luavm.exe, assert, exit non-zero on fail
  packages/      test_*.lua   per-package require + round-trip (compiled with compiler.exe)
  differential/  *.lua        same script under JIT and -i; stdout must be identical
```

## Mechanism — the runner does everything; the Makefile is untouched for tests

`tools/run-tests.lua` (executed by `luavm.exe`) is the universal runner:

1. **Core archive.** Globs `build/bin/obj/{ffi,jit,compiler,runtime}/*.o`,
   **excluding** the two objects that define `main` (`compiler/main.o`,
   `runtime/luavm_main.o`), and runs `ar rcs build/bin/libluavmtest.a <objs>`.
   (Archive members are only pulled in when a test references their symbols, so
   this is safe and per-test link lists are unnecessary.)
2. **C unit tests.** Globs `tests/unit/test_*.c`; for each, runs
   `gcc <CFLAGS> -Itests/unit -o build/bin/tests/<name>.exe <test.c>
   build/bin/libluavmtest.a build/bin/liblua54.a -lm -lkernel32 …`, then runs the
   exe. CFLAGS mirror the Makefile: `-std=c99 -Wall -Wextra -Wno-unused-parameter
   -O2 -g -I src -I lua-5.4/src -I build/gen -DLUAVM_TARGET_WINDOWS_X64=1`.
3. **Lua behavioral.** Globs `tests/lua/*.lua`; runs each under `luavm.exe`.
   Pass = exit 0 and no `FAIL` line.
4. **Package tests.** Globs `tests/packages/test_*.lua`; compiles each with
   `compiler.exe` (guarantees the package is bundled) and runs the exe. A package
   whose external DLL is absent **skips with a reason** (counts as skip, not fail).
5. **Differential.** Globs `tests/differential/*.lua`; runs each under `luavm.exe`
   (JIT) and `luavm.exe -i` (interpreter) and diffs stdout. Mismatch = fail.
6. **Fold in existing suites.** The self-contained `tools/` suites (diagnostics,
   force-link, pkgmgr ×5) are invoked too.
7. **Tally.** Prints `[PASS] N  [FAIL] M  [SKIP] K (…s)` and exits non-zero if any
   fail. Each phase prints `[+] PASS <name>` / `[-] FAIL <name>` lines.

Because all discovery/compile/run logic lives in `run-tests.lua`, the Makefile
keeps building only products. The dead C-unit rules (referencing the removed
`tests/`) are deleted from the Makefile as part of this change.

## One command

`build\run-tests.bat`: sets up the MinGW/make PATH (reuses `build.bat`'s logic),
builds products (`compiler`, `luavm`, `packages-embedded`), then runs
`luavm.exe tools\run-tests.lua`. Shell-agnostic (runner is Lua, not make), so no
`$_`/bash hazard. Returns the runner's exit code.

## C unit test contract

Each `tests/unit/test_*.c` is a standalone program:

```c
#include "test_harness.h"
#include "ffi/ctype.h"   /* or whatever it exercises */

int main(void) {
    TEST_BEGIN("ctype_primitives");
    CHECK(Ctype_Lookup("int") != NULL);
    CHECK_EQ_INT(Ctype_Lookup("int")->Size, 4);
    TEST_END();   /* prints [+] PASS / [-] FAIL <name>, returns 0/1 */
}
```

`test_harness.h` provides: `TEST_BEGIN(name)`, `CHECK(cond)`, `CHECK_EQ_INT(a,b)`,
`CHECK_EQ_STR(a,b)`, `CHECK_NEQ`, `TEST_END()` — counting failures and reporting
the located first failure.

## Lua test contract

`tests/lua/*.lua` and `tests/packages/test_*.lua` use a tiny convention: call a
local `assert`-style helper and `print("[-] FAIL <name>: …"); os.exit(1)` on
failure; `print("[+] PASS <name>")` at the end. (A shared `tests/lua/_assert.lua`
is provided and bundled via `require` where helpful, or inlined for package
tests that must compile standalone.)

## Coverage (written fresh)

- **C unit:** cdecl_lexer, cdecl_parser, ctype, cdata (+ metamethods, field
  access, borrowed), marshal (primitives/strings/cdata/return), ffi_lib (cast
  string/wchar, **array arithmetic**), ffi_load, veh (classify/region), emit_x64,
  exec_mem, jit_smoke, **jit_tailcall**, regalloc, paths, blob, blob_reader,
  resolve, diag, win_types, cdef (primitives/struct/union/enum/funcdecl/pointers/
  **storage-fnptr**/errors).
- **Lua behavioral:** Lua 5.4 `<close>`, goto, integer/float subtype + `math.type`,
  bitwise ops + `//`/`%` sign rules, `string.pack`/`unpack`, utf8, coroutines,
  varargs, pcall/error, metatables; ffi-from-Lua basics.
- **differential:** tail-call, pcall, coroutine, vararg, `<close>` programs.
- **packages:** aes (GCM+CBC round-trip), hash (known vectors), json, base64,
  semver, uuid, csv, cbor; plus ffi.gc users that need no external DLL.

## Workflow convention (CLAUDE.md)

A new `CLAUDE.md` "Testing discipline" section: when you add or change a feature,
function, or system, add/adjust a test in the matching `tests/` layer and run
`build\run-tests.bat` before calling it done. Auto-discovery means you just drop a
file in — no wiring. Documents the four test types + the one command.

## Acceptance criteria

1. `build\run-tests.bat` builds products, auto-discovers and runs every test,
   and prints a single `[PASS]/[FAIL]/[SKIP]` tally; exit non-zero on any fail.
2. Adding `tests/unit/test_new.c` (or any `tests/**` file) makes it run with **no**
   Makefile/runner edit; deleting any test file breaks nothing.
3. The fresh coverage above is green (packages needing absent DLLs skip-with-reason).
4. The Makefile no longer references any `tests/` file; products still build.

## Risks / open questions (resolve during build)

- **Host package availability:** `luavm.exe` may not preload all 224 packages for
  `tests/lua`/`tests/packages` run directly; package tests therefore compile via
  `compiler.exe` (which bundles). Behavioral `tests/lua` use only core Lua + ffi.
- **Link libs:** start with `-lm -lkernel32`; add `-lbcrypt`/`-lws2_32`/`-lntdll`
  etc. if a unit test pulls an object that needs them (discovered at validate time).
- **Archive `main` collision:** excluded by name; verify no other object defines a
  conflicting global.
- **ar/gcc on PATH:** `run-tests.bat` sets the MinGW PATH before invoking the runner.
