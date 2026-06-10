/* test_cdef_primitives.c -- parse primitive types via Cdecl_Parse and verify
 * the resulting ctype kind, size, and signedness. Covers: plain int/char/float/
 * double/void, signed/unsigned modifiers, short/long/long-long combinations,
 * typedef aliases, multiple decls in one source, and const/volatile stripping. */

#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"

/* Parse Source, look up Alias; check Kind and Size. Returns 1 on match. */
static int CheckAlias(const char *Source, const char *Alias,
                      CTYPE_KIND_T ExpKind, size_t ExpSize) {
    Ctype_Shutdown();
    Ctype_Init();
    if (!Cdecl_Parse(Source)) return 0;
    PCType_T T = Ctype_Lookup(Alias);
    if (T == NULL) return 0;
    if (T->Kind != ExpKind) return 0;
    if (T->Size != ExpSize) return 0;
    return 1;
}

int main(void) {
    TEST_BEGIN("cdef_primitives");

    /* --- basic integral typedefs --- */
    CHECK(CheckAlias("typedef int MyInt;",             "MyInt", CT_INT,   4));
    CHECK(CheckAlias("typedef unsigned int U32;",      "U32",   CT_INT,   4));
    CHECK(CheckAlias("typedef short S16;",             "S16",   CT_INT,   2));
    CHECK(CheckAlias("typedef unsigned short U16;",    "U16",   CT_INT,   2));
    CHECK(CheckAlias("typedef char C8;",               "C8",    CT_INT,   1));
    CHECK(CheckAlias("typedef long L;",                "L",     CT_INT,   4));
    CHECK(CheckAlias("typedef unsigned long UL;",      "UL",    CT_INT,   4));
    CHECK(CheckAlias("typedef long long LL;",          "LL",    CT_INT,   8));
    CHECK(CheckAlias("typedef unsigned long long ULL;","ULL",   CT_INT,   8));

    /* --- floating-point --- */
    CHECK(CheckAlias("typedef float F32;",  "F32", CT_FLOAT, 4));
    CHECK(CheckAlias("typedef double F64;", "F64", CT_FLOAT, 8));

    /* --- void --- */
    CHECK(CheckAlias("typedef void V;", "V", CT_VOID, 0));

    /* --- signedness --- */
    {
        Ctype_Shutdown(); Ctype_Init();
        CHECK(Cdecl_Parse("typedef int SI; typedef unsigned int UI;"));
        PCType_T S = Ctype_Lookup("SI");
        PCType_T U = Ctype_Lookup("UI");
        CHECK_NOT_NULL(S);
        CHECK_NOT_NULL(U);
        CHECK_EQ_INT(S->IsSigned, 1);
        CHECK_EQ_INT(U->IsSigned, 0);
    }

    /* --- signed char vs plain char vs unsigned char --- */
    {
        Ctype_Shutdown(); Ctype_Init();
        CHECK(Cdecl_Parse("typedef signed char SC; typedef unsigned char UC;"));
        PCType_T SC = Ctype_Lookup("SC");
        PCType_T UC = Ctype_Lookup("UC");
        CHECK_NOT_NULL(SC); CHECK_NOT_NULL(UC);
        CHECK_EQ_INT(SC->Size, 1);
        CHECK_EQ_INT(UC->Size, 1);
        CHECK_EQ_INT(SC->IsSigned, 1);
        CHECK_EQ_INT(UC->IsSigned, 0);
    }

    /* --- `unsigned` alone means unsigned int (C90 default-int) --- */
    {
        Ctype_Shutdown(); Ctype_Init();
        CHECK(Cdecl_Parse("typedef unsigned U;"));
        PCType_T T = Ctype_Lookup("U");
        CHECK_NOT_NULL(T);
        CHECK_EQ_INT(T->Kind,     CT_INT);
        CHECK_EQ_INT(T->Size,     4);
        CHECK_EQ_INT(T->IsSigned, 0);
    }

    /* --- short int / long int redundancy --- */
    CHECK(CheckAlias("typedef short int SI2;",         "SI2", CT_INT, 2));
    CHECK(CheckAlias("typedef long int LI;",           "LI",  CT_INT, 4));
    CHECK(CheckAlias("typedef unsigned long int ULI;", "ULI", CT_INT, 4));

    /* --- const / volatile are silently stripped --- */
    CHECK(CheckAlias("typedef const int CI;",    "CI", CT_INT, 4));
    CHECK(CheckAlias("typedef volatile int VI;", "VI", CT_INT, 4));

    /* --- multiple declarations in one source string --- */
    {
        Ctype_Shutdown(); Ctype_Init();
        CHECK(Cdecl_Parse("typedef int A; typedef short B; typedef char C;"));
        CHECK_NOT_NULL(Ctype_Lookup("A"));
        CHECK_NOT_NULL(Ctype_Lookup("B"));
        CHECK_NOT_NULL(Ctype_Lookup("C"));
        CHECK_EQ_INT(Ctype_Lookup("A")->Size, 4);
        CHECK_EQ_INT(Ctype_Lookup("B")->Size, 2);
        CHECK_EQ_INT(Ctype_Lookup("C")->Size, 1);
    }

    /* --- inline _Bool --- */
    CHECK(CheckAlias("typedef _Bool MYBOOL;", "MYBOOL", CT_BOOL, 1));

    Ctype_Shutdown();
    TEST_END();
}
