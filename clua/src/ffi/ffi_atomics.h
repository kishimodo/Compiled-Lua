/*!
 * @brief
 *  Built-in atomic thunks for Interlocked* intrinsics.
 *
 *  On x64 Windows the Win32 Interlocked* functions (InterlockedExchange,
 *  InterlockedCompareExchange, etc.) are compiler intrinsics: they emit
 *  lock-prefixed machine instructions inline and are NOT exported by
 *  kernel32 or any system DLL, so GetProcAddress returns NULL for them.
 *
 *  This module provides real C implementations of all 16 variants that
 *  the built-in packages use, compiled with GCC __atomic builtins so
 *  the code is correct-by-construction (lock-prefixed on x64, sequentially
 *  consistent ordering).  Ffi_AtomicsLookup is called as a fallback in
 *  Ffi_LookupSymAcrossModules and Ffi_ResolveSymbol before the "not found"
 *  error fires.
 */

#ifndef LUAVM_FFI_ATOMICS_H
#define LUAVM_FFI_ATOMICS_H

/*!
 * @brief
 *  Return a pointer to the built-in atomic thunk that matches Sym, or
 *  NULL if Sym is not one of the supported Interlocked* names.
 */
void *Ffi_AtomicsLookup( const char *Sym );

#endif /* LUAVM_FFI_ATOMICS_H */
