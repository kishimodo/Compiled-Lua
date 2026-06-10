/*
** protoinit_emit.c — the ProtoInit C-emitter for LuaC (AOT fork).
**
** AOT-compiled function bodies (luac_fn_<i>, genuine native code in .text)
** recover their constants at runtime from a live Proto (ci->func -> closure ->
** Proto -> k[]). Because LuaC ships NO bytecode blob, each Proto's
** constants/upvalues/nested-protos (NOT its executable bytecode) must be
** reconstructed at program startup. This file generates the C that does that:
**
**   - one `static Proto *ProtoInit_<i>(lua_State*)` per reachable function that
**     builds the Proto, fills k[]/upvalues[]/p[] from the compile-time Proto,
**     installs a one-instruction RETURN0 safety-net `code` (never executed; it
**     exists only because luaD_precall sets savedpc = P->code, so code must be
**     non-NULL), and registers the native body via Jit_RegisterCompiled.
**   - `Proto *LuacProgram_BuildEntry(lua_State*)` which runs every ProtoInit_<i>
**     and returns the entry Proto.
**
** The function bodies themselves are real codegen (Task 11). Only this
** constructor glue is generated C — an accepted M0 simplification.
*/
#include "codegen/protoinit_emit.h"

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lobject.h"
#include "lstate.h"   /* gco2ts() used by the tsvalue() accessor macro */

/* This emitter READS the compile-time Proto's constants/upvalues via the Lua
** accessor macros (tsvalue/ivalue/fltvalue/getstr/tsslen/...). The GENERATED
** file (not this one) is what needs lstring.h/lfunc.h/lmem.h/lopcodes.h to
** BUILD a Proto at runtime — those are emitted into its preamble. */

static void emit_err( char *err, size_t errlen, const char *fmt, ... ) {
    if ( err == NULL || errlen == 0 ) return;
    va_list ap;
    va_start( ap, fmt );
    vsnprintf( err, errlen, fmt, ap );
    va_end( ap );
}

/* Emit a C byte-array literal for `n` bytes of `s`:  { 0x70,0x72,... } */
static void emit_byte_array( FILE *f, const char *s, size_t n ) {
    size_t i;
    fputc( '{', f );
    for ( i = 0; i < n; i++ ) {
        fprintf( f, "%s0x%02x", ( i ? "," : "" ), ( unsigned char )s[i] );
    }
    /* A C array initializer must be non-empty; for the n==0 case we still emit
    ** a single 0 so the declaration is valid (length passed separately is 0). */
    if ( n == 0 ) fputc( '0', f );
    fputc( '}', f );
}

/* Print a double as a C source literal that round-trips and is unambiguously a
** floating-point token (so it parses as `double`, not `int`). */
static void emit_double_literal( FILE *f, double d ) {
    char buf[64];
    snprintf( buf, sizeof( buf ), "%.17g", d );
    /* If the rendered token has no '.', 'e'/'E', 'n'(nan)/'i'(inf), append ".0"
    ** so the C compiler treats it as a double constant. */
    if ( strpbrk( buf, ".eEnNiI" ) == NULL ) {
        fprintf( f, "%s.0", buf );
    } else {
        fputs( buf, f );
    }
}

/* Map a nested-proto child pointer back to its index in m->funcs (so the parent
** can call ProtoInit_<child>). Returns -1 if not found. */
static int proto_index( LcModule *m, Proto *p ) {
    uint32_t i;
    for ( i = 0; i < m->nfuncs; i++ ) {
        if ( m->funcs[i] != NULL && m->funcs[i]->source == p ) return ( int )i;
    }
    return -1;
}

/* Emit one constant setter for P->k[j] into the generated function body. */
static int emit_const( FILE *f, Proto *P, int j, char *err, size_t errlen ) {
    const TValue *o = &P->k[j];

    if ( ttisstring( o ) ) {
        TString    *ts  = tsvalue( o );
        const char *s   = getstr( ts );
        size_t      len = ( size_t )tsslen( ts );
        fprintf( f, "    { static const char b[] = " );
        emit_byte_array( f, s, len );
        fprintf( f, "; setsvalue( L, &P->k[%d], luaS_newlstr( L, b, %zu ) ); }\n",
                 j, len );
        return 1;
    }
    if ( ttisinteger( o ) ) {
        /* LUAI_UACINT is the format-able widening of lua_Integer; print as a
        ** long long so the literal width is unambiguous. */
        fprintf( f, "    setivalue( &P->k[%d], (lua_Integer)%lldLL );\n",
                 j, ( long long )ivalue( o ) );
        return 1;
    }
    if ( ttisfloat( o ) ) {
        fprintf( f, "    setfltvalue( &P->k[%d], (lua_Number)", j );
        emit_double_literal( f, ( double )fltvalue( o ) );
        fprintf( f, " );\n" );
        return 1;
    }
    if ( ttisboolean( o ) ) {
        if ( ttistrue( o ) )
            fprintf( f, "    setbtvalue( &P->k[%d] );\n", j );
        else
            fprintf( f, "    setbfvalue( &P->k[%d] );\n", j );
        return 1;
    }
    if ( ttisnil( o ) ) {
        fprintf( f, "    setnilvalue( &P->k[%d] );\n", j );
        return 1;
    }

    emit_err( err, errlen,
              "ProtoInit emit: unsupported constant type (tag=%d) at k[%d] of "
              "function with Proto %p", ( int )ttypetag( o ), j, ( void * )P );
    return 0;
}

