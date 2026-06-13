# LuaC fork manifest (grounded in the v1 audit)

This is the file-level companion to [`../PROMPT.md`](../PROMPT.md). It records, per
subsystem: the exact **copy / strip / drop** action for each v1 file, the **key
interfaces** the new backend calls or mirrors (with `file:line` into v1), and the
**audited gotchas** that must be preserved. Actions:

- **copy-as-is** — bring into LuaC unchanged.
- **copy-and-strip** — copy, then remove the noted parts.
- **replace-with-new** — LuaC writes a fresh implementation; v1 is reference.
- **drop** — not linked in LuaC (archived as `*_v1_archive.*` for readability).
- **new-file** — does not exist in v1.

---

## 1. Front-end (Lua source → bytecode) + require-resolution — REUSED VERBATIM

LuaC compiles Lua 5.4 to bytecode with the unmodified upstream parser/codegen,
then the new IR-lift consumes the `Proto` trees. Nothing here changes.

| v1 file | action | note |
|---|---|---|
| `lua-5.4/src/llex.{c,h}` | copy-as-is | lexer |
| `lua-5.4/src/lparser.{c,h}` | copy-as-is | parser → `Proto` tree |
| `lua-5.4/src/lcode.{c,h}` | copy-as-is | bytecode emitter |
| `lua-5.4/src/lobject.h` | copy-as-is | `Proto`, `TValue`, `Upvaldesc`, bytecode types |
| `lua-5.4/src/lopcodes.h` | copy-as-is | opcode enum + decode macros |
| `lua-5.4/src/ldump.c`, `lundump.c` | copy-as-is | bytecode (de)serialize; lift loads via `lundump` |
| `lua-5.4/src/lfunc.{c,h}` | copy-as-is | `luaF_newproto`, closures |
| `src/compiler/lua_compile.{c,h}` | copy-as-is | `LuaCompile_File` |
| `src/compiler/resolve.{c,h}` | copy-as-is | `Resolve_Walk` closed-world scan |
| `src/compiler/paths.{c,h}` | copy-as-is | module-name → path |
| `src/compiler/diag.{c,h}` | copy-as-is | gcc/clang-style diagnostics |

**Key interfaces**

- `Proto` (`lobject.h:550-573`) — `code: Instruction[]`, `k: TValue[]`,
  `p: Proto[]`, `upvalues: Upvaldesc[]`, `numparams`, `is_vararg`, `maxstacksize`,
  plus optional debug (`lineinfo`, `locvars`, `source`).
- `Instruction` (`llimits.h:205` = `l_uint32`; formats in `lopcodes.h`) — decode
  with `GET_OPCODE`, `GETARG_A/B/C/Bx/sBx/Ax/sJ`. 5 formats (iABC, iABx, iAsBx,
  iAx, isJ); pick by opcode.
- `LuaCompile_File` (`lua_compile.c:44-80`) — parse + `lua_dump`; bytecode in
  `Result->Bytes`.
- `Resolve_Walk` (`resolve.c:288-428`) → `RESOLVE_RESULT_T` (`resolve.h:22-37`):
  `Modules[]` (entry `[0]`), `Count`, `WarnCount`, `BuiltinPackages[]`. This is the
  closed-world boundary.
- `RESOLVED_MODULE_T` (`resolve.h:15-20`) — `Name`, `Path`, `Bytes`, `BytesLen`.

**Gotchas:** `_ENV` is upvalue 0; globals are `GETTABUP _ENV`. Varargs +
`LUA_MULTRET`. Int (`LOADI`) vs float (`LOADF`) vs `LOADK` constants. `OP_CLOSURE`
binds upvalues at closure-creation; nested Protos are compile-time refs.
`OP_MMBIN` metamethod fallback after arith. `--strip` drops debug info. Fuse
`LOADKX`+`EXTRAARG` and `NEWTABLE`+`EXTRAARG`. Interned `TString*` are load-stable
→ bake into `.rdata`. Decode the correct instruction format per opcode.

---

## 2. Runtime core — STATIC SUPPORT LIBRARY ("the libc")

Linked unchanged, minus the interpreter loop. Generated code calls into it.

