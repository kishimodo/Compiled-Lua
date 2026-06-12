/*!
 * @brief
 *  Read-only view over an in-memory LUAVM blob.
 */

#ifndef LUAVM_RUNTIME_BLOB_READER_H
#define LUAVM_RUNTIME_BLOB_READER_H

#include <stddef.h>
#include <stdint.h>

#include "common/blob_format.h"

typedef struct _BLOB_READER {
    const unsigned char  *Base;        /* pointer to blob start */
    size_t                Size;        /* total blob size */
    uint32_t              Count;
    uint32_t              EntryIndex;
    PMODULE_ENTRY_T       Table;       /* points inside Base */
} BLOB_READER_T, *PBLOB_READER_T;

typedef struct _BLOB_LOOKUP {
    const unsigned char *Bytes;
    size_t               BytesLen;
} BLOB_LOOKUP_T, *PBLOB_LOOKUP_T;

/*!
 * @brief
 *  Validate the blob header and populate Reader. Returns 0 on invalid input.
 */
int BlobReader_Open( const unsigned char *Base, size_t Size, PBLOB_READER_T Reader );

/*!
 * @brief
 *  Look up a module by exact name match. Returns 0 if not found.
 */
int BlobReader_Find( PBLOB_READER_T Reader, const char *Name, PBLOB_LOOKUP_T Out );

/*!
 * @brief
 *  Get the entry module's bytes directly.
 */
int BlobReader_GetEntry( PBLOB_READER_T Reader, PBLOB_LOOKUP_T Out );

#endif /* LUAVM_RUNTIME_BLOB_READER_H */
