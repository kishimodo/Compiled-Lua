# Roadmap: shipping binaries with no CRT (`--crt=none`)

Status: **planned, not started.** Measured on `codex/concurrency-size-stability`
at `7fec28f` + the delivered slice, 2026-07-26, with `nm`/`objdump` from the
project toolchain. Every number below is measured, not estimated; estimates are
labelled as such.

---

## 0. The headline, before anyone gets the wrong idea

**The CRT is already not inside our binaries, and `--crt=none` will make output
bigger, not smaller.**

`hello.exe` imports these 13 DLLs:

```
KERNEL32.dll
api-ms-win-crt-{runtime,stdio,string,heap,private,math,locale,
                time,environment,utility,filesystem,convert}-l1-1-0.dll
```

Those `api-ms-win-crt-*` names are the **UCRT apiset forwarders** — the CRT code
lives in `ucrtbase.dll`, shipped with the OS. We link it dynamically today. So
the 114,736-byte `.text` in `hello.exe` is **our runtime plus the Lua core**, not
CRT. Removing the CRT deletes ~3 KB of import table and adds 15–30 KB of our own
implementations.

If the goal is *smaller binaries*, this is the wrong project — see
[§8](#8-the-actual-size-lever-is-somewhere-else). If the goal is
**self-containment, determinism, and control of the allocator**, this is the
right project and it is tractable. Section 2 states the real payoffs.

---

## 1. The exact dependency surface (measured)

From `nm -u` over `build/bin/runtime-aot.a`, `build/bin/liblua54.a` and
`build/bin/aot_entry.o`, with `__imp_` stripped and deduplicated:

| Bucket | Count | Meaning |
|---|---:|---|
| External symbols referenced | 552 | raw `nm -u` union |
| — resolved within our own archives | 446 | cross-object references, not a dependency |
| — generated per build | 6 | `g_LuaBlob`, `g_LuaBlob_size`, `luac_protoblob`, `luac_fn_table`, `Runtime_GetPackages`, `Native_GetEmbeddedDlls` |
| **Genuine libc dependency** | **100** | what `clua/src/libc/` must provide |
| — of which UCRT DLL imports | 93 | disappear from `.idata` under `--crt=none` |
| — of which **static** mingw code already in `.text` | 7 | `___chkstk_ms` `__main` `__mingw_fprintf` `__mingw_sprintf` `__mingw_strtod` `__stack_chk_fail` `__stack_chk_guard` |

Separately, 45 of the 552 are satisfied by the Win32 import libraries
(`kernel32`/`user32`/`advapi32`/`shell32`) and stay exactly as they are — Win32
is not the CRT and we keep importing it.

Reproduce with `tools/audit-libc-surface.sh` (item **N0** below builds it; the
one-off pipeline that produced this table is recorded in
[`docs/benchmarks/no-crt-baseline.md`](../benchmarks/no-crt-baseline.md)).

### The 100, grouped by implementation difficulty

**Tier 1 — mechanical, no fidelity risk (33)**

- `memcpy memmove memset memcmp memchr` — GCC also *emits calls* to these for
  struct assignment, so they must exist under any mode.
- `strlen strchr strrchr strcmp strncat strncpy strpbrk strspn strstr strcoll`
  — `strcoll` is `strcmp` in the C locale, which is the only locale we support.
- `isalnum isalpha iscntrl isgraph islower ispunct isspace isupper isxdigit
  tolower toupper` — one 256-byte table. Must be **C-locale exact**; that is
  what Lua's lexer and `string.*` assume.
- `___chkstk_ms __main __stack_chk_fail __stack_chk_guard` — `__main` becomes an
  empty function; the stack-protector pair disappears under
  `-fno-stack-protector`; `___chkstk_ms` is ~10 instructions.
- `strerror` — **small but a real fidelity trap.** Lua prints it verbatim from
  `luaL_fileresult`, so `io.open` failure messages are compared by the
  differential suite. The strings must be captured from `ucrtbase` and
  hard-coded, not invented. See [§5](#5-fidelity-traps-ranked).

**Tier 2 — shallow Win32 wrappers (48)**

| Family | Symbols | Backed by |
|---|---|---|
| heap | `malloc calloc realloc free` | `HeapAlloc` family, or our own allocator — see §2.3 |
| stdio | `fopen freopen fclose fread fwrite fseek ftell fflush fgets fputc fputs getc ungetc feof ferror clearerr setvbuf remove rename tmpfile tmpnam __acrt_iob_func` | `CreateFileW`/`ReadFile`/`WriteFile`/`SetFilePointerEx`, plus our own `FILE` and buffering |
| pipes | `_popen _pclose` | `CreatePipe` + `CreateProcessW`. **Rover depends on these** — it shells out through `io.popen` throughout |
| process | `exit abort getenv system _errno _beginthreadex` | `ExitProcess`, `GetEnvironmentVariableW`, `CreateProcessW` on `cmd.exe /c`, a `__declspec(thread)` slot, `CreateThread` |
| time | `_time64 _difftime64 _gmtime64 _localtime64 _mktime64 clock strftime` | `GetSystemTimeAsFileTime`, `FileTimeToSystemTime`, `SystemTimeToTzSpecificLocalTime` |
| locale | `setlocale localeconv` | C locale only, fixed struct. Lua uses it solely for `lua_getlocaledecpoint`; returning `"C"` and `.` is correct **and more deterministic than today** |

Shallow, but 48 functions is the bulk of the typing. No algorithmic risk.

**Tier 3 — the hard three, carrying essentially all the risk (19)**

1. **`snprintf` `vsnprintf` `fprintf` `__mingw_sprintf` `__mingw_fprintf`** —
   integer and string conversion is trivial; **float conversion is not.** Lua's
   `LUAI_NUMFFORMAT` is `"%.14g"`, and `string.format` exposes `%a %e %f %g` at
   arbitrary width and precision. Producing byte-identical output to `ucrtbase`
   for every double requires **correctly-rounded fixed-precision** conversion:
   a big-integer Dragon4/Steele-&-White path, as in David Gay's `dtoa` and musl.
   **Do not reach for Ryū or Grisu** — those compute the *shortest*
   round-tripping representation, which is a different function from `%.14g` and
   will disagree. `%a` is exact and easy.
2. **`strtod` (`__mingw_strtod`)** — correctly-rounded decimal→binary. Used by
   `tonumber`, the lexer, and every `string.format` round-trip. Must handle
   subnormals, exact-halfway ties (round-half-to-even), overflow to infinity,
   Lua 5.4 hex float literals, and whatever `ucrtbase` does with `"inf"`/`"nan"`
   — match the oracle, do not reason from the C standard. Same big-integer
   machinery as (1), reversed.
3. **libm: `sin cos tan asin acos atan2 sinh cosh tanh exp log log10 pow fmod
   frexp ldexp`** — and this is the finding that reshaped the plan:

   > **`libmingwex.a` does not provide any of the transcendentals.** All 15 come
   > from UCRT in this toolchain (verified by `nm --defined-only` over
   > `build/bin/sysroot/libmingwex.a`). There is no free static libm to fall
   > back on.

   `sqrt fmod frexp ldexp` are exact — SSE2 instructions or bit manipulation, no
   risk. The 11 transcendentals **cannot be made bit-identical to `ucrtbase`**
   without reimplementing its exact algorithms, which we cannot do. Any
   implementation of ours will differ in the last ulp on some inputs. That
   directly threatens the differential contract, because `clua-interp.exe` links
   the CRT. The resolution is in [§4](#4-the-oracle-problem-and-its-only-sound-answer).

**`setjmp`/`longjmp`: already almost solved, and worth noting.** The Lua core
does **not** depend on the CRT here — `lua-5.4/src/ldo.c:73-74` carries a
CLua-specific patch using `__builtin_setjmp`/`__builtin_longjmp` precisely to
avoid Windows SEH unwinding, and `liblua54.a` references neither symbol.
Only two of our own objects remain: `dispatch.o` needs `__intrinsic_setjmpex`
and `veh.o` needs `longjmp`. Both are ours to convert. A plain register-save
`setjmp` (rbx, rsp, rbp, rsi, rdi, r12–r15, xmm6–15, return address) is correct
here because nothing between the save and the jump requires unwinding — no C++
destructors, no `__try`/`__finally`. **Verification obligation:** confirm the FFI
callback path does not rely on SEH unwinding across a `longjmp` before removing
`__intrinsic_setjmpex`.

---

## 2. Why do it, then

### 2.1 Self-containment

Import only `kernel32.dll` and the program runs where a UCRT may not be
present or may not be the one we tested: Server Core minimal installs, WinPE,
Windows 7 without KB2999226, locked-down sandboxes, custom loaders, and PE
contexts that cannot tolerate a CRT init. This is the primary motivation and it
is qualitative — there is no benchmark for it, only a supported-configuration
list.

### 2.2 Determinism

Today a `ucrtbase` servicing update could change a `%.14g` edge case or a `sin`
last-ulp result under us. Our differential oracle would **not** catch it, because
`clua-interp.exe` links the same CRT and would move in step. Owning the libc
means one behaviour on every Windows build, pinned by our own tests. This
complements the existing byte-reproducibility guarantee: reproducible *output*
today, reproducible *behaviour* after this.

### 2.3 The allocator — the one plausible speed win

Lua's GC does a very large number of small, short-lived allocations. Replacing
`malloc` with an allocator shaped for that pattern (size-segregated free lists
over `VirtualAlloc`, no thread-safety cost on the single-threaded path) is the
only item in this roadmap with a credible runtime upside. **It must be measured
with `tools/bench-runtime.lua` under the protocol in
[`docs/benchmarks/README.md`](../benchmarks/README.md), and reported even if the
answer is zero** — as the codegen work was.

### 2.4 Startup latency

No CRT initialisation, no apiset resolution for 12 DLLs at load. Expect a small
win on process start; measure it, since `clua`/`rover` invoke child processes
frequently and short-lived program startup is user-visible.

### 2.5 It unlocks a genuinely small tier

A program that touches no `io`, `os`, `math` or float formatting needs perhaps a
tenth of the libc. `--freestanding` (item N10) is where a small binary floor
becomes reachable — but only because we own the libc and can drop most of it.

---

## 3. Modes, and what stays the default

The design is a mode axis, not a switch:

| Mode | Imports | Status |
|---|---|---|
| `--crt=ucrt` | `api-ms-win-crt-*` + Win32 | **today's behaviour, stays the default forever** |
| `--crt=none` | `kernel32` + whatever FFI asks for | the new mode |
| `--freestanding` | `kernel32` only, `io`/`os`/`math` unavailable | N10, opt-in subset |

`--crt=ucrt` remains default because it is the compatible, best-tested
configuration and because `ucrtbase`'s float conversion is the reference our
fidelity contract currently rests on. `--crt=none` earns the default only if it
ever passes the full matrix for several releases — that is a later decision, not
part of this plan.

There is deliberately **no `--crt=msvcrt`** mode. Supporting the legacy
`msvcrt.dll` adds a third float-formatting behaviour to be bug-compatible with,
for a platform we do not target.

Mode selection lives in the driver and changes only the archive set the internal
linker consumes plus the PE entry point — it is not a codegen input. Keep it out
of `clua/src/codegen/` entirely, so the no-new-globals guard and byte-identity
corpus stay meaningful.

---

## 4. The oracle problem, and its only sound answer

`clua-interp.exe` is the frozen fidelity reference, and it links the CRT. If our
compiled output uses our libm and the oracle uses `ucrtbase`'s, then
`math.sin(1)` can differ in the last bit and the differential suite fails on a
divergence that is not a miscompile.

Three candidate answers, only one of which holds:

1. ~~Link static mingwex libm in both~~ — **impossible**: mingwex has no
   transcendentals (§1, verified).
2. ~~Loosen the float comparison in the differential runner~~ — **rejected
   outright.** The differential suite is the arbiter; weakening it to make a
   change pass is exactly the failure mode `CLAUDE.md` prohibits.
3. **Build `clua-interp.exe` against the same `clua/src/libc/`.** Both sides of
   every diff then use one implementation, and the oracle is self-consistent.
   This is the answer.

The consequence must be stated plainly: **`math.sin(1)` under `--crt=none` may
print differently from PUC-Rio Lua on MSVC.** That is acceptable and documented —
the Lua manual does not specify transcendental accuracy, and real Lua already
differs across platforms for this exact reason. What is *not* acceptable is CLua
disagreeing with its own oracle.

Ordering consequence: **item N9 (flip the oracle) must land before `--crt=none`
is declared usable**, and the full differential + conformance matrix must be run
in both modes afterwards.

---

## 5. Fidelity traps, ranked

Ordered by how likely each is to produce a silent, hard-to-attribute diff:

1. **`%.14g` float formatting** — every `print` of a non-integer number. A
   single wrong digit in one rounding case shows up as a diff in an unrelated
   test. Highest-volume risk in the project.
2. **`strtod` rounding** — every numeric literal and `tonumber`. Halfway ties and
   subnormals are where naive implementations fail.
3. **libm last-ulp** — resolved structurally by §4, not by being careful.
4. **`argv` quoting.** With no CRT we parse `GetCommandLineW` ourselves, and
   MSVCRT's quoting/backslash rules are idiosyncratic. Get them wrong and `arg[]`
   differs. Must match MSVCRT's documented algorithm exactly, with tests over
   adversarial command lines.
5. **`strerror` strings** — printed verbatim in `io` error messages (§1 Tier 1).
6. **`clock()` semantics.** `os.clock` maps to C `clock()`. On Windows,
   `ucrtbase`'s `clock()` returns **wall time since process start**, not CPU
   time as POSIX specifies. Match `ucrtbase`, not the standard, or `os.clock`
   silently changes meaning.
7. **`tmpnam`/`tmpfile` naming** — only matters if a test prints the name; check
   before assuming it does not.
8. **Locale decimal point** — we return `.` always. This is *more* deterministic
   than today, but it is a behaviour change on a non-C-locale machine, so state
   it in the release notes rather than discovering it later.

---

## 6. Verification strategy

The reason this is tractable at all is that CLua already has the machinery. Two
new gates, both cheap, both built **before** the code they gate:

**6.1 A C-level libc-vs-CRT differential (item N1 — first, before any
implementation).** A harness that links *both* our libc and `ucrtbase` into one
process and compares them function by function. This is a far stronger and much
faster gate than going through the whole compile pipeline:

- `tests/libc/test_*.c`, discovered like the existing unit layer, using
  `tests/unit/test_harness.h`.
- Float conversion: millions of random doubles plus the classic pathological
  decimal strings, comparing `%.14g`/`%.17g`/`%a` output and `strtod` results
  bit-for-bit against `ucrtbase` in the same process.
- Every Tier 1/2 function against its CRT counterpart over adversarial inputs
  (empty strings, overlapping `memmove`, zero lengths, `realloc(NULL)`,
  `realloc(p,0)`, seek past EOF, short reads).

**6.2 An import-table assertion — this is the definition of done.**
`--crt=none` output must import **only** `kernel32.dll` plus whatever the
program's own FFI requests. One `objdump -p` check; add it as a Lua test so the
normal suite enforces it.

**6.3 Extend the existing gates rather than adding parallel ones.**

- `tools/run-tests.lua` gains a **mode axis** so the differential and conformance
  layers run under both `--crt=ucrt` and `--crt=none`. This roughly doubles
  suite time — budget for it, and make the mode selectable so ordinary runs stay
  fast while the full matrix runs before a merge.
- `tools/check-byte-identity.py` gains `--crt=none` rows: the new mode must be
  byte-reproducible too.
- `tools/test-olevel-contract.lua` must keep passing in both modes.
- Every claim in §2.3 and §2.4 gets a `docs/benchmarks/` entry with its method.

**6.4 Do not trust a green tally.** Per `CLAUDE.md` and the caveats in
`docs/benchmarks/README.md`: a passing run of a suite that never exercised
`--crt=none` proves nothing about `--crt=none`. Assert the mode was actually
used — check the import table, not the exit code.

---

## 7. Work items in dependency order

Each item is independently landable and leaves the tree green. `N0`–`N2` are
worth doing even if the rest is deferred.

| # | Item | Gate |
|---|---|---|
| **N0** | `tools/audit-libc-surface.sh` — make §1's table reproducible on demand, with a test that fails when the surface grows unexpectedly | table matches this document |
| **N1** | The libc-vs-CRT differential harness (§6.1), with **zero implementations behind it yet** — it must be able to test `ucrtbase` against itself and pass | harness green against the CRT |
| **N2** | `--crt=` plumbing: driver flag, archive-set selection in the linker, `--crt=ucrt` default, no behaviour change | byte-identity corpus unchanged |
| **N3** | Tier 1: `mem*`, `str*`, ctype, `__main`, `___chkstk_ms`, `-fno-stack-protector` | N1 harness green for Tier 1 |
| **N4** | Allocator + our own PE entry point (`GetCommandLineW` + MSVCRT-exact argv parsing, TLS init, libc init, `ExitProcess`) | a `hello` that touches nothing else imports **only** `kernel32` (§6.2) |
| **N5** | Tier 2: stdio, `_popen`/`_pclose`, process/env, time, locale | N1 green; Rover builds and its tests pass under `--crt=none` |
| **N6** | Own `setjmp`/`longjmp`; convert `dispatch.o` and `veh.o`; **first verify** the FFI callback path needs no SEH unwind across a jump | error handling + FFI callback tests green in both modes |
| **N7** | `printf` family with Dragon4 correctly-rounded float conversion | N1 float suite bit-exact vs `ucrtbase` |
| **N8** | `strtod` correctly-rounded | N1 round-trip suite bit-exact |
| **N9** | libm; **then flip `clua-interp.exe` onto `clua/src/libc/`** (§4) | full differential + conformance matrix green in both modes |
| **N10** | `--freestanding` tier; document the supported-configuration list and the §5.8 locale note | size floor measured and recorded |

**Where this sits relative to the platform roadmap.** It is a third track,
independent of the front end, and it should start **after** the linker split
(`language-platform.md` Phase B item 4) because N2 touches archive-set handling
that the split is about to move. Running it in parallel with the front-end track
is fine; running N2 into an unsplit `pe_emit.c` means a merge across a moved file.

---

## 8. The actual size lever is somewhere else

Because the question that started this was about size, the honest answer needs a
place to point instead.

`hello.exe` `-O1` is 137,216 bytes: `.text` 114,736, `.rdata` 11,420, `.idata`
4,330, `.pdata` 1,536, `.xdata` 1,512, `.bss` 3,104, `.reloc` 400, `.data` 512,
`.tls` 16. The `.text` is our runtime plus the Lua core, and it does not move
with user code — the whole-session A/B measured `hello` at **0 bytes changed**
while Rover fell 9.22%.

The linker already drops 21,104 bytes of dead code on `hello` (656 sections kept,
338 dropped). The lever is making that GC finer-grained:

- Build the runtime and Lua core with `-ffunction-sections -fdata-sections` so
  the existing section GC can drop individual unused functions rather than whole
  objects. This is likely the single largest available reduction and it needs no
  new mechanism — only more sections for the GC we already have.
- Extend the `lc_module_uses_debug`-style scan (AOT-NODEBUG-001, which already
  swaps in `lvm_nointerp.o`) to more stdlib families: a program that never
  mentions `os`, `io` or `utf8` need not carry them.
- Audit `.rdata` for tables retained by a single reference.

These are orthogonal to `--crt=none`, cheaper, and they move the number that
actually dominates. They belong in `concurrency-size-stability.md`, not here, and
this section exists to make sure the two projects are not confused for each
other again.

---

## 9. Honest cost and risk

| | |
|---|---|
| **Effort** | Tier 1 ~1 day. Tier 2 ~1 week. N7+N8 (float conversion both ways) **1–2 weeks and the real cost**. N9 libm ~1 week plus the oracle flip. N0–N2 ~2 days. Total: roughly a month of focused work, over half of it in float↔text. |
| **Size effect** | **Net increase, estimated +15 to +30 KB.** `.idata` loses ~3 KB; our implementations add more. `hello` plausibly 137 KB → ~165 KB. Not a size project. |
| **Speed effect** | Unknown, plausibly positive via §2.3, plausibly zero. Must be measured, and reported either way. |
| **Risk concentration** | Almost entirely in `%.14g` and `strtod`. Both are fully covered by the N1 harness, which is why N1 comes first. |
| **Biggest unknown** | Whether the FFI callback path tolerates our own `setjmp` (N6). Verify before implementing. |
| **What would make this a bad idea** | If the answer to "why" is size. If `--crt=ucrt` stops being the default before the matrix has been green for several releases. If anyone proposes loosening the differential comparison to make libm pass. |
