# LuaC M0 Epsilon-Slice Bring-Up — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the entire LuaC AOT pipeline end-to-end and prove it with one differential-green binary: `aotc.exe hello.lua -o hello.exe` where `hello.lua` is `print("hello")`, and `hello.exe` stdout matches `luavm.exe -i hello.lua` exactly.

**Architecture:** Reuse the v1 front-end (`Resolve_Walk`) and the already-built runtime archives (`runtime-embedded.a`, `liblua54-embedded.a`) unchanged. Build the new backend IR-driven (decision #2): bytecode → memory-form IR (no SSA) → IR-driven x64 codegen that emits `Rt_*`/`luaV_*` calls as **REL32 relocations** into a growable byte buffer → a **COFF object** → link with MinGW `ld` (strategy B). At runtime, generated per-function bodies are dispatched through v1's existing `Proto*→entry` JIT side-cache, into which the AOT entry registers them at startup. Each function's `Proto` (constants/upvalues/nested, **not** executable bytecode) is reconstructed at startup by a generated **`ProtoInit`** — emitted as generated C for M0 (compiled by MinGW like v1's blob object), because hand-emitting Proto-graph construction is fiddly and low-value while the **function bodies remain genuine native codegen**.

**Tech Stack:** C99, MinGW-w64 (`x86_64-w64-mingw32-gcc`), GnuWin32 `make`, the v1 Lua 5.4 front-end + runtime, `tests/unit/test_harness.h` (C-unit), the differential runner (`tools/run-tests.lua`).

**Reference (read once before starting):** the approved design
[`docs/superpowers/specs/2026-06-09-luac-m0-vertical-slice-design.md`](../specs/2026-06-09-luac-m0-vertical-slice-design.md);
and `PROMPT.md` §5–§12. v1 lowering reference: `src/jit/codegen.c`
(`EmitPrologue`:136, `EmitEpilogue`:179, `EmitReloadRdiAndCache`:229,
`EmitStoreSavedPc`:253, `Lower_GetTabUp`:357, `Lower_LoadK`:353, `Lower_Call`:347,
`Lower_Return`:348/`Return0`:349/`Return1`:350, `Lower_VarargPrep`:418), dispatch
(`src/jit/dispatch.c`: `g_Cache`, `Jit_LookupCached`:176, `Jit_Compile`:198), encoder
(`src/jit/emit_x64.h`), bootstrap (`src/runtime/runtime_init.c` `RuntimeMain`).

---

## Conventions baked into every task

- **Frame ABI (from v1, do not change):** `RBX`=`lua_State* L`; `RDI`=Lua register base
  (`ci->func.p + 16`); Lua register `N` at `[RDI + N*16]` (value at +0, tag byte at +8).
  **Tag tests use 8-bit CMP.** Callee-saved cache regs: `R12,R13,R14,R15,RSI`. Prologue
  pushes `RDI,RBX,R12,R13,R14,R15,RSI` then `SUB RSP,0x20`; 96-byte frame, 16-aligned at
  calls. Helper ABI: `RCX`=L, `RDX/R8/R9`=A/B/C, `RAX`=ret.
- **Native entry signature:** `int luac_fn_<id>(lua_State *L)` returning the Lua result
  count — identical to v1's `JIT_FUNC_T` (`int(*)(lua_State*)`).
- **Build:** from PowerShell, `cmd /c "build\build.bat <target>"`; never run `make` from
  bash. New AOT targets live in `build/Makefile.luac`, invoked by a new
  `build\build-luac.bat` wrapper (mirrors `build.bat`'s PATH setup).
- **Run the suite:** `cmd /c "build\run-tests.bat"` (full) or, when products are built,
  `build\bin\luavm.exe tools\run-tests.lua`.
- **Commit cadence:** one commit per task (per the steps). Branch first — work on
  `luac-m0-epsilon`, never commit M0 work to `main` directly.

```bash
git checkout -b luac-m0-epsilon
```

---

## File-structure map (what this plan creates / modifies)

| Path | Responsibility |
|---|---|
| `src/codegen/x64_emit.{h,c}` | **Create** — copy of `src/jit/emit_x64.*` adapted to emit into a plain `LcCodeBuf` and to record `LcReloc`s (new `X64Emit_CallSym`, `X64Emit_LeaRipSym`) |
| `src/codegen/lc_codebuf.{h,c}` | **Create** — growable byte buffer + reloc list (`LcCodeBuf`, `LcReloc`) |
| `src/codegen/codegen.c` | **Implement** — IR-driven lowering for the epsilon op set (port the cited `Lower_*` bodies onto `LcCodeBuf`) |
| `src/ir/ir.{h,c}` | **Implement/extend** — memory-form IR builders; add pre-SSA bytecode-operand carrier to `LcInst` |
| `src/ir/lift.c` | **Implement** — bytecode → memory-form IR for the epsilon op set |
| `src/link/coff_write.{h,c}` | **Create** — emit one COFF object (`.text`/`.rdata`, symbols, relocations from `LcReloc`) |
| `src/link/pe_link_v2.{h,c}` | **Create** (strip from `pe_link.c`) — `LuacLink_LinkUserObject(...)` reusing the MinGW link line |
| `src/runtime/aot_entry.c` | **Create** (strip from `runtime_init.c`) — AOT `main`: state setup, run `ProtoInit_*`, register entries, invoke entry under protection |
| `src/jit/dispatch.c` | **Modify** — add `Jit_RegisterCompiled(Proto*, JIT_FUNC_T)` (insert an external entry into `g_Cache`) |
| `src/jit/dispatch.h` | **Modify** — declare `Jit_RegisterCompiled` |
| `src/driver/main.c` | **Implement** — `lc_drive` wiring + argv parse + closed-world gate + `luaU_undump` |
| `src/driver/closed_world.{h,c}` | **Create** — reject dynamic `require`/`load`/`loadstring`/`dofile`/`string.dump` |
| `build/Makefile.luac`, `build/build-luac.bat` | **Create** — build `aotc.exe`; per-program codegen→coff→link |
| `tests/unit/test_lc_codebuf.c`, `test_lc_coff.c`, `test_lc_lift.c`, `test_lc_dispatch_spike.c` | **Create** — C-unit tests |
| `tests/differential/aot_epsilon.lua` + AOT differential runner hook | **Create** — the gate |

---

## Phase 0 — De-risk spikes (prove the unknowns in isolation)

### Task 1: Dispatch-registration spike

**Files:**
- Create: `tests/unit/test_lc_dispatch_spike.c`
- Modify: `src/jit/dispatch.c`, `src/jit/dispatch.h`

- [ ] **Step 1: Add the registration API declaration**

In `src/jit/dispatch.h`, after the `Jit_Compile` declaration (line ~23), add:

```c
/* Register an externally-generated native entry for Proto P in the dispatch
 * cache, exactly as Jit_Compile would after codegen. Used by AOT startup
 * (ProtoInit) so the existing Rt_Call -> Jit_LookupCached path invokes the
 * AOT body with no JIT present. Returns 1 on success, 0 if the cache is full
 * or P is already registered. */
int Jit_RegisterCompiled( Proto *P, JIT_FUNC_T Entry );
```

- [ ] **Step 2: Implement it (mirror the tail of `Jit_Compile`, minus codegen)**

In `src/jit/dispatch.c`, after `Jit_Compile` (ends line 254), add:

```c
int Jit_RegisterCompiled( Proto *P, JIT_FUNC_T Entry ) {
    if ( P == NULL || Entry == NULL ) { return 0; }
    if ( CacheFind( P ) != NULL ) { return 1; }          /* idempotent */
    if ( g_CacheCount >= JIT_CACHE_MAX ) {
        fprintf( stderr, "[-] jit: cache full (aot register)\n" );
        return 0;
    }
    JIT_CACHE_ENTRY_T *Slot = &g_Cache[ g_CacheCount ];
    memset( Slot, 0, sizeof( *Slot ) );
    Slot->P          = P;
    Slot->Entry      = Entry;          /* points into the PE .text, not exec-mem */
    Slot->PcToOffset = NULL;           /* no pc-map for AOT bodies (M0) */
    Slot->PcCount    = P->sizecode;
    CacheHashInsert( ( int32_t )g_CacheCount, P );
    g_CacheCount++;
    return 1;
}
```

- [ ] **Step 3: Write the spike test (hand-build a Proto, register a C body, dispatch through `Rt_Call`)**

Create `tests/unit/test_lc_dispatch_spike.c`. This proves a registered entry is invoked by
the call path with no JIT. Use the harness; build a minimal vararg main Proto with a single
`OP_RETURN0`, register a C function as its entry, push a closure, and call via the public
`luaD_call` (the same path `Rt_Call` uses). Assert the C body ran.

```c
#include "tests/unit/test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "lfunc.h"
#include "ldo.h"
#include "jit/dispatch.h"

static int g_BodyRan = 0;

static int SpikeBody( lua_State *L ) {
    (void)L;
    g_BodyRan = 1;
    return 0;            /* zero results */
}

TEST_BEGIN( "lc_dispatch_spike" )
    lua_State *L = luaL_newstate();
    CHECK( L != NULL );

    /* Build a trivial Proto: one RETURN0, no constants, vararg main shape. */
    Proto *P = luaF_newproto( L );
    P->numparams = 0; P->is_vararg = 1; P->maxstacksize = 2;
    P->sizecode = 1;
    P->code = luaM_newvector( L, 1, Instruction );
    P->code[0] = CREATE_ABC( OP_RETURN0, 0, 1, 0 );

    /* Register our C body as P's compiled entry. */
    CHECK( Jit_RegisterCompiled( P, SpikeBody ) == 1 );
    CHECK( Jit_LookupCached( P ) == SpikeBody );

    /* Wrap P in a closure, push it, and call it through the normal call path. */
    LClosure *Cl = luaF_newLclosure( L, 0 );
    Cl->p = P;
    setclLvalue2s( L, L->top.p, Cl );
    L->top.p++;
    luaD_callnoyield( L, L->top.p - 1, 0 );

    CHECK( g_BodyRan == 1 );
    lua_close( L );
TEST_END()
```

> Note: confirm the exact macro names (`CREATE_ABC`, `setclLvalue2s`) against
> `lua-5.4/src/lopcodes.h` / `lobject.h` when wiring; adjust if the tree differs. The
> point of the spike is the dispatch path, not the macros.

- [ ] **Step 4: Build + run the unit suite, verify the spike passes**

Run: `cmd /c "build\run-tests.bat"`
Expected: tally shows the new `lc_dispatch_spike` among `[PASS]`; no `[FAIL]`. If the call
path does **not** route through `Jit_LookupCached` for a freshly-built closure (e.g. it only
checks the cache on a second call), record the actual trigger point in a comment and adjust
the AOT entry (Task 16) to match — this is exactly the fact the spike exists to pin down.

- [ ] **Step 5: Commit**

```bash
git add src/jit/dispatch.c src/jit/dispatch.h tests/unit/test_lc_dispatch_spike.c
git commit -m "spike(luac): register AOT entries into the JIT dispatch cache"
```

### Task 2: COFF-object + link spike

**Files:**
- Create: `tests/unit/test_lc_coff_spike.c` (throwaway harness, kept as a regression)

- [ ] **Step 1: Write a spike that hand-builds a COFF `.o` calling one `Rt_*` helper, links it, runs it**

The point: lock down the COFF target format (`IMAGE_FILE_HEADER` machine `0x8664`, one
`.text` section, one defined symbol `luac_fn_spike`, one external symbol `Rt_Len`, one
`IMAGE_REL_AMD64_REL32` relocation on the call site) and prove MinGW `ld` links it against
`runtime-embedded.a`. Implement `WriteSpikeObj(path)` that writes the bytes for a function
that does `xor eax,eax; ret` plus a relocated `call Rt_Len` it never reaches (reloc presence
is what we test). Then shell out:

```c
/* test body (sketch): */
WriteSpikeObj( "build\\tmp\\spike.o" );
int rc = system( "x86_64-w64-mingw32-gcc build\\tmp\\spike.o "
                 "build\\bin\\runtime-embedded.a build\\bin\\liblua54-embedded.a "
                 "-o build\\tmp\\spike_probe.exe -lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi "
                 "-Wl,--unresolved-symbols=report-all" );
CHECK( rc == 0 );   /* link succeeded => COFF format + reloc accepted, Rt_Len resolved */
```

- [ ] **Step 2: Run it**

Run: `cmd /c "build\run-tests.bat"`
Expected: `lc_coff_spike` PASS. A link failure here means the COFF header/section/symbol/
reloc layout is wrong — fix `WriteSpikeObj` until `ld` accepts it. **This format is the
spec the real COFF writer (Task 13) implements.**

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_lc_coff_spike.c
git commit -m "spike(luac): hand-built COFF .o links against runtime archives"
```

### Task 3: CallInfo / entry-invocation spike

**Files:**
- Create: `tests/unit/test_lc_callinfo_spike.c`

- [ ] **Step 1: Replicate v1's pre-invocation `CallInfo` setup and call a trivial native body**

Read `src/runtime/runtime_init.c` lines ~553–599 (the block that sets `L->ci->func.p`,
`ci->top.p`, `L->top.p` and calls the jitted entry under `luaD_rawrunprotected` /
`Jit_TrampolineEntry`). Reproduce the minimal version: push a closure over a 1-op Proto
whose registered entry calls `lua_pushinteger(L, 42)` and returns 1; invoke it the way the
entry will (Task 16); assert the returned value is 42.

```c
static int Body42( lua_State *L ) { lua_pushinteger( L, 42 ); return 1; }
/* ... build Proto+closure, Jit_RegisterCompiled(P, Body42), set up CallInfo
   per runtime_init.c:553-599, luaD_callnoyield, CHECK lua_tointeger(L,-1)==42 */
```

- [ ] **Step 2: Run; record the exact CallInfo fields the body relies on**

Run: `cmd /c "build\run-tests.bat"`
Expected: `lc_callinfo_spike` PASS. Document in a comment which `ci`/`L->top` fields must be
set before invoking a native body — Task 16 copies this verbatim.

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_lc_callinfo_spike.c
git commit -m "spike(luac): native-entry CallInfo setup mirrors v1 trampoline"
```

---

## Phase 1 — Backend scaffolding

### Task 4: `LcCodeBuf` (growable byte buffer + reloc list)

**Files:**
- Create: `src/codegen/lc_codebuf.h`, `src/codegen/lc_codebuf.c`
- Test: `tests/unit/test_lc_codebuf.c`

- [ ] **Step 1: Write the failing test**

```c
#include "tests/unit/test_harness.h"
#include "codegen/lc_codebuf.h"

TEST_BEGIN( "lc_codebuf" )
    LcCodeBuf B;
    CHECK( LcCodeBuf_Init( &B, 4 ) == 1 );
    uint8_t three[3] = { 0x90, 0x91, 0x92 };
    CHECK( LcCodeBuf_Append( &B, three, 3 ) == 1 );
    CHECK( LcCodeBuf_Append( &B, three, 3 ) == 1 );   /* forces a grow past cap 4 */
    CHECK( B.used == 6 );
    CHECK( B.bytes[4] == 0x91 );
    CHECK( LcCodeBuf_AddReloc( &B, LC_RELOC_REL32, 1, "Rt_Len", 0 ) == 1 );
    CHECK( B.nrelocs == 1 );
    CHECK( B.relocs[0].offset == 1 );
    LcCodeBuf_Free( &B );
TEST_END()
```

- [ ] **Step 2: Run, verify it fails (no such header)**

Run: `cmd /c "build\run-tests.bat"`
Expected: build error / FAIL — `codegen/lc_codebuf.h` not found.

- [ ] **Step 3: Implement the header**

```c
/* src/codegen/lc_codebuf.h */
#ifndef LUAC_CODEGEN_LC_CODEBUF_H
#define LUAC_CODEGEN_LC_CODEBUF_H
#include <stddef.h>
#include <stdint.h>

typedef enum {
    LC_RELOC_REL32,   /* IMAGE_REL_AMD64_REL32: disp32 at offset, vs symbol  */
    LC_RELOC_ADDR64,  /* IMAGE_REL_AMD64_ADDR64: abs64 at offset, vs symbol  */
    LC_RELOC_REL32_RDATA  /* REL32 against a .rdata local symbol (RIP-rel)   */
} LcRelocKind;

typedef struct {
    LcRelocKind kind;
    uint32_t    offset;   /* byte offset within .bytes of the field to patch */
    char        symbol[64];
    int32_t     addend;
} LcReloc;

typedef struct {
    uint8_t *bytes; size_t used, cap;
    LcReloc *relocs; size_t nrelocs, relocap;
} LcCodeBuf;

int  LcCodeBuf_Init  ( LcCodeBuf *b, size_t cap );
int  LcCodeBuf_Append( LcCodeBuf *b, const uint8_t *p, size_t n );
int  LcCodeBuf_AddReloc( LcCodeBuf *b, LcRelocKind k, uint32_t off, const char *sym, int32_t addend );
void LcCodeBuf_Free  ( LcCodeBuf *b );
#endif
```

- [ ] **Step 4: Implement the source**

```c
/* src/codegen/lc_codebuf.c */
#include "codegen/lc_codebuf.h"
#include <stdlib.h>
#include <string.h>

int LcCodeBuf_Init( LcCodeBuf *b, size_t cap ) {
    memset( b, 0, sizeof( *b ) );
    if ( cap < 16 ) cap = 16;
    b->bytes = ( uint8_t * )malloc( cap );
    if ( !b->bytes ) return 0;
    b->cap = cap;
    return 1;
}
int LcCodeBuf_Append( LcCodeBuf *b, const uint8_t *p, size_t n ) {
    if ( b->used + n > b->cap ) {
        size_t nc = b->cap ? b->cap : 16;
        while ( nc < b->used + n ) nc *= 2;
        uint8_t *nb = ( uint8_t * )realloc( b->bytes, nc );
        if ( !nb ) return 0;
        b->bytes = nb; b->cap = nc;
    }
    memcpy( b->bytes + b->used, p, n );
    b->used += n;
    return 1;
}
int LcCodeBuf_AddReloc( LcCodeBuf *b, LcRelocKind k, uint32_t off, const char *sym, int32_t addend ) {
    if ( b->nrelocs == b->relocap ) {
        size_t nc = b->relocap ? b->relocap * 2 : 8;
        LcReloc *nr = ( LcReloc * )realloc( b->relocs, nc * sizeof( LcReloc ) );
        if ( !nr ) return 0;
        b->relocs = nr; b->relocap = nc;
    }
    LcReloc *r = &b->relocs[ b->nrelocs++ ];
    r->kind = k; r->offset = off; r->addend = addend;
    memset( r->symbol, 0, sizeof( r->symbol ) );
    strncpy( r->symbol, sym, sizeof( r->symbol ) - 1 );
    return 1;
}
void LcCodeBuf_Free( LcCodeBuf *b ) {
    free( b->bytes ); free( b->relocs );
    memset( b, 0, sizeof( *b ) );
}
```

- [ ] **Step 5: Wire into the test build + Makefile, run, verify PASS**

Add `src/codegen/lc_codebuf.c` to the `libluavmtest.a` source list in `build/Makefile`
(find the `*_TEST_SRCS`/codegen glob; if tests auto-discover `tests/unit/test_*.c`, the
support `.c` still needs listing). Run: `cmd /c "build\run-tests.bat"` → `lc_codebuf` PASS.

- [ ] **Step 6: Commit**

```bash
git add src/codegen/lc_codebuf.* tests/unit/test_lc_codebuf.c build/Makefile
git commit -m "feat(luac): LcCodeBuf growable code buffer + reloc list"
```

### Task 5: `x64_emit` — copy v1 encoder, retarget to `LcCodeBuf`, add reloc emitters

**Files:**
- Create: `src/codegen/x64_emit.h`, `src/codegen/x64_emit.c` (from `src/jit/emit_x64.*`)
- Test: extend `tests/unit/test_lc_codebuf.c` (or new `test_lc_x64emit.c`)

- [ ] **Step 1: Copy and mechanically retarget**

Copy `src/jit/emit_x64.h` → `src/codegen/x64_emit.h` and `src/jit/emit_x64.c` →
`src/codegen/x64_emit.c`. Mechanical change: replace the buffer parameter type
`PEXEC_MEM_SLOT_T Slot` with `LcCodeBuf *Buf` throughout, and replace the byte-append idiom
(`Slot->Code[Slot->Used++] = b;` / capacity checks) with `LcCodeBuf_Append(Buf, &b, 1)` (or
a small `static int Emit1(LcCodeBuf*,uint8_t)` helper). Rename the public prefix
`EmitX64_` → `X64Emit_` to avoid clashing with the still-linked v1 `emit_x64`. Keep ModR/M /
SIB / REX / rel8 / rel32 logic **byte-for-byte identical**. Drop `#include "jit/exec_mem.h"`.

- [ ] **Step 2: Add the two AOT-only emitters (declarations)**

In `src/codegen/x64_emit.h`, add:

```c
/* CALL rel32 to an external symbol. Emits E8 <disp32=0> and records an
 * LC_RELOC_REL32 against `Sym` at the disp32 offset. The linker resolves it. */
int X64Emit_CallSym( LcCodeBuf *Buf, const char *Sym );

/* LEA Dst, [RIP + disp32] referencing a .rdata local symbol. Emits 48 8D /r
 * with disp32=0 and records LC_RELOC_REL32_RDATA against `Sym`. */
int X64Emit_LeaRipSym( LcCodeBuf *Buf, X64_GPR_T Dst, const char *Sym );
```

- [ ] **Step 3: Implement them**

```c
int X64Emit_CallSym( LcCodeBuf *Buf, const char *Sym ) {
    uint8_t op = 0xE8;
    if ( !LcCodeBuf_Append( Buf, &op, 1 ) ) return 0;
    uint32_t at = ( uint32_t )Buf->used;            /* disp32 starts here */
    uint8_t z4[4] = { 0, 0, 0, 0 };
    if ( !LcCodeBuf_Append( Buf, z4, 4 ) ) return 0;
    /* REL32 addend is -4: disp is relative to the END of the instruction. */
    return LcCodeBuf_AddReloc( Buf, LC_RELOC_REL32, at, Sym, -4 );
}

int X64Emit_LeaRipSym( LcCodeBuf *Buf, X64_GPR_T Dst, const char *Sym ) {
    /* 48 8D /r  ModRM = mod=00 reg=Dst rm=101 (RIP-relative) */
    uint8_t rex = ( uint8_t )( 0x48 | ( ( Dst >= X64_R8 ) ? 0x04 : 0x00 ) );
    uint8_t opc = 0x8D;
    uint8_t modrm = ( uint8_t )( 0x00 | ( ( Dst & 7 ) << 3 ) | 0x05 );
    uint8_t pre[3] = { rex, opc, modrm };
    if ( !LcCodeBuf_Append( Buf, pre, 3 ) ) return 0;
    uint32_t at = ( uint32_t )Buf->used;
    uint8_t z4[4] = { 0, 0, 0, 0 };
    if ( !LcCodeBuf_Append( Buf, z4, 4 ) ) return 0;
    return LcCodeBuf_AddReloc( Buf, LC_RELOC_REL32_RDATA, at, Sym, -4 );
}
```

- [ ] **Step 4: Test the two emitters produce the expected bytes + relocs**

```c
TEST_BEGIN( "lc_x64emit_callsym" )
    LcCodeBuf B; LcCodeBuf_Init( &B, 16 );
    CHECK( X64Emit_CallSym( &B, "Rt_Len" ) == 1 );
    CHECK( B.used == 5 );
    CHECK( B.bytes[0] == 0xE8 );
    CHECK( B.nrelocs == 1 && B.relocs[0].kind == LC_RELOC_REL32 && B.relocs[0].offset == 1 );
    CHECK( X64Emit_LeaRipSym( &B, X64_RAX, "k0_str" ) == 1 );
    CHECK( B.bytes[5] == 0x48 && B.bytes[6] == 0x8D && B.bytes[7] == 0x05 );
    CHECK( B.nrelocs == 2 && B.relocs[1].kind == LC_RELOC_REL32_RDATA );
    LcCodeBuf_Free( &B );
TEST_END()
```

- [ ] **Step 5: Build, run, verify PASS; commit**

Add `src/codegen/x64_emit.c` to `libluavmtest.a` sources. Run `cmd /c "build\run-tests.bat"`.

```bash
git add src/codegen/x64_emit.* tests/unit/test_lc_x64emit.c build/Makefile
git commit -m "feat(luac): x64_emit (retargeted encoder) + CallSym/LeaRipSym reloc emitters"
```

---

## Phase 2 — Front-end wiring & closed-world gate

### Task 6: Closed-world gate (reject load/dofile/dynamic-require)

**Files:**
- Create: `src/driver/closed_world.h`, `src/driver/closed_world.c`
- Test: `tests/unit/test_lc_closed_world.c`

- [ ] **Step 1: Write the failing test**

Two `Proto`s built from source via `luaL_loadstring` (which gives a closure → `Proto`):
`local x = require("json")` (static require — **allowed**) vs `load("return 1")` (**rejected**).

```c
#include "tests/unit/test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "driver/closed_world.h"

static Proto *ProtoOf( lua_State *L, const char *src ) {
    luaL_loadstring( L, src );
    return ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
}

TEST_BEGIN( "lc_closed_world" )
    lua_State *L = luaL_newstate(); luaL_openlibs( L );
    char err[256];
    CHECK( Lc_CheckClosedWorld( ProtoOf( L, "local t = require('json'); return t" ), err, sizeof err ) == 1 );
    CHECK( Lc_CheckClosedWorld( ProtoOf( L, "return load('return 1')" ),            err, sizeof err ) == 0 );
    CHECK( Lc_CheckClosedWorld( ProtoOf( L, "dofile('x.lua')" ),                    err, sizeof err ) == 0 );
    lua_close( L );
TEST_END()
```

- [ ] **Step 2: Run, verify it fails (no header)**

Run: `cmd /c "build\run-tests.bat"` → FAIL (header missing).

- [ ] **Step 3: Implement the scanner**

Scan `P->code` recursively (into `P->p[]`). For each `OP_GETTABUP` whose upvalue is `_ENV`
and whose constant key is one of `load`/`loadstring`/`dofile` → reject. For
`string.dump`: an `OP_GETFIELD` with key `"dump"` whose base traces to the `string` global —
M0 takes the conservative form: reject any `OP_GETFIELD`/`OP_GETTABUP` with constant key
`"dump"`. Dynamic `require(var)` reuses the v1 detection: a `GETTABUP _ENV "require"` **not**
followed by `OP_LOADK` (mirror `resolve.c:104-110`).

```c
/* src/driver/closed_world.h */
#ifndef LUAC_DRIVER_CLOSED_WORLD_H
#define LUAC_DRIVER_CLOSED_WORLD_H
#include <stddef.h>
struct Proto;
/* Returns 1 if P (and all nested protos) are closed-world-safe; 0 + writes a
 * gcc-style message into Err otherwise. */
int Lc_CheckClosedWorld( struct Proto *P, char *Err, size_t ErrLen );
#endif
```

```c
/* src/driver/closed_world.c */
#include "driver/closed_world.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lstring.h"
#include <string.h>
#include <stdio.h>

static int IsName( const TValue *K, const char *Name ) {
    return ttisstring( K ) && strcmp( getstr( tsvalue( K ) ), Name ) == 0;
}

static int ScanProto( Proto *P, char *Err, size_t ErrLen ) {
    int i;
    for ( i = 0; i < P->sizecode; i++ ) {
        Instruction op = P->code[i];
        int oc = GET_OPCODE( op );
        if ( oc == OP_GETTABUP ) {
            const TValue *K = &P->k[ GETARG_C( op ) ];
            const char *banned[] = { "load", "loadstring", "dofile", NULL };
            int b;
            for ( b = 0; banned[b]; b++ ) {
                if ( IsName( K, banned[b] ) ) {
                    snprintf( Err, ErrLen, "error: %s() is not permitted in an "
                              "AOT-compiled program (closed world)", banned[b] );
                    return 0;
                }
            }
            if ( IsName( K, "require" ) ) {
                if ( i + 1 >= P->sizecode || GET_OPCODE( P->code[i + 1] ) != OP_LOADK ) {
                    snprintf( Err, ErrLen, "error: dynamic require(<non-constant>) is not "
                              "resolvable in an AOT-compiled program (closed world)" );
                    return 0;
                }
            }
        }
        if ( ( oc == OP_GETFIELD || oc == OP_GETTABUP ) && IsName( &P->k[ GETARG_C( op ) ], "dump" ) ) {
            snprintf( Err, ErrLen, "error: string.dump is not permitted in an "
                      "AOT-compiled program (closed world)" );
            return 0;
        }
    }
    { int j; for ( j = 0; j < P->sizep; j++ ) if ( !ScanProto( P->p[j], Err, ErrLen ) ) return 0; }
    return 1;
}

int Lc_CheckClosedWorld( Proto *P, char *Err, size_t ErrLen ) {
    if ( Err && ErrLen ) Err[0] = 0;
    return ScanProto( P, Err, ErrLen );
}
```

- [ ] **Step 4: Build, run, verify PASS; commit**

```bash
git add src/driver/closed_world.* tests/unit/test_lc_closed_world.c build/Makefile
git commit -m "feat(luac): closed-world gate rejects load/dofile/string.dump/dynamic-require"
```

### Task 7: `undump` reachable modules to `Proto*`

**Files:**
- Create: `src/driver/lc_undump.h`, `src/driver/lc_undump.c`
- Test: `tests/unit/test_lc_undump.c`

- [ ] **Step 1: Failing test** — compile a source to bytes via `lua_dump`, undump, assert opcode count.

```c
TEST_BEGIN( "lc_undump" )
    lua_State *L = luaL_newstate();
    luaL_loadstring( L, "return 1 + 2" );
    /* dump to a buffer */
    luaL_Buffer b; ... use lua_dump with a writer ...
    Proto *P = Lc_Undump( L, bytes, len );
    CHECK( P != NULL );
    CHECK( P->sizecode > 0 );
    lua_close( L );
TEST_END()
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement** — wrap `luaU_undump` (the internal API resolve.c already relies
on indirectly). Mirror `resolve.c:188-196`: `luaL_loadbufferx(L, bytes, len, "@aot", "b")`
then `Proto *P = clLvalue(s2v(L->top.p-1))->p;`. Return `P` (kept alive by the closure on
the stack — caller must not pop until done; M0 keeps the loader `L` alive for the whole
compile).

```c
/* src/driver/lc_undump.c */
#include "driver/lc_undump.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"

Proto *Lc_Undump( lua_State *L, const unsigned char *Bytes, size_t Len ) {
    if ( luaL_loadbufferx( L, ( const char * )Bytes, Len, "@aot", "b" ) != LUA_OK )
        return NULL;
    return ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;   /* stays on L's stack */
}
```

- [ ] **Step 4: Run, verify PASS; commit.**

```bash
git add src/driver/lc_undump.* tests/unit/test_lc_undump.c build/Makefile
git commit -m "feat(luac): undump resolved module bytes to Proto*"
```

---

## Phase 3 — Lift (memory-form IR, epsilon op set)

### Task 8: Extend `ir.h` with the pre-SSA operand carrier

**Files:**
- Modify: `src/ir/ir.h`, `src/ir/ir.c`

- [ ] **Step 1: Add the M0 fields to `LcInst` and an `is_ssa` flag to `LcFunc`**

In `src/ir/ir.h`, extend `LcInst` (keep existing SSA fields untouched for M1):

```c
/* M0 memory-form: instructions carry their originating bytecode operands so
 * codegen can emit Rt_*/luaV_* calls by register index without SSA values.
 * (M1's mem2reg introduces LcValue defs + phis and sets func->is_ssa = true.) */
struct LcInst {
    LcOpcode op;
    int      bc_pc;          /* originating bytecode pc (already present)       */
    int      a, b, c;        /* NEW: decoded A/B/C (or Bx in `a`, sBx in `b`)   */
    uint32_t flags;          /* LcEffect bitset                                 */
    /* ... existing SSA fields (args/result/...) remain; unused in M0 ...        */
    LcInst  *next, *prev;
};
```

Add `bool is_ssa;` to `LcFunc` (default `false` after lift). The verifier (`lc_module_verify`)
gains a pre-SSA branch: when `!is_ssa`, skip single-def/dominance/phi-arity checks; still
assert CFG well-formedness and "no `LC_OP_CALL_FFI` is `LC_FX_PURE`".

- [ ] **Step 2: Implement the IR builders that were stubs**

In `src/ir/ir.c`, implement `lc_func_new` (allocate, set `source=P`, `is_ssa=false`),
`lc_block_new`, `lc_emit` (append an `LcInst` to a block), and a new
`lc_emit_bc(LcBlock*, LcOpcode, int a, int b, int c, int bc_pc)`. Keep arena/bump allocation
or simple `malloc`/free-list; M0 prioritizes clarity.

- [ ] **Step 3: Unit-test the builders** (`tests/unit/test_lc_ir.c`): create a module, a func,
a block, emit two `lc_emit_bc` insts, assert linkage + `is_ssa == false`. Run → PASS.

- [ ] **Step 4: Commit.**

```bash
git add src/ir/ir.* tests/unit/test_lc_ir.c build/Makefile
git commit -m "feat(luac): memory-form IR builders + pre-SSA LcInst operand carrier"
```

### Task 9: Lift the epsilon op set

**Files:**
- Implement: `src/ir/lift.c`
- Test: `tests/unit/test_lc_lift.c`

The epsilon op set (what `print("hello")` compiles to): `OP_VARARGPREP`, `OP_GETTABUP`,
`OP_LOADK`, `OP_CALL`, `OP_RETURN`/`OP_RETURN0`/`OP_RETURN1`. (Verify with
`luavm.exe -e 'local f=load("print(\"hello\")"); ...'` or by dumping; the main chunk is
vararg, so it begins with `VARARGPREP` and ends with `RETURN`.)

- [ ] **Step 1: Failing test** — undump `print("hello")`, lift, assert the IR block holds one
inst per bytecode op in order, with correct opcodes and operands.

```c
TEST_BEGIN( "lc_lift_epsilon" )
    lua_State *L = luaL_newstate();
    /* dump+undump print("hello") -> Proto *P (reuse Lc_Undump) */
    LcModule *M = lc_module_new();
    LcFunc *F = lc_func_new( M, P );
    lc_lift_func( F );
    CHECK( F->is_ssa == 0 );
    /* first inst is the VARARGPREP-derived op; a GLOBAL_GET for print exists;
       a CONST/LOADK for "hello"; a CALL; a RETURN. */
    CHECK( lc_func_has_op( F, LC_OP_GLOBAL_GET ) );
    CHECK( lc_func_has_op( F, LC_OP_CALL ) );
    CHECK( lc_func_has_op( F, LC_OP_RETURN ) );
    lua_close( L );
TEST_END()
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Implement `lc_lift_program` + `lc_lift_func`** — for M0, **single basic block
is enough** for the epsilon slice (no branches), but implement the general CFG split now so
later ops don't need a rewrite:
  1. `lc_lift_program`: for each reachable `Proto` (entry + recursively `p[]`), `lc_func_new`;
     set `m->entry` to the entry func; call `lc_lift_func` on each.
  2. `lc_lift_func`: compute basic-block leaders (pc 0; every jump target; every pc after a
     branch), create `LcBlock`s, then walk `P->code`, emitting one generic `LcInst` per op
     via `lc_emit_bc`, mapping opcode→`LcOpcode` per the PROMPT §8 table. For the epsilon set:
     `OP_VARARGPREP`→`LC_OP_VARARG` (prep marker; M0 carries it through), `OP_GETTABUP` with
     upvalue `_ENV`→`LC_OP_GLOBAL_GET` (else `LC_OP_TABLE_GET`), `OP_LOADK`→`LC_OP_CONST`,
     `OP_CALL`→`LC_OP_CALL`, `OP_RETURN*`→`LC_OP_RETURN`. Record call-graph edges on
     `LC_OP_CALL` (sentinel for unknown callee). No folding, no typing.

- [ ] **Step 4: Run, verify PASS.**

- [ ] **Step 5: Commit.**

```bash
git add src/ir/lift.c tests/unit/test_lc_lift.c
git commit -m "feat(luac): lift bytecode to memory-form IR (epsilon op set + CFG skeleton)"
```

---

## Phase 4 — Codegen (epsilon op set)

> Strategy: the IR-driven codegen mirrors v1's `Lower_*` emit sequences but (a) emits into an
> `LcCodeBuf` via `X64Emit_*`, (b) replaces every baked helper address with `X64Emit_CallSym`
> against the helper's symbol name, and (c) drives off the IR `LcInst` (which carries the
> bytecode operands) instead of re-decoding `P->code`. The per-op byte sequences are
> authoritative in `src/jit/codegen.c` at the cited lines — port them, don't reinvent.

### Task 10: Prologue, epilogue, helper-call helper, savedpc

**Files:**
- Implement (part of): `src/codegen/codegen.c`
- Test: `tests/unit/test_lc_codegen_frame.c`

- [ ] **Step 1: Port the frame scaffolding onto `LcCodeBuf`** — translate `EmitPrologue`
(`codegen.c:136-172`), `EmitEpilogue` (`179-190`), `EmitRestoreL` (`194`),
`EmitReloadRdiAndCache` (`229-237`) using `X64Emit_*`. For M0, **disable the regalloc cache**
(treat all Lua regs as memory-resident: `RegAlloc_Analyse` may still run, but emit
load/store against `[RDI+N*16]` only) to keep the first slice simple — cache slots are an M1
speedup, not correctness. So the prologue pushes the 7 callee-saved regs (to keep the frame
shape / unwind identical) but skips the cache-preload loop.

- [ ] **Step 2: Implement the helper-call shim**

```c
/* Emit: MOV RCX,RBX ; MOV RDX,imm(a) ; MOV R8,imm(b) ; MOV R9,imm(c) ;
 *       CALL <sym>(rel32 reloc) ; then optionally reload RDI+cache.        */
static int EmitHelperCall3( LcCodeBuf *B, const char *Sym,
                            int a, int b, int c, int ReloadAfter ) {
    if ( !X64Emit_MovRegToReg( B, X64_RCX, X64_RBX ) ) return 0;          /* L     */
    if ( !X64Emit_MovImm64ToReg( B, X64_RDX, ( uint64_t )( int64_t )a ) ) return 0;
    if ( !X64Emit_MovImm64ToReg( B, X64_R8,  ( uint64_t )( int64_t )b ) ) return 0;
    if ( !X64Emit_MovImm64ToReg( B, X64_R9,  ( uint64_t )( int64_t )c ) ) return 0;
    if ( !X64Emit_CallSym( B, Sym ) ) return 0;
    if ( ReloadAfter && !EmitReloadRdiAndCache( B ) ) return 0;
    return 1;
}
```

- [ ] **Step 3: Test** — emit prologue+epilogue into a buffer, assert the byte length and the
first/last opcodes match v1's (`PUSH RDI` = `0x57`, `SUB RSP,0x20`, … `RET` = `0xC3`). Run →
PASS.

- [ ] **Step 4: Commit.**

```bash
git add src/codegen/codegen.c tests/unit/test_lc_codegen_frame.c
git commit -m "feat(luac): codegen frame scaffolding + helper-call shim on LcCodeBuf"
```

### Task 11: Lower the epsilon ops

**Files:**
- Implement (rest of): `src/codegen/codegen.c`

- [ ] **Step 1: Implement `lc_codegen` and per-op lowering** for the epsilon set, porting:
  - `OP_VARARGPREP` → port `Lower_VarargPrep` (`codegen.c:418`): for the main chunk it calls
    `Rt_VarargPrep` → emit `EmitHelperCall3(B, "Rt_VarargPrep", nparams, 0, 0, /*reload*/1)`.
  - `LC_OP_GLOBAL_GET` (from `OP_GETTABUP _ENV`) → port `Lower_GetTabUp` (`codegen.c:357`):
    `EmitHelperCall3(B, "Rt_GetTabUp", A, B, C, 1)` (A=dst reg, B=upval index of `_ENV`,
    C=const index of the name).
  - `LC_OP_CONST` (from `OP_LOADK`) → port `Lower_LoadK` (`codegen.c:353`):
    `EmitHelperCall3(B, "Rt_LoadK", A, Bx, 0, 0)` **iff** a `Rt_LoadK` helper exists; if v1
    inlines LOADK by copying `P->k[Bx]` into `[RDI+A*16]` via `ci`-recovered `k`, port that
    inline sequence instead (check `Lower_LoadK` body — it likely recovers `k` and does a
    16-byte `setobj`). Either way the constant comes from the live Proto (§5 of the design).
  - `LC_OP_CALL` (from `OP_CALL`) → port `Lower_Call` (`codegen.c:347`):
    `EmitHelperCall3(B, "Rt_Call", A, nargs, nresults, 1)`.
  - `LC_OP_RETURN` (from `OP_RETURN/RETURN0/RETURN1`) → port `Lower_Return*`
    (`codegen.c:348-350`): set up the return via `Rt_PrepReturn`, then jump to the shared
    epilogue (use an epilogue-patch list as v1 does, or emit the epilogue inline for the
    single-block epsilon case).
  - `OP_MMBIN*` markers: no-op (consumed by the preceding arith op; absent in epsilon).
- [ ] **Step 2: `savedpc`** — for any op where `OpcodeNeedsSavedPc` (`codegen.c:272`) is true
  (CALL, GETTABUP), emit a savedpc store. **AOT caveat (design §5):** the absolute
  `&P->code[pc+1]` is not a compile-time constant. M0 fix: load the live Proto's `code`
  pointer at runtime (recover `P` via `ci->func`→closure→`p`, add `pc+1` * sizeof) and store
  that — port a runtime-relative variant of `EmitStoreSavedPc`. If that proves fiddly,
  **defer**: skip savedpc in M0 (it only affects error-traceback line numbers on stderr,
  which the stdout differential does not check) and leave a `// TODO(savedpc) bug LUAC-001`
  + an XFAIL differential test that prints a traceback line.
- [ ] **Step 3: No standalone unit test** — codegen correctness is proven by the end-to-end
  differential (Task 17). Build only: `cmd /c "build\build-luac.bat aotc"` must compile.
- [ ] **Step 4: Commit.**

```bash
git add src/codegen/codegen.c
git commit -m "feat(luac): lower epsilon op set (VARARGPREP/GETTABUP/LOADK/CALL/RETURN)"
```

---

## Phase 5 — COFF writer

### Task 12: Emit one COFF object from `LcCodeModule`

**Files:**
- Create: `src/link/coff_write.h`, `src/link/coff_write.c`
- Test: `tests/unit/test_lc_coff.c` (assert it links — promote the Task 2 spike's link check)

- [ ] **Step 1: Failing test** — build an `LcCodeModule` with one tiny function (`xor eax,eax;
ret`) + one `Rt_Len` REL32 reloc, call `LcCoff_Write("build/tmp/u.o", cm)`, then `system()`
the same link line as Task 2 and assert `rc == 0`.

- [ ] **Step 2: Implement the COFF writer** using the format locked by Task 2:
  - `IMAGE_FILE_HEADER`: `Machine=0x8664`, `NumberOfSections` (2: `.text`,`.rdata`),
    `PointerToSymbolTable`, `NumberOfSymbols`, `Characteristics=0`.
  - Section headers for `.text` (`IMAGE_SCN_CNT_CODE|MEM_EXECUTE|MEM_READ`, align 16) and
    `.rdata` (`CNT_INITIALIZED_DATA|MEM_READ`, align 16), each with `PointerToRawData` and
    `PointerToRelocations`.
  - Raw `.text` = concatenated function bytes (record each function's start offset → that's
    its symbol value). Raw `.rdata` = the pooled string-constant bytes (from `LcCodeModule.rodata`).
  - Per-function reloc → `IMAGE_RELOCATION{ VirtualAddress=func_off+reloc.offset,
    SymbolTableIndex, Type }` where `Type = IMAGE_REL_AMD64_REL32 (0x04)` for
    `LC_RELOC_REL32`/`_RDATA`, `IMAGE_REL_AMD64_ADDR64 (0x01)` for `LC_RELOC_ADDR64`. The
    REL32 addend (-4) lives in the disp32 field already written by the emitter (COFF REL32 is
    relative to the next instruction, matching our `-4`).
  - Symbol table: one `IMAGE_SYMBOL` per defined function (`luac_fn_<id>`, `External`,
    section `.text`, value=func offset), one per `.rdata` local label, and one `External`
    undefined symbol per distinct external reloc target (`Rt_*`, `luaV_*`). Names > 8 bytes
    go in the string table (offset form). Build a name→symbol-index map so relocs point
    correctly.
- [ ] **Step 3: Run, verify the link PASSES** (`rc==0`). A failure means a header/offset/symbol
miscalc — diff against the Task 2 hand-built object byte-for-byte.
- [ ] **Step 4: Commit.**

```bash
git add src/link/coff_write.* tests/unit/test_lc_coff.c build/Makefile
git commit -m "feat(luac): COFF object writer (sections, symbols, AMD64 relocations)"
```

---

## Phase 6 — AOT entry, ProtoInit, link glue, driver

### Task 13: Generated `ProtoInit` (as C) + the per-program glue object

**Files:**
- Implement (part of): `src/codegen/codegen.c` (emit a `.c` string), or a new
  `src/codegen/protoinit_emit.c`
- Test: covered by the end-to-end differential (Task 17)

- [ ] **Step 1: Emit a generated C file** `luac_protoinit_<pid>.c` containing, per function:
  - a `ProtoInit_<id>(lua_State *L)` that: `Proto *P = luaF_newproto(L);` sets
    `numparams/is_vararg/maxstacksize/sizek/...`; allocates `k[]` and fills it — integers/
    floats as `setivalue`/`setfltvalue`, strings as `setsvalue(L, &P->k[i], luaS_newlstr(L, "<bytes>", n))`;
    allocates `upvalues[]` (the entry's single `_ENV`); links `p[]` to child Protos (call
    children first); leaves `code=NULL`/`sizecode` set so helpers that read `sizecode` are
    consistent; then `extern int luac_fn_<id>(lua_State*); Jit_RegisterCompiled(P, luac_fn_<id>);`
    and returns `P`.
  - a `LuacProgram_BuildEntry(lua_State *L)` that calls every `ProtoInit_*` in
    children-before-parents order and returns the entry `Proto*`.
  This file is compiled by MinGW (reuse `ComposeObjectCompileFlags`) and linked — exactly the
  mechanism v1's `MakeBlobCObject` already uses, minus the blob array.

  > **M0 simplification (design note):** `ProtoInit` is generated C, not hand-emitted native.
  > The *function bodies* (`luac_fn_*`) are genuine native codegen — that is the AOT
  > guarantee. Emitting the constructor glue natively is a later refinement (M4), tracked.

- [ ] **Step 2: Commit** (after Task 16 lets it link).

### Task 14: AOT entry (strip `runtime_init.c`)

**Files:**
- Create: `src/runtime/aot_entry.c`

- [ ] **Step 1: Implement `int main(int argc, char **argv)`** by porting `RuntimeMain`
(`runtime_init.c:293-625`) and **removing** the blob path:
  - Keep: `Veh_Init`/`RegisterRuntimeTextRegion`, `Native_Bootstrap`, `luaL_newstate`,
    `Ffi_SetDispatchL`, `luaL_openlibs`, `Coro_OpenLib`, `Ctype_Init`,
    `Ffi_RegisterWindowsTypes`, `Ffi_OpenLib`, `PushArgTable`, the message handler
    (`Runtime_Msghandler`).
  - **Install the dispatch hook (Task 1 finding — verified `lvm.c:1199`):** set
    `luavm_jit_compile_hook = Jit_LookupCached` (**lookup-only**, *not* `Jit_Compile` — AOT
    bodies are pre-registered; we never JIT at runtime) and leave `luavm_jit_invoke_hook` at
    its default. `luaV_execute` then dispatches each Lua closure whose `Proto` is registered
    to its AOT body and never interprets bytecode. Confirm `L->hookmask == 0` (it is, with no
    debug hook). The four trigger conditions (A–D) are documented in
    `tests/unit/test_lc_dispatch_spike.c`.
  - **Replace** the `luaL_loadbufferx(blob...)` + `Jit_Compile` block with:
    `extern Proto *LuacProgram_BuildEntry(lua_State*); Proto *P = LuacProgram_BuildEntry(L);`
    (this also runs every `ProtoInit_*`, which call `Jit_RegisterCompiled(P_i, luac_fn_i)` —
    so all bodies are in the cache before the entry runs). Then build an `LClosure` over the
    entry `P` (one `_ENV` upvalue bound to the globals table: `Cl->upvals[0]` ← registry
    `_ENV`), push it, and invoke it the normal way (e.g. `lua_pcall` / `luaD_call` with the
    message handler installed) — `luaV_execute`'s hook dispatches it to `luac_fn_entry`. Use
    the **Task 3 spike notes** for any `CallInfo` specifics.
  - **Drop** `EmbeddedLoader_Install`, `InstallEmbeddedPackages` (no blob/preload in M0
    epsilon; re-add a native package-init in a later plan).
- [ ] **Step 2: Commit** (after it links via Task 16).

### Task 15: Link glue (`pe_link_v2`)

**Files:**
- Create: `src/link/pe_link_v2.h`, `src/link/pe_link_v2.c` (strip from `pe_link.c`)

- [ ] **Step 1: Implement `LuacLink_LinkUserObject`** — keep `ComposeObjectCompileFlags`,
`ComposeLinkLineFlags`, `PostLinkPatchPE`, `VerifyPeCharacteristics` (copy from `pe_link.c`).
Compile the generated `ProtoInit` C → `.o`. Then invoke the MinGW link line (mirror
`LinkBlobWithRuntime`):

```
x86_64-w64-mingw32-gcc -o <out.exe> <user.o> <protoinit.o> <aot_entry.o>
    build/bin/runtime-embedded.a build/bin/liblua54-embedded.a
    -Wl,--subsystem,console -lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi
```

**Do not** pass `-Wl,--strip-all` / section-randomize in M0 (keep `.pdata`/`.xdata` and
symbols for debugging). `aot_entry.c` is a *new* source — add it as its own object on the
link line (or a small `aot-rt.a`), and name its entry `main`.

**Task 2 spike finding (must honor):** the stock `runtime-embedded.a` contains the
blob-coupled v1 bootstrap (`runtime_entry.o` → `runtime_init.o`), which references symbols
that **do not exist** in an AOT program: `g_LuaBlob`, `g_LuaBlob_size`, `Runtime_GetPackages`
(plus `embedded_loader`/`blob_reader` paths). If `runtime_entry.o`'s `main` is pulled (because
no other `main` exists), it drags `runtime_init.o` and the link fails on those symbols.
**Fix (confirmed working in the spike):** provide our own `main` in `aot_entry.o` so
`runtime_entry.o` is never pulled, and ensure `aot_entry.c` does **not** reference any
`runtime_init.o` symbol (drop `EmbeddedLoader_Install`/`InstallEmbeddedPackages`, per Task 14).
Then `runtime_init.o` stays unpulled and the missing blob symbols never matter. Verify at link
time with `nm`/a clean link. If any path still drags `runtime_init.o`, either (a) build a
stripped AOT archive dropping `runtime_init.o`/`runtime_entry.o`/`embedded_loader.o`/
`blob_reader.o`, or (b) add a tiny `aot_blob_stubs.c` defining `g_LuaBlob`/`g_LuaBlob_size`/
`Runtime_GetPackages` as empty (the blob code is then dead, never reached since our `main`
runs). Prefer (a) for cleanliness once green.

- [ ] **Step 2: Commit** (after Task 16).

### Task 16: Driver wiring (`lc_drive` + argv)

**Files:**
- Implement: `src/driver/main.c`

- [ ] **Step 1: Wire the pipeline** in `lc_drive`, mirroring v1 `main.c` (Task-5 reader notes):
  1. parse argv → `LcDriverOptions` (`input`, `-o output`, `-O<n>` default 0, `--dll`, `-L pkg`);
  2. `Resolve_Walk(input, &opts, &res)`; on `res.WarnCount>0` **fail** (closed world);
  3. for each `res.Modules[i]`: `Lc_Undump` → `Proto*`; run `Lc_CheckClosedWorld` on each →
     `Diag` error + exit on failure;
  4. `lc_lift_program(entryProto, reachable[], n)` → `LcModule`;
  5. `lc_optimize(m, &cfg{opt_level=0})` (no-op);
  6. `lc_codegen(m)` → `LcCodeModule` (+ generated `ProtoInit` C);
  7. `LcCoff_Write(userObj, cm)`;
  8. `LuacLink_LinkUserObject(userObj, protoInitC, aotEntry, out, &link)`.
- [ ] **Step 2: Implement `int main`** under `#ifdef LUAC_AOTC_STANDALONE` to call `lc_drive`.
- [ ] **Step 3: Commit.**

```bash
git add src/driver/main.c src/runtime/aot_entry.c src/link/pe_link_v2.* src/codegen/*protoinit* 
git commit -m "feat(luac): aotc driver wiring + AOT entry + native link glue"
```

---

## Phase 7 — Build target & the differential gate

### Task 17: `Makefile.luac` + `build-luac.bat`, and the epsilon differential test

**Files:**
- Create: `build/Makefile.luac`, `build/build-luac.bat`
- Create: `tests/differential/aot_epsilon.lua`
- Modify: the differential runner to add an AOT mode (or a dedicated `tools/run-aot-diff.lua`)

- [ ] **Step 1: `build/Makefile.luac`** — target `aotc` links the new backend objects
(`src/ir/*.o src/opt/passes.o src/codegen/*.o src/link/coff_write.o src/link/pe_link_v2.o
src/driver/*.o`) against the front-end objects (`resolve.o lua_compile.o paths.o diag.o` +
`liblua54.a`) into `build/bin/aotc.exe` with `-DLUAC_AOTC_STANDALONE`. Reuse the existing
`EMBEDDED_RT_CFLAGS`/include paths. Add a phony `runtime-embedded.a` dependency (already
built by the base Makefile). `build/build-luac.bat` mirrors `build.bat`'s PATH setup and runs
`make -f build/Makefile.luac <target>`.

- [ ] **Step 2: The differential test fixture**

`tests/differential/aot_epsilon.lua`:
```lua
print("hello")
```

- [ ] **Step 3: The differential check** — script: compile with `aotc`, run the `.exe`, capture
stdout; run the same file under `build\bin\luavm.exe -i`, capture stdout; assert byte-equal.

```
build\bin\aotc.exe tests\differential\aot_epsilon.lua -o build\tmp\aot_epsilon.exe
build\tmp\aot_epsilon.exe              > build\tmp\aot.out
build\bin\luavm.exe -i tests\differential\aot_epsilon.lua > build\tmp\interp.out
fc build\tmp\aot.out build\tmp\interp.out    (PowerShell: Compare-Object)
```

Expected: both print `hello\n`; diff is empty. **This is the M0 epsilon gate.**

- [ ] **Step 4: Build everything and run the gate**

Run:
```
cmd /c "build\build-luac.bat aotc"
cmd /c "build\run-tests.bat"
```
Expected: `aotc.exe` builds; the AOT epsilon differential is `[PASS]`; the existing suite tally
shows no new `[FAIL]`. If stdout differs, debug via the spikes' invariants (dispatch reached?
entry CallInfo correct? `Rt_GetTabUp`/`Rt_Call` args right?) — **never** edit v1 to match.

- [ ] **Step 5: Commit.**

```bash
git add build/Makefile.luac build/build-luac.bat tests/differential/aot_epsilon.lua tools/
git commit -m "feat(luac): aotc build target + epsilon differential gate (print hello) GREEN"
```

---

## Done = M0 epsilon slice green

At this point the entire pipeline exists and is proven end-to-end: front-end → closed-world
gate → undump → memory-form IR → IR-driven codegen with relocations → COFF → MinGW link →
standard PE → dispatch-cache registration → differential-green `print("hello")`.

**Follow-on plans (separate specs/plans, each differential-green before the next):**
1. **Arithmetic + control flow** — `OP_ADD/SUB/MUL/DIV/MOD/IDIV/POW` (+ `K`/`I` variants),
   `OP_MOVE/LOADI/LOADF/LOADBOOL/LOADNIL`, `OP_JMP/EQ/LT/LE/TEST/TESTSET`, numeric
   `FORPREP/FORLOOP`. (Multi-block codegen + branch patching via the `BranchCtx` v1 uses.)
2. **Tables + globals write** — `NEWTABLE/GETI/SETI/GETFIELD/SETFIELD/GETTABLE/SETTABLE/
   SETTABUP/SETLIST/LEN/CONCAT/SELF`.
3. **Closures + upvalues + generic for** — `CLOSURE/GETUPVAL/SETUPVAL/VARARG/TFOR*`,
   upvalue capture + closing, to-be-closed (`TBC/CLOSE`).
4. **`pcall` + coroutine + one pure-Lua package** — `.pdata`/`.xdata` correctness under
   unwind; fiber init; complete the M0 differential set; resolve `savedpc` (LUAC-001).

---

## Self-review (run against the spec)

- **Spec coverage:** pipeline (§4) → Tasks 6–17; constants/Proto-without-blob (§5) → Tasks
  1, 13, 14; closed-world (§3/§9) → Task 6; COFF/link strategy B (M0-B) → Tasks 2, 12, 15;
  memory-form IR / no SSA (M0-A) → Tasks 8, 9; differential gate (§10) → Task 17; spikes-first
  (§11) → Tasks 1–3; savedpc risk (§5/§12) → Task 11 step 2. **Covered.** The full M0 op set
  (§10) is intentionally split into follow-on plans (noted above) — this plan delivers the
  epsilon slice that proves the pipeline, per the design's "first slice = epsilon."
- **Placeholder scan:** the only deferred item is `savedpc` (Task 11 step 2), which is an
  explicit, gated decision (XFAIL + bug id), not a hand-wave. Per-op machine code references
  `codegen.c:<line>` because that file is the authoritative in-tree implementation (DRY) — the
  AOT delta (CallSym/reload/savedpc) is spelled out in full.
- **Type/name consistency:** `LcCodeBuf`/`LcReloc`/`X64Emit_CallSym`/`X64Emit_LeaRipSym`/
  `Jit_RegisterCompiled`/`LcCoff_Write`/`LuacLink_LinkUserObject`/`Lc_CheckClosedWorld`/
  `Lc_Undump`/`lc_lift_func`/`lc_codegen` used consistently across tasks.
