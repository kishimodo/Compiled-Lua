/*
** cluatoml.c -- per-project clua.toml loader (F3).
**
** Discovery: walk from a start directory upward, stop at the first `clua.toml`
** found or at a `.git` marker or the filesystem root -- whichever comes first.
** Same rule git itself uses to find `.gitconfig` / `.git/config`. On Windows
** the walk terminates when the parent-directory string stops shrinking (both
** `C:\` and `\\server\share` yield themselves as their own parent).
**
** Parser scope: a hand-written recursive descent over the TOML v1.0 subset
** the F3 schema needs -- tables `[section]`, arrays-of-tables `[[bundle]]`,
** `key = value` for boolean / integer / basic-string / array-of-string. Any
** shape we do not accept is a hard error at parse time so a typo cannot
** silently drop to defaults. Every diagnostic is `clua.toml:line:col`
** flavoured so an editor / CI log stays greppable.
**
** Merge: LcConfig_ApplyToOptions overlays the parsed values on top of an
** LcDriverOptions the caller has zeroed / defaulted, and LcConfig_ApplyEnv
** overlays the CLUA_* env vars on top of THAT. The driver then does its
** argv scan on the merged struct so an explicit CLI flag wins over both.
*/
#include "cluatoml.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../compiler/diag_pretty.h"   /* LC_DIAG_FORMAT_T / COLOR_MODE      */

#ifdef _WIN32
#include <direct.h>   /* _getcwd */
#include <windows.h>  /* GetFileAttributesA -- .git detection                */
#else
#include <unistd.h>
#include <sys/stat.h>
#endif

/* ------------------------------------------------------------------ */
/*  Small string helpers.                                              */
/* ------------------------------------------------------------------ */

static char *xstrdup( const char *s ) {
    size_t n;
    char  *o;
    if ( s == NULL ) return NULL;
    n = strlen( s );
    o = ( char * )malloc( n + 1 );
    if ( o == NULL ) return NULL;
    memcpy( o, s, n + 1 );
    return o;
}

static char *xstrndup( const char *s, size_t n ) {
    char *o = ( char * )malloc( n + 1 );
    if ( o == NULL ) return NULL;
    if ( n > 0 ) memcpy( o, s, n );
    o[ n ] = '\0';
    return o;
}

static bool path_exists( const char *p ) {
#ifdef _WIN32
    DWORD a = GetFileAttributesA( p );
    return a != INVALID_FILE_ATTRIBUTES;
#else
    struct stat st;
    return stat( p, &st ) == 0;
#endif
}

/* ------------------------------------------------------------------ */
/*  LcConfig lifetime.                                                 */
/* ------------------------------------------------------------------ */

void LcConfig_Init( LcConfig *cfg ) {
    if ( cfg != NULL ) memset( cfg, 0, sizeof( *cfg ) );
}

void LcConfig_Free( LcConfig *cfg ) {
    size_t i;
    if ( cfg == NULL ) return;
    for ( i = 0; i < cfg->warn_count; i++ ) free( cfg->warn_names[ i ] );
    free( cfg->warn_names );
    for ( i = 0; i < cfg->bundle_count; i++ ) free( cfg->bundles[ i ] );
    free( cfg->bundles );
    free( cfg->product_name );
    free( cfg->product_version );
    free( cfg->company_name );
    free( cfg->copyright );
    free( cfg->manifest );
    free( cfg->icon );
    free( cfg->target_triple );
    free( cfg->source_path );
    memset( cfg, 0, sizeof( *cfg ) );
}

/* ------------------------------------------------------------------ */
/*  Discovery: walk from CWD upward.                                   */
/* ------------------------------------------------------------------ */

/* Return 1 if `dir/name` names an existing file OR directory. */
static int has_child( const char *dir, const char *name ) {
    char probe[ 1024 ];
    int  n = snprintf( probe, sizeof( probe ), "%s%s%s", dir,
                       ( dir[ 0 ] != '\0' &&
                         dir[ strlen( dir ) - 1 ] != '/' &&
                         dir[ strlen( dir ) - 1 ] != '\\' ) ? "\\" : "",
                       name );
    if ( n <= 0 || ( size_t )n >= sizeof( probe ) ) return 0;
    return path_exists( probe ) ? 1 : 0;
}

