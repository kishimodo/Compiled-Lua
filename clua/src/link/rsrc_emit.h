/*
** rsrc_emit.h -- build the PE .rsrc section blob (VS_VERSION_INFO, RT_MANIFEST,
** optional RT_GROUP_ICON + RT_ICON).
**
** The .rsrc section holds a three-level tree:
**   Type   -> Name -> Language -> DataEntry -> (raw bytes)
** encoded per the Microsoft PE spec's IMAGE_RESOURCE_DIRECTORY layout.
**
** Callers pass raw resource payloads (already-serialized VS_VERSION_INFO blob,
** manifest UTF-8 XML, .ico bytes) and this module builds a single relocatable
** .rsrc blob whose data entries carry RVAs relative to the section's own base
** (`rsrc_rva` supplied at build time). The blob has no relocations of its
** own -- everything is section-relative -- so the outer linker just concatenates
** it into the OS_RSRC output section and populates the RESOURCE data directory.
*/
#ifndef LUAC_LINK_RSRC_EMIT_H
#define LUAC_LINK_RSRC_EMIT_H

#include <stddef.h>
#include <stdint.h>

/* One resource entry to embed. `type_id` is a standard RT_* code (see the
** RT_* macros below). `name_id` disambiguates multiple resources of the same
** type; VS_VERSION_INFO conventionally uses 1, RT_MANIFEST for an EXE uses
** the special value 1 (CREATEPROCESS_MANIFEST_RESOURCE_ID). For icons, the
** RT_GROUP_ICON entry uses `name_id=1` and each RT_ICON gets a distinct id
** starting from 1. */
typedef struct LcRsrcEntry {
    uint16_t       type_id;      /* RT_VERSION / RT_MANIFEST / RT_GROUP_ICON / RT_ICON */
    uint16_t       name_id;
    uint16_t       lang_id;      /* 0x0409 = US English, 0 = neutral       */
    const uint8_t *data;         /* payload bytes (not owned)              */
    uint32_t       size;         /* payload length                          */
} LcRsrcEntry;

/* Standard PE resource type IDs. */
#define LC_RT_ICON       3
#define LC_RT_GROUP_ICON 14
#define LC_RT_VERSION    16
#define LC_RT_MANIFEST   24

/* Build the .rsrc section content. `rsrc_rva` is the RVA the outer linker
** has assigned to the section; every OffsetToData in the data entries is
** written as `rsrc_rva + <internal offset>` so the loader can resolve it
** directly. Returns 1 on success and hands ownership of a malloc'd buffer
** (out_bytes / *out_len) to the caller; 0 on failure. */
int LcRsrc_Build( const LcRsrcEntry *entries, size_t nentries,
                  uint32_t rsrc_rva,
                  uint8_t **out_bytes, size_t *out_len,
                  char *err, size_t errlen );

/* Build a VS_VERSION_INFO binary blob from the supplied field strings.
** Any string may be NULL / empty; the writer supplies a documented default.
**
**   file_version_str, product_version_str  -- like "0.3.0.4" (4-part), used
**     both in the fixed VS_FIXEDFILEINFO 64-bit versions and in the string
**     table. If the string is not parseable, the fixed fields go to 0.
**   product_name, file_description, company_name, legal_copyright,
**   internal_name, original_filename -- StringFileInfo entries (UTF-16LE).
**   lang_id -- typically 0x0409 (US English)
**   codepage -- typically 0x04B0 (1200 = Unicode)
**
** Returns 1 on success; the malloc'd blob is written to (*out, *out_len).
** 0 on failure with a message in err. */
int LcRsrc_BuildVersionInfo( const char *file_version_str,
                             const char *product_version_str,
                             const char *product_name,
                             const char *file_description,
                             const char *company_name,
                             const char *legal_copyright,
                             const char *internal_name,
                             const char *original_filename,
                             uint16_t    lang_id,
                             uint16_t    codepage,
                             uint8_t **out, size_t *out_len,
                             char *err, size_t errlen );

/* Return the default XML manifest (UTF-8, no BOM) that enables Win10/11
** compatibility, PerMonitorV2 DPI awareness, long path support, and UTF-8
** active code page. The returned pointer is a NUL-terminated static string;
** *out_len is set to its byte length excluding the terminator. */
void LcRsrc_DefaultManifest( const char **out, size_t *out_len );

/* Wrap `xml_bytes` (of length xml_len) as an RT_MANIFEST payload. The RT_MANIFEST
** resource stores the XML unchanged -- no BOM, no length prefix -- so this
** helper is a memcpy today; kept as a distinct entry point so a future
** normalization step (BOM strip, CRLF normalize) has one place to live.
** Returns 1 on success; hands ownership of a malloc'd buffer to the caller. */
int LcRsrc_BuildManifest( const uint8_t *xml_bytes, size_t xml_len,
                          uint8_t **out, size_t *out_len,
                          char *err, size_t errlen );

#endif /* LUAC_LINK_RSRC_EMIT_H */
