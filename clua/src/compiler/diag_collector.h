/* diag_collector.h -- multi-error collector for the cross-module resolve
 * driver.
 *
 * The traditional compiler flow bails at the first parse failure: the user
 * fixes it, recompiles, and only then sees the next one. Real toolchains
 * accumulate diagnostics so a broken tree lands as one report.
 *
 * This structure is intentionally small: an ordered append-only list of
 * (path, message) pairs, plus a running count. Resolve_Walk pushes into it
 * whenever a per-module compile fails, then continues to the next module;
 * the driver drains the list at the end of resolve, prints each entry in
 * the standard rustc/clang shape, and fails the build if the count is
 * non-zero.
 *
 * All strings are copied in with strdup so the caller may free its own
 * transient buffers immediately after LcDiagCollector_Push returns.
 */
#ifndef CLUA_COMPILER_DIAG_COLLECTOR_H
#define CLUA_COMPILER_DIAG_COLLECTOR_H

#include <stddef.h>
#include "compiler/diag.h"

typedef struct _LC_DIAG_ENTRY {
    char *Path;    /* source file path, malloc'd (may be NULL for context-free) */
    char *Message; /* raw Lua loader error string, malloc'd */
} LC_DIAG_ENTRY_T, *PLC_DIAG_ENTRY_T;

typedef struct _LC_DIAG_COLLECTOR {
    PLC_DIAG_ENTRY_T Entries;
    size_t           Count;
    size_t           Cap;
} LC_DIAG_COLLECTOR_T, *PLC_DIAG_COLLECTOR_T;

/* Initialize an empty collector. Safe to call on a memset(&c,0,sizeof(c))
   struct too -- the free path handles Count==0 with a NULL array. */
void LcDiagCollector_Init( PLC_DIAG_COLLECTOR_T C );

/* Append one (path, message) pair. Both strings are copied. Silently drops
   the entry on OOM rather than crashing -- the resolve phase already fails
   the build via the non-zero count, and losing one message on OOM is a
   better failure mode than aborting mid-diagnostic. */
void LcDiagCollector_Push( PLC_DIAG_COLLECTOR_T C, const char *Path,
                           const char *Message );

/* Print every collected entry through Diag_PrintCompileError, in the order
   they were recorded. Returns the count so the caller can decide to fail. */
size_t LcDiagCollector_Drain( PLC_DIAG_COLLECTOR_T C, const DIAG_OPTS_T *Opts );

void LcDiagCollector_Free( PLC_DIAG_COLLECTOR_T C );

#endif /* CLUA_COMPILER_DIAG_COLLECTOR_H */
