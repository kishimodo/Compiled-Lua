/* test_cdef_enum.c -- enum type registration and constant values.
 * Covers: implicit sequential values (0,1,2,...), explicit values with gap,
 * continuation after explicit value, hex literals, negative sentinel,
 * anonymous enum (constants-only, no tag), missing constant returns 0. */

#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"

int main(void) {
    TEST_BEGIN("cdef_enum");

    PCType_T T;
    int64_t  V;

    /* --- implicit 0-based sequential values --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("enum Color { RED, GREEN, BLUE };"));
    T = Ctype_Lookup("Color");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind,       CT_ENUM);
    CHECK_EQ_INT((int)T->Size,  4);
    CHECK_EQ_INT((int)T->Align, 4);
    V = -1; CHECK(Ctype_LookupEnumConst("RED",   &V)); CHECK_EQ_INT(V, 0);
    V = -1; CHECK(Ctype_LookupEnumConst("GREEN", &V)); CHECK_EQ_INT(V, 1);
    V = -1; CHECK(Ctype_LookupEnumConst("BLUE",  &V)); CHECK_EQ_INT(V, 2);

    /* --- explicit values + continuation (D = C+1 = 5) + hex (E = 0x10 = 16) --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("enum Flags { A = 1, B = 2, C = 4, D, E = 0x10 };"));
    V = -1; CHECK(Ctype_LookupEnumConst("A", &V)); CHECK_EQ_INT(V,  1);
    V = -1; CHECK(Ctype_LookupEnumConst("B", &V)); CHECK_EQ_INT(V,  2);
    V = -1; CHECK(Ctype_LookupEnumConst("C", &V)); CHECK_EQ_INT(V,  4);
    V = -1; CHECK(Ctype_LookupEnumConst("D", &V)); CHECK_EQ_INT(V,  5);
    V = -1; CHECK(Ctype_LookupEnumConst("E", &V)); CHECK_EQ_INT(V, 16);

    /* --- negative sentinel: INVALID = -1 --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("enum Status { STATUS_OK = 0, STATUS_ERR = 1, STATUS_INVALID = -1 };"));
    V = 99; CHECK(Ctype_LookupEnumConst("STATUS_OK",      &V)); CHECK_EQ_INT(V,  0);
    V = 99; CHECK(Ctype_LookupEnumConst("STATUS_ERR",     &V)); CHECK_EQ_INT(V,  1);
    V = 99; CHECK(Ctype_LookupEnumConst("STATUS_INVALID", &V)); CHECK_EQ_INT(V, -1);

    /* --- anonymous enum: constants registered without a tag name --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("enum { WAIT_OBJECT_0 = 0, WAIT_ABANDONED = 0x80 };"));
    V = -1; CHECK(Ctype_LookupEnumConst("WAIT_OBJECT_0",  &V)); CHECK_EQ_INT(V,   0);
    V = -1; CHECK(Ctype_LookupEnumConst("WAIT_ABANDONED", &V)); CHECK_EQ_INT(V, 128);

    /* --- missing constant returns 0 (lookup fails) --- */
    CHECK_EQ_INT(Ctype_LookupEnumConst("DOES_NOT_EXIST", &V), 0);

    /* --- typedef enum alias --- */
    Ctype_Shutdown(); Ctype_Init();
    CHECK(Cdecl_Parse("typedef enum { X = 10, Y = 20 } MyEnum;"));
    T = Ctype_Lookup("MyEnum");
    CHECK_NOT_NULL(T);
    CHECK_EQ_INT(T->Kind, CT_ENUM);
    V = -1; CHECK(Ctype_LookupEnumConst("X", &V)); CHECK_EQ_INT(V, 10);
    V = -1; CHECK(Ctype_LookupEnumConst("Y", &V)); CHECK_EQ_INT(V, 20);

    Ctype_Shutdown();
    TEST_END();
}
