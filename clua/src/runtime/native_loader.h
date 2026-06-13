/*!
 * @brief
 *  Per-build embedded native DLL bootstrap. The compiler synthesizes
 *  one native_refs.c per build that defines:
 *
 *      Native_GetEmbeddedDlls(size_t *count) -> table
 *
 *  At runtime startup, Native_Bootstrap walks that table, writes each
 *  DLL's bytes to a stable per-binary directory under %TEMP%, and
 *  prepends that directory to the DLL search path via
 *  SetDllDirectoryW so subsequent ffi.load() calls find the DLLs.
 *
 *  Packages that don't need any native deps get a stub
 *  Native_GetEmbeddedDlls returning (NULL, 0), and Native_Bootstrap
 *  is a no-op.
 */

#ifndef CLUA_NATIVE_LOADER_H
#define CLUA_NATIVE_LOADER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char          *Name;     /* e.g. "sqlite3.dll" */
    const unsigned char *Bytes;
    const unsigned int  *LenPtr;
    const unsigned char *Digest;   /* SHA-256, 32 bytes -- verified at extract time */
} EMBEDDED_NATIVE_DLL_T;

/* Defined by the per-build native_refs.o; a weak stub in
   native_loader.c returns (NULL, 0) when nothing is embedded. */
extern const EMBEDDED_NATIVE_DLL_T *Native_GetEmbeddedDlls( size_t *OutCount );

/* Extract every embedded DLL to a per-binary temp dir and prepend
   that dir to the DLL search path. Idempotent: re-running skips
   already-extracted files when size matches. */
void Native_Bootstrap( void );

#ifdef __cplusplus
}
#endif

#endif /* CLUA_NATIVE_LOADER_H */
