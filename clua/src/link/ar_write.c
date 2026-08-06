/*
** ar_write.c -- write a GNU-form `ar` archive that wraps a single COFF object.
**
** Backs `clua build --output=lib`: the codegen COFF is already the artifact,
** so a static "library" is just that COFF file wrapped with the ar container
** shape that MinGW ld / MSVC lib consumers already know how to open. No link
** step, no runtime pull-in, no aot_entry.
**
** On-disk layout produced here (all offsets from BOF):
**
**   0x00 : "!<arch>\n"                                (8 bytes, ar magic)
**   0x08 : member #1 header:  name  = "/               " (SysV/GNU symbol tbl)
**                             mtime = "0           "     (deterministic)
**                             uid   = "0     "
**                             gid   = "0     "
**                             mode  = "0       "
**                             size  = decimal, symbol-table payload bytes
**                             fmag  = "`\n"             (60 bytes total)
**          symbol table (SysV/GNU big-endian form):
**              be32 nsyms
**              be32 member_offset[nsyms]  -- offset of the DEFINING member's
**                                            header (60-byte aligned counted
**                                            from the archive start; NOT the
**                                            data offset)
**              nsyms NUL-terminated symbol names, tight
**          + 1 byte '\n' pad if the payload size is odd (2-byte alignment)
**
**   member #2 header:         name  = "obj.o           "
**                             size  = decimal, COFF byte length
**                             fmag  = "`\n"
**          COFF payload bytes exactly as `obj_path` on disk.
**          + 1 byte '\n' pad if the payload size is odd.
**
** MinGW's binutils `ar` / `ld` accepts this shape (it is what GNU `ar` itself
** writes for a small archive that has no long names). MSVC's `link.exe` /
** `lib.exe` insist on a "second linker member" (the MS-form index) and the
** longnames member in a specific order -- GNU archives omit both -- so a
** `.lib` produced here is MinGW-consumable, not directly link.exe-consumable.
** Downstream users targeting MSVC should either round-trip through `lib.exe
** /convert` or ask for `--output=dll` + `--emit-def=<path>` and let `link
** /def` synthesize the MSVC-form import library.
**
** No dependency on the rest of the internal linker: parses the input COFF only
** enough to enumerate its EXTERNAL, defined symbols (SectionNumber >= 1,
** StorageClass == EXTERNAL, name != ""). Everything else -- relocations,
** COMDATs, weak externals -- rides through in the payload bytes untouched.
*/

#include "link/ar_write.h"
#include "link/coff_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AR_MAGIC       "!<arch>\n"
#define AR_MAGIC_LEN   8
#define AR_HDR_LEN     60

static int wfail( char *err, size_t errlen, const char *fmt, const char *a ) {
    if ( err && errlen ) snprintf( err, errlen, fmt, a ? a : "" );
    return 0;
}

/* Write a big-endian uint32. */
static void put_be32( uint8_t *p, uint32_t v ) {
    p[0] = ( uint8_t )( ( v >> 24 ) & 0xff );
    p[1] = ( uint8_t )( ( v >> 16 ) & 0xff );
    p[2] = ( uint8_t )( ( v >> 8  ) & 0xff );
    p[3] = ( uint8_t )( v & 0xff );
}

/* Fill a fixed-width text field: `text` left-justified, space-padded, no NUL. */
static void fill_field( uint8_t *dst, size_t width, const char *text ) {
    size_t tlen = text ? strlen( text ) : 0;
    if ( tlen > width ) tlen = width;
    memset( dst, ' ', width );
    if ( tlen ) memcpy( dst, text, tlen );
}

/* Fill a decimal integer field, left-justified space-padded. */
static void fill_dec( uint8_t *dst, size_t width, uint32_t v ) {
    char buf[24];
    int  n = snprintf( buf, sizeof( buf ), "%u", ( unsigned )v );
    if ( n < 0 ) n = 0;
    if ( ( size_t )n > width ) n = ( int )width;
    memset( dst, ' ', width );
    memcpy( dst, buf, ( size_t )n );
}

