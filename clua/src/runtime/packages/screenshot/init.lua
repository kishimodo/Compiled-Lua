-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- screenshot -- screen / window / region capture to BGRA + PNG.
--
-- Public surface:
--   screenshot.screen(monitor?)          -> bytes, w, h    (BGRA top-down)
--   screenshot.monitor(index?)           -> bytes, w, h    (1-based; default = primary)
--   screenshot.window(hwnd)              -> bytes, w, h    (clientarea-relative)
--   screenshot.region(x, y, w, h)        -> bytes, w, h    (virtual-screen coords)
--   screenshot.save_png(path, bgra, w, h)
--
-- Capture path: BitBlt the source DC into a CreateCompatibleDC + a
-- CreateDIBSection that's been set up with a top-down 32-bit BGRA layout.
-- This avoids the bottom-up flip and palette lookup overhead of
-- GetDIBits, and matches what most consumers want.
--
-- PNG path: hand-rolled because we can't assume libpng on the host.
-- zlib's "stored block" mode (no compression) is legal PNG and lets us
-- skip the LZ77 dictionary -- the file is bigger but always decodes.
local W = require "windows"

ffi.cdef[[
/* user32 -- screen/window DCs */
typedef void *HDC;
typedef void *HBITMAP;
HDC     GetDC(HWND);
HDC     GetWindowDC(HWND);
int     ReleaseDC(HWND, HDC);
BOOL    GetClientRect(HWND, RECT *);
BOOL    GetWindowRect(HWND, RECT *);
int     GetSystemMetrics(int);
HWND    GetDesktopWindow(void);

/* gdi32 -- bitmap creation + bit blit */
HDC     CreateCompatibleDC(HDC);
BOOL    DeleteDC(HDC);
HBITMAP CreateCompatibleBitmap(HDC, int, int);
HBITMAP CreateDIBSection(HDC, void *pbmi, UINT iUsage, void **ppvBits, HANDLE hSection, DWORD dwOffset);
HANDLE  SelectObject(HDC, HANDLE);
BOOL    DeleteObject(HANDLE);
BOOL    BitBlt(HDC, int, int, int, int, HDC, int, int, DWORD);
BOOL    PrintWindow(HWND, HDC, UINT);

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

typedef struct tagBITMAPINFO {
    BITMAPINFOHEADER bmiHeader;
    DWORD            bmiColors[1];
} BITMAPINFO;
]]

pcall(ffi.load, "gdi32")
local C = ffi.C

-- ===== Constants ========================================================
local SRCCOPY        = 0x00CC0020
local CAPTUREBLT     = 0x40000000
local BI_RGB         = 0
local DIB_RGB_COLORS = 0

-- GetSystemMetrics indices for virtual-screen geometry. These return
-- the combined bounding box across all monitors (negative origins are
-- valid -- e.g. a second monitor placed to the left of the primary).
local SM_XVIRTUALSCREEN  = 76
local SM_YVIRTUALSCREEN  = 77
local SM_CXVIRTUALSCREEN = 78
local SM_CYVIRTUALSCREEN = 79

-- PrintWindow flag: render even off-screen / DWM-composited windows.
local PW_RENDERFULLCONTENT = 0x00000002

