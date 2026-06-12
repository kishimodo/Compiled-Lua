/* test_ffi_lib_basic.c -- ffi.cdef + ffi.new + ffi.sizeof/alignof/offsetof basics.
 * Exercises the core FFI library interface at the Lua API level. */
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

static void *TestJitHook(lua_State *L, void *Proto) {
    return (void *)Jit_Compile(L, (struct Proto *)Proto);
}

static int RunLua(lua_State *L, const char *Src) {
    if (luaL_loadstring(L, Src) != LUA_OK) {
        fprintf(stderr, "  load error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        return 0;
    }
    if (lua_pcall(L, 0, LUA_MULTRET, 0) != LUA_OK) {
        fprintf(stderr, "  runtime error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        return 0;
    }
    return 1;
}

int main(void) {
    TEST_BEGIN("ffi_lib_basic");

    clua_dispatch_hook = TestJitHook;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* ffi.sizeof("int") == 4 */
    CHECK_MSG(RunLua(L, "return ffi.sizeof('int')"), "sizeof int runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 4);
    lua_pop(L, 1);

    /* ffi.sizeof("DWORD") == 4 */
    CHECK_MSG(RunLua(L, "return ffi.sizeof('DWORD')"), "sizeof DWORD runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 4);
    lua_pop(L, 1);

    /* ffi.sizeof("double") == 8 */
    CHECK_MSG(RunLua(L, "return ffi.sizeof('double')"), "sizeof double runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 8);
    lua_pop(L, 1);

    /* ffi.alignof("double") == 8 */
    CHECK_MSG(RunLua(L, "return ffi.alignof('double')"), "alignof double runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 8);
    lua_pop(L, 1);

    /* ffi.alignof("int") == 4 */
    CHECK_MSG(RunLua(L, "return ffi.alignof('int')"), "alignof int runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 4);
    lua_pop(L, 1);

    /* ffi.sizeof("int", 10) == 40 (flex-array style) */
    CHECK_MSG(RunLua(L, "return ffi.sizeof('int', 10)"), "sizeof int x10 runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 40);
    lua_pop(L, 1);

    /* ffi.new("int") returns a cdata */
    CHECK_MSG(RunLua(L, "return ffi.new('int')"), "new int runs");
    CHECK_MSG(FfiIsCData(L, -1), "new int returns cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK(Cd->Type == Ctype_Lookup("int"));
    }
    lua_pop(L, 1);

    /* ffi.new("double") */
    CHECK_MSG(RunLua(L, "return ffi.new('double')"), "new double runs");
    CHECK_MSG(FfiIsCData(L, -1), "new double returns cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_FLOAT);
        CHECK_EQ_INT((int)Cd->Type->Size, 8);
    }
    lua_pop(L, 1);

    /* ffi.cdef struct, ffi.new struct, check Kind+Size */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct Vec2 { float x; float y; };');"
        "return ffi.new('struct Vec2')"),
        "cdef+new struct Vec2");
    CHECK_MSG(FfiIsCData(L, -1), "struct Vec2 returns cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_STRUCT);
        CHECK_EQ_INT((int)Cd->Type->Size, 8);
    }
    lua_pop(L, 1);

    /* ffi.offsetof("struct Vec2", "y") == 4 */
    CHECK_MSG(RunLua(L, "return ffi.offsetof('struct Vec2', 'y')"),
              "offsetof Vec2.y runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 4);
    lua_pop(L, 1);

    /* ffi.offsetof("struct Vec2", "x") == 0 */
    CHECK_MSG(RunLua(L, "return ffi.offsetof('struct Vec2', 'x')"),
              "offsetof Vec2.x runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 0);
    lua_pop(L, 1);

    /* ffi.sizeof("struct Vec2") == 8 */
    CHECK_MSG(RunLua(L, "return ffi.sizeof('struct Vec2')"),
              "sizeof struct Vec2 runs");
    CHECK_EQ_INT(lua_tointeger(L, -1), 8);
    lua_pop(L, 1);

    /* ffi.cdef typedef, ffi.new via typedef name */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('typedef struct Vec2 Vec2_t;');"
        "return ffi.new('Vec2_t')"),
        "typedef cdef+new Vec2_t");
    CHECK_MSG(FfiIsCData(L, -1), "Vec2_t via typedef returns cdata");
    lua_pop(L, 1);

    /* ffi.new struct, write and read back a field */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct IPoint { int x; int y; };');"
        "local p = ffi.new('struct IPoint');"
        "p.x = 11; p.y = 22;"
        "return p.x + p.y"),
        "ffi.new struct field write+read");
    CHECK_EQ_INT(lua_tointeger(L, -1), 33);
    lua_pop(L, 1);

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
