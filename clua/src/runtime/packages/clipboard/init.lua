-- clipboard -- Windows clipboard read/write.
--
-- Public surface:
--   clipboard.get_text()                  -> string | nil
--   clipboard.set_text(s)
--   clipboard.get_html()                  -> string | nil   (strips CF_HTML header)
--   clipboard.set_html(html)                                (wraps in CF_HTML header)
--   clipboard.get_files()                 -> { path, ... } | nil
--   clipboard.set_files(paths)            -- list of absolute paths
--   clipboard.get_image()                 -> { w, h, bytes } | nil   (BGRA, top-down)
--   clipboard.set_image(w, h, bgra)
--   clipboard.clear()
--   clipboard.is_empty()                  -> bool
--
-- All functions OpenClipboard / CloseClipboard internally. The clipboard
-- is acquired only for the duration of the call -- never held across
-- yields -- so other apps stay responsive even if a script polls fast.
local W = require "windows"

ffi.cdef[[
/* user32 -- clipboard core */
BOOL    OpenClipboard(HWND);
BOOL    CloseClipboard(void);
BOOL    EmptyClipboard(void);
HANDLE  GetClipboardData(UINT uFormat);
HANDLE  SetClipboardData(UINT uFormat, HANDLE hMem);
BOOL    IsClipboardFormatAvailable(UINT uFormat);
UINT    RegisterClipboardFormatW(LPCWSTR);
int     CountClipboardFormats(void);
UINT    EnumClipboardFormats(UINT);

/* kernel32 -- moveable global memory (clipboard handles must be HGLOBAL) */
HANDLE  GlobalAlloc(UINT uFlags, ULONGLONG dwBytes);
HANDLE  GlobalFree(HANDLE hMem);
LPVOID  GlobalLock(HANDLE hMem);
BOOL    GlobalUnlock(HANDLE hMem);
ULONGLONG GlobalSize(HANDLE hMem);

/* shell32 -- CF_HDROP unpack */
UINT    DragQueryFileW(HANDLE, UINT, LPWSTR, UINT);

/* gdi32 -- needed for image transcoding between CF_DIB and BGRA */
typedef struct tagBITMAPINFOHEADER {
    DWORD biSize;
    LONG  biWidth;
    LONG  biHeight;
    WORD  biPlanes;
    WORD  biBitCount;
    DWORD biCompression;
    DWORD biSizeImage;
    LONG  biXPelsPerMeter;
    LONG  biYPelsPerMeter;
    DWORD biClrUsed;
    DWORD biClrImportant;
} BITMAPINFOHEADER;

typedef struct tagDROPFILES {
    DWORD pFiles;   /* offset of file list */
    LONG  ptX;
    LONG  ptY;
    BOOL  fNC;
    BOOL  fWide;
} DROPFILES;
]]

pcall(ffi.load, "shell32")
pcall(ffi.load, "gdi32")

local C = ffi.C

-- ===== Clipboard format IDs =============================================
local CF_TEXT          = 1
local CF_BITMAP        = 2
local CF_DIB           = 8
local CF_UNICODETEXT   = 13
local CF_HDROP         = 15
local CF_DIBV5         = 17

-- GlobalAlloc flags
local GMEM_MOVEABLE    = 0x0002
local GMEM_ZEROINIT    = 0x0040
local GHND             = 0x0042  -- MOVEABLE | ZEROINIT

-- BITMAPINFOHEADER.biCompression
local BI_RGB           = 0

-- Lazily-registered CF_HTML format ID. RegisterClipboardFormatW returns
-- a process-wide ID -- safe to cache.
local _cf_html
local function html_fmt()
    if not _cf_html then
        local name = W.ToWide("HTML Format")
        _cf_html = C.RegisterClipboardFormatW(name)
    end
    return _cf_html
end

-- ===== Open/close helpers ================================================
-- Run `fn` while we hold the clipboard. The caller never has to remember
-- to close -- and any error gets the close anyway via pcall + rethrow.
local function with_clipboard(fn)
    if C.OpenClipboard(nil) == 0 then return nil, "OpenClipboard failed" end
    local ok, a, b = pcall(fn)
    C.CloseClipboard()
    if not ok then error(a, 2) end
    return a, b
end

-- Allocate a moveable HGLOBAL of `size` bytes and copy `src` (a cdata
-- pointer) into it. Returns the HGLOBAL handle -- ownership transfers to
-- SetClipboardData on success, so we deliberately do NOT GlobalFree.
local function alloc_hglobal(size, src)
    local h = C.GlobalAlloc(GHND, size)
    if h == nil then error("GlobalAlloc failed") end
    local p = C.GlobalLock(h)
    if p == nil then
        C.GlobalFree(h)
        error("GlobalLock failed")
    end
    if src ~= nil and size > 0 then
        ffi.copy(p, src, size)
    end
    C.GlobalUnlock(h)
    return h
end

-- ===== Text (CF_UNICODETEXT) ============================================
local M = {}

