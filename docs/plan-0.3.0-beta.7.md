# plan for 0.3.0-beta.7

binary size and libc surface. this is the sibling doc to beta.6 (which
covers language sugar, static typing, ergonomics, opts, subcommands,
editor extension). style rules the same: lowercase, ascii only, no em
dashes, no smart quotes, no invented measurements, no ai watermarks.

why a separate doc: beta.6 is already 840 lines and covers user-visible
surface; the work here is a different tree (linker, runtime archives,
libc) and different reviewer set (the binary produced changes for every
build, not just for programs using new sugar). keeping them separate
lets each ship on its own cadence.

## measured baseline (do not answer size questions from memory)

read [`docs/benchmarks/no-crt-baseline.md`](benchmarks/no-crt-baseline.md)
before touching this track. the headline that anchors every decision here:

- `hello.exe` at -O1 is 137,216 bytes. `.text` is 114,736 (83.6%); everything
  else is the wrapper.
- `.text` is OUR runtime plus lua core, not crt code. CRT is already outside
  the binary (imported from `ucrtbase.dll` via `api-ms-win-crt-*` apiset
  forwarders).
- the CRT's entire on-disk cost is import-table entries, at most 4,330 bytes.
- `--crt=none` deletes those imports AND adds ~15-30 KB of our own libc code.
  net effect: binary GROWS by ~20 KB, not shrinks.
- the actual size lever is `-ffunction-sections -fdata-sections` on the
  runtime plus extended dead-stdlib scans. potentially 30-40 KB off.

that measurement inverts a naive premise. the two projects in this doc do
different things:
- **track L** wants smaller binaries. lands first, cheaper, no oracle
  rebuild.
- **track M** wants self-containment / determinism / owned allocator.
  grows binaries but delivers a supported-configuration list that "hello
  runs on server core, winpe, sandboxed loaders."

## track L: actually shrink the binary

everything in L targets `.text` and `.rdata` in the emitted PE, not the
import table. no libc changes. safe to run alongside track M's early items.

### L1. `-ffunction-sections -fdata-sections` on runtime + lua core

today `runtime-aot.a` and `liblua54-embedded.a` are built without these
flags. every object file is one big section; the linker's `--gc-sections`
can only drop whole objects. a `runtime-aot/table_helpers.o` that contains
50 helpers of which the user program calls 3 pulls in all 50.

flip the flag on:
- `EMBEDDED_LUA_CFLAGS` in build/Makefile (already `-ffunction-sections`
  on line 124; check that `-fdata-sections` is there too and audit that
  it applies to every archive)
- `runtime-aot.a` build recipe
- `aot_entry.o` build recipe
- every `_pkg_gen.o` (the generated package objects)

then the linker's existing `--gc-sections` sweep prunes unreachable
functions at INDIVIDUAL granularity. measured potential: on a small
program that uses maybe 15 runtime helpers out of ~200, this removes
the other 185. estimated 15-25 KB off `hello.exe`, more on medium
programs.

verification: byte-identity delta is EXPECTED here. update the
byte-identity corpus baseline once, gate on "new baseline is stable
across a repeated cold-and-warm build."

### L2. extend `lc_module_used_libs` to `os` / `io` / `utf8` scans

the compiler already scans for a `debug` reference and swaps
`lvm_nointerp.o` in when the program never uses debug. same trick
scales to the other stdlib families: a program that never mentions
`os` / `io` / `utf8` does not need `loslib.o` / `liolib.o` /
`lutf8lib.o`.

per-library scan lives in the closed-world pass. gate each family
behind a used-libs bit; the linker force-undefs only the anchors
whose bit is set (mirroring the existing `LCLIB_*` scheme in
`common/stdlib_libs.h`). unused families disappear at link time
because nothing references their `Clua_Open<Lib>` anchor and
`--gc-sections` drops them.

measured potential per family (from the anchor-split notes in the
project memory): 5-15 KB each. a rover-shaped program that uses
none of these could drop 30-40 KB.

