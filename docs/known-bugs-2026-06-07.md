# CLua — Bugs found by the new test suite (2026-06-07) — ALL FIXED

Building the fresh test suite surfaced five pre-existing bugs (three in the JIT,
two in packages). Each was root-caused and fixed the same day; each now has a
permanent regression test. Suite is green with **0 XFAIL**. This file is kept as
the record.

## JIT correctness

### JIT-001 — `<close>` variable in scope at `return` dropped the return value — FIXED
`function f() local g <close> = setmetatable({},{__close=fn}); return 42 end`
returned **nil** under the JIT (the interpreter returned `42`).
**Root cause:** `Rt_Close` called `luaF_close(L, base, LUA_OK, …)`. With
`LUA_OK`, `prepcallclosemth` → `luaD_seterrorobj` resets `L->top` to
`level + 2` — right on top of the live result registers — and the `__close` call
frame overwrites the result.
**Fix:** mirror `lvm.c` `OP_RETURN` — raise `L->top` to the frame ceiling **and**
pass `CLOSEKTOP`. `src/jit/runtime.c` `Rt_Close`. Regression:
`tests/lua/test_jit_regressions.lua`.

### JIT-002 — NaN `>`/`>=` comparison returned the wrong boolean — FIXED
`nan > 0` returned **true** (must be false).
**Root cause:** `Lower_Gti`/`Lower_Gei` implemented `a > b` as `!(a <= b)` —
correct for normal numbers, wrong for NaN.
**Fix:** new `Rt_GtISlow`/`Rt_GeISlow` using operand-swapped `sB < R[A]` (the
NaN-correct form). `src/jit/runtime.c` + `src/jit/codegen.c`.

### JIT-003 — deep tail recursion crashed the process — FIXED
A tail-recursive loop grew the native C stack and crashed (`STACK_OVERFLOW`) at
~25k–300k depth; the interpreter ran it in constant stack.
**Root cause:** `Rt_TailCall` reused the Lua `CallInfo` but re-entered the JIT
as a nested C call per tail call.
**Fix:** an iterative drive loop — top-level tail call marks its `CallInfo` with
`CIST_JITTAILDRIVE` and loops; nested tail calls detect the bit and signal
`g_TailRepeat` instead of recursing. `src/jit/runtime.c` `Rt_TailCall`.
Regression: `tests/lua/test_jit_regressions.lua` + `tests/differential/tailcall.lua`.

## Package bugs

### CBOR-001 — float64 encode/decode corrupted non-dyadic values — FIXED
`cbor.decode(cbor.encode(3.14))` returned **6.96**. **Root cause:** the manual
IEEE-754 decode assembled the 52-bit mantissa with the wrong byte grouping.
**Fix:** `string.pack(">d", n)` / `string.unpack(">d", s, p)`.
`src/runtime/packages/cbor/init.lua`. Regression: `tests/packages/test_cbor.lua`.

### AES-002 — AES-128 key import failed (`STATUS_INVALID_PARAMETER`) — FIXED
A 16-byte key caused `BCryptGenerateSymmetricKey` to fail.
**Root cause:** `import_key` passed a hand-built `BCRYPT_KEY_DATA_BLOB` (12-byte
header + key); the API expects raw key bytes. The 28-byte total matched no valid
AES key length. (24- and 32-byte keys worked by accident.)
**Fix:** pass the raw key buffer + length. `src/runtime/packages/aes/init.lua`.
Regression: `tests/packages/test_aes.lua` (AES-128/192/256 × GCM/CBC/CTR).

## Round 2 — audit-driven (2026-06-07) — ALL FIXED

A 9-dimension codebase audit + a new Lua 5.4 conformance corpus surfaced more.
All fixed; suite 116/0/0.

- **JIT-decline crash (CRITICAL).** `luaV_execute` called `luaG_runerror` when
  codegen couldn't compile a Proto, aborting every shipped exe with a large
  function. Now falls through to `luaVM_Interpret`. (`lua-5.4/src/lvm.c`)
- **Oversized-Proto segfault (CRITICAL).** `CodegenInternal` ignored
  `BranchCtx_RecordPc`'s return code, corrupting forward branches; a 5000-op
  function deterministically segfaulted. Now rejects oversized Protos up front
  and falls back to the interpreter. (`src/jit/codegen.c`)
