/*
** stdlib_anchors.c -- opt-in standard-library opening for AOT exes.
**
** luaL_openlibs() opens the WHOLE standard library, which forces every
** luaopen_* (and its archive member: lstrlib.o, ltablib.o, ...) into the link
** even when a `print` program touches none of them. Instead, aot_entry.c opens
** the base + package libs directly (always needed) and calls one of these
** anchors per OPTIONAL library through a WEAK reference. The driver force-undefs
** (`-Wl,--undefined=` / the internal linker's force-undef roots) only the
** anchors for libraries the program actually references -- see
** lc_module_used_libs() in opt/passes.c. An anchor that is not force-undef'd is
** swept by --gc-sections, its luaopen_* goes with it, and &Clua_OpenXxx is a
** weak-undefined null, so aot_entry skips it. Each anchor is its own section
** (the runtime archive is -ffunction-sections), so the sweep is per-library.
**
** Mirrors the FFI's Clua_OpenFfi anchor (ffi_anchor.c) exactly.
*/
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#define CLUA_STDLIB_ANCHOR( Fn, Name, Open )         \
    void Fn( lua_State *L ) {                         \
        luaL_requiref( L, ( Name ), ( Open ), 1 );   \
        lua_pop( L, 1 );                             \
    }

CLUA_STDLIB_ANCHOR( Clua_OpenStrlib,  LUA_STRLIBNAME,  luaopen_string )
CLUA_STDLIB_ANCHOR( Clua_OpenTablib,  LUA_TABLIBNAME,  luaopen_table  )
CLUA_STDLIB_ANCHOR( Clua_OpenMathlib, LUA_MATHLIBNAME, luaopen_math   )
CLUA_STDLIB_ANCHOR( Clua_OpenIolib,   LUA_IOLIBNAME,   luaopen_io     )
CLUA_STDLIB_ANCHOR( Clua_OpenOslib,   LUA_OSLIBNAME,   luaopen_os     )
CLUA_STDLIB_ANCHOR( Clua_OpenUtf8lib, LUA_UTF8LIBNAME, luaopen_utf8   )
CLUA_STDLIB_ANCHOR( Clua_OpenDbglib,  LUA_DBLIBNAME,   luaopen_debug  )