/* Compute the parent directory in-place. Returns 1 if a parent was reachable
** (strictly shorter than input), 0 if `dir` is already the root. Recognises
** the Windows drive-letter root `C:\` and UNC roots `\\server\share`. */
static int parent_of( char *dir ) {
    size_t n = strlen( dir );
    size_t stop = 0;
    /* Recognise Windows roots to avoid an infinite loop stripping `C:\`. */
    if ( n >= 3 &&
         ( ( dir[ 1 ] == ':' ) &&
           ( dir[ 2 ] == '\\' || dir[ 2 ] == '/' ) ) ) {
        stop = 3;
    } else if ( n >= 2 && ( dir[ 0 ] == '\\' && dir[ 1 ] == '\\' ) ) {
        /* UNC path: walk down to `\\server\share` and stop there. Count two
        ** path separators after the leading `\\`; keep both. */
        size_t seps = 0, i;
        for ( i = 2; i < n && seps < 2; i++ ) {
            if ( dir[ i ] == '\\' || dir[ i ] == '/' ) seps++;
        }
        if ( seps < 2 ) return 0;
        stop = i;
    } else if ( n >= 1 && ( dir[ 0 ] == '/' || dir[ 0 ] == '\\' ) ) {
        stop = 1;
    }
    if ( n <= stop ) return 0;
    /* Strip a trailing separator, then the final path component. */
    while ( n > stop && ( dir[ n - 1 ] == '\\' || dir[ n - 1 ] == '/' ) ) {
        dir[ --n ] = '\0';
    }
    while ( n > stop && dir[ n - 1 ] != '\\' && dir[ n - 1 ] != '/' ) {
        dir[ --n ] = '\0';
    }
    while ( n > stop && ( dir[ n - 1 ] == '\\' || dir[ n - 1 ] == '/' ) ) {
        dir[ --n ] = '\0';
    }
    if ( n == 0 ) return 0;
    return 1;
}

int LcConfigDiscover( const char *start_dir, char *out_path, size_t out_size ) {
    char dir[ 1024 ] = { 0 };
    if ( out_path == NULL || out_size == 0 ) return 0;
    if ( start_dir != NULL && start_dir[ 0 ] != '\0' ) {
        size_t n = strlen( start_dir );
        if ( n >= sizeof( dir ) ) return 0;
        memcpy( dir, start_dir, n + 1 );
    } else {
#ifdef _WIN32
        if ( _getcwd( dir, ( int )sizeof( dir ) ) == NULL ) return 0;
#else
        if ( getcwd( dir, sizeof( dir ) ) == NULL ) return 0;
#endif
    }

    for ( ;; ) {
        /* Test for the config FIRST so a repo root that has both `.git` and
        ** `clua.toml` still resolves to the config. */
        if ( has_child( dir, "clua.toml" ) ) {
            int n = snprintf( out_path, out_size, "%s%sclua.toml", dir,
                              ( dir[ 0 ] != '\0' &&
                                dir[ strlen( dir ) - 1 ] != '/' &&
                                dir[ strlen( dir ) - 1 ] != '\\' ) ? "\\" : "" );
            if ( n <= 0 || ( size_t )n >= out_size ) return 0;
            return 1;
        }
        if ( has_child( dir, ".git" ) ) return 0;
        if ( !parent_of( dir ) ) return 0;
    }
}

/* ------------------------------------------------------------------ */
/*  Tiny TOML parser.                                                  */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *path;      /* file path shown in diagnostics                */
    const char *buf;
    size_t      len;
    size_t      pos;
    int         line;
    int         col;
    /* `section` is the current [table] header. NULL means the pre-table
    ** top-level. Owned by parser; freed on switch and on parser destroy. */
    char       *section;
    /* Set to non-zero the first time the parser is inside a `[[bundle]]`
    ** array-of-tables item so we can validate keys locally. */
    int         in_bundle_item;
} Parser;

static void diag_at( const Parser *p, int line, int col, const char *fmt,
                     const char *arg ) {
    /* Match the driver's other diagnostics: `<path>:<line>:<col>: error: ...`.
    ** Deliberately not routed through diag_pretty because we do not have the
    ** source-line context loaded and this is a config file, not Lua. */
    fprintf( stderr, "%s:%d:%d: error: ", p->path, line, col );
    if ( arg != NULL ) fprintf( stderr, fmt, arg );
    else               fputs( fmt, stderr );
    fputc( '\n', stderr );
}

static void diag_here( const Parser *p, const char *fmt, const char *arg ) {
    diag_at( p, p->line, p->col, fmt, arg );
}

static int at_eof( const Parser *p ) { return p->pos >= p->len; }

static char peek( const Parser *p, size_t off ) {
    if ( p->pos + off >= p->len ) return '\0';
    return p->buf[ p->pos + off ];
}

/* Advance one byte, tracking line/col. */
static void advance( Parser *p ) {
    if ( p->pos >= p->len ) return;
    if ( p->buf[ p->pos ] == '\n' ) {
        p->line++;
        p->col = 1;
    } else {
        p->col++;
    }
    p->pos++;
}

/* Skip whitespace WITHIN a line (spaces, tabs). Returns nothing. */
static void skip_hspace( Parser *p ) {
    while ( !at_eof( p ) ) {
        char c = p->buf[ p->pos ];
        if ( c == ' ' || c == '\t' ) advance( p );
        else break;
    }
}