-- ===== Capture core =====================================================
-- Capture from the screen DC, using virtual-screen coordinates. The pixel
-- buffer is allocated as a DIBSection so we get direct CPU access at
-- ppvBits without a second copy.
local function capture(src_x, src_y, w, h, hwnd)
    local screen_dc = hwnd and C.GetWindowDC(hwnd) or C.GetDC(nil)
    if screen_dc == nil then error("GetDC failed") end
    local mem_dc = C.CreateCompatibleDC(screen_dc)
    if mem_dc == nil then C.ReleaseDC(nil, screen_dc); error("CreateCompatibleDC failed") end
    local bmi = ffi.new("BITMAPINFO[1]")
    bmi[0].bmiHeader.biSize        = ffi.sizeof("BITMAPINFOHEADER")
    bmi[0].bmiHeader.biWidth       = w
    bmi[0].bmiHeader.biHeight      = -h    -- negative = top-down
    bmi[0].bmiHeader.biPlanes      = 1
    bmi[0].bmiHeader.biBitCount    = 32
    bmi[0].bmiHeader.biCompression = BI_RGB
    local bits_pp = ffi.new("void*[1]")
    local hbmp = C.CreateDIBSection(mem_dc, bmi, DIB_RGB_COLORS, bits_pp, nil, 0)
    if hbmp == nil then
        C.DeleteDC(mem_dc); C.ReleaseDC(nil, screen_dc)
        error("CreateDIBSection failed")
    end
    local old = C.SelectObject(mem_dc, hbmp)
    -- CAPTUREBLT folds in layered windows; required to catch popups.
    local flags = SRCCOPY + CAPTUREBLT
    if hwnd then
        -- PrintWindow handles DWM redirection that BitBlt can't see.
        C.PrintWindow(hwnd, mem_dc, PW_RENDERFULLCONTENT)
    else
        C.BitBlt(mem_dc, 0, 0, w, h, screen_dc, src_x, src_y, flags)
    end
    local bytes = ffi.string(bits_pp[0], w * h * 4)
    C.SelectObject(mem_dc, old)
    C.DeleteObject(hbmp)
    C.DeleteDC(mem_dc)
    C.ReleaseDC(hwnd, screen_dc)
    return bytes, w, h
end

local M = {}

-- Whole virtual screen (every monitor, single bounding box).
function M.screen(monitor)
    if monitor and type(monitor) == "table" and monitor.rect then
        return capture(monitor.rect.x, monitor.rect.y,
                       monitor.rect.w, monitor.rect.h, nil)
    end
    local x = C.GetSystemMetrics(SM_XVIRTUALSCREEN)
    local y = C.GetSystemMetrics(SM_YVIRTUALSCREEN)
    local w = C.GetSystemMetrics(SM_CXVIRTUALSCREEN)
    local h = C.GetSystemMetrics(SM_CYVIRTUALSCREEN)
    return capture(x, y, w, h, nil)
end

function M.monitor(index)
    local display = require "display"
    local mons    = display.monitors()
    local idx     = index or 1
    -- Find the primary if no index supplied.
    if not index then
        for i, m in ipairs(mons) do
            if m.is_primary then idx = i break end
        end
    end
    local mon = mons[idx]
    if not mon then error("monitor index out of range") end
    return capture(mon.rect.x, mon.rect.y, mon.rect.w, mon.rect.h, nil)
end

function M.window(hwnd)
    local r = ffi.new("RECT[1]")
    if C.GetClientRect(hwnd, r) == 0 then error("GetClientRect failed") end
    local w = r[0].right - r[0].left
    local h = r[0].bottom - r[0].top
    return capture(0, 0, w, h, hwnd)
end

function M.region(x, y, w, h)
    return capture(x, y, w, h, nil)
end

-- ===== PNG encoder ======================================================
-- CRC-32 (poly 0xEDB88320). Table built lazily on first save_png call so
-- scripts that only capture (and pass bytes elsewhere) don't pay for it.
-- Uses LuaJIT's bit library throughout (band/bxor/rshift) -- the same
-- one every other CLua package relies on.
local bit_band  = bit.band
local bit_bxor  = bit.bxor
local bit_rsh   = bit.rshift

local _crc_table
local function build_crc_table()
    _crc_table = {}
    for n = 0, 255 do
        local c = n
        for _ = 1, 8 do
            if bit_band(c, 1) == 1 then
                c = bit_bxor(bit_rsh(c, 1), 0xEDB88320)
            else
                c = bit_rsh(c, 1)
            end
        end
        -- Normalise to unsigned 32-bit; LuaJIT's bit returns signed int.
        if c < 0 then c = c + 0x100000000 end
        _crc_table[n] = c
    end
end

local function crc32(data)
    if not _crc_table then build_crc_table() end
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        local idx = bit_band(bit_bxor(crc, data:byte(i)), 0xFF)
        crc = bit_bxor(bit_rsh(crc, 8), _crc_table[idx])
        if crc < 0 then crc = crc + 0x100000000 end
    end
    return bit_bxor(crc, 0xFFFFFFFF) % 0x100000000
end