function M.get_text()
    return with_clipboard(function()
        if C.IsClipboardFormatAvailable(CF_UNICODETEXT) == 0 then return nil end
        local h = C.GetClipboardData(CF_UNICODETEXT)
        if h == nil then return nil end
        local p = C.GlobalLock(h)
        if p == nil then return nil end
        local out = W.FromWide(p)
        C.GlobalUnlock(h)
        return out
    end)
end

function M.set_text(s)
    if type(s) ~= "string" then error("set_text: expected string") end
    return with_clipboard(function()
        local wbuf, wlen = W.ToWide(s)
        local bytes = wlen * 2  -- WCHAR = 2 bytes; wlen includes null
        local h = alloc_hglobal(bytes, wbuf)
        C.EmptyClipboard()
        if C.SetClipboardData(CF_UNICODETEXT, h) == nil then
            C.GlobalFree(h)
            error("SetClipboardData failed")
        end
        return true
    end)
end

-- ===== HTML (CF_HTML) ===================================================
-- CF_HTML uses a documented ASCII header preceded by byte-offset markers
-- so that Word / Outlook / browsers can locate the actual fragment inside
-- a larger document. We always write the minimal valid form: a synthesised
-- document wrapping the user's fragment in <html><body>.

local function build_html_blob(html)
    -- We'll build the blob in two passes -- one to discover where the
    -- offsets land, one to fill them in. The offsets are fixed-width
    -- (10-digit decimal) so the second pass keeps lengths stable.
    local pre  = "<html><body><!--StartFragment-->"
    local post = "<!--EndFragment--></body></html>"
    local header_template =
        "Version:0.9\r\n" ..
        "StartHTML:%010d\r\n" ..
        "EndHTML:%010d\r\n" ..
        "StartFragment:%010d\r\n" ..
        "EndFragment:%010d\r\n"
    -- Compute lengths with placeholder zeros first to size the header.
    local dummy_hdr = string.format(header_template, 0, 0, 0, 0)
    local hdr_len   = #dummy_hdr
    local body      = pre .. html .. post
    local start_html     = hdr_len
    local start_fragment = hdr_len + #pre
    local end_fragment   = start_fragment + #html
    local end_html       = hdr_len + #body
    local hdr = string.format(header_template,
        start_html, end_html, start_fragment, end_fragment)
    return hdr .. body
end

local function strip_html_header(blob)
    -- Use the documented StartFragment / EndFragment markers -- comments
    -- in the body might (legitimately) contain HTML, so we trust the
    -- byte offsets in the header rather than text-search.
    local sf = blob:match("StartFragment:(%d+)")
    local ef = blob:match("EndFragment:(%d+)")
    if not sf or not ef then return blob end
    sf, ef = tonumber(sf), tonumber(ef)
    return blob:sub(sf + 1, ef)  -- +1: Lua is 1-indexed, offsets are 0-indexed
end

function M.get_html()
    return with_clipboard(function()
        local fmt = html_fmt()
        if C.IsClipboardFormatAvailable(fmt) == 0 then return nil end
        local h = C.GetClipboardData(fmt)
        if h == nil then return nil end
        local p   = C.GlobalLock(h)
        local sz  = C.GlobalSize(h)
        local out = ffi.string(p, sz)
        C.GlobalUnlock(h)
        -- The blob is ASCII-encoded UTF-8 per the CF_HTML spec.
        return strip_html_header(out)
    end)
end

