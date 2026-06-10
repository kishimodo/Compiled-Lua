/* test_cdef_storage_fnptr.c -- calling-convention modifiers and storage-class
 * keywords are silently consumed; function-pointer typedefs with __stdcall /
 * WINAPI / NTAPI in the declarator; extern variable declarations; COM-vtable-
 * style struct members with `HRESULT (__stdcall *Slot)(...)` fields.
 *
 * On Win64 all calling conventions collapse to the Microsoft x64 ABI, so the
 * parser records CT_FUNCPTR with the correct return type and param list and
 * ignores the modifier token (TOK_KW_CALLCONV maps to SkipCallConv). */

#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"

#include <string.h>

static PField_T FindField(PCType_T T, const char *Name) {
    PField_T F = T->Fields;
    while (F != NULL) {
        if (strcmp(F->Name, Name) == 0) return F;
        F = F->Next;
    }
    return NULL;
}

int main(void) {
    TEST_BEGIN("cdef_storage_fnptr");

    PCType_T T;

    /* --- __stdcall modifier before return type is consumed silently ---
     *  `__stdcall int Foo(int);` parses as `int Foo(int)` (CT_FUNC). */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("__stdcall int Foo(int x);"));
    T = Ctype_Lookup("Foo");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_FUNC);
    CHECK_EQ_INT(T->ElemType->Kind, CT_INT);
    CHECK_EQ_INT(T->NumParams,      1);

    /* --- __cdecl modifier between return type and name is consumed ---
     *  `int __cdecl Bar(void);` */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("int __cdecl Bar(void);"));
    T = Ctype_Lookup("Bar");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,      CT_FUNC);
    CHECK_EQ_INT(T->NumParams, 0);

    /* --- WINAPI / NTAPI / CALLBACK aliases also map to TOK_KW_CALLCONV ---
     *  `void WINAPI WinFunc(unsigned int);` */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("void WINAPI WinFunc(unsigned int code);"));
    T = Ctype_Lookup("WinFunc");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_FUNC);
    CHECK_EQ_INT(T->ElemType->Kind, CT_VOID);
    CHECK_EQ_INT(T->NumParams,      1);

    /* --- function-pointer typedef with __stdcall in declarator ---
     *  `typedef void (__stdcall *StdFnPtr)(int, int);` */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("typedef void (__stdcall *StdFnPtr)(int a, int b);"));
    T = Ctype_Lookup("StdFnPtr");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_FUNCPTR);
    CHECK_EQ_INT((int)T->Size,      8);
    CHECK_EQ_INT((int)T->Align,     8);
    CHECK_EQ_INT(T->ElemType->Kind, CT_VOID);
    CHECK_EQ_INT(T->NumParams,      2);

    /* --- function-pointer typedef with NTAPI ---
     *  `typedef int (NTAPI *NtFn)(void *handle, int flags);` */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("typedef int (NTAPI *NtFn)(void *handle, int flags);"));
    T = Ctype_Lookup("NtFn");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_FUNCPTR);
    CHECK_EQ_INT(T->ElemType->Kind, CT_INT);
    CHECK_EQ_INT(T->NumParams,      2);

    /* --- extern variable declaration registers in extern namespace ---
     *  `extern int g_Counter;` */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("extern int g_Counter;"));
    /* extern decls go to the extern namespace, not the type namespace */
    T = Ctype_LookupExtern("g_Counter");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind, CT_INT);

    /* --- static function decl: `static` is TOK_KW_STORAGE, consumed silently ---
     *  `static int Helper(int n);` parses as a normal function. */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("static int Helper(int n);"));
    T = Ctype_Lookup("Helper");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,      CT_FUNC);
    CHECK_EQ_INT(T->NumParams, 1);

    /* --- inline function decl: `inline` is TOK_KW_STORAGE --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("inline double Sqrt(double x);"));
    T = Ctype_Lookup("Sqrt");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_FUNC);
    CHECK_EQ_INT(T->ElemType->Kind, CT_FLOAT);
    CHECK_EQ_INT(T->NumParams,      1);

    /* --- COM-vtable-style struct: HRESULT (__stdcall *QueryInterface)(...) ---
     *  The struct's field is a CT_FUNCPTR. */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse(
        "typedef int HRESULT;\n"
        "struct IUnknownVtbl {\n"
        "    HRESULT (__stdcall *QueryInterface)(void *This, void *riid, void **ppv);\n"
        "    unsigned long (__stdcall *AddRef)(void *This);\n"
        "    unsigned long (__stdcall *Release)(void *This);\n"
        "};"));
    T = Ctype_Lookup("IUnknownVtbl");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind, CT_STRUCT);
    {
        PField_T QI  = FindField(T, "QueryInterface");
        PField_T AR  = FindField(T, "AddRef");
        PField_T Rel = FindField(T, "Release");
        CHECK_NOT_NULL(QI);
        CHECK_NOT_NULL(AR);
        CHECK_NOT_NULL(Rel);
        CHECK_EQ_INT(QI->Type->Kind,  CT_FUNCPTR);
        CHECK_EQ_INT(AR->Type->Kind,  CT_FUNCPTR);
        CHECK_EQ_INT(Rel->Type->Kind, CT_FUNCPTR);
        /* QueryInterface returns HRESULT (int) and takes 3 params */
        CHECK_EQ_INT(QI->Type->ElemType->Kind, CT_INT);
        CHECK_EQ_INT(QI->Type->NumParams,      3);
        /* struct of 3 pointers = 24 bytes, align 8 */
        CHECK_EQ_INT((int)T->Size,  24);
        CHECK_EQ_INT((int)T->Align,  8);
    }

    /* --- __fastcall on a no-args function --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("int __fastcall FastFunc(void);"));
    T = Ctype_Lookup("FastFunc");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,      CT_FUNC);
    CHECK_EQ_INT(T->NumParams, 0);

    Ctype_Shutdown();
    TEST_END();
}
