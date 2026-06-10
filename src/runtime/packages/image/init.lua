-- image -- image decode / encode wrapper.
--
-- Backends are picked in this order on each call:
--   1. windowscodecs.dll (WIC) via the `wic` sub-package
--   2. stb_image.dll if it happens to be loadable from PATH
--   3. pure-Lua BMP decoder + pure-Lua "stored block" PNG (uncompressed)
--
-- All public functions hand back the same in-memory representation, which
-- the rest of the runtime treats as a "raw image":
--   {
--     width   = w,
--     height  = h,
--     channels = 1|3|4,            -- 1 = gray, 3 = rgb (24bpp), 4 = rgba/bgra
--     order    = "rgba"|"bgra"|"rgb"|"bgr"|"gray",
--     pixels   = string,           -- row-major, top-down, width*height*channels bytes
--   }
--
-- Public surface:
--   image.decode(bytes_or_path, opts?)        -> image
--   image.encode(image, format, opts?)        -> string             -- "png"|"jpg"|"bmp"|"tga"
--   image.load(path, opts?)                   -> image
--   image.save(image, path, opts?)            -> nothing            -- format inferred from ext
--   image.from_pixels(pixels, w, h, channels) -> image
--   image.convert(image, target_channels)     -> image
--   image.resize(image, w, h, opts?)          -> image              -- nearest | bilinear
--   image.crop(image, x, y, w, h)             -> image
--   image.flip(image, axis)                   -> image              -- "x" | "y"
--   image.formats()                           -> { read=..., write=... }
--   image.backends()                          -> { wic=bool, stb=bool }

local ffi = ffi
local W   = require "windows"

local M = {}

-- ===== Optional WIC backend ============================================
local _wic_ok, _wic = pcall(require, "wic")
if not _wic_ok then _wic = nil end

local function have_wic()
    return _wic ~= nil
end

-- ===== Optional stb_image backend ======================================
-- We only cdef the surface lazily so that requiring the image package
-- never trips an ffi.cdef redefinition error on hosts that have no DLL.
local _stb
local _stb_tried
local function load_stb()
    if _stb_tried then return _stb end
    _stb_tried = true
    local ok, lib = pcall(ffi.load, "stb_image")
    if not ok then
        ok, lib = pcall(ffi.load, "stbi")
        if not ok then return nil end
    end
    pcall(ffi.cdef, [[
        unsigned char *stbi_load_from_memory(const unsigned char *buffer, int len,
                                             int *x, int *y, int *channels_in_file,
                                             int desired_channels);
        unsigned char *stbi_load(const char *filename,
                                 int *x, int *y, int *channels_in_file,
                                 int desired_channels);
        void           stbi_image_free(void *retval);
        int            stbi_write_png(const char *filename, int w, int h, int comp,
                                      const void *data, int stride_in_bytes);
        int            stbi_write_bmp(const char *filename, int w, int h, int comp, const void *data);
        int            stbi_write_tga(const char *filename, int w, int h, int comp, const void *data);
        int            stbi_write_jpg(const char *filename, int w, int h, int comp, const void *data, int quality);
        const char    *stbi_failure_reason(void);
    ]])
    _stb = lib
    return lib
end

-- ===== Helpers =========================================================

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

local function looks_like_path(s)
    if type(s) ~= "string" then return false end
    if #s == 0 or #s > 1024 then return false end
    if s:find("\0", 1, true) then return false end
    -- A path generally won't contain raw control bytes other than NUL,
    -- but to keep the heuristic cheap we only reject NULs and obvious
    -- binary signatures.
    local h = s:sub(1, 8)
    if h:sub(1, 8) == "\137PNG\r\n\26\n" then return false end
    if h:sub(1, 2) == "\255\216"          then return false end  -- JPEG SOI
    if h:sub(1, 2) == "BM"                then return false end  -- BMP
    if h:sub(1, 6) == "GIF87a"            then return false end
    if h:sub(1, 6) == "GIF89a"            then return false end
    if h:sub(1, 4) == "RIFF"              then return false end
    if h:sub(1, 4) == "II*\0" or h:sub(1, 4) == "MM\0*" then return false end
    return true
end

-- ===== Pure-Lua BMP decoder ============================================
--
-- Handles the most common subset of BMP: 24bpp BI_RGB and 32bpp BI_RGB /
-- BI_BITFIELDS. The format ships row-padded to 4 bytes and bottom-up
-- (positive biHeight) or top-down (negative biHeight).

