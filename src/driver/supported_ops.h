#ifndef LUAC_DRIVER_SUPPORTED_OPS_H
#define LUAC_DRIVER_SUPPORTED_OPS_H
#include <stddef.h>
struct Proto;
/* Returns 1 if every opcode in P (and nested protos) is implemented by the
 * current backend; 0 + a gcc-style message in Err naming the first
 * unsupported opcode otherwise. Keeps LuaC sound-conservative: programs the
 * backend can't yet compile correctly are REJECTED, never silently miscompiled. */
int Lc_CheckSupportedOps( struct Proto *P, char *Err, size_t ErrLen );
#endif
