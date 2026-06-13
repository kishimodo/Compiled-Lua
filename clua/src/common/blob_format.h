/*!
 * @brief
 *  On-disk layout of the bundled Lua modules embedded in every output.exe.
 *  Used by both the compiler (writer) and the runtime stub (reader).
 *
 *  Layout (v4):
 *      [ CLUA_BLOB_HEADER_T              ]
 *      [ MODULE_ENTRY_T  * Header.Count   ]
 *      [ name pool (NUL-separated chars)  ]
 *      [ bytecode payloads, back-to-back  ]
 *
 *  All offsets are relative to the start of the blob.
 *
 *  Flags = 0 means a plain unprocessed blob. The runtime examines Flags to
 *  decide which per-feature path (decrypt, integrity verify, decompress) to run.
 */

#ifndef CLUA_BLOB_FORMAT_H
#define CLUA_BLOB_FORMAT_H

#include <stdint.h>

#define CLUA_BLOB_MAGIC   0x424D564C   /* 'LVMB' little-endian */
#define CLUA_BLOB_VERSION 4

/* Header Flags bits. Compiler sets at build time per --flag; runtime
   reads at startup and runs the matching pass. All flags compose. */
#define CLUA_BLOB_FLAG_STRIPPED          0x00000001u  /* --strip: debug info dropped from bytecode */
#define CLUA_BLOB_FLAG_ENCRYPTED         0x00000002u  /* --encrypt: payload region needs decrypt-in-place at startup */
#define CLUA_BLOB_FLAG_LUA_VERSION_STRIP 0x00020000u  /* --lua-version-strip: runtime nils out _VERSION at startup */
#define CLUA_BLOB_FLAG_LUA_SANDBOX       0x00040000u  /* --lua-sandbox: runtime removes dangerous globals (os.execute, io.popen, loadfile, dofile, debug.*, package.loadlib) at startup */
#define CLUA_BLOB_FLAG_BYTECODE_ONLY     0x00080000u  /* --bytecode-only: parser/lexer/codegen excluded from link; loading source aborts */
#define CLUA_BLOB_FLAG_JIT_ONLY          0x00100000u  /* --jit-only: lvm.c interpreter excluded; any non-JIT-compilable function aborts */
#define CLUA_BLOB_FLAG_COMPRESS_PAYLOAD  0x00200000u  /* --compress-blob: payload XPRESS_HUFF compressed; runtime decompresses before BlobReader_Open */

#pragma pack( push, 1 )

typedef struct _CLUA_BLOB_HEADER {
    uint32_t Magic;             /* must equal CLUA_BLOB_MAGIC */
    uint32_t Version;           /* must equal CLUA_BLOB_VERSION */
    uint32_t Count;             /* number of modules */
    uint32_t EntryIndex;        /* index into ModuleEntry[] for the program entry */
    uint32_t TotalSize;         /* total blob size, header included, in bytes */
    uint32_t Flags;             /* CLUA_BLOB_FLAG_* bitmask; 0 for plain blobs */
    uint8_t  EncryptionKey[32]; /* stream-cipher key; zero unless ENCRYPTED */
} CLUA_BLOB_HEADER_T, *PCLUA_BLOB_HEADER_T;

typedef struct _MODULE_ENTRY {
    uint32_t NameOffset;   /* offset of NUL-terminated name within blob */
    uint32_t NameLen;      /* length of name, NUL excluded */
    uint32_t DataOffset;   /* offset of bytecode payload within blob */
    uint32_t DataLen;      /* length of bytecode payload in bytes */
} MODULE_ENTRY_T, *PMODULE_ENTRY_T;

#pragma pack( pop )

#endif /* CLUA_BLOB_FORMAT_H */
