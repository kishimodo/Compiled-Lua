/* test_veh_attribution.c -- VEH fault attribution: faults from inside a
 * registered code region are caught and attributed to that region; faults
 * outside are not. Uses synthetic inputs — no real crashes needed. */
#include "test_harness.h"
#include "ffi/veh.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdint.h>
#include <string.h>

/* Exposed for testing (defined in ffi/veh.c). */
int Veh_ClassifyFault( PEXCEPTION_POINTERS Pointers );

int main( void ) {
    TEST_BEGIN( "veh_attribution" );

    Veh_Shutdown();

    /* Register two non-adjacent code regions. */
    void *RegA = (void *)(uintptr_t)0x40000000;
    void *RegB = (void *)(uintptr_t)0x50000000;
    CHECK_EQ_INT( Veh_RegisterRegion( RegA, 0x2000 ), 1 );
    CHECK_EQ_INT( Veh_RegisterRegion( RegB, 0x1000 ), 1 );

    EXCEPTION_RECORD   ER  = { 0 };
    CONTEXT            Ctx = { 0 };
    EXCEPTION_POINTERS EP  = { &ER, &Ctx };
    ER.NumberParameters = 0;

    /* AV at start of RegA -> caught (attributed to RegA). */
    ER.ExceptionCode    = EXCEPTION_ACCESS_VIOLATION;
    ER.ExceptionAddress = RegA;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* AV at end of RegA (last byte 0x40001FFF) -> caught. */
    ER.ExceptionAddress = (void *)( (uintptr_t)RegA + 0x1FFF );
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* AV one byte past RegA end -> not caught. */
    ER.ExceptionAddress = (void *)( (uintptr_t)RegA + 0x2000 );
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* AV in gap between RegA and RegB -> not caught. */
    ER.ExceptionAddress = (void *)(uintptr_t)0x48000000;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* DIV0 inside RegB -> caught. */
    ER.ExceptionCode    = EXCEPTION_INT_DIVIDE_BY_ZERO;
    ER.ExceptionAddress = (void *)( (uintptr_t)RegB + 0x500 );
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* DIV0 past RegB end -> not caught. */
    ER.ExceptionAddress = (void *)( (uintptr_t)RegB + 0x1000 );
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* STACK_OVERFLOW always caught regardless of address. */
    ER.ExceptionCode    = EXCEPTION_STACK_OVERFLOW;
    ER.ExceptionAddress = (void *)(uintptr_t)0x1;   /* outside any region */
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* After unregistering RegA, fault there is no longer caught. */
    CHECK_EQ_INT( Veh_UnregisterRegion( RegA ), 1 );
    ER.ExceptionCode    = EXCEPTION_ACCESS_VIOLATION;
    ER.ExceptionAddress = RegA;
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 0 );

    /* RegB still active. */
    ER.ExceptionAddress = (void *)( (uintptr_t)RegB + 0x100 );
    CHECK_EQ_INT( Veh_ClassifyFault( &EP ), 1 );

    /* Veh_IsCodeRegion mirrors classification for non-special codes. */
    CHECK_EQ_INT( Veh_IsCodeRegion( (void *)( (uintptr_t)RegB + 0x100 ) ), 1 );
    CHECK_EQ_INT( Veh_IsCodeRegion( RegA ), 0 );

    Veh_Shutdown();
    TEST_END();
}
