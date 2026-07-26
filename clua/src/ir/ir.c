/*
** ir.c — LcModule/LcFunc/LcBlock/LcInst construction + SSA verifier.
** See ir.h and ../../PROMPT.md §7. STUB: implement for Milestone M0.
*/
#include "ir.h"
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>   /* lc_verr's message formatting            */
#include <stdio.h>    /* vsnprintf                               */

/* The verifier checks IR operands against the source Proto's own limits, and
** uses Lua's opcode mode table (testAMode) rather than a hand-maintained list of
** which opcodes write a register. */
#include "lobject.h"
#include "lopcodes.h"

/* ------------------------------------------------------------------ */
/* Arena (resolves the old TODO(M0))                                   */
/*                                                                     */
/* A grow-only chunked bump allocator owned by the LcModule. Every IR  */
/* node (LcFunc/LcBlock/LcInst) and every builder-grown pointer array  */
/* (m->funcs, f->blocks, in->args) is carved out of it, so building    */
/* the IR is a pointer bump and lc_module_free is one walk over the    */
/* chunk chain instead of a walk over every node. Returned memory is   */
/* zero-filled (the constructors used to calloc) and 8-byte aligned    */
/* (sufficient for every IR struct on x64: max member alignment is 8). */
/*                                                                     */
/* Growable arrays use grow-by-arena-copy: capacity is implicitly      */
/* 4 << k derived from the element count (grow exactly when count is   */
/* 0 or a power of two >= 4), so no capacity field is stored and the   */
/* abandoned old copies simply stay in the arena (bounded ~1x waste).  */
/* Analysis scratch that genuinely reallocs (opt/passes.c worklists,   */
/* blk->live_in/out, m->callees) stays on plain malloc/free.           */
/* ------------------------------------------------------------------ */

#define LC_ARENA_CHUNK_PAYLOAD (64u * 1024u)   /* default chunk data size */

typedef struct LcArenaChunk {
  struct LcArenaChunk *next;     /* chain, newest first */
  size_t used, cap;
  /* payload follows the header; header is 24 bytes, so data is 8-aligned */
  unsigned char data[];
} LcArenaChunk;

struct LcArena {
  LcArenaChunk *chunks;          /* newest chunk first; bump into chunks[0] */
};

static void *lc_arena_alloc(LcArena *a, size_t n) {
  LcArenaChunk *c = a->chunks;
  void *p;
  n = (n + 7u) & ~(size_t)7u;    /* keep every object 8-byte aligned */
  if (!c || c->cap - c->used < n) {
    size_t cap = n > LC_ARENA_CHUNK_PAYLOAD ? n : LC_ARENA_CHUNK_PAYLOAD;
    LcArenaChunk *nc = (LcArenaChunk *)malloc(sizeof(LcArenaChunk) + cap);
    if (!nc) return NULL;
    nc->next = a->chunks;
    nc->used = 0;
    nc->cap = cap;
    a->chunks = nc;
    c = nc;
  }
  p = c->data + c->used;
  c->used += n;
  memset(p, 0, n);
  return p;
}

/* Grow `arr` (count elements of elemsz bytes) for one more element under the
** implicit 4<<k capacity rule above. Returns the (possibly moved) array, or
** NULL on OOM. The old copy, if any, stays in the arena. */
static void *lc_arena_grow(LcArena *a, void *arr, uint32_t count, size_t elemsz) {
  if (count == 0 || (count >= 4 && (count & (count - 1)) == 0)) {
    size_t newcap = count ? (size_t)count * 2u : 4u;
    void *na = lc_arena_alloc(a, newcap * elemsz);
    if (!na) return NULL;
    if (count) memcpy(na, arr, (size_t)count * elemsz);
    return na;
  }
  return arr;
}

LcModule *lc_module_new(void) {
  LcModule *m = (LcModule *)calloc(1, sizeof(LcModule));
  if (!m) return NULL;
  m->arena = (LcArena *)calloc(1, sizeof(LcArena));
  if (!m->arena) { free(m); return NULL; }
  return m;
}

