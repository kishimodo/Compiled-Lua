/*
** ir.h — LuaC mid-level SSA IR.
**
** This is the heart of the LuaC optimizing AOT compiler. The pipeline is:
**
**     Lua source --[v1 front-end]--> Proto (bytecode) --[lift.c]--> THIS IR
**                --[opt/*.c passes]--> optimized IR --[codegen]--> x64
**
** Design invariants (see ../../PROMPT.md §IR and §Optimizer):
**  - SSA form: every LcValue is assigned exactly once; control-flow joins use phi.
**  - Closed-world: the whole reachable program is lifted into ONE LcModule, so the
**    call graph is complete except across FFI/C edges (which are opaque barriers).
**  - Sound-conservative typing: the LcType lattice carries only facts we can PROVE.
**    Where a value's type is ANY (boxed TValue), codegen falls back to the same
**    dynamic runtime helpers the v1 interpreter uses — never wrong, just slower.
**  - Faithful Lua 5.4: int/float subtypes, metatable dispatch, and coercion rules
**    are modeled explicitly so an optimized op and its boxed fallback agree bit-for-bit.
*/
#ifndef LUAC_IR_H
#define LUAC_IR_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* Opaque handles into the reused v1 front-end (lua-5.4/src/lobject.h). */
typedef struct Proto Proto;     /* a compiled Lua function prototype  */
typedef struct TValue TValue;   /* a boxed Lua value                  */

/* ------------------------------------------------------------------ */
/* Type lattice                                                       */
/*                                                                    */
/* Ordered from most-precise (BOTTOM, unreachable) to least (ANY).    */
/* The interprocedural type-propagation pass computes a fixpoint over  */
/* this lattice; meet() narrows, join() widens. Unboxing is legal      */
/* ONLY for the concrete scalar kinds (INT/FLT/BOOL). Everything else  */
/* stays a GC-managed boxed reference, but a precise reference kind     */
/* (STR/TAB/FUNC) still enables devirtualization and barrier elision.  */
/* ------------------------------------------------------------------ */
typedef enum {
  LC_T_BOTTOM = 0, /* proven unreachable / no value                    */
  LC_T_NIL,        /* exactly nil                                      */
  LC_T_BOOL,       /* boolean — unboxable to a 1-byte reg             */
  LC_T_INT,        /* lua_Integer — unboxable to a 64-bit GPR         */
  LC_T_FLT,        /* lua_Number  — unboxable to an XMM reg           */
  LC_T_NUM,        /* INT|FLT (number, subtype unknown) — still raw-ish*/
  LC_T_STR,        /* interned TString*                                */
  LC_T_TAB,        /* Table* (optionally with a shape id, see below)   */
  LC_T_FUNC,       /* Lua closure (Proto known when monomorphic)       */
  LC_T_CFUNC,      /* C function pointer                               */
  LC_T_USERDATA,   /* full/light userdata (incl. FFI cdata)            */
  LC_T_THREAD,     /* coroutine                                        */
  LC_T_ANY         /* TOP: unknown — boxed TValue, full dynamic path   */
} LcTypeKind;

/*
** A refined type. `kind` is the lattice point; the union carries extra
** facts that unlock specific optimizations when present.
*/
typedef struct LcType {
  LcTypeKind kind;
  /* For LC_T_FUNC when the callee is monomorphic: the exact Proto, so the
  ** call can be lowered to a direct relocated CALL and inlined. NULL = unknown. */
  Proto *known_proto;
  /* For LC_T_TAB after escape/shape analysis: a shape id grouping tables with
  ** the same field layout, enabling field-offset specialization and
  ** dead-field elimination. 0 = unknown/polymorphic shape. */
  uint32_t table_shape;
  /* For LC_T_INT/LC_T_FLT compile-time constants: validity + value. */
  bool is_const;
  union { int64_t i; double n; } cval;
} LcType;

LcType lc_type_meet(LcType a, LcType b); /* narrow (intersection)   */
LcType lc_type_join(LcType a, LcType b); /* widen   (union)         */
bool   lc_type_is_unboxable(LcType t);   /* INT/FLT/BOOL            */

