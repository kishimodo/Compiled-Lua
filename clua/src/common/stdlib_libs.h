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

#endif /* CLUA_STDLIB_LIBS_H */
