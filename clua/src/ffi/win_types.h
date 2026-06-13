/*!
 * @brief
 *  Registers the standard set of Windows API typedefs (BYTE, WORD, DWORD,
 *  HANDLE, LPCSTR, etc.) into the ctype table. Call after Ctype_Init.
 */

#ifndef CLUA_FFI_WIN_TYPES_H
#define CLUA_FFI_WIN_TYPES_H

void Ffi_RegisterWindowsTypes( void );

#endif /* CLUA_FFI_WIN_TYPES_H */
