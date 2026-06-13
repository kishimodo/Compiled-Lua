/*!
 * @brief
 *  Thread-safe lazy allocation of a process-global Win32 TLS slot.
 *
 *  The AOT runtime stores its per-thread execution state (JIT recovery frame,
 *  tail-call drive flag, current coroutine) in Win32 TLS slots rather than
 *  `__thread` -- a `__thread` would drag in gcc's emutls (+ winpthread), which
 *  the lean internal linker cannot resolve. A slot is allocated on first use,
 *  which can race when several native worker threads (thread.spawn) touch the
 *  same state for the first time at once. CluaTls_Ensure resolves that race:
 *  the first writer's TlsAlloc wins via an interlocked compare-exchange and the
 *  losers free their spare slot. Reads of the slot are plain aligned 32-bit
 *  loads (atomic) and see either the sentinel (-> the caller treats the value
 *  as unset, which is correct for a thread that has not written yet) or the
 *  final slot index.
 */

#ifndef CLUA_JIT_TLS_SLOT_H
#define CLUA_JIT_TLS_SLOT_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

static inline DWORD CluaTls_Ensure( volatile LONG *PSlot ) {
    DWORD cur = ( DWORD )*PSlot;
    if ( cur == TLS_OUT_OF_INDEXES ) {
        DWORD s = TlsAlloc( );
        LONG  prev;
        if ( s == TLS_OUT_OF_INDEXES ) return TLS_OUT_OF_INDEXES;
        prev = InterlockedCompareExchange( PSlot, ( LONG )s, ( LONG )TLS_OUT_OF_INDEXES );
        if ( ( DWORD )prev != TLS_OUT_OF_INDEXES ) { TlsFree( s ); return ( DWORD )prev; }
        return s;
    }
    return cur;
}

#endif /* CLUA_JIT_TLS_SLOT_H */
