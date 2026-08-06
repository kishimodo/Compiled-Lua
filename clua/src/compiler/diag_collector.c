/* diag_collector.c -- see diag_collector.h.
 *
 * A trivial dynamic array. The interesting piece is what CALLS it: the
 * resolve driver, after a per-module compile failure, records the error and
 * continues iterating instead of returning immediately. The user then sees
 * every module's error in one build, in the order the driver visited them.
 * Ordering is stable: the entry module is pushed first (if it fails), then
 * queue modules in the order the FIFO drained them. */
#include "compiler/diag_collector.h"

#include <stdlib.h>
#include <string.h>

void LcDiagCollector_Init( PLC_DIAG_COLLECTOR_T C ) {
    if ( C == NULL ) return;
    C->Entries = NULL;
    C->Count   = 0;
    C->Cap     = 0;
}

static char *DupStr( const char *S ) {
    /* Local dup so we don't pull in strdup's platform variance and can
       tolerate NULL as an empty string (some Lua error paths hand out
       lua_tostring(L,-1) that is technically nullable). */
    size_t N;
    char  *P;
    if ( S == NULL ) S = "";
    N = strlen( S );
    P = ( char * )malloc( N + 1 );
    if ( P == NULL ) return NULL;
    memcpy( P, S, N + 1 );
    return P;
}

void LcDiagCollector_Push( PLC_DIAG_COLLECTOR_T C, const char *Path,
                           const char *Message ) {
    char *P, *M;
    if ( C == NULL ) return;
    if ( C->Count == C->Cap ) {
        size_t Nc = C->Cap ? C->Cap * 2 : 4;
        PLC_DIAG_ENTRY_T Grown = ( PLC_DIAG_ENTRY_T )realloc(
            C->Entries, Nc * sizeof( LC_DIAG_ENTRY_T ) );
        if ( Grown == NULL ) return;         /* drop on OOM; see header */
        C->Entries = Grown;
        C->Cap     = Nc;
    }
    P = DupStr( Path ? Path : "" );
    M = DupStr( Message ? Message : "(unknown error)" );
    if ( P == NULL || M == NULL ) {
        free( P );
        free( M );
        return;
    }
    C->Entries[ C->Count ].Path    = P;
    C->Entries[ C->Count ].Message = M;
    C->Count++;
}

size_t LcDiagCollector_Drain( PLC_DIAG_COLLECTOR_T C, const DIAG_OPTS_T *Opts ) {
    size_t I;
    if ( C == NULL ) return 0;
    for ( I = 0; I < C->Count; I++ ) {
        Diag_PrintCompileError( C->Entries[ I ].Path,
                                C->Entries[ I ].Message,
                                0, Opts );
    }
    return C->Count;
}

void LcDiagCollector_Free( PLC_DIAG_COLLECTOR_T C ) {
    size_t I;
    if ( C == NULL ) return;
    for ( I = 0; I < C->Count; I++ ) {
        free( C->Entries[ I ].Path );
        free( C->Entries[ I ].Message );
    }
    free( C->Entries );
    C->Entries = NULL;
    C->Count   = 0;
    C->Cap     = 0;
}
