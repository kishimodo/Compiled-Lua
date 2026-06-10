/*!
 * @brief
 *  ffi.load implementation + ffi.C namespace + per-symbol resolution
 *  cache. Wires LoadLibraryA / GetProcAddress into the Lua-callable
 *  cdata machinery.
 */

#ifndef LUAVM_FFI_LOAD_H
#define LUAVM_FFI_LOAD_H

#include "ffi/cdata.h"
#include "ffi/ctype.h"

#include "lua.h"

/*!
 * @brief
 *  Registers ffi.load + ffi.C on the ffi table already on L's stack
 *  (top is the ffi table). Also performs the static preloads
 *  (kernel32, ntdll, advapi32) so ffi.C symbol lookup works without
 *  explicit ffi.load calls.
 */
void Ffi_OpenLoad( lua_State *L );

/*!
 * @brief
 *  Resolve a symbol against a CT_LIB namespace cdata. Returns 1 with a
 *  fresh CT_FUNC cdata pushed onto L's stack, 0 on failure (no cdata
 *  pushed; an error message is pushed instead).
 *
 *  The returned CT_FUNC cdata has NativeAddr populated via GetProcAddress.
 *  Subsequent lookups of the same symbol on the same namespace return
 *  the cached cdata (same userdata identity).
 */
int Ffi_ResolveSymbol( lua_State *L, PCData_T Namespace, const char *Sym );

/*!
 * @brief
 *  Append an HMODULE (passed as void*) to the global module list searched
 *  by ffi.C symbol lookups. Idempotent — duplicate handles are not re-added.
 */
void Ffi_RegisterModule( void *Hm );

/*!
 * @brief
 *  Helper for the JIT: walks the loaded modules list and returns the
 *  first GetProcAddress hit for Sym, or NULL.
 */
void *Ffi_LookupSymAcrossModules( const char *Sym );

#endif /* LUAVM_FFI_LOAD_H */
