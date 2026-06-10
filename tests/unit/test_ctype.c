/* test_ctype.c -- the FFI ctype table: primitive sizes/signedness, registration
 * and lookup, the interned pointer-to-T cache (Ctype_PointerTo), and enum/extern
 * namespaces. Exercises src/ffi/ctype.c. */
#include "test_harness.h"
#include "ffi/ctype.h"

int main(void) {
    TEST_BEGIN("ctype");
    Ctype_Init();

    /* Primitive types exist with the expected size/signedness. */
    PCType_T i = Ctype_Lookup("int");
    CHECK_NOT_NULL(i);
    CHECK_EQ_INT(i->Kind, CT_INT);
    CHECK_EQ_INT(i->Size, 4);
    CHECK_EQ_INT(i->IsSigned, 1);

    PCType_T u = Ctype_Lookup("unsigned int");
    CHECK_NOT_NULL(u);
    CHECK_EQ_INT(u->IsSigned, 0);

    PCType_T c = Ctype_Lookup("char");
    CHECK_NOT_NULL(c);
    CHECK_EQ_INT(c->Size, 1);

    PCType_T d = Ctype_Lookup("double");
    CHECK_NOT_NULL(d);
    CHECK_EQ_INT(d->Kind, CT_FLOAT);
    CHECK_EQ_INT(d->Size, 8);

    /* Unknown name -> NULL. */
    CHECK_NULL(Ctype_Lookup("no_such_type_xyz"));

    /* Register a new named type and look it back up. */
    PCType_T nt = Ctype_New();
    CHECK_NOT_NULL(nt);
    nt->Kind = CT_INT; nt->Size = 4; nt->Align = 4; nt->IsSigned = 1;
    CHECK_EQ_INT(Ctype_Register("MyInt", nt), 1);
    CHECK(Ctype_Lookup("MyInt") == nt);

    /* Ctype_PointerTo interns one pointer type per element (cached on PtrTo). */
    PCType_T p1 = Ctype_PointerTo(i);
    CHECK_NOT_NULL(p1);
    CHECK_EQ_INT(p1->Kind, CT_PTR);
    CHECK_EQ_INT(p1->Size, 8);
    CHECK(p1->ElemType == i);
    PCType_T p2 = Ctype_PointerTo(i);
    CHECK(p1 == p2);            /* interned: same pointer back */

    /* Enum constant namespace. */
    Ctype_RegisterEnumConst("MY_ENUM_VAL", 42);
    int64_t ev = 0;
    CHECK_EQ_INT(Ctype_LookupEnumConst("MY_ENUM_VAL", &ev), 1);
    CHECK_EQ_INT(ev, 42);
    CHECK_EQ_INT(Ctype_LookupEnumConst("MISSING", &ev), 0);

    TEST_END();
}
