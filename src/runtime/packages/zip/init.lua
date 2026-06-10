-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- zip -- PKZIP archive reader + writer.
--
-- Format references:
--   APPNOTE.TXT 6.3.10 (PKZIP application note) -- the de-facto spec.
--   Each entry has a Local File Header + data + optional Data Descriptor.
--   The Central Directory at the tail enumerates every entry; the EOCD
--   record holds the pointer to it. ZIP64 extends 32-bit size fields
--   when an archive crosses 4 GiB or 65535 entries.
--
-- Public surface:
--   zip.reader(bytes_or_path)            -> reader object
--     reader:entries()                   -> array of entry tables { name, size, csize, method, mtime, crc32 }
--     reader:read(name)                  -> bytes (decompresses if needed)
--     reader:extract(dest_dir)           -> array of extracted paths
--   zip.writer(path)                     -> writer object
--     writer:add_file(name, bytes, opts?)
--     writer:add_directory(name)
--     writer:close()                     -> bytes_written
--
-- opts on writer:add_file:
--   method = "stored" | "deflate" (default "deflate" -- delegated to zlib)
--   mtime  = unix timestamp (default os.time())
--   level  = deflate level (default 6)

local M = {}

-- zlib is needed for DEFLATE; tolerate its absence by degrading to
-- stored-only mode (matches the spec's soft-require behaviour).
local _zlib_ok, zlib = pcall(require, "zlib")
if not _zlib_ok then zlib = nil end

local bit_band = bit.band
local bit_bor  = bit.bor
local bit_lsh  = bit.lshift
local bit_rsh  = bit.rshift

-- Wire format magic numbers.
local LFH_SIG  = 0x04034B50  -- local file header
local CFH_SIG  = 0x02014B50  -- central directory file header
local EOCD_SIG = 0x06054B50  -- end of central directory
local EOCD64_SIG     = 0x06064B50
local EOCD64_LOC_SIG = 0x07064B50

-- Methods.
local METHOD_STORED  = 0
local METHOD_DEFLATE = 8

-- ===== bytewise helpers ==================================================

local function u16_le(s, off)
    local a, b = s:byte(off, off + 1)
    if b == nil then error("zip: truncated u16") end
    return a + b * 256
end

local function u32_le(s, off)
    local a, b, c, d = s:byte(off, off + 3)
    if d == nil then error("zip: truncated u32") end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u64_le(s, off)
    local lo = u32_le(s, off)
    local hi = u32_le(s, off + 4)
    -- Lua numbers stay exact through 2^53. For ZIP64 archives bigger
    -- than that, callers are out of luck regardless.
    return lo + hi * 4294967296
end

local function p16_le(v)
    return string.char(bit_band(v, 0xFF), bit_band(bit_rsh(v, 8), 0xFF))
end

local function p32_le(v)
    return string.char(
        bit_band(v, 0xFF),
        bit_band(bit_rsh(v,  8), 0xFF),
        bit_band(bit_rsh(v, 16), 0xFF),
        bit_band(bit_rsh(v, 24), 0xFF))
end

local function p64_le(v)
    local hi = math.floor(v / 4294967296)
    local lo = v - hi * 4294967296
    return p32_le(lo) .. p32_le(hi)
end

-- ===== DOS timestamp encoding ============================================
-- ZIP times are MS-DOS format: date and time each packed into u16.
-- date: bits 9..15 = year-1980, 5..8 = month, 0..4 = day
-- time: bits 11..15 = hour, 5..10 = minute, 0..4 = seconds/2

local function pack_dos_time(t)
    local d = os.date("*t", t)
    local dos_time = bit_bor(bit_lsh(d.hour, 11),
                             bit_lsh(d.min,  5),
                             math.floor(d.sec / 2))
    local dos_date = bit_bor(bit_lsh(d.year - 1980, 9),
                             bit_lsh(d.month, 5),
                             d.day)
    return dos_time, dos_date
end

local function unpack_dos_time(dos_time, dos_date)
    local year  = bit_rsh(dos_date, 9) + 1980
    local month = bit_band(bit_rsh(dos_date, 5), 0x0F)
    local day   = bit_band(dos_date, 0x1F)
    local hour  = bit_rsh(dos_time, 11)
    local min   = bit_band(bit_rsh(dos_time, 5), 0x3F)
    local sec   = bit_band(dos_time, 0x1F) * 2
    return os.time({ year = year, month = month, day = day,
                     hour = hour, min = min, sec = sec })
end

-- ===== reader ============================================================

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then error("zip.reader: cannot open " .. tostring(path)) end
    local s = f:read("*a")
    f:close()
    return s
end

-- Find EOCD by scanning backwards from end of buffer. The record ends
-- the file unless a comment follows, in which case the comment can be
-- up to 65535 bytes long, so we scan a 64KB+22 window.
local function find_eocd(buf)
    local n = #buf
    local max_scan = math.min(65535 + 22, n)
    for off = n - 21, n - max_scan, -1 do
        if off >= 1 and u32_le(buf, off) == EOCD_SIG then
            return off
        end
    end
    error("zip: end-of-central-directory record not found (not a ZIP?)")
end

local function parse_extra_zip64(extra, want_uncomp, want_comp, want_offset)
    -- Walk extra field looking for ZIP64 header id 0x0001.
    -- Each extra field: id(u16), size(u16), data(size).
    -- ZIP64 data layout: only fields whose 32-bit slots were 0xFFFFFFFF
    -- appear, in order: uncompressed, compressed, local header offset, disk #.
    local i = 1
    local n = #extra
    while i + 3 <= n do
        local id   = u16_le(extra, i)
        local size = u16_le(extra, i + 2)
        if id == 0x0001 then
            local pos = i + 4
            local r = {}
            if want_uncomp and pos + 7 <= i + 3 + size then
                r.uncompressed = u64_le(extra, pos); pos = pos + 8
            end
            if want_comp and pos + 7 <= i + 3 + size then
                r.compressed = u64_le(extra, pos); pos = pos + 8
            end
            if want_offset and pos + 7 <= i + 3 + size then
                r.local_offset = u64_le(extra, pos); pos = pos + 8
            end
            return r
        end
        i = i + 4 + size
    end
    return nil
end

local _reader_mt = {}
_reader_mt.__index = _reader_mt

function _reader_mt:entries()
    if self._entries then return self._entries end
    local buf = self._buf
    local eocd = find_eocd(buf)
    local total_entries = u16_le(buf, eocd + 10)
    local cd_size       = u32_le(buf, eocd + 12)
    local cd_offset     = u32_le(buf, eocd + 16)
    -- ZIP64 fixup: if the canonical 32-bit fields are saturated, the
    -- real values live in the ZIP64 EOCD record, located via the
    -- ZIP64 EOCD locator just before the regular EOCD.
    if total_entries == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF then
        if eocd >= 21 and u32_le(buf, eocd - 20) == EOCD64_LOC_SIG then
            local eocd64_off = u64_le(buf, eocd - 20 + 8) + 1
            if u32_le(buf, eocd64_off) == EOCD64_SIG then
                total_entries = u64_le(buf, eocd64_off + 32)
                cd_size       = u64_le(buf, eocd64_off + 40)
                cd_offset     = u64_le(buf, eocd64_off + 48)
            end
        end
    end
    local entries = {}
    local pos = cd_offset + 1
    for _ = 1, total_entries do
        if u32_le(buf, pos) ~= CFH_SIG then
            error(string.format("zip: bad central-directory signature at offset %d", pos - 1))
        end
        local method   = u16_le(buf, pos + 10)
        local dos_time = u16_le(buf, pos + 12)
        local dos_date = u16_le(buf, pos + 14)
        local crc      = u32_le(buf, pos + 16)
        local csize    = u32_le(buf, pos + 20)
        local usize    = u32_le(buf, pos + 24)
        local nlen     = u16_le(buf, pos + 28)
        local elen     = u16_le(buf, pos + 30)
        local clen     = u16_le(buf, pos + 32)
        local local_off = u32_le(buf, pos + 42)
        local name     = buf:sub(pos + 46, pos + 46 + nlen - 1)
        local extra    = buf:sub(pos + 46 + nlen, pos + 46 + nlen + elen - 1)
        if csize == 0xFFFFFFFF or usize == 0xFFFFFFFF or local_off == 0xFFFFFFFF then
            local z64 = parse_extra_zip64(extra,
                usize == 0xFFFFFFFF,
                csize == 0xFFFFFFFF,
                local_off == 0xFFFFFFFF)
            if z64 then
                if z64.uncompressed then usize     = z64.uncompressed end
                if z64.compressed   then csize     = z64.compressed   end
                if z64.local_offset then local_off = z64.local_offset end
            end
        end
        local entry = {
            name         = name,
            method       = method,
            compressed   = csize,
            uncompressed = usize,
            crc32        = crc,
            mtime        = unpack_dos_time(dos_time, dos_date),
            _local_off   = local_off,
            is_dir       = name:sub(-1) == "/",
        }
        entries[#entries + 1] = entry
        pos = pos + 46 + nlen + elen + clen
    end
    self._entries = entries
    return entries
end

function _reader_mt:read(name)
    local entries = self:entries()
    for _, e in ipairs(entries) do
        if e.name == name then
            local buf = self._buf
            local lfh = e._local_off + 1
            if u32_le(buf, lfh) ~= LFH_SIG then
                error("zip: bad local file header for " .. name)
            end
            local nlen = u16_le(buf, lfh + 26)
            local elen = u16_le(buf, lfh + 28)
            local data_start = lfh + 30 + nlen + elen
            local data = buf:sub(data_start, data_start + e.compressed - 1)
            if e.method == METHOD_STORED then
                return data
            elseif e.method == METHOD_DEFLATE then
                if not zlib then
                    error("zip.read: zlib package unavailable -- cannot inflate " .. name)
                end
                return zlib.inflate(data)
            else
                error(string.format("zip: unsupported method %d for entry %s",
                                    e.method, name))
            end
        end
    end
    error("zip: entry not found: " .. tostring(name))
end

-- Best-effort recursive mkdir using io / os primitives only.
local function ensure_dir(path)
    if path == nil or path == "" or path == "." then return end
    -- Try creating; if already there, succeeds either way (ignore error).
    local cmd = string.format('mkdir "%s" 2>nul', path:gsub("/", "\\"))
    os.execute(cmd)
end

local function dirname(path)
    local p = path:gsub("\\", "/")
    local i = p:find("/[^/]*$")
    if i then return p:sub(1, i - 1) end
    return ""
end

-- Reject archive entry names that would escape the destination directory
-- (Zip-Slip / CWE-22): an absolute path, a Windows drive prefix, or any ".."
-- path segment. A crafted .zip can otherwise write arbitrary files anywhere
-- the process can write. Raises on a hostile name rather than writing it.
local function safe_entry_name(name)
    local n = name:gsub("\\", "/")
    if n:sub(1, 1) == "/" or n:match("^%a:") then
        error("zip.extract: refusing absolute path in archive entry: " .. name)
    end
    for seg in (n .. "/"):gmatch("([^/]*)/") do
        if seg == ".." then
            error("zip.extract: refusing path traversal ('..') in entry: " .. name)
        end
    end
end

function _reader_mt:extract(dest_dir)
    local out = {}
    for _, e in ipairs(self:entries()) do
        safe_entry_name(e.name)
        local target = dest_dir .. "/" .. e.name
        if e.is_dir then
            ensure_dir(target)
        else
            ensure_dir(dirname(target))
            local body = self:read(e.name)
            -- Optional integrity check (skipped when zlib unavailable).
            if zlib then
                local crc = zlib.crc32(body)
                if crc ~= e.crc32 then
                    error(string.format("zip.extract: CRC mismatch for %s", e.name))
                end
            end
            local f = io.open(target, "wb")
            if not f then error("zip.extract: cannot create " .. target) end
            f:write(body); f:close()
            out[#out + 1] = target
        end
    end
    return out
end

function M.reader(bytes_or_path)
    if type(bytes_or_path) ~= "string" then
        error("zip.reader: expected string (bytes or path)")
    end
    local buf
    -- Heuristic: if the input starts with PKZIP local-header magic OR
    -- ends with EOCD magic, treat as raw bytes; otherwise it's a path.
    if #bytes_or_path > 4 and u32_le(bytes_or_path, 1) == LFH_SIG then
        buf = bytes_or_path
    else
        buf = read_file(bytes_or_path)
    end
    return setmetatable({ _buf = buf }, _reader_mt)
end

-- ===== writer ============================================================

local _writer_mt = {}
_writer_mt.__index = _writer_mt

function _writer_mt:_pos()
    return self._offset
end

function _writer_mt:_emit(s)
    self._fp:write(s)
    self._offset = self._offset + #s
end

function _writer_mt:add_directory(name)
    if name:sub(-1) ~= "/" then name = name .. "/" end
    local now = os.time()
    local dos_time, dos_date = pack_dos_time(now)
    local local_off = self:_pos()
    local lfh = p32_le(LFH_SIG)
        .. p16_le(20)         -- version needed
        .. p16_le(0)          -- gp flags
        .. p16_le(0)          -- method = stored
        .. p16_le(dos_time)
        .. p16_le(dos_date)
        .. p32_le(0)          -- crc32
        .. p32_le(0)          -- comp size
        .. p32_le(0)          -- uncomp size
        .. p16_le(#name)
        .. p16_le(0)          -- extra len
        .. name
    self:_emit(lfh)
    self._entries[#self._entries + 1] = {
        name = name, method = 0, csize = 0, usize = 0,
        crc = 0, dos_time = dos_time, dos_date = dos_date,
        local_off = local_off, is_dir = true,
    }
end

function _writer_mt:add_file(name, bytes, opts)
    opts = opts or {}
    local method
    if opts.method == "stored" or not zlib then
        method = METHOD_STORED
    else
        method = METHOD_DEFLATE
    end
    local mtime = opts.mtime or os.time()
    local dos_time, dos_date = pack_dos_time(mtime)
    -- CRC32 falls back to a local minimal impl if zlib is missing.
    local crc
    if zlib then
        crc = zlib.crc32(bytes)
    else
        crc = M._crc32(bytes)
    end
    local usize = #bytes
    local data
    if method == METHOD_DEFLATE then
        data = zlib.deflate(bytes, opts.level or 6)
        -- Edge case: deflate output bigger than original (incompressible
        -- input). Fall back to stored so the archive stays compact.
        if #data >= usize then
            data   = bytes
            method = METHOD_STORED
        end
    else
        data = bytes
    end
    local csize = #data
    local local_off = self:_pos()
    local lfh = p32_le(LFH_SIG)
        .. p16_le(20)
        .. p16_le(0)
        .. p16_le(method)
        .. p16_le(dos_time)
        .. p16_le(dos_date)
        .. p32_le(crc)
        .. p32_le(csize)
        .. p32_le(usize)
        .. p16_le(#name)
        .. p16_le(0)
        .. name
    self:_emit(lfh)
    self:_emit(data)
    self._entries[#self._entries + 1] = {
        name = name, method = method, csize = csize, usize = usize,
        crc = crc, dos_time = dos_time, dos_date = dos_date,
        local_off = local_off, is_dir = false,
    }
end

local function emit_central_entry(e)
    -- Saturate 32-bit slots when ZIP64 is needed; we'll embed real
    -- values in the extra field.
    local need_zip64 = (e.csize >= 0xFFFFFFFF) or (e.usize >= 0xFFFFFFFF)
                       or (e.local_off >= 0xFFFFFFFF)
    local csize     = need_zip64 and 0xFFFFFFFF or e.csize
    local usize     = need_zip64 and 0xFFFFFFFF or e.usize
    local local_off = need_zip64 and 0xFFFFFFFF or e.local_off
    local extra = ""
    if need_zip64 then
        extra = p16_le(0x0001) .. p16_le(24)
            .. p64_le(e.usize) .. p64_le(e.csize) .. p64_le(e.local_off)
    end
    return p32_le(CFH_SIG)
        .. p16_le(20)              -- version made by
        .. p16_le(need_zip64 and 45 or 20)  -- version needed
        .. p16_le(0)               -- gp flags
        .. p16_le(e.method)
        .. p16_le(e.dos_time)
        .. p16_le(e.dos_date)
        .. p32_le(e.crc)
        .. p32_le(csize)
        .. p32_le(usize)
        .. p16_le(#e.name)
        .. p16_le(#extra)
        .. p16_le(0)               -- comment len
        .. p16_le(0)               -- disk number start
        .. p16_le(0)               -- internal attrs
        .. p32_le(e.is_dir and 0x10 or 0)  -- external attrs (DOS dir bit)
        .. p32_le(local_off)
        .. e.name
        .. extra
end

function _writer_mt:close()
    local cd_start = self:_pos()
    local cd_bytes = {}
    for _, e in ipairs(self._entries) do
        cd_bytes[#cd_bytes + 1] = emit_central_entry(e)
    end
    local cd_blob = table.concat(cd_bytes)
    self:_emit(cd_blob)
    local cd_size = #cd_blob
    local cd_off  = cd_start
    local n_entries = #self._entries
    local need_zip64 = (cd_size >= 0xFFFFFFFF) or (cd_off >= 0xFFFFFFFF)
                       or (n_entries >= 0xFFFF)
    if need_zip64 then
        local eocd64_off = self:_pos()
        local eocd64 = p32_le(EOCD64_SIG)
            .. p64_le(44)              -- size of zip64 EOCD record - 12
            .. p16_le(45)              -- version made by
            .. p16_le(45)              -- version needed
            .. p32_le(0)               -- disk number
            .. p32_le(0)               -- disk with CD start
            .. p64_le(n_entries)
            .. p64_le(n_entries)
            .. p64_le(cd_size)
            .. p64_le(cd_off)
        self:_emit(eocd64)
        local loc = p32_le(EOCD64_LOC_SIG)
            .. p32_le(0)
            .. p64_le(eocd64_off)
            .. p32_le(1)
        self:_emit(loc)
    end
    local eocd = p32_le(EOCD_SIG)
        .. p16_le(0)                   -- this disk
        .. p16_le(0)                   -- disk w/ CD
        .. p16_le(need_zip64 and 0xFFFF or n_entries)
        .. p16_le(need_zip64 and 0xFFFF or n_entries)
        .. p32_le(need_zip64 and 0xFFFFFFFF or cd_size)
        .. p32_le(need_zip64 and 0xFFFFFFFF or cd_off)
        .. p16_le(0)                   -- comment len
    self:_emit(eocd)
    self._fp:close()
    return self._offset
end

function M.writer(path)
    local fp = io.open(path, "wb")
    if not fp then error("zip.writer: cannot create " .. path) end
    return setmetatable({
        _fp = fp,
        _offset = 0,
        _entries = {},
    }, _writer_mt)
end

-- ===== Spec-shaped facade (open / list / extract_all / create) ==========
-- These mirror the surface used by the zlib / lz4 / zstd / cab packages
-- so callers see a uniform `open()` + `create()` shape regardless of
-- which archive format they're driving.

local function _reader_facade(buf)
    local r = setmetatable({ _buf = buf }, _reader_mt)
    return {
        list = function()
            local out = {}
            for _, e in ipairs(r:entries()) do
                out[#out + 1] = {
                    name   = e.name,
                    size   = e.uncompressed,
                    csize  = e.compressed,
                    mtime  = e.mtime,
                    method = (e.method == METHOD_DEFLATE) and "deflate"
                          or (e.method == METHOD_STORED  and "stored")
                          or tostring(e.method),
                    crc32  = e.crc32,
                    is_dir = e.is_dir,
                }
            end
            return out
        end,
        read = function(self, name)
            if type(self) == "string" then name = self end
            return r:read(name)
        end,
        extract_all = function(self, dest_dir)
            if type(self) == "string" then dest_dir = self end
            return r:extract(dest_dir)
        end,
        _reader = r,
    }
end

function M.open(path_or_bytes)
    if type(path_or_bytes) ~= "string" then
        error("zip.open: expected path or bytes")
    end
    local buf
    if #path_or_bytes > 4 and u32_le(path_or_bytes, 1) == LFH_SIG then
        buf = path_or_bytes
    else
        local f = io.open(path_or_bytes, "rb")
        if not f then error("zip.open: cannot open " .. path_or_bytes) end
        buf = f:read("*a"); f:close()
    end
    return _reader_facade(buf)
end

local function _slurp(path)
    local f = io.open(path, "rb")
    if not f then error("zip: cannot open " .. tostring(path)) end
    local s = f:read("*a"); f:close()
    return s
end

local function _writer_facade(w)
    return {
        add_file = function(self, name, bytes, opts)
            if type(self) == "string" then
                -- Calling-convention helper: `wr.add_file(name, bytes)`
                -- (no colon) still works.
                opts  = bytes
                bytes = name
                name  = self
            end
            w:add_file(name, bytes, opts)
        end,
        add_path = function(self, disk_path, archive_name, opts)
            if type(self) == "string" then
                opts = archive_name; archive_name = disk_path; disk_path = self
            end
            archive_name = archive_name or disk_path
            local body = _slurp(disk_path)
            w:add_file(archive_name, body, opts)
        end,
        add_directory = function(self, name)
            if type(self) == "string" then name = self end
            w:add_directory(name)
        end,
        close = function(self)
            return w:close()
        end,
        _writer = w,
    }
end

function M.create(path)
    if type(path) ~= "string" then error("zip.create: path required") end
    local fp = io.open(path, "wb")
    if not fp then error("zip.create: cannot create " .. path) end
    local w = setmetatable({
        _fp      = fp,
        _offset  = 0,
        _entries = {},
    }, _writer_mt)
    return _writer_facade(w)
end

-- ===== Minimal CRC32 fallback used when zlib is unavailable ==============
do
    local crc_table
    local function build()
        crc_table = {}
        for n = 0, 255 do
            local c = n
            for _ = 1, 8 do
                if bit_band(c, 1) == 1 then
                    c = bit.bxor(bit_rsh(c, 1), 0xEDB88320)
                else
                    c = bit_rsh(c, 1)
                end
            end
            crc_table[n] = c
        end
    end
    function M._crc32(bytes)
        if not crc_table then build() end
        local c = 0xFFFFFFFF
        for i = 1, #bytes do
            c = bit.bxor(bit_rsh(c, 8), crc_table[bit_band(bit.bxor(c, bytes:byte(i)), 0xFF)])
        end
        return bit_band(bit.bxor(c, 0xFFFFFFFF), 0xFFFFFFFF)
    end
end

return M