trap to avoid: false negatives. `os.time()` reached through
`_G["os"].time()` must still force-keep the lib. the existing
`lc_module_used_libs` returns `LCLIB_ALL` for the three shapes that
reach an unnamed library (`package.loaded[k]`, `_G[k]`,
`debug.getregistry()`) per the anchor-split fix; keep that.

### L3. `.rdata` audit for single-reference tables

the `.rdata` share is small (11,420 bytes on hello, 8.3%). worth a
one-time audit to see if any tables in `runtime-aot.a` retain other
tables through one reference that gc-sections cannot see. one-off
pass; document findings even if the answer is zero.

### L4. -Oz mode wired to L1-L3

beta.6 G9 documented a `-Oz` mode. once L1-L3 have landed, `-Oz`
becomes meaningful: (i) force `-ffunction-sections -fdata-sections`
if not already, (ii) turn on the extended stdlib scans unconditionally,
(iii) plus everything G9 already said (`--strip=all`, no debug
sections, `--shared-rt` when available). only meaningful after L1-L3;
before that it is a synonym for `-O2`.

## track M: no-CRT (`--crt=none`)

read [`docs/roadmaps/no-crt.md`](roadmaps/no-crt.md) in full before
starting any item in M. every line in this section is a summary of
what the roadmap says in more detail.

### M0 == N0. `tools/audit-libc-surface.sh`

reproduce the "100 libc symbols" table from the baseline doc as a
script. add a test that fails if the surface grows unexpectedly (a
new archive object that pulls in `getchar` or similar). before any
implementation.

### M1 == N1. libc-vs-CRT differential harness

before writing ANY replacement libc code, write the harness that
links BOTH `ucrtbase` and (future) `clua/src/libc/` into one process
and compares them function by function. tier-1 tests millions of
inputs. this is the gate every M-item after this must pass.

pass criterion for M1 itself: the harness can test `ucrtbase`
against itself with zero implementations behind it and still pass.
that proves the harness works before we start writing our libc.

### M2 == N2. `--crt=` driver flag

