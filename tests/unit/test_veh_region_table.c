/* test_veh_region_table.c -- VEH registered memory-region table lookup.
 * Exercises Veh_RegisterRegion, Veh_UnregisterRegion, Veh_IsCodeRegion. */
#include "test_harness.h"
#include "ffi/veh.h"

#include <stdint.h>

int main( void ) {
    TEST_BEGIN( "veh_region_table" );

    void *A = (void *)(uintptr_t)0x10000;
    void *B = (void *)(uintptr_t)0x20000;
    void *C = (void *)(uintptr_t)0x30000;

    /* Start with a clean table. */
    Veh_Shutdown();

    /* Empty table: nothing matches. */
    CHECK_EQ_INT( Veh_IsCodeRegion( A ), 0 );
    CHECK_EQ_INT( Veh_IsCodeRegion( (void *)(uintptr_t)0xAAAA ), 0 );

    /* Register one region [0x10000, 0x11000). */
    CHECK_EQ_INT( Veh_RegisterRegion( A, 0x1000 ), 1 );

    /* Exact start is inside. */
    CHECK_EQ_INT( Veh_IsCodeRegion( A ), 1 );
    /* Interior byte. */
    CHECK_EQ_INT( Veh_IsCodeRegion( (void *)(uintptr_t)0x10500 ), 1 );
    /* Last byte (0x10FFF). */
    CHECK_EQ_INT( Veh_IsCodeRegion( (void *)(uintptr_t)0x10FFF ), 1 );
    /* One byte past end (exclusive). */
    CHECK_EQ_INT( Veh_IsCodeRegion( (void *)(uintptr_t)0x11000 ), 0 );
    /* One byte before start. */
    CHECK_EQ_INT( Veh_IsCodeRegion( (void *)(uintptr_t)0x0FFFF ), 0 );

    /* Register two more regions out of order — table must sort them. */
    CHECK_EQ_INT( Veh_RegisterRegion( C, 0x1000 ), 1 );
    CHECK_EQ_INT( Veh_RegisterRegion( B, 0x1000 ), 1 );

    CHECK_EQ_INT( Veh_IsCodeRegion( A ), 1 );
    CHECK_EQ_INT( Veh_IsCodeRegion( B ), 1 );
    CHECK_EQ_INT( Veh_IsCodeRegion( C ), 1 );
    /* Gap between A and B. */
    CHECK_EQ_INT( Veh_IsCodeRegion( (void *)(uintptr_t)0x18000 ), 0 );

    /* Unregister B. */
    CHECK_EQ_INT( Veh_UnregisterRegion( B ), 1 );
    CHECK_EQ_INT( Veh_IsCodeRegion( A ), 1 );
    CHECK_EQ_INT( Veh_IsCodeRegion( B ), 0 );
    CHECK_EQ_INT( Veh_IsCodeRegion( C ), 1 );

    /* Unregistering a non-existent region returns 0. */
    CHECK_EQ_INT( Veh_UnregisterRegion( (void *)(uintptr_t)0xBEEF ), 0 );

    /* Duplicate registration of A (still registered) returns 0. */
    CHECK_EQ_INT( Veh_RegisterRegion( A, 0x1000 ), 0 );

    /* NULL / zero-size inputs fail gracefully. */
    CHECK_EQ_INT( Veh_RegisterRegion( NULL, 0x1000 ), 0 );
    CHECK_EQ_INT( Veh_RegisterRegion( (void *)(uintptr_t)0x99000, 0 ), 0 );

    Veh_Shutdown();
    TEST_END();
}
