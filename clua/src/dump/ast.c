/*
** ast.c -- diagnostic tree dump of the front-end's Proto structure.
**
** `--emit=ast` walks the Proto tree (entry first, then each nested p[]
** recursively) and prints one indented block per Proto with its declared
** shape: source/lines, parameter/local/upvalue names, constant count, and
** nested-function count. Not a raw bytecode dump (that's --emit=bytecode);
** this is the front-end's parsed structure, closer to what a user asking
** "what does the parser see" wants.
**
** The output is a plain-text tree using ASCII "+-" branches (no UTF-8, no
** color) so it round-trips through the same TTY assumptions the other
** dumpers keep. Constants are summarised as counts + type kinds; nested
** function shapes are recursed into so the whole program's AST is one
** block.
*/
#include "dump/emit.h"

#include "lua.h"
#include "lobject.h"
#include "lstate.h"        /* used indirectly through tsvalue() etc. */

#include <stdio.h>
#include <string.h>

/* Print `depth` "|  " indent segments, then a "+- " branch marker so each
** printed line hangs off its parent's column. Depth 0 prints nothing. */
static void PrintIndent( FILE *out, int depth ) {
    int i;
    for ( i = 0; i < depth; i++ ) fputs( "|  ", out );
    if ( depth > 0 ) fputs( "+- ", out );
}

/* Human-readable tag for a TValue's payload (used when summarising K[]).
** Only the tags Lua's front end can emit into a Proto.k slot appear
** here; anything else prints its numeric tt for diagnostics. */
static const char *ConstTypeName( const TValue *k ) {
    switch ( ttypetag( k ) ) {
    case LUA_VNIL:     return "nil";
    case LUA_VFALSE:   return "false";
    case LUA_VTRUE:    return "true";
    case LUA_VNUMINT:  return "int";
    case LUA_VNUMFLT:  return "float";
    case LUA_VSHRSTR:
    case LUA_VLNGSTR:  return "string";
    default:           return "?";
    }
}

/* Escape a string constant for a single-line dump (quotes + control bytes
** shown as \n / \t / \NNN). Cap the visible portion so a giant embedded
** blob does not blow the line width. */
static void PrintStringLit( FILE *out, const TString *s ) {
    const char *p = getstr( s );
    size_t n = tsslen( s );
    size_t i;
    size_t cap = ( n > 40 ) ? 40 : n;
    fputc( '"', out );
    for ( i = 0; i < cap; i++ ) {
        unsigned char c = ( unsigned char )p[ i ];
        switch ( c ) {
        case '"':  fputs( "\\\"", out ); break;
        case '\\': fputs( "\\\\", out ); break;
        case '\n': fputs( "\\n",  out ); break;
        case '\r': fputs( "\\r",  out ); break;
        case '\t': fputs( "\\t",  out ); break;
        default:
            if ( c < 32 || c == 127 ) fprintf( out, "\\%u", ( unsigned )c );
            else                       fputc( ( int )c, out );
        }
    }
    if ( cap < n ) fputs( "...", out );
    fputc( '"', out );
}

/* Print one KV entry, e.g. `K[3] = int 42` or `K[0] = string "hello"`. */
static void DumpConstant( FILE *out, int depth, int idx, const TValue *k ) {
    PrintIndent( out, depth );
    fprintf( out, "K[%d] = %s", idx, ConstTypeName( k ) );
    switch ( ttypetag( k ) ) {
    case LUA_VNUMINT:
        fprintf( out, " %lld", ( long long )ivalue( k ) );
        break;
    case LUA_VNUMFLT:
        fprintf( out, " %.14g", ( double )fltvalue( k ) );
        break;
    case LUA_VSHRSTR:
    case LUA_VLNGSTR:
        fputc( ' ', out );
        PrintStringLit( out, tsvalue( k ) );
        break;
    default:
        break;
    }
    fputc( '\n', out );
}

static void DumpUpvalue( FILE *out, int depth, int idx, const Upvaldesc *u ) {
    const char *name = ( u->name != NULL ) ? getstr( u->name ) : "?";
    PrintIndent( out, depth );
    fprintf( out, "upvalue[%d] = %s (%s slot %d)\n",
             idx, name,
             u->instack ? "instack" : "outer",
             ( int )u->idx );
}

static void DumpLocVar( FILE *out, int depth, int idx, const LocVar *v ) {
    const char *name = ( v->varname != NULL ) ? getstr( v->varname ) : "?";
    PrintIndent( out, depth );
    fprintf( out, "local[%d] = %s (pc %d..%d)\n",
             idx, name, v->startpc, v->endpc );
}

/* Depth-first walk mirroring driver/main.c CollectReachable: entry first,
** then p[] children recursively. `depth` controls indent. */
static int DumpProto( FILE *out, const Proto *p, int depth ) {
    const char *src = ( p->source != NULL ) ? getstr( p->source ) : "?";
    int i;

    PrintIndent( out, depth );
    fprintf( out,
        "Function[%d..%d] source=%s params=%d vararg=%d stack=%d "
        "code=%d upvals=%d consts=%d locals=%d children=%d\n",
        p->linedefined, p->lastlinedefined, src,
        ( int )p->numparams, ( int )p->is_vararg,
        ( int )p->maxstacksize, p->sizecode,
        p->sizeupvalues, p->sizek, p->sizelocvars, p->sizep );

    for ( i = 0; i < p->sizeupvalues; i++ ) {
        DumpUpvalue( out, depth + 1, i, &p->upvalues[ i ] );
    }
    for ( i = 0; i < p->sizelocvars; i++ ) {
        DumpLocVar( out, depth + 1, i, &p->locvars[ i ] );
    }
    for ( i = 0; i < p->sizek; i++ ) {
        DumpConstant( out, depth + 1, i, &p->k[ i ] );
    }
    for ( i = 0; i < p->sizep; i++ ) {
        if ( p->p[ i ] != NULL ) {
            if ( !DumpProto( out, p->p[ i ], depth + 1 ) ) return 0;
        }
    }
    return 1;
}

int Lc_DumpAst( FILE *out, struct Proto *root ) {
    if ( out == NULL || root == NULL ) return 0;
    fputs( "; ast dump (Lua 5.4 Proto tree)\n", out );
    return DumpProto( out, root, 0 );
}