void lc_module_free(LcModule *m) {
  if (!m) return;
  /* call-graph arrays, if any (still plain malloc — they realloc-grow) */
  if (m->callees) {
    for (uint32_t i = 0; i < m->nfuncs; i++) free(m->callees[i]);
  }
  free(m->callees);
  free(m->ncallees);
  /* every func/block/inst and their builder arrays live in the arena:
  ** releasing the chunk chain releases the whole IR. */
  if (m->arena) {
    LcArenaChunk *c = m->arena->chunks;
    while (c) {
      LcArenaChunk *next = c->next;
      free(c);
      c = next;
    }
    free(m->arena);
  }
  free(m);
}

LcFunc *lc_func_new(LcModule *m, Proto *p) {
  LcFunc *f;
  LcFunc **grown;
  if (!m) return NULL;  /* funcs are arena-owned, so a module is required */
  f = (LcFunc *)lc_arena_alloc(m->arena, sizeof(LcFunc));
  if (!f) return NULL;
  f->source = p;
  f->is_ssa = false;   /* M0 memory form until M1 mem2reg lifts to SSA */
  f->arena  = m->arena;
  grown = (LcFunc **)lc_arena_grow(m->arena, m->funcs, m->nfuncs,
                                   sizeof(LcFunc *));
  if (!grown) return NULL;  /* f stays in the arena; freed with the module */
  m->funcs = grown;
  m->funcs[m->nfuncs] = f;
  m->nfuncs++;
  return f;
}

LcBlock *lc_block_new(LcFunc *f) {
  if (!f) return NULL;
  LcBlock *blk = (LcBlock *)lc_arena_alloc(f->arena, sizeof(LcBlock));
  if (!blk) return NULL;
  blk->id    = f->nblocks;
  blk->arena = f->arena;
  LcBlock **grown = (LcBlock **)lc_arena_grow(f->arena, f->blocks, f->nblocks,
                                              sizeof(LcBlock *));
  if (!grown) return NULL;  /* blk stays in the arena; freed with the module */
  f->blocks = grown;
  f->blocks[f->nblocks] = blk;
  f->nblocks++;
  return blk;
}

LcInst *lc_emit(LcBlock *b, LcOpcode op) {
  if (!b) return NULL;
  LcInst *in = (LcInst *)lc_arena_alloc(b->arena, sizeof(LcInst));
  if (!in) return NULL;
  in->op    = op;
  in->arena = b->arena;
  /* Append to the block's doubly-linked instruction list. */
  in->prev = b->last;
  in->next = NULL;
  if (b->last) b->last->next = in;
  else         b->first = in;
  b->last = in;
  return in;
}

LcInst *lc_emit_bc(LcBlock *blk, LcOpcode op, int a, int b, int c, int bc_pc) {
  LcInst *in = lc_emit(blk, op);
  if (!in) return NULL;
  in->a = a;
  in->b = b;
  in->c = c;
  in->bc_pc = bc_pc;
  return in;
}

void lc_inst_add_arg(LcInst *in, LcValue *v) {
  if (!in) return;
  LcValue **grown = (LcValue **)lc_arena_grow(in->arena, in->args, in->nargs,
                                              sizeof(LcValue *));
  if (!grown) return;
  in->args = grown;
  in->args[in->nargs] = v;
  in->nargs++;
}

/* ---- type lattice ---- */

LcType lc_type_meet(LcType a, LcType b) {
  /* TODO(M1): proper lattice meet (narrow). Placeholder widens to ANY on mismatch. */
  if (a.kind == b.kind) return a;
  LcType any; memset(&any, 0, sizeof(any)); any.kind = LC_T_ANY; return any;
}

LcType lc_type_join(LcType a, LcType b) {
  /* TODO(M1): proper lattice join (widen). */
  if (a.kind == b.kind) return a;
  LcType any; memset(&any, 0, sizeof(any)); any.kind = LC_T_ANY; return any;
}

bool lc_type_is_unboxable(LcType t) {
  return t.kind == LC_T_INT || t.kind == LC_T_FLT || t.kind == LC_T_BOOL;
}

