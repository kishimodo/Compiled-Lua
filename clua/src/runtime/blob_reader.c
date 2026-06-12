#include "runtime/blob_reader.h"

#include <stddef.h>
#include <string.h>

int BlobReader_Open( const unsigned char *Base, size_t Size, PBLOB_READER_T Reader ) {
    PLUAVM_BLOB_HEADER_T Hdr = { 0 };

    if ( Base == NULL || Reader == NULL ) {
        return 0;
    }
    if ( Size < sizeof( LUAVM_BLOB_HEADER_T ) ) {
        return 0;
    }
    Hdr = ( PLUAVM_BLOB_HEADER_T )Base;
    if ( Hdr->Magic != LUAVM_BLOB_MAGIC )         { return 0; }
    if ( Hdr->Version != LUAVM_BLOB_VERSION )     { return 0; }
    if ( Hdr->Count == 0 )                        { return 0; }
    if ( Hdr->TotalSize != Size )                 { return 0; }
    if ( Hdr->EntryIndex >= Hdr->Count )          { return 0; }

    /* table must fit */
    if ( sizeof( *Hdr ) + ( size_t )Hdr->Count * sizeof( MODULE_ENTRY_T ) > Size ) {
        return 0;
    }

    Reader->Base       = Base;
    Reader->Size       = Size;
    Reader->Count      = Hdr->Count;
    Reader->EntryIndex = Hdr->EntryIndex;
    Reader->Table      = ( PMODULE_ENTRY_T )( Base + sizeof( *Hdr ) );
    return 1;
}

static int EntryToLookup( PBLOB_READER_T  Reader,
                          PMODULE_ENTRY_T E,
                          PBLOB_LOOKUP_T  Out ) {
    if ( ( size_t )E->DataOffset + E->DataLen > Reader->Size ) {
        return 0;
    }
    Out->Bytes    = Reader->Base + E->DataOffset;
    Out->BytesLen = E->DataLen;
    return 1;
}

int BlobReader_Find( PBLOB_READER_T Reader, const char *Name, PBLOB_LOOKUP_T Out ) {
    uint32_t I = { 0 };
    if ( Reader == NULL || Name == NULL || Out == NULL ) { return 0; }
    for ( I = 0; I < Reader->Count; I++ ) {
        PMODULE_ENTRY_T E = &Reader->Table[ I ];
        if ( E->NameOffset >= Reader->Size )                          { return 0; }
        const char *N = ( const char * )( Reader->Base + E->NameOffset );
        if ( strlen( N ) == E->NameLen && strcmp( N, Name ) == 0 ) {
            return EntryToLookup( Reader, E, Out );
        }
    }
    return 0;
}

int BlobReader_GetEntry( PBLOB_READER_T Reader, PBLOB_LOOKUP_T Out ) {
    if ( Reader == NULL || Out == NULL )                              { return 0; }
    return EntryToLookup( Reader, &Reader->Table[ Reader->EntryIndex ], Out );
}