/* Skip comments, blank lines, and whitespace. Consumes newlines. */
static void skip_gap( Parser *p ) {
    while ( !at_eof( p ) ) {
        char c = p->buf[ p->pos ];
        if ( c == ' ' || c == '\t' || c == '\r' || c == '\n' ) {
            advance( p );
        } else if ( c == '#' ) {
            while ( !at_eof( p ) && p->buf[ p->pos ] != '\n' ) advance( p );
        } else break;
    }
}

/* If a line ends with `# comment` or spaces + newline, consume it. Returns 1
** if the line ended cleanly, 0 if some non-whitespace non-comment garbage
** followed (caller reports). */
static int skip_line_tail( Parser *p ) {
    skip_hspace( p );
    if ( at_eof( p ) ) return 1;
    if ( p->buf[ p->pos ] == '#' ) {
        while ( !at_eof( p ) && p->buf[ p->pos ] != '\n' ) advance( p );
    }
    if ( at_eof( p ) ) return 1;
    if ( p->buf[ p->pos ] == '\r' ) advance( p );
    if ( at_eof( p ) ) return 1;
    if ( p->buf[ p->pos ] == '\n' ) { advance( p ); return 1; }
    return 0;
}

/* Parse a bare identifier: [A-Za-z0-9_-]+. Returned string is heap-owned.
** Position advances past it. NULL on empty match (caller reports). */
static char *parse_bare_key( Parser *p ) {
    size_t start = p->pos;
    while ( !at_eof( p ) ) {
        unsigned char c = ( unsigned char )p->buf[ p->pos ];
        if ( ( c >= 'A' && c <= 'Z' ) || ( c >= 'a' && c <= 'z' ) ||
             ( c >= '0' && c <= '9' ) || c == '_' || c == '-' ) {
            advance( p );
        } else break;
    }
    if ( p->pos == start ) return NULL;
    return xstrndup( p->buf + start, p->pos - start );
}

/* Parse a basic string ("..."), advancing past both quotes. Handles a small
** escape subset (\n \t \r \\ \" \0). Returns heap-owned bytes on success. On
** error prints a diagnostic and returns NULL. */
static char *parse_basic_string( Parser *p ) {
    int   start_line = p->line, start_col = p->col;
    char *out = NULL;
    size_t cap = 32, len = 0;

    if ( at_eof( p ) || p->buf[ p->pos ] != '"' ) {
        diag_here( p, "expected \" to open string", NULL );
        return NULL;
    }
    advance( p );   /* consume opening " */
    out = ( char * )malloc( cap );
    if ( out == NULL ) return NULL;

    while ( !at_eof( p ) ) {
        char c = p->buf[ p->pos ];
        if ( c == '"' ) {
            advance( p );
            if ( len + 1 > cap ) {
                cap = len + 1;
                out = ( char * )realloc( out, cap );
                if ( out == NULL ) return NULL;
            }
            out[ len ] = '\0';
            return out;
        }
        if ( c == '\n' ) {
            diag_at( p, start_line, start_col,
                     "unterminated string literal", NULL );
            free( out );
            return NULL;
        }
        if ( c == '\\' ) {
            char esc;
            advance( p );
            if ( at_eof( p ) ) {
                diag_at( p, start_line, start_col,
                         "unterminated string literal (dangling backslash)",
                         NULL );
                free( out );
                return NULL;
            }
            esc = p->buf[ p->pos ];
            switch ( esc ) {
                case 'n':  c = '\n'; break;
                case 't':  c = '\t'; break;
                case 'r':  c = '\r'; break;
                case '\\': c = '\\'; break;
                case '"':  c = '"';  break;
                case '0':  c = '\0'; break;
                default:
                    diag_here( p, "unknown string escape '\\%c'",
                               ( const char[]){ esc, '\0' } );
                    free( out );
                    return NULL;
            }
            advance( p );
        } else {
            advance( p );
        }
        if ( len + 2 > cap ) {
            cap *= 2;
            out = ( char * )realloc( out, cap );
            if ( out == NULL ) return NULL;
        }
        out[ len++ ] = c;
    }
    diag_at( p, start_line, start_col, "unterminated string literal", NULL );
    free( out );
    return NULL;
}

/* Parse an integer literal (with optional +/-). Returns 1 on success and
** writes to *out; 0 on error (with a diagnostic already printed). */
static int parse_integer( Parser *p, long long *out ) {
    int    line = p->line, col = p->col;
    size_t start = p->pos;
    int    sign  = 1;
    long long acc = 0;
    int    any = 0;
    if ( !at_eof( p ) && ( p->buf[ p->pos ] == '-' ||
                            p->buf[ p->pos ] == '+' ) ) {
        if ( p->buf[ p->pos ] == '-' ) sign = -1;
        advance( p );
    }
    while ( !at_eof( p ) ) {
        char c = p->buf[ p->pos ];
        if ( c < '0' || c > '9' ) break;
        acc = acc * 10 + ( c - '0' );
        any = 1;
        advance( p );
    }
    if ( !any ) {
        diag_at( p, line, col, "expected integer literal", NULL );
        p->pos = start;
        return 0;
    }
    *out = acc * sign;
    return 1;
}

