/*!
 * @brief
 *  Registers the `ffi` global library table on L. Idempotent.
 *  After Ffi_OpenLib, Lua scripts can call ffi.new, ffi.cast, etc.
 */

#ifndef CLUA_FFI_LIB_H
#define CLUA_FFI_LIB_H

#include "lua.h"

void Ffi_OpenLib( lua_State *L );

#endif /* CLUA_FFI_LIB_H */