-- Adler-32 (zlib checksum).
local function adler32(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local function u32_be(n)
    return string.char(
        math.floor(n / 0x1000000) % 256,
        math.floor(n / 0x10000) % 256,
        math.floor(n / 0x100) % 256,
        n % 256)
end

local function u32_le(n)
    return string.char(
        n % 256,
        math.floor(n / 0x100) % 256,
        math.floor(n / 0x10000) % 256,
        math.floor(n / 0x1000000) % 256)
end

local function u16_le(n)
    return string.char(n % 256, math.floor(n / 0x100) % 256)
end

-- Build a PNG IDAT payload using zlib's "stored" (BTYPE=00) blocks.
-- Each block: 1-byte header (BFINAL, BTYPE), 2-byte LEN LE, 2-byte ~LEN
-- LE, then LEN raw bytes. The PNG filter byte (00 = None) goes at the
-- start of each scanline.
local function deflate_stored(raw)
    local MAX = 65535  -- max LEN per stored block (uint16)
    local parts, np = {}, 0
    -- zlib stream header: CMF=0x78 (deflate, 32K window), FLG=0x01.
    np = np + 1; parts[np] = string.char(0x78, 0x01)
    local pos, len = 1, #raw
    while pos <= len do
        local chunk = math.min(MAX, len - pos + 1)
        local bfinal = (pos + chunk - 1 == len) and 1 or 0
        np = np + 1; parts[np] = string.char(bfinal)
        np = np + 1; parts[np] = u16_le(chunk)
        np = np + 1; parts[np] = u16_le(0xFFFF - chunk)  -- ~chunk
        np = np + 1; parts[np] = raw:sub(pos, pos + chunk - 1)
        pos = pos + chunk
    end
    np = np + 1; parts[np] = u32_be(adler32(raw))
    return table.concat(parts)
end

-- Wrap a payload + chunk type into a PNG chunk (length, type, data, crc).
local function png_chunk(typ, data)
    local crc = crc32(typ .. data)
    return u32_be(#data) .. typ .. data .. u32_be(crc)
end

-- BGRA -> RGBA conversion + per-row PNG filter byte. We rebuild the
-- pixel buffer with a 0x00 (filter None) byte prepended to every
-- scanline -- that's the on-wire format zlib gets fed.
local function bgra_to_filtered_rgba(bgra, w, h)
    local stride = w * 4
    local parts, np = {}, 0
    for y = 0, h - 1 do
        np = np + 1; parts[np] = "\0"   -- filter byte = None
        -- Walk this row, swap B<->R.
        local row_start = y * stride + 1  -- Lua is 1-indexed
        local row_end   = row_start + stride - 1
        -- We work byte-by-byte; for ~megapixel screenshots this loop
        -- runs into the tens of millions, so the hot path goes through
        -- string.char + table.concat rather than fragmented small concats.
        local row = {}
        local ri = 0
        for px = row_start, row_end, 4 do
            local b = bgra:byte(px)
            local g = bgra:byte(px + 1)
            local r = bgra:byte(px + 2)
            local a = bgra:byte(px + 3)
            ri = ri + 1; row[ri] = string.char(r, g, b, a)
        end
        np = np + 1; parts[np] = table.concat(row)
    end
    return table.concat(parts)
end

local function encode_png(bgra, w, h)
    local sig  = string.char(137, 80, 78, 71, 13, 10, 26, 10)  -- PNG magic
    local ihdr = u32_be(w) .. u32_be(h)
        .. string.char(8)   -- bit depth = 8
        .. string.char(6)   -- color type = 6 (RGBA)
        .. string.char(0)   -- compression = deflate
        .. string.char(0)   -- filter method = adaptive (default)
        .. string.char(0)   -- interlace = none
    local raw  = bgra_to_filtered_rgba(bgra, w, h)
    local idat = deflate_stored(raw)
    return sig
        .. png_chunk("IHDR", ihdr)
        .. png_chunk("IDAT", idat)
        .. png_chunk("IEND", "")
end

function M.save_png(path, bgra, w, h)
    local png = encode_png(bgra, w, h)
    local f, err = io.open(path, "wb")
    if not f then error("save_png: " .. tostring(err)) end
    f:write(png)
    f:close()
    return #png
end

-- Expose the encoder so callers can stream to a non-file sink (e.g. an
-- HTTP body) without going through the disk.
M.encode_png = encode_png

return M
