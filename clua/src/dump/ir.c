/*
** ir.c -- diagnostic dump of the LcModule, one function per section.
**
** Prints the IR the optimizer produced, right before codegen consumes it.
** Every instruction gets its own line with:
**
**     [bc_pc]  LC_OP_<opcode>  A=.. B=.. C=..  ; type=<result kind>  bc=<Lua op>
**
** The result-type annotation (from LcInst.result.type) is the interesting
** part: it is what M1 tag-check elision and integer FORLOOP residency
** decide against, so a dump lets you see whether a given op is running the
** typed fast path or the boxed fallback.
*/
#include "dump/emit.h"

#include "ir/ir.h"

#include <stdio.h>
#include <string.h>

/* Keep the order aligned with LcOpcode in ir/ir.h. Anything missing is
** printed as OP_? by name, so a new opcode does not go silently unnamed. */
static const char *const kOpNames[] = {
    [ LC_OP_CONST       ] = "LC_OP_CONST",
    [ LC_OP_PHI         ] = "LC_OP_PHI",
    [ LC_OP_ARG         ] = "LC_OP_ARG",
    [ LC_OP_UPVAL_GET   ] = "LC_OP_UPVAL_GET",
    [ LC_OP_UPVAL_SET   ] = "LC_OP_UPVAL_SET",
    [ LC_OP_GLOBAL_GET  ] = "LC_OP_GLOBAL_GET",
    [ LC_OP_GLOBAL_SET  ] = "LC_OP_GLOBAL_SET",
    [ LC_OP_ARITH       ] = "LC_OP_ARITH",
    [ LC_OP_IARITH      ] = "LC_OP_IARITH",
    [ LC_OP_FARITH      ] = "LC_OP_FARITH",
    [ LC_OP_BITWISE     ] = "LC_OP_BITWISE",
    [ LC_OP_UNM         ] = "LC_OP_UNM",
    [ LC_OP_NOT         ] = "LC_OP_NOT",
    [ LC_OP_LEN         ] = "LC_OP_LEN",
    [ LC_OP_CONCAT      ] = "LC_OP_CONCAT",
    [ LC_OP_CMP         ] = "LC_OP_CMP",
    [ LC_OP_ICMP        ] = "LC_OP_ICMP",
    [ LC_OP_FCMP        ] = "LC_OP_FCMP",
    [ LC_OP_TEST        ] = "LC_OP_TEST",
    [ LC_OP_BRANCH      ] = "LC_OP_BRANCH",
    [ LC_OP_JMP         ] = "LC_OP_JMP",
    [ LC_OP_NEWTABLE    ] = "LC_OP_NEWTABLE",
    [ LC_OP_TABLE_GET   ] = "LC_OP_TABLE_GET",
    [ LC_OP_TABLE_SET   ] = "LC_OP_TABLE_SET",
    [ LC_OP_RAWGET      ] = "LC_OP_RAWGET",
    [ LC_OP_RAWSET      ] = "LC_OP_RAWSET",
    [ LC_OP_CALL        ] = "LC_OP_CALL",
    [ LC_OP_CALL_DIRECT ] = "LC_OP_CALL_DIRECT",
    [ LC_OP_CALL_INTRIN ] = "LC_OP_CALL_INTRIN",
    [ LC_OP_CALL_FFI    ] = "LC_OP_CALL_FFI",
    [ LC_OP_TAILCALL    ] = "LC_OP_TAILCALL",
    [ LC_OP_RETURN      ] = "LC_OP_RETURN",
    [ LC_OP_VARARG      ] = "LC_OP_VARARG",
    [ LC_OP_CLOSURE     ] = "LC_OP_CLOSURE",
    [ LC_OP_FORPREP_I   ] = "LC_OP_FORPREP_I",
    [ LC_OP_FORLOOP_I   ] = "LC_OP_FORLOOP_I",
    [ LC_OP_FORPREP_F   ] = "LC_OP_FORPREP_F",
    [ LC_OP_FORLOOP_F   ] = "LC_OP_FORLOOP_F",
    [ LC_OP_TFORCALL    ] = "LC_OP_TFORCALL",
    [ LC_OP_TFORLOOP    ] = "LC_OP_TFORLOOP",
    [ LC_OP_PCALL_BEGIN ] = "LC_OP_PCALL_BEGIN",
    [ LC_OP_PCALL_END   ] = "LC_OP_PCALL_END",
};