| v1 file | action | note |
|---|---|---|
| `lua-5.4/src/lobject.{c,h}` | copy-as-is | `TValue`, object helpers |
| `lua-5.4/src/lstring.{c,h}` | copy-as-is | interning |
| `lua-5.4/src/ltable.{c,h}` | copy-as-is | array+hash tables |
| `lua-5.4/src/lgc.{c,h}` | copy-as-is | mark-sweep GC + barriers |
| `lua-5.4/src/ltm.{c,h}` | copy-as-is | metamethod dispatch |
| `lua-5.4/src/lfunc.{c,h}` | copy-as-is | closures/upvalues |
| `lua-5.4/src/lstate.{c,h}` | copy-as-is | `lua_State`, `global_State` |
| `lua-5.4/src/lmem.{c,h}` | copy-as-is | GC-aware allocator |
| `lua-5.4/src/ldo.{c,h}` | copy-as-is | `luaD_call`, `luaD_throw` (error/longjmp) |
| `lua-5.4/src/lvm.h` | copy-as-is | coercion/fastget macros |
| `lua-5.4/src/lvm.c` | **copy-and-strip** → `lvm_semantics.c` | **strip `luaV_execute` + opcode loop**; keep the `luaV_*` semantic helpers |
| `lua-5.4/src/{lua.h,luaconf.h,llimits.h,lprefix.h}` | copy-as-is | config (`lua_Number=double`, `lua_Integer=long long`) |
| `src/runtime/coro.{c,h}` | copy-as-is | Windows-fiber coroutines |
| `src/runtime/runtime_init.{c,h}` | copy-and-strip | keep init; drop blob-loader wiring |

**Key interfaces (generated code calls these)**

- Tables (`ltable.h`): `luaH_new`, `luaH_get`, `luaH_set`, `luaH_getint`,
  `luaH_setint`, `luaH_getshortstr`.
- Strings (`lstring.h`): `luaS_new`, `luaS_newlstr`.
- Metamethods (`ltm.h`): `luaT_gettm`, `luaT_gettmbyobj`, `luaT_callTM`.
- **GC barriers (`lgc.h:179-186`): `luaC_barrier`, `luaC_barrierback`** (impls
  `luaC_barrier_`/`luaC_barrierback_`, `lgc.c:208-240`) — **mandatory** on stores
  of collectable values.
- Semantics (`lvm.h`): `luaV_tonumber_`, `luaV_tointeger`, `luaV_tointegerns`,
  `luaV_idiv`, `luaV_mod`, `luaV_modf`, `luaV_shiftl`, `luaV_lessthan`,
  `luaV_lessequal`, `luaV_equalobj`, `luaV_concat`, `luaV_objlen`,
  `luaV_finishget`, `luaV_finishset`.
- Calls/errors (`ldo.h`): `luaD_call`, `luaD_callnoyield`, `luaD_throw`.
- Closures (`lfunc.h`): `luaF_newLclosure`, `luaF_findupval`, `luaF_closeupval`.
- Coroutines (`coro.h`): `Coro_InitThreadAsFiber`, `Coro_OpenLib`.

**TValue layout** (`lobject.h:49-69`): `{ Value value_; lu_byte tt_; }`, `Value` =
union(`gc`,`p`,`f`,`i`,`n`). Tag bits 0-3 base / 4-5 variant
(`LUA_VNUMINT`/`LUA_VNUMFLT`, `LUA_VSHRSTR`/`LUA_VLNGSTR`) / bit 6 collectable.

**Gotchas:** call GC barriers on every collectable store unless proven unneeded;
intern all strings (pointer-equality field lookup); tag+value are separate fields
— write both, compare tag with **8-bit** CMP; int/float subtype rules
(`tonumber` vs `tointegerns`); deep `__index`/`__newindex` chains
(`MAXTAGLOOP=2000`, `lvm.c:49`); weak tables; `__gc` finalizer re-entrancy any GC
phase; `pairs` order not stable across GC/mutation; close upvalues on scope exit
(`luaF_closeupval`) or use-after-free; `luaV_concat` can GC; generational vs
incremental barrier rules; `load`/`loadstring` must be rejected (interpreter +
`lundump` are stripped from output).

---

## 3. Windows FFI — RUNTIME LIBRARY + CONSERVATIVE OPTIMIZATION BARRIER

The entire FFI (`src/ffi/*`) is **copy-as-is** and linked as a library. Files:
`ctype.{c,h}`, `cdata.{c,h}`, `marshal.{c,h}`, `ffi_call.{c,h}`,
`ffi_thunk.{c,h}`, `ffi_callback.{c,h}`, `ffi_lib.{c,h}`, `ffi_load.{c,h}`,
`cdecl_parser.c`, `cdecl_lexer.c`, `veh.{c,h}`, `ffi_atomics.{c,h}`.

