/*!
 * @brief
 *  Built-in atomic thunks for Interlocked* intrinsics.  See ffi_atomics.h.
 *
 *  GCC __atomic builtins with __ATOMIC_SEQ_CST compile to LOCK-prefixed x64
 *  instructions (xchg / lock xadd / lock cmpxchg / lock or / lock and) which
 *  give sequentially consistent semantics, identical to what the Win32
 *  intrinsic versions emit.
 */

#include "ffi/ffi_atomics.h"

#include <stdint.h>
#include <string.h>

/* ---- 32-bit variants ---------------------------------------------------- */

static int32_t A_InterlockedExchange( int32_t volatile *T, int32_t V ) {
    return __atomic_exchange_n( ( int32_t * )T, V, __ATOMIC_SEQ_CST );
}

static int32_t A_InterlockedExchangeAdd( int32_t volatile *A, int32_t V ) {
    return __atomic_fetch_add( ( int32_t * )A, V, __ATOMIC_SEQ_CST );
}

static int32_t A_InterlockedCompareExchange( int32_t volatile *D,
                                             int32_t E, int32_t C ) {
    int32_t Exp = C;
    __atomic_compare_exchange_n( ( int32_t * )D, &Exp, E,
                                 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST );
    return Exp;
}

static int32_t A_InterlockedIncrement( int32_t volatile *A ) {
    return __atomic_add_fetch( ( int32_t * )A, 1, __ATOMIC_SEQ_CST );
}

static int32_t A_InterlockedDecrement( int32_t volatile *A ) {
    return __atomic_sub_fetch( ( int32_t * )A, 1, __ATOMIC_SEQ_CST );
}

static int32_t A_InterlockedOr( int32_t volatile *D, int32_t V ) {
    return __atomic_fetch_or( ( int32_t * )D, V, __ATOMIC_SEQ_CST );
}

static int32_t A_InterlockedAnd( int32_t volatile *D, int32_t V ) {
    return __atomic_fetch_and( ( int32_t * )D, V, __ATOMIC_SEQ_CST );
}

/* ---- 64-bit variants ---------------------------------------------------- */

static int64_t A_InterlockedExchange64( int64_t volatile *T, int64_t V ) {
    return __atomic_exchange_n( ( int64_t * )T, V, __ATOMIC_SEQ_CST );
}

static int64_t A_InterlockedExchangeAdd64( int64_t volatile *A, int64_t V ) {
    return __atomic_fetch_add( ( int64_t * )A, V, __ATOMIC_SEQ_CST );
}

static int64_t A_InterlockedCompareExchange64( int64_t volatile *D,
                                               int64_t E, int64_t C ) {
    int64_t Exp = C;
    __atomic_compare_exchange_n( ( int64_t * )D, &Exp, E,
                                 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST );
    return Exp;
}

static int64_t A_InterlockedIncrement64( int64_t volatile *A ) {
    return __atomic_add_fetch( ( int64_t * )A, ( int64_t )1, __ATOMIC_SEQ_CST );
}

static int64_t A_InterlockedDecrement64( int64_t volatile *A ) {
    return __atomic_sub_fetch( ( int64_t * )A, ( int64_t )1, __ATOMIC_SEQ_CST );
}

static int64_t A_InterlockedOr64( int64_t volatile *D, int64_t V ) {
    return __atomic_fetch_or( ( int64_t * )D, V, __ATOMIC_SEQ_CST );
}

static int64_t A_InterlockedAnd64( int64_t volatile *D, int64_t V ) {
    return __atomic_fetch_and( ( int64_t * )D, V, __ATOMIC_SEQ_CST );
}

/* ---- Pointer variants --------------------------------------------------- */

static void *A_InterlockedExchangePointer( void * volatile *T, void *V ) {
    void *Old;
    __atomic_exchange( ( void ** )T, &V, &Old, __ATOMIC_SEQ_CST );
    return Old;
}

static void *A_InterlockedCompareExchangePointer( void * volatile *D,
                                                  void *E, void *C ) {
    void *Exp = C;
    __atomic_compare_exchange_n( ( void ** )D, &Exp, E,
                                 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST );
    return Exp;
}

/* ---- Name table --------------------------------------------------------- */

typedef struct {
    const char *Name;
    void       *Fn;
} AtomicEntry_T;

static const AtomicEntry_T g_AtomicsTable[] = {
    { "InterlockedExchange",               ( void * )A_InterlockedExchange               },
    { "InterlockedExchange64",             ( void * )A_InterlockedExchange64             },
    { "InterlockedExchangePointer",        ( void * )A_InterlockedExchangePointer        },
    { "InterlockedExchangeAdd",            ( void * )A_InterlockedExchangeAdd            },
    { "InterlockedExchangeAdd64",          ( void * )A_InterlockedExchangeAdd64          },
    { "InterlockedCompareExchange",        ( void * )A_InterlockedCompareExchange        },
    { "InterlockedCompareExchange64",      ( void * )A_InterlockedCompareExchange64      },
    { "InterlockedCompareExchangePointer", ( void * )A_InterlockedCompareExchangePointer },
    { "InterlockedIncrement",              ( void * )A_InterlockedIncrement              },
    { "InterlockedDecrement",              ( void * )A_InterlockedDecrement              },
    { "InterlockedIncrement64",            ( void * )A_InterlockedIncrement64            },
    { "InterlockedDecrement64",            ( void * )A_InterlockedDecrement64            },
    { "InterlockedOr",                     ( void * )A_InterlockedOr                     },
    { "InterlockedOr64",                   ( void * )A_InterlockedOr64                   },
    { "InterlockedAnd",                    ( void * )A_InterlockedAnd                    },
    { "InterlockedAnd64",                  ( void * )A_InterlockedAnd64                  },
    { NULL,                                NULL                                           },
};

void *Ffi_AtomicsLookup( const char *Sym ) {
    if ( Sym == NULL ) return NULL;
    int I = 0;
    for ( ; g_AtomicsTable[ I ].Name != NULL; I++ ) {
        if ( strcmp( g_AtomicsTable[ I ].Name, Sym ) == 0 ) {
            return g_AtomicsTable[ I ].Fn;
        }
    }
    return NULL;
}