/* Parse a bare boolean word `true` / `false` (lower-case). Returns 1 on
** match with *out set. */
static int parse_bool( Parser *p, int *out ) {
    if ( p->pos + 4 <= p->len && memcmp( p->buf + p->pos, "true", 4 ) == 0 ) {
        int i;
        char after = ( p->pos + 4 < p->len ) ? p->buf[ p->pos + 4 ] : '\0';
        if ( after == '\0' || after == ' ' || after == '\t' || after == '\r' ||
             after == '\n' || after == '#' ) {
            for ( i = 0; i < 4; i++ ) advance( p );
            *out = 1;
            return 1;
        }
    }
    if ( p->pos + 5 <= p->len && memcmp( p->buf + p->pos, "false", 5 ) == 0 ) {
        int i;
        char after = ( p->pos + 5 < p->len ) ? p->buf[ p->pos + 5 ] : '\0';
        if ( after == '\0' || after == ' ' || after == '\t' || after == '\r' ||
             after == '\n' || after == '#' ) {
            for ( i = 0; i < 5; i++ ) advance( p );
            *out = 0;
            return 1;
        }
    }
    return 0;
}

/* Parse `[ "a", "b" ]`. Returns 1 on success and appends every string to
** (*out_arr, *out_count) which the caller must free. Trailing commas allowed. */
static int parse_string_array( Parser *p, char ***out_arr, size_t *out_count ) {
    char  **arr = *out_arr;
    size_t  n   = *out_count;
    size_t  cap = *out_count;
    int     line = p->line, col = p->col;
    if ( at_eof( p ) || p->buf[ p->pos ] != '[' ) {
        diag_here( p, "expected '['", NULL );
        return 0;
    }
    advance( p );
    for ( ;; ) {
        skip_gap( p );
        if ( at_eof( p ) ) {
            diag_at( p, line, col, "unterminated array literal", NULL );
            return 0;
        }
        if ( p->buf[ p->pos ] == ']' ) {
            advance( p );
            *out_arr   = arr;
            *out_count = n;
            return 1;
        }
        if ( p->buf[ p->pos ] != '"' ) {
            diag_here( p,
                       "only quoted strings allowed in this array (got '%c')",
                       ( const char[]){ p->buf[ p->pos ], '\0' } );
            return 0;
        }
        {
            char *s = parse_basic_string( p );
            if ( s == NULL ) return 0;
            if ( n == cap ) {
                size_t nc = cap ? cap * 2 : 4;
                char **na = ( char ** )realloc( arr, nc * sizeof( char * ) );
                if ( na == NULL ) { free( s ); return 0; }
                arr = na;
                cap = nc;
            }
            arr[ n++ ] = s;
        }
        skip_gap( p );
        if ( at_eof( p ) ) {
            diag_at( p, line, col, "unterminated array literal", NULL );
            return 0;
        }
        if ( p->buf[ p->pos ] == ',' ) { advance( p ); continue; }
        if ( p->buf[ p->pos ] == ']' ) { advance( p ); break; }
        diag_here( p, "expected ',' or ']' in array", NULL );
        return 0;
    }
    *out_arr   = arr;
    *out_count = n;
    return 1;
}

/* ------------------------------------------------------------------ */
/*  Section / key dispatch.                                            */
/* ------------------------------------------------------------------ */

static int enum_opt_level( const char *s, int *out ) {
    if ( s == NULL ) return 0;
    /* Accept "O0", "O1", ..., or plain "0" / "1" / ... . */
    if ( ( s[ 0 ] == 'O' || s[ 0 ] == 'o' ) &&
         s[ 1 ] >= '0' && s[ 1 ] <= '3' && s[ 2 ] == '\0' ) {
        *out = s[ 1 ] - '0'; return 1;
    }
    if ( s[ 0 ] >= '0' && s[ 0 ] <= '3' && s[ 1 ] == '\0' ) {
        *out = s[ 0 ] - '0'; return 1;
    }
    return 0;
}

static int enum_output_kind( const char *s, int *out ) {
    if ( s == NULL ) return 0;
    if ( strcmp( s, "exe" ) == 0 ) { *out = LC_OUTPUT_EXE; return 1; }
    if ( strcmp( s, "dll" ) == 0 ) { *out = LC_OUTPUT_DLL; return 1; }
    if ( strcmp( s, "obj" ) == 0 ) { *out = LC_OUTPUT_OBJ; return 1; }
    if ( strcmp( s, "lib" ) == 0 ) { *out = LC_OUTPUT_LIB; return 1; }
    return 0;
}