add the flag with three values: `ucrt` (default, today's behaviour),
`none` (the new mode, no implementations behind it yet), `msvcrt`
NOT supported (documented as such; adds a third float behaviour to
be bug-compatible with for a platform we do not target).

no behaviour change on this item. `--crt=ucrt` remains default and
byte-identity corpus is unchanged. m2 is plumbing.

### M3 == N3. tier 1 libc: memory, strings, ctype, stack-check stubs

`mem*` (5 fns), `str*` (10 fns), ctype (11 fns), `___chkstk_ms`,
`__main`, `__stack_chk_fail`, `__stack_chk_guard`. mechanical; no
algorithmic risk. `mem*` and `str*` MUST exist under any mode
because gcc emits calls to them for struct copies.

pass criterion: N1 harness green for tier 1.

### M4 == N4. own PE entry + allocator + argv parsing + tls init

replace CRT `mainCRTStartup` with our own PE entry that:
- calls `GetCommandLineW`, parses MSVCRT-exact argv (backslash /
  quote rules are documented but idiosyncratic; test adversarially)
- initialises `.tls` slots without CRT
- calls our `main()` equivalent
- calls `ExitProcess`

allocator: replace `malloc`/`calloc`/`realloc`/`free` with our own
implementation over `HeapAlloc` family or a size-segregated free-list
over `VirtualAlloc`. this is §2.3 of the roadmap — the ONE ITEM in
M with a credible runtime upside. measured with `tools/bench-runtime.lua`
under the benchmark protocol; report even if the answer is zero.

pass criterion: a hello that touches nothing but printing imports
ONLY `kernel32.dll` (asserted by `objdump -p`).

### M5 == N5. tier 2 libc: stdio, pipe, process, time, locale

48 shallow win32 wrappers:
- stdio (`fopen`/`fread`/`fwrite`/`fclose`/`fseek`/`ftell`/...) over
  `CreateFileW`/`ReadFile`/`WriteFile`/`SetFilePointerEx` plus our
  own `FILE` and buffering
- pipes (`_popen`/`_pclose`) over `CreatePipe` + `CreateProcessW`.
  ROVER depends on these (`io.popen` throughout).
- process/env (`exit`/`abort`/`getenv`/`system`/`_errno`/
  `_beginthreadex`) over `ExitProcess` / `GetEnvironmentVariableW` /
  `CreateProcessW` / thread-local storage / `CreateThread`
- time (`_time64`/`_difftime64`/`_gmtime64`/`_localtime64`/
  `_mktime64`/`clock`/`strftime`) over `GetSystemTimeAsFileTime` etc
- locale: C locale only, fixed struct

trap: `clock()` on windows via ucrtbase returns WALL time since
process start, NOT cpu time. match ucrtbase, not the standard, or
`os.clock` silently changes meaning.

trap: `strerror` strings are printed verbatim in `io` error
messages. must be captured from ucrtbase and hard-coded, not
invented, so `luaL_fileresult` output matches.

pass criterion: N1 harness green for tier 2; rover builds and its
tests pass under `--crt=none`.

### M6 == N6. own setjmp/longjmp

lua core already uses `__builtin_setjmp`/`__builtin_longjmp` via
the CLua patch in `ldo.c:73-74`. only two of our own objects still
reference CRT setjmp: `dispatch.o` (`__intrinsic_setjmpex`) and
`veh.o` (`__imp_longjmp`).

VERIFY FIRST that the FFI callback path does not rely on SEH
unwinding across a longjmp before removing `__intrinsic_setjmpex`.
this is the roadmap's biggest unknown; a wrong assumption here breaks
FFI callbacks in ways that are hard to diagnose.

plain register-save setjmp (rbx, rsp, rbp, rsi, rdi, r12-r15,
xmm6-15, return address) is correct because nothing between save and
jump needs unwinding (no C++ destructors, no `__try`/`__finally`).

pass criterion: error handling + FFI callback tests green in both
CRT modes.

### M7 == N7. printf family with correctly-rounded float conversion

`snprintf` / `vsnprintf` / `fprintf` / `__mingw_sprintf` /
`__mingw_fprintf`. integer + string trivial. `%a` exact and easy.
`%e`/`%f`/`%g` at arbitrary width/precision needs a correctly-rounded
big-integer path (Dragon4 / David Gay `dtoa` / musl).

DO NOT REACH FOR RYU OR GRISU. those compute the shortest
round-tripping representation, which is a different function from
`%.14g` and will disagree.

pass criterion: N1 float suite bit-exact vs ucrtbase across millions
of random doubles plus the classic pathological decimal strings.

this is the ROADMAP'S BIGGEST SINGLE COST. 1-2 weeks by itself.

### M8 == N8. strtod correctly-rounded

decimal-to-binary, reverse of M7. handles subnormals, exact-halfway
ties (round-half-to-even), overflow to infinity, lua 5.4 hex float
literals, and whatever ucrtbase does with `"inf"`/`"nan"`. same
big-integer machinery as M7, reversed.

pass criterion: N1 round-trip suite bit-exact.

another 1-2 weeks.

### M9 == N9. libm + FLIP THE ORACLE

15 transcendentals: `sin cos tan asin acos atan2 sinh cosh tanh exp
log log10 pow fmod frexp ldexp`. `sqrt fmod frexp ldexp` are exact;
the 11 transcendentals CANNOT be made bit-identical to ucrtbase
without reimplementing its exact algorithms which we cannot do.

the ONLY sound resolution to the oracle problem (§4 of the roadmap):
BUILD `clua-interp.exe` AGAINST THE SAME `clua/src/libc/`. both
sides of every differential test then use one implementation.
math.sin(1) may differ from PUC-Rio Lua on MSVC (documented behavior
change); math.sin(1) MUST NOT differ between our compiled output
and our own oracle.

this is a merge-blocker item. the full differential + conformance
matrix must be run in BOTH modes after this lands.

pass criterion: full differential + conformance matrix green in
both `--crt=ucrt` and `--crt=none`.

### M10 == N10. `--freestanding` tier

a program that touches no `io`/`os`/`math` (or only touches the
tiny slice actually implemented in freestanding mode) can drop most
of libc. document the supported-configuration list. this is where
the "genuinely small binary" tier lives; only reachable AFTER we own
libc AND after track L has landed.

pass criterion: size floor measured on a freestanding hello (no
imports beyond `kernel32`, no libc beyond what the program calls),
recorded in `docs/benchmarks/`.

## ordering

phase L (independent of M; smaller binaries; land first because
cheap and no oracle problem):
- L1 -ffunction-sections + -fdata-sections on runtime + lua core
- L2 extended stdlib scans (os / io / utf8 anchors gated behind
  used-libs bits)
- L3 .rdata single-reference audit (one-off; document findings)
- L4 -Oz wired to L1-L3

phase M (in strict order; each blocks the next):
- M0 audit-libc-surface script
- M1 libc-vs-CRT differential harness (before ANY implementation)
- M2 --crt= driver flag (plumbing only, no behavior change)
- M3 tier 1 libc (mechanical)
- M4 own PE entry + allocator + argv parsing + tls init
     ("hello imports only kernel32" is the gate)
- M5 tier 2 libc (stdio, pipe, process, time, locale)
- M6 own setjmp/longjmp (verify FFI callback path FIRST)
- M7 printf family with dragon4 (biggest single cost, 1-2 weeks)
- M8 strtod correctly-rounded (1-2 weeks)
- M9 libm + FLIP THE ORACLE (merge-blocker; full matrix in both modes)
- M10 --freestanding tier

## gates (extra, on top of the standard suite-green gate)

per the roadmap §6:

- N1 harness (item M1) is the primary gate for every libc item M3
  through M9. a green run of the full suite does NOT prove `--crt=none`
  works; the harness must assert bit-exact behaviour against ucrtbase
  for every replaced function.
- "imports only kernel32" import-table assertion (item M4 gate)
  becomes a permanent test in `tools/test-crt-none-imports.lua` for
  every future build under `--crt=none`.
- byte-identity corpus grows a `--crt=none` row after M2 lands;
  every subsequent item must not perturb it beyond its own explicit
  add.
- `tools/test-olevel-contract.lua` must pass in BOTH modes.
- track L: byte-identity delta is EXPECTED on L1. rebaseline once,
  then gate on "new baseline stable across cold+warm rebuild."
- track L: measured size delta reported per item, with the
  benchmark protocol from `docs/benchmarks/README.md`.

## explicit non-goals

- msvcrt.dll support. rejected. adds a third float behaviour to be
  bug-compatible with for a platform we do not target.
- weakening the differential comparison to make libm pass. rejected.
- making `--crt=none` the default. NEVER on this arc; earning
  default status is a separate decision after the full matrix has
  been green for several releases.
- linux backend. explicitly out of scope (beta.6 said this too, for
  a different track; repeating here so nobody thinks track M opens
  the door to POSIX libc). wasm is fine (beta.6 track I2); linux is
  not.

## honest cost and risk (from the roadmap §9)

| | |
|---|---|
| **effort** | tier 1 ~1 day. tier 2 ~1 week. m7+m8 (float conversion both ways) 1-2 weeks and the real cost. m9 libm ~1 week plus the oracle flip. m0-m2 ~2 days. total: roughly a month of focused work, over half in float text conversion. |
| **size effect** | NET INCREASE of about +15 to +30 KB. hello plausibly 137 KB -> ~165 KB. NOT A SIZE PROJECT. |
| **speed effect** | unknown, plausibly positive via M4's allocator, plausibly zero. must be measured, reported either way. |
| **risk concentration** | almost entirely in `%.14g` and `strtod`. both fully covered by N1 harness, which is why N1 comes first. |
| **biggest unknown** | whether the FFI callback path tolerates our own setjmp (M6). verify before implementing. |
| **what would make this a bad idea** | if the answer to "why" is size (do track L instead; that's what shrinks the binary). if `--crt=ucrt` stops being default before the matrix has been green for several releases. if anyone proposes loosening the differential comparison to make libm pass. |
