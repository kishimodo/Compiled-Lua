/*
** compdb.c -- compile_commands.json emitter (see compdb.h for the schema
** contract and why it exists).
**
** Schema written per entry:
**   { "directory": "<CWD>",
**     "file":      "<input>",
**     "arguments": ["<argv[0]>", "<argv[1]>", ...] }
**
** This is the "arguments" form (list of tokens) rather than "command" (single
** shell string). It's what clang tooling prefers because it sidesteps every
** shell-quoting ambiguity on Windows, where paths carry backslashes and are
** allergic to naive shell splitting. clangd, VS Code and ccls all accept it.
**
** JSON escaping is done inline because the driver has no JSON library and
** pulling one in would be gratuitous: the only strings ever escaped here are
** filesystem paths and argv tokens.  We escape the two mandatory
** metacharacters (`"` and `\`), forward slash is passed through, and every
** control char below 0x20 is escaped using the \uXXXX form (JSON does not
** allow raw controls in strings; \b/\f/\n/\r/\t use their short forms).
**
** APPEND MODE
** -----------
** The specification says: "If the file exists and is a valid JSON array,
** parse it, append the new entry, rewrite. If it doesn't exist, treat as
** empty array." We take the lightest correct interpretation: read the file,
** locate the array brackets, splice the new entry in front of the closing
** bracket. This preserves whatever formatting the file already had (a build
** system that curates a manually-tweaked file keeps its layout) while still
** producing a syntactically valid document. If the file exists but doesn't
** parse as a bracketed array (missing `[` or `]`, or an object at top level),
** we fall back to the empty-array behaviour with a stderr note so the caller
** notices they clobbered a hand-edited file.
*/
#include "compdb.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Growable char buffer. Kept intentionally small: the driver only holds one
** buffer at a time and the size is bounded by argv + one .json file. */
typedef struct {
    char  *data;
    size_t len;
    size_t cap;
    int    oom;
} CdBuf;

static void cd_free( CdBuf *b ) { free( b->data ); b->data = NULL; b->len = b->cap = 0; }

static int cd_reserve( CdBuf *b, size_t extra ) {
    if ( b->oom ) return 0;
    size_t need = b->len + extra + 1;
    if ( need <= b->cap ) return 1;
    size_t nc = b->cap ? b->cap : 128;
    while ( nc < need ) nc *= 2;
    char *nd = ( char * )realloc( b->data, nc );
    if ( nd == NULL ) { b->oom = 1; return 0; }
    b->data = nd; b->cap = nc;
    return 1;
}

static int cd_putc( CdBuf *b, char c ) {
    if ( !cd_reserve( b, 1 ) ) return 0;
    b->data[ b->len++ ] = c;
    b->data[ b->len ]   = '\0';
    return 1;
}

static int cd_puts( CdBuf *b, const char *s ) {
    size_t n = strlen( s );
    if ( !cd_reserve( b, n ) ) return 0;
    memcpy( b->data + b->len, s, n );
    b->len += n;
    b->data[ b->len ] = '\0';
    return 1;
}

static int cd_putn( CdBuf *b, const char *s, size_t n ) {
    if ( !cd_reserve( b, n ) ) return 0;
    memcpy( b->data + b->len, s, n );
    b->len += n;
    b->data[ b->len ] = '\0';
    return 1;
}

