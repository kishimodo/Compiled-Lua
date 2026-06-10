/*!
 * test_ffi_thunk.c -- low-level thunk/trampoline generation.
 *
 * For each unique function signature (CT_FUNC ctype), Ffi_GetSignatureThunk
 * produces a callable:
 *     void Thunk(void *Fn, uint64_t *Args, uint64_t *Result)
 *
 * Coverage:
 *   - 8 int args (stack overflow beyond RCX/RDX/R8/R9)
 *   - 2 double args + double return (XMM0/XMM1, MOVQ RAX,XMM0)
 *   - mixed int+double (positional ABI: arg[0]=RCX, arg[1]=XMM1, arg[2]=R8)
 *   - 4 alternating int/double (positional XMM slot by position, not seq.)
 *   - thunk cache hit: same FuncT pointer returned on second call
 */
#include "test_harness.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"
#include "ffi/ffi_thunk.h"
#include "ffi/win_types.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Test target functions with various signatures. */
static int Sum8Ints(int a, int b, int c, int d, int e, int f, int g, int h) {
    return a + b + c + d + e + f + g + h;
}

static double AddDouble(double x, double y) {
    return x + y;
}

static double MixedIntFloat(int n, double d) {
    return (double)n + d;
}

static double FourMixed(int a, double b, int c, double d) {
    return (double)a + b + (double)c + d;
}

static int AddTwo(int a, int b) {
    return a + b;
}

static double MulDouble(double x, double y) {
    return x * y;
}

