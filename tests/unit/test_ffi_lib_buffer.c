/* test_ffi_lib_buffer.c -- ffi.fill / ffi.copy / ffi.string on buffers. */
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
    TEST_BEGIN("ffi_lib_buffer");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* --- ffi.copy from Lua string + ffi.string with explicit length --- */
    CHECK_MSG(RunLua(L,
        "local b = ffi.new('char[16]');"
        "ffi.copy(b, 'hello', 5);"
        "return ffi.string(b, 5)"),
        "copy + string with length");
    CHECK_EQ_STR(lua_tostring(L, -1), "hello");
    lua_pop(L, 1);

    /* --- ffi.copy + ffi.string NUL-terminated (6 bytes: 5 chars + NUL) --- */
    CHECK_MSG(RunLua(L,
        "local b = ffi.new('char[16]');"
        "ffi.copy(b, 'world', 6);"    /* 5 chars + NUL */
        "return ffi.string(b)"),
        "copy + string NUL-terminated");
    CHECK_EQ_STR(lua_tostring(L, -1), "world");
    lua_pop(L, 1);

    /* --- ffi.fill with explicit byte value 'A' (65) --- */
    CHECK_MSG(RunLua(L,
        "local b = ffi.new('char[16]');"
        "ffi.fill(b, 5, 65);"          /* 65 = 'A' */
        "return ffi.string(b, 5)"),
        "fill 'A'");
    CHECK_EQ_STR(lua_tostring(L, -1), "AAAAA");
    lua_pop(L, 1);

    /* --- ffi.fill with default value 0 clears bytes --- */
    CHECK_MSG(RunLua(L,
        "local b = ffi.new('char[16]');"
        "ffi.fill(b, 5, 65);"          /* write 'A' x5 */
        "ffi.fill(b, 3);"              /* overwrite first 3 with 0 */
        "return ffi.string(b, 5)"),
        "fill default 0 overwrites");
    {
        size_t Len = 0;
        const char *S = lua_tolstring(L, -1, &Len);
        CHECK_NOT_NULL(S);
        CHECK_EQ_INT((int)Len, 5);
        CHECK_EQ_INT(memcmp(S, "\0\0\0AA", 5), 0);
    }
    lua_pop(L, 1);

    /* --- ffi.fill full buffer with 0xFF then read back --- */
    CHECK_MSG(RunLua(L,
        "local b = ffi.new('char[4]');"
        "ffi.fill(b, 4, 0xFF);"
        "return ffi.string(b, 4)"),
        "fill 0xFF x4");
    {
        size_t Len = 0;
        const char *S = lua_tolstring(L, -1, &Len);
        CHECK_NOT_NULL(S);
        CHECK_EQ_INT((int)Len, 4);
        CHECK_EQ_INT(memcmp(S, "\xFF\xFF\xFF\xFF", 4), 0);
    }
    lua_pop(L, 1);

    /* --- ffi.string from char* pointer with explicit length --- */
    CHECK_MSG(RunLua(L,
        "local b = ffi.new('char[8]');"
        "ffi.copy(b, 'abcde', 5);"
        "local p = ffi.cast('char*', b);"
        "return ffi.string(p, 3)"),    /* only first 3 chars */
        "string from char* with length");
    CHECK_EQ_STR(lua_tostring(L, -1), "abc");
    lua_pop(L, 1);

    /* --- ffi.copy from another buffer (cdata src, not a Lua string) --- */
    CHECK_MSG(RunLua(L,
        "local src = ffi.new('char[8]');"
        "local dst = ffi.new('char[8]');"
        "ffi.copy(src, 'test', 5);"     /* 4+NUL */
        "ffi.copy(dst, src, 5);"
        "return ffi.string(dst)"),
        "copy cdata->cdata");
    CHECK_EQ_STR(lua_tostring(L, -1), "test");
    lua_pop(L, 1);

    /* --- ffi.string length 0 returns empty string --- */
    CHECK_MSG(RunLua(L,
        "local b = ffi.new('char[4]');"
        "ffi.fill(b, 4, 65);"
        "return ffi.string(b, 0)"),
        "string length 0");
    {
        size_t Len = 999;
        lua_tolstring(L, -1, &Len);
        CHECK_EQ_INT((int)Len, 0);
    }
    lua_pop(L, 1);

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