- **Close-upvalue register staleness (CRITICAL, silent wrong output).** `Lower_Close`
  didn't reload the register cache after `Rt_Close`, so a value a `__close` handler
  wrote to a captured upvalue was read stale on the next line. Found by the
  conformance differential. Now reloads. (`src/jit/codegen.c`)
- **debug.sethook ignored under the JIT (HIGH).** Hooks (call/line/count) now route
  any function entered while a hook is active to the hook-aware interpreter.
  (`lvm.c` + `src/jit/runtime.c`)
- **FORPREP error text wrong/double-substituted.** Now emits exactly
  `bad 'for' <what> (number expected, got <type>)`. (`src/jit/runtime.c`)
- **msgpack float64 decode corrupted every value** (same class as CBOR-001) →
  `string.unpack(">d")`.
- **punycode all-ASCII delimiter** (RFC 3492) and **yaml plain float scalars**
  (bad pattern) fixed.
- **Package manager: missing input validation** on package names used in
  `io.popen` calls (names from a remote registry); fixed with a strict allowlist
  `^[%w_%.%-]+$`. Also fixed: **install did not honor the lockfile** (non-reproducible
  installs). Added Merkle integrity, transitive dep resolution, and registry
  signature verification.
- **CI was red on every run** (looped `make` over deleted targets) — fixed.

Deferred (documented, not a correctness issue): growing the JIT branch arrays
dynamically (over-limit functions already fall back to the interpreter correctly).

## Round 3 — whole-stack hardening (2026-06-09) — ALL FIXED

A 15-dimension audit (each finding adversarially verified) of the JIT, FFI,
compiler, packages, package manager, and CI surfaced a further batch. All fixed,
each with a regression test; suite 151 PASS / 0 FAIL / 0 XFAIL.

JIT (the `Lower_Close` register-cache bug had siblings — silent miscompile +
use-after-free under the default executor):
- **SET paths** (OP_SETTABLE/SETFIELD/SETI/SETTABUP) ran a `__newindex`
  metamethod (which can relocate the Lua stack) without reloading RDI + the
  register cache. Now each reloads, mirroring the GET twins. (`src/jit/codegen.c`)
- **Comparison slow paths** (OP_EQ/LT/LE register form and EQI/LTI/LEI/GTI/GEI/
  EQK immediate form) ran `__eq/__lt/__le` without reloading; the reload also
  has to precede the conditional branch (the prior EQK reload sat *after* it, so
  the taken edge stayed stale). New `EmitCompareSlowReloadAndBranch` stashes the
  result in R11D, reloads, then tests + branches. (`src/jit/codegen.c`)
- `Rt_EqKSlow` now uses `luaV_rawequalobj` (matching OP_EQK). (`src/jit/runtime.c`)
  Repros: `tests/differential/{settable,compare}_meta_stale.lua` (proven to fail
  without the fix — one returned a stale `table:`, the other crashed).

Packages:
- **zlib** pure-Lua inflate corrupted every overlapping back-reference (RLE runs)
  — the read index advanced twice per byte (`"aaaa"->"aa"`). Anchored the read.
- **mime** `parse_multipart` interpolated the boundary into a Lua pattern (broke
  real boundaries with `- . + =`); `parse_content_type` split on `;` inside a
  quoted value. Both fixed (plain scan / quote-aware scan).
- **Zip-Slip / path traversal** in the `zip`, `zip_native`, `tar`, `cab`
  extractors — entries with `..`, absolute, or drive-prefixed names could write
  outside the destination. Each now refuses such entries.
- **matrix.eigenvalues** returned wrong values for every 3×3 (a spurious sign
  flip on the depressed-cubic constant). **units.parse** stole a bare number's
  trailing digit as a bogus unit. **currency.format** leaked IEEE-754 garbage
  for 18-dp currencies. **slug** separator was a pattern-injection. **lpeg**
  pure-Lua fallback lacked the `/` capture operator and a fixed-length `B()`.
  **glob_match** `**` never matched + anchored rules over-matched. **x509**
  parse_time decoded UTC as local time. **formula** had a nonsense infix `%`.
  **ini** dropped null list members. **xml** pretty-print corrupted mixed
  content. **phone** false-rejected NANP +1-670. **stats** one-sided t-test was
  wrong. **random.unbiased_range** rejection was non-functional (signed MASK64).
  **email_validate** accepted trailing-dot domains. **quoted_printable** emitted
  a literal trailing space. **zstd** one-shot FFI returns truncated size_t.