/* ------------------------------------------------------------------ */
/* IR opcodes                                                         */
/*                                                                    */
/* Each op has a "generic" (boxed, metatable-aware) form and, where    */
/* meaningful, the optimizer rewrites it to a typed form once the      */
/* operand types are proven. Codegen lowers generic forms to Rt_*      */
/* helper calls (same semantics as v1 lvm.c) and typed forms to inline */
/* machine code.                                                       */
/* ------------------------------------------------------------------ */
typedef enum {
  /* --- values & constants --- */
  LC_OP_CONST,        /* materialize a constant (nil/bool/int/flt/str)   */
  LC_OP_PHI,          /* SSA join                                        */
  LC_OP_ARG,          /* incoming function parameter                     */

  /* --- locals are SSA values; upvalues/globals are explicit --- */
  LC_OP_UPVAL_GET,    /* read captured upvalue                           */
  LC_OP_UPVAL_SET,    /* write captured upvalue (+ GC barrier)           */
  LC_OP_GLOBAL_GET,   /* _ENV[name]  — a TABLE_GET on _ENV under the hood */
  LC_OP_GLOBAL_SET,   /* _ENV[name] = v                                  */

  /* --- arithmetic: generic (may invoke __add etc.) vs typed inline --- */
  LC_OP_ARITH,        /* generic; carries a sub-op (add/sub/.../idiv/mod) */
  LC_OP_IARITH,       /* typed integer arith (wraps per 5.4)             */
  LC_OP_FARITH,       /* typed float arith                               */
  LC_OP_BITWISE,      /* &,|,~,<<,>> — integer-only per 5.4              */
  LC_OP_UNM, LC_OP_NOT, LC_OP_LEN, /* unary; LEN/CONCAT may hit metamethods */
  LC_OP_CONCAT,

  /* --- comparison/branch --- */
  LC_OP_CMP,          /* generic ==,<,<= (may invoke __eq/__lt/__le)     */
  LC_OP_ICMP, LC_OP_FCMP, /* typed comparisons                          */
  LC_OP_TEST,         /* truthiness test for conditional branch          */
  LC_OP_BRANCH,       /* conditional branch                             */
  LC_OP_JMP,          /* unconditional                                  */

  /* --- tables --- */
  LC_OP_NEWTABLE,     /* allocate (with size hints from bytecode)        */
  LC_OP_TABLE_GET,    /* t[k] generic (metatable __index chain)          */
  LC_OP_TABLE_SET,    /* t[k]=v generic (__newindex + GC barrier)        */
  LC_OP_RAWGET, LC_OP_RAWSET, /* proven no-metatable fast path          */

  /* --- calls/returns --- */
  LC_OP_CALL,         /* indirect/unknown callee (boxed dispatch)        */
  LC_OP_CALL_DIRECT,  /* known Proto — relocated direct call/inlined     */
  LC_OP_CALL_INTRIN,  /* modeled stdlib intrinsic (math.*, string.* ...) */
  LC_OP_CALL_FFI,     /* FFI/C boundary — OPTIMIZATION BARRIER           */
  LC_OP_TAILCALL,
  LC_OP_RETURN,
  LC_OP_VARARG,

  /* --- closures & loops --- */
  LC_OP_CLOSURE,      /* create closure, capturing upvalues              */
  LC_OP_FORPREP_I, LC_OP_FORLOOP_I, /* numeric-for, integer-specialized  */
  LC_OP_FORPREP_F, LC_OP_FORLOOP_F,
  LC_OP_TFORCALL, LC_OP_TFORLOOP,   /* generic-for                       */

  /* --- coroutine / error boundaries (affect escape analysis) --- */
  LC_OP_PCALL_BEGIN, LC_OP_PCALL_END, /* protected region (SEH/.pdata)   */

  LC_OP__COUNT
} LcOpcode;

