#include "driver/supported_ops.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lopnames.h"
#include <stdio.h>
#include <string.h>

static int OpSupported( int op ) {
    switch ( op ) {
        case OP_VARARGPREP:
        case OP_GETTABUP:
        case OP_LOADK:
        case OP_CALL:
        case OP_RETURN:
        case OP_RETURN0:
        case OP_RETURN1:
            return 1;
        default:
            return 0;
    }
}

static int Scan( Proto *P, char *Err, size_t ErrLen ) {
    int i;
    for ( i = 0; i < P->sizecode; i++ ) {
        int op = GET_OPCODE( P->code[i] );
        if ( !OpSupported( op ) ) {
            const char *name = ( op >= 0 && opnames[op] != NULL ) ? opnames[op] : NULL;
            if ( name ) {
                snprintf( Err, ErrLen,
                    "error: opcode OP_%s (opcode %d) is not yet supported by the "
                    "LuaC backend (this program uses a language feature beyond the "
                    "current milestone)",
                    name, op );
            } else {
                snprintf( Err, ErrLen,
                    "error: opcode %d is not yet supported by the LuaC backend "
                    "(this program uses a language feature beyond the current milestone)",
                    op );
            }
            return 0;
        }
    }
    { int j; for ( j = 0; j < P->sizep; j++ ) if ( !Scan( P->p[j], Err, ErrLen ) ) return 0; }
    return 1;
}

int Lc_CheckSupportedOps( Proto *P, char *Err, size_t ErrLen ) {
    if ( Err && ErrLen ) Err[0] = 0;
    return Scan( P, Err, ErrLen );
}