**Key interfaces** (runtime lib must export):
`Ffi_GenericCall` (`ffi_call.h:25`), `Marshal_LuaToC`/`Marshal_CToLua`
(`marshal.h:19,21`), `Ffi_GetSignatureThunk` (`ffi_thunk.h:30`),
`Ffi_AllocCallback` (`ffi_callback.h:27`), `Callback_Dispatch`
(`ffi_callback.h:59`), `Ffi_ResolveSymbol` (`ffi_load.h:35`), `Ctype_Lookup`
(`ctype.h:71`), `FfiNewCData` (`cdata.h:67`), `Cdata_Storage` (`cdata.h:111`),
plus cdata metamethods.

**Barrier semantics (optimizer):** at every `ffi.C.sym(...)` call
(→ `Ffi_GenericCall`, IR `LC_OP_CALL_FFI`) and every callback re-entry: stop type
propagation, escape analysis, devirtualization, CSE/code-motion. Assume all
globally/stack-reachable Lua state may be read/mutated; assume full register/stack
clobber. C symbol addresses are runtime values (`GetProcAddress`) — never relocate
to them. Variadic C calls rejected (`ffi_call.c:38-41`).

**Gotchas:** thunk `RSP%16==0` before the C call (`ffi_thunk.c:105-112`); the
>4-arg callback stack-slot fix (`ffi_callback.c:140-159`); float-return `movq
xmm0↔rax` reinterpret; borrowed-cdata parent lifetime via uservalue slot;
forward-decl struct in-place completion (`ctype.c:88-109`); enum/extern separate
namespaces; UTF-8→UTF-16 marshal buffer must outlive the call; 256-callback-slot
limit; `Interlocked*` via `Ffi_AtomicsLookup` (not exported by DLLs); VEH region
registration after `ExecMem_Commit`; `self`-first module preload order;
`ffi.metatype` per-type metatable shadowing; ctype pointer-identity interning.

---

## 4. x64 codegen — REUSE THE ENCODER, REPLACE THE TRANSLATOR

| v1 file | action | note |
|---|---|---|
| `src/jit/emit_x64.{c,h}` | copy-and-strip → `src/codegen/x64_emit.*` | keep encoder; add RIP-relative + relocation metadata, buffer-based emission (not `ExecMem_Append`) |
| `src/jit/regalloc.{c,h}` | copy-and-strip → `src/codegen/regalloc.*` | reuse use-count cache-slot allocation |
| `src/jit/runtime.{c,h}` | copy-as-is → `src/runtime/lua_rt.*` | the `Rt_*` helper layer → static runtime lib |
| `src/jit/codegen.{c,h}` | **drop** (reference) | study per-opcode lowering; LuaC is IR-driven |
| `src/jit/exec_mem.{c,h}` | **drop** | replaced by PE sections + relocations (no RWX) |
| `src/jit/dispatch.{c,h}` | **drop** | no on-demand compile; whole program at once |

**Encoder API** (`emit_x64.h`): `EmitX64_MovImm64ToReg` (31),
`EmitX64_MovMemToReg` (38), `EmitX64_MovRegToMem` (45), `EmitX64_CallAbs` (169),
`EmitX64_JmpRel8/32_Placeholder` (108/125), `EmitX64_PatchRel8/32` (117/141), plus
CMP/ADD/SUB/PUSH/POP and SSE2 scalar-double. **Regalloc:** `RegAlloc_Analyse`
(48), `RegAlloc_IsCached` (55) — top Lua regs → R12–R15, RSI.

**`Rt_*` helpers** (`runtime.h:19-338`): `Rt_AddSlow`, `Rt_Call` (JIT→JIT fast
path concept becomes "always-compiled direct call"), `Rt_GetI`, `Rt_SetField`,
`Rt_GetField`, `Rt_GetTable`, `Rt_SetTable`, `Rt_Len`, `Rt_Concat`, `Rt_ForPrep`/
`Rt_ForLoop`, `Rt_GetUpval`/`Rt_SetUpval`, `Rt_NewClosure`, varargs/iterators.
Win64 ABI: `RCX`=`L`, `RDX`/`R8`/`R9`=operands, `RAX`=ret; Lua reg N at
`[RDI + N*16]`, tag at `+8`.

**New vs v1 JIT:** relocations instead of baked imm64; RIP-relative `.rdata`
loads; `.pdata`/`.xdata` `UNWIND_INFO` per framed function; GC stack maps +
safepoints; type-specialized lowering (emit only the proven arithmetic arm).

