/* test_blob_reader.c -- LVC1 blob reader round-trips what the writer produced.
 * Exercises src/runtime/blob_reader.c with blobs built by compiler/blob.c. */
#include "test_harness.h"
#include "compiler/blob.h"
#include "runtime/blob_reader.h"

#include <string.h>

int main( void ) {
    TEST_BEGIN( "blob_reader" );

    BLOB_MODULE_T       Mods[2] = { 0 };
    BLOB_BUILD_RESULT_T Built   = { 0 };
    BLOB_READER_T       Reader  = { 0 };
    BLOB_LOOKUP_T       Found   = { 0 };

    const unsigned char A[3] = { 1, 2, 3 };
    const unsigned char B[5] = { 4, 5, 6, 7, 8 };

    Mods[0].Name     = "main";
    Mods[0].Bytes    = A;
    Mods[0].BytesLen = sizeof( A );

    Mods[1].Name     = "util.x";
    Mods[1].Bytes    = B;
    Mods[1].BytesLen = sizeof( B );

    CHECK_EQ_INT( Blob_Build( Mods, 2, 0, &Built ), 1 );

    /* Open the reader on the valid blob. */
    CHECK_EQ_INT( BlobReader_Open( Built.Bytes, Built.BytesLen, &Reader ), 1 );
    CHECK_EQ_INT( (int)Reader.Count,      2 );
    CHECK_EQ_INT( (int)Reader.EntryIndex, 0 );
    CHECK_NOT_NULL( (void *)Reader.Base );

    /* Find "main" by name. */
    CHECK_EQ_INT( BlobReader_Find( &Reader, "main", &Found ), 1 );
    CHECK_EQ_INT( (int)Found.BytesLen, 3 );
    CHECK_EQ_INT( memcmp( Found.Bytes, A, 3 ), 0 );

    /* Find "util.x" by name. */
    CHECK_EQ_INT( BlobReader_Find( &Reader, "util.x", &Found ), 1 );
    CHECK_EQ_INT( (int)Found.BytesLen, 5 );
    CHECK_EQ_INT( memcmp( Found.Bytes, B, 5 ), 0 );

    /* Missing name returns 0. */
    CHECK_EQ_INT( BlobReader_Find( &Reader, "missing", &Found ), 0 );

    /* GetEntry returns the entry module's bytes (index 0 = "main"). */
    BLOB_LOOKUP_T Entry = { 0 };
    CHECK_EQ_INT( BlobReader_GetEntry( &Reader, &Entry ), 1 );
    CHECK_EQ_INT( (int)Entry.BytesLen, 3 );
    CHECK_EQ_INT( memcmp( Entry.Bytes, A, 3 ), 0 );

    /* Build blob with entry = 1 and verify GetEntry returns "util.x". */
    BLOB_BUILD_RESULT_T B2 = { 0 };
    CHECK_EQ_INT( Blob_Build( Mods, 2, 1, &B2 ), 1 );
    BLOB_READER_T R2 = { 0 };
    CHECK_EQ_INT( BlobReader_Open( B2.Bytes, B2.BytesLen, &R2 ), 1 );
    CHECK_EQ_INT( (int)R2.EntryIndex, 1 );
    BLOB_LOOKUP_T E2 = { 0 };
    CHECK_EQ_INT( BlobReader_GetEntry( &R2, &E2 ), 1 );
    CHECK_EQ_INT( (int)E2.BytesLen, 5 );
    CHECK_EQ_INT( memcmp( E2.Bytes, B, 5 ), 0 );
    Blob_FreeResult( &B2 );

    /* Corrupt the magic -> Open returns 0. */
    Built.Bytes[0] ^= 0xFF;
    CHECK_EQ_INT( BlobReader_Open( Built.Bytes, Built.BytesLen, &Reader ), 0 );

    /* NULL inputs -> returns 0. */
    CHECK_EQ_INT( BlobReader_Open( NULL, Built.BytesLen, &Reader ), 0 );
    CHECK_EQ_INT( BlobReader_Open( Built.Bytes, 0, &Reader ), 0 );

    Blob_FreeResult( &Built );
    TEST_END();
}
