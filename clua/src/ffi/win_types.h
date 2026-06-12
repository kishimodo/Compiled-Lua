/*!
 * @brief
 *  Registers the standard set of Windows API typedefs (BYTE, WORD, DWORD,
 *  HANDLE, LPCSTR, etc.) into the ctype table. Call after Ctype_Init.
 */

#ifndef LUAVM_FFI_WIN_TYPES_H
#define LUAVM_FFI_WIN_TYPES_H

void Ffi_RegisterWindowsTypes( void );

#endif /* LUAVM_FFI_WIN_TYPES_H */
