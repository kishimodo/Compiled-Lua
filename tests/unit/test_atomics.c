/* test_atomics.c -- ffi_atomics.c correctness.
 *
 * Phase 1: single-threaded verification of all 16 Interlocked* thunks
 *   (exchange, exchange-add, compare-exchange, inc/dec, or, and; 32/64/ptr).
 * Phase 2: two-thread contention -- each thread increments a shared int32
 *   counter 10 000 times; the final value must be exactly 20 000. */

#include "test_harness.h"
#include "ffi/ffi_atomics.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

typedef int32_t (*FnI32_PP)(int32_t volatile *, int32_t);
typedef int32_t (*FnI32_P) (int32_t volatile *);
typedef int32_t (*FnI32_PPP)(int32_t volatile *, int32_t, int32_t);
typedef int64_t (*FnI64_PP)(int64_t volatile *, int64_t);
typedef int64_t (*FnI64_P) (int64_t volatile *);
typedef int64_t (*FnI64_PPP)(int64_t volatile *, int64_t, int64_t);
typedef void *  (*FnPtr_PP)(void * volatile *, void *);
typedef void *  (*FnPtr_PPP)(void * volatile *, void *, void *);

#define THREAD_ITERS 10000
static int32_t g_Counter = 0;

static DWORD WINAPI IncThread( LPVOID Arg ) {
    FnI32_P inc = ( FnI32_P )Arg;
    for ( int I = 0; I < THREAD_ITERS; I++ ) inc( &g_Counter );
    return 0;
}