local function u32le(s, i) return (s:byte(i)) + (s:byte(i+1)*256) + (s:byte(i+2)*65536) + (s:byte(i+3)*16777216) end
local function s32le(s, i)
    local v = u32le(s, i)
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end
local function u16le(s, i) return (s:byte(i)) + (s:byte(i+1)*256) end

local function decode_bmp(data)
    if #data < 54 then return nil, "bmp: header too short" end
    if data:sub(1, 2) ~= "BM" then return nil, "bmp: bad magic" end
    local off_pixels = u32le(data, 11)
    local hdr_size   = u32le(data, 15)
    local width      = s32le(data, 19)
    local height     = s32le(data, 23)
    local bpp        = u16le(data, 29)
    local compression = u32le(data, 31)
    if bpp ~= 24 and bpp ~= 32 then
        return nil, "bmp: only 24bpp / 32bpp supported (got " .. bpp .. ")"
    end
    if compression ~= 0 and compression ~= 3 then
        return nil, "bmp: only BI_RGB / BI_BITFIELDS supported"
    end
    local channels   = bpp // 8
    local row_bytes  = ((width * bpp + 31) // 32) * 4
    local out_stride = width * channels
    local top_down   = height < 0
    local h          = math.abs(height)
    local out = {}
    local op  = 0
    for y = 1, h do
        local src_row
        if top_down then src_row = y - 1 else src_row = h - y end
        local p = off_pixels + 1 + src_row * row_bytes
        for x = 0, width - 1 do
            -- BMP rows are stored as B, G, R, [A].
            op = op + 1; out[op] = string.sub(data, p, p)
            op = op + 1; out[op] = string.sub(data, p + 1, p + 1)
            op = op + 1; out[op] = string.sub(data, p + 2, p + 2)
            if channels == 4 then
                op = op + 1; out[op] = string.sub(data, p + 3, p + 3)
            end
            p = p + channels
        end
    end
    return {
        width = width, height = h, channels = channels,
        order = channels == 4 and "bgra" or "bgr",
        pixels = table.concat(out),
    }
end

-- ===== Pure-Lua BMP encoder (24bpp / 32bpp) ============================
local function encode_bmp(img)
    local w, h, ch = img.width, img.height, img.channels
    local order = img.order
    if ch ~= 3 and ch ~= 4 then
        img = M.convert(img, 4); ch = 4; order = img.order
    end
    local row_bytes = ((w * ch * 8 + 31) // 32) * 4
    local pad       = row_bytes - w * ch
    local pixels    = img.pixels
    local rows = {}
    for y = h - 1, 0, -1 do  -- BMP is bottom-up
        local row_start = y * w * ch + 1
        if order == "rgba" or order == "rgb" then
            local pieces = {}
            for x = 0, w - 1 do
                local p = row_start + x * ch
                pieces[#pieces + 1] = pixels:sub(p + 2, p + 2)
                pieces[#pieces + 1] = pixels:sub(p + 1, p + 1)
                pieces[#pieces + 1] = pixels:sub(p,     p)
                if ch == 4 then pieces[#pieces + 1] = pixels:sub(p + 3, p + 3) end
            end
            rows[#rows + 1] = table.concat(pieces)
        else
            rows[#rows + 1] = pixels:sub(row_start, row_start + w * ch - 1)
        end
        if pad > 0 then rows[#rows + 1] = string.rep("\0", pad) end
    end
    local pixel_blob = table.concat(rows)
    local pixel_off  = 14 + 40
    local file_size  = pixel_off + #pixel_blob
    local function put_u32(v) return string.char(v % 256, (v // 256) % 256, (v // 65536) % 256, (v // 16777216) % 256) end
    local function put_u16(v) return string.char(v % 256, (v // 256) % 256) end
    local function put_s32(v) if v < 0 then v = v + 0x100000000 end; return put_u32(v) end
    -- Build the 14-byte file header + 40-byte BITMAPINFOHEADER manually
    -- (Lua-table-constructor varargs trip the JIT codegen on some hosts).
    local hdr_parts = {}
    hdr_parts[#hdr_parts + 1] = "BM"
    hdr_parts[#hdr_parts + 1] = put_u32(file_size)
    hdr_parts[#hdr_parts + 1] = put_u16(0)
    hdr_parts[#hdr_parts + 1] = put_u16(0)
    hdr_parts[#hdr_parts + 1] = put_u32(pixel_off)
    hdr_parts[#hdr_parts + 1] = put_u32(40)
    hdr_parts[#hdr_parts + 1] = put_s32(w)
    hdr_parts[#hdr_parts + 1] = put_s32(h)
    hdr_parts[#hdr_parts + 1] = put_u16(1)
    hdr_parts[#hdr_parts + 1] = put_u16(ch * 8)
    hdr_parts[#hdr_parts + 1] = put_u32(0)
    hdr_parts[#hdr_parts + 1] = put_u32(#pixel_blob)
    hdr_parts[#hdr_parts + 1] = put_u32(2835)   -- ~72 dpi
    hdr_parts[#hdr_parts + 1] = put_u32(2835)
    hdr_parts[#hdr_parts + 1] = put_u32(0)
    hdr_parts[#hdr_parts + 1] = put_u32(0)
    return table.concat(hdr_parts) .. pixel_blob
end

-- ===== Pure-Lua stored-block PNG encoder ===============================
-- Real PNG with a "stored" deflate stream (no compression). Every PNG
-- decoder accepts it; the file is bigger than a deflated PNG but the
-- code is small enough to keep inline.

local _crc_table
local function _build_crc()
    _crc_table = {}
    for n = 0, 255 do
        local c = n
        for _ = 1, 8 do
            if c % 2 == 1 then c = 0xEDB88320 ~ (c >> 1)
            else c = c >> 1 end
        end
        _crc_table[n] = c
    end
end

local function crc32(data, init)
    if not _crc_table then _build_crc() end
    local c = (init or 0) ~ 0xFFFFFFFF
    for i = 1, #data do
        c = _crc_table[(c ~ data:byte(i)) & 0xFF] ~ (c >> 8)
    end
    return (c ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

local function adler32(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return (b * 65536 + a) & 0xFFFFFFFF
end

local function put_u32be(v) return string.char((v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) end
local function put_u16le(v) return string.char(v & 0xFF, (v >> 8) & 0xFF) end

local function png_chunk(kind, data)
    local body = kind .. data
    return put_u32be(#data) .. body .. put_u32be(crc32(body))
end

local function deflate_store(raw)
    -- Wrap raw bytes into a zlib stream of stored deflate blocks.
    local zlib_hdr = string.char(0x78, 0x01)  -- deflate, no preset dict
    local out  = {}
    out[1] = zlib_hdr
    local left = #raw
    local pos  = 1
    local MAX  = 65535
    while left > 0 do
        local take = math.min(MAX, left)
        local final = (left == take) and 1 or 0
        out[#out + 1] = string.char(final)
        out[#out + 1] = put_u16le(take)
        out[#out + 1] = put_u16le((~take) & 0xFFFF)
        out[#out + 1] = raw:sub(pos, pos + take - 1)
        pos  = pos  + take
        left = left - take
    end
    out[#out + 1] = put_u32be(adler32(raw))
    return table.concat(out)
end

local function encode_png(img)
    local w, h, ch = img.width, img.height, img.channels
    if ch ~= 1 and ch ~= 3 and ch ~= 4 then
        error("image.encode_png: channels must be 1, 3, or 4")
    end
    -- PNG expects RGB / RGBA. If our image is BGRA-ish, convert in place.
    local pixels = img.pixels
    if img.order == "bgra" then
        local out = {}
        for i = 1, #pixels, 4 do
            out[#out + 1] = pixels:sub(i + 2, i + 2)
            out[#out + 1] = pixels:sub(i + 1, i + 1)
            out[#out + 1] = pixels:sub(i,     i)
            out[#out + 1] = pixels:sub(i + 3, i + 3)
        end
        pixels = table.concat(out)
    elseif img.order == "bgr" then
        local out = {}
        for i = 1, #pixels, 3 do
            out[#out + 1] = pixels:sub(i + 2, i + 2)
            out[#out + 1] = pixels:sub(i + 1, i + 1)
            out[#out + 1] = pixels:sub(i,     i)
        end
        pixels = table.concat(out)
    end
    -- Prepend a filter byte (0 = no filter) to each scanline.
    local rows = {}
    local row_bytes = w * ch
    for y = 0, h - 1 do
        rows[y + 1] = "\0" .. pixels:sub(y * row_bytes + 1, (y + 1) * row_bytes)
    end
    local raw = table.concat(rows)
    local idat = deflate_store(raw)
    local colour_type = (ch == 1) and 0 or (ch == 3) and 2 or 6
    local ihdr = put_u32be(w) .. put_u32be(h)
              .. string.char(8, colour_type, 0, 0, 0)
    local png = "\137PNG\r\n\26\n"
             .. png_chunk("IHDR", ihdr)
             .. png_chunk("IDAT", idat)
             .. png_chunk("IEND", "")
    return png
end

-- ===== Format inference ================================================

local function sniff_format(bytes)
    if #bytes >= 8 and bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if #bytes >= 3 and bytes:sub(1, 3) == "\255\216\255"     then return "jpg" end
    if #bytes >= 2 and bytes:sub(1, 2) == "BM"               then return "bmp" end
    if #bytes >= 6 and (bytes:sub(1, 6) == "GIF87a" or bytes:sub(1, 6) == "GIF89a") then return "gif" end
    if #bytes >= 4 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return "webp" end
    if #bytes >= 4 and (bytes:sub(1, 4) == "II*\0" or bytes:sub(1, 4) == "MM\0*") then return "tiff" end
    return "unknown"
end

-- ===== WIC bridge (when available) =====================================
--
-- We talk to the wic sub-package and translate its frame -> our image
-- shape. WIC delivers 32bpp BGRA top-down, which is exactly the layout
-- our other helpers expect when order == "bgra".

local function wic_decode(bytes_or_path, opts)
    if not _wic then return nil end
    opts = opts or {}
    local frame
    if opts.is_path or looks_like_path(bytes_or_path) then
        local bytes = read_file(bytes_or_path)
        if not bytes then return nil end
        frame = _wic.decode(bytes, { is_bytes = true })
    else
        frame = _wic.decode(bytes_or_path, { is_bytes = true })
    end
    local w, h = frame:size()
    local pixels = frame:read_pixels({ target_format = _wic.GUID_WICPixelFormat32bppBGRA })
    local img = {
        width = w, height = h, channels = 4,
        order = "bgra", pixels = pixels,
    }
    if opts.channels and opts.channels ~= 0 and opts.channels ~= 4 then
        return M.convert(img, opts.channels)
    end
    return img
end

local function wic_encode(img, format, opts)
    if not _wic then return nil end
    opts = opts or {}
    -- WIC encoder takes BGRA pixels. Make sure ours are in that order.
    local src = img
    if src.channels ~= 4 or src.order ~= "bgra" then
        src = M.convert(src, 4)
        if src.order ~= "bgra" then
            -- The convert helper produces rgba for 4-channel pure-Lua
            -- output; swap once more.
            src = M.from_pixels(src.pixels, src.width, src.height, 4)
            -- assume the convert produced rgba: byte-swap to bgra in place.
            local out, p = {}, src.pixels
            for i = 1, #p, 4 do
                out[#out + 1] = p:sub(i + 2, i + 2)
                out[#out + 1] = p:sub(i + 1, i + 1)
                out[#out + 1] = p:sub(i,     i)
                out[#out + 1] = p:sub(i + 3, i + 3)
            end
            src = { width = src.width, height = src.height, channels = 4,
                    order = "bgra", pixels = table.concat(out) }
        end
    end
    local input = {
        width  = src.width,
        height = src.height,
        pixels = src.pixels,
    }
    if opts.path then
        return _wic.encode(input, format, opts.path)
    end
    local buf_size = opts.buffer_size or math.max(64 * 1024, src.width * src.height * 4)
    local bytes = _wic.encode(input, format, nil, { buffer_size = buf_size })
    return bytes
end

-- ===== stb_image bridge ================================================

local function stb_decode(bytes, opts)
    local lib = load_stb()
    if lib == nil then return nil end
    opts = opts or {}
    local desired = opts.channels or 0
    local x = ffi.new("int[1]")
    local y = ffi.new("int[1]")
    local n = ffi.new("int[1]")
    local data = lib.stbi_load_from_memory(bytes, #bytes, x, y, n, desired)
    if data == nil then return nil end
    local actual = desired ~= 0 and desired or tonumber(n[0])
    local w, h   = tonumber(x[0]), tonumber(y[0])
    local pixels = ffi.string(data, w * h * actual)
    lib.stbi_image_free(data)
    return {
        width = w, height = h, channels = actual,
        order = actual == 4 and "rgba" or (actual == 3 and "rgb" or "gray"),
        pixels = pixels,
    }
end

-- ===== Public API =======================================================

function M.backends()
    return {
        wic = have_wic(),
        stb = load_stb() ~= nil,
    }
end

function M.formats()
    local read  = { "png", "jpg", "bmp", "gif", "tga", "tiff" }
    local write = { "png", "bmp" }
    if have_wic() then
        read[#read + 1]  = "wmp"
        write[#write + 1] = "jpg"
        write[#write + 1] = "gif"
        write[#write + 1] = "tiff"
    end
    if load_stb() ~= nil then
        write[#write + 1] = "tga"
        write[#write + 1] = "jpg"
    end
    return { read = read, write = write }
end

function M.from_pixels(pixels, w, h, channels)
    local order
    if     channels == 4 then order = "rgba"
    elseif channels == 3 then order = "rgb"
    elseif channels == 1 then order = "gray"
    else error("image.from_pixels: channels must be 1, 3, or 4") end
    if #pixels ~= w * h * channels then
        error(string.format("image.from_pixels: pixel size %d != w*h*c (%d*%d*%d)",
              #pixels, w, h, channels))
    end
    return {
        width = w, height = h, channels = channels,
        order = order, pixels = pixels,
    }
end

function M.convert(img, target_channels)
    if img.channels == target_channels then return img end
    local src   = img.pixels
    local n     = img.width * img.height
    local out   = {}
    local order = img.order
    if img.channels == 4 and target_channels == 3 then
        for i = 1, n do
            local p = (i - 1) * 4 + 1
            if order == "bgra" then
                out[#out + 1] = src:sub(p + 2, p + 2)
                out[#out + 1] = src:sub(p + 1, p + 1)
                out[#out + 1] = src:sub(p,     p)
            else
                out[#out + 1] = src:sub(p,     p)
                out[#out + 1] = src:sub(p + 1, p + 1)
                out[#out + 1] = src:sub(p + 2, p + 2)
            end
        end
        return { width = img.width, height = img.height, channels = 3,
                 order = "rgb", pixels = table.concat(out) }
    elseif img.channels == 3 and target_channels == 4 then
        for i = 1, n do
            local p = (i - 1) * 3 + 1
            if order == "bgr" then
                out[#out + 1] = src:sub(p + 2, p + 2)
                out[#out + 1] = src:sub(p + 1, p + 1)
                out[#out + 1] = src:sub(p,     p)
            else
                out[#out + 1] = src:sub(p,     p)
                out[#out + 1] = src:sub(p + 1, p + 1)
                out[#out + 1] = src:sub(p + 2, p + 2)
            end
            out[#out + 1] = "\255"
        end
        return { width = img.width, height = img.height, channels = 4,
                 order = "rgba", pixels = table.concat(out) }
    elseif img.channels == 4 and target_channels == 1 then
        for i = 1, n do
            local p = (i - 1) * 4 + 1
            local r, g, b
            if order == "bgra" then b, g, r = src:byte(p), src:byte(p + 1), src:byte(p + 2)
            else r, g, b = src:byte(p), src:byte(p + 1), src:byte(p + 2) end
            local y = (r * 299 + g * 587 + b * 114) // 1000
            out[#out + 1] = string.char(y)
        end
        return { width = img.width, height = img.height, channels = 1,
                 order = "gray", pixels = table.concat(out) }
    elseif img.channels == 3 and target_channels == 1 then
        for i = 1, n do
            local p = (i - 1) * 3 + 1
            local r, g, b
            if order == "bgr" then b, g, r = src:byte(p), src:byte(p + 1), src:byte(p + 2)
            else r, g, b = src:byte(p), src:byte(p + 1), src:byte(p + 2) end
            out[#out + 1] = string.char((r * 299 + g * 587 + b * 114) // 1000)
        end
        return { width = img.width, height = img.height, channels = 1,
                 order = "gray", pixels = table.concat(out) }
    elseif img.channels == 1 and target_channels == 3 then
        for i = 1, n do
            local b = src:sub(i, i)
            out[#out + 1] = b; out[#out + 1] = b; out[#out + 1] = b
        end
        return { width = img.width, height = img.height, channels = 3,
                 order = "rgb", pixels = table.concat(out) }
    elseif img.channels == 1 and target_channels == 4 then
        for i = 1, n do
            local b = src:sub(i, i)
            out[#out + 1] = b; out[#out + 1] = b; out[#out + 1] = b
            out[#out + 1] = "\255"
        end
        return { width = img.width, height = img.height, channels = 4,
                 order = "rgba", pixels = table.concat(out) }
    end
    error("image.convert: unsupported conversion " .. img.channels .. " -> " .. target_channels)
end

function M.decode(bytes_or_path, opts)
    opts = opts or {}
    local bytes = bytes_or_path
    if looks_like_path(bytes_or_path) or opts.is_path then
        local content, err = read_file(bytes_or_path)
        if not content then
            -- Treat as a literal byte string instead of erroring; the user
            -- might have passed compact image bytes that happen to be short.
            if opts.is_path then error("image.decode: " .. tostring(err)) end
        else
            bytes = content
        end
    end
    -- WIC handles the most formats; try it first.
    if have_wic() then
        local ok, img = pcall(wic_decode, bytes, opts)
        if ok and img then return img end
    end
    -- stb_image second.
    if load_stb() ~= nil then
        local img = stb_decode(bytes, opts)
        if img then return img end
    end
    -- Pure-Lua fallbacks.
    local fmt = sniff_format(bytes)
    if fmt == "bmp" then
        local img, err = decode_bmp(bytes)
        if not img then error("image.decode: " .. err) end
        if opts.channels and opts.channels ~= 0 and opts.channels ~= img.channels then
            return M.convert(img, opts.channels)
        end
        return img
    end
    error("image.decode: no backend available for format '" .. fmt .. "'")
end

function M.encode(img, format, opts)
    format = format:lower()
    opts = opts or {}
    if format == "bmp" then
        return encode_bmp(img)
    elseif format == "png" then
        -- Prefer WIC if available (smaller output), else pure-Lua "stored" PNG.
        if have_wic() then
            local ok, bytes = pcall(wic_encode, img, "png", opts)
            if ok and bytes then return bytes end
        end
        if load_stb() then
            -- stb_image_write doesn't accept a memory buffer easily; let
            -- callers route through save() if they want the stb encoder.
        end
        return encode_png(img)
    elseif format == "jpg" or format == "jpeg" then
        if have_wic() then return wic_encode(img, "jpeg", opts) end
        error("image.encode: jpg requires WIC backend")
    elseif format == "gif" then
        if have_wic() then return wic_encode(img, "gif", opts) end
        error("image.encode: gif requires WIC backend")
    elseif format == "tiff" or format == "tif" then
        if have_wic() then return wic_encode(img, "tiff", opts) end
        error("image.encode: tiff requires WIC backend")
    elseif format == "tga" then
        -- Trivial uncompressed TGA: 18-byte header + raw BGRA / BGR pixels.
        local src = img
        if src.channels ~= 3 and src.channels ~= 4 then
            src = M.convert(src, 4)
        end
        local hdr = string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                 .. put_u16le(src.width) .. put_u16le(src.height)
                 .. string.char(src.channels * 8, src.channels == 4 and 0x28 or 0x20)
        -- Convert RGBA/RGB to BGRA/BGR if needed.
        local pix = src.pixels
        if src.order == "rgba" then
            local out = {}
            for i = 1, #pix, 4 do
                out[#out + 1] = pix:sub(i + 2, i + 2)
                out[#out + 1] = pix:sub(i + 1, i + 1)
                out[#out + 1] = pix:sub(i,     i)
                out[#out + 1] = pix:sub(i + 3, i + 3)
            end
            pix = table.concat(out)
        elseif src.order == "rgb" then
            local out = {}
            for i = 1, #pix, 3 do
                out[#out + 1] = pix:sub(i + 2, i + 2)
                out[#out + 1] = pix:sub(i + 1, i + 1)
                out[#out + 1] = pix:sub(i,     i)
            end
            pix = table.concat(out)
        end
        return hdr .. pix
    end
    error("image.encode: unsupported format '" .. format .. "'")
end

function M.save(img, path, opts)
    opts = opts or {}
    local ext = path:match("%.([%w]+)$") or "png"
    ext = ext:lower()
    -- stb_image_write has a path-based API we can use directly for the
    -- formats WIC doesn't trivially produce.
    local stb = load_stb()
    if stb ~= nil and (ext == "jpg" or ext == "jpeg") and not have_wic() then
        local src = img
        if src.channels ~= 3 then src = M.convert(src, 3) end
        if src.order == "bgr" then src = M.convert(src, 4); src = M.convert(src, 3) end
        local quality = opts.quality or 90
        local pbuf = ffi.new("uint8_t[?]", #src.pixels, src.pixels)
        local rc = stb.stbi_write_jpg(path, src.width, src.height, src.channels, pbuf, quality)
        if rc == 0 then error("image.save: stbi_write_jpg failed") end
        return
    end
    local bytes = M.encode(img, ext, opts)
    local ok, err = write_file(path, bytes)
    if not ok then error("image.save: " .. tostring(err)) end
end

function M.load(path, opts)
    opts = opts or {}
    opts.is_path = true
    local bytes, err = read_file(path)
    if not bytes then error("image.load: " .. tostring(err)) end
    return M.decode(bytes, opts)
end

function M.resize(img, new_w, new_h, opts)
    opts = opts or {}
    local mode = opts.mode or "bilinear"
    local sw, sh, ch = img.width, img.height, img.channels
    local src = img.pixels
    local out_size = new_w * new_h * ch
    local buf = ffi.new("uint8_t[?]", out_size)
    if mode == "nearest" then
        local x_ratio = sw / new_w
        local y_ratio = sh / new_h
        for y = 0, new_h - 1 do
            local sy = math.floor(y * y_ratio)
            for x = 0, new_w - 1 do
                local sx = math.floor(x * x_ratio)
                local sp = (sy * sw + sx) * ch
                local dp = (y  * new_w + x) * ch
                for c = 0, ch - 1 do
                    buf[dp + c] = src:byte(sp + c + 1)
                end
            end
        end
    else  -- bilinear
        local x_ratio = (sw > 1) and ((sw - 1) / new_w) or 0
        local y_ratio = (sh > 1) and ((sh - 1) / new_h) or 0
        for y = 0, new_h - 1 do
            local fy = y * y_ratio
            local y0 = math.floor(fy)
            local dy = fy - y0
            local y1 = math.min(y0 + 1, sh - 1)
            for x = 0, new_w - 1 do
                local fx = x * x_ratio
                local x0 = math.floor(fx)
                local dx = fx - x0
                local x1 = math.min(x0 + 1, sw - 1)
                local p00 = (y0 * sw + x0) * ch
                local p01 = (y0 * sw + x1) * ch
                local p10 = (y1 * sw + x0) * ch
                local p11 = (y1 * sw + x1) * ch
                local dp  = (y * new_w + x) * ch
                for c = 0, ch - 1 do
                    local v00 = src:byte(p00 + c + 1)
                    local v01 = src:byte(p01 + c + 1)
                    local v10 = src:byte(p10 + c + 1)
                    local v11 = src:byte(p11 + c + 1)
                    local v0  = v00 + (v01 - v00) * dx
                    local v1  = v10 + (v11 - v10) * dx
                    buf[dp + c] = math.floor(v0 + (v1 - v0) * dy + 0.5)
                end
            end
        end
    end
    return {
        width = new_w, height = new_h, channels = ch,
        order = img.order,
        pixels = ffi.string(buf, out_size),
    }
end

function M.crop(img, x, y, w, h)
    if x < 0 or y < 0 or x + w > img.width or y + h > img.height then
        error("image.crop: out of bounds")
    end
    local ch = img.channels
    local out = {}
    for row = 0, h - 1 do
        local sp = ((y + row) * img.width + x) * ch + 1
        out[#out + 1] = img.pixels:sub(sp, sp + w * ch - 1)
    end
    return {
        width = w, height = h, channels = ch,
        order = img.order, pixels = table.concat(out),
    }
end

function M.flip(img, axis)
    local w, h, ch = img.width, img.height, img.channels
    local row_bytes = w * ch
    local src = img.pixels
    local rows = {}
    if axis == "y" then
        for y = h, 1, -1 do
            rows[#rows + 1] = src:sub((y - 1) * row_bytes + 1, y * row_bytes)
        end
    elseif axis == "x" then
        for y = 0, h - 1 do
            local row = src:sub(y * row_bytes + 1, (y + 1) * row_bytes)
            local rev = {}
            for x = w - 1, 0, -1 do
                rev[#rev + 1] = row:sub(x * ch + 1, x * ch + ch)
            end
            rows[#rows + 1] = table.concat(rev)
        end
    else
        error("image.flip: axis must be 'x' or 'y'")
    end
    return {
        width = w, height = h, channels = ch,
        order = img.order, pixels = table.concat(rows),
    }
end

return M