/* Emit a single ProtoInit_<idx> function. */
static int emit_protoinit( FILE *f, LcModule *m, int idx, char *err,
                           size_t errlen ) {
    Proto *P = m->funcs[idx]->source;
    int    j, u, c;

    if ( P == NULL ) {
        emit_err( err, errlen,
                  "ProtoInit emit: function %d has no source Proto", idx );
        return 0;
    }

    fprintf( f, "static Proto *ProtoInit_%d( lua_State *L ) {\n", idx );
    fprintf( f, "    Proto *P = luaF_newproto( L );\n" );
    fprintf( f, "    P->numparams = %u; P->is_vararg = %u; P->maxstacksize = %u;\n",
             ( unsigned )P->numparams, ( unsigned )P->is_vararg,
             ( unsigned )P->maxstacksize );

    /* ---- constants ---- */
    fprintf( f, "    P->sizek = %d;\n", P->sizek );
    if ( P->sizek > 0 ) {
        fprintf( f, "    P->k = luaM_newvector( L, %d, TValue );\n", P->sizek );
        for ( j = 0; j < P->sizek; j++ ) {
            if ( !emit_const( f, P, j, err, errlen ) ) return 0;
        }
    }

    /* ---- upvalues (copied verbatim from the compile-time Proto) ---- */
    fprintf( f, "    P->sizeupvalues = %d;\n", P->sizeupvalues );
    if ( P->sizeupvalues > 0 ) {
        fprintf( f, "    P->upvalues = luaM_newvector( L, %d, Upvaldesc );\n",
                 P->sizeupvalues );
        for ( u = 0; u < P->sizeupvalues; u++ ) {
            Upvaldesc *uv = &P->upvalues[u];
            fprintf( f,
                     "    P->upvalues[%d].instack = %u; "
                     "P->upvalues[%d].idx = %u; P->upvalues[%d].kind = %u;\n",
                     u, ( unsigned )uv->instack, u, ( unsigned )uv->idx, u,
                     ( unsigned )uv->kind );
            if ( uv->name != NULL ) {
                const char *s   = getstr( uv->name );
                size_t      len = ( size_t )tsslen( uv->name );
                fprintf( f, "    { static const char b[] = " );
                emit_byte_array( f, s, len );
                fprintf( f,
                         "; P->upvalues[%d].name = luaS_newlstr( L, b, %zu ); }\n",
                         u, len );
            } else {
                fprintf( f, "    P->upvalues[%d].name = NULL;\n", u );
            }
        }
    }

    /* ---- nested protos ---- */
    fprintf( f, "    P->sizep = %d;\n", P->sizep );
    if ( P->sizep > 0 ) {
        fprintf( f, "    P->p = luaM_newvector( L, %d, Proto * );\n", P->sizep );
        for ( c = 0; c < P->sizep; c++ ) {
            int ci = proto_index( m, P->p[c] );
            if ( ci < 0 ) {
                emit_err( err, errlen,
                          "ProtoInit emit: nested Proto p[%d] of function %d is "
                          "not present in the module (lifting must include all "
                          "reachable nested functions)",
                          c, idx );
                return 0;
            }
            fprintf( f, "    P->p[%d] = ProtoInit_%d( L );\n", c, ci );
        }
    }

    /* ---- code safety-net ----
    ** The registered native body is dispatched at function entry, so this is
    ** never executed; but luaD_precall sets ci->savedpc = P->code, so code must
    ** be non-NULL. A single OP_RETURN0 is a valid, harmless instruction. */
    fprintf( f, "    P->sizecode = 1;\n" );
    fprintf( f, "    P->code = luaM_newvector( L, 1, Instruction );\n" );
    fprintf( f, "    P->code[0] = CREATE_ABCk( OP_RETURN0, 0, 1, 0, 0 );\n" );

    /* ---- register the AOT body ---- */
    fprintf( f, "    { extern int luac_fn_%d( lua_State * ); "
                "Jit_RegisterCompiled( P, luac_fn_%d ); }\n",
             idx, idx );

    fprintf( f, "    return P;\n" );
    fprintf( f, "}\n\n" );
    return 1;
}

