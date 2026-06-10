/* test_cdef_pointers_arrays.c -- pointer and array declarators via Cdecl_Parse.
 * Covers: T*, T**, void*, const T*, T[N], T[] (flex/empty), T[?] VLA,
 * and chaining (pointer to array length). */

#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"

/* Fresh Ctype table, parse Source, return Ctype_Lookup(Name). NULL on error. */
static PCType_T ParseAndLookup(const char *Source, const char *Name) {
    Ctype_Shutdown();
    Ctype_Init();
    if (!Cdecl_Parse(Source)) return NULL;
    return Ctype_Lookup(Name);
}

int main(void) {
    TEST_BEGIN("cdef_pointers_arrays");

    PCType_T T;

    /* --- T* --- */
    T = ParseAndLookup("typedef int *PI;", "PI");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,  CT_PTR);
    CHECK_EQ_INT(T->Size,  8);
    CHECK_EQ_INT(T->Align, 8);
    CHECK_NOT_NULL(T->ElemType);
    CHECK_EQ_INT(T->ElemType->Kind, CT_INT);

    /* --- T** --- */
    T = ParseAndLookup("typedef int **PPI;", "PPI");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,              CT_PTR);
    CHECK_EQ_INT(T->ElemType->Kind,    CT_PTR);
    CHECK_EQ_INT(T->ElemType->ElemType->Kind, CT_INT);

    /* --- void* --- */
    T = ParseAndLookup("typedef void *VP;", "VP");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_PTR);
    CHECK_EQ_INT(T->ElemType->Kind, CT_VOID);

    /* --- T[N] --- */
    T = ParseAndLookup("typedef int A10[10];", "A10");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_ARRAY);
    CHECK_EQ_INT(T->ArrayLen,       10);
    CHECK_EQ_INT(T->ElemType->Kind, CT_INT);
    CHECK_EQ_INT((int)T->Size,      40);   /* 10 * 4 */
    CHECK_EQ_INT((int)T->Align,     4);

    /* --- T[] flex / empty array (ArrayLen == -1, Size == 0) --- */
    T = ParseAndLookup("typedef int Flex[];", "Flex");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,     CT_ARRAY);
    CHECK_EQ_INT(T->ArrayLen, -1);
    CHECK_EQ_INT((int)T->Size, 0);

    /* --- T[?] VLA marker (IsFlex == 1, ArrayLen == -1) --- */
    T = ParseAndLookup("typedef int VLA[?];", "VLA");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,   CT_ARRAY);
    CHECK_EQ_INT(T->IsFlex, 1);
    CHECK_EQ_INT(T->ArrayLen, -1);
    CHECK_EQ_INT((int)T->Size, 0);

    /* --- char[256] -- common Win32 path buffer --- */
    T = ParseAndLookup("typedef char Path[256];", "Path");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  256);
    CHECK_EQ_INT((int)T->Align, 1);

    /* --- double[4] --- */
    T = ParseAndLookup("typedef double D4[4];", "D4");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  32);
    CHECK_EQ_INT((int)T->Align, 8);

    /* --- const qualifier on pointee is silently stripped (pointer still CT_PTR) --- */
    T = ParseAndLookup("typedef const int *PCI;", "PCI");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,           CT_PTR);
    CHECK_EQ_INT(T->ElemType->Kind, CT_INT);

    /* --- pointer to pointer to char --- */
    T = ParseAndLookup("typedef char **PPCH;", "PPCH");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,                        CT_PTR);
    CHECK_EQ_INT(T->ElemType->Kind,              CT_PTR);
    CHECK_EQ_INT(T->ElemType->ElemType->Kind,    CT_INT); /* char is CT_INT */
    CHECK_EQ_INT(T->ElemType->ElemType->Size,    1);

    Ctype_Shutdown();
    TEST_END();
}
