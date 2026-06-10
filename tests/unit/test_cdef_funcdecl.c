/* test_cdef_funcdecl.c -- function declarations: return type, parameter types,
 * varargs, zero-param forms "(void)" and "()", function-pointer typedef,
 * anonymous (unnamed) parameters, and varargs with fixed params. */

#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"

int main(void) {
    TEST_BEGIN("cdef_funcdecl");

    PCType_T F;

    /* --- MessageBoxA: int func(void*, char*, char*, unsigned int) --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse(
        "int MessageBoxA(void *hWnd, char *text, char *caption, unsigned int type);"));
    F = Ctype_Lookup("MessageBoxA");
    CHECK_NOT_NULL(F);
    CHECK_EQ_INT(F->Kind, CT_FUNC);
    CHECK_NOT_NULL(F->ElemType);
    CHECK_EQ_INT(F->ElemType->Kind, CT_INT);
    CHECK_EQ_INT(F->NumParams, 4);
    CHECK_EQ_INT(F->ParamTypes[0]->Kind, CT_PTR);  /* void* */
    CHECK_EQ_INT(F->ParamTypes[1]->Kind, CT_PTR);  /* char* */
    CHECK_EQ_INT(F->ParamTypes[2]->Kind, CT_PTR);  /* char* */
    CHECK_EQ_INT(F->ParamTypes[3]->Kind, CT_INT);
    CHECK_EQ_INT(F->ParamTypes[3]->IsSigned, 0);   /* unsigned */
    CHECK_EQ_INT(F->HasVararg, 0);

    /* --- void return: Sleep(unsigned int) --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("void Sleep(unsigned int ms);"));
    F = Ctype_Lookup("Sleep");
    CHECK_NOT_NULL(F);
    CHECK_EQ_INT(F->Kind, CT_FUNC);
    CHECK_EQ_INT(F->ElemType->Kind, CT_VOID);
    CHECK_EQ_INT(F->NumParams, 1);
    CHECK_EQ_INT(F->ParamTypes[0]->IsSigned, 0);

    /* --- "(void)" sentinel: zero params --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("unsigned int GetVersion(void);"));
    F = Ctype_Lookup("GetVersion");
    CHECK_NOT_NULL(F);
    CHECK_EQ_INT(F->NumParams, 0);

    /* --- "()" empty: zero params --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("unsigned int GetTickCount();"));
    F = Ctype_Lookup("GetTickCount");
    CHECK_NOT_NULL(F);
    CHECK_EQ_INT(F->NumParams, 0);

    /* --- varargs: printf-style int (char*, ...) --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("int printf(char *fmt, ...);"));
    F = Ctype_Lookup("printf");
    CHECK_NOT_NULL(F);
    CHECK_EQ_INT(F->NumParams,  1);
    CHECK_EQ_INT(F->HasVararg,  1);
    CHECK_EQ_INT(F->ParamTypes[0]->Kind, CT_PTR);

    /* --- anonymous (unnamed) param: int NtClose(void*) --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("int NtClose(void*);"));
    F = Ctype_Lookup("NtClose");
    CHECK_NOT_NULL(F);
    CHECK_EQ_INT(F->NumParams, 1);
    CHECK_EQ_INT(F->ParamTypes[0]->Kind, CT_PTR);

    /* --- function-pointer typedef: typedef int (*Callback)(int, void*) --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("typedef int (*Callback)(int n, void *ctx);"));
    PCType_T CB = Ctype_Lookup("Callback");
    CHECK_NOT_NULL(CB);
    CHECK_EQ_INT(CB->Kind,       CT_FUNCPTR);
    CHECK_EQ_INT((int)CB->Size,  8);
    CHECK_EQ_INT((int)CB->Align, 8);
    CHECK_NOT_NULL(CB->ElemType);
    CHECK_EQ_INT(CB->ElemType->Kind, CT_INT);  /* return type */
    CHECK_EQ_INT(CB->NumParams, 2);
    CHECK_EQ_INT(CB->ParamTypes[0]->Kind, CT_INT);   /* int */
    CHECK_EQ_INT(CB->ParamTypes[1]->Kind, CT_PTR);   /* void* */

    /* --- multiple params of same base type --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("int AddThree(int a, int b, int c);"));
    F = Ctype_Lookup("AddThree");
    CHECK_NOT_NULL(F);
    CHECK_EQ_INT(F->NumParams, 3);
    CHECK_EQ_INT(F->ElemType->Kind, CT_INT);

    Ctype_Shutdown();
    TEST_END();
}