/* Read the whole file at `path` into a freshly malloc'd buffer. */
static uint8_t *slurp( const char *path, size_t *out_len,
                       char *err, size_t errlen ) {
    FILE   *f;
    long    sz;
    uint8_t *buf;

    *out_len = 0;
    f = fopen( path, "rb" );
    if ( f == NULL ) { wfail( err, errlen, "cannot open %s", path ); return NULL; }
    if ( fseek( f, 0, SEEK_END ) != 0 ) {
        fclose( f ); wfail( err, errlen, "seek failed on %s", path ); return NULL;
    }
    sz = ftell( f );
    if ( sz < 0 ) {
        fclose( f ); wfail( err, errlen, "ftell failed on %s", path ); return NULL;
    }
    if ( fseek( f, 0, SEEK_SET ) != 0 ) {
        fclose( f ); wfail( err, errlen, "seek failed on %s", path ); return NULL;
    }
    buf = ( uint8_t * )malloc( ( size_t )sz );
    if ( buf == NULL ) {
        fclose( f ); wfail( err, errlen, "oom reading %s", path ); return NULL;
    }
    if ( sz > 0 && fread( buf, 1, ( size_t )sz, f ) != ( size_t )sz ) {
        free( buf ); fclose( f );
        wfail( err, errlen, "short read on %s", path );
        return NULL;
    }
    fclose( f );
    *out_len = ( size_t )sz;
    return buf;
}

