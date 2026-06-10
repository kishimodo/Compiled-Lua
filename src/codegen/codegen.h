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

/* A relocation the linker must resolve when placing the code. */
typedef enum {
  LC_RELOC_HELPER,     /* -> a runtime-library symbol (Rt_* / luaH_* / luaS_*)  */
  LC_RELOC_LUAFUNC,    /* -> another LuaC-generated function (.text)             */
  LC_RELOC_RODATA,     /* -> a constant in .rdata (string/float pool)           */
  LC_RELOC_IMPORT      /* -> an imported symbol via .idata (kernel32, etc.)      */
} LcRelocKind;

typedef struct LcReloc {
  LcRelocKind kind;
  uint32_t    offset;      /* patch site within this function's code            */
  uint32_t    target;      /* symbol/func/const index (resolved by linker)      */
  int32_t     addend;
  uint8_t     width;       /* 4 = rip-relative disp32 (default), 8 = abs64      */
} LcReloc;

/* The compiled output for one LcFunc. */
typedef struct LcCompiledFunc {
  uint8_t  *code;          /* machine code bytes                                */
  size_t    code_len;
  LcReloc  *relocs;
  uint32_t  nrelocs;
  uint8_t  *unwind;        /* Win64 UNWIND_INFO blob -> .xdata                  */
  size_t    unwind_len;
  uint8_t  *stackmap;      /* GC stack map (live-ref slots per safepoint)       */
  size_t    stackmap_len;
  uint32_t  symbol;        /* this function's symbol index                      */
} LcCompiledFunc;

typedef struct LcCodeModule {
  LcCompiledFunc *funcs;
  uint32_t        nfuncs;
  uint8_t        *rodata;  /* pooled constants                                  */
  size_t          rodata_len;
} LcCodeModule;

/* Compile the optimized module. Each LcFunc -> one LcCompiledFunc. */
LcCodeModule *lc_codegen(LcModule *m);
void          lc_codemodule_free(LcCodeModule *cm);

#endif /* LUAC_CODEGEN_H */
