/*!
 * @brief
 *  Build a CLUA blob from a set of bytecode modules.
 */

#ifndef CLUA_COMPILER_BLOB_H
#define CLUA_COMPILER_BLOB_H

#include <stddef.h>

typedef struct _BLOB_MODULE {
    const char           *Name;     /* dotted module name, NUL-terminated */
    const unsigned char  *Bytes;    /* bytecode payload */
    size_t                BytesLen; /* payload length */
} BLOB_MODULE_T, *PBLOB_MODULE_T;

typedef struct _BLOB_BUILD_RESULT {
    unsigned char *Bytes;    /* malloc'd; release with Blob_FreeResult */
    size_t         BytesLen;
} BLOB_BUILD_RESULT_T, *PBLOB_BUILD_RESULT_T;

/*!
 * @brief
 *  Serialise modules into the CLUA blob format.
 *
 * @return
 *  1 on success; 0 on invalid input or allocation failure
 */
int Blob_Build( PBLOB_MODULE_T        Modules,
                size_t                Count,
                unsigned              EntryIndex,
                PBLOB_BUILD_RESULT_T  Result );

void Blob_FreeResult( PBLOB_BUILD_RESULT_T Result );

#endif /* CLUA_COMPILER_BLOB_H */
