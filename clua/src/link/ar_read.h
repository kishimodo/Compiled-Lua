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
} LcArchive;

int  LcAr_Open( const char *path, LcArchive *out, char *err, size_t errlen );
void LcAr_Close( LcArchive *a );

/* Find the member that defines `sym` via the archive symbol index.
** Returns the member (by header offset match) or NULL. */
const LcArMember *LcAr_MemberDefining( const LcArchive *a, const char *sym );

/* Find a member by its header offset (the value stored in the symbol index). */
const LcArMember *LcAr_MemberByHdrOff( const LcArchive *a, uint32_t hdr_off );

#endif /* LUAC_LINK_AR_READ_H */
