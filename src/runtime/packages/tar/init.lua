-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- tar -- POSIX ustar archive reader + writer.
--
-- Format references:
--   POSIX.1-1988 ustar header (TAR_HDR_*).
--   POSIX.1-2001 PAX extended header (typeflag 'x' for per-entry, 'g'
--   for global -- only per-entry is consumed here).
--
-- ustar header (512 bytes, all numeric fields are octal ASCII):
--   name(100) | mode(8) | uid(8) | gid(8) | size(12) | mtime(12)
--   chksum(8) | typeflag(1) | linkname(100) | magic("ustar\0",6)
--   version("00",2) | uname(32) | gname(32) | devmajor(8) | devminor(8)
--   prefix(155) | padding(12)
--
-- typeflag codes used here:
--   '0' or '\0'  regular file
--   '1'          hard link
--   '2'          symbolic link
--   '5'          directory
--   'x'          PAX extended header (applies to next entry)
--   'g'          PAX global extended header (consumed and skipped)
--   'L'          GNU long name (next entry's name comes from here)
--   'K'          GNU long link name
--
-- Records are padded with NUL to 512-byte boundary; the archive ends
-- with at least two consecutive all-NUL records (and writers typically
-- pad out to 10240-byte ("RECORDSIZE") blocks).
--
-- Public surface:
--   tar.reader(bytes_or_path) -> reader
--     reader:entries()  -> iterator yielding entry tables
--     reader:read_all() -> array of { name, type, size, mtime, mode, content, linkname }
--   tar.writer(path) -> writer
--     writer:add_file(name, bytes, opts?)
--     writer:add_directory(name, opts?)
--     writer:add_symlink(name, target, opts?)
--     writer:close()

local M = {}

local BLOCK_SIZE = 512

-- ===== reader helpers ====================================================

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then error("tar.reader: cannot open " .. tostring(path)) end
    local s = f:read("*a")
    f:close()
    return s
end

local function rtrim_nul(s)
    local last = #s
    while last > 0 and (s:byte(last) == 0 or s:byte(last) == 32) do
        last = last - 1
    end
    return s:sub(1, last)
end

local function parse_octal(s)
    s = rtrim_nul(s)
    if s == "" then return 0 end
    -- Strip any leading spaces (some headers pad numeric fields that way).
    s = s:gsub("^%s+", "")
    return tonumber(s, 8) or 0
end

-- Some tar variants (GNU "base-256") store sizes >8 GiB by setting the
-- top bit of byte 0 to 1 and treating the remaining bytes as a big-
-- endian unsigned integer.
local function parse_size_field(s)
    if #s >= 1 and bit.band(s:byte(1), 0x80) ~= 0 then
        local v = 0
        v = (s:byte(1) - 0x80) * 256
        for i = 2, #s do
            v = v * 256 + s:byte(i)
        end
        return v
    end
    return parse_octal(s)
end

local function header_checksum(block)
    -- Sum of unsigned byte values, treating the chksum field bytes as
    -- 32 (ASCII space). Used to validate the header.
    local sum = 0
    for i = 1, BLOCK_SIZE do
        local b = block:byte(i)
        if i >= 149 and i <= 156 then
            sum = sum + 32
        else
            sum = sum + b
        end
    end
    return sum
end

-- Parse PAX extended header content: each record is "<len> <key>=<value>\n"
-- where <len> is the total record length including itself.
local function parse_pax(content)
    local out = {}
    local i = 1
    while i <= #content do
        local space = content:find(" ", i, true)
        if not space then break end
        local len = tonumber(content:sub(i, space - 1))
        if not len then break end
        local kv = content:sub(space + 1, i + len - 2)  -- minus trailing \n
        local eq = kv:find("=", 1, true)
        if eq then
            out[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
        end
        i = i + len
    end
    return out
end

local function parse_header(block)
    if #block < BLOCK_SIZE then return nil end
    -- Detect all-NUL record (archive terminator).
    local all_nul = true
    for i = 1, BLOCK_SIZE do
        if block:byte(i) ~= 0 then all_nul = false; break end
    end
    if all_nul then return nil end
    local stored_chksum = parse_octal(block:sub(149, 156))
    if header_checksum(block) ~= stored_chksum then
        error("tar: header checksum mismatch")
    end
    local h = {
        name     = rtrim_nul(block:sub(1, 100)),
        mode     = parse_octal(block:sub(101, 108)),
        uid      = parse_octal(block:sub(109, 116)),
        gid      = parse_octal(block:sub(117, 124)),
        size     = parse_size_field(block:sub(125, 136)),
        mtime    = parse_octal(block:sub(137, 148)),
        typeflag = block:sub(157, 157),
        linkname = rtrim_nul(block:sub(158, 257)),
        magic    = block:sub(258, 263),
        uname    = rtrim_nul(block:sub(266, 297)),
        gname    = rtrim_nul(block:sub(298, 329)),
        prefix   = rtrim_nul(block:sub(346, 500)),
    }
    -- ustar joins prefix + "/" + name (only when prefix is non-empty).
    if h.magic:sub(1, 5) == "ustar" and h.prefix ~= "" then
        h.name = h.prefix .. "/" .. h.name
    end
    -- Map "\0" typeflag to "0" (regular file) for caller convenience.
    if h.typeflag == "\0" then h.typeflag = "0" end
    return h
end

local function type_name(tf)
    if tf == "0" then return "file"
    elseif tf == "1" then return "hardlink"
    elseif tf == "2" then return "symlink"
    elseif tf == "5" then return "directory"
    elseif tf == "x" then return "pax_header"
    elseif tf == "g" then return "pax_global"
    elseif tf == "L" then return "gnu_long_name"
    elseif tf == "K" then return "gnu_long_link"
    else return "unknown" end
end

-- ===== reader ============================================================

local _reader_mt = {}
_reader_mt.__index = _reader_mt

function _reader_mt:entries()
    local buf = self._buf
    local pos = 1
    -- Pending extended state from a PAX or GNU L/K record.
    local pending_pax  = nil
    local pending_name = nil
    local pending_link = nil
    return function()
        while pos + BLOCK_SIZE - 1 <= #buf do
            local block = buf:sub(pos, pos + BLOCK_SIZE - 1)
            local hdr = parse_header(block)
            if hdr == nil then
                pos = pos + BLOCK_SIZE
                -- Two consecutive NUL records -> archive done.
                if pos + BLOCK_SIZE - 1 <= #buf then
                    local b2 = buf:sub(pos, pos + BLOCK_SIZE - 1)
                    local all_nul = true
                    for i = 1, BLOCK_SIZE do
                        if b2:byte(i) ~= 0 then all_nul = false; break end
                    end
                    if all_nul then return nil end
                end
            else
                local data_start = pos + BLOCK_SIZE
                local data_len   = hdr.size
                local padded     = data_len + (BLOCK_SIZE - data_len % BLOCK_SIZE) % BLOCK_SIZE
                local content    = buf:sub(data_start, data_start + data_len - 1)
                pos = data_start + padded
                if hdr.typeflag == "x" then
                    pending_pax = parse_pax(content)
                elseif hdr.typeflag == "g" then
                    -- Global PAX; ignored for the simple reader path.
                elseif hdr.typeflag == "L" then
                    pending_name = rtrim_nul(content)
                elseif hdr.typeflag == "K" then
                    pending_link = rtrim_nul(content)
                else
                    -- Apply any pending PAX / GNU overrides.
                    if pending_pax then
                        if pending_pax.path then hdr.name = pending_pax.path end
                        if pending_pax.linkpath then hdr.linkname = pending_pax.linkpath end
                        if pending_pax.size then hdr.size = tonumber(pending_pax.size) end
                        if pending_pax.mtime then hdr.mtime = math.floor(tonumber(pending_pax.mtime)) end
                        pending_pax = nil
                    end
                    if pending_name then hdr.name     = pending_name; pending_name = nil end
                    if pending_link then hdr.linkname = pending_link; pending_link = nil end
                    return {
                        name     = hdr.name,
                        type     = type_name(hdr.typeflag),
                        size     = hdr.size,
                        mtime    = hdr.mtime,
                        mode     = hdr.mode,
                        uname    = hdr.uname,
                        gname    = hdr.gname,
                        linkname = hdr.linkname ~= "" and hdr.linkname or nil,
                        content  = (hdr.typeflag == "0") and content or nil,
                    }
                end
            end
        end
        return nil
    end
end

function _reader_mt:read_all()
    local out = {}
    for e in self:entries() do
        out[#out + 1] = e
    end
    return out
end

function M.reader(bytes_or_path)
    if type(bytes_or_path) ~= "string" then
        error("tar.reader: expected string (bytes or path)")
    end
    -- Heuristic: if the first block looks like a tar header (magic at
    -- bytes 258..262), treat as bytes; otherwise it's a path.
    local buf
    if #bytes_or_path >= BLOCK_SIZE
       and bytes_or_path:sub(258, 262) == "ustar" then
        buf = bytes_or_path
    else
        buf = read_file(bytes_or_path)
    end
    return setmetatable({ _buf = buf }, _reader_mt)
end

-- ===== writer ============================================================

local _writer_mt = {}
_writer_mt.__index = _writer_mt

local function pad_block(s)
    local rem = #s % BLOCK_SIZE
    if rem == 0 then return s end
    return s .. string.rep("\0", BLOCK_SIZE - rem)
end

local function format_octal(value, width)
    -- Width-1 octal digits + trailing NUL. value clamped to fit.
    local s = string.format("%0" .. (width - 1) .. "o", value)
    if #s >= width then s = s:sub(-(width - 1)) end
    return s .. "\0"
end

-- For size fields that overflow octal (12 chars = up to 8 GiB), use
-- GNU base-256: top bit set in byte 0, then big-endian binary.
local function format_size(value, width)
    local cap = math.pow and math.pow(8, width - 1) or 8^(width - 1)
    if value < cap then
        return format_octal(value, width)
    end
    local bytes, v = {}, value
    for _ = 1, width - 1 do
        table.insert(bytes, 1, string.char(v % 256))
        v = math.floor(v / 256)
    end
    table.insert(bytes, 1, string.char(0x80))
    return table.concat(bytes)
end

local function build_ustar_header(name, opts)
    opts = opts or {}
    local prefix = ""
    local stem   = name
    if #name > 100 then
        -- Try splitting at a "/" so the head goes in prefix.
        local cut
        for i = math.min(#name, 155), 1, -1 do
            if name:sub(i, i) == "/" and (#name - i) <= 100 then
                cut = i; break
            end
        end
        if cut then
            prefix = name:sub(1, cut - 1)
            stem   = name:sub(cut + 1)
        else
            return nil  -- caller emits PAX / GNU L instead
        end
    end
    if #prefix > 155 then return nil end
    local typeflag = opts.typeflag or "0"
    local link     = opts.linkname or ""
    local mode     = opts.mode or 0644
    local uid      = opts.uid or 0
    local gid      = opts.gid or 0
    local size     = opts.size or 0
    local mtime    = opts.mtime or os.time()
    local uname    = opts.uname or "root"
    local gname    = opts.gname or "root"
    local function pad(s, n)
        if #s >= n then return s:sub(1, n) end
        return s .. string.rep("\0", n - #s)
    end
    local header = pad(stem, 100)
        .. format_octal(mode, 8)
        .. format_octal(uid,  8)
        .. format_octal(gid,  8)
        .. format_size(size, 12)
        .. format_octal(mtime, 12)
        .. string.rep(" ", 8)            -- placeholder for checksum
        .. typeflag
        .. pad(link, 100)
        .. "ustar\0"
        .. "00"
        .. pad(uname, 32)
        .. pad(gname, 32)
        .. format_octal(0, 8)            -- devmajor
        .. format_octal(0, 8)            -- devminor
        .. pad(prefix, 155)
    header = header .. string.rep("\0", BLOCK_SIZE - #header)
    -- Compute checksum + patch it in (bytes 149..156).
    local sum = header_checksum(header)
    local chk = format_octal(sum, 8)
    -- ustar quirk: 6 octal digits + NUL + space.
    chk = string.format("%06o\0 ", sum)
    header = header:sub(1, 148) .. chk .. header:sub(157)
    return header
end

-- Emit a PAX extended header that overrides keys for the next entry.
local function build_pax_record(pairs_table)
    local out = {}
    for k, v in pairs(pairs_table) do
        -- "<len> <k>=<v>\n" where len includes its own digits.
        -- Iterate to find a self-consistent length.
        local body = " " .. k .. "=" .. tostring(v) .. "\n"
        local len, prev
        repeat
            prev = len
            len = #body + #tostring(#body + (prev or 0))
        until len == prev
        out[#out + 1] = tostring(len) .. body
    end
    return table.concat(out)
end

function _writer_mt:_emit(s)
    self._fp:write(s)
    self._offset = self._offset + #s
end

function _writer_mt:_write_entry(name, content, opts)
    opts = opts or {}
    opts.size = content and #content or 0
    local hdr = build_ustar_header(name, opts)
    if hdr == nil then
        -- Name too long for ustar -- emit a PAX 'x' extended header.
        local pax_content = build_pax_record({ path = name })
        local pax_hdr = build_ustar_header("PaxHeader/" .. tostring(self._pax_seq),
            { typeflag = "x", size = #pax_content })
        self._pax_seq = self._pax_seq + 1
        self:_emit(pax_hdr)
        self:_emit(pad_block(pax_content))
        -- Now emit the real entry with a truncated name (PAX overrides it).
        opts.size = content and #content or 0
        hdr = build_ustar_header(name:sub(1, 100), opts)
    end
    self:_emit(hdr)
    if content and #content > 0 then
        self:_emit(pad_block(content))
    end
end

function _writer_mt:add_file(name, bytes, opts)
    opts = opts or {}
    opts.typeflag = "0"
    self:_write_entry(name, bytes, opts)
end

function _writer_mt:add_directory(name, opts)
    if name:sub(-1) ~= "/" then name = name .. "/" end
    opts = opts or {}
    opts.typeflag = "5"
    opts.mode = opts.mode or 0755
    self:_write_entry(name, nil, opts)
end

function _writer_mt:add_symlink(name, target, opts)
    opts = opts or {}
    opts.typeflag = "2"
    opts.linkname = target
    self:_write_entry(name, nil, opts)
end

function _writer_mt:close()
    -- Trailer: two NUL records + pad to 10240-byte ("blocking factor 20").
    self:_emit(string.rep("\0", BLOCK_SIZE * 2))
    local rem = self._offset % 10240
    if rem ~= 0 then
        self:_emit(string.rep("\0", 10240 - rem))
    end
    self._fp:close()
    return self._offset
end

function M.writer(path)
    local fp = io.open(path, "wb")
    if not fp then error("tar.writer: cannot create " .. path) end
    return setmetatable({
        _fp      = fp,
        _offset  = 0,
        _pax_seq = 0,
    }, _writer_mt)
end

-- ===== Spec-shaped facade (open / list / read / extract_all / iter) ======

local function _path_join(dest, name)
    if dest:sub(-1) == "/" or dest:sub(-1) == "\\" then
        return dest .. name
    end
    return dest .. "/" .. name
end

-- Reject tar entry names that would escape the destination directory
-- (Zip-Slip / CWE-22): an absolute path, a Windows drive prefix, or any ".."
-- path segment. tar header names carry no integrity binding, so a crafted
-- archive can otherwise write arbitrary files. Raises on a hostile name.
local function _safe_entry_name(name)
    local n = name:gsub("\\", "/")
    if n:sub(1, 1) == "/" or n:match("^%a:") then
        error("tar.extract_all: refusing absolute path in archive entry: " .. name)
    end
    for seg in (n .. "/"):gmatch("([^/]*)/") do
        if seg == ".." then
            error("tar.extract_all: refusing path traversal ('..') in entry: " .. name)
        end
    end
end

local function _ensure_dir(path)
    if path == nil or path == "" or path == "." then return end
    os.execute(string.format('mkdir "%s" 2>nul', path:gsub("/", "\\")))
end

local function _dirname(path)
    local p = path:gsub("\\", "/")
    local i = p:find("/[^/]*$")
    if i then return p:sub(1, i - 1) end
    return ""
end

local function _reader_facade(r)
    return {
        list = function()
            local out = {}
            for e in r:entries() do
                out[#out + 1] = {
                    name     = e.name,
                    size     = e.size,
                    mtime    = e.mtime,
                    mode     = e.mode,
                    type     = e.type,
                    linkname = e.linkname,
                }
            end
            return out
        end,
        read = function(self, name)
            if type(self) == "string" then name = self end
            for e in r:entries() do
                if e.name == name then
                    return e.content or ""
                end
            end
            error("tar.read: entry not found: " .. tostring(name))
        end,
        extract_all = function(self, dest)
            if type(self) == "string" then dest = self end
            _ensure_dir(dest)
            local out = {}
            for e in r:entries() do
                _safe_entry_name(e.name)
                local target = _path_join(dest, e.name)
                if e.type == "directory" then
                    _ensure_dir(target)
                elseif e.type == "file" then
                    _ensure_dir(_dirname(target))
                    local f = io.open(target, "wb")
                    if not f then error("tar.extract_all: cannot write " .. target) end
                    f:write(e.content or "")
                    f:close()
                    out[#out + 1] = target
                end
                -- symlink / hardlink: skipped in pure-Lua extract.
            end
            return out
        end,
        iter = function()
            return r:entries()
        end,
        _reader = r,
    }
end

function M.open(path_or_bytes)
    if type(path_or_bytes) ~= "string" then
        error("tar.open: expected path or bytes")
    end
    local buf
    if #path_or_bytes >= BLOCK_SIZE
       and path_or_bytes:sub(258, 262) == "ustar" then
        buf = path_or_bytes
    else
        local f = io.open(path_or_bytes, "rb")
        if not f then error("tar.open: cannot open " .. path_or_bytes) end
        buf = f:read("*a"); f:close()
    end
    local r = setmetatable({ _buf = buf }, _reader_mt)
    return _reader_facade(r)
end

local function _slurp(path)
    local f = io.open(path, "rb")
    if not f then error("tar: cannot open " .. tostring(path)) end
    local s = f:read("*a"); f:close()
    return s
end

local function _writer_facade(w)
    return {
        add_file = function(self, name, bytes, opts)
            if type(self) == "string" then
                opts  = bytes; bytes = name; name = self
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
        add_directory = function(self, name, opts)
            if type(self) == "string" then opts = name; name = self end
            w:add_directory(name, opts)
        end,
        add_symlink = function(self, name, target, opts)
            if type(self) == "string" then
                opts = target; target = name; name = self
            end
            w:add_symlink(name, target, opts)
        end,
        close = function() return w:close() end,
        _writer = w,
    }
end

function M.create(path)
    if type(path) ~= "string" then error("tar.create: path required") end
    local fp = io.open(path, "wb")
    if not fp then error("tar.create: cannot create " .. path) end
    local w = setmetatable({
        _fp      = fp,
        _offset  = 0,
        _pax_seq = 0,
    }, _writer_mt)
    return _writer_facade(w)
end

-- ===== gzip / gunzip helpers (tar.gz convenience wrappers) ===============
-- Soft require on zlib so callers without a DEFLATE backend still get a
-- functional tar package.

local _zlib_ok, zlib = pcall(require, "zlib")
if not _zlib_ok then zlib = nil end

function M.gzip(path_in, path_out)
    if not zlib then error("tar.gzip: zlib package required") end
    local body = _slurp(path_in)
    local f = io.open(path_out, "wb")
    if not f then error("tar.gzip: cannot create " .. path_out) end
    f:write(zlib.gzip_compress(body))
    f:close()
    return path_out
end

function M.gunzip(path_in, path_out)
    if not zlib then error("tar.gunzip: zlib package required") end
    local body = _slurp(path_in)
    local plain = zlib.gzip_decompress(body)
    local f = io.open(path_out, "wb")
    if not f then error("tar.gunzip: cannot create " .. path_out) end
    f:write(plain)
    f:close()
    return path_out
end

return M