int LcEmitProtoInitC( const char *path, LcModule *m, char *err, size_t errlen ) {
    FILE    *f;
    uint32_t i;
    int      entry_idx = -1;

    if ( err && errlen ) err[0] = '\0';

    if ( path == NULL || m == NULL ) {
        emit_err( err, errlen, "ProtoInit emit: NULL path or module" );
        return 0;
    }
    if ( m->nfuncs == 0 ) {
        emit_err( err, errlen, "ProtoInit emit: module has no functions" );
        return 0;
    }

    /* Locate the entry index up front (also validates m->entry is in funcs). */
    for ( i = 0; i < m->nfuncs; i++ ) {
        if ( m->funcs[i] == m->entry ) {
            entry_idx = ( int )i;
            break;
        }
    }
    if ( entry_idx < 0 ) {
        emit_err( err, errlen,
                  "ProtoInit emit: module entry is not among m->funcs" );
        return 0;
    }

    f = fopen( path, "w" );
    if ( f == NULL ) {
        emit_err( err, errlen, "ProtoInit emit: cannot open '%s' for writing",
                  path );
        return 0;
    }

    /* ---- file preamble: includes the generated constructors need ---- */
    fprintf( f, "/* GENERATED by LcEmitProtoInitC — do not edit. */\n" );
    fprintf( f, "#include \"lua.h\"\n" );
    fprintf( f, "#include \"lobject.h\"\n" );
    fprintf( f, "#include \"lstate.h\"\n" );
    fprintf( f, "#include \"lstring.h\"\n" );
    fprintf( f, "#include \"lfunc.h\"\n" );
    fprintf( f, "#include \"lmem.h\"\n" );
    fprintf( f, "#include \"lopcodes.h\"\n" );
    fprintf( f, "#include \"jit/dispatch.h\"\n\n" );

    /* ---- forward declarations ----
    ** A parent ProtoInit builds its nested children recursively
    ** (P->p[c] = ProtoInit_<child>(L)), and a child's index may be HIGHER than
    ** the parent's (lifting order is not parent-before-child). Forward-declare
    ** every ProtoInit_<i> so those recursive calls resolve regardless of order. */
    for ( i = 0; i < m->nfuncs; i++ ) {
        fprintf( f, "static Proto *ProtoInit_%u( lua_State *L );\n", i );
    }
    fprintf( f, "\n" );

    /* ---- one ProtoInit_<i> per reachable function ---- */
    for ( i = 0; i < m->nfuncs; i++ ) {
        if ( !emit_protoinit( f, m, ( int )i, err, errlen ) ) {
            fclose( f );
            return 0;
        }
    }

    /* ---- LuacProgram_BuildEntry (C3 fix) ----
    ** Each ProtoInit_<i> already builds its nested children recursively
    ** (P->p[c] = ProtoInit_<child>(L)). So BuildEntry must call ProtoInit_<i>
    ** ONLY for top-level ROOTS — Protos that do not appear in any other
    ** reachable Proto's p[] — otherwise a nested child is built twice (two
    ** Proto objects, two Jit_RegisterCompiled cache slots; the standalone dup
    ** is unanchored and its registration shadows/duplicates the real one).
    **
    ** Compute the root set here: mark every Proto reachable as a child of some
    ** parent's p[] as `nested`; the rest are roots. The roots include the entry
    ** (the program main chunk) and any independently-required module main chunks
    ** (which are not nested under any other Proto). Build each root once. */
    {
        char    *nested = ( char * )calloc( m->nfuncs, 1 );
        uint32_t j;
        if ( nested == NULL ) {
            emit_err( err, errlen,
                      "ProtoInit emit: out of memory computing root set" );
            fclose( f );
            return 0;
        }
        /* Mark every Proto that is a nested child of another module function. */
        for ( j = 0; j < m->nfuncs; j++ ) {
            Proto *P;
            int    c;
            if ( m->funcs[j] == NULL || m->funcs[j]->source == NULL ) continue;
            P = m->funcs[j]->source;
            for ( c = 0; c < P->sizep; c++ ) {
                int ci = proto_index( m, P->p[c] );
                if ( ci >= 0 ) nested[ ci ] = 1;
            }
        }

        fprintf( f, "Proto *LuacProgram_BuildEntry( lua_State *L ) {\n" );
        fprintf( f, "    Proto *entry = NULL;\n" );
        for ( i = 0; i < m->nfuncs; i++ ) {
            if ( nested[ i ] ) continue;   /* built recursively by its parent */
            fprintf( f, "    Proto *p%u = ProtoInit_%u( L );\n", i, i );
            if ( ( int )i == entry_idx ) {
                fprintf( f, "    entry = p%u;\n", i );
            } else {
                fprintf( f, "    (void)p%u;\n", i );
            }
        }
        free( nested );
        fprintf( f, "    return entry;\n" );
        fprintf( f, "}\n" );
    }

    if ( ferror( f ) ) {
        emit_err( err, errlen, "ProtoInit emit: write error on '%s'", path );
        fclose( f );
        return 0;
    }
    if ( fclose( f ) != 0 ) {
        emit_err( err, errlen, "ProtoInit emit: close failed on '%s'", path );
        return 0;
    }
    return 1;
}