static int enum_strip_mode( const char *s, int *out ) {
    if ( s == NULL ) return 0;
    if ( strcmp( s, "none"  ) == 0 ) { *out = LC_STRIP_NONE;  return 1; }
    if ( strcmp( s, "debug" ) == 0 ) { *out = LC_STRIP_DEBUG; return 1; }
    if ( strcmp( s, "all"   ) == 0 ) { *out = LC_STRIP_ALL;   return 1; }
    return 0;
}

static int enum_color_mode( const char *s, int *out ) {
    LC_DIAG_COLOR_MODE_T m;
    if ( !LcDiag_ParseColorMode( s, &m ) ) return 0;
    *out = ( int )m;
    return 1;
}

static int enum_diag_format( const char *s, int *out ) {
    LC_DIAG_FORMAT_T f;
    if ( !LcDiag_ParseFormat( s, &f ) ) return 0;
    *out = ( int )f;
    return 1;
}

/* Dispatch a `key = value` inside `[build]`. Returns 1 on success, 0 on error. */
static int apply_build_key( Parser *p, LcConfig *cfg, const char *k,
                            int val_line, int val_col ) {
    if ( strcmp( k, "optimization" ) == 0 ) {
        char *s = parse_basic_string( p );
        int   n;
        if ( s == NULL ) return 0;
        if ( !enum_opt_level( s, &n ) ) {
            diag_at( p, val_line, val_col,
                     "expected \"O0\"..\"O3\" for optimization, got \"%s\"", s );
            free( s );
            return 0;
        }
        free( s );
        cfg->has_optimization = true;
        cfg->optimization     = n;
        return 1;
    }
    if ( strcmp( k, "output" ) == 0 ) {
        char *s = parse_basic_string( p );
        int   n;
        if ( s == NULL ) return 0;
        if ( !enum_output_kind( s, &n ) ) {
            diag_at( p, val_line, val_col,
                     "expected \"exe\"/\"dll\"/\"obj\"/\"lib\", got \"%s\"", s );
            free( s );
            return 0;
        }
        free( s );
        cfg->has_output   = true;
        cfg->output_kind  = n;
        return 1;
    }
    if ( strcmp( k, "strip" ) == 0 ) {
        char *s = parse_basic_string( p );
        int   n;
        if ( s == NULL ) return 0;
        if ( !enum_strip_mode( s, &n ) ) {
            diag_at( p, val_line, val_col,
                     "expected \"none\"/\"debug\"/\"all\", got \"%s\"", s );
            free( s );
            return 0;
        }
        free( s );
        cfg->has_strip   = true;
        cfg->strip_mode  = n;
        return 1;
    }
    if ( strcmp( k, "jobs" ) == 0 ) {
        long long v;
        if ( !parse_integer( p, &v ) ) return 0;
        if ( v < 0 || v > 1024 ) {
            diag_at( p, val_line, val_col,
                     "jobs must be in 0..1024", NULL );
            return 0;
        }
        cfg->has_jobs = true;
        cfg->jobs     = ( int )v;
        return 1;
    }
    if ( strcmp( k, "debug" ) == 0 || strcmp( k, "cache" ) == 0 ||
         strcmp( k, "shared-rt" ) == 0 ) {
        int b;
        if ( !parse_bool( p, &b ) ) {
            diag_here( p, "expected `true` or `false`", NULL );
            return 0;
        }
        if ( strcmp( k, "debug" ) == 0 ) {
            cfg->has_debug = true; cfg->debug = ( bool )b;
        } else if ( strcmp( k, "cache" ) == 0 ) {
            cfg->has_cache = true; cfg->cache = ( bool )b;
        } else {
            cfg->has_shared_rt = true; cfg->shared_rt = ( bool )b;
        }
        return 1;
    }
    if ( strcmp( k, "color" ) == 0 ) {
        char *s = parse_basic_string( p );
        int   n;
        if ( s == NULL ) return 0;
        if ( !enum_color_mode( s, &n ) ) {
            diag_at( p, val_line, val_col,
                     "expected \"auto\"/\"always\"/\"never\", got \"%s\"", s );
            free( s );
            return 0;
        }
        free( s );
        cfg->has_color = true;
        cfg->color     = n;
        return 1;
    }
    diag_at( p, val_line, val_col,
             "unknown [build] key \"%s\"", k );
    return 0;
}

