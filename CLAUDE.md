# LuaC (LuaVM 2.0) — working notes

> **This is LuaC, the AOT fork. Read [`PROMPT.md`](PROMPT.md) first** — it is the
> build spec & implementation prompt (mission, locked decisions, IR, optimizer,
> codegen, PE emission, FFI rules, testing, milestones). The grounded file-level
> fork manifest is [`docs/fork-manifest.md`](docs/fork-manifest.md).
>
> **What's different from v1:** LuaC compiles Lua 5.4 to **native x64 machine code
> at compile time** and emits an ordinary PE (standard sections, no bytecode blob,
> no in-binary VM). The runtime (GC/tables/strings/metatables/coroutines/FFI) is a
> statically-linked *library*, like libc. The new backend lives in
> `src/{ir,opt,codegen,link,driver}`; the front-end, runtime core, and FFI are
> reused from v1 verbatim. **Closed world:** `load`/`loadstring`/`dofile`/
> `string.dump`/dynamic `require` are compile errors. **Fidelity:** the compiled
> program must match v1's `luavm.exe -i` interpreter output exactly — the
> differential test is the arbiter.
>
> The notes below are inherited from v1 and still describe the reused build/test
> machinery and discipline. The AOT driver is `aotc.exe` (see `src/driver/`); it
> builds via `build/Makefile.luac` once the backend exists.

---

## v1 inherited notes

LuaVM compiles Lua 5.4 into a standalone Windows x64 PE (an x64 JIT + a custom
Windows FFI). `compiler.exe` bakes a standalone exe; `luavm.exe` runs a script
(JIT by default, `-i` = bytecode interpreter). The compiler statically scans
`require "literal"` to bundle packages (or `-L <pkg>` to force-bundle).

## Build

From PowerShell (authoritative): `cmd /c "build\build.bat <target>"`. Targets:
`compiler`, `luavm`, `embedded`, `packages-embedded`, `lua`, `clean`. `build.bat`
puts GnuWin32 `make` + the MinGW `bin` on PATH, then runs `make -f build/Makefile`.
Do **not** run `make` directly from bash (the package-discovery `$_` PowerShell
gotcha prints harmless `'x86' is not recognized` noise).

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
| C unit | `tests/unit/test_*.c` | internals (FFI/JIT/compiler) | standalone C program using `tests/unit/test_harness.h` (`TEST_BEGIN`/`CHECK*`/`TEST_END`); links against the auto-built `libluavmtest.a` |
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
