# CLua (LuaC) — working notes

> **This is CLua, the standalone AOT-compiled Lua 5.4 language** (separated
> from LuaVM, the JIT-based v1, in June 2026 — v1 lives in its own repository
> and is no longer related to this codebase except as history). Read
> [`README.md`](README.md) for status and [`PROMPT.md`](PROMPT.md) for the
> build spec (mission, locked decisions, IR, optimizer, codegen, PE emission,
> FFI rules, testing, milestones). The file-level inheritance record is
> [`docs/fork-manifest.md`](docs/fork-manifest.md).
>
> **The product is `clua.exe`** (subcommands `build`/`run`/`check`/`version`,
> `-O1` default, output name derived from the input; relocatable — finds its
> runtime libs next to the exe or via `CLUA_HOME`), plus **`rover.exe`**, the
> package manager, itself a CLua-compiled closed-world program built from
> `package-manager/src/rover.lua` (project files: `rover.toml`/`rover.lock`;
> env: `ROVER_REGISTRY`/`ROVER_REGISTRY_KEY`; store under `CLUA_HOME` or
> `%LOCALAPPDATA%\clua`). `aotc.exe` is the low-level flag-compatible driver
> the test layers use; both share `lc_drive()`.
> CLua compiles Lua 5.4 to **native x64 machine code at compile time** and
> emits an ordinary PE (standard sections, no bytecode blob, no in-binary VM,
> no JIT). The pipeline is in-memory: ProtoInit data rides as a serialized
> blob (`.rdata$L`; format in `src/runtime/protoblob_format.h`, rebuilt at
> startup by `src/runtime/protoinit_rt.c`) inside the single COFF object, so
> the only external step is ONE native link against `runtime-aot.a` (the
> AOT runtime variant: dispatch cache but **no JIT compiler**) + the Lua
> core (**no front-end** — `aot_entry.c` stubs `luaY_parser`/`luaU_undump`/
> `luaU_dump`/`luaX_init`; see AOT-CLOSEDWORLD-002 — and **no bytecode
> interpreter** for programs that never mention `debug`: `lvm_nointerp.o`
> replaces lvm.o via the `lc_module_uses_debug` scan, AOT-NODEBUG-001; the
> native-dispatch entry is `clua_dispatch_hook` in the patched lvm.c).
> The runtime
> (GC/tables/strings/metatables/coroutines/FFI) is a statically-linked
> *library*, like libc. The backend lives in `src/{ir,opt,codegen,link,driver}`.
> **Closed world:** `load`/`loadstring`/`dofile`/`string.dump`/dynamic
> `require` are compile errors. **Fidelity:** the compiled program must match
> the embedded reference interpreter (`luavm.exe -i`) exactly — the
> differential test is the arbiter.
>
> **The v1 interpreter + JIT inside this repo are TEST ORACLE infrastructure,
> not the product.** `luavm.exe -i` is the frozen fidelity reference — never
> edit interpreter semantics to make a diff pass. The v1 JIT (also inside
> `src/jit/`) is slated for removal once the behavioral test layers run
> against compiled exes; the `Rt_*` helpers in `src/jit/runtime.c` are NOT
> JIT code — they are the shared runtime library the AOT codegen links.

---

## Oracle / build-machinery notes (inherited from v1)

`luavm.exe` runs a script (JIT by default, `-i` = the reference interpreter).
`compiler.exe` is v1's bytecode-embedding front-end (kept for the package
test layer). The compiler statically scans `require "literal"` to bundle
packages (or `-L <pkg>` to force-bundle).

## Build

From PowerShell (authoritative): `cmd /c "build\build-luac.bat"` builds
everything: `clua.exe`, `aotc.exe`, `aot_entry.o`, `rover.exe` (via
`build/Makefile.luac`) plus the base products and the three runtime archives
(`runtime-embedded.a`, `runtime-aot.a`, `liblua54-embedded.a`). The v1
targets remain available via `cmd /c "build\build.bat <target>"`: `compiler`,
`luavm`, `embedded`, `packages-embedded`, `lua`, `clean`. `build.bat` puts
GnuWin32 `make` + the MinGW `bin` on PATH, then runs `make -f build/Makefile`.
Do **not** run `make` directly from bash (the package-discovery `$_` PowerShell
gotcha prints harmless `'x86' is not recognized` noise). The user-facing
layout: `make -f build/Makefile.luac dist` → `dist\` (clua.exe + rover.exe +
lib\ + README).

**Gotcha:** changes to `src/ir/ir.h` (or any backend header, e.g.
`src/codegen/codegen.h`) require wiping the backend objects first
(`build/bin/obj/{ir,opt,codegen,link,driver}`) — the Makefile does not track
header dependencies, and stale `lift.o` produces silent empty-output binaries.

**Gotcha:** `src/runtime/aot_entry.c` is precompiled to `build/bin/aot_entry.o`
by Makefile.luac (target `aot-entry`); the linker prefers that object and only
falls back to compiling the source in a cold tree. After editing aot_entry.c,
rebuild via `build-luac.bat` (the Makefile dep handles it) — a stale .o links
old startup code into every emitted PE.

## Testing discipline — READ THIS

**When you add or change a feature, function, or system, add or update a test in
the matching `tests/` layer, then run the full suite before calling it done.**

```
build\run-tests.bat
```

builds the products and runs **every** test plus the behavioral suites, printing
one tally: `[PASS] n  [FAIL] n  [SKIP] n  [XFAIL] n  [XPASS] n`. Exit non-zero on
any real failure. (If products are already built: `build\bin\luavm.exe tools\run-tests.lua`.)

Tests are **auto-discovered** — the Makefile and runner never name an individual
test file. **Just drop a file in the right folder**; deleting one breaks nothing.

| Layer | Folder | What it is | How to add one |
|---|---|---|---|
| C unit | `tests/unit/test_*.c` | internals (FFI/JIT/compiler) | standalone C program using `tests/unit/test_harness.h` (`TEST_BEGIN`/`CHECK*`/`TEST_END`); links against the auto-built `libcluatest.a` |
| Lua behavioral | `tests/lua/*.lua` | language/runtime behavior under the JIT | assert with a local helper; `print("[+] PASS <name>")` + `os.exit(0)`, or `os.exit(1)` on failure |
| Package | `tests/packages/test_*.lua` | a builtin package round-trip | `require` the package + assert; the runner compiles it with `compiler.exe` then runs it. Absent external DLL → `print("[~] SKIP …") os.exit(0)` |
| Differential | `tests/differential/*.lua` | JIT-vs-interpreter equivalence | a deterministic script that *prints*; the runner runs it under JIT and `-i` and diffs stdout (catches silent JIT miscompiles) |

Templates to copy: `tests/unit/test_ctype.c`, `tests/lua/test_basics.lua`,
`tests/packages/test_json.lua`, `tests/differential/closures.lua`.

### Known bugs — don't hide them, XFAIL them

A test must assert **correct** behavior. If a test would catch a *known,
unfixed* bug, do **not** work around it to go green — mark it XFAIL so it stays
visible and turns XPASS (telling us to remove the marker) when the bug is fixed:

```lua
local function xfail(cond, desc, bug)
  if cond then print(("[!] XPASS <name>: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
  else        print(("[x] XFAIL <name>: %s (known bug %s)"):format(desc, bug)) end
end
```

The runner counts `[x] XFAIL` and `[!] XPASS` lines separately; XFAIL does not
fail the run, XPASS is flagged for cleanup. Current known bugs (with repros) are
in `docs/known-bugs-2026-06-07.md`. The design of the test system is in
`docs/test-system-design-2026-06-07.md`.