- **pbkdf2 Argon2id** crashed for parallelism >= 2 (cross-lane reference-area
  over-sized into uncomputed blocks). Fixed; verified against the RFC 9106
  official (p=4) and PHC (p=1, m=65536) vectors.
- **bignum** divmod/div/mod (BIGNUM-001) gave a wrong q/r for a negative divisor
  needing the multi-limb path (signed arithmetic where magnitude was assumed).
  Normalised both operands to magnitude in `udivmod`.

Package manager: `~1` tilde range, compound `>=a <b` ranges, x-ranges, and
hyphen ranges were unsupported/wrong; a registry value was interpolated into the
shell without metacharacter validation; a corrupt lockfile was silently
re-resolved; the lock integrity check compared mismatched hash kinds; conflict
reconciliation skipped the reconciled version's transitive deps. All fixed.

CI/release: the release zip shipped an empty `docs/` and promised deleted
examples; release notes were always the generic fallback; both workflows installed
an unused .NET SDK + winmd cache. Fixed.

Compiler + FFI: reviewed inline (the agent dimensions were policy-blocked) —
marshal sign/width/LLP64 conversions, the ctype primitive table, the blob
layout, and the require-literal scan (recurses nested Protos) are all correct;
no defects found.

### JIT-VARARG-001 — `...` forwarded right after a generic-for loop expanded extra values — FIXED
Forwarding the varargs (`f(...)`, `return ...`, `select('#', ...)`) immediately
after a **generic**-for loop (`for k in pairs(t)` / `ipairs`) in the same
function produced TOO MANY values under the JIT:

```lua
local function f(...) local t={a=1,b=2,c=3}; for _ in pairs(t) do end; return select('#', ...) end
f(1,9,4)   -- was JIT: 5   |   interpreter (-i): 3   |   now both 3
```

**Root cause:** a generic-for creates a to-be-closed slot (its 4th control
register), so the compiler sets the **k (close)** flag on the function's terminal
`OP_TAILCALL`/`OP_RETURN`. `Lower_TailCall`/`Lower_Return` emit `Rt_Close` BEFORE
the multret consumer, and `Rt_Close` raised `L->top` to the frame ceiling
(`ci->top.p`) to give a `__close` metamethod scratch space (CLOSEKTOP) but never
restored it. The following `Rt_TailCall`/`Rt_PrepReturn` then computed the
multret (B==0) value count from the raised `L->top`, counting the dead for-loop
register slots as extra trailing arguments (extra = `nloopvars + 1`). The
interpreter captures the count BEFORE closing; the JIT closed first. A numeric
for-loop has no TBC slot -> no k -> never triggered. **Fix:** `Rt_Close`
save/restores the logical `L->top` around the raise+close (`savestack`/
`restorestack`, so it also survives a stack relocation from a real `__close`),
making the close `L->top`-neutral for the multret consumer while still giving
`__close` its scratch and preserving the earlier `<close> + return v` fix.
`src/jit/runtime.c` `Rt_Close`. Regression: `tests/lua/test_jit_vararg_genfor.lua`
(incl. a combined `<close>` + pairs + multret case). The `expr` package was also
reworked to an O(1) allow-set (faster, and it no longer relied on the buggy
pattern).

## Round 4 — whole-codebase review (2026-06-09)

A parallel multi-agent review of the JIT codegen/runtime and the FFI, each
finding adversarially **verified against the interpreter before any fix** (one
agent finding was a false positive, ruled out below). Nine real bugs fixed; suite
185 → 191.

### R4-001 — numeric-for loop-variable mutation leaked across iterations (JIT) — FIXED
`for i=1,4 do t[#t+1]=i; i=i+100 end` produced `1,102,203,304` under the JIT vs
`1,2,3,4` in the interpreter. Lua 5.4 makes the loop variable a fresh local each
iteration, so reassigning it in the body must not affect iteration. The integer
`Rt_ForLoop` advanced the VISIBLE control variable `R[A+3]` instead of the hidden
internal index `R[A]` (which it never maintained); the float path was already
correct. **Fix:** keep the internal index in `R[A]` like `lvm.c` and the float
path (`Rt_ForPrep`/`Rt_ForLoop`, `src/jit/runtime.c`). Regression:
`tests/differential/forloop_var_mutation.lua`.

