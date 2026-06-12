/*
** lift.h — Bytecode -> SSA IR lifting.
**
** Consumes the v1 front-end's Proto trees (lua-5.4/src/lobject.h, produced by
** src/compiler/lua_compile.c) and builds the LcModule. This is a faithful,
** semantics-preserving translation: NO optimization happens here — every op is
** emitted in its generic, metatable-aware, boxed form. The opt passes refine it.
**
** Algorithm (see ../../PROMPT.md §Lift):
**  1. Walk the reachable Proto set from the entry chunk + bundled packages
**     (the require-scan in src/compiler/resolve.c already enumerated them — this
**     is what makes the world "closed"). Each Proto -> one LcFunc.
**  2. Per function: reconstruct the CFG from bytecode jump targets; run a
**     standard SSA construction (Braun et al. / dominance-frontier phi insertion)
**     over Lua register slots, since Lua bytecode is register-based.
**  3. Map each opcode to its generic IR op:
**       OP_ADD/OP_SUB/...   -> LC_OP_ARITH
**       OP_GETTABLE/GETFIELD-> LC_OP_TABLE_GET
**       OP_SETTABLE/SETFIELD-> LC_OP_TABLE_SET
**       OP_GETUPVAL/SETUPVAL-> LC_OP_UPVAL_GET/SET
**       OP_GETTABUP _ENV    -> LC_OP_GLOBAL_GET
**       OP_CALL/TAILCALL    -> LC_OP_CALL/TAILCALL  (callee resolved later)
**       OP_CLOSURE          -> LC_OP_CLOSURE (records captured upvalues)
**       OP_FORPREP/FORLOOP  -> LC_OP_FORPREP_* / FORLOOP_* (subtype refined later)
**       OP_TFORCALL/TFORLOOP-> LC_OP_TFORCALL/TFORLOOP
**       ... (full table in PROMPT.md)
**  4. Record call-graph edges; mark ffi.* / C-function call sites as barriers.
**
** GOTCHAS to preserve exactly (else the differential test will catch you):
**  - Lua 5.4 integer/float subtypes and the coercion rules in lvm.c.
**  - Multiple-return / vararg adjustment (LUA_MULTRET) semantics.
**  - to-be-closed variables (OP_TBC / __close) and their scope-exit ordering.
**  - _ENV is upvalue[0] of the main chunk; globals are sugar for _ENV table ops.
*/
#ifndef LUAC_LIFT_H
#define LUAC_LIFT_H

#include "ir.h"

typedef struct Proto Proto;

/* Lift the closed reachable program rooted at `entry` into a fresh module.
** `reachable`/`nreachable` is the Proto set the require-scan produced. */
LcModule *lc_lift_program(Proto *entry, Proto **reachable, uint32_t nreachable);

/* Lift a single Proto into an (already-created) LcFunc. */
void lc_lift_func(LcFunc *f);

#endif /* LUAC_LIFT_H */
