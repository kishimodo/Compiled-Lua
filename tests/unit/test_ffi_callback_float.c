/*!
 * test_ffi_callback_float.c -- callback with float/double args and return.
 *
 * Creates CT_FUNCPTR callbacks with double signatures; invokes the generated
 * x64 stubs directly from C and verifies XMM0/XMM1 marshalling + double
 * return (stub does MOVQ XMM0, RAX before RET for double-return sigs).
 */
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

#include <math.h>
#include <stdint.h>
#include <stdio.h>
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
    TEST_BEGIN("ffi_callback_float");

    clua_dispatch_hook = TestJitHook;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_OpenLib(L);
    Ffi_SetDispatchL(L);

    /* --- double(double, double) add callback --- */
    CHECK_MSG(RunLua(L, "ffi.cdef('typedef double (*AddD)(double, double);')"),
              "cdef AddD");
    lua_settop(L, 0);

    CHECK_MSG(RunLua(L,
        "return ffi.cast('AddD', function(a, b) return a + b end)"),
        "cast lua fn to AddD");
    int CbIdx = lua_gettop(L);
    CHECK_MSG(FfiIsCData(L, CbIdx), "AddD cast returns cdata");
    {
        PCData_T Cb = FfiGetCData(L, CbIdx);
        CHECK_NOT_NULL(Cb);
        CHECK_EQ_INT(Cb->Type->Kind, CT_FUNCPTR);
        CHECK_NOT_NULL(Cb->Ptr);
    }

    typedef double (*AddD)(double, double);
    {
        PCData_T Cb = FfiGetCData(L, CbIdx);
        AddD Fn = (AddD)Cb->Ptr;

        /* 1.5 + 2.25 == 3.75 */
        double Result = Fn(1.5, 2.25);
        CHECK_MSG(fabs(Result - 3.75) < 1e-9, "AddD(1.5, 2.25) == 3.75");

        /* -1.0 + 0.5 == -0.5 */
        Result = Fn(-1.0, 0.5);
        CHECK_MSG(fabs(Result - (-0.5)) < 1e-9, "AddD(-1.0, 0.5) == -0.5");

        /* 0.0 + 0.0 == 0.0 */
        Result = Fn(0.0, 0.0);
        CHECK_MSG(fabs(Result) < 1e-15, "AddD(0, 0) == 0");

        /* large values */
        Result = Fn(1e10, 2e10);
        CHECK_MSG(fabs(Result - 3e10) < 1.0, "AddD(1e10, 2e10) == 3e10");
    }

    /* --- double(double, double) multiply callback --- */
    CHECK_MSG(RunLua(L,
        "return ffi.cast('AddD', function(a, b) return a * b end)"),
        "cast mul callback (double)");
    {
        PCData_T Cb = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cb->Ptr);
        AddD Fn = (AddD)Cb->Ptr;

        double Result = Fn(3.0, 2.5);
        CHECK_MSG(fabs(Result - 7.5) < 1e-9, "MulD(3.0, 2.5) == 7.5");

        Result = Fn(-2.0, 4.0);
        CHECK_MSG(fabs(Result - (-8.0)) < 1e-9, "MulD(-2, 4) == -8");
    }
    lua_pop(L, 1);

    /* --- double(double) unary callback (single XMM arg) --- */
    CHECK_MSG(RunLua(L, "ffi.cdef('typedef double (*NegD)(double);')"),
              "cdef NegD");
    CHECK_MSG(RunLua(L,
        "return ffi.cast('NegD', function(x) return -x end)"),
        "cast NegD callback");
    {
        PCData_T Cb = FfiGetCData(L, -1);
        CHECK_NOT_NULL(Cb->Ptr);
        typedef double (*NegD)(double);
        NegD Fn = (NegD)Cb->Ptr;
        CHECK_MSG(fabs(Fn(5.5) - (-5.5)) < 1e-9,  "NegD(5.5) == -5.5");
        CHECK_MSG(fabs(Fn(-3.0) - 3.0) < 1e-9,    "NegD(-3.0) == 3.0");
    }
    lua_pop(L, 1);

    Ctype_Shutdown();
    lua_close(L);
    TEST_END();
}
