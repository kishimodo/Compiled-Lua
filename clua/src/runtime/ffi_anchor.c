/*
** ffi_anchor.c — opt-in FFI initialization for AOT-compiled programs.
**
** aot_entry.c calls Clua_OpenFfi through a WEAK reference, so by default no
** compiled exe carries the FFI (~25 KB). When the resolve scan sees the
** program reference the `ffi`/`bit` runtime globals, the link adds
** -Wl,--undefined=Clua_OpenFfi, which extracts this member from
** runtime-aot.a and binds the weak call. Mirrors v1 runtime_init's FFI
** bring-up: type tables, Windows primitive typedefs, then the library
** (which installs the `ffi` global).
*/
#include "lua.h"
#include "ffi/ctype.h"
#include "ffi/ffi_lib.h"
#include "ffi/win_types.h"

void Clua_OpenFfi( lua_State *L ) {
    Ctype_Init( );
    Ffi_RegisterWindowsTypes( );
    Ffi_OpenLib( L );
}