function M.set_html(html)
    if type(html) ~= "string" then error("set_html: expected string") end
    return with_clipboard(function()
        local blob = build_html_blob(html)
        local h    = alloc_hglobal(#blob + 1, blob)
        C.EmptyClipboard()
        if C.SetClipboardData(html_fmt(), h) == nil then
            C.GlobalFree(h)
            error("SetClipboardData(CF_HTML) failed")
        end
        return true
    end)
end

-- ===== Files (CF_HDROP) =================================================
function M.get_files()
    return with_clipboard(function()
        if C.IsClipboardFormatAvailable(CF_HDROP) == 0 then return nil end
        local h = C.GetClipboardData(CF_HDROP)
        if h == nil then return nil end
        local count = C.DragQueryFileW(h, 0xFFFFFFFF, nil, 0)
        local files = {}
        local buf = ffi.new("unsigned short[1024]")
        for i = 0, count - 1 do
            local n = C.DragQueryFileW(h, i, buf, 1024)
            if n > 0 then files[#files + 1] = W.FromWide(buf) end
        end
        return files
    end)
end

function M.set_files(paths)
    if type(paths) ~= "table" then error("set_files: expected table") end
    return with_clipboard(function()
        -- Layout: DROPFILES header, then WCHAR strings with internal
        -- nulls between paths, then a final double-null terminator.
        local hdr_size = ffi.sizeof("DROPFILES")
        -- Sum WCHAR counts (each path + trailing null, plus final null).
        local total_wchars = 1  -- final extra null
        local wbufs = {}
        for i = 1, #paths do
            local wb, wl = W.ToWide(paths[i])
            wbufs[i] = { buf = wb, len = wl }  -- wl includes the null
            total_wchars = total_wchars + wl
        end
        local total_bytes = hdr_size + total_wchars * 2
        local hglob = C.GlobalAlloc(GHND, total_bytes)
        if hglob == nil then error("GlobalAlloc failed") end
        local p = C.GlobalLock(hglob)
        if p == nil then C.GlobalFree(hglob); error("GlobalLock failed") end
        local df = ffi.cast("DROPFILES*", p)
        df.pFiles = hdr_size
        df.fWide  = 1
        local cursor = ffi.cast("unsigned short*", ffi.cast("char*", p) + hdr_size)
        for i = 1, #paths do
            ffi.copy(cursor, wbufs[i].buf, wbufs[i].len * 2)
            cursor = cursor + wbufs[i].len
        end
        -- final terminator already zero thanks to GMEM_ZEROINIT
        C.GlobalUnlock(hglob)
        C.EmptyClipboard()
        if C.SetClipboardData(CF_HDROP, hglob) == nil then
            C.GlobalFree(hglob)
            error("SetClipboardData(CF_HDROP) failed")
        end
        return true
    end)
end

-- ===== Image (CF_DIB <-> BGRA) ==========================================
-- CF_DIB is a packed BITMAPINFOHEADER + optional palette + pixel rows.
-- For 32-bit BI_RGB there's no palette, so the pixel rows start at
-- sizeof(BITMAPINFOHEADER). DIBs are usually bottom-up (positive
-- biHeight); we flip on get/set so the caller always sees top-down BGRA.

function M.get_image()
    return with_clipboard(function()
        if C.IsClipboardFormatAvailable(CF_DIB) == 0 then return nil end
        local h = C.GetClipboardData(CF_DIB)
        if h == nil then return nil end
        local p = C.GlobalLock(h)
        if p == nil then return nil end
        local bih = ffi.cast("BITMAPINFOHEADER*", p)
        local w   = bih.biWidth
        local h_signed = bih.biHeight
        local h_abs    = h_signed < 0 and -h_signed or h_signed
        local bpp = bih.biBitCount
        if bpp ~= 32 then
            -- We only handle the BGRA case directly; other depths would
            -- require palette unpacking. The caller can request 32-bit by
            -- copying through a GDI HBITMAP, but for now we bail.
            C.GlobalUnlock(h)
            return nil
        end
        local stride   = w * 4
        local pixels   = ffi.cast("char*", bih) + bih.biSize
        local out      = ffi.new("char[?]", stride * h_abs)
        if h_signed > 0 then
            -- Bottom-up DIB: flip rows so caller gets top-down BGRA.
            for y = 0, h_abs - 1 do
                ffi.copy(out + y * stride,
                         pixels + (h_abs - 1 - y) * stride,
                         stride)
            end
        else
            ffi.copy(out, pixels, stride * h_abs)
        end
        C.GlobalUnlock(h)
        return {
            width  = w,
            height = h_abs,
            bytes  = ffi.string(out, stride * h_abs),
        }
    end)
end

function M.set_image(w, h, bgra)
    if type(bgra) ~= "string" then error("set_image: expected string bgra") end
    local stride = w * 4
    if #bgra < stride * h then error("set_image: buffer too small") end
    return with_clipboard(function()
        local bih_size = ffi.sizeof("BITMAPINFOHEADER")
        local total    = bih_size + stride * h
        local hglob    = C.GlobalAlloc(GHND, total)
        if hglob == nil then error("GlobalAlloc failed") end
        local p = C.GlobalLock(hglob)
        if p == nil then C.GlobalFree(hglob); error("GlobalLock failed") end
        local bih = ffi.cast("BITMAPINFOHEADER*", p)
        bih.biSize      = bih_size
        bih.biWidth     = w
        bih.biHeight    = -h    -- negative = top-down (matches our BGRA convention)
        bih.biPlanes    = 1
        bih.biBitCount  = 32
        bih.biCompression = BI_RGB
        bih.biSizeImage = stride * h
        local dst = ffi.cast("char*", bih) + bih_size
        ffi.copy(dst, bgra, stride * h)
        C.GlobalUnlock(hglob)
        C.EmptyClipboard()
        if C.SetClipboardData(CF_DIB, hglob) == nil then
            C.GlobalFree(hglob)
            error("SetClipboardData(CF_DIB) failed")
        end
        return true
    end)
end

-- ===== Misc =============================================================
function M.clear()
    return with_clipboard(function()
        C.EmptyClipboard()
        return true
    end)
end

function M.is_empty()
    return with_clipboard(function()
        return C.CountClipboardFormats() == 0
    end)
end

function M.has_format(fmt_id)
    -- Escape hatch: lets callers probe for arbitrary formats they may
    -- have registered themselves (e.g. CF_RTF via RegisterClipboardFormat).
    return with_clipboard(function()
        return C.IsClipboardFormatAvailable(fmt_id) ~= 0
    end)
end

-- Format ID exports for callers who need to feed `has_format`.
M.CF_TEXT        = CF_TEXT
M.CF_BITMAP      = CF_BITMAP
M.CF_DIB         = CF_DIB
M.CF_UNICODETEXT = CF_UNICODETEXT
M.CF_HDROP       = CF_HDROP

return M
