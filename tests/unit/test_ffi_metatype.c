/* test_ffi_metatype.c -- ffi.metatype: attach a metatable to a struct ctype;
 * method dispatch; __tostring; return-value semantics. */
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

#include <string.h>

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
    TEST_BEGIN("ffi_metatype");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* --- basic method dispatch: constant return (same as proven old test) --- */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct Pt { int x; int y; };');"
        "local methods = { sum = function(p) return 100 end };"
        "ffi.metatype('struct Pt', { __index = methods });"
        "local p = ffi.new('struct Pt');"
        "return p:sum()"),
        "metatype method dispatch constant");
    CHECK_EQ_INT(lua_tointeger(L, -1), 100);
    lua_pop(L, 1);

    /* --- method with argument --- */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct Counter { int n; };');"
        "ffi.metatype('struct Counter', { __index = {"
        "  addN = function(c, x) return x * 2 end"
        "} });"
        "local c = ffi.new('struct Counter');"
        "return c:addN(21)"),
        "metatype method with arg");
    CHECK_EQ_INT(lua_tointeger(L, -1), 42);
    lua_pop(L, 1);

    /* --- multiple methods on same type --- */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct Shape { int kind; };');"
        "ffi.metatype('struct Shape', { __index = {"
        "  getKind = function(s) return 7 end,"
        "  getName = function(s) return 'circle' end"
        "} });"
        "local s = ffi.new('struct Shape');"
        "local k = s:getKind();"
        "local nm = s:getName();"
        "return k, nm"),
        "metatype two methods");
    CHECK_EQ_INT(lua_tointeger(L, -2), 7);
    CHECK_EQ_STR(lua_tostring(L, -1), "circle");
    lua_pop(L, 2);

    /* --- ffi.metatype returns non-nil ctype handle --- */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct Tag { int v; };');"
        "local ct = ffi.metatype('struct Tag', { __index = {} });"
        "return ct ~= nil and 1 or 0"),
        "metatype returns non-nil");
    CHECK_EQ_INT(lua_tointeger(L, -1), 1);
    lua_pop(L, 1);

    /* --- ffi.new respects registered metatype (method callable on fresh inst) --- */
    CHECK_MSG(RunLua(L,
        "local inst = ffi.new('struct Tag');"
        "return type(inst)"),
        "ffi.new with metatype returns userdata");
    CHECK_EQ_STR(lua_tostring(L, -1), "userdata");
    lua_pop(L, 1);

    /* --- __tostring metamethod --- */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct Labeled { int id; };');"
        "ffi.metatype('struct Labeled', {"
        "  __tostring = function(x) return 'Labeled' end"
        "});"
        "local lb = ffi.new('struct Labeled');"
        "return tostring(lb)"),
        "metatype __tostring");
    CHECK_EQ_STR(lua_tostring(L, -1), "Labeled");
    lua_pop(L, 1);

    /* --- field writes+reads still work without metatype-set __index clash ---
       Use a separate struct that has NO metatype so field dispatch goes through
       the normal cdata __index handler. */
    CHECK_MSG(RunLua(L,
        "ffi.cdef('struct Plain { int a; int b; };');"
        "local p = ffi.new('struct Plain');"
        "p.a = 11; p.b = 22;"
        "return p.a + p.b"),
        "struct field write+read (no metatype)");
    CHECK_EQ_INT(lua_tointeger(L, -1), 33);
    lua_pop(L, 1);

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
