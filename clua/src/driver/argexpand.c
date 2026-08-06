/*
** argexpand.c -- @response-file support for the CLua drivers.
**
** See argexpand.h. Not part of lc_drive itself: the driver receives an
** already-expanded argv, so nothing downstream needs to know a response
** file was in play. Kept as its own translation unit so both main.c
** (aotc.exe) and clua_main.c (clua.exe) can call it without duplicating
** the tokenizer.
*/
#include "argexpand.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Grow a pointer array by one, pushing `s` at the tail. Ownership of `s`
** transfers into the array. Returns 0 on OOM, 1 on success. */
static int push( char ***v, int *n, int *cap, char *s ) {
    if ( *n == *cap ) {
        int    nc = ( *cap == 0 ) ? 8 : ( *cap * 2 );
        char **nv = ( char ** )realloc( *v, ( size_t )nc * sizeof( char * ) );
        if ( nv == NULL ) { free( s ); return 0; }
        *v = nv;
        *cap = nc;
    }
    ( *v )[ ( *n )++ ] = s;
    return 1;
}

/* Tokenize `text` (an in-memory copy of the response file) into `*out_v`.
** Whitespace separates tokens. Both `"..."` and `'...'` protect embedded
** whitespace; the surrounding quote is stripped. Backslash inside a quoted
** span escapes the quote char and the backslash itself. Windows CR/LF is
** treated as whitespace exactly like a space. */
static int tokenize( const char *text, char ***out_v, int *out_n ) {
    char **v = NULL;
    int    n = 0, cap = 0;
    size_t i = 0;

    while ( text[ i ] != '\0' ) {
        char *tok;
        size_t start, len, j;
        /* skip whitespace */
        while ( text[ i ] != '\0' &&
                ( unsigned char )text[ i ] <= ' ' ) i++;
        if ( text[ i ] == '\0' ) break;
        /* Line comment starting with # anywhere at token start; skip to EOL. */
        if ( text[ i ] == '#' ) {
            while ( text[ i ] != '\0' && text[ i ] != '\n' ) i++;
            continue;
        }
        /* Quoted or bare token. */
        if ( text[ i ] == '"' || text[ i ] == '\'' ) {
            char q = text[ i++ ];
            start = i;
            while ( text[ i ] != '\0' && text[ i ] != q ) {
                if ( text[ i ] == '\\' && text[ i + 1 ] != '\0' ) i++;
                i++;
            }
            len = i - start;
            tok = ( char * )malloc( len + 1 );
            if ( tok == NULL ) { free( v ); return 0; }
            /* copy with escape handling */
            j = 0;
            {
                size_t p;
                for ( p = start; p < start + len; p++ ) {
                    if ( text[ p ] == '\\' &&
                         ( text[ p + 1 ] == q || text[ p + 1 ] == '\\' ) ) {
                        p++;
                    }
                    tok[ j++ ] = text[ p ];
                }
            }
            tok[ j ] = '\0';
            if ( text[ i ] == q ) i++;    /* consume closing quote */
        } else {
            start = i;
            while ( text[ i ] != '\0' &&
                    ( unsigned char )text[ i ] > ' ' ) i++;
            len = i - start;
            tok = ( char * )malloc( len + 1 );
            if ( tok == NULL ) { free( v ); return 0; }
            memcpy( tok, text + start, len );
            tok[ len ] = '\0';
        }
        if ( !push( &v, &n, &cap, tok ) ) return 0;
    }
    *out_v = v;
    *out_n = n;
    return 1;
}

/* Read the whole file at `path` into a heap buffer (nul-terminated).
** Returns NULL on any I/O error. Bounded at 1 MB to guard against a
** hostile response file. */
static char *slurp( const char *path ) {
    FILE  *f = fopen( path, "rb" );
    char  *buf;
    long   sz;
    size_t got;
    if ( f == NULL ) return NULL;
    if ( fseek( f, 0, SEEK_END ) != 0 ) { fclose( f ); return NULL; }
    sz = ftell( f );
    if ( sz < 0 || sz > ( 1L << 20 ) ) { fclose( f ); return NULL; }
    if ( fseek( f, 0, SEEK_SET ) != 0 ) { fclose( f ); return NULL; }
    buf = ( char * )malloc( ( size_t )sz + 1 );
    if ( buf == NULL ) { fclose( f ); return NULL; }
    got = fread( buf, 1, ( size_t )sz, f );
    fclose( f );
    buf[ got ] = '\0';
    return buf;
}

char **LcArg_Expand( int argc, char **argv, int *out_argc ) {
    char **out = NULL;
    int    n = 0, cap = 0;
    int    i, k;

    if ( out_argc == NULL ) return NULL;
    *out_argc = 0;

    for ( i = 0; i < argc; i++ ) {
        char *arg = argv[ i ];
        if ( arg == NULL ) continue;
        if ( arg[ 0 ] == '@' && arg[ 1 ] != '\0' ) {
            /* response file: read + tokenize + splice */
            char  *text = slurp( arg + 1 );
            char **toks = NULL;
            int    ntoks = 0;
            if ( text == NULL ) {
                fprintf( stderr,
                         "clua: cannot read response file '%s'\n", arg + 1 );
                LcArg_FreeExpanded( n, out );
                return NULL;
            }
            if ( !tokenize( text, &toks, &ntoks ) ) {
                fprintf( stderr, "clua: response file '%s' parse failed\n",
                         arg + 1 );
                free( text );
                LcArg_FreeExpanded( n, out );
                return NULL;
            }
            free( text );
            for ( k = 0; k < ntoks; k++ ) {
                if ( !push( &out, &n, &cap, toks[ k ] ) ) {
                    /* free remaining unmoved tokens */
                    int r;
                    for ( r = k + 1; r < ntoks; r++ ) free( toks[ r ] );
                    free( toks );
                    LcArg_FreeExpanded( n, out );
                    return NULL;
                }
            }
            free( toks );
        } else {
            /* verbatim copy (heap-owned so caller frees uniformly) */
            char *dup = _strdup( arg );
            if ( dup == NULL || !push( &out, &n, &cap, dup ) ) {
                LcArg_FreeExpanded( n, out );
                return NULL;
            }
        }
    }
    *out_argc = n;
    return out;
}

void LcArg_FreeExpanded( int argc, char **argv ) {
    int i;
    if ( argv == NULL ) return;
    for ( i = 0; i < argc; i++ ) free( argv[ i ] );
    free( argv );
}
