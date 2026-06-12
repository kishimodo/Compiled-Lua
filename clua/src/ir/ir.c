/*
** ir.c — LcModule/LcFunc/LcBlock/LcInst construction + SSA verifier.
** See ir.h and ../../PROMPT.md §7. STUB: implement for Milestone M0.
*/
#include "ir.h"
#include <stdlib.h>
#include <string.h>

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

bool lc_module_verify(LcModule *m, char *err, size_t errlen) {
  if (err && errlen) err[0] = '\0';
  /* M0 memory form: functions are pre-SSA (is_ssa == false), so the
  ** SSA-specific invariants (single-definition, dominance, phi arity ==
  ** pred count, no LC_OP_CALL_FFI marked PURE, ...) do NOT yet hold and
  ** must be gated behind f->is_ssa once M1 mem2reg runs.
  ** TODO(M1): assert those invariants for is_ssa functions. */
  (void)m;
  return true;
}