/* ---------------------------------------------------------------------------
** IR verifier.
**
** Only checks that are PROVABLE facts of the current memory form. Each one is
** here because a real bug would violate it, not to pad the list:
**
**   * arena identity -- lc_module_free releases the IR by walking the module's
**     arena chunks, so a node allocated from a different arena is a
**     use-after-free waiting for the second module to be freed. A future
**     inliner splicing nodes across modules is exactly how that happens.
**   * list linkage -- codegen walks blk->first..NULL by ->next and the
**     optimizer edits with ->prev; a half-updated splice loses instructions
**     silently (they simply stop being emitted) rather than crashing.
**   * one instruction per bytecode pc -- codegen records PcOff[bc_pc] and
**     resolves every branch through it, so a duplicate or out-of-range bc_pc
**     makes a branch land on the wrong instruction.
**   * branch targets -- lift resolves JMP/FORPREP/FORLOOP targets into ->c; a
**     target no instruction occupies produces a jump into the middle of an
**     emitted sequence.
**   * operand ranges -- a/b/c index the source Proto's registers, constants,
**     upvalues and nested protos. Out of range reads adjacent heap memory at
**     runtime, which is the class of bug the OP_SELF k-bit miscompile was.
**
** SSA invariants (single definition, dominance, phi arity == pred count) are
** NOT checked: is_ssa is false for every function today because lc_pass_mem2reg
** is a stub. They are listed explicitly at the bottom so the gap is visible
** rather than forgotten.
** ------------------------------------------------------------------------- */

static bool lc_verr(char *err, size_t errlen, const char *fmt, ...) {
  /* Reports the FIRST failure only: later ones are usually consequences. */
  if (err && errlen) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
  }
  return false;
}

