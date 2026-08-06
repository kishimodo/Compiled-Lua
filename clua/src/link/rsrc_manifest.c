/*
** rsrc_manifest.c -- RT_MANIFEST wrapper + the default XML manifest.
**
** The RT_MANIFEST resource stores its UTF-8 XML unchanged -- no BOM, no
** length prefix. Windows fusion parses it directly from the resource data
** at PE load time.
**
** The default template enables Windows 10/11 compatibility (via the
** supportedOS GUID {8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}), PerMonitorV2
** DPI awareness, long path support, and UTF-8 active code page. The GUID
** is documented by Microsoft as the "Windows 10 and Windows 11" identifier;
** older Windows still loads the app but ignores the newer settings.
*/
#include "link/rsrc_emit.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char kDefaultManifest[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
    "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\r\n"
    "  <compatibility xmlns=\"urn:schemas-microsoft-com:compatibility.v1\">\r\n"
    "    <application>\r\n"
    "      <supportedOS Id=\"{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}\"/>\r\n"
    "    </application>\r\n"
    "  </compatibility>\r\n"
    "  <application xmlns=\"urn:schemas-microsoft-com:asm.v3\">\r\n"
    "    <windowsSettings>\r\n"
    "      <dpiAwareness xmlns=\"http://schemas.microsoft.com/SMI/2016/WindowsSettings\">PerMonitorV2</dpiAwareness>\r\n"
    "      <longPathAware xmlns=\"http://schemas.microsoft.com/SMI/2016/WindowsSettings\">true</longPathAware>\r\n"
    "      <activeCodePage xmlns=\"http://schemas.microsoft.com/SMI/2019/WindowsSettings\">UTF-8</activeCodePage>\r\n"
    "    </windowsSettings>\r\n"
    "  </application>\r\n"
    "</assembly>\r\n";

void LcRsrc_DefaultManifest( const char **out, size_t *out_len ) {
    if ( out ) *out = kDefaultManifest;
    if ( out_len ) *out_len = sizeof( kDefaultManifest ) - 1;
}

int LcRsrc_BuildManifest( const uint8_t *xml_bytes, size_t xml_len,
                          uint8_t **out, size_t *out_len,
                          char *err, size_t errlen ) {
    if ( out ) *out = NULL;
    if ( out_len ) *out_len = 0;
    if ( xml_bytes == NULL || xml_len == 0 ) {
        if ( err && errlen ) snprintf( err, errlen, "manifest: empty XML" );
        return 0;
    }

    /* If the XML starts with a UTF-8 BOM, strip it -- Windows fusion accepts
    ** either form but a bare no-BOM stream is what MSVC's rc.exe emits and
    ** what documented samples show. */
    const uint8_t *src = xml_bytes;
    size_t         n   = xml_len;
    if ( n >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF ) {
        src += 3; n -= 3;
    }

    uint8_t *buf = ( uint8_t * )malloc( n ? n : 1 );
    if ( buf == NULL ) {
        if ( err && errlen ) snprintf( err, errlen, "manifest: oom" );
        return 0;
    }
    memcpy( buf, src, n );
    *out = buf;
    *out_len = n;
    return 1;
}
