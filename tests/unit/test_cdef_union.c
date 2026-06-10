/* test_cdef_union.c -- union layout: overlapping offsets, size = max field size,
 * alignment = max field alignment. Covers: simple union, anonymous nested union
 * inside struct (LARGE_INTEGER pattern), anonymous nested struct inside struct. */

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
    TEST_BEGIN("cdef_union");

    PCType_T T;

    /* --- simple union: int(4) + double(8) + char(1) ---
     *  all offsets == 0; size = 8 (double), align = 8 (double) */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("union U { int i; double d; char c; };"));
    T = Ctype_Lookup("U");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,       CT_UNION);
    CHECK_EQ_INT((int)T->Size,  8);
    CHECK_EQ_INT((int)T->Align, 8);
    {
        PField_T I = FindField(T, "i");
        PField_T D = FindField(T, "d");
        PField_T C = FindField(T, "c");
        CHECK_NOT_NULL(I); CHECK_EQ_INT((int)I->Offset, 0);
        CHECK_NOT_NULL(D); CHECK_EQ_INT((int)D->Offset, 0);
        CHECK_NOT_NULL(C); CHECK_EQ_INT((int)C->Offset, 0);
    }

    /* --- all-int union: three ints all at offset 0, size=4 --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("union IntUnion { int a; int b; int c; };"));
    T = Ctype_Lookup("IntUnion");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  4);
    CHECK_EQ_INT((int)T->Align, 4);
    {
        PField_T A = FindField(T, "a");
        PField_T B = FindField(T, "b");
        CHECK_NOT_NULL(A); CHECK_EQ_INT((int)A->Offset, 0);
        CHECK_NOT_NULL(B); CHECK_EQ_INT((int)B->Offset, 0);
    }

    /* --- LARGE_INTEGER pattern: struct containing anonymous union that contains
     *  an anonymous struct {LowPart, HighPart} and a QuadPart long long.
     *  All three names (LowPart, HighPart, QuadPart) promote to LI.
     *  Total: union = 8 bytes (max of {int,int}=8 and long long=8), align=8. */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse(
        "struct LI { union { struct { unsigned int LowPart; int HighPart; }; long long QuadPart; }; };"));
    T = Ctype_Lookup("LI");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  8);
    CHECK_EQ_INT((int)T->Align, 8);
    {
        PField_T LP = FindField(T, "LowPart");
        PField_T HP = FindField(T, "HighPart");
        PField_T QP = FindField(T, "QuadPart");
        CHECK_NOT_NULL(LP); CHECK_EQ_INT((int)LP->Offset, 0);
        CHECK_NOT_NULL(HP); CHECK_EQ_INT((int)HP->Offset, 4);
        CHECK_NOT_NULL(QP); CHECK_EQ_INT((int)QP->Offset, 0);
    }

    /* --- anonymous struct inside named struct: fields promote to outer ---
     *  Pt: z @ 0 (int=4), then anon struct {x,y} @ 4 (size 8, align 4)
     *  x @ 4, y @ 8, total size=12, align=4 */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse(
        "struct Pt { int z; struct { int x; int y; }; };"));
    T = Ctype_Lookup("Pt");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT((int)T->Size,  12);
    CHECK_EQ_INT((int)T->Align,  4);
    {
        PField_T Z = FindField(T, "z");
        PField_T X = FindField(T, "x");
        PField_T Y = FindField(T, "y");
        CHECK_NOT_NULL(Z); CHECK_EQ_INT((int)Z->Offset, 0);
        CHECK_NOT_NULL(X); CHECK_EQ_INT((int)X->Offset, 4);
        CHECK_NOT_NULL(Y); CHECK_EQ_INT((int)Y->Offset, 8);
    }

    Ctype_Shutdown();
    TEST_END();
}
