/*!
 * @brief
 *  Minimal SHA-256 implementation, header-only, public-domain style.
 *  Used by both the compiler (compute build-time digest of embedded
 *  DLLs) and the runtime (verify on-disk DLL matches the embedded
 *  digest). The runtime's hash package wraps bcrypt CNG -- we don't
 *  reuse it because (a) the compiler doesn't link bcrypt today,
 *  and (b) the runtime call needs to happen BEFORE Lua state init
 *  where CNG isn't yet warmed up.
 */

#ifndef LUAVM_SHA256_LITE_H
#define LUAVM_SHA256_LITE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint32_t State[ 8 ];
    uint64_t BitLen;
    uint32_t DataLen;
    uint8_t  Data[ 64 ];
} SHA256_LITE_CTX_T;

static const uint32_t SHA256_LITE_K[ 64 ] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static inline uint32_t SHA256_LITE_ROTR( uint32_t X, unsigned N ) {
    return ( X >> N ) | ( X << ( 32 - N ) );
}

static void Sha256Lite_Transform( SHA256_LITE_CTX_T *Ctx, const uint8_t *Data ) {
    uint32_t W[ 64 ] = { 0 };
    uint32_t A, B, C, D, E, F, G, H, T1, T2;
    for ( int I = 0; I < 16; I++ ) {
        W[ I ] = ( ( uint32_t )Data[ I * 4 ] << 24 ) |
                 ( ( uint32_t )Data[ I * 4 + 1 ] << 16 ) |
                 ( ( uint32_t )Data[ I * 4 + 2 ] << 8 ) |
                 ( uint32_t )Data[ I * 4 + 3 ];
    }
    for ( int I = 16; I < 64; I++ ) {
        uint32_t S0 = SHA256_LITE_ROTR( W[ I - 15 ], 7 ) ^ SHA256_LITE_ROTR( W[ I - 15 ], 18 ) ^ ( W[ I - 15 ] >> 3 );
        uint32_t S1 = SHA256_LITE_ROTR( W[ I - 2 ], 17 ) ^ SHA256_LITE_ROTR( W[ I - 2 ], 19 ) ^ ( W[ I - 2 ] >> 10 );
        W[ I ] = W[ I - 16 ] + S0 + W[ I - 7 ] + S1;
    }
    A = Ctx->State[ 0 ]; B = Ctx->State[ 1 ]; C = Ctx->State[ 2 ]; D = Ctx->State[ 3 ];
    E = Ctx->State[ 4 ]; F = Ctx->State[ 5 ]; G = Ctx->State[ 6 ]; H = Ctx->State[ 7 ];
    for ( int I = 0; I < 64; I++ ) {
        uint32_t S1 = SHA256_LITE_ROTR( E, 6 ) ^ SHA256_LITE_ROTR( E, 11 ) ^ SHA256_LITE_ROTR( E, 25 );
        uint32_t Ch = ( E & F ) ^ ( ~E & G );
        T1 = H + S1 + Ch + SHA256_LITE_K[ I ] + W[ I ];
        uint32_t S0 = SHA256_LITE_ROTR( A, 2 ) ^ SHA256_LITE_ROTR( A, 13 ) ^ SHA256_LITE_ROTR( A, 22 );
        uint32_t Maj = ( A & B ) ^ ( A & C ) ^ ( B & C );
        T2 = S0 + Maj;
        H = G; G = F; F = E; E = D + T1;
        D = C; C = B; B = A; A = T1 + T2;
    }
    Ctx->State[ 0 ] += A; Ctx->State[ 1 ] += B; Ctx->State[ 2 ] += C; Ctx->State[ 3 ] += D;
    Ctx->State[ 4 ] += E; Ctx->State[ 5 ] += F; Ctx->State[ 6 ] += G; Ctx->State[ 7 ] += H;
}

static inline void Sha256Lite_Init( SHA256_LITE_CTX_T *Ctx ) {
    Ctx->DataLen = 0;
    Ctx->BitLen  = 0;
    Ctx->State[ 0 ] = 0x6a09e667; Ctx->State[ 1 ] = 0xbb67ae85;
    Ctx->State[ 2 ] = 0x3c6ef372; Ctx->State[ 3 ] = 0xa54ff53a;
    Ctx->State[ 4 ] = 0x510e527f; Ctx->State[ 5 ] = 0x9b05688c;
    Ctx->State[ 6 ] = 0x1f83d9ab; Ctx->State[ 7 ] = 0x5be0cd19;
}

static inline void Sha256Lite_Update( SHA256_LITE_CTX_T *Ctx, const uint8_t *Data, size_t Len ) {
    for ( size_t I = 0; I < Len; I++ ) {
        Ctx->Data[ Ctx->DataLen++ ] = Data[ I ];
        if ( Ctx->DataLen == 64 ) {
            Sha256Lite_Transform( Ctx, Ctx->Data );
            Ctx->BitLen += 512;
            Ctx->DataLen = 0;
        }
    }
}

static inline void Sha256Lite_Final( SHA256_LITE_CTX_T *Ctx, uint8_t Out[ 32 ] ) {
    uint32_t I = Ctx->DataLen;
    if ( I < 56 ) {
        Ctx->Data[ I++ ] = 0x80;
        while ( I < 56 ) Ctx->Data[ I++ ] = 0;
    } else {
        Ctx->Data[ I++ ] = 0x80;
        while ( I < 64 ) Ctx->Data[ I++ ] = 0;
        Sha256Lite_Transform( Ctx, Ctx->Data );
        memset( Ctx->Data, 0, 56 );
    }
    Ctx->BitLen += ( uint64_t )Ctx->DataLen * 8;
    Ctx->Data[ 63 ] = ( uint8_t )( Ctx->BitLen );
    Ctx->Data[ 62 ] = ( uint8_t )( Ctx->BitLen >> 8 );
    Ctx->Data[ 61 ] = ( uint8_t )( Ctx->BitLen >> 16 );
    Ctx->Data[ 60 ] = ( uint8_t )( Ctx->BitLen >> 24 );
    Ctx->Data[ 59 ] = ( uint8_t )( Ctx->BitLen >> 32 );
    Ctx->Data[ 58 ] = ( uint8_t )( Ctx->BitLen >> 40 );
    Ctx->Data[ 57 ] = ( uint8_t )( Ctx->BitLen >> 48 );
    Ctx->Data[ 56 ] = ( uint8_t )( Ctx->BitLen >> 56 );
    Sha256Lite_Transform( Ctx, Ctx->Data );
    for ( int J = 0; J < 8; J++ ) {
        Out[ J * 4 + 0 ] = ( uint8_t )( Ctx->State[ J ] >> 24 );
        Out[ J * 4 + 1 ] = ( uint8_t )( Ctx->State[ J ] >> 16 );
        Out[ J * 4 + 2 ] = ( uint8_t )( Ctx->State[ J ] >> 8 );
        Out[ J * 4 + 3 ] = ( uint8_t )( Ctx->State[ J ] );
    }
}

static inline void Sha256Lite_Hash( const void *Data, size_t Len, uint8_t Out[ 32 ] ) {
    SHA256_LITE_CTX_T Ctx;
    Sha256Lite_Init( &Ctx );
    Sha256Lite_Update( &Ctx, ( const uint8_t * )Data, Len );
    Sha256Lite_Final( &Ctx, Out );
}

#endif /* LUAVM_SHA256_LITE_H */