/* Emit a JSON string literal, quotes included. Escapes:
**   \"  \\  \b  \f  \n  \r  \t   for the named controls,
**   \uXXXX                       for every other byte < 0x20,
**   raw byte                     for everything else (including UTF-8, which
**                                 is already valid JSON string content).
** Note: forward slash '/' is passed through unescaped; JSON allows escaping
** it but does not require it, and consumers (clangd, VS Code) handle both.
** Windows paths ("C:\\Users\\...") therefore produce doubled backslashes,
** which is the whole point. */
static int cd_json_string( CdBuf *b, const char *s ) {
    if ( !cd_putc( b, '"' ) ) return 0;
    if ( s == NULL ) return cd_putc( b, '"' );
    const unsigned char *p = ( const unsigned char * )s;
    for ( ; *p; p++ ) {
        unsigned char c = *p;
        switch ( c ) {
            case '"':  if ( !cd_puts( b, "\\\"" ) ) return 0; break;
            case '\\': if ( !cd_puts( b, "\\\\" ) ) return 0; break;
            case '\b': if ( !cd_puts( b, "\\b"  ) ) return 0; break;
            case '\f': if ( !cd_puts( b, "\\f"  ) ) return 0; break;
            case '\n': if ( !cd_puts( b, "\\n"  ) ) return 0; break;
            case '\r': if ( !cd_puts( b, "\\r"  ) ) return 0; break;
            case '\t': if ( !cd_puts( b, "\\t"  ) ) return 0; break;
            default:
                if ( c < 0x20 ) {
                    char esc[ 8 ];
                    snprintf( esc, sizeof( esc ), "\\u%04x", ( unsigned )c );
                    if ( !cd_puts( b, esc ) ) return 0;
                } else {
                    if ( !cd_putc( b, ( char )c ) ) return 0;
                }
                break;
        }
    }
    return cd_putc( b, '"' );
}

/* Serialize one entry as a JSON object (no leading/trailing whitespace). */
static int cd_write_entry( CdBuf *b,
                           const char        *cwd,
                           const char        *input,
                           int                argc,
                           const char *const *argv ) {
    if ( !cd_puts( b, "{\n    \"directory\": " ) ) return 0;
    if ( !cd_json_string( b, cwd ? cwd : "" ) ) return 0;
    if ( !cd_puts( b, ",\n    \"file\": " ) ) return 0;
    if ( !cd_json_string( b, input ? input : "" ) ) return 0;
    if ( !cd_puts( b, ",\n    \"arguments\": [" ) ) return 0;
    for ( int i = 0; i < argc; i++ ) {
        if ( i > 0 ) { if ( !cd_puts( b, ", " ) ) return 0; }
        if ( !cd_json_string( b, argv[ i ] ? argv[ i ] : "" ) ) return 0;
    }
    if ( !cd_puts( b, "]\n  }" ) ) return 0;
    return 1;
}

/* Read whole file into a fresh malloc'd buffer. Returns NULL if the file
** cannot be opened; sets *n_out even on the empty-file case. Caller frees. */
static char *slurp( const char *path, size_t *n_out ) {
    FILE *f = fopen( path, "rb" );
    if ( f == NULL ) { *n_out = 0; return NULL; }
    if ( fseek( f, 0, SEEK_END ) != 0 ) { fclose( f ); *n_out = 0; return NULL; }
    long sz = ftell( f );
    if ( sz < 0 ) { fclose( f ); *n_out = 0; return NULL; }
    rewind( f );
    char *buf = ( char * )malloc( ( size_t )sz + 1 );
    if ( buf == NULL ) { fclose( f ); *n_out = 0; return NULL; }
    size_t r = fread( buf, 1, ( size_t )sz, f );
    fclose( f );
    buf[ r ] = '\0';
    *n_out = r;
    return buf;
}

/* Locate the last '[' and the last ']' in `s` at the OUTERMOST level, treating
** JSON string literals correctly so a bracket inside a value doesn't fool us.
** Returns 0 iff the input contains a syntactically bracketed array. */
static int find_array_span( const char *s, size_t n,
                            size_t *open_out, size_t *close_out ) {
    long open_idx  = -1;
    long close_idx = -1;
    int  in_str = 0;
    int  escape = 0;
    for ( size_t i = 0; i < n; i++ ) {
        char c = s[ i ];
        if ( in_str ) {
            if ( escape )      { escape = 0; }
            else if ( c == '\\' ) escape = 1;
            else if ( c == '"' )  in_str = 0;
            continue;
        }
        if ( c == '"' ) { in_str = 1; continue; }
        if ( c == '[' && open_idx < 0 ) open_idx = ( long )i;
        if ( c == ']' ) close_idx = ( long )i;   /* last one wins */
    }
    if ( open_idx < 0 || close_idx < 0 || close_idx < open_idx ) return 0;
    *open_out  = ( size_t )open_idx;
    *close_out = ( size_t )close_idx;
    return 1;
}

