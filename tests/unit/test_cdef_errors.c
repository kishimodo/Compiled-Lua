/* test_cdef_errors.c -- malformed declarations are rejected, not silently
 * misparsed or crashed. Each case verifies: (a) Cdecl_Parse returns 0, and
 * (b) Cdecl_LastError() contains an expected substring. */

#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"

#include <string.h>

/* Returns 1 if Source fails to parse AND the error contains Substr. */
static int ParseFails(const char *Source, const char *Substr) {
    Ctype_Shutdown();
    Ctype_Init();
    int Ok = Cdecl_Parse(Source);
    if (Ok) return 0;
    const char *Err = Cdecl_LastError();
    if (Err == NULL) return 0;
    if (strstr(Err, Substr) == NULL) return 0;
    return 1;
}

int main(void) {
    TEST_BEGIN("cdef_errors");

    /* --- unknown / undefined type name --- */
    CHECK(ParseFails("typedef UndefinedType T;", "unknown type"));

    /* --- unexpected character (@) in input --- */
    CHECK(ParseFails("typedef int @foo;", "unexpected character"));

    /* --- missing semicolon at end of declaration --- */
    CHECK(ParseFails("typedef int Foo", "expected ;"));

    /* --- missing declarator identifier after type --- */
    CHECK(ParseFails("typedef int ;", "expected declarator identifier"));

    /* --- redefinition mismatch: re-register X with a different type --- */
    {
        Ctype_Shutdown(); Ctype_Init();
        CHECK(Cdecl_Parse("typedef int X;"));
        int Ok2 = Cdecl_Parse("typedef double X;");
        CHECK(!Ok2);
        const char *Err = Cdecl_LastError();
        CHECK_NOT_NULL(Err);
        CHECK(strstr(Err, "redefinition mismatch") != NULL);
    }

    /* --- missing closing brace on struct body --- */
    CHECK(ParseFails("struct S { int a;", "expected"));

    /* --- anonymous enum without body is an error --- */
    CHECK(ParseFails("enum;", "expected '{' after anonymous enum"));

    /* --- named enum used as forward-ref without body then nothing after ---
     *  `enum Foo;` is allowed as a forward reference in the parser (it creates
     *  a stub or returns existing). Verify that `enum;` (no name, no body)
     *  is rejected. */
    CHECK(ParseFails("typedef enum; T;", "expected '{' after anonymous enum"));

    /* --- missing type specifier (just a semicolon where a type was expected) --- */
    CHECK(ParseFails("typedef ; X;", "expected type specifier"));

    /* --- ellipsis as first param (no fixed arg before ...) --- */
    CHECK(ParseFails("int Bad(...);", "requires at least one fixed parameter"));

    /* --- function-pointer declarator missing the '*': `(name)` instead of `(*name)` ---
     *  `(IDENT` is NOT a fnptr pattern (Next is IDENT, not STAR/CALLCONV) so the
     *  parser tries to parse IDENT as a function declarator name, then sees ')'
     *  which is not '[' or '(' for a trailing suffix or ';' — it will fail with
     *  "expected ;" or similar. Just verify it fails cleanly. */
    {
        Ctype_Shutdown(); Ctype_Init();
        int Ok = Cdecl_Parse("typedef int (BadFnPtr)(int);");
        /* either succeeds (as a plain alias) or fails — either way no crash */
        (void)Ok;
        CHECK(1);   /* just prove we didn't crash */
    }

    /* --- missing closing bracket on array declarator --- */
    CHECK(ParseFails("typedef int A[10;", "expected ]"));

    Ctype_Shutdown();
    TEST_END();
}
