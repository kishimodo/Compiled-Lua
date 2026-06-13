/*!
 * @brief
 *  Per-signature x64 thunk codegen. For each unique FuncT (ctype of kind
 *  CT_FUNC), Ffi_GetSignatureThunk produces a callable thunk whose contract is:
 *
 *      void Thunk( void *Fn, uint64_t *Args, uint64_t *Result );
 *
 *  The thunk's body places Args[i] into the appropriate Win64 ABI slot per
 *  the FuncT's parameter list (register/stack, GPR/XMM by position and type),
 *  calls Fn, and writes the result back to *Result as 8 raw bytes:
 *    - int/ptr/bool/enum return -> RAX value
 *    - float/double return       -> XMM0 reinterpreted via MOVQ
 *    - void return               -> *Result is left untouched
 */

#ifndef CLUA_FFI_THUNK_H
#define CLUA_FFI_THUNK_H

#include "ffi/ctype.h"

#include <stdint.h>

typedef void ( *FFI_THUNK_T )( void *Fn, uint64_t *Args, uint64_t *Result );

/*!
 * @brief
 *  Return the cached thunk for FuncT, generating one if necessary.
 *  Returns NULL if the signature is unsupported (e.g. struct-by-value, >16 args).
 */
FFI_THUNK_T Ffi_GetSignatureThunk( PCType_T FuncT );

/*!
 * @brief
 *  Test helper: reset the cache + slab. Lets unit tests start clean.
 *  Not for production use.
 */
void Ffi_ResetThunkCache( void );

#endif /* CLUA_FFI_THUNK_H */