### R4-002 — `Rt_Call` used a stale `Func` after a stack relocation (JIT) — FIXED
`Rt_Call` captured `Func`, set `L->ci`, then `lua_checkstack` — which can grow and
RELOCATE the stack (`correctstack` fixes `Ci->func.p` but not the C local). The
nil-pad loop and `L->top` assignment then wrote through the dangling pointer into
the freed buffer when a callee frame didn't fit. **Fix:** re-derive
`Func = Ci->func.p` after `lua_checkstack` (`src/jit/runtime.c`).

### R4-003 — `Rt_Concat` stored the result through a stale `Base` (JIT) — FIXED
A stack-growing `__concat` metamethod relocated the stack, leaving the `Base`
captured before `luaV_concat` dangling for the result copy. **Fix:** re-derive
`Base` after `luaV_concat` (the copy is then a safe self-copy, matching upstream
`OP_CONCAT`). `src/jit/runtime.c`.

### R4-004 — `ffi.cast` to a narrow integer did not truncate to width — FIXED
`ffi.cast("unsigned int", -1)` boxed `0xFFFFFFFFFFFFFFFF` and printed
`18446744073709551615` instead of `4294967295`; `ffi.cast("int", 0x1FFFFFFFF)`
gave `8589934591` not `-1`. The cast path stored the full 64-bit value into the
cdata, while the primitive read path (`Cdata_Tostring`/`Cdata_Eq`) trusts
`I64` is already width-correct (the struct-field write path via `WriteInt` was
fine). **Fix:** new `Ffi_NarrowInt` truncates + sign/zero-extends at both cast
sites (`src/ffi/ffi_lib.c`). Regression: `tests/lua/test_ffi_cast_width.lua`.

### R4-005 — float→integer FFI write used `floor` not truncation-toward-zero — FIXED
A `-2.7` assigned to an `int` field stored `-3`; a C cast (and LuaJIT) gives `-2`.
**Fix:** `(int64_t)N` instead of `(int64_t)floor(N)` (`src/ffi/marshal.c`).

### R4-006 — `OP_SELF` used `luaH_getshortstr` for method keys (JIT) — FIXED
A method name > `LUAI_MAXSHORTLEN` (40 chars) interns as a LONG string; `Rt_Self`
read its lazily-computed hash before it existed and scanned the wrong bucket
(masked only by the `luaV_finishget` fallback, and an assert landmine). Upstream
`OP_SELF` uses `luaH_getstr`. **Fix:** use `luaH_getstr` (`src/jit/runtime.c`).
Regression: `tests/differential/self_method_dispatch.lua`.

### R4-007 — FFI callbacks with > 4 args read the wrong stack slots — FIXED
The callback stub read stack args (index ≥ 4) at `[rbp+0x10+(i-4)*8]` — inside the
32-byte Win64 home/shadow space — instead of `[rbp+0x30+...]` (above it), so a
callback with ≥ 5 args saw garbage for args 4+. **Fix:** offset `0x30`
(`src/ffi/ffi_callback.c`). Regression: `tests/lua/test_ffi_callback_args.lua`
(round-trips a 6-arg callback through the call thunk).

### R4-008 — multi-dimensional C arrays nested dimensions in reverse — FIXED
`int a[2][3]` parsed as array-3-of-array-2 (innermost-first wrapping), swapping
the strides: `a[0][2]` aliased `a[1][0]` (total size unaffected, which hid it).
**Fix:** `ParseArraySuffixes` collects a dimension run and nests it
first-bracket-outermost, used by both the declarator and type-expression paths
(`src/ffi/cdecl_parser.c`). Regression: `tests/lua/test_ffi_multidim_array.lua`.

