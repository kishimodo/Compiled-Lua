/*
** codegen.h — Optimized IR -> relocatable x64 machine code.
**
** Unlike the v1 JIT (src/jit/codegen.c), which emits straight into RWX memory
** with runtime-helper addresses baked in as absolute immediates, LuaC codegen is
** AHEAD-OF-TIME: it emits position-independent machine code into a byte buffer
** plus a RELOCATION TABLE and UNWIND INFO, which the linker (../link/pe_write.c)
** places into .text/.pdata and binds against the runtime library.
**
** REUSE from v1 (do NOT rewrite these — copy/adapt src/jit/emit_x64.* and
** src/jit/regalloc.*):
**   - emit_x64: the raw instruction encoder (REX/ModRM/SIB, mov/add/cmp/jcc/call…).
**   - regalloc: register allocation over the SSA values.
** NEW for AOT (v1 never needed these):
**   - relocations: every call to a runtime helper / direct call to another LuaC
**     function / reference to an .rdata constant becomes a reloc the linker fixes.
**   - unwind info: Win64 requires .pdata/.xdata UNWIND_INFO for any function that
**     establishes a frame, so pcall/error longjmp, FFI, and coroutine switches
**     unwind correctly. The JIT could skip this; the AOT binary cannot.
**   - GC safepoints + a stack map so the collector can find live references in
**     generated frames (the v1 interpreter knew the stack layout; native code must
**     describe it).
**
** Lowering: typed ops (IARITH/FARITH/ICMP/RAWGET…) become inline instructions;
** generic ops (ARITH/TABLE_GET/CALL…) become CALLs to the Rt_* helper layer
** (src/jit/runtime.c) with identical semantics to v1 lvm.c.
*/
#ifndef LUAC_CODEGEN_H
#define LUAC_CODEGEN_H

#include "../ir/ir.h"
#include "codegen/lc_codebuf.h"   /* LcCodeBuf + the encoder-level LcReloc/LcRelocKind */

/* A relocation the linker must resolve when placing the code.
**
** NB: this MODULE/linker-level reloc descriptor is deliberately named
** LcModReloc to avoid colliding with the encoder-level LcReloc defined in
** lc_codebuf.h (different concept: that one is a per-buffer rel32/abs64 patch
** site keyed by symbol *name*; this one is a linker symbol/func/const *index*).
** A translation unit that needs both — e.g. codegen.c and the frame unit tests —
** includes both headers. */
typedef enum {
  LC_MRELOC_HELPER,    /* -> a runtime-library symbol (Rt_* / luaH_* / luaS_*)  */
  LC_MRELOC_LUAFUNC,   /* -> another LuaC-generated function (.text)             */
  LC_MRELOC_RODATA,    /* -> a constant in .rdata (string/float pool)           */
  LC_MRELOC_IMPORT     /* -> an imported symbol via .idata (kernel32, etc.)      */
} LcModRelocKind;

typedef struct LcModReloc {
  LcModRelocKind kind;
  uint32_t    offset;      /* patch site within this function's code            */
  uint32_t    target;      /* symbol/func/const index (resolved by linker)      */
  int32_t     addend;
  uint8_t     width;       /* 4 = rip-relative disp32 (default), 8 = abs64      */
} LcModReloc;

/* The compiled output for one LcFunc.
**
** Task-11 data-flow contract (consumed by the COFF writer / Task 12 and
** ProtoInit / Task 13): relocs are NAME-KEYED (the encoder-level LcReloc from
** lc_codebuf.h, recording rel32/abs64/.rdata patch sites against a symbol
** *name*), and each function carries a stable symbol name "luac_fn_<i>" whose
** index i matches its slot in LcModule.funcs (so ProtoInit can register
** luac_fn_i against m->funcs[i]->source). */
typedef struct LcCompiledFunc {
  uint8_t  *code;          /* machine code bytes                                */
  size_t    code_len;
  LcReloc  *relocs;        /* name-keyed REL32/ADDR64/RDATA (lc_codebuf.h)      */
  size_t    nrelocs;
  char      name[64];      /* this function's symbol, e.g. "luac_fn_0"          */
  uint8_t  *unwind;        /* Win64 UNWIND_INFO blob -> .xdata (M0: NULL/0)     */
  size_t    unwind_len;
} LcCompiledFunc;

typedef struct LcCodeModule {
  LcCompiledFunc *funcs;
  uint32_t        nfuncs;
  uint8_t        *rodata;  /* pooled constants                                  */
  size_t          rodata_len;
  /* LCPB ProtoInit blob (attached by the driver from LcBuildProtoBlob; owned
  ** by this module, freed by lc_codemodule_free). When non-NULL the COFF
  ** writer emits a .rdata$L section holding luac_fn_table (ADDR64-relocated
  ** native body pointers, one per funcs[i]) followed by luac_protoblob. */
  uint8_t        *protoblob;
  size_t          protoblob_len;
} LcCodeModule;

/* Compile the optimized module. Each LcFunc -> one LcCompiledFunc. */
LcCodeModule *lc_codegen(LcModule *m);
void          lc_codemodule_free(LcCodeModule *cm);

/* ------------------------------------------------------------------ */
/* Frame scaffolding (ported from v1 src/jit/codegen.c).               */
/*                                                                     */
/* Frame ABI (validated by tests/unit/test_lc_callinfo_spike.c):       */
/*   RBX = lua_State* L; RDI = ci->func.p + 16 (Lua register base);    */
/*   Lua register N at [RDI + N*16] (value +0, tag byte +8).           */
/*   Prologue pushes RDI,RBX,R12,R13,R14,R15,RSI (7 callee-saved) then */
/*   SUB RSP,0x20 (shadow space) -> 96B frame, 16-aligned at calls.    */
/*   Helper ABI: RCX=L, RDX/R8/R9=args, RAX=ret.                       */
/* ------------------------------------------------------------------ */
int LcCg_EmitPrologue        ( LcCodeBuf *B );  /* save regs, SUB RSP, RBX=L, RDI=ci->func+16 */
int LcCg_EmitEpilogue        ( LcCodeBuf *B );  /* ADD RSP, pop regs, RET                     */
int LcCg_EmitRestoreL        ( LcCodeBuf *B );  /* MOV RCX, RBX                               */
int LcCg_EmitReloadRdiAndCache( LcCodeBuf *B ); /* recompute RDI after a stack-relocating call */

/* Helper-call shim: MOV RCX,L ; MOV RDX,a ; MOV R8,b ; MOV R9,c ;
   CALL <Sym> (rel32 reloc) ; optional RDI reload. Reusable by lowering. */
int LcCg_EmitHelperCall3( LcCodeBuf *B, const char *Sym,
                          int a, int b, int c, int reload_after );

#endif /* LUAC_CODEGEN_H */
