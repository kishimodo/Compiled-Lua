/*!
 * @brief
 *  Generic call dispatcher — invoked from cdata's __call metamethod
 *  when a CT_FUNC cdata is called. Marshals Lua args into Win64 ABI
 *  slots, dispatches via a per-arg-count C cast, marshals return back
 *  to Lua.
 *
 *  v1 limitation: 0-8 int/pointer args, int-or-pointer return. Float
 *  args and large struct returns are 6e's job.
 */

#ifndef CLUA_FFI_CALL_H
#define CLUA_FFI_CALL_H

#include "ffi/cdata.h"
#include "lua.h"

/*!
 * @brief
 *  Dispatch a call to FnCd (CT_FUNC cdata) with args at L's stack
 *  positions [BaseIdx .. BaseIdx + FnCd->Type->NumParams - 1].
 *  Pushes 0 or 1 return values onto L's stack.
 *  Returns number of pushed values, or raises a Lua error.
 */
int Ffi_GenericCall( lua_State *L, PCData_T FnCd, int BaseIdx );

/*!
 * @brief
 *  __call metamethod for the cdata metatable. Dispatches CT_FUNC to
 *  Ffi_GenericCall; raises for other kinds.
 */
int Cdata_Call( lua_State *L );

#endif /* CLUA_FFI_CALL_H */
