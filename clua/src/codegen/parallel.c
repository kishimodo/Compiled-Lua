/*
** parallel.c -- per-function codegen dispatch across a small win32 thread pool.
**
** The precondition for this file is enforced by tools/test-codegen-no-globals.lua:
** every source in clua/src/codegen/ has zero mutable file-scope state. LcCgCtx is
** per-compilation and read-only after setup; LcCgFnCtx is per-function and lives
** on the worker's stack. Two workers compiling m->funcs[i] and m->funcs[j]
** (i != j) therefore share (a) the source module m -- read-only during codegen --
** and (b) the destination cm -- but they only ever WRITE to cm->funcs[k] for a
** k that a single worker owns (each k is pulled off an atomic counter exactly
** once). No lock is needed inside LcCg_CompileFunctionBody.
**
** Thread creation goes through _beginthreadex (NOT CreateThread) for the same
** reason clua/src/runtime/aot_entry.c does: the compiler codegen allocates via
** the CRT (malloc/realloc/free through LcCodeBuf), and a CreateThread'd worker
** skips the per-thread CRT initialisation that keeps the heap intact under
** concurrency. The Windows CRT malloc/free are themselves thread-safe.
**
** Correctness notes worth writing down (in order of what would go wrong first
** if a well-meaning change removed them):
**   - InterlockedIncrement, not `int++`: two workers reading the same counter
**     and racing to increment would both take job k, silently miscompile the
**     pair, and the byte-identity gate would only catch it on the runs where
**     the race fired. The atomic returns the POST-increment value, so we take
**     v = InterlockedIncrement(&next) - 1 to get a fresh 0-based index.
**   - WaitForMultipleObjects has a finite deadline. INFINITE would let one
**     wedged worker hang the whole compile with no diagnostic; a 60s timeout
**     is longer than any codegen we have ever seen and short enough that a
**     hung build fails visibly.
**   - Any worker returning non-zero fails the whole run. We publish the first
**     failure into a shared int; the main thread converts that into a whole-
**     module failure after the join. Individual workers do not free cm; the
**     caller does (lc_codemodule_free is safe against zeroed slots because
**     free(NULL) is a no-op).
*/

#include "codegen.h"
#include "../ir/ir.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include <windows.h>       /* HANDLE, WaitForMultipleObjects, InterlockedIncrement */
#include <process.h>       /* _beginthreadex -- CRT-correct thread creation        */

/* Compile-time cap on worker threads. WaitForMultipleObjects tops out at
   MAXIMUM_WAIT_OBJECTS (64) per call; clamping here avoids the "split the wait
   into batches" path, which no plausible machine needs. */
#define LC_CG_MAX_JOBS 64

/* Shared, MUTABLE-BUT-SYNCHRONISED state for the pool. Lives on the main
   thread's stack across the CreateThreadEx / WaitForMultipleObjects sequence;
   every field is either atomic (next_idx) or race-safe (fail_flag is written
   monotonically 0 -> non-zero, races are benign because "any failure wins").

   Not a file-scope object, deliberately: putting this in `static` would trip
   tools/test-codegen-no-globals.lua and, worse, would silently break two
   concurrent compilations sharing this translation unit (which nothing today
   does, but the invariant test is what keeps that from silently regressing). */
typedef struct LcCgParPool {
    /* immutable across the run */
    LcModule       *m;
    LcCodeModule   *cm;
    const LcCgCtx  *cg;
    uint32_t        nfuncs;
    /* synchronised counters */
    volatile LONG   next_idx;    /* InterlockedIncrement()-driven work index      */
    volatile LONG   fail_flag;   /* set non-zero by any worker that fails         */
} LcCgParPool;

/* Worker body: pull one index at a time from the atomic counter, compile
   m->funcs[i] into cm->funcs[i], and set fail_flag on any failure. A worker
   whose pull index is >= nfuncs is done; a worker that observes fail_flag != 0
   bails early (avoids doing more work when the module is already doomed --
   the wait join still gets us). */
static unsigned __stdcall LcCg_ParWorker( void *param ) {
    LcCgParPool *P = ( LcCgParPool * )param;
    for ( ;; ) {
        LONG raw = InterlockedIncrement( &P->next_idx );
        uint32_t i = ( uint32_t )( raw - 1 );
        if ( i >= P->nfuncs ) return 0;
        if ( P->fail_flag ) return 0;         /* early bail: someone failed */
        if ( !LcCg_CompileFunctionBody( P->m, P->cm, P->cg, i ) ) {
            InterlockedIncrement( &P->fail_flag );
            return 1;
        }
    }
}

/* Run per-function codegen across `jobs` worker threads. jobs must be >= 1
   (the caller collapses jobs == 1 to the sequential path; this function still
   handles the degenerate case correctly, but it's worth doing that check up
   the stack so the sequential path stays exactly the shape it was pre-
   parallel). Returns 1 on success, 0 on failure. */
int LcCg_RunParallel( LcModule *m, LcCodeModule *cm,
                      const LcCgCtx *cg, int jobs ) {
    LcCgParPool pool;
    HANDLE      threads[ LC_CG_MAX_JOBS ];
    int         n_started = 0;
    int         i;
    DWORD       wait_r;
    int         ok = 1;
    /* 60s is longer than any codegen we have ever seen (rover is <1s) and
       short enough that a wedged worker fails visibly rather than hanging the
       build indefinitely. If a future change makes codegen slower this needs
       to grow, but "grow the timeout" is a better failure mode than
       "compiler wedges forever with no output". */
    const DWORD kTimeoutMs = 60 * 1000;

    if ( m == NULL || cm == NULL || cg == NULL ) return 0;
    if ( jobs < 1 ) jobs = 1;
    if ( jobs > LC_CG_MAX_JOBS ) jobs = LC_CG_MAX_JOBS;
    if ( ( uint32_t )jobs > cm->nfuncs ) jobs = ( int )cm->nfuncs;
    if ( jobs < 1 ) jobs = 1;

    pool.m         = m;
    pool.cm        = cm;
    pool.cg        = cg;
    pool.nfuncs    = cm->nfuncs;
    pool.next_idx  = 0;
    pool.fail_flag = 0;

    /* Spawn workers. If any CreateThread fails we run the ones that did
       start (they will drain the queue) and then fail the whole compile
       so a partial run cannot silently mask a real error. */
    for ( i = 0; i < jobs; i++ ) {
        uintptr_t h = _beginthreadex( NULL, 0, LcCg_ParWorker, &pool, 0, NULL );
        if ( h == 0 ) {
            InterlockedIncrement( &pool.fail_flag );
            ok = 0;
            break;
        }
        threads[ n_started++ ] = ( HANDLE )h;
    }

    if ( n_started > 0 ) {
        wait_r = WaitForMultipleObjects( ( DWORD )n_started, threads,
                                         TRUE /* wait for all */,
                                         kTimeoutMs );
        if ( wait_r == WAIT_TIMEOUT ) {
            /* Fatal: a worker is wedged. We deliberately do NOT try to kill
               the threads (TerminateThread leaks the CRT per-thread state and
               can leave a lock held). Let them run to completion after the
               process exits; return failure to the driver so the build does
               not silently continue on partial output. */
            ok = 0;
        } else if ( wait_r == WAIT_FAILED ) {
            ok = 0;
        }
        for ( i = 0; i < n_started; i++ ) {
            CloseHandle( threads[ i ] );
        }
    }

    if ( pool.fail_flag ) ok = 0;
    return ok;
}
