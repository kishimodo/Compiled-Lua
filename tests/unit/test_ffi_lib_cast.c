/* test_ffi_lib_cast.c -- ffi.cast comprehensive coverage.
 * Required R1 features:
 *   - array->pointer arithmetic decay (arr+n)
 *   - cast a Lua string to char* (raw bytes)
 *   - cast a Lua string to WCHAR* / unsigned short* (UTF-16 transcode)
 *   - numeric <-> pointer casts with round-trips
 */
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
    TEST_BEGIN("ffi_lib_cast");

    luavm_jit_compile_hook = TestJitHook;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);

    /* --- numeric -> pointer cast (void*) --- */
    CHECK_MSG(RunLua(L, "return ffi.cast('void*', 0xDEADBEEF)"),
              "cast int to void*");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_PTR);
        CHECK_EQ_INT((unsigned long long)Cd->Ptr, 0xDEADBEEFULL);
    }
    lua_pop(L, 1);

    /* --- numeric -> pointer cast (int*) --- */
    CHECK_MSG(RunLua(L, "return ffi.cast('int*', 0x1000)"),
              "cast int to int*");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_PTR);
        CHECK_EQ_INT(Cd->Type->ElemType->Kind, CT_INT);
        CHECK_EQ_INT((unsigned long long)Cd->Ptr, 0x1000ULL);
    }
    lua_pop(L, 1);

    /* --- pointer -> integer round-trip: cast void* back to uintptr_t cdata --- */
    CHECK_MSG(RunLua(L,
        "local p = ffi.cast('void*', 0x12345678);"
        "return ffi.cast('uintptr_t', p)"),
        "pointer->integer round-trip (cdata)");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_INT);
        /* I64 holds the pointer value after CT_PTR -> CT_INT reinterpret */
        CHECK_EQ_INT((unsigned long long)Cd->I64, 0x12345678ULL);
    }
    lua_pop(L, 1);

    /* --- pointer type coercion: int* -> char* --- */
    CHECK_MSG(RunLua(L,
        "local p = ffi.cast('int*', 0x2000);"
        "return ffi.cast('char*', p)"),
        "int* to char* recast");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_PTR);
        CHECK_EQ_INT(Cd->Type->ElemType->Size, 1);
        CHECK_EQ_INT((unsigned long long)Cd->Ptr, 0x2000ULL);
    }
    lua_pop(L, 1);

    /* --- Lua string -> char* (raw byte pointer, direct) --- */
    CHECK_MSG(RunLua(L, "return ffi.cast('const char*', 'hello')"),
              "string to char*");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_PTR);
        const char *Ptr = (const char *)Cd->Ptr;
        CHECK_NOT_NULL(Ptr);
        CHECK_EQ_INT(memcmp(Ptr, "hello", 5), 0);
    }
    lua_pop(L, 1);

    /* --- Lua string -> WCHAR* (unsigned short*, UTF-16 transcode) ---
       WCHAR is registered as `unsigned short` (size=2, CT_INT). The cast
       path detects ElemType->Size==2 and runs MultiByteToWideChar.        */
    CHECK_MSG(RunLua(L, "return ffi.cast('WCHAR*', 'A')"),
              "string to WCHAR*");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT(Cd->Type->Kind, CT_PTR);
        const unsigned short *Wp = (const unsigned short *)Cd->Ptr;
        CHECK_NOT_NULL(Wp);
        /* 'A' transcoded to UTF-16LE must be 0x0041 */
        CHECK_EQ_INT((int)Wp[0], 0x0041);
        /* NUL terminator */
        CHECK_EQ_INT((int)Wp[1], 0x0000);
    }
    lua_pop(L, 1);

    /* --- WCHAR* multi-char string: "Hi" -> 0x0048, 0x0069, 0x0000 --- */
    CHECK_MSG(RunLua(L, "return ffi.cast('WCHAR*', 'Hi')"),
              "string 'Hi' to WCHAR*");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        const unsigned short *Wp = (const unsigned short *)Cd->Ptr;
        CHECK_NOT_NULL(Wp);
        CHECK_EQ_INT((int)Wp[0], 0x0048);  /* 'H' */
        CHECK_EQ_INT((int)Wp[1], 0x0069);  /* 'i' */
        CHECK_EQ_INT((int)Wp[2], 0x0000);  /* NUL */
    }
    lua_pop(L, 1);

    /* --- array -> pointer decay: arr+n --- */
    CHECK_MSG(RunLua(L,
        "local arr = ffi.new('int[8]');"
        "for i=0,7 do arr[i] = i*10 end;"
        "local p = arr + 3;"   /* pointer to arr[3] */
        "return p[0]"),        /* dereference */
        "array+n decay and deref");
    CHECK_EQ_INT(lua_tointeger(L, -1), 30);
    lua_pop(L, 1);

    /* --- array + 0 is start element --- */
    CHECK_MSG(RunLua(L,
        "local arr = ffi.new('int[4]');"
        "arr[0] = 99;"
        "local p = arr + 0;"
        "return p[0]"),
        "array+0 is start element");
    CHECK_EQ_INT(lua_tointeger(L, -1), 99);
    lua_pop(L, 1);

    /* --- arr+n with last valid index --- */
    CHECK_MSG(RunLua(L,
        "local arr = ffi.new('int[5]');"
        "arr[4] = 77;"
        "local p = arr + 4;"
        "return p[0]"),
        "array+last decay and deref");
    CHECK_EQ_INT(lua_tointeger(L, -1), 77);
    lua_pop(L, 1);

    /* --- chained pointer cast round-trip via I64 read --- */
    CHECK_MSG(RunLua(L,
        "local p = ffi.cast('void*', 0xABC0);"
        "return ffi.cast('uintptr_t', p)"),
        "chain cast round-trip cdata");
    {
        PCData_T Cd = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cd);
        CHECK_EQ_INT((unsigned long long)Cd->I64, 0xABC0ULL);
    }
    lua_pop(L, 1);

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
