/* test_blob.c -- LVC1 blob writer: Blob_Build / Blob_FreeResult.
 * Exercises src/compiler/blob.c. */
#include "test_harness.h"
#include "compiler/blob.h"
#include "common/blob_format.h"

#include <string.h>

int main( void ) {
    TEST_BEGIN( "blob" );

    BLOB_MODULE_T       Mods[2]  = { 0 };
    BLOB_BUILD_RESULT_T Result   = { 0 };

    const unsigned char BytesA[4] = { 0xDE, 0xAD, 0xBE, 0xEF };
    const unsigned char BytesB[2] = { 0xAA, 0xBB };

    Mods[0].Name     = "main";
    Mods[0].Bytes    = BytesA;
    Mods[0].BytesLen = sizeof( BytesA );

    Mods[1].Name     = "lang.en";
    Mods[1].Bytes    = BytesB;
    Mods[1].BytesLen = sizeof( BytesB );

    /* Build returns non-zero on success. */
    CHECK_EQ_INT( Blob_Build( Mods, 2, 0, &Result ), 1 );
    CHECK_NOT_NULL( Result.Bytes );
    CHECK( Result.BytesLen > 0 );

    /* Validate header fields. */
    PLUAVM_BLOB_HEADER_T Hdr = (PLUAVM_BLOB_HEADER_T)Result.Bytes;
    CHECK_EQ_INT( (int)Hdr->Magic,      (int)LUAVM_BLOB_MAGIC );
    CHECK_EQ_INT( (int)Hdr->Version,    (int)LUAVM_BLOB_VERSION );
    CHECK_EQ_INT( (int)Hdr->Count,      2 );
    CHECK_EQ_INT( (int)Hdr->EntryIndex, 0 );
    CHECK_EQ_INT( (int)Hdr->TotalSize,  (int)Result.BytesLen );

    /* Module entry table follows the header. */
    PMODULE_ENTRY_T E = (PMODULE_ENTRY_T)( Result.Bytes + sizeof( *Hdr ) );

    /* Names round-trip via NameOffset. */
    CHECK_EQ_STR( (const char *)( Result.Bytes + E[0].NameOffset ), "main" );
    CHECK_EQ_STR( (const char *)( Result.Bytes + E[1].NameOffset ), "lang.en" );

    /* Payloads round-trip byte-for-byte. */
    CHECK_EQ_INT( (int)E[0].DataLen, 4 );
    CHECK_EQ_INT( memcmp( Result.Bytes + E[0].DataOffset, BytesA, 4 ), 0 );

    CHECK_EQ_INT( (int)E[1].DataLen, 2 );
    CHECK_EQ_INT( memcmp( Result.Bytes + E[1].DataOffset, BytesB, 2 ), 0 );

    /* EntryIndex 1 also works. */
    BLOB_BUILD_RESULT_T R2 = { 0 };
    CHECK_EQ_INT( Blob_Build( Mods, 2, 1, &R2 ), 1 );
    PLUAVM_BLOB_HEADER_T H2 = (PLUAVM_BLOB_HEADER_T)R2.Bytes;
    CHECK_EQ_INT( (int)H2->EntryIndex, 1 );
    Blob_FreeResult( &R2 );

    /* Single-module blob. */
    BLOB_BUILD_RESULT_T R3 = { 0 };
    CHECK_EQ_INT( Blob_Build( Mods, 1, 0, &R3 ), 1 );
    PLUAVM_BLOB_HEADER_T H3 = (PLUAVM_BLOB_HEADER_T)R3.Bytes;
    CHECK_EQ_INT( (int)H3->Count, 1 );
    Blob_FreeResult( &R3 );

    /* Invalid inputs: NULL modules or zero count. */
    CHECK_EQ_INT( Blob_Build( NULL, 2, 0, &Result ), 0 );
    CHECK_EQ_INT( Blob_Build( Mods, 0, 0, &Result ), 0 );

    Blob_FreeResult( &Result );
    TEST_END();
}