### R4-009 — JIT recovery frame was process-global, not per-fiber — FIXED
`g_CurrentJitFrame` (the VEH→Lua-error recovery `setjmp` target) is shared, and
`Jit_TrampolineEntry` installs one only when it is NULL. A coroutine resumed from
within the main fiber's JIT frame skipped its own frame, so a hardware fault in
the coroutine's JIT code would `longjmp` into the resumer's frame — a `jmp_buf`
captured on a different (suspended) fiber stack. **Fix:** `coroutine.resume`
save/restores `g_CurrentJitFrame` around the fiber switch so each fiber owns its
recovery frame (`src/runtime/coro.c`). The trigger (a JIT-region fault inside a
coroutine) is hard to provoke from Lua; verified the swap does not disturb normal
coroutines (`tests/differential/coroutines_jitframe.lua`).

### Ruled out / deferred (Round 4)
- **NOT a bug — `OP_SETLIST` skips the RDI reload after `Rt_SetList`.** Claimed an
  emergency GC during `luaH_resizearray` could relocate the stack. It cannot:
  `lgc.c` shrinks the stack only when `!g->gcemergency` (line 644), and the
  resize's allocation-failure GC is an emergency cycle. The existing comment is
  correct; SETLIST runs no metamethod, unlike the SET ops that do reload.
- **Deferred — immediate-comparison metamethods get an int for a float literal.**
  `obj < 2.0` with a `__lt` passes integer `2` (the `isfloat` C-flag isn't
  threaded into `Rt_*ISlow`). Real but astronomically narrow (custom order
  metamethod compared to a float-valued literal); the fix touches five helper
  signatures + codegen, so it's documented rather than fixed.
- **Deferred (perf only) — `Rt_NewTable` doesn't decode the B hash-size field nor
  fold the EXTRAARG high bits**, so tables are under-presized (they still grow on
  demand; correctness is unaffected).

## Round 5 — test-infrastructure + package coverage (2026-06-09)

Added a hard-deadline test watchdog (`tools/timeout-run.c`, a kill-on-close Job
Object enforcing a per-test wall-clock limit), a seeded **differential fuzzer**
(`tools/fuzz-differential.lua`, JIT vs interpreter, grammar weighted to the
historical bug classes — 2500 seeds run clean), a package **interpreter-oracle**
cross-check (`pkgdiff`: each package test also runs from source under JIT and -i
with stdout diffed), and 44 new package tests. Also fixed the CI/release pipeline
(`make test` now self-builds the embedded archives; release gained a test gate).
The new coverage surfaced a batch of real bugs.

