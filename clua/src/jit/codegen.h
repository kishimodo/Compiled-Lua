/*!
 * @brief
 *  Per-opcode x64 lowering. Called by dispatch.c after a Proto's bytecode
 *  has been pre-scanned and confirmed JIT-able.
 */

#ifndef LUAVM_JIT_CODEGEN_H
#define LUAVM_JIT_CODEGEN_H

#include "jit/exec_mem.h"
#include "jit/regalloc.h"

#include "lua.h"
#include "lobject.h"

/*!
 * @brief
 *  Emit prologue, then one snippet per bytecode op, then epilogue, into
 *  Slot. Returns 1 on success, 0 if any emission failed.
 *
 *  If OutPcToOffset is non-NULL it must point to an array of size P->sizecode
 *  size_t entries. On successful return it is populated with the byte offset
 *  (within Slot->Code) of each Lua PC's emitted code start.
 */
int Codegen_EmitFunction( PEXEC_MEM_SLOT_T Slot,
                          Proto *P,
                          PREGALLOC_T RegAlloc,
                          size_t *OutPcToOffset );

#endif /* LUAVM_JIT_CODEGEN_H */