static int apply_diag_key( Parser *p, LcConfig *cfg, const char *k,
                           int val_line, int val_col ) {
    if ( strcmp( k, "format" ) == 0 ) {
        char *s = parse_basic_string( p );
        int   n;
        if ( s == NULL ) return 0;
        if ( !enum_diag_format( s, &n ) ) {
            diag_at( p, val_line, val_col,
                     "expected \"text\"/\"json\", got \"%s\"", s );
            free( s );
            return 0;
        }
        free( s );
        cfg->has_diag_format = true;
        cfg->diag_format     = n;
        return 1;
    }
    if ( strcmp( k, "werror" ) == 0 ) {
        int b;
        if ( !parse_bool( p, &b ) ) {
            diag_here( p, "expected `true` or `false`", NULL );
            return 0;
        }
        cfg->has_werror = true;
        cfg->werror     = ( bool )b;
        return 1;
    }
    if ( strcmp( k, "warn" ) == 0 ) {
        return parse_string_array( p, &cfg->warn_names, &cfg->warn_count );
    }
    diag_at( p, val_line, val_col,
             "unknown [diagnostics] key \"%s\"", k );
    return 0;
}

/* Assign a string value to a `char **slot`. Fails if slot was already set. */
static int assign_string_slot( Parser *p, char **slot, const char *label ) {
    char *s = parse_basic_string( p );
    if ( s == NULL ) return 0;
    if ( *slot != NULL ) free( *slot );
    *slot = s;
    ( void )label;
    return 1;
}

static int apply_resource_key( Parser *p, LcConfig *cfg, const char *k,
                               int val_line, int val_col ) {
    if ( strcmp( k, "product-name"    ) == 0 ) return assign_string_slot( p, &cfg->product_name,    k );
    if ( strcmp( k, "product-version" ) == 0 ) return assign_string_slot( p, &cfg->product_version, k );
    if ( strcmp( k, "company-name"    ) == 0 ) return assign_string_slot( p, &cfg->company_name,    k );
    if ( strcmp( k, "copyright"       ) == 0 ) return assign_string_slot( p, &cfg->copyright,       k );
    if ( strcmp( k, "manifest"        ) == 0 ) return assign_string_slot( p, &cfg->manifest,        k );
    if ( strcmp( k, "icon"            ) == 0 ) return assign_string_slot( p, &cfg->icon,            k );
    diag_at( p, val_line, val_col,
             "unknown [resource] key \"%s\"", k );
    return 0;
}

static int apply_explain_key( Parser *p, LcConfig *cfg, const char *k,
                              int val_line, int val_col ) {
    if ( strcmp( k, "target-triple" ) == 0 )
        return assign_string_slot( p, &cfg->target_triple, k );
    diag_at( p, val_line, val_col,
             "unknown [explain] key \"%s\"", k );
    return 0;
}

/* Push a bundle package name onto cfg->bundles. */
static int push_bundle( LcConfig *cfg, char *pkg ) {
    char **na = ( char ** )realloc( cfg->bundles,
                                     ( cfg->bundle_count + 1 ) *
                                     sizeof( char * ) );
    if ( na == NULL ) { free( pkg ); return 0; }
    cfg->bundles = na;
    cfg->bundles[ cfg->bundle_count++ ] = pkg;
    return 1;
}

static int apply_bundle_key( Parser *p, LcConfig *cfg, const char *k,
                             int val_line, int val_col ) {
    if ( strcmp( k, "package" ) == 0 ) {
        char *s = parse_basic_string( p );
        if ( s == NULL ) return 0;
        return push_bundle( cfg, s );
    }
    diag_at( p, val_line, val_col,
             "unknown [[bundle]] key \"%s\"", k );
    return 0;
}

/* Route a `key = value` line into the appropriate section handler. */
static int apply_key( Parser *p, LcConfig *cfg, const char *k,
                      int val_line, int val_col ) {
    if ( p->section == NULL ) {
        diag_at( p, val_line, val_col,
                 "top-level key \"%s\" outside any [section]", k );
        return 0;
    }
    if ( p->in_bundle_item ) return apply_bundle_key( p, cfg, k, val_line, val_col );
    if ( strcmp( p->section, "build" )       == 0 ) return apply_build_key   ( p, cfg, k, val_line, val_col );
    if ( strcmp( p->section, "diagnostics" ) == 0 ) return apply_diag_key    ( p, cfg, k, val_line, val_col );
    if ( strcmp( p->section, "resource" )    == 0 ) return apply_resource_key( p, cfg, k, val_line, val_col );
    if ( strcmp( p->section, "explain" )     == 0 ) return apply_explain_key ( p, cfg, k, val_line, val_col );
    diag_at( p, val_line, val_col,
             "unknown [section] \"[%s]\"", p->section );
    return 0;
}