**Gotchas:** absolute→RIP-relative/reloc or it crashes; helper-address relocation
required; `.xdata` unwind mandatory; RBP/R13 mod-bias + RSP/R12 SIB; **8-bit** tag
CMP; `savedpc` updates before throw-capable ops; reload `RDI`+cache after
stack-relocating helpers (leaf helpers may skip); write-through coherency; rel8 vs
rel32 sizing then patch; 32-byte shadow space; `RSP%16==0` at calls; Win64
volatile vs callee-saved discipline; closure creation defers no codegen
(all Protos compiled at link time).

---

## 5. PE output — REPLACE BLOB EMBEDDING WITH NATIVE LINKING

| v1 file | action | note |
|---|---|---|
| `src/compiler/pe_link.c` | copy-and-strip → `pe_link_v2.c` | rewrite `LinkBlobWithRuntime`; drop `MakeBlobCObject`; keep `ComposeObjectCompileFlags`, `ComposeLinkLineFlags`, `PostLinkPatchPE`, `VerifyPeCharacteristics`; add `.pdata`/`.xdata` emission |
| `src/compiler/pe_link.h` | copy-and-strip → `pe_link_v2.h` | `PeLink_Bundle` → `LuacLink_LinkUserObject(userObj, pkgObjs[], n, out, opts)`; keep only `PE_OUT_EXE`/`PE_OUT_DLL` |
| `src/compiler/blob.c` | **drop** | no blob |
| `src/common/blob_format.h` | **drop** | `LUAVM_BLOB_HEADER_T`/`MODULE_ENTRY_T` gone |
| `src/runtime/embedded_loader.{c,h}` | **drop** | no runtime module searcher |
| `src/runtime/blob_reader.{c,h}` | **drop** | no blob to read |
| `src/runtime/native_loader.c` | copy-and-strip → `native_loader_v2.c` | keep `Native_Bootstrap` + SHA-256 DLL extraction; drop blob coupling |
| `build/Makefile` | copy-and-strip → `Makefile.luac` | build `runtime-embedded.a` once; add codegen→object + native-link rules; drop blob/embedded-loader from `RUNTIME_SRCS` |
| `build/gen/packages.mk` | copy-and-strip → `packages_native.mk` | packages → native objects, not embedded-bytecode `.o` |

**Sections LuaC emits:** `.text` (user native + runtime), `.rdata` (constants/
interned strings), `.data`/`.bss` (globals), `.pdata`+`.xdata` (SEH unwind —
**do not strip/randomize**), `.reloc` (ASLR base relocs), `.idata` (kernel32,
advapi32, iphlpapi, psapi imports). No blob, no overlay, no searcher.

**Two link strategies** (PROMPT §12): (A) self-contained PE writer resolving
`LcReloc`s against the runtime symbol table; (B) emit COFF objects and delegate to
the MinGW `ld` already in the toolchain. Bring up on B, optionally graduate to A.

**Reference:** v1 `PeLink_Bundle` (`pe_link.c:1258-1549`), `MakeBlobCObject`
(`341-397`), `LinkBlobWithRuntime` (`1087-1141`), `PostLinkPatchPE` (`69-119`).

---

## 6. Packages & tests

**Packages** (`src/runtime/packages/`, ~195) — copy-as-is. Pure-Lua packages are
part of the closed world and AOT-compiled into the program; FFI-wrapper packages
cross the FFI barrier. Discovery (`build/gen/packages.mk`,
`build/gen/_builtin_packages.h`, `tools/build-package-catalog.lua`) adapted to
emit native package objects. Absent external DLL → `SKIP`.

**Tests** — reuse the 5-layer auto-discovered suite (`tests/unit`, `tests/lua`,
`tests/packages`, `tests/differential`; runner `tools/run-tests.lua`,
`build\run-tests.bat`) and **add the AOT differential oracle**: compile a printing
script with **LuaC (native)**, run the same script under **v1 `clua-interp.exe -i`
(interpreter)**, **diff stdout**. v1 is the frozen oracle; never edit v1 to make a
diff pass. Keep the `XFAIL`/`XPASS` discipline (CLAUDE.md). New C-unit tests cover
the IR builder, each opt pass, emitter relocations, PE sections, and unwind-info
correctness.

---

*Provenance: subsystem deep-reads of the codebase (front-end, runtime
core, FFI, JIT/codegen, PE link, packages/tests), 190 file reads.*