static const char *OpName( LcOpcode op ) {
    if ( ( int )op < 0 || ( int )op >= LC_OP__COUNT ) return "LC_OP_?";
    const char *n = kOpNames[ op ];
    return n != NULL ? n : "LC_OP_?";
}

static const char *TypeName( LcTypeKind k ) {
    switch ( k ) {
    case LC_T_BOTTOM:   return "bottom";
    case LC_T_NIL:      return "nil";
    case LC_T_BOOL:     return "bool";
    case LC_T_INT:      return "int";
    case LC_T_FLT:      return "flt";
    case LC_T_NUM:      return "num";
    case LC_T_STR:      return "str";
    case LC_T_TAB:      return "tab";
    case LC_T_FUNC:     return "func";
    case LC_T_CFUNC:    return "cfunc";
    case LC_T_USERDATA: return "userdata";
    case LC_T_THREAD:   return "thread";
    case LC_T_ANY:      return "any";
    default:            return "?";
    }
}

static void DumpInst( FILE *out, const LcInst *in ) {
    LcTypeKind rk = in->result.type.kind;
    fprintf( out, "    [%4d] %-20s A=%4d B=%4d C=%4d",
             in->bc_pc, OpName( in->op ), in->a, in->b, in->c );
    /* Extra facts if we have them: proven-known bits, callee identity,
    ** result type. Everything unset (0/ANY) is silently omitted so a
    ** noise-free line still reads. */
    if ( in->known ) fprintf( out, " known=0x%02x", ( unsigned )in->known );
    if ( in->op == LC_OP_CALL && in->call_callee >= 0 ) {
        fprintf( out, " callee=fn%d", in->call_callee );
    }
    fprintf( out, "  ; bc_op=%d type=%s", in->bc_op, TypeName( rk ) );
    if ( rk == LC_T_INT && in->result.type.is_const ) {
        fprintf( out, "(%lld)", ( long long )in->result.type.cval.i );
    } else if ( rk == LC_T_FLT && in->result.type.is_const ) {
        fprintf( out, "(%.14g)", in->result.type.cval.n );
    }
    fputc( '\n', out );
}

static void DumpFunc( FILE *out, const LcFunc *f, uint32_t idx ) {
    uint32_t b;
    const char *name = ( f->module_name != NULL )
                        ? f->module_name : "<entry-or-anon>";
    fprintf( out,
        "-- function[%u] %s  nblocks=%u nargs=%u %s\n",
        idx, name, f->nblocks, ( unsigned )f->nargs,
        f->is_vararg ? "vararg" : "fixed" );

    for ( b = 0; b < f->nblocks; b++ ) {
        const LcBlock *blk = f->blocks[ b ];
        const LcInst  *in;
        if ( blk == NULL ) continue;
        fprintf( out, "  block[%u]:\n", blk->id );
        for ( in = blk->first; in != NULL; in = in->next ) {
            DumpInst( out, in );
        }
    }
}

int Lc_DumpIr( FILE *out, const LcModule *m ) {
    uint32_t i;
    if ( out == NULL || m == NULL ) return 0;
    fprintf( out, "; IR dump (opt_level=%d, nfuncs=%u)\n",
             m->opt_level, m->nfuncs );
    for ( i = 0; i < m->nfuncs; i++ ) {
        if ( m->funcs[ i ] == NULL ) continue;
        if ( i > 0 ) fputc( '\n', out );
        DumpFunc( out, m->funcs[ i ], i );
    }
    return 1;
}
