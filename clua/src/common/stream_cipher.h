/*!
 * @brief
 *  Tiny symmetric stream cipher shared by the compiler (encrypts the
 *  emitted blob payload) and the runtime stub (decrypts in-place at
 *  startup). Implemented as a header-only inline pair so both build
 *  trees pull from the same source without a separate .c TU.
 *
 *  Threat model:
 *  ----------------------------------------------------------------
 *  The goal is to defeat `strings` and casual disassembly of the
 *  embedded Lua bytecode -- NOT to provide cryptographic
 *  confidentiality against a motivated reverse engineer. The 32-byte
 *  key lives in the blob header next to the ciphertext, so anyone
 *  with the binary plus this source can decrypt trivially. The win
 *  is that the cleartext (Lua string constants, embedded source for
 *  the unstripped path, module names) no longer appears in the PE
 *  at rest.
 *
 *  Construction:
 *  ----------------------------------------------------------------
 *  Four independent SplitMix64 streams are seeded from the four
 *  64-bit chunks of the 32-byte key and XOR-mixed each round to
 *  produce 64 bits of keystream per call. The keystream XORs the
 *  payload byte-by-byte; applying twice with the same key returns
 *  the original input, so the same routine encrypts and decrypts.
 */

#ifndef CLUA_COMMON_STREAM_CIPHER_H
#define CLUA_COMMON_STREAM_CIPHER_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct _STREAM_STATE {
    uint64_t S[ 4 ];
} STREAM_STATE_T, *PSTREAM_STATE_T;

static inline uint64_t StreamCipher_SplitMix64( uint64_t *X ) {
    uint64_t Z = ( *X += 0x9E3779B97F4A7C15ULL );
    Z = ( Z ^ ( Z >> 30 ) ) * 0xBF58476D1CE4E5B9ULL;
    Z = ( Z ^ ( Z >> 27 ) ) * 0x94D049BB133111EBULL;
    return Z ^ ( Z >> 31 );
}

static inline void StreamCipher_Init( PSTREAM_STATE_T S, const uint8_t Key[ 32 ] ) {
    memcpy( S->S, Key, 32 );
}

static inline uint64_t StreamCipher_NextU64( PSTREAM_STATE_T S ) {
    /* XOR-combine four independent SplitMix64 streams */
    uint64_t A = StreamCipher_SplitMix64( &S->S[ 0 ] );
    uint64_t B = StreamCipher_SplitMix64( &S->S[ 1 ] );
    uint64_t C = StreamCipher_SplitMix64( &S->S[ 2 ] );
    uint64_t D = StreamCipher_SplitMix64( &S->S[ 3 ] );
    return A ^ B ^ C ^ D;
}

/*!
 * @brief
 *  XOR Buf in place against keystream derived from Key. Symmetric:
 *  calling twice with the same key returns the original bytes.
 *  Safe to call with Len == 0.
 */
static inline void StreamCipher_Apply( const uint8_t Key[ 32 ],
                                       uint8_t      *Buf,
                                       size_t        Len ) {
    STREAM_STATE_T St = { { 0, 0, 0, 0 } };
    size_t         I  = 0;
    StreamCipher_Init( &St, Key );
    while ( I + 8 <= Len ) {
        uint64_t K = StreamCipher_NextU64( &St );
        Buf[ I + 0 ] ^= ( uint8_t )( K       );
        Buf[ I + 1 ] ^= ( uint8_t )( K >>  8 );
        Buf[ I + 2 ] ^= ( uint8_t )( K >> 16 );
        Buf[ I + 3 ] ^= ( uint8_t )( K >> 24 );
        Buf[ I + 4 ] ^= ( uint8_t )( K >> 32 );
        Buf[ I + 5 ] ^= ( uint8_t )( K >> 40 );
        Buf[ I + 6 ] ^= ( uint8_t )( K >> 48 );
        Buf[ I + 7 ] ^= ( uint8_t )( K >> 56 );
        I += 8;
    }
    if ( I < Len ) {
        uint64_t K = StreamCipher_NextU64( &St );
        size_t   J = 0;
        while ( I + J < Len ) {
            Buf[ I + J ] ^= ( uint8_t )( K >> ( J * 8 ) );
            J++;
        }
    }
}

#endif /* CLUA_COMMON_STREAM_CIPHER_H */
