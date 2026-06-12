/*!
 * @brief
 *  Recursive-descent parser for cdef strings. Consumes a NUL-terminated
 *  C source fragment, populates the global ctype table. Errors are written
 *  to an internal buffer accessible via Cdecl_LastError().
 */

#ifndef LUAVM_FFI_CDECL_PARSER_H
#define LUAVM_FFI_CDECL_PARSER_H

#include "ffi/ctype.h"

/*!
 * @brief
 *  Parse Source. Returns 1 on success, 0 on parse error.
 *  On failure, Cdecl_LastError() returns a descriptive message.
 *  Side effect: registers named types in the global ctype table.
 */
int Cdecl_Parse( const char *Source );

/*!
 * @brief
 *  Returns the last parser error message (valid only after Cdecl_Parse
 *  returned 0). Format: "<message> at line N col C".
 */
const char *Cdecl_LastError( void );

/*!
 * @brief
 *  Parse a type expression (abstract declarator) and return its resolved
 *  ctype. Used by ffi.new("int*"), ffi.cast("DWORD", x), ffi.typeof("char[16]").
 *  Returns NULL on parse error; the error message is available via
 *  Cdecl_LastError().
 *
 *  Accepted forms: declspec, declspec*..., declspec[N], declspec[].
 *  Does NOT support function-type expressions or named declarators.
 */
PCType_T Cdecl_ParseTypeExpr( const char *Source );

#endif /* LUAVM_FFI_CDECL_PARSER_H */
