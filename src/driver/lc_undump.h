#ifndef LUAC_DRIVER_LC_UNDUMP_H
#define LUAC_DRIVER_LC_UNDUMP_H
#include <stddef.h>
struct lua_State;
struct Proto;
/* Reconstruct a Proto* from dumped Lua 5.4 bytecode (mode "b"). The closure
 * wrapping it is left on L's stack and must stay there (don't pop) for the
 * Proto to remain alive. Returns NULL on load error. */
struct Proto *Lc_Undump( struct lua_State *L, const unsigned char *Bytes, size_t Len );
#endif