int main(void) {
    TEST_BEGIN("ffi_thunk");

    Ctype_Init();
    Ffi_RegisterWindowsTypes();
    Ffi_ResetThunkCache();

    /* --- 8 int args, int return (exercises stack spill: args 5-8) --- */
    CHECK_MSG(Cdecl_Parse("int Sum8(int, int, int, int, int, int, int, int);"),
              "parse Sum8 decl");
    PCType_T FuncSum8 = Ctype_Lookup("Sum8");
    CHECK_NOT_NULL(FuncSum8);
    CHECK_EQ_INT(FuncSum8->Kind, CT_FUNC);

    FFI_THUNK_T ThunkSum8 = Ffi_GetSignatureThunk(FuncSum8);
    CHECK_NOT_NULL(ThunkSum8);
    {
        uint64_t Args[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        uint64_t R = 0;
        ThunkSum8((void *)Sum8Ints, Args, &R);
        CHECK_EQ_INT((int)R, 36);
    }

    /* --- 2 double args, double return --- */
    CHECK_MSG(Cdecl_Parse("double AddD(double, double);"),
              "parse AddD decl");
    PCType_T FuncAddD = Ctype_Lookup("AddD");
    CHECK_NOT_NULL(FuncAddD);
    CHECK_EQ_INT(FuncAddD->Kind, CT_FUNC);

    FFI_THUNK_T ThunkAddD = Ffi_GetSignatureThunk(FuncAddD);
    CHECK_NOT_NULL(ThunkAddD);
    {
        double X = 1.5, Y = 2.25;
        uint64_t Args[2] = {0, 0};
        memcpy(&Args[0], &X, 8);
        memcpy(&Args[1], &Y, 8);
        uint64_t R = 0;
        ThunkAddD((void *)AddDouble, Args, &R);
        double Result;
        memcpy(&Result, &R, 8);
        CHECK_MSG(fabs(Result - 3.75) < 1e-9, "AddDouble(1.5, 2.25) = 3.75");
    }

    /* --- mixed: int then double --- */
    CHECK_MSG(Cdecl_Parse("double Mix(int, double);"),
              "parse Mix decl");
    PCType_T FuncMix = Ctype_Lookup("Mix");
    CHECK_NOT_NULL(FuncMix);

    FFI_THUNK_T ThunkMix = Ffi_GetSignatureThunk(FuncMix);
    CHECK_NOT_NULL(ThunkMix);
    {
        int N = 7;
        double D = 0.5;
        uint64_t Args[2] = {0, 0};
        Args[0] = (uint64_t)(int64_t)N;
        memcpy(&Args[1], &D, 8);
        uint64_t R = 0;
        ThunkMix((void *)MixedIntFloat, Args, &R);
        double Result;
        memcpy(&Result, &R, 8);
        CHECK_MSG(fabs(Result - 7.5) < 1e-9, "MixedIntFloat(7, 0.5) = 7.5");
    }

    /* --- 4 params: int, double, int, double (positional ABI quirk) ---
       arg[0] (int)    -> RCX
       arg[1] (double) -> XMM1  (position 1, not sequence 0)
       arg[2] (int)    -> R8
       arg[3] (double) -> XMM3  (position 3)                            */
    CHECK_MSG(Cdecl_Parse("double Four(int, double, int, double);"),
              "parse Four decl");
    PCType_T FuncFour = Ctype_Lookup("Four");
    CHECK_NOT_NULL(FuncFour);

    FFI_THUNK_T ThunkFour = Ffi_GetSignatureThunk(FuncFour);
    CHECK_NOT_NULL(ThunkFour);
    {
        int A = 1; double B = 2.0; int C = 3; double D = 4.0;
        uint64_t Args[4] = {0};
        Args[0] = (uint64_t)(int64_t)A;
        memcpy(&Args[1], &B, 8);
        Args[2] = (uint64_t)(int64_t)C;
        memcpy(&Args[3], &D, 8);
        uint64_t R = 0;
        ThunkFour((void *)FourMixed, Args, &R);
        double Result;
        memcpy(&Result, &R, 8);
        CHECK_MSG(fabs(Result - 10.0) < 1e-9, "FourMixed = 10.0");
    }

    /* --- thunk cache hit: same FuncT returns same pointer --- */
    FFI_THUNK_T ThunkSum8Again = Ffi_GetSignatureThunk(FuncSum8);
    CHECK(ThunkSum8Again == ThunkSum8);

    /* --- 2 int args, int return (minimal signature) --- */
    CHECK_MSG(Cdecl_Parse("int Add2(int, int);"),
              "parse Add2 decl");
    PCType_T FuncAdd2 = Ctype_Lookup("Add2");
    CHECK_NOT_NULL(FuncAdd2);

    FFI_THUNK_T ThunkAdd2 = Ffi_GetSignatureThunk(FuncAdd2);
    CHECK_NOT_NULL(ThunkAdd2);
    {
        uint64_t Args[2] = {17, 25};
        uint64_t R = 0;
        ThunkAdd2((void *)AddTwo, Args, &R);
        CHECK_EQ_INT((int)R, 42);
    }

    /* --- double multiply: two XMM args, double return --- */
    CHECK_MSG(Cdecl_Parse("double MulD(double, double);"),
              "parse MulD decl");
    PCType_T FuncMulD = Ctype_Lookup("MulD");
    CHECK_NOT_NULL(FuncMulD);

    FFI_THUNK_T ThunkMulD = Ffi_GetSignatureThunk(FuncMulD);
    CHECK_NOT_NULL(ThunkMulD);
    {
        double X = 3.0, Y = 2.5;
        uint64_t Args[2] = {0};
        memcpy(&Args[0], &X, 8);
        memcpy(&Args[1], &Y, 8);
        uint64_t R = 0;
        ThunkMulD((void *)MulDouble, Args, &R);
        double Result;
        memcpy(&Result, &R, 8);
        CHECK_MSG(fabs(Result - 7.5) < 1e-9, "MulDouble(3.0, 2.5) = 7.5");
    }

    /* --- distinct signatures -> distinct thunk pointers --- */
    CHECK(ThunkAddD != ThunkMulD);
    CHECK(ThunkSum8 != ThunkAdd2);

    Ctype_Shutdown();
    TEST_END();
}
