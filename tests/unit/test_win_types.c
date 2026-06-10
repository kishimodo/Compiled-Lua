/* test_win_types.c -- Windows primitive typedef table: DWORD/HANDLE/BOOL/etc.
 * registered with correct sizes/kinds via Ffi_RegisterWindowsTypes. */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/win_types.h"

/* Helper: check a named type has the expected kind, size, and alignment. */
static int CheckType(const char *Name, CTYPE_KIND_T Kind, size_t Size, size_t Align) {
    PCType_T T = Ctype_Lookup(Name);
    if (T == NULL) return 0;
    if (T->Kind  != Kind)  return 0;
    if (T->Size  != Size)  return 0;
    if (T->Align != Align) return 0;
    return 1;
}

int main(void) {
    TEST_BEGIN("win_types");

    Ctype_Init();
    Ffi_RegisterWindowsTypes();

    /* --- unsigned integer types --- */
    CHECK_MSG(CheckType("BYTE",      CT_INT, 1, 1), "BYTE: CT_INT 1/1");
    CHECK_MSG(CheckType("WORD",      CT_INT, 2, 2), "WORD: CT_INT 2/2");
    CHECK_MSG(CheckType("DWORD",     CT_INT, 4, 4), "DWORD: CT_INT 4/4");
    CHECK_MSG(CheckType("QWORD",     CT_INT, 8, 8), "QWORD: CT_INT 8/8");
    CHECK_MSG(CheckType("ULONG",     CT_INT, 4, 4), "ULONG: CT_INT 4/4");
    CHECK_MSG(CheckType("ULONGLONG", CT_INT, 8, 8), "ULONGLONG: CT_INT 8/8");

    /* --- signed integer types --- */
    CHECK_MSG(CheckType("LONG",     CT_INT, 4, 4), "LONG: CT_INT 4/4");
    CHECK_MSG(CheckType("LONGLONG", CT_INT, 8, 8), "LONGLONG: CT_INT 8/8");

    /* --- boolean / character types --- */
    CHECK_MSG(CheckType("BOOL",    CT_INT, 4, 4), "BOOL: CT_INT 4/4");
    CHECK_MSG(CheckType("BOOLEAN", CT_INT, 1, 1), "BOOLEAN: CT_INT 1/1");
    CHECK_MSG(CheckType("WCHAR",   CT_INT, 2, 2), "WCHAR: CT_INT 2/2");

    /* --- status/error code integer --- */
    CHECK_MSG(CheckType("NTSTATUS", CT_INT, 4, 4), "NTSTATUS: CT_INT 4/4");

    /* --- pointer types: all 8/8 on x64 --- */
    CHECK_MSG(CheckType("HANDLE",  CT_PTR, 8, 8), "HANDLE: CT_PTR 8/8");
    CHECK_MSG(CheckType("HMODULE", CT_PTR, 8, 8), "HMODULE: CT_PTR 8/8");
    CHECK_MSG(CheckType("HWND",    CT_PTR, 8, 8), "HWND: CT_PTR 8/8");
    CHECK_MSG(CheckType("PVOID",   CT_PTR, 8, 8), "PVOID: CT_PTR 8/8");
    CHECK_MSG(CheckType("LPVOID",  CT_PTR, 8, 8), "LPVOID: CT_PTR 8/8");
    CHECK_MSG(CheckType("LPSTR",   CT_PTR, 8, 8), "LPSTR: CT_PTR 8/8");
    CHECK_MSG(CheckType("LPCSTR",  CT_PTR, 8, 8), "LPCSTR: CT_PTR 8/8");
    CHECK_MSG(CheckType("LPWSTR",  CT_PTR, 8, 8), "LPWSTR: CT_PTR 8/8");
    CHECK_MSG(CheckType("LPCWSTR", CT_PTR, 8, 8), "LPCWSTR: CT_PTR 8/8");
    CHECK_MSG(CheckType("PDWORD",  CT_PTR, 8, 8), "PDWORD: CT_PTR 8/8");
    CHECK_MSG(CheckType("LPDWORD", CT_PTR, 8, 8), "LPDWORD: CT_PTR 8/8");
    CHECK_MSG(CheckType("PULONG",  CT_PTR, 8, 8), "PULONG: CT_PTR 8/8");

    /* --- LARGE_INTEGER: union, 8/8 --- */
    {
        PCType_T LI = Ctype_Lookup("LARGE_INTEGER");
        CHECK_NOT_NULL(LI);
        CHECK_EQ_INT(LI->Kind,  CT_UNION);
        CHECK_EQ_INT(LI->Size,  8);
        CHECK_EQ_INT(LI->Align, 8);
    }

    Ctype_Shutdown();
    TEST_END();
}
