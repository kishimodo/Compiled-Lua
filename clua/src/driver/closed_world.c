#include "driver/closed_world.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lstring.h"
#include <string.h>
#include <stdio.h>

static int IsName( const TValue *K, const char *Name ) {
    return ttisstring( K ) && strcmp( getstr( tsvalue( K ) ), Name ) == 0;
}

static int ScanProto( Proto *P, char *Err, size_t ErrLen ) {
    int i;
    for ( i = 0; i < P->sizecode; i++ ) {
        Instruction op = P->code[i];
        int oc = GET_OPCODE( op );
        if ( oc == OP_GETTABUP ) {
            const TValue *K = &P->k[ GETARG_C( op ) ];
            const char *banned[] = { "load", "loadstring", "dofile", NULL };
            int b;
            for ( b = 0; banned[b]; b++ ) {
                if ( IsName( K, banned[b] ) ) {
                    snprintf( Err, ErrLen, "error: %s() is not permitted in an "
                              "AOT-compiled program (closed world)", banned[b] );
                    return 0;
                }
            }
            if ( IsName( K, "require" ) ) {
                if ( i + 1 >= P->sizecode || GET_OPCODE( P->code[i + 1] ) != OP_LOADK ) {
                    snprintf( Err, ErrLen, "error: dynamic require(<non-constant>) is not "
                              "resolvable in an AOT-compiled program (closed world)" );
                    return 0;
                }
            }
        }
        if ( ( oc == OP_GETFIELD || oc == OP_GETTABUP ) && IsName( &P->k[ GETARG_C( op ) ], "dump" ) ) {
            snprintf( Err, ErrLen, "error: string.dump is not permitted in an "
                      "AOT-compiled program (closed world)" );
            return 0;
        }
    }
    { int j; for ( j = 0; j < P->sizep; j++ ) if ( !ScanProto( P->p[j], Err, ErrLen ) ) return 0; }
    return 1;
}

int Lc_CheckClosedWorld( Proto *P, char *Err, size_t ErrLen ) {
    if ( Err && ErrLen ) Err[0] = 0;
    return ScanProto( P, Err, ErrLen );
}
