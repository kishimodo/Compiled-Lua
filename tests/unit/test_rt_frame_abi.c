/*
** test_rt_frame_abi.c -- the packed operand word codegen and the runtime share.
**
** common/rt_frame_abi.h is the only thing keeping two translation units that
** never see each other's code in agreement: codegen.c packs A/B/C/K into one
** int32 and emits `mov r8d, imm32`, and jit/runtime.c's Rt_*F helpers unpack
** it. A disagreement is not a build error -- it is a compiled program reading
** the wrong register or the wrong constant, which surfaces as a corrupted
** value somewhere far away.
**
** So: round-trip every field independently and at its boundary, prove the
** fields do not bleed into each other, and pin the two properties the emitter
** relies on -- that the word stays a positive int32 (so it can travel as a
** plain 32-bit immediate) and that LC_RTF_FITS rejects exactly what does not
** round-trip.
*/
#include "test_harness.h"
#include "common/rt_frame_abi.h"

int main( void ) {
    TEST_BEGIN( "rt_frame_abi" );

    /* --- round-trip: each field, independently ---------------------------- */
    {
        int w = ( int )LC_RTF_PACK( 7, 200, 999, 1 );
        CHECK( LC_RTF_A( w ) == 7 );
        CHECK( LC_RTF_B( w ) == 200 );
        CHECK( LC_RTF_C( w ) == 999 );
        CHECK( LC_RTF_K( w ) == 1 );
    }

    /* --- zero and maximum, so an off-by-one in a shift shows up ----------- */
    {
        int lo = ( int )LC_RTF_PACK( 0, 0, 0, 0 );
        CHECK( lo == 0 );
        CHECK( LC_RTF_A( lo ) == 0 && LC_RTF_B( lo ) == 0 &&
               LC_RTF_C( lo ) == 0 && LC_RTF_K( lo ) == 0 );

        int hi = ( int )LC_RTF_PACK( LC_RTF_MAX, LC_RTF_MAX, LC_RTF_MAX, 1 );
        CHECK( LC_RTF_A( hi ) == LC_RTF_MAX );
        CHECK( LC_RTF_B( hi ) == LC_RTF_MAX );
        CHECK( LC_RTF_C( hi ) == LC_RTF_MAX );
        CHECK( LC_RTF_K( hi ) == 1 );

        /* The emitter uses `mov r8d, imm32` and the helpers take a signed int.
           If a future field pushes into bit 31 the word goes negative and the
           immediate changes meaning -- catch that here, not in a miscompile. */
        CHECK( hi > 0 );
    }

    /* --- fields must not bleed: set one, all others stay zero ------------- */
    {
        int a = ( int )LC_RTF_PACK( LC_RTF_MAX, 0, 0, 0 );
        CHECK( LC_RTF_B( a ) == 0 && LC_RTF_C( a ) == 0 && LC_RTF_K( a ) == 0 );

        int b = ( int )LC_RTF_PACK( 0, LC_RTF_MAX, 0, 0 );
        CHECK( LC_RTF_A( b ) == 0 && LC_RTF_C( b ) == 0 && LC_RTF_K( b ) == 0 );

        int c = ( int )LC_RTF_PACK( 0, 0, LC_RTF_MAX, 0 );
        CHECK( LC_RTF_A( c ) == 0 && LC_RTF_B( c ) == 0 && LC_RTF_K( c ) == 0 );

        int k = ( int )LC_RTF_PACK( 0, 0, 0, 1 );
        CHECK( LC_RTF_A( k ) == 0 && LC_RTF_B( k ) == 0 && LC_RTF_C( k ) == 0 );
        CHECK( LC_RTF_K( k ) == 1 );
    }

    /* --- K is a flag, not a field: any non-zero means 1 -------------------- */
    {
        int w = ( int )LC_RTF_PACK( 1, 2, 3, 42 );
        CHECK( LC_RTF_K( w ) == 1 );
        CHECK( LC_RTF_A( w ) == 1 && LC_RTF_B( w ) == 2 && LC_RTF_C( w ) == 3 );
    }

    /* --- FITS accepts exactly the round-trippable range -------------------- */
    {
        CHECK( LC_RTF_FITS( 0, 0, 0 ) );
        CHECK( LC_RTF_FITS( LC_RTF_MAX, LC_RTF_MAX, LC_RTF_MAX ) );
        CHECK( !LC_RTF_FITS( LC_RTF_MAX + 1, 0, 0 ) );
        CHECK( !LC_RTF_FITS( 0, LC_RTF_MAX + 1, 0 ) );
        CHECK( !LC_RTF_FITS( 0, 0, LC_RTF_MAX + 1 ) );

        /* Negative operands must be rejected too. codegen decodes a setter's
           signed Ck before calling FITS, but an operand that is negative for
           any other reason would wrap to a huge unsigned and silently pack as
           some other value -- so the unsigned compare has to catch it. */
        CHECK( !LC_RTF_FITS( -1, 0, 0 ) );
        CHECK( !LC_RTF_FITS( 0, -1, 0 ) );
        CHECK( !LC_RTF_FITS( 0, 0, -1 ) );
    }

    /* --- every Lua iABC operand fits, which is the whole premise ----------- */
    {
        /* Lua's A, B and C are 8 bits. If LC_RTF_BITS ever drops below that,
           the frame-passing path would fall back for ordinary code and quietly
           stop paying for itself. */
        CHECK( LC_RTF_MAX >= 255 );
        for ( int i = 0; i <= 255; i++ ) {
            int w = ( int )LC_RTF_PACK( i, 255 - i, i, i & 1 );
            CHECK( LC_RTF_A( w ) == i );
            CHECK( LC_RTF_B( w ) == 255 - i );
            CHECK( LC_RTF_C( w ) == i );
            CHECK( LC_RTF_K( w ) == ( i & 1 ) );
        }
    }

    TEST_END();
}
