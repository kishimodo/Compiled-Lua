/*
** rsrc_versioninfo.c -- build a VS_VERSION_INFO binary blob.
**
** The VS_VERSION_INFO structure is documented in the Windows SDK
** (VerRsrc.h + winres.h). Its wire form is:
**
**   VS_VERSIONINFO {
**     WORD  wLength;         // whole record incl. children, aligned
**     WORD  wValueLength;    // sizeof VS_FIXEDFILEINFO (52)
**     WORD  wType;           // 0 = binary value
**     WCHAR szKey[];         // L"VS_VERSION_INFO", padded to 4-byte
**     BYTE  Padding1[];
**     VS_FIXEDFILEINFO Value; // 52 bytes
**     BYTE  Padding2[];      // 4-byte align
**     Children[];            // StringFileInfo + VarFileInfo
**   }
**
**   StringFileInfo -> StringTable (lang+codepage) -> String (name/value pairs).
**   VarFileInfo    -> Var("Translation") -> array of LANGID+CP pairs.
**
** Every record is 4-byte aligned; wLength is the aligned total including all
** children. Strings are UTF-16LE, NUL-terminated.
*/
#include "link/rsrc_emit.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t *p; size_t len, cap; } VBuf;

static int vb_need( VBuf *b, size_t n ) {
    if ( b->len + n > b->cap ) {
        size_t nc = b->cap ? b->cap : 256;
        uint8_t *np;
        while ( nc < b->len + n ) nc *= 2;
        np = ( uint8_t * )realloc( b->p, nc );
        if ( !np ) return 0;
        b->p = np; b->cap = nc;
    }
    return 1;
}
static int vb_putn( VBuf *b, const void *s, size_t n ) {
    if ( !n ) return 1;
    if ( !vb_need( b, n ) ) return 0;
    memcpy( b->p + b->len, s, n ); b->len += n; return 1;
}
static int vb_zero( VBuf *b, size_t n ) {
    if ( !vb_need( b, n ) ) return 0;
    memset( b->p + b->len, 0, n ); b->len += n; return 1;
}
static int vb_pad4( VBuf *b ) {
    while ( b->len & 3 ) if ( !vb_zero( b, 1 ) ) return 0;
    return 1;
}
static void vw16( uint8_t *p, uint16_t v ) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void vw32( uint8_t *p, uint32_t v ) {
    p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24);
}

/* ASCII/UTF-8 -> UTF-16LE. Only the ASCII subset is written verbatim; bytes
** > 0x7F are copied as their low 8 bits into the WCHAR (crude but adequate
** for identifier-like fields; the manifest resource carries full UTF-8
** separately). Writes wchars followed by a UTF-16 NUL terminator. Returns
** the total byte count written. */
static size_t write_utf16_asciiz( VBuf *b, const char *s ) {
    size_t n = 0;
    if ( s == NULL ) s = "";
    for ( ; *s; s++ ) {
        uint8_t c = ( uint8_t )*s;
        uint8_t w[2] = { c, 0 };
        if ( !vb_putn( b, w, 2 ) ) return 0;
        n += 2;
    }
    uint8_t nul[2] = { 0, 0 };
    if ( !vb_putn( b, nul, 2 ) ) return 0;
    n += 2;
    return n;
}

/* Reserve a WORD wLength slot; the caller patches it once children are done. */
static size_t begin_record( VBuf *b ) {
    size_t pos = b->len;
    uint8_t hdr[6] = { 0, 0, 0, 0, 0, 0 };
    if ( !vb_putn( b, hdr, 6 ) ) return ( size_t )-1;
    return pos;
}

static void patch_wlength( VBuf *b, size_t rec_start ) {
    vw16( b->p + rec_start, ( uint16_t )( b->len - rec_start ) );
}

static void patch_wvaluelength( VBuf *b, size_t rec_start, uint16_t v ) {
    vw16( b->p + rec_start + 2, v );
}

static void patch_wtype( VBuf *b, size_t rec_start, uint16_t t ) {
    vw16( b->p + rec_start + 4, t );
}

