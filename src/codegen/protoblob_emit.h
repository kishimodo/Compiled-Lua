/* protoblob_emit.h — serialize an LcModule's Protos into the LCPB blob.
**
** Successor to protoinit_emit.h's generated-C path: the blob goes into the
** user COFF's .rdata (with a relocated luac_fn_table) and is rebuilt at
** startup by src/runtime/protoinit_rt.c — no generated C, no compiler
** invocation at user-build time. Format: src/runtime/protoblob_format.h.
*/
#ifndef LUAC_PROTOBLOB_EMIT_H
#define LUAC_PROTOBLOB_EMIT_H

#include "../ir/ir.h"
#include <stddef.h>

/* Build the blob for module m. On success returns 1 and hands the caller a
** malloc'd buffer (*out, *out_len) — the caller owns it (the driver attaches
** it to the LcCodeModule, freed by lc_codemodule_free). On failure returns 0
** with a message in err. */
int LcBuildProtoBlob( LcModule *m, unsigned char **out, size_t *out_len,
                      char *err, size_t errlen );

#endif /* LUAC_PROTOBLOB_EMIT_H */
