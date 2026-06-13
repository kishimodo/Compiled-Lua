/*!
 * @brief
 *  CData_T — boxed native value backed by a Lua full userdata. Allocated
 *  via FfiNewCData; detected via FfiGetCData / FfiIsCData; the shared
 *  metatable lives in the Lua registry under "ffi.cdata.mt".
 */

#ifndef CLUA_FFI_CDATA_H
#define CLUA_FFI_CDATA_H

#include "ffi/ctype.h"

#include "lua.h"

#include <stddef.h>
#include <stdint.h>

/* Flag bits on CData_T.Flags. */
#define CDATA_FLAG_OWNS_MEMORY   0x01   /* this CData allocated the storage and must free it on __gc */
#define CDATA_FLAG_IS_CONST      0x02   /* read-only */
#define CDATA_FLAG_IS_TYPEOF     0x04   /* ctype handle (ffi.typeof result), not a value */
#define CDATA_FLAG_BORROWED      0x08   /* storage is at .Ptr, lives in some other cdata; .Inline unused.
                                           Created for struct field / array element access of aggregate
                                           types so that `s.field.sub = v` writes propagate back to
                                           the parent. The parent cdata is held alive via uservalue
                                           slot 1 (lua_setiuservalue) to prevent GC while we point
                                           into its bytes. */

typedef struct _CData_T {
    PCType_T  Type;
    int       Flags;
    int       FlexN;             /* CT_ARRAY + IsFlex: runtime element count; 0 otherwise */
    union {
        void    *Ptr;
        int64_t  I64;
        double   F64;
        uint8_t  Inline[ 1 ];  /* tail-allocated for CT_STRUCT / CT_UNION / CT_ARRAY */
    };
} CData_T, *PCData_T;

#define CDATA_METATABLE_NAME "ffi.cdata.mt"

/* Registry key for the ffi.gc finalizer table: maps a cdata's userdata
   address (a lightuserdata key, which does NOT keep the cdata alive) to the
   Lua finalizer attached via ffi.gc(cd, fn). The shared cdata __gc handler
   looks the finalizer up here and invokes it when the cdata is collected. */
#define CDATA_GC_REGISTRY_KEY "ffi.cdata.gc"

/*!
 * @brief
 *  Register the shared cdata metatable in the Lua registry under
 *  CDATA_METATABLE_NAME. Idempotent. Called once during Ffi_OpenLib.
 */
void Cdata_RegisterMetatable( lua_State *L );

/*!
 * @brief
 *  Allocate a fresh CData wrapping Type. Pushes a full userdata onto L's
 *  stack and returns a pointer into it. The userdata size is sized to fit
 *  the type (inline payload for struct/union/array; scalar fits in the
 *  union). The shared cdata metatable is attached automatically. Returns
 *  NULL on allocation failure.
 *
 *  Initial flags: CDATA_FLAG_OWNS_MEMORY (caller can clear bits as needed).
 *  The inline payload (if any) is zero-initialised; Ptr/I64/F64 are also 0.
 */
PCData_T FfiNewCData( lua_State *L, PCType_T Type );

/*!
 * @brief
 *  Like FfiNewCData but allocates PayloadBytes of inline storage instead of
 *  using Type->Size. Used for VLA `T[?]` allocation where the payload size
 *  is only known at runtime. PayloadBytes must be >= 0.
 */
PCData_T FfiNewCDataN( lua_State *L, PCType_T Type, int PayloadBytes );

/*!
 * @brief
 *  Allocate a "borrowed" CData -- one whose storage lives at Storage,
 *  typically inside another cdata's Inline payload. The new cdata has
 *  CDATA_FLAG_BORROWED set, its `.Ptr` is Storage, and the parent at
 *  stack index ParentIdx (must be a valid stack index in L) is anchored
 *  on uservalue slot 1 of the new cdata so the parent isn't garbage-
 *  collected while we hold a reference into it.
 *
 *  Used by struct/union field access and array element access for
 *  aggregate-typed children so that `s.field.subfield = v` writes through
 *  to the parent's storage instead of dropping into a discarded copy.
 *
 *  Returns NULL on allocation failure.
 */
PCData_T FfiNewBorrowedCData( lua_State *L, PCType_T Type, void *Storage, int ParentIdx );

/*!
 * @brief
 *  Allocate a pointer-valued cdata (.Ptr = Ptr, kind from Type) that anchors
 *  the object at stack index SourceIdx in uservalue slot 1, keeping it alive
 *  while the pointer references its bytes. Used for ffi.cast(string -> a
 *  char or wchar_t pointer) so the derived pointer cannot dangle if the
 *  caller drops the source. Pass SourceIdx == 0 for no anchor; pushes onto L.
 */
PCData_T FfiNewAnchoredPtr( lua_State *L, PCType_T Type, void *Ptr, int SourceIdx );

/*!
 * @brief
 *  Returns the start address of a cdata's storage: .Inline for normal
 *  cdata, .Ptr for borrowed cdata. Use this everywhere instead of
 *  &Cd->Inline so borrowed cdata participate correctly in field access,
 *  struct→ptr marshalling, equality, etc.
 */
void *Cdata_Storage( PCData_T Cd );

/*!
 * @brief
 *  Returns the CData_T at stack index Idx, or NULL if the value is not a
 *  cdata (checked via metatable identity).
 */
PCData_T FfiGetCData( lua_State *L, int Idx );

/*!
 * @brief
 *  Returns 1 if the value at Idx is a cdata, 0 otherwise.
 */
int FfiIsCData( lua_State *L, int Idx );

#endif /* CLUA_FFI_CDATA_H */
