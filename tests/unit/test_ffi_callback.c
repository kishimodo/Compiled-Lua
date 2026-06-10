/* test_ffi_callback.c -- ffi.callback: create a C-callable thunk from a Lua
 * function; invoke it from C and verify the Lua side ran correctly. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/ffi_lib.h"
#include "ffi/ffi_load.h"
#include "ffi/ffi_callback.h"
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
    TEST_BEGIN("ffi_callback");

    luavm_jit_compile_hook = TestJitHook;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);
    Ffi_SetDispatchL(L);

    /* --- declare callback signature int(int, int) --- */
    CHECK_MSG(RunLua(L, "ffi.cdef('typedef int (*PairOp)(int, int);')"),
              "cdef PairOp typedef");
    lua_settop(L, 0);

    /* --- cast Lua function to PairOp: returns a CT_FUNCPTR cdata with Ptr set --- */
    CHECK_MSG(RunLua(L,
        "return ffi.cast('PairOp', function(a, b) return a + b end)"),
        "cast lua fn to PairOp");
    int CbIdx = lua_gettop(L);
    CHECK_MSG(FfiIsCData(L, CbIdx), "cast returns cdata");
    {
        PCData_T Cb = FfiGetCData(L, CbIdx);
        CHECK_NOT_NULL(Cb);
        CHECK_EQ_INT(Cb->Type->Kind, CT_FUNCPTR);
        CHECK_NOT_NULL(Cb->Ptr);
    }

    /* --- invoke the stub directly from C: 7 + 35 == 42 --- */
    typedef int (*PairOp)(int, int);
    {
        PCData_T Cb = FfiGetCData(L, CbIdx);
        PairOp Fn = (PairOp)Cb->Ptr;
        int Result = Fn(7, 35);
        CHECK_EQ_INT(Result, 42);
    }

    /* --- second invocation with different args --- */
    {
        PCData_T Cb = FfiGetCData(L, CbIdx);
        PairOp Fn = (PairOp)Cb->Ptr;
        CHECK_EQ_INT(Fn(100, -50), 50);
    }

    /* --- zero args --- */
    {
        PCData_T Cb = FfiGetCData(L, CbIdx);
        PairOp Fn = (PairOp)Cb->Ptr;
        CHECK_EQ_INT(Fn(0, 0), 0);
    }

    /* --- allocate a second callback: multiplication --- */
    CHECK_MSG(RunLua(L,
        "return ffi.cast('PairOp', function(a, b) return a * b end)"),
        "cast mul callback");
    int MulIdx = lua_gettop(L);
    CHECK_MSG(FfiIsCData(L, MulIdx), "mul callback is cdata");
    {
        PCData_T Cb = FfiGetCData(L, MulIdx);
        CHECK_NOT_NULL(Cb->Ptr);
        PairOp Fn = (PairOp)Cb->Ptr;
        CHECK_EQ_INT(Fn(6, 7), 42);
        CHECK_EQ_INT(Fn(3, 3), 9);
    }

    /* --- the two stubs are different pointers --- */
    {
        PCData_T Cb1 = FfiGetCData(L, CbIdx);
        PCData_T Cb2 = FfiGetCData(L, MulIdx);
        CHECK(Cb1->Ptr != Cb2->Ptr);
    }

    /* --- ffi.callback_free nulls Ptr; original callback at CbIdx unaffected --- */
    CHECK_MSG(RunLua(L,
        "local cb = ffi.cast('PairOp', function(a, b) return a - b end);"
        "ffi.callback_free(cb);"
        "return cb"),
        "cast + free");
    {
        PCData_T Freed = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Freed);
        CHECK_NULL(Freed->Ptr);
    }
    lua_pop(L, 1);

    /* original add callback still callable */
    {
        PCData_T Cb = FfiGetCData(L, CbIdx);
        CHECK_NOT_NULL(Cb->Ptr);
        PairOp Fn = (PairOp)Cb->Ptr;
        CHECK_EQ_INT(Fn(1, 2), 3);
    }

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
