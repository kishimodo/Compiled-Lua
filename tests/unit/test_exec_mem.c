/* test_exec_mem.c -- executable-memory allocator: alloc, write,
 * make-executable, run a tiny stub. Also verifies W^X semantics:
 * append after commit is rejected, release nulls the pointer.
 */
#include "test_harness.h"
#include "jit/exec_mem.h"

#include <string.h>

typedef int ( *FN_T )( void );

int main( void ) {
    TEST_BEGIN("exec_mem");

    EXEC_MEM_SLOT_T Slot = { 0 };

    /* Reserve */
    CHECK( ExecMem_Reserve( 64, &Slot ) );
    CHECK_NOT_NULL( Slot.Code );
    CHECK_MSG( Slot.Size >= 64, "size >= requested" );
    CHECK_EQ_INT( Slot.Used, 0 );
    CHECK_EQ_INT( Slot.Committed, 0 );

    /* Append: mov eax,42; ret  (B8 2A 00 00 00 C3) */
    const unsigned char Code[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    CHECK( ExecMem_Append( &Slot, Code, sizeof( Code ) ) );
    CHECK_EQ_INT( (int)Slot.Used, (int)sizeof( Code ) );

    /* Commit */
    CHECK( ExecMem_Commit( &Slot ) );
    CHECK_EQ_INT( Slot.Committed, 1 );

    /* Execute */
    FN_T Fn = (FN_T)(void *)Slot.Code;
    CHECK_EQ_INT( Fn(), 42 );

    /* Append after commit must be rejected */
    CHECK_MSG( !ExecMem_Append( &Slot, Code, 1 ),
               "append after commit rejected" );

    /* Release */
    ExecMem_Release( &Slot );
    CHECK_NULL( Slot.Code );

    /* ---------------------------------------------------------------
     * Second slot: test that a fresh reserve after release works and
     * can hold distinct code (returns 99).
     * -------------------------------------------------------------- */
    EXEC_MEM_SLOT_T Slot2 = { 0 };
    CHECK( ExecMem_Reserve( 32, &Slot2 ) );
    const unsigned char Code2[] = { 0xB8, 0x63, 0x00, 0x00, 0x00, 0xC3 };
    CHECK( ExecMem_Append( &Slot2, Code2, sizeof( Code2 ) ) );
    CHECK( ExecMem_Commit( &Slot2 ) );
    FN_T Fn2 = (FN_T)(void *)Slot2.Code;
    CHECK_EQ_INT( Fn2(), 99 );
    ExecMem_Release( &Slot2 );
    CHECK_NULL( Slot2.Code );

    /* ---------------------------------------------------------------
     * Two independent slots can coexist (both committed, both callable).
     * -------------------------------------------------------------- */
    EXEC_MEM_SLOT_T SA = { 0 }, SB = { 0 };
    CHECK( ExecMem_Reserve( 32, &SA ) );
    CHECK( ExecMem_Reserve( 32, &SB ) );
    /* SA -> return 11;  SB -> return 22 */
    const unsigned char CodeA[] = { 0xB8, 0x0B, 0x00, 0x00, 0x00, 0xC3 };
    const unsigned char CodeB[] = { 0xB8, 0x16, 0x00, 0x00, 0x00, 0xC3 };
    CHECK( ExecMem_Append( &SA, CodeA, sizeof( CodeA ) ) );
    CHECK( ExecMem_Append( &SB, CodeB, sizeof( CodeB ) ) );
    CHECK( ExecMem_Commit( &SA ) );
    CHECK( ExecMem_Commit( &SB ) );
    CHECK_EQ_INT( ( (FN_T)(void *)SA.Code )(), 11 );
    CHECK_EQ_INT( ( (FN_T)(void *)SB.Code )(), 22 );
    ExecMem_Release( &SA );
    ExecMem_Release( &SB );

    TEST_END();
}