/* Sub-op selector shared by LC_OP_ARITH/IARITH/FARITH/BITWISE/CMP. */
typedef enum {
  LC_A_ADD, LC_A_SUB, LC_A_MUL, LC_A_DIV, LC_A_FLOORDIV, LC_A_MOD, LC_A_POW,
  LC_A_BAND, LC_A_BOR, LC_A_BXOR, LC_A_SHL, LC_A_SHR,
  LC_A_EQ, LC_A_LT, LC_A_LE
} LcArithKind;

/* Effect summary — drives DCE, code motion, and where analyses must stop. */
typedef enum {
  LC_FX_PURE       = 0,        /* no reads/writes, no traps                 */
  LC_FX_READS_HEAP = 1 << 0,   /* may read GC heap (table/upvalue/global)   */
  LC_FX_WRITES_HEAP= 1 << 1,   /* may write heap (+ needs GC barrier)       */
  LC_FX_MAY_THROW  = 1 << 2,   /* may raise a Lua error (longjmp)           */
  LC_FX_CALLS_LUA  = 1 << 3,   /* may transfer control to unknown Lua       */
  LC_FX_FFI_BARRIER= 1 << 4    /* crosses to C: conservative for ALL state  */
} LcEffect;

/* ------------------------------------------------------------------ */
/* SSA structures                                                     */
/* ------------------------------------------------------------------ */
typedef struct LcInst LcInst;
typedef struct LcBlock LcBlock;
typedef struct LcFunc LcFunc;
typedef struct LcModule LcModule;

/* An SSA value is produced by exactly one instruction (or is an ARG). */
typedef struct LcValue {
  LcInst *def;        /* defining instruction (NULL for ARG/const-pool)   */
  LcType  type;       /* refined type after analysis                      */
  uint32_t id;        /* dense id for bitsets/worklists                   */
} LcValue;

struct LcInst {
  LcOpcode op;
  LcArithKind sub;    /* valid for arith/cmp/bitwise                      */
  uint32_t flags;     /* LcEffect bitset                                  */
  LcValue **args;     /* operand values                                  */
  uint16_t nargs;
  LcValue  result;    /* this instruction's SSA result                   */
  int      bc_pc;     /* originating bytecode pc (diagnostics/debug info) */
  LcInst  *next, *prev;
};

struct LcBlock {
  uint32_t id;
  LcInst  *first, *last;       /* instruction list                       */
  LcBlock **preds, **succs;
  uint16_t npreds, nsuccs;
  /* dominator-tree + liveness scratch filled by analyses */
  LcBlock *idom;
  void    *live_in, *live_out; /* bitsets, owned by liveness pass         */
};

struct LcFunc {
  Proto   *source;             /* the v1 Proto this was lifted from       */
  LcBlock **blocks;            /* RPO-ordered                             */
  uint32_t nblocks;
  LcValue **args;              /* parameters                              */
  uint16_t nargs;
  bool     is_vararg;
  /* interprocedural summary (filled by the whole-program passes) */
  LcType   ret_type;           /* joined return type                      */
  uint32_t effect_summary;     /* LcEffect bitset for the whole function  */
  bool     escapes;            /* address/closure escapes the module      */
};

struct LcModule {
  LcFunc  **funcs;             /* every reachable function (closed world) */
  uint32_t nfuncs;
  LcFunc   *entry;             /* program entry (main chunk)              */
  /* call graph: edges[i] lists callee indices of funcs[i]; FFI/unknown
  ** callees are recorded as a sentinel so passes treat them as barriers. */
  uint32_t **callees;
  uint32_t  *ncallees;
};

/* ------------------------------------------------------------------ */
/* Builder / lifecycle (implemented in ir.c)                          */
/* ------------------------------------------------------------------ */
LcModule *lc_module_new(void);
void      lc_module_free(LcModule *m);
LcFunc   *lc_func_new(LcModule *m, Proto *p);
LcBlock  *lc_block_new(LcFunc *f);
LcInst   *lc_emit(LcBlock *b, LcOpcode op);
void      lc_inst_add_arg(LcInst *in, LcValue *v);

/* Verify SSA well-formedness + effect consistency (debug builds). */
bool lc_module_verify(LcModule *m, char *err, size_t errlen);

#endif /* LUAC_IR_H */