static bool lc_verify_func(LcFunc *f, uint32_t fi, char *err, size_t errlen) {
  Proto   *p;
  int      sizecode, maxstack, sizek, sizeup, sizep;
  uint32_t bi;
  LcInst **at_pc = NULL;
  bool     ok = true;

  if (!f)          return lc_verr(err, errlen, "func %u is NULL", fi);
  if (!f->arena)   return lc_verr(err, errlen, "func %u has no arena", fi);
  if (!f->source)  return lc_verr(err, errlen, "func %u has no source Proto", fi);
  if (f->nblocks == 0 || !f->blocks)
    return lc_verr(err, errlen, "func %u has no blocks", fi);
  /* Memory form: parameters are Lua stack slots, not SSA ARG values. A non-empty
  ** args array here means someone started an SSA transform without setting
  ** is_ssa, and the SSA checks below would then be skipped for it. */
  if (!f->is_ssa && (f->args != NULL || f->nargs != 0))
    return lc_verr(err, errlen,
                   "func %u is not SSA but carries %u ARG values", fi, f->nargs);

  p        = f->source;
  sizecode = p->sizecode;
  maxstack = p->maxstacksize;
  sizek    = p->sizek;
  sizeup   = p->sizeupvalues;
  sizep    = p->sizep;

  if (sizecode > 0) {
    at_pc = (LcInst **)calloc((size_t)sizecode, sizeof(LcInst *));
    if (!at_pc) return lc_verr(err, errlen, "verify: out of memory");
  }

  /* pass 1: structure, arena identity, and the pc map */
  for (bi = 0; ok && bi < f->nblocks; bi++) {
    LcBlock *blk = f->blocks[bi];
    LcInst  *in;
    if (!blk) { ok = lc_verr(err, errlen, "func %u block %u is NULL", fi, bi); break; }
    if (blk->arena != f->arena) {
      ok = lc_verr(err, errlen, "func %u block %u belongs to another arena",
                   fi, bi);
      break;
    }
    if ((blk->first == NULL) != (blk->last == NULL)) {
      ok = lc_verr(err, errlen, "func %u block %u has a half-empty list", fi, bi);
      break;
    }
    if (blk->first && blk->first->prev != NULL) {
      ok = lc_verr(err, errlen, "func %u block %u: first->prev is not NULL",
                   fi, bi);
      break;
    }
    if (blk->last && blk->last->next != NULL) {
      ok = lc_verr(err, errlen, "func %u block %u: last->next is not NULL",
                   fi, bi);
      break;
    }
    /* One LcBlock per function today (branches resolve by bc_pc in codegen), so
    ** a populated CFG edge here means an analysis wrote state the rest of the
    ** pipeline does not read. */
    if (!f->is_ssa && (blk->npreds != 0 || blk->nsuccs != 0)) {
      ok = lc_verr(err, errlen,
                   "func %u block %u has CFG edges in memory form (%u/%u)",
                   fi, bi, blk->npreds, blk->nsuccs);
      break;
    }
    for (in = blk->first; in; in = in->next) {
      if (in->arena != blk->arena) {
        ok = lc_verr(err, errlen, "func %u block %u: instruction from another arena",
                     fi, bi);
        break;
      }
      if (in->next && in->next->prev != in) {
        ok = lc_verr(err, errlen,
                     "func %u block %u: broken next/prev linkage at pc %d",
                     fi, bi, in->bc_pc);
        break;
      }
      if ((int)in->op < 0 || (int)in->op >= LC_OP__COUNT) {
        ok = lc_verr(err, errlen, "func %u pc %d: opcode %d out of range",
                     fi, in->bc_pc, (int)in->op);
        break;
      }
      if (in->bc_pc < 0 || in->bc_pc >= sizecode) {
        ok = lc_verr(err, errlen, "func %u: bc_pc %d outside [0,%d)",
                     fi, in->bc_pc, sizecode);
        break;
      }
      if (at_pc[in->bc_pc]) {
        ok = lc_verr(err, errlen, "func %u: two instructions at bc_pc %d",
                     fi, in->bc_pc);
        break;
      }
      at_pc[in->bc_pc] = in;

      /* operand ranges against the source Proto */
      /* Upvalue index for the two TABUP opcodes -- how every global access is
      ** compiled, since _ENV is an upvalue, so this is the most-executed operand
      ** of the lot. The GETUPVAL/SETUPVAL case below does NOT cover them.
      **
      ** THE OPERAND DIFFERS BETWEEN THEM, which is not guessable and cost a
      ** broken build to learn (lopcodes.h:213,218 and lift.c:300-311 are the
      ** authority, not intuition):
      **     OP_GETTABUP A B C   R[A] := UpValue[B][K[C]]   -> upvalue is B
      **     OP_SETTABUP A B C   UpValue[A][K[B]] := RK(C)   -> upvalue is A
      ** Using `b` for both rejects valid IR: for SETTABUP, b is the constant-key
      ** index, which legitimately exceeds sizeupvalues. Three differential cases
      ** caught it immediately -- a verifier that rejects correct programs is
      ** worse than one that checks too little.
      **
      ** The constant KEY indexes are deliberately NOT checked here. lift.c
      ** Ck-encodes some operands (`k ? -C-1 : C`) and OP_SELF switches C between
      ** a constant and a register above 255 constants, so a naive range check on
      ** those fields is exactly the same class of false rejection. Checking them
      ** needs the encoding verified per opcode first. */
      if (in->bc_op == OP_GETTABUP && (in->b < 0 || in->b >= sizeup)) {
        ok = lc_verr(err, errlen,
                     "func %u pc %d (GETTABUP): upvalue index %d outside [0,%d)",
                     fi, in->bc_pc, in->b, sizeup);
        break;
      }
      if (in->bc_op == OP_SETTABUP && (in->a < 0 || in->a >= sizeup)) {
        ok = lc_verr(err, errlen,
                     "func %u pc %d (SETTABUP): upvalue index %d outside [0,%d)",
                     fi, in->bc_pc, in->a, sizeup);
        break;
      }
      if (in->op == LC_OP_CLOSURE && (in->b < 0 || in->b >= sizep)) {
        ok = lc_verr(err, errlen,
                     "func %u pc %d: nested-proto index %d outside [0,%d)",
                     fi, in->bc_pc, in->b, sizep);
        break;
      }
      if ((in->bc_op == OP_GETUPVAL || in->bc_op == OP_SETUPVAL) &&
          (in->b < 0 || in->b >= sizeup)) {
        ok = lc_verr(err, errlen,
                     "func %u pc %d: upvalue index %d outside [0,%d)",
                     fi, in->bc_pc, in->b, sizeup);
        break;
      }
      if (in->bc_op == OP_LOADK && (in->b < 0 || in->b >= sizek)) {
        ok = lc_verr(err, errlen,
                     "func %u pc %d: constant index %d outside [0,%d)",
                     fi, in->bc_pc, in->b, sizek);
        break;
      }
      /* A writes a register for the great majority of ops; testAMode is Lua's
      ** own "sets register A" bit. OP_VARARGPREP is excluded because its A is
      ** the fixed-parameter COUNT, which legitimately equals maxstacksize. */
      if (in->bc_op >= 0 && in->bc_op < NUM_OPCODES &&
          testAMode((OpCode)in->bc_op) && in->bc_op != OP_VARARGPREP &&
          (in->a < 0 || in->a >= maxstack)) {
        ok = lc_verr(err, errlen,
                     "func %u pc %d (bc_op %d): register A=%d outside [0,%d)",
                     fi, in->bc_pc, in->bc_op, in->a, maxstack);
        break;
      }
    }
  }

  /* pass 2: resolved branch targets must land on a real instruction */
  if (ok) {
    for (bi = 0; ok && bi < f->nblocks; bi++) {
      LcInst *in;
      for (in = f->blocks[bi]->first; in; in = in->next) {
        if (in->bc_op != OP_JMP && in->bc_op != OP_FORPREP &&
            in->bc_op != OP_FORLOOP && in->bc_op != OP_TFORLOOP) continue;
        if (in->c < 0 || in->c >= sizecode) {
          ok = lc_verr(err, errlen,
                       "func %u pc %d: branch target %d outside [0,%d)",
                       fi, in->bc_pc, in->c, sizecode);
          break;
        }
        if (!at_pc[in->c]) {
          ok = lc_verr(err, errlen,
                       "func %u pc %d: branch target %d has no instruction",
                       fi, in->bc_pc, in->c);
          break;
        }
      }
    }
  }

  free(at_pc);
  return ok;
}