/* Return non-zero iff [start, end) is only JSON whitespace. */
static int span_is_blank( const char *s, size_t start, size_t end ) {
    for ( size_t i = start; i < end; i++ ) {
        char c = s[ i ];
        if ( c != ' ' && c != '\t' && c != '\r' && c != '\n' ) return 0;
    }
    return 1;
}

int LcCompdb_Write( const char        *path,
                    int                argc,
                    const char *const *argv,
                    const char        *cwd,
                    const char        *input,
                    int                append ) {
    if ( path == NULL || argc < 0 || ( argc > 0 && argv == NULL ) ) return 1;

    CdBuf out = { 0 };

    /* Existing content, if any, only relevant for append mode. */
    char  *existing = NULL;
    size_t existing_n = 0;
    size_t open_at = 0, close_at = 0;
    int    have_prior_entries = 0;

    if ( append ) {
        existing = slurp( path, &existing_n );
        if ( existing != NULL && existing_n > 0 &&
             find_array_span( existing, existing_n, &open_at, &close_at ) ) {
            /* Locate the end of the last non-blank byte inside the array,
            ** so a trailing comma sits right after the previous entry's
            ** closing brace rather than after whatever whitespace preceded
            ** the `]`. */
            size_t k = close_at;
            while ( k > open_at + 1 ) {
                char c = existing[ k - 1 ];
                if ( c != ' ' && c != '\t' && c != '\r' && c != '\n' ) break;
                k--;
            }
            have_prior_entries = ( k > open_at + 1 );

            /* Head: everything up to and including the `[`, plus the prior
            ** entries verbatim (or nothing if the array was empty). */
            if ( !cd_putn( &out, existing, open_at + 1 ) ) goto oom;
            if ( have_prior_entries ) {
                if ( !cd_putn( &out, existing + open_at + 1,
                               k - ( open_at + 1 ) ) ) goto oom;
                if ( !cd_puts( &out, ",\n  " ) ) goto oom;
            } else {
                if ( !cd_puts( &out, "\n  " ) ) goto oom;
            }
            /* New entry, then the tail from `]` onward. */
            if ( !cd_write_entry( &out, cwd, input, argc, argv ) ) goto oom;
            if ( !cd_puts( &out, "\n" ) ) goto oom;
            if ( !cd_putn( &out, existing + close_at,
                           existing_n - close_at ) ) goto oom;
            /* Ensure the file ends with a newline (may already be there). */
            if ( out.len == 0 || out.data[ out.len - 1 ] != '\n' ) {
                if ( !cd_putc( &out, '\n' ) ) goto oom;
            }
            free( existing );
            existing = NULL;
            goto write_out;
        }
        if ( existing != NULL && existing_n > 0 &&
             !span_is_blank( existing, 0, existing_n ) ) {
            fprintf( stderr,
                     "clua: --emit-compdb-append: '%s' is not a valid JSON "
                     "array; overwriting with a fresh one\n", path );
        }
        free( existing );
        existing = NULL;
    }

    /* Fresh single-entry array (both --emit-compdb and the fallback for
    ** append when the destination is missing / empty / malformed). */
    if ( !cd_puts( &out, "[\n  " ) ) goto oom;
    if ( !cd_write_entry( &out, cwd, input, argc, argv ) ) goto oom;
    if ( !cd_puts( &out, "\n]\n" ) ) goto oom;

write_out:
    if ( out.oom ) goto oom;
    {
        FILE *f = fopen( path, "wb" );
        if ( f == NULL ) {
            fprintf( stderr, "clua: --emit-compdb: cannot write '%s'\n", path );
            cd_free( &out );
            return 1;
        }
        size_t w = fwrite( out.data, 1, out.len, f );
        int    ferr = ( w != out.len );
        if ( fclose( f ) != 0 ) ferr = 1;
        cd_free( &out );
        if ( ferr ) {
            fprintf( stderr, "clua: --emit-compdb: write error on '%s'\n", path );
            return 1;
        }
        return 0;
    }

oom:
    fprintf( stderr, "clua: --emit-compdb: out of memory\n" );
    free( existing );
    cd_free( &out );
    return 1;
}
