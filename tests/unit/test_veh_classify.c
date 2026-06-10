/* test_veh_classify.c -- VEH exception-code -> fault classification logic.
 * Exercises Veh_ClassifyFault with synthetic EXCEPTION_POINTERS. */
#include "test_harness.h"
#include "ffi/veh.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* Exposed for testing only (defined in ffi/veh.c). */
int Veh_ClassifyFault( PEXCEPTION_POINTERS Pointers );

int main( void ) {
    TEST_BEGIN( "veh_classify" );

    /* Reset region table. */
    Veh_Shutdown();

    /* Register a synthetic code region at [0x10000, 0x11000). */
    void *Region = (void *)(uintptr_t)0x10000;
    CHECK_EQ_INT( Veh_RegisterRegion( Region, 0x1000 ), 1 );

    EXCEPTION_RECORD ER  = { 0 };
    CONTEXT          Ctx = { 0 };
    EXCEPTION_POINTERS EP = { &ER, &Ctx };

    /* AV inside region -> catch (return 1). */
    ER.ExceptionCode    = EXCEPTION_ACCESS_VIOLATION;
    ER.ExceptionAddress = (void *)(uintptr_t)0x10500;
    ER.NumberParameters = 2;
    ER.ExceptionInformation[0] = 0;
    ER.ExceptionInformation[1] = 0xCAFEBABE;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* AV outside any region -> passthrough (return 0). */
    ER.ExceptionAddress = (void *)(uintptr_t)0xFFFF0000;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* DIV0 inside region -> catch. */
    ER.ExceptionAddress = (void *)(uintptr_t)0x10100;
    ER.ExceptionCode    = EXCEPTION_INT_DIVIDE_BY_ZERO;
    ER.NumberParameters = 0;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* Illegal instruction inside region -> catch. */
    ER.ExceptionCode = EXCEPTION_ILLEGAL_INSTRUCTION;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* Integer overflow inside region -> catch. */
    ER.ExceptionCode = EXCEPTION_INT_OVERFLOW;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* Stack overflow -> catch always (even outside any region). */
    ER.ExceptionAddress = (void *)(uintptr_t)0xFFFF0000;
    ER.ExceptionCode    = EXCEPTION_STACK_OVERFLOW;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* C++ exception (0xE06D7363) inside region -> passthrough always. */
    ER.ExceptionAddress = (void *)(uintptr_t)0x10500;
    ER.ExceptionCode    = 0xE06D7363u;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* Ctrl-C (DBG_CONTROL_C) -> passthrough. */
    ER.ExceptionCode = 0x40010005u;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* Debug breakpoint -> passthrough. */
    ER.ExceptionCode = EXCEPTION_BREAKPOINT;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* NULL EXCEPTION_POINTERS -> returns 0 (no crash). */
    CHECK_EQ_INT( Veh_ClassifyFault( NULL ), 0 );

    Veh_Shutdown();
    TEST_END();
}