/* Parse a `[header]` or `[[header]]` line. On success updates parser state
** and returns 1; on error prints a diagnostic and returns 0. */
static int parse_header( Parser *p, LcConfig *cfg ) {
    int  line = p->line, col = p->col;
    int  is_aot = 0;
    char *name;
    if ( at_eof( p ) || p->buf[ p->pos ] != '[' ) return 0;
    advance( p );
    if ( !at_eof( p ) && p->buf[ p->pos ] == '[' ) { is_aot = 1; advance( p ); }
    skip_hspace( p );
    name = parse_bare_key( p );
    if ( name == NULL ) {
        diag_at( p, line, col, "expected identifier after '['", NULL );
        return 0;
    }
    skip_hspace( p );
    if ( at_eof( p ) || p->buf[ p->pos ] != ']' ) {
        diag_here( p, "expected ']' to close section header", NULL );
        free( name );
        return 0;
    }
    advance( p );
    if ( is_aot ) {
        if ( at_eof( p ) || p->buf[ p->pos ] != ']' ) {
            diag_here( p, "expected ']]' to close [[array]] header", NULL );
            free( name );
            return 0;
        }
        advance( p );
    }
    if ( !skip_line_tail( p ) ) {
        diag_here( p, "trailing text after section header", NULL );
        free( name );
        return 0;
    }
    if ( is_aot ) {
        if ( strcmp( name, "bundle" ) != 0 ) {
            diag_at( p, line, col,
                     "only [[bundle]] is supported as array-of-tables, "
                     "got [[%s]]", name );
            free( name );
            return 0;
        }
        free( p->section );
        p->section = name;
        p->in_bundle_item = 1;
        ( void )cfg;
        return 1;
    }
    free( p->section );
    p->section = name;
    p->in_bundle_item = 0;
    return 1;
}

/* Parse the whole file. Returns 1 on success. */
static int parse_file( Parser *p, LcConfig *cfg ) {
    for ( ;; ) {
        skip_gap( p );
        if ( at_eof( p ) ) return 1;
        if ( p->buf[ p->pos ] == '[' ) {
            if ( !parse_header( p, cfg ) ) return 0;
            continue;
        }
        /* key = value */
        {
            char *key;
            int   val_line, val_col;
            skip_hspace( p );
            key = parse_bare_key( p );
            if ( key == NULL ) {
                diag_here( p, "expected key or [section]", NULL );
                return 0;
            }
            skip_hspace( p );
            if ( at_eof( p ) || p->buf[ p->pos ] != '=' ) {
                diag_here( p, "expected '=' after key", NULL );
                free( key );
                return 0;
            }
            advance( p );
            skip_hspace( p );
            val_line = p->line;
            val_col  = p->col;
            if ( !apply_key( p, cfg, key, val_line, val_col ) ) {
                free( key );
                return 0;
            }
            free( key );
            if ( !skip_line_tail( p ) ) {
                diag_here( p, "trailing text after value", NULL );
                return 0;
            }
        }
    }
}

int LcConfig_Load( const char *path, LcConfig *cfg ) {
    FILE   *f;
    long    sz;
    char   *buf;
    size_t  n;
    Parser  p;
    int     ok;

    if ( cfg == NULL || path == NULL ) return 0;
    LcConfig_Init( cfg );
    cfg->source_path = xstrdup( path );

    f = fopen( path, "rb" );
    if ( f == NULL ) {
        fprintf( stderr, "%s: error: cannot open config file\n", path );
        return 0;
    }
    fseek( f, 0, SEEK_END );
    sz = ftell( f );
    fseek( f, 0, SEEK_SET );
    if ( sz < 0 ) sz = 0;
    buf = ( char * )malloc( ( size_t )sz + 1 );
    if ( buf == NULL ) { fclose( f ); return 0; }
    n = fread( buf, 1, ( size_t )sz, f );
    fclose( f );
    buf[ n ] = '\0';

    memset( &p, 0, sizeof( p ) );
    p.path = path;
    p.buf  = buf;
    p.len  = n;
    p.pos  = 0;
    p.line = 1;
    p.col  = 1;
    ok = parse_file( &p, cfg );
    free( p.section );
    free( buf );
    if ( !ok ) LcConfig_Free( cfg );
    return ok;
}

/* ------------------------------------------------------------------ */
/*  Overlay onto LcDriverOptions.                                      */
/* ------------------------------------------------------------------ */

