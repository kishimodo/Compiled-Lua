#ifndef LUAC_LINK_COFF_WRITE_H
#define LUAC_LINK_COFF_WRITE_H
#include <stddef.h>
#include "codegen/codegen.h"
/* Write one COFF object for the whole module to `path`. Returns 1 on success,
 * 0 + message in `err`. Layout per tests/unit/test_lc_coff_spike.c. */
int LcCoff_Write( const char *path, const LcCodeModule *cm, char *err, size_t errlen );
#endif
