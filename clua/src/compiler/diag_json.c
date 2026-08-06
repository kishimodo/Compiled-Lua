/* diag_json.c -- rustc-shaped one-object-per-line JSON diagnostic writer.
 *
 * The escaper is deliberately minimal: only the JSON-mandatory escapes plus
 * every C0 control byte (0x00..0x1F). Everything at 0x20 and above passes
 * through as-is, which preserves UTF-8 sequences verbatim (multibyte UTF-8
 * bytes are all >= 0x80). This matches how rustc's own JSON output handles
 * non-ASCII: emitting `\uXXXX` for every non-ASCII code point would require
 * decoding UTF-8 to code points (and encoding surrogate pairs for U+10000+),
 * which is both slower and needlessly noisy for editor consumers that already
 * speak UTF-8 -- which is all of them.
 *
 * Windows path handling falls out for free: `\` is a JSON-mandatory escape,
 * so `C:\src\app.lua` becomes `C:\\src\\app.lua` in the emitted `file` field
 * with no path-specific code path.
 */
#include "compiler/diag_json.h"

#include <stdio.h>
#include <string.h>

static const char *SeverityString( LC_SEVERITY_T Sev ) {
    switch ( Sev ) {
        case LC_SEV_WARNING: return "warning";
        case LC_SEV_NOTE:    return "note";
        case LC_SEV_HELP:    return "help";
        case LC_SEV_ERROR:
        default:             return "error";
    }
}

void lc_json_string( FILE *Out, const char *S ) {
    if ( Out == NULL ) { return; }
    fputc( '"', Out );
    if ( S == NULL ) { fputc( '"', Out ); return; }
    /* Walk byte-by-byte. `unsigned char` matters: a signed `char` would sign-
     * extend a UTF-8 continuation byte (>= 0x80) to a negative int, and the
     * `< 0x20` control-char check would then wrongly include it. Casting to
     * unsigned first is the standard fix. */
    for ( const unsigned char *P = ( const unsigned char * )S; *P != 0; P++ ) {
        unsigned char C = *P;
        switch ( C ) {
            case '"' : fputs( "\\\"", Out ); break;
            case '\\': fputs( "\\\\", Out ); break;
            case '\b': fputs( "\\b",  Out ); break;
            case '\f': fputs( "\\f",  Out ); break;
            case '\n': fputs( "\\n",  Out ); break;
            case '\r': fputs( "\\r",  Out ); break;
            case '\t': fputs( "\\t",  Out ); break;
            default:
                if ( C < 0x20 ) {
                    /* All remaining C0 controls: emit as \u00XX with 2 hex
                     * digits, four total after the `u` (RFC 8259 requires
                     * exactly four hex digits per \u escape). */
                    fprintf( Out, "\\u%04x", ( unsigned )C );
                } else {
                    /* 0x20 .. 0xFF: pass through. For 0x80..0xFF this is a
                     * UTF-8 continuation or lead byte and must not be
                     * touched -- the resulting string stays valid UTF-8. */
                    fputc( ( int )C, Out );
                }
                break;
        }
    }
    fputc( '"', Out );
}

/* One span object. Line/columns of 0 come out as JSON `null` so a consumer
 * can tell "unknown" from "start-of-line": rustc reports full ranges and a
 * 0/null column is not a legal thing in its schema; encoding "unknown" as
 * null (rather than 0 or 1) keeps range math on the consumer side honest. */
static void WriteSpan( FILE *Out, const LC_DIAG_SPAN_T *Sp ) {
    fputc( '{', Out );
    fputs( "\"file\":", Out ); lc_json_string( Out, Sp->File );
    if ( Sp->Line > 0 ) {
        fprintf( Out, ",\"line\":%d", Sp->Line );
    } else {
        fputs( ",\"line\":null", Out );
    }
    if ( Sp->ColStart > 0 ) {
        int End = Sp->ColEnd;
        if ( End <= Sp->ColStart ) { End = Sp->ColStart + 1; }
        fprintf( Out, ",\"col_start\":%d,\"col_end\":%d", Sp->ColStart, End );
    } else {
        fputs( ",\"col_start\":null,\"col_end\":null", Out );
    }
    fputs( ",\"label\":", Out );
    if ( Sp->Label ) { lc_json_string( Out, Sp->Label ); }
    else             { fputs( "null", Out );             }
    fprintf( Out, ",\"is_primary\":%s", Sp->IsPrimary ? "true" : "false" );
    fputc( '}', Out );
}

static void WriteSpans( FILE *Out, const LC_DIAG_SPAN_T *Spans, int N ) {
    fputc( '[', Out );
    for ( int I = 0; I < N; I++ ) {
        if ( I ) { fputc( ',', Out ); }
        WriteSpan( Out, &Spans[ I ] );
    }
    fputc( ']', Out );
}

static void WriteChildren( FILE *Out, const LC_DIAG_CHILD_T *Kids, int N ) {
    fputc( '[', Out );
    for ( int I = 0; I < N; I++ ) {
        if ( I ) { fputc( ',', Out ); }
        fputc( '{', Out );
        fputs( "\"severity\":", Out );
        lc_json_string( Out, SeverityString( Kids[ I ].Severity ) );
        fputs( ",\"message\":", Out );
        lc_json_string( Out, Kids[ I ].Message ? Kids[ I ].Message : "" );
        fputs( ",\"spans\":", Out );
        WriteSpans( Out, Kids[ I ].Spans, Kids[ I ].NSpans );
        fputc( '}', Out );
    }
    fputc( ']', Out );
}

void LcDiag_WriteJson( FILE                  *Out,
                       LC_SEVERITY_T          Severity,
                       const char            *Code,
                       const char            *Message,
                       const LC_DIAG_SPAN_T  *Spans,
                       int                    NSpans,
                       const LC_DIAG_CHILD_T *Children,
                       int                    NChildren,
                       const char            *Help ) {
    if ( Out == NULL ) { return; }
    fputc( '{', Out );

    fputs( "\"severity\":", Out );
    lc_json_string( Out, SeverityString( Severity ) );

    fputs( ",\"code\":", Out );
    if ( Code && Code[ 0 ] ) { lc_json_string( Out, Code ); }
    else                     { fputs( "null", Out );        }

    fputs( ",\"message\":", Out );
    lc_json_string( Out, Message ? Message : "" );

    fputs( ",\"spans\":", Out );
    WriteSpans( Out, Spans, NSpans );

    fputs( ",\"children\":", Out );
    WriteChildren( Out, Children, NChildren );

    fputs( ",\"help\":", Out );
    if ( Help && Help[ 0 ] ) { lc_json_string( Out, Help ); }
    else                     { fputs( "null", Out );        }

    /* Close the object AND terminate the line. Consumers split on `\n`; the
     * object itself contains no literal newlines because lc_json_string
     * escapes them as `\n` inside the payload strings. */
    fputs( "}\n", Out );
    fflush( Out );
}
