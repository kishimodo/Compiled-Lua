/* test_ffi_c_namespace.c -- ffi.C namespace metatable: indexing a symbol.
 * Verifies ffi.C is CT_LIB cdata, resolves kernel32 + user32 symbols,
 * and rejects symbols absent from all loaded modules. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/ffi_lib.h"
#include "ffi/ffi_load.h"
#include "ffi/win_types.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "jit/dispatch.h"
#include "lvm.h"

static void *TestJitHook(lua_State *L, void *Proto) {
    return (void *)Jit_Compile(L, (struct Proto *)Proto);
}

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
    TEST_BEGIN("ffi_c_namespace");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    clua_dispatch_hook = TestJitHook;
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* ffi.C exists and is a CT_LIB cdata */
    CHECK_MSG(RunLua(L, "return ffi.C"), "ffi.C accessible");
    CHECK_MSG(FfiIsCData(L, -1), "ffi.C is cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_LIB);
    }
    lua_pop(L, 1);

    /* ffi.C.GetCurrentProcessId resolves without explicit ffi.load
       (kernel32 is statically preloaded) */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('DWORD GetCurrentProcessId(void);');"
        "return ffi.C.GetCurrentProcessId"),
        "ffi.C.GetCurrentProcessId resolved");
    CHECK_MSG(FfiIsCData(L, -1), "resolved to cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_FUNC);
        CHECK_NOT_NULL(Cd->Ptr);
    }
    lua_pop(L, 1);

    /* After ffi.load("user32"), a user32-only symbol resolves via ffi.C */
    CHECK_MSG(RunLua(L,
        "ffi.load('user32');"
        "ffi.cdef('int MessageBoxA(void *hwnd, const char *text, const char *cap, unsigned int type);');"
        "return ffi.C.MessageBoxA"),
        "ffi.C.MessageBoxA after loading user32");
    CHECK_MSG(FfiIsCData(L, -1), "MessageBoxA is cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_FUNC);
        CHECK_NOT_NULL(Cd->Ptr);
    }
    lua_pop(L, 1);

    /* A cdef'd-but-not-exported symbol fails on ffi.C lookup */
    CHECK_MSG(RunLua(L, "ffi.cdef('void TotallyMadeUpFunction(void);')"),
              "cdef bogus symbol");
    CHECK_MSG(!RunLua(L, "return ffi.C.TotallyMadeUpFunction"),
              "bogus symbol rejected on ffi.C");
    lua_pop(L, 1);  /* error string */

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