int LcArWrite_SingleMemberObject( const char *obj_path,
                                  const char *out_lib_path,
                                  char *err, size_t errlen ) {
    uint8_t   *obj_bytes = NULL;
    size_t     obj_len   = 0;
    LcCoffObj  obj;
    int        parsed_ok = 0;

    /* Symbol table build state. */
    uint32_t   nsyms      = 0;
    size_t     names_len  = 0;   /* total bytes of NUL-terminated names       */
    uint32_t  *keep       = NULL;/* symbol-slot indices that make the armap   */
    uint32_t   keep_cap   = 0;

    /* Output builder. */
    uint8_t   *out_buf    = NULL;
    size_t     out_cap    = 0;
    size_t     out_len    = 0;
    FILE      *of         = NULL;
    int        rc         = 0;

    if ( obj_path == NULL || out_lib_path == NULL ) {
        wfail( err, errlen, "ar_write: null path%s", "" );
        return 0;
    }

    memset( &obj, 0, sizeof( obj ) );

    obj_bytes = slurp( obj_path, &obj_len, err, errlen );
    if ( obj_bytes == NULL ) goto done;

    /* Parse only to enumerate public symbols; the emitted payload is the
    ** original COFF bytes untouched. */
    if ( !LcCoff_Parse( obj_bytes, obj_len, obj_path, &obj, err, errlen ) )
        goto done;
    parsed_ok = 1;

    /* First pass: collect the indices of public defined symbols and total up
    ** the name-pool size for the armap payload. "Public" here = EXTERNAL class
    ** with a defined section number (>= 1). WEAK_EXTERNAL and static (STATIC,
    ** LABEL, FILE, SECTION, FUNCTION) are excluded -- a real static archive
    ** built by `ar rcs` under GNU binutils includes exactly the same set. */
    {
        uint32_t s;
        for ( s = 0; s < obj.nsymbols_slots; s++ ) {
            const LcCoffSymbol *sym = &obj.symbols[ s ];
            /* Skip aux marker slots (LcCoff_Parse sets section to a sentinel
            ** on those; SymByIndex returns NULL for them). */
            if ( LcCoff_SymByIndex( &obj, s ) == NULL ) continue;
            if ( sym->storage != LC_IMAGE_SYM_CLASS_EXTERNAL ) continue;
            if ( sym->section < 1 ) continue;   /* undefined / abs / debug   */
            if ( sym->name == NULL || sym->name[0] == '\0' ) continue;

            if ( nsyms == keep_cap ) {
                uint32_t   nc = keep_cap ? keep_cap * 2 : 16;
                uint32_t  *nk = ( uint32_t * )realloc( keep,
                                                       nc * sizeof( uint32_t ) );
                if ( nk == NULL ) { wfail( err, errlen, "ar_write: oom%s", "" ); goto done; }
                keep = nk; keep_cap = nc;
            }
            keep[ nsyms++ ] = s;
            names_len += strlen( sym->name ) + 1;
        }
    }

    /* Layout arithmetic. The armap member's payload size is:
    **   4 (nsyms) + 4 * nsyms (offsets) + names_len.
    ** All member headers are AR_HDR_LEN. The COFF payload starts right after
    ** the armap payload (+1 pad byte if the armap payload is odd) + the COFF
    ** member header.
    **
    ** The member_offset field in the armap must point at the DEFINING member's
    ** HEADER byte offset, i.e. the byte position of the 60-byte header itself,
    ** NOT the data that follows. */
    {
        uint32_t armap_payload_len = 4u + 4u * nsyms + ( uint32_t )names_len;
        uint32_t armap_pad         = ( armap_payload_len & 1u ) ? 1u : 0u;
        uint32_t coff_hdr_off      = ( uint32_t )AR_MAGIC_LEN
                                   + ( uint32_t )AR_HDR_LEN
                                   + armap_payload_len
                                   + armap_pad;
        uint32_t coff_pad          = ( ( uint32_t )obj_len & 1u ) ? 1u : 0u;
        size_t   total             = ( size_t )coff_hdr_off + AR_HDR_LEN
                                   + obj_len + coff_pad;
        uint8_t *p;

        out_buf = ( uint8_t * )malloc( total );
        if ( out_buf == NULL ) { wfail( err, errlen, "ar_write: oom%s", "" ); goto done; }
        out_cap = total;
        memset( out_buf, 0, total );

        /* magic */
        memcpy( out_buf, AR_MAGIC, AR_MAGIC_LEN );
        out_len = AR_MAGIC_LEN;

        /* --- armap member header --- */
        p = out_buf + out_len;
        fill_field( p +  0, 16, "/"       );  /* name = "/" (symbol table)   */
        fill_field( p + 16, 12, "0"       );  /* mtime = 0 (deterministic)   */
        fill_field( p + 28,  6, "0"       );  /* uid                          */
        fill_field( p + 34,  6, "0"       );  /* gid                          */
        fill_field( p + 40,  8, "0"       );  /* mode                         */
        fill_dec  ( p + 48, 10, armap_payload_len );
        p[ 58 ] = '`';
        p[ 59 ] = '\n';
        out_len += AR_HDR_LEN;

        /* --- armap payload: nsyms, offsets, names --- */
        p = out_buf + out_len;
        put_be32( p, nsyms );
        {
            uint32_t i;
            for ( i = 0; i < nsyms; i++ ) {
                /* every symbol resolves to the single member. */
                put_be32( p + 4u + 4u * i, coff_hdr_off );
            }
        }
        {
            uint32_t i;
            uint8_t *np = p + 4u + 4u * nsyms;
            for ( i = 0; i < nsyms; i++ ) {
                const char *nm = obj.symbols[ keep[ i ] ].name;
                size_t nl = strlen( nm );
                memcpy( np, nm, nl );
                np[ nl ] = '\0';
                np += nl + 1;
            }
        }
        out_len += armap_payload_len;
        if ( armap_pad ) { out_buf[ out_len++ ] = '\n'; }

        /* Sanity: we are now at coff_hdr_off. */
        if ( ( uint32_t )out_len != coff_hdr_off ) {
            wfail( err, errlen, "ar_write: internal layout mismatch%s", "" );
            goto done;
        }

        /* --- COFF member header --- */
        p = out_buf + out_len;
        /* Short name "obj.o" fits in 16 bytes; GNU convention terminates a
        ** short name with '/' before the trailing spaces. */
        fill_field( p +  0, 16, "obj.o/"  );
        fill_field( p + 16, 12, "0"       );
        fill_field( p + 28,  6, "0"       );
        fill_field( p + 34,  6, "0"       );
        fill_field( p + 40,  8, "644"     );
        fill_dec  ( p + 48, 10, ( uint32_t )obj_len );
        p[ 58 ] = '`';
        p[ 59 ] = '\n';
        out_len += AR_HDR_LEN;

        /* --- COFF payload (untouched) --- */
        if ( obj_len > 0 ) {
            memcpy( out_buf + out_len, obj_bytes, obj_len );
            out_len += obj_len;
        }
        if ( coff_pad ) { out_buf[ out_len++ ] = '\n'; }

        if ( out_len != total ) {
            wfail( err, errlen, "ar_write: internal write size mismatch%s", "" );
            goto done;
        }
    }

    of = fopen( out_lib_path, "wb" );
    if ( of == NULL ) { wfail( err, errlen, "cannot open %s", out_lib_path ); goto done; }
    if ( out_len > 0 && fwrite( out_buf, 1, out_len, of ) != out_len ) {
        fclose( of ); of = NULL;
        wfail( err, errlen, "short write to %s", out_lib_path );
        goto done;
    }
    fflush( of );
    if ( fclose( of ) != 0 ) {
        of = NULL;
        wfail( err, errlen, "close failed on %s", out_lib_path );
        goto done;
    }
    of = NULL;

    rc = 1;

done:
    if ( of != NULL ) fclose( of );
    free( out_buf );
    free( keep );
    if ( parsed_ok ) LcCoff_Free( &obj );
    free( obj_bytes );
    return rc;
}