bool lc_module_verify(LcModule *m, char *err, size_t errlen) {
  uint32_t i;
  bool entry_seen = false;

  if (err && errlen) err[0] = '\0';

  if (!m)         return lc_verr(err, errlen, "module is NULL");
  if (!m->arena)  return lc_verr(err, errlen, "module has no arena");
  if (m->nfuncs == 0 || !m->funcs)
    return lc_verr(err, errlen, "module has no functions");
  if (!m->entry)  return lc_verr(err, errlen, "module has no entry function");
  if ((m->callees == NULL) != (m->ncallees == NULL))
    return lc_verr(err, errlen, "module call graph is half-built");

  for (i = 0; i < m->nfuncs; i++) {
    if (m->funcs[i] == m->entry) entry_seen = true;
    if (!lc_verify_func(m->funcs[i], i, err, errlen)) return false;
  }
  /* lc_codegen emits funcs[0..nfuncs) and the entry is called by name; an entry
  ** outside the array would be optimized but never emitted. */
  if (!entry_seen)
    return lc_verr(err, errlen, "module entry is not one of its functions");

  if (m->callees) {
    uint32_t j;
    for (i = 0; i < m->nfuncs; i++) {
      if (!m->callees[i]) continue;
      for (j = 0; j < m->ncallees[i]; j++) {
        if (m->callees[i][j] >= m->nfuncs)
          return lc_verr(err, errlen,
                         "module callee edge %u->%u out of range (nfuncs=%u)",
                         i, m->callees[i][j], m->nfuncs);
      }
    }
  }

  /* TODO(M1), gated on f->is_ssa once lc_pass_mem2reg stops being a stub:
  ** single definition per LcValue; every use dominated by its def; phi arity
  ** == npreds with operands positionally matched to preds; exactly one
  ** terminator per block; blocks in RPO; no LC_OP_CALL_FFI marked PURE. Those
  ** invariants do not hold in the memory form, so asserting them now would
  ** fail on correct IR. */
  return true;
}
