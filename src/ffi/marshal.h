/*!
 * @brief
 *  Marshal helpers: convert a Lua value (at L's stack index) to a C value
 *  of TargetType, written to Dst (Dst must point to at least TargetType->Size
 *  bytes). Returns the number of bytes written on success (== Type->Size),
 *  0 on type-incompatibility (an error message is set via lua_pushstring on
 *  the stack — caller's responsibility to raise it).
 */

#ifndef LUAVM_FFI_MARSHAL_H
#define LUAVM_FFI_MARSHAL_H

#include "ffi/ctype.h"

#include "lua.h"

#include <stddef.h>

int Marshal_LuaToC( lua_State *L, int StackIdx, PCType_T TargetType, void *Dst );

int Marshal_CToLua( lua_State *L, PCType_T SourceType, const void *Src );

#endif /* LUAVM_FFI_MARSHAL_H */
