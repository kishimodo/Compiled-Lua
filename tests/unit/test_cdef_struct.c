/* test_cdef_struct.c -- struct layout: field offsets, total size, alignment.
 * Exercises Win64/MSVC ABI layout rules (natural alignment, no packing pragma).
 * Covers: simple mixed-type struct, pointer-field alignment, nested named
 * struct, array field, forward declaration + body completion. */

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
    TEST_BEGIN("cdef_struct");

    PCType_T T;

    /* --- simple struct: int(4) + char(1) + double(8) ---
     *  a @ 0, b @ 4, c @ 8 (aligned to 8), size=16, align=8 */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("struct S { int a; char b; double c; };"));
    T = Ctype_Lookup("S");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind, CT_STRUCT);
    {
        PField_T A = FindField(T, "a");
        PField_T B = FindField(T, "b");
        PField_T C = FindField(T, "c");
        CHECK_NOT_NULL(A); CHECK_EQ_INT((int)A->Offset, 0);
        CHECK_NOT_NULL(B); CHECK_EQ_INT((int)B->Offset, 4);
        CHECK_NOT_NULL(C); CHECK_EQ_INT((int)C->Offset, 8);
    }
    CHECK_EQ_INT((int)T->Size,  16);
    CHECK_EQ_INT((int)T->Align,  8);

    /* --- struct with pointer field: char(1) + ptr(8) ---
     *  c @ 0, p @ 8 (aligned), size=16, align=8 */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("struct P { char c; void *p; };"));
    T = Ctype_Lookup("P");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  16);
    CHECK_EQ_INT((int)T->Align,  8);

    /* --- nested named struct ---
     *  Inner: {int x; int y;} = size 8, align 4
     *  Outer: {Inner i; int z;} = 8+4=12, align 4 */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse(
        "struct Inner { int x; int y; };\n"
        "struct Outer { struct Inner i; int z; };"));
    {
        PCType_T Inner = Ctype_Lookup("Inner");
        CHECK_NOT_NULL(Inner);
        CHECK_EQ_INT((int)Inner->Size,  8);
        CHECK_EQ_INT((int)Inner->Align, 4);
        PCType_T Outer = Ctype_Lookup("Outer");
        CHECK_NOT_NULL(Outer);
        CHECK_EQ_INT((int)Outer->Size,  12);
        CHECK_EQ_INT((int)Outer->Align,  4);
        PField_T Z = FindField(Outer, "z");
        CHECK_NOT_NULL(Z);
        CHECK_EQ_INT((int)Z->Offset, 8);
    }

    /* --- struct with array field ---
     *  n @ 0 (size 4), buf @ 4 (char[256] align 1), total 260, align 4 */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("struct WithBuf { int n; char buf[256]; };"));
    T = Ctype_Lookup("WithBuf");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  260);
    CHECK_EQ_INT((int)T->Align,   4);
    {
        PField_T N   = FindField(T, "n");
        PField_T Buf = FindField(T, "buf");
        CHECK_NOT_NULL(N);   CHECK_EQ_INT((int)N->Offset,   0);
        CHECK_NOT_NULL(Buf); CHECK_EQ_INT((int)Buf->Offset, 4);
    }

    /* --- a Win32-style info struct (simplified SYSTEM_INFO shape) ---
     * Two DWORDs (4+4=8), two pointers (8+8=16), one ULONGLONG (8),
     * three DWORDs (4+4+4=12), two WORDs (2+2=4) → total 48, align 8 */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse(
        "struct Simple {"
        "  unsigned int dwOemId;"
        "  unsigned int dwPageSize;"
        "  void *lpMinAppAddr;"
        "  void *lpMaxAppAddr;"
        "  unsigned long long dwActiveProcessorMask;"
        "  unsigned int dwNumberOfProcessors;"
        "  unsigned int dwProcessorType;"
        "  unsigned int dwAllocGranularity;"
        "  unsigned short wProcessorLevel;"
        "  unsigned short wProcessorRevision;"
        "};"));
    T = Ctype_Lookup("Simple");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  48);
    CHECK_EQ_INT((int)T->Align,  8);
    {
        PField_T Mask = FindField(T, "dwActiveProcessorMask");
        CHECK_NOT_NULL(Mask);
        CHECK_EQ_INT((int)Mask->Offset, 24);
    }

    /* --- forward declaration + body completion ---
     *  Second parse of `struct Fwd { int x; int y; }` should fill in the stub. */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("struct Fwd; struct Fwd { int x; int y; };"));
    T = Ctype_Lookup("Fwd");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,       CT_STRUCT);
    CHECK_EQ_INT((int)T->Size,  8);
    CHECK_EQ_INT((int)T->Align, 4);
    CHECK_EQ_INT(T->NumFields,  2);

    /* --- all-int struct: three ints, packed naturally, size=12, align=4 --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("struct Triple { int a; int b; int c; };"));
    T = Ctype_Lookup("Triple");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  12);
    CHECK_EQ_INT((int)T->Align,  4);
    {
        PField_T A = FindField(T, "a");
        PField_T B = FindField(T, "b");
        PField_T C = FindField(T, "c");
        CHECK_NOT_NULL(A); CHECK_EQ_INT((int)A->Offset, 0);
        CHECK_NOT_NULL(B); CHECK_EQ_INT((int)B->Offset, 4);
        CHECK_NOT_NULL(C); CHECK_EQ_INT((int)C->Offset, 8);
    }

    Ctype_Shutdown();
    TEST_END();
}
