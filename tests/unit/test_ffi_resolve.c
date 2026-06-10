/* test_ffi_resolve.c -- multi-module symbol resolver: Ffi_ResolveSymbol,
 * cache identity, undeclared symbol rejection, missing export rejection. */
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

#include <string.h>

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
    TEST_BEGIN("ffi_resolve");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    luavm_jit_compile_hook = TestJitHook;
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* Declare GetCurrentProcessId so the ctype table has its signature. */
    CHECK_MSG(RunLua(L, "ffi.cdef('DWORD GetCurrentProcessId(void);')"),
              "cdef GetCurrentProcessId");

    /* Resolve it on the kernel32 namespace -> CT_FUNC cdata with non-null Ptr */
    CHECK_MSG(RunLua(L,
        "local k32 = ffi.load('kernel32');"
        "return k32.GetCurrentProcessId"),
        "k32.GetCurrentProcessId resolved");
    CHECK_MSG(FfiIsCData(L, -1), "resolved value is cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_FUNC);
        CHECK_NOT_NULL(Cd->Ptr);
    }
    lua_pop(L, 1);

    /* Resolve same symbol twice — rawequal (cache returns identity) */
    CHECK_MSG(RunLua(L,
        "local k32 = ffi.load('kernel32');"
        "local a = k32.GetCurrentProcessId;"
        "local b = k32.GetCurrentProcessId;"
        "return rawequal(a, b)"),
        "double resolve rawequal");
    CHECK_MSG(lua_toboolean(L, -1), "rawequal is true (cached identity)");
    lua_pop(L, 1);

    /* Resolving a symbol not declared with cdef raises an error */
    CHECK_MSG(!RunLua(L,
        "local k32 = ffi.load('kernel32');"
        "return k32.SomeUnknownNotCdefdSymbol"),
        "undeclared symbol rejected");
    {
        const char *Err = lua_tostring(L, -1);
        CHECK_NOT_NULL(Err);
        CHECK_MSG(strstr(Err, "undeclared") != NULL, "error mentions 'undeclared'");
    }
    lua_pop(L, 1);

    /* Resolving a cdef'd-but-not-exported symbol raises an error */
    CHECK_MSG(RunLua(L, "ffi.cdef('void DefinitelyDoesNotExistInK32(void);')"),
              "cdef bogus symbol");
    CHECK_MSG(!RunLua(L,
        "local k32 = ffi.load('kernel32');"
        "return k32.DefinitelyDoesNotExistInK32"),
        "missing export rejected");
    {
        const char *Err = lua_tostring(L, -1);
        CHECK_NOT_NULL(Err);
        CHECK_MSG(strstr(Err, "not found") != NULL, "error mentions 'not found'");
    }
    lua_pop(L, 1);

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