void LcConfig_ApplyToOptions( const LcConfig *cfg, LcDriverOptions *opt,
                              const char ***out_force, int *out_nforce ) {
    if ( cfg == NULL || opt == NULL ) return;

    if ( cfg->has_optimization ) opt->opt_level     = cfg->optimization;
    if ( cfg->has_output )       opt->output_kind   = cfg->output_kind;
    if ( cfg->has_strip ) {
        opt->strip_mode          = cfg->strip_mode;
        opt->strip_mode_explicit = true;
    }
    if ( cfg->has_jobs )         opt->jobs          = cfg->jobs;
    if ( cfg->has_debug )        opt->debug_line_info = cfg->debug;
    if ( cfg->has_cache )        opt->no_cache      = !cfg->cache;
    if ( cfg->has_shared_rt )    opt->shared_rt     = cfg->shared_rt;
    if ( cfg->has_color )        LcDiag_SetColorMode( ( LC_DIAG_COLOR_MODE_T )cfg->color );
    if ( cfg->has_diag_format )  LcDiag_SetFormat( ( LC_DIAG_FORMAT_T )cfg->diag_format );

    if ( cfg->has_werror )       opt->warn.werror_all = cfg->werror;
    /* Category names in cfg->warn_names are treated like -W<name>. */
    {
        size_t i;
        for ( i = 0; i < cfg->warn_count; i++ ) {
            const char *n = cfg->warn_names[ i ];
            if ( n == NULL || n[ 0 ] == '\0' ) continue;
            /* strcmp is fine here; the only category id today is "unused". */
            if ( strcmp( n, "unused" ) == 0 || strcmp( n, "shadow" ) == 0 ) {
                opt->warn.unused = true;
            }
        }
    }

    if ( cfg->product_name    != NULL ) opt->product_name    = cfg->product_name;
    if ( cfg->product_version != NULL ) opt->product_version = cfg->product_version;
    if ( cfg->company_name    != NULL ) opt->company_name    = cfg->company_name;
    if ( cfg->copyright       != NULL ) opt->legal_copyright = cfg->copyright;
    if ( cfg->manifest        != NULL ) opt->manifest_path   = cfg->manifest;
    if ( cfg->icon            != NULL ) opt->icon_path       = cfg->icon;

    if ( cfg->bundle_count > 0 && out_force != NULL && out_nforce != NULL ) {
        size_t i;
        const char **arr = ( const char ** )calloc( cfg->bundle_count + 1,
                                                    sizeof( char * ) );
        if ( arr == NULL ) return;
        for ( i = 0; i < cfg->bundle_count; i++ ) {
            arr[ i ] = cfg->bundles[ i ];
        }
        arr[ cfg->bundle_count ] = NULL;
        *out_force  = arr;
        *out_nforce = ( int )cfg->bundle_count;
        opt->force_pkgs  = arr;
        opt->nforce_pkgs = ( int )cfg->bundle_count;
    }
}

/* ------------------------------------------------------------------ */
/*  Environment overlay.                                               */
/* ------------------------------------------------------------------ */

static int env_bool( const char *name ) {
    const char *v = getenv( name );
    if ( v == NULL || v[ 0 ] == '\0' ) return -1;
    if ( v[ 0 ] == '0' && v[ 1 ] == '\0' ) return 0;
    return 1;
}

void LcConfig_ApplyEnv( LcDriverOptions *opt ) {
    const char *s;
    if ( opt == NULL ) return;

    s = getenv( "CLUA_OPTIMIZATION" );
    if ( s != NULL && s[ 0 ] != '\0' ) {
        int n;
        if ( enum_opt_level( s, &n ) ) opt->opt_level = n;
    }
    s = getenv( "CLUA_JOBS" );
    if ( s != NULL && s[ 0 ] != '\0' ) {
        int n = atoi( s );
        if ( n >= 0 && n <= 1024 ) opt->jobs = n;
    }
    s = getenv( "CLUA_STRIP" );
    if ( s != NULL && s[ 0 ] != '\0' ) {
        int n;
        if ( enum_strip_mode( s, &n ) ) {
            opt->strip_mode = n;
            opt->strip_mode_explicit = true;
        }
    }
    {
        int v = env_bool( "CLUA_DEBUG" );
        if ( v >= 0 ) opt->debug_line_info = ( bool )v;
    }
    {
        int v = env_bool( "CLUA_NO_CACHE" );
        if ( v >= 0 ) opt->no_cache = ( bool )v;
    }
    s = getenv( "CLUA_CACHE_DIR" );
    if ( s != NULL && s[ 0 ] != '\0' ) opt->cache_dir = s;
    {
        int v = env_bool( "CLUA_SHARED_RT" );
        if ( v >= 0 ) opt->shared_rt = ( bool )v;
    }
    s = getenv( "CLUA_COLOR" );
    if ( s != NULL && s[ 0 ] != '\0' ) {
        LC_DIAG_COLOR_MODE_T m;
        if ( LcDiag_ParseColorMode( s, &m ) ) LcDiag_SetColorMode( m );
    }
    s = getenv( "CLUA_DIAGNOSTICS_FORMAT" );
    if ( s != NULL && s[ 0 ] != '\0' ) {
        LC_DIAG_FORMAT_T f;
        if ( LcDiag_ParseFormat( s, &f ) ) LcDiag_SetFormat( f );
    }
}