/* Parse a version string like "1.2.3.4" or "0.3.0-beta.4" into 4 WORDs.
** Non-digit / dash / plus terminates parsing early; missing components are 0.
** Returns 1 if at least one field parsed, 0 otherwise (fields become 0). */
static int parse_version_4( const char *s, uint16_t out[ 4 ] ) {
    int i = 0;
    out[0] = out[1] = out[2] = out[3] = 0;
    if ( s == NULL ) return 0;
    while ( *s && i < 4 ) {
        unsigned long v = 0;
        int digits = 0;
        while ( *s >= '0' && *s <= '9' ) {
            v = v * 10 + ( unsigned long )( *s - '0' );
            if ( v > 0xFFFF ) v = 0xFFFF;
            s++; digits++;
        }
        if ( digits == 0 ) break;
        out[ i++ ] = ( uint16_t )v;
        if ( *s == '.' ) { s++; continue; }
        break;
    }
    return i > 0 ? 1 : 0;
}

int LcRsrc_BuildVersionInfo( const char *file_version_str,
                             const char *product_version_str,
                             const char *product_name,
                             const char *file_description,
                             const char *company_name,
                             const char *legal_copyright,
                             const char *internal_name,
                             const char *original_filename,
                             uint16_t    lang_id,
                             uint16_t    codepage,
                             uint8_t **out, size_t *out_len,
                             char *err, size_t errlen ) {
    VBuf buf; memset( &buf, 0, sizeof buf );

    if ( out ) *out = NULL;
    if ( out_len ) *out_len = 0;

    /* Defaults for optional strings. Empty strings are LEGAL (the resource
    ** viewer just shows a blank line), so an empty override is honored. */
    if ( product_name == NULL )    product_name    = "CLua Compiled Program";
    if ( file_description == NULL )
        file_description = product_name;
    if ( company_name == NULL )    company_name    = "";
    if ( legal_copyright == NULL ) legal_copyright = "";
    if ( internal_name == NULL )   internal_name   = "";
    if ( original_filename == NULL ) original_filename = "";
    if ( file_version_str == NULL ) file_version_str = "0.0.0.0";
    if ( product_version_str == NULL ) product_version_str = file_version_str;
    if ( lang_id == 0 ) lang_id = 0x0409;   /* US English */
    if ( codepage == 0 ) codepage = 0x04B0; /* Unicode (1200) */

    /* --- VS_VERSIONINFO header --- */
    size_t root = begin_record( &buf );
    if ( root == ( size_t )-1 ) return 0;
    if ( !write_utf16_asciiz( &buf, "VS_VERSION_INFO" ) ) goto oom;
    if ( !vb_pad4( &buf ) ) goto oom;

    /* --- VS_FIXEDFILEINFO (52 bytes) --- */
    {
        uint16_t fv[4], pv[4];
        parse_version_4( file_version_str,    fv );
        parse_version_4( product_version_str, pv );
        uint8_t fixed[ 52 ];
        memset( fixed, 0, sizeof fixed );
        vw32( fixed +  0, 0xFEEF04BDu ); /* dwSignature */
        vw32( fixed +  4, 0x00010000u ); /* dwStrucVersion 1.0 */
        vw32( fixed +  8, ( ( uint32_t )fv[0] << 16 ) | ( uint32_t )fv[1] ); /* FileVersionMS */
        vw32( fixed + 12, ( ( uint32_t )fv[2] << 16 ) | ( uint32_t )fv[3] ); /* FileVersionLS */
        vw32( fixed + 16, ( ( uint32_t )pv[0] << 16 ) | ( uint32_t )pv[1] ); /* ProductVersionMS */
        vw32( fixed + 20, ( ( uint32_t )pv[2] << 16 ) | ( uint32_t )pv[3] ); /* ProductVersionLS */
        vw32( fixed + 24, 0x3Fu );       /* dwFileFlagsMask: all flags valid */
        vw32( fixed + 28, 0 );           /* dwFileFlags   */
        vw32( fixed + 32, 0x00000004u ); /* dwFileOS = VOS__WINDOWS32 */
        vw32( fixed + 36, 0x00000001u ); /* dwFileType = VFT_APP */
        vw32( fixed + 40, 0 );           /* dwFileSubtype */
        vw32( fixed + 44, 0 ); vw32( fixed + 48, 0 ); /* dwFileDate */
        if ( !vb_putn( &buf, fixed, sizeof fixed ) ) goto oom;
    }
    patch_wvaluelength( &buf, root, 52 );
    patch_wtype( &buf, root, 0 );        /* binary */
    if ( !vb_pad4( &buf ) ) goto oom;

    /* --- StringFileInfo --- */
    {
        size_t sfi = begin_record( &buf );
        if ( sfi == ( size_t )-1 ) goto oom;
        patch_wvaluelength( &buf, sfi, 0 );
        patch_wtype( &buf, sfi, 1 );      /* text */
        if ( !write_utf16_asciiz( &buf, "StringFileInfo" ) ) goto oom;
        if ( !vb_pad4( &buf ) ) goto oom;

        /* --- StringTable "040904B0" (lang+codepage as 8 hex digits) --- */
        char st_key[ 16 ];
        snprintf( st_key, sizeof st_key, "%04X%04X", lang_id, codepage );
        size_t st = begin_record( &buf );
        if ( st == ( size_t )-1 ) goto oom;
        patch_wvaluelength( &buf, st, 0 );
        patch_wtype( &buf, st, 1 );
        if ( !write_utf16_asciiz( &buf, st_key ) ) goto oom;
        if ( !vb_pad4( &buf ) ) goto oom;

        /* --- one String record per (name,value) --- */
        struct { const char *name; const char *value; } kv[] = {
            { "CompanyName",      company_name       },
            { "FileDescription",  file_description   },
            { "FileVersion",      file_version_str   },
            { "InternalName",     internal_name      },
            { "LegalCopyright",   legal_copyright    },
            { "OriginalFilename", original_filename  },
            { "ProductName",      product_name       },
            { "ProductVersion",   product_version_str },
        };
        size_t nkv = sizeof( kv ) / sizeof( kv[0] );
        for ( size_t i = 0; i < nkv; i++ ) {
            size_t s0 = begin_record( &buf );
            if ( s0 == ( size_t )-1 ) goto oom;
            patch_wtype( &buf, s0, 1 );   /* text */
            if ( !write_utf16_asciiz( &buf, kv[i].name ) ) goto oom;
            if ( !vb_pad4( &buf ) ) goto oom;
            /* The Value field for a text String is a WCHAR string. The
            ** wValueLength field counts wchars (not bytes) including NUL. */
            size_t val_start = buf.len;
            size_t val_bytes = write_utf16_asciiz( &buf, kv[i].value );
            if ( val_bytes == 0 ) goto oom;
            patch_wvaluelength( &buf, s0, ( uint16_t )( val_bytes / 2 ) );
            (void)val_start;
            if ( !vb_pad4( &buf ) ) goto oom;
            patch_wlength( &buf, s0 );
        }
        patch_wlength( &buf, st );
        patch_wlength( &buf, sfi );
    }

    /* --- VarFileInfo -> Translation --- */
    {
        size_t vfi = begin_record( &buf );
        if ( vfi == ( size_t )-1 ) goto oom;
        patch_wvaluelength( &buf, vfi, 0 );
        patch_wtype( &buf, vfi, 1 );
        if ( !write_utf16_asciiz( &buf, "VarFileInfo" ) ) goto oom;
        if ( !vb_pad4( &buf ) ) goto oom;

        size_t v = begin_record( &buf );
        if ( v == ( size_t )-1 ) goto oom;
        /* Value is one DWORD: low WORD = LANGID, high WORD = codepage. */
        patch_wvaluelength( &buf, v, 4 );
        patch_wtype( &buf, v, 0 );
        if ( !write_utf16_asciiz( &buf, "Translation" ) ) goto oom;
        if ( !vb_pad4( &buf ) ) goto oom;
        uint8_t tr[4];
        vw16( tr + 0, lang_id );
        vw16( tr + 2, codepage );
        if ( !vb_putn( &buf, tr, 4 ) ) goto oom;
        if ( !vb_pad4( &buf ) ) goto oom;
        patch_wlength( &buf, v );
        patch_wlength( &buf, vfi );
    }

    patch_wlength( &buf, root );

    *out = buf.p;
    *out_len = buf.len;
    return 1;

oom:
    free( buf.p );
    if ( err && errlen ) snprintf( err, errlen, "versioninfo: oom" );
    return 0;
}
