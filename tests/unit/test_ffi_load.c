/* test_ffi_load.c -- ffi.load / Ffi_OpenLoad: loading a system module,
 * symbol resolution via Ffi_ResolveSymbol, error on missing DLL. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/ffi_lib.h"
#include "ffi/win_types.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "jit/dispatch.h"
#include "lvm.h"

#include <stdint.h>
#include <string.h>

static int RunLua(lua_State *L, const char *Src) {
    if (luaL_loadstring(L, Src) != LUA_OK) {
        return 0;
    }
    if (lua_pcall(L, 0, LUA_MULTRET, 0) != LUA_OK) {
        return 0;
    }
    return 1;
}

int main(void) {
    TEST_BEGIN("ffi_load");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* ffi.load("kernel32") returns a CT_LIB cdata with non-null Ptr */
    CHECK_MSG(RunLua(L, "return ffi.load('kernel32')"), "ffi.load kernel32 succeeds");
    CHECK_MSG(FfiIsCData(L, -1), "returned value is a cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_LIB);
        CHECK_NOT_NULL(Cd->Ptr);
    }
    lua_pop(L, 1);

    /* ffi.load on a missing DLL raises an error */
    CHECK_MSG(!RunLua(L, "return ffi.load('definitely_not_a_real_dll_xyz')"),
              "missing DLL raises error");
    {
        const char *Err = lua_tostring(L, -1);
        CHECK_NOT_NULL(Err);
        CHECK_MSG(strstr(Err, "cannot load") != NULL, "error mentions 'cannot load'");
    }
    lua_pop(L, 1);

    /* ffi.load("ntdll") also returns valid CT_LIB cdata */
    CHECK_MSG(RunLua(L, "return ffi.load('ntdll')"), "ffi.load ntdll succeeds");
    CHECK_MSG(FfiIsCData(L, -1), "ntdll cdata returned");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_LIB);
        CHECK_NOT_NULL(Cd->Ptr);
    }
    lua_pop(L, 1);

    /* ffi.load twice on the same DLL — both return valid ptr cdata */
    CHECK_MSG(RunLua(L,
        "local a = ffi.load('kernel32');"
        "local b = ffi.load('kernel32');"
        "return not not string.find(tostring(a),'ptr'), "
               "not not string.find(tostring(b),'ptr')"),
        "double load both produce ptr cdata");
    CHECK_MSG(lua_toboolean(L, -2) && lua_toboolean(L, -1),
              "both tostring contain 'ptr'");
    lua_pop(L, 2);

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
