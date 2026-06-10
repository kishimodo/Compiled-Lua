/* test_ffi_dispatch.c -- FFI call dispatcher: argument/return classification.
 * Calls real kernel32 functions (0-arg, 1-arg, 2-arg, 3-arg) via ffi.C and
 * verifies correct marshalling and arg-count mismatch rejection. */
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
    TEST_BEGIN("ffi_dispatch");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    luavm_jit_compile_hook = TestJitHook;
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* 0 args, DWORD return: GetCurrentProcessId */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('DWORD GetCurrentProcessId(void);');"
        "return ffi.C.GetCurrentProcessId()"),
        "0-arg call GetCurrentProcessId");
    CHECK_MSG(lua_isinteger(L, -1), "result is integer");
    {
        lua_Integer Pid = lua_tointeger(L, -1);
        CHECK_MSG(Pid > 0, "pid > 0");
    }
    lua_pop(L, 1);

    /* 0 args, DWORD return: GetTickCount */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('DWORD GetTickCount(void);');"
        "return ffi.C.GetTickCount()"),
        "0-arg call GetTickCount");
    CHECK_MSG(lua_tointeger(L, -1) > 0, "tick count > 0");
    lua_pop(L, 1);

    /* 1 string arg, int return: lstrlenA("hello") == 5 */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('int lstrlenA(const char *s);');"
        "return ffi.C.lstrlenA('hello')"),
        "1-arg lstrlenA");
    CHECK_EQ_INT(lua_tointeger(L, -1), 5);
    lua_pop(L, 1);

    /* 2 string args, int return: lstrcmpA equal strings -> 0 */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('int lstrcmpA(const char *a, const char *b);');"
        "return ffi.C.lstrcmpA('foo', 'foo')"),
        "2-arg lstrcmpA equal");
    CHECK_EQ_INT(lua_tointeger(L, -1), 0);
    lua_pop(L, 1);

    /* 3 int args, int return: MulDiv(100, 200, 4) == 5000 */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('int MulDiv(int a, int b, int c);');"
        "return ffi.C.MulDiv(100, 200, 4)"),
        "3-arg MulDiv");
    CHECK_EQ_INT(lua_tointeger(L, -1), 5000);
    lua_pop(L, 1);

    /* arg-count mismatch is rejected */
    CHECK_MSG(!RunLua(L,
        "return ffi.C.lstrcmpA('only_one_arg')"),
        "wrong arg count rejected");
    lua_pop(L, 1);  /* error string */

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