int main( void ) {
    TEST_BEGIN( "atomics" );

    /* ---- lookup table: all 16 names resolve, unknown names return NULL ---- */
    const char *known[] = {
        "InterlockedExchange",          "InterlockedExchange64",
        "InterlockedExchangePointer",   "InterlockedExchangeAdd",
        "InterlockedExchangeAdd64",     "InterlockedCompareExchange",
        "InterlockedCompareExchange64", "InterlockedCompareExchangePointer",
        "InterlockedIncrement",         "InterlockedDecrement",
        "InterlockedIncrement64",       "InterlockedDecrement64",
        "InterlockedOr",                "InterlockedOr64",
        "InterlockedAnd",               "InterlockedAnd64",
        NULL
    };
    for ( int I = 0; known[ I ]; I++ ) CHECK_NOT_NULL( Ffi_AtomicsLookup( known[ I ] ) );
    CHECK_NULL( Ffi_AtomicsLookup( "NotARealInterlockedFn" ) );
    CHECK_NULL( Ffi_AtomicsLookup( NULL ) );

    /* ---- InterlockedExchange: returns old, stores new ---- */
    {
        FnI32_PP xchg = ( FnI32_PP )Ffi_AtomicsLookup( "InterlockedExchange" );
        int32_t cell  = 0;
        CHECK_EQ_INT( xchg( &cell, 42 ), 0 );
        CHECK_EQ_INT( cell, 42 );
        CHECK_EQ_INT( xchg( &cell, 7  ), 42 );
        CHECK_EQ_INT( cell, 7 );
    }

    /* ---- InterlockedExchangeAdd: returns old, adds delta ---- */
    {
        FnI32_PP xadd = ( FnI32_PP )Ffi_AtomicsLookup( "InterlockedExchangeAdd" );
        int32_t cell  = 10;
        CHECK_EQ_INT( xadd( &cell,  5 ), 10 );
        CHECK_EQ_INT( cell, 15 );
        CHECK_EQ_INT( xadd( &cell, -3 ), 15 );
        CHECK_EQ_INT( cell, 12 );
    }

    /* ---- InterlockedCompareExchange: returns old; exchanges on match ---- */
    {
        FnI32_PPP cas  = ( FnI32_PPP )Ffi_AtomicsLookup( "InterlockedCompareExchange" );
        int32_t   cell = 100;
        CHECK_EQ_INT( cas( &cell, 200, 100 ), 100 ); /* success */
        CHECK_EQ_INT( cell, 200 );
        CHECK_EQ_INT( cas( &cell, 999, 100 ), 200 ); /* fail (cell != 100) */
        CHECK_EQ_INT( cell, 200 );
    }

    /* ---- InterlockedIncrement / InterlockedDecrement: return new value ---- */
    {
        FnI32_P inc = ( FnI32_P )Ffi_AtomicsLookup( "InterlockedIncrement" );
        FnI32_P dec = ( FnI32_P )Ffi_AtomicsLookup( "InterlockedDecrement" );
        int32_t cell = 0;
        CHECK_EQ_INT( inc( &cell ), 1 );
        CHECK_EQ_INT( inc( &cell ), 2 );
        CHECK_EQ_INT( dec( &cell ), 1 );
        CHECK_EQ_INT( dec( &cell ), 0 );
    }

    /* ---- InterlockedOr / InterlockedAnd: return old value ---- */
    {
        FnI32_PP or32  = ( FnI32_PP )Ffi_AtomicsLookup( "InterlockedOr"  );
        FnI32_PP and32 = ( FnI32_PP )Ffi_AtomicsLookup( "InterlockedAnd" );
        int32_t cell   = 0xFF00;
        CHECK_EQ_INT( or32(  &cell, 0x00FF ), 0xFF00 );
        CHECK_EQ_INT( cell, 0xFFFF );
        CHECK_EQ_INT( and32( &cell, 0x0F0F ), 0xFFFF );
        CHECK_EQ_INT( cell, 0x0F0F );
    }

    /* ---- 64-bit exchange ---- */
    {
        FnI64_PP xchg = ( FnI64_PP )Ffi_AtomicsLookup( "InterlockedExchange64" );
        int64_t  cell = 0;
        CHECK_EQ_INT( ( long long )xchg( &cell, ( int64_t )0x1234567890ABCDEFLL ), 0 );
        CHECK_EQ_INT( ( long long )cell, ( long long )0x1234567890ABCDEFLL );
    }

    /* ---- 64-bit exchange-add ---- */
    {
        FnI64_PP xadd = ( FnI64_PP )Ffi_AtomicsLookup( "InterlockedExchangeAdd64" );
        int64_t  cell = ( int64_t )1000000000000LL;
        CHECK_EQ_INT( ( long long )xadd( &cell, 7 ), ( long long )1000000000000LL );
        CHECK_EQ_INT( ( long long )cell,             ( long long )1000000000007LL );
    }

    /* ---- 64-bit CAS ---- */
    {
        FnI64_PPP cas  = ( FnI64_PPP )Ffi_AtomicsLookup( "InterlockedCompareExchange64" );
        int64_t   cell = 42;
        CHECK_EQ_INT( ( long long )cas( &cell, 99, 42 ), 42 ); /* success */
        CHECK_EQ_INT( ( long long )cell, 99 );
        CHECK_EQ_INT( ( long long )cas( &cell,  0, 42 ), 99 ); /* fail */
        CHECK_EQ_INT( ( long long )cell, 99 );
    }

    /* ---- 64-bit inc/dec ---- */
    {
        FnI64_P inc = ( FnI64_P )Ffi_AtomicsLookup( "InterlockedIncrement64" );
        FnI64_P dec = ( FnI64_P )Ffi_AtomicsLookup( "InterlockedDecrement64" );
        int64_t cell = ( int64_t )-1;
        CHECK_EQ_INT( ( long long )inc( &cell ),  0 );
        CHECK_EQ_INT( ( long long )dec( &cell ), -1 );
    }

    /* ---- 64-bit or/and ---- */
    {
        FnI64_PP or64  = ( FnI64_PP )Ffi_AtomicsLookup( "InterlockedOr64"  );
        FnI64_PP and64 = ( FnI64_PP )Ffi_AtomicsLookup( "InterlockedAnd64" );
        int64_t cell   = ( int64_t )0xFF00FF0000000000LL;
        or64(  &cell, ( int64_t )0x00FF00FFLL );
        CHECK_EQ_INT( ( long long )cell, ( long long )0xFF00FF0000FF00FFLL );
        and64( &cell, ( int64_t )0x0F0F0F0F0F0F0F0FLL );
        CHECK_EQ_INT( ( long long )cell, ( long long )0x0F000F00000F000FLL );
    }

    /* ---- pointer exchange ---- */
    {
        FnPtr_PP pxchg = ( FnPtr_PP )Ffi_AtomicsLookup( "InterlockedExchangePointer" );
        int      d1 = 1, d2 = 2;
        void    *cell = &d1;
        void    *old  = pxchg( &cell, &d2 );
        CHECK( old == &d1 );
        CHECK( cell == &d2 );
    }

    /* ---- pointer CAS ---- */
    {
        FnPtr_PPP pcas = ( FnPtr_PPP )Ffi_AtomicsLookup( "InterlockedCompareExchangePointer" );
        int       d1 = 1, d2 = 2, d3 = 3;
        void     *cell = &d1;
        void     *old  = pcas( &cell, &d2, &d1 );  /* success */
        CHECK( old == &d1 );
        CHECK( cell == &d2 );
        old = pcas( &cell, &d3, &d1 );              /* fail */
        CHECK( old == &d2 );
        CHECK( cell == &d2 );
    }

    /* ---- two-thread contention ---- */
    /* Both threads call InterlockedIncrement on the same counter; no
       increments may be lost.  Final value must equal 2 * THREAD_ITERS. */
    {
        FnI32_P  inc = ( FnI32_P )Ffi_AtomicsLookup( "InterlockedIncrement" );
        g_Counter    = 0;
        HANDLE T1    = CreateThread( NULL, 0, IncThread, ( LPVOID )inc, 0, NULL );
        HANDLE T2    = CreateThread( NULL, 0, IncThread, ( LPVOID )inc, 0, NULL );
        CHECK_NOT_NULL( T1 );
        CHECK_NOT_NULL( T2 );
        if ( T1 && T2 ) {
            HANDLE Hs[ 2 ] = { T1, T2 };
            WaitForMultipleObjects( 2, Hs, TRUE, INFINITE );
        }
        if ( T1 ) CloseHandle( T1 );
        if ( T2 ) CloseHandle( T2 );
        CHECK_EQ_INT( g_Counter, 2 * THREAD_ITERS );
    }

    TEST_END( );
}
