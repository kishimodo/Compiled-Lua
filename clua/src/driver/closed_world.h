#ifndef LUAC_DRIVER_CLOSED_WORLD_H
#define LUAC_DRIVER_CLOSED_WORLD_H
#include <stddef.h>
struct Proto;
/* Returns 1 if P (and all nested protos) are closed-world-safe; 0 + writes a
 * gcc-style message into Err otherwise. */
int Lc_CheckClosedWorld( struct Proto *P, char *Err, size_t ErrLen );
#endif
