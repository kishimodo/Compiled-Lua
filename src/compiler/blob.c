#include "compiler/blob.h"
#include "common/blob_format.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

void Blob_FreeResult( PBLOB_BUILD_RESULT_T Result ) {
    if ( Result == NULL ) {
        return;
    }
    free( Result->Bytes );
    Result->Bytes    = NULL;
    Result->BytesLen = 0;
}

int Blob_Build( PBLOB_MODULE_T        Modules,
                size_t                Count,
                unsigned              EntryIndex,
                PBLOB_BUILD_RESULT_T  Result ) {
    size_t        HeaderSize = { 0 };
    size_t        TableSize  = { 0 };
    size_t        NamePool   = { 0 };
    size_t        PayloadSum = { 0 };
    size_t        Total      = { 0 };
    size_t        I          = { 0 };
    unsigned char *Buf       = { 0 };
    size_t        Cursor     = { 0 };

    if ( Modules == NULL || Count == 0 || Result == NULL ) {
        return 0;
    }
    if ( EntryIndex >= Count ) {
        return 0;
    }
    for ( I = 0; I < Count; I++ ) {
        if ( Modules[ I ].Name == NULL || Modules[ I ].Name[ 0 ] == '\0' ) {
            return 0;
        }
        if ( Modules[ I ].Bytes == NULL || Modules[ I ].BytesLen == 0 ) {
            return 0;
        }
        NamePool   += strlen( Modules[ I ].Name ) + 1;
        PayloadSum += Modules[ I ].BytesLen;
    }

    HeaderSize = sizeof( LUAVM_BLOB_HEADER_T );
    TableSize  = sizeof( MODULE_ENTRY_T ) * Count;
    Total      = HeaderSize + TableSize + NamePool + PayloadSum;

    Buf = ( unsigned char * )calloc( 1, Total );
    if ( Buf == NULL ) {
        return 0;
    }

    PLUAVM_BLOB_HEADER_T Hdr = ( PLUAVM_BLOB_HEADER_T )Buf;
    Hdr->Magic      = LUAVM_BLOB_MAGIC;
    Hdr->Version    = LUAVM_BLOB_VERSION;
    Hdr->Count      = ( uint32_t )Count;
    Hdr->EntryIndex = ( uint32_t )EntryIndex;
    Hdr->TotalSize  = ( uint32_t )Total;
    Hdr->Flags      = 0;
    /* EncryptionKey already zeroed by calloc. */

    PMODULE_ENTRY_T Table = ( PMODULE_ENTRY_T )( Buf + HeaderSize );

    /* lay out the name pool */
    Cursor = HeaderSize + TableSize;
    for ( I = 0; I < Count; I++ ) {
        size_t L = strlen( Modules[ I ].Name );
        Table[ I ].NameOffset = ( uint32_t )Cursor;
        Table[ I ].NameLen    = ( uint32_t )L;
        memcpy( Buf + Cursor, Modules[ I ].Name, L + 1 );
        Cursor += L + 1;
    }

    /* lay out the payloads */
    for ( I = 0; I < Count; I++ ) {
        Table[ I ].DataOffset = ( uint32_t )Cursor;
        Table[ I ].DataLen    = ( uint32_t )Modules[ I ].BytesLen;
        memcpy( Buf + Cursor, Modules[ I ].Bytes, Modules[ I ].BytesLen );
        Cursor += Modules[ I ].BytesLen;
    }

    Result->Bytes    = Buf;
    Result->BytesLen = Total;
    return 1;
}
