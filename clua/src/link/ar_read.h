/*
** ar_read.h — a reader for GNU `ar` archives (the .a static libraries the
** internal linker pulls objects and import members from).
**
** GNU archive layout:
**   "!<arch>\n" magic (8 bytes)
**   members, each: 60-byte header (name[16] mtime[12] uid[6] gid[6]
**     mode[8] size[10] "`\n"[2]) + data, padded to 2 bytes.
**   First special member "/ " : the symbol index (SysV/GNU form):
**     big-endian uint32 count, then `count` big-endian uint32 member-header
**     offsets, then `count` NUL-terminated symbol names.
**   Optional "// " member: the long-name table (names > 15 chars or with
**     spaces); a member header name of "/<dec>" indexes into it.
*/
#ifndef LUAC_LINK_AR_READ_H
#define LUAC_LINK_AR_READ_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    char           name[256]; /* resolved member name                       */
    const uint8_t *data;      /* into the owned archive buffer              */
    uint32_t       size;
    uint32_t       hdr_off;   /* offset of this member's 60-byte header     */
} LcArMember;

typedef struct {
    char        *symname;     /* NUL-terminated (into owned name pool)      */
    uint32_t     member_off;  /* archive offset of the defining member hdr  */
} LcArSym;

/* Lookup accounting. The internal linker resolves every undefined symbol
** against every archive in order, and re-scans the still-unresolved ones on
** each fixpoint round, so the number of NAME COMPARISONS is the quantity that
** actually predicts link time -- not the archive count and not the byte count.
** These are plain counters bumped on the lookup path (three adds against a
** strcmp walk, i.e. unmeasurable), reported by the linker under CLUA_GC_DEBUG.
** They live per-archive rather than in a global so nothing here becomes shared
** mutable state; see docs/benchmarks/archive-symbol-lookup.md. */
typedef struct {
    /* NOTE the unit: one "query" is one (symbol, archive) pair, i.e. one
    ** LcAr_MemberDefining call scanning ONE archive's index -- not one symbol
    ** resolution, which asks several archives in turn until one answers.
    ** Dividing compares by resolutions instead of by queries overstates the
    ** per-scan cost by roughly the archive count. */
    uint64_t     queries;      /* LcAr_MemberDefining calls                  */
    uint64_t     compares;     /* armap entries strcmp'd across those calls   */
    uint64_t     matched;      /* calls whose symbol NAME matched an entry     */
    uint64_t     hits;         /* calls that returned a member (matched, and  */
                               /*   the entry's member_off named a real one)   */
    uint64_t     mem_lookups;  /* LcAr_MemberByHdrOff calls                   */
    uint64_t     mem_compares; /* members scanned across those calls          */
} LcArStats;

typedef struct {
    uint8_t     *buf;         /* owned copy of the whole archive            */
    size_t       buf_len;
    LcArMember  *members;
    uint32_t     nmembers;
    LcArSym     *index;       /* symbol -> member-header-offset map         */
    uint32_t     nindex;
    char        *sympool;     /* owned; the index symbol names              */
    size_t       sympool_len;
    char         path[260];
    LcArStats    stats;       /* lookup accounting; see LcArStats            */

    /* Lazily built lookup indexes. Open-addressed, power-of-two capacity,
    ** linear probing. A slot holds an INDEX PLUS ONE into the array it indexes
    ** -- 0 is the empty sentinel -- never a pointer, and the key is re-read from
    ** that array on every probe, so a slot can never be silently stale.
    **
    ** state: 0 = not built yet, 1 = built, -1 = no index (empty or allocation
    ** failure) and lookups fall back to the linear scan, which stays in the file
    ** and stays correct.
    **
    ** Built on FIRST QUERY rather than in LcAr_Open, so an archive that is
    ** opened and never asked about pays nothing -- which matters because a link
    ** opens twelve archives and queries them unevenly. That makes the first
    ** lookup a WRITE: if a future change shares one LcArchive across threads,
    ** build the indexes before publishing the archive. */
    uint32_t    *sym_slots;      /* armap index + 1                          */
    uint32_t     sym_slot_cap;
    int          sym_index_state;
    uint32_t    *mem_slots;      /* member index + 1                        */
    uint32_t     mem_slot_cap;
    int          mem_index_state;
} LcArchive;

int  LcAr_Open( const char *path, LcArchive *out, char *err, size_t errlen );
void LcAr_Close( LcArchive *a );

/* Find the member that defines `sym` via the archive symbol index.
** Returns the member (by header offset match) or NULL.
**
** Takes a non-const archive because it updates `stats`. Every caller already
** owns a mutable archive, so this costs nothing and avoids casting const away. */
const LcArMember *LcAr_MemberDefining( LcArchive *a, const char *sym );

/* Find a member by its header offset (the value stored in the symbol index). */
const LcArMember *LcAr_MemberByHdrOff( LcArchive *a, uint32_t hdr_off );

#endif /* LUAC_LINK_AR_READ_H */
