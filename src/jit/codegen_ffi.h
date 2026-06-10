/*!
 * @brief
 *  JIT inline trampoline for FFI calls. The JIT detects when a Lua
 *  register holds a known FFI CFunc cdata (resolved at JIT-compile
 *  time via Ffi_ResolveSymbol), and at OP_CALL emits inline x64 code
 *  instead of routing through Rt_Call.
 */

#ifndef LUAVM_JIT_CODEGEN_FFI_H
#define LUAVM_JIT_CODEGEN_FFI_H

#include "ffi/cdata.h"
#include "jit/exec_mem.h"
#include "lua.h"

/* The JIT keeps a per-Proto side table indexed by Lua register number.
   When a non-NULL entry is present, the JIT knows that register holds a
   constant FFI CFunc cdata with its Ptr already resolved. */
#define KNOWN_FFI_MAX_REGS 256

typedef struct {
    PCData_T  Known[ KNOWN_FFI_MAX_REGS ];
} KNOWN_FFI_T, *PKNOWN_FFI_T;

/*!
 * @brief
 *  Zero the side table. Called once at the start of every Proto's
 *  codegen.
 */
void KnownFfi_Reset( PKNOWN_FFI_T K );

/*!
 * @brief
 *  Mark Lua register Reg as holding a known FFI CFunc cdata.
 */
void KnownFfi_Mark( PKNOWN_FFI_T K, int Reg, PCData_T Cd );

/*!
 * @brief
 *  Clear the entry for Lua register Reg (called on any opcode that
 *  writes Reg and isn't a known-FFI-constant load).
 */
void KnownFfi_Clear( PKNOWN_FFI_T K, int Reg );

/*!
 * @brief
 *  Returns the known FFI CFunc cdata for Reg, or NULL if not known.
 */
PCData_T KnownFfi_Get( PKNOWN_FFI_T K, int Reg );

/*!
 * @brief
 *  Emit an inline FFI call trampoline at the current Slot position.
 *  The callee is a known CT_FUNC cdata FnCd with FnCd->Ptr already
 *  resolved. NArgs is the param count; A is the Lua register of the
 *  callee (args start at A+1, result goes to A).
 *
 *  Returns 1 on success, 0 if the call signature requires features
 *  the inline trampoline doesn't support (strings, structs, floats),
 *  in which case the caller should fall back to Rt_Call emission.
 */
int Lower_FfiCallInline( PEXEC_MEM_SLOT_T Slot, PCData_T FnCd, int A, int NArgs );

#endif /* LUAVM_JIT_CODEGEN_FFI_H */
