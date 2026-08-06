/*!
 * @brief
 *  The set of OPTIONAL standard libraries an AOT exe can open selectively.
 *
 *  Bit i in a "used libs" mask corresponds to one luaopen_* / its weak anchor
 *  in runtime/stdlib_anchors.c. Shared by the optimizer scan that produces the
 *  mask (opt/passes.c, lc_module_used_libs) and the linker that force-undefs the
 *  matching anchors (link/pe_link_v2.c). base, package and coroutine are always
 *  opened and are not represented here.
 */

#ifndef CLUA_STDLIB_LIBS_H
#define CLUA_STDLIB_LIBS_H

#define LCLIB_STRING ( 1u << 0 )
#define LCLIB_TABLE  ( 1u << 1 )
#define LCLIB_MATH   ( 1u << 2 )
#define LCLIB_IO     ( 1u << 3 )
#define LCLIB_OS     ( 1u << 4 )
#define LCLIB_UTF8   ( 1u << 5 )
#define LCLIB_DEBUG  ( 1u << 6 )

/*!
 * @brief
 *  Every optional library. The mask's escape hatch, not a convenience.
 *
 *  The per-library bits are set by NAMING the library, which is only sound
 *  while a program cannot reach a library table it never named. Three shapes
 *  break that -- `_G[k]`, `package.loaded[k]`, and `debug.getregistry()` --
 *  and for those lc_module_used_libs() returns this instead of a guess. See
 *  the soundness argument on that function; do not add a bit here without
 *  extending that argument to cover it.
 */
#define LCLIB_ALL    ( ( 1u << 7 ) - 1u )

#endif /* CLUA_STDLIB_LIBS_H */