### FIXED
- **R5-001 (perf) — bignum multi-limb division was O(BASE) per numerator limb.**
  `udivmod`'s qhat back-off decremented one at a time; with no Knuth
  normalization a divisor with a small top limb (e.g. `987654321` → top limb 58)
  overestimates qhat by up to ~16M, so the loop ran millions of multiplies per
  limb. Replaced with a binary search over `[0, qhat]` (qhat stays an upper
  bound, so it's exact). `isqrt` of a 30-digit number: **42 s → 0.001 s**;
  `test_bignum`: 104 s → instant. The watchdog exposed it.
  `src/runtime/packages/bignum/init.lua`.
- **R5-002 (FFI) — forward-declared struct typedefs never completed.** `typedef
  struct _X X; struct _X {…};` left `sizeof(X)` = 0 (the idiom every Windows
  header uses). `Ctype_Register` now completes the stub IN PLACE instead of
  repointing the registry slot, so the typedef and self-referential fields
  observe the real layout. Fixed `ffi.sizeof("CRITICAL_SECTION")` (was 0 → 40),
  which in turn fixed `mutex.mutex()`/`channel` (they did `malloc(0)` and
  corrupted the heap). `src/ffi/ctype.c`, `src/ffi/cdecl_parser.c`.
- **R5-003 (FFI) — `ffi.new("T[N]", v)` rejected a scalar initializer** ("kind 4
  vs target kind 5") — it marshalled against the array type, not the element.
  Now a non-aggregate initializer fills element [0] (`ffi.new("HANDLE[1]", h)`),
  fixing event/semaphore construction and the `mem`/`network_info` DWORD paths.
  `src/ffi/ffi_lib.c`.
- **R5-004 — rtf colortbl off-by-one** (leading `;` double-counted; `\cfN` →
  `colors[N]` instead of `colors[N+1]`). **R5-005 — lint** flagged function
  params as undefined globals (`declare_params` never called) and crashed on a
  nameless `local =`. **R5-006 — xpress** faulted on `compress("")` and
  under-sized `out_cap` for XPRESS_HUFF's 256-byte table on tiny inputs.
- **R5-007 — tls_client** leaked the SChannel handshake token (now
  `FreeContextBuffer`); **wmi.execute_method** silently dropped in-params (now
  errors clearly instead of misleading the caller).

### Known bugs (documented, XFAIL/SKIP — not yet fixed)
- **ATOMIC-INTERLOCKED-SYMS-001 — x64 `Interlocked*` intrinsics aren't FFI-
  callable.** kernel32 on x64 exports only the SList variants; `InterlockedOr`,
  `InterlockedIncrement`, `InterlockedCompareExchange64`, … are compiler
  intrinsics with no exported symbol, so `ffi.C.InterlockedXxx` fails. This makes
  the `atomic` package (and `queue`/`pool`/`semaphore`, which use it) non-
  functional; their tests SKIP the atomic ops cleanly. **Proper fix:** built-in
  machine-code atomic stubs (`lock xadd`/`lock cmpxchg`/…) injected by the FFI
  symbol resolver — a focused feature for its own pass.
- **CAB-FFI-001** — the FFI can't CALL a `ffi.cast`'d function pointer ("function
  pointer not resolved"), which blocks every functional `cab` op (they drive a
  cast `SetupIterateCabinetA`/FCI pointer). `cab` test SKIPs the round-trip.
- **XPRESS-SMALL-001** — `RtlCompressBuffer` returns `STATUS_BUFFER_TOO_SMALL`
  for XPRESS and LZNT1 on a 1-byte input (not the output buffer — likely a
  format minimum); XPRESS_HUFF works after R5-006. XFAIL.
- **NET-FFINEW-001 (ULONG path) / NET-ROUTE-002** — `network_info` adapters/
  dns_servers/default_gateway still hit an `ffi.new` integer→pointer conversion
  on the `ULONG[1]` path (the `DWORD[1]` path was fixed by R5-003); routing-table
  shape. XFAIL.

## FIXED — AOT-MULTIMOD-001 (2026-06-12): GC swept Protos during startup build

**Root cause (found via blob-roundtrip instrumentation + layout probes, NOT
the original "miscompile" theory):** `LuacProgram_BuildEntry` reconstructs
every Proto at startup as fresh WHITE, UNANCHORED GC objects; nothing roots
them until the entry closure / package.preload registration at the end. Once
a program's reconstruction allocates past the collector's step threshold
(~17 KB+, i.e. any larger multi-module bundle), an incremental cycle
completes mid-build and SWEEPS the live Protos — the exe then runs on freed
memory. Manifestations varied with layout (heap corruption, access
violations, wrong-register calls, negative line numbers) because the freed
blocks were reused differently; -O1 exes often "worked" only because their
elided code reads fewer Proto fields (code[]/k[]) at runtime than -O0's
helper-heavy code. The bug was LATENT since the generated-ProtoInit-C era
(same unanchored pattern); small programs never tripped a full cycle. The
serializer/deserializer were verified byte-faithful
(tests/unit/test_lc_protoblob_roundtrip.c) before the GC was implicated.

**Fix:** stop the collector across the build and restart it once everything
is rooted (clua/src/runtime/aot_entry.c) — the same idiom upstream Lua uses
in `f_luaopen` for state bootstrap. Regression:
tests/differential/aot_multimod.lua (+ multimod_payload.lua, 150 functions —
red-green verified: heap-corruption crash without the fix, byte-identical to
the oracle with it) at the diff and aotdiff[O0/O1] layers.

## (historical record of the original OPEN entry follows)

### AOT-MULTIMOD-001 original report: multi-module miscompile at scale

Compiling a program that bundles LARGER multi-module sets (e.g. the registry
`json` ~64 functions + `semver`) produces a corrupted exe; the oracle runs
the identical sources correctly, and the v0.1.0 single/two-module corpus
(greet, rover's 71-fn single module) is unaffected. Manifestations shift
with link layout (memory corruption, so the same .text fails differently):

- 3-module `require "json" + require "semver"` at -O1, lvm_nointerp link:
  exit 0xC0000374 (heap corruption) before any output.
- Same with the full lvm.o linked (add a `"debug"` string constant):
  `json/init.lua:25: attempt to call a nil value (local '_null')` — a CALL
  took its callee from a wrong register/slot.
- Single-module stripped-json at -O0: `:-25: attempt to call a nil value
  (field '?')` — NEGATIVE line + garbage name (corrupt debug-info reads);
  the byte-identical source runs clean under `clua-interp -i`, and the
  UNSTRIPPED json works at -O0 — the failure is input-shape-sensitive
  (line-table/layout dependent), not a source-semantics issue.

Repro: `tools\build-registry.lua <stage>` + `rover publish <stage>` +
`rover install json --registry <stage>` (isolated CLUA_HOME), then
`clua build` a program requiring json+semver. Suspect surface: blob/COFF
emission or codegen at larger function counts/sizes (fn table, reloc,
branch-patch, or lineinfo paths). NEEDS a minimization pass + an XFAIL
differential fixture; until fixed, large multi-module bundles are
unreliable — the published registry packages themselves are
oracle-verified correct.

- `hash` is correct: `sha256("abc")` = `ba7816bf…20015ad` matches the NIST vector.
- `math.type("x")` returning `nil` is correct Lua 5.4.
- Across 26+ differential probes the JIT had **no silent wrong-answer
  arithmetic/metamethod/closure miscompiles** — the JIT risks were
  crashes-on-limits + the one close-upvalue register caching corner (fixed).
- **Argon2id "wrong p=1 digest"** (Round-3 audit claim): false — it compared the
  m=256 output to the published reference for m=65536. Both authoritative vectors
  pass.
- **table.move "must bypass metamethods"** (audit claim): false — Lua 5.4
  `table.move` uses `lua_geti`/`lua_seti`, so it correctly honors `__index`/
  `__newindex`. CLua matches the spec.

## Update 2026-06-10 — LuaC AOT adversarial attack findings (rounds 1–6)

The multi-lens differential attack harness (aotc -O1 vs `clua-interp -i`) found and we
fixed five silent wrong-answer bugs — including three in the **shared baseline
runtime/JIT**, which corrects the earlier "no silent metamethod miscompiles"
note above:

- **FIXED `2910a30`/`13489d3`** — two -O1 type-inference elision unsoundnesses
  (metamethod result types; closure-captured loop var) + pre-existing
  SHRI/SHLI `__shl` dispatch.
- **FIXED `66f4b66`** — three baseline (-O0, also v1-JIT) fidelity bugs:
  (1) `Rt_ForPrep` skipped every integer loop with an out-of-int64 float limit
  (`for i = 1, math.huge` ran zero iterations) instead of truncating like
  lvm.c `forlimit()`; (2) imm/K arith helpers dispatched the wrong metamethod
  event/order (`x - 1` called `__add(x, -1)` instead of `__sub(x, 1)`; flipped
  `1 + x` lost operand order) — now `Rt_ArithIK` reads the trailing
  MMBINI/MMBINK; (3) LTI/LEI/GTI/GEI handed `__lt`/`__le` an integer immediate
  where lvm.c passes a float (`t < 2.0`) — now `Rt_OrderISlow` honors the isf
  flag. Regression tests: `tests/differential/aot_forlimit.lua`,
  `tests/differential/aot_mm_dispatch.lua` (run under both engines).

### Known bounded divergence (not a bug to fix per-test; use pcall in tests)

- **AOT-ERRBANNER-001** — an UNCAUGHT runtime error prints
  `clua: runtime error: <msg>` (no traceback) from a compiled exe, vs
  `clua-interp: <msg>` + `stack traceback: …` under `clua-interp -i`. The `<msg>` itself
  (including `source:line:` and operand annotations) matches. Differential
  tests must assert error behavior through `pcall` (messages compare exactly);
  byte-equality of the top-level banner is inherently impossible (different
  program names). A traceback-printing msghandler in the AOT entry would
  narrow (not close) this; tracked as a polish item.

### Round 6 (2026-06-10, post-`66f4b66`) — three more, FIXED in `80ec826`

- **Stale `L->top.p` in arith slow helpers** — every arith/bitwise/unary/len
  helper ran `luaO_arith`/`luaV_objlen` on whatever top was current and only
  restored the ceiling afterwards, so metamethod/error pushes clobbered live
  operand slots: `nil + 1` in a pcall'd closure reported "arithmetic on a
  **string** value"; `"hi" + 1` handed the string `__add` a **function**
  operand (value corruption). All 31 sites now raise top BEFORE dispatch
  (the pattern the order-compare helpers already used). Affected both engines.
- **`Rt_ArithIK` raw-op conflation** — `x - 0` (ADDI x,0 + MMBINI TM_SUB) must
  compute the ADDITION `x + (-0)` like lvm.c's ADDI arm (observable at
  `x = -0.0`); now split into `luaO_rawarith` (original opcode semantics) +
  `luaT_trybinTM` (MMBIN event, metamethods only).
- **`debug.setlocal` vs -O1 type proofs** — reflection can rewrite any live
  local, falsifying static INT/FLT proofs (a proven-int local set to 9.5
  printed garbage). Mitigation: any module carrying the string constant
  `"debug"` compiles with the typeinfer pass disabled (checked fastpaths,
  which re-verify tags at runtime, stay on).

Regression test: `tests/differential/aot_errpath_fidelity.lua` (both engines).

### Known bounded divergence (in addition to AOT-ERRBANNER-001)

- **AOT-DEBUGREFLECT-001** — a debug table fetched WITHOUT the literal string
  `"debug"` anywhere in the chunk (e.g. `_G["de".."bug"]`, `pairs(_G)`
  harvesting) evades the constant-scan guard, so `debug.setlocal` under such
  a chunk can still falsify -O1 type proofs. This is the standard optimizing-
  compiler reflection caveat (LuaJIT behaves analogously); a fully sound guard
  would require killing proofs on any dynamic `_ENV`/`_G` indexing. Documented,
  accepted at -O1; `-O0` is always reflection-exact.

- **AOT-CLOSEDWORLD-002** (2026-06-12) — compiled exes no longer link the Lua
  front-end: `aot_entry.c` defines closed-world stubs for `luaY_parser` /
  `luaU_undump` / `luaU_dump` / `luaX_init`, so ld never extracts
  lparser/lcode/llex/lundump/ldump from the archive (~34 KB text per exe). A
  program that EVADES the compile-time closed-world scan (e.g.
  `_G["lo".."ad"]`) gets a runtime loader error — `load(...)` returns
  `nil, "source chunk loading is disabled in a compiled CLua program (closed
  world)"` — where `clua-interp -i` would parse and run the chunk. Legal programs
  can never reach the stubs (`load`/`loadstring`/`dofile`/`string.dump` by
  name are compile errors), so this is a bounded divergence of the same class
  as AOT-DEBUGREFLECT-001. Guarded by tools/test-clua-cli.lua (asserts the
  exact stub message and a lean-exe size canary). Same date, same mechanism:
  emitted exes link `runtime-aot.a` (LUAC_AOT_RUNTIME), which carries the
  dispatch CACHE but no JIT compiler (codegen/emit_x64/regalloc excluded;
  the tail-call drive loop does lookup-only dispatch).

- **AOT-NODEBUG-001** (2026-06-12) — a compiled program whose chunks never
  carry the string constant `"debug"` links `lvm_nointerp.o` instead of the
  archive's full `lvm.o`: the bytecode interpreter loop (`clua_Interpret`,
  ~15 KB) is compiled out, because debug hooks — the only way the
  interpreter can become reachable in a closed-world exe — cannot be
  activated without the debug library. The scan is the SAME conservative
  constant scan that disables the -O1 type proofs (`lc_module_uses_debug`).
  Programs that mention debug keep the full interpreter and behave exactly
  like the oracle under `debug.sethook` (guarded by
  tests/differential/aot_debughooks.lua at O0/O1). A program that EVADES the
  scan (`_G["de".."bug"].sethook(...)`) FAILS FAST: the hook closure is the
  first thing dispatched through luaV_execute, so the exe exits 1 at the
  sethook site with `clua: runtime error: <src>:<line>: bytecode interpreter
  unavailable in this compiled CLua program (closed world: no 'debug'
  reference, so debug hooks cannot run)` — uncatchable by pcall (it fires
  inside the call-hook machinery), which is the desirable shape for an
  evader: loud, immediate, attributed. Same accepted class as
  AOT-DEBUGREFLECT-001/AOT-CLOSEDWORLD-002. Guarded by
  tools/test-clua-cli.lua (asserts the message + nonzero exit).
