/*!
 * @brief
 *  FFI callbacks — convert a Lua function into a C function pointer the OS
 *  can call directly (qsort, EnumWindows, WNDPROC, etc.).
 */

#ifndef LUAVM_FFI_CALLBACK_H
#define LUAVM_FFI_CALLBACK_H

#include "ffi/ctype.h"

#include "lua.h"

#include <stdint.h>

/*!
 * @brief
 *  Allocate a new callback. Pops the Lua function from the top of L's stack
 *  (storing it via luaL_ref), generates an x64 stub, and returns the stub's
 *  address (suitable for storing in a CT_FUNCPTR cdata's Ptr).
 *
 *  CallbackType must be CT_FUNCPTR with ElemType pointing to a CT_FUNC ctype
 *  (the actual signature).
 *
 *  Returns NULL on failure (stub pool exhausted, unsupported signature, etc.).
 */
void *Ffi_AllocCallback( lua_State *L, PCType_T CallbackType );

/*!
 * @brief
 *  Release a callback's stub slot and unbind its Lua function. StubAddr must
 *  be a pointer previously returned by Ffi_AllocCallback. After this call,
 *  invoking the stub address is undefined behaviour.
 *
 *  Returns 1 on success, 0 if StubAddr isn't a recognised callback.
 */
int Ffi_FreeCallback( lua_State *L, void *StubAddr );

/*!
 * @brief
 *  Swap the Lua function a live callback invokes, keeping the same stub
 *  address (LuaJIT cb:set(fn) semantics). Pops the new function from the
 *  top of L's stack regardless of outcome.
 *
 *  Returns 1 on success, 0 if StubAddr isn't a recognised callback.
 */
int Ffi_SetCallback( lua_State *L, void *StubAddr );

/*!
 * @brief
 *  C dispatcher called from every callback stub. StubId identifies which
 *  callback fired; ArgBuf is a stack-allocated uint64_t[N] populated by the
 *  stub from the native ABI registers/stack. Returns the user callback's
 *  raw 8-byte result (RAX). For double returns, the stub does `movq xmm0,rax`
 *  before ret.
 *
 *  Not for direct use — exposed only so the stub codegen can take its address.
 */
int64_t Callback_Dispatch( int StubId, uint64_t *ArgBuf );

/*!
 * @brief
 *  Bind the lua_State the dispatcher uses to invoke Lua callbacks.
 *  Called once at runtime startup. v1 is single-threaded — one state only.
 */
void Ffi_SetDispatchL( lua_State *L );

#endif /* LUAVM_FFI_CALLBACK_H */
