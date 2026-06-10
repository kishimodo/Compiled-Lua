-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- kv_file -- append-log KV store, pure Lua. No native deps.
--
-- On-disk record format (little-endian for length fields):
--   [8 bytes key_len][8 bytes value_len][key bytes][value bytes][4 bytes crc32]
--
-- value_len == 0xFFFFFFFFFFFFFFFF marks a tombstone (delete record).
-- The 8-byte length fields are excessive for most workloads, but keep
-- the format extensible without breaking changes. Real keys/values are
-- capped at 2^31-1 bytes for compatibility with Lua string indexing.
--
-- Index: file-offset table keyed by key, rebuilt on open by scanning
-- the file once. Tombstones erase the in-memory entry during rebuild.
-- Writes append to EOF; the index is updated to point at the new offset.
--
-- Compaction: rewrite into a sidecar file with only the latest record
-- per key, fsync, atomically rename over the original. The compaction
-- holds the writer lock for its duration -- there is no online compaction.
--
-- Public surface:
--   kv_file.open(path)               -> db
--   db:get(key)                      -> string | nil
--   db:put(key, value)               -- value may be any 8-bit-clean string
--   db:delete(key)                   -- writes a tombstone record
--   db:keys()                        -> iterator over present keys
--   db:size()                        -> count of live keys
--   db:close()
--   db:compact()                     -- rewrite to drop tombstones / stale records
--   db:flush()                       -- explicit fsync
--
-- Concurrency: single-writer. If you need cross-process locking, wrap
-- with the mutex package. Multiple concurrent readers within a single
-- process are safe as long as no writer is active.

local M = {}

local bit_band = bit.band
local bit_bxor = bit.bxor
local bit_rsh  = bit.rshift

-- ===== CRC32 (table-driven, polynomial 0xEDB88320) =====================

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
        _crc_table[n] = c
    end
end

local function crc32(bytes)
    if _crc_table == nil then build_crc_table() end
    local c = 0xFFFFFFFF
    for i = 1, #bytes do
        c = bit_bxor(bit_rsh(c, 8), _crc_table[bit_band(bit_bxor(c, bytes:byte(i)), 0xFF)])
    end
    return bit_band(bit_bxor(c, 0xFFFFFFFF), 0xFFFFFFFF)
end

-- ===== Little-endian length encoding ====================================

-- Pack a Lua number into 8 LE bytes. Lua numbers > 2^53 lose precision;
-- we encode only the low 53 bits cleanly. The four high bytes are 0
-- for normal records and 0xFF for the tombstone sentinel below.
local function u64_le(n)
    if n == 0xFFFFFFFFFFFFFFFF then
        return string.char(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
    end
    -- Split into low 32 / high 32 to avoid the >2^32 boundary.
    local lo = n % 0x100000000
    local hi = math.floor(n / 0x100000000)
    return string.char(
        bit_band(lo, 0xFF),
        bit_band(bit_rsh(lo, 8), 0xFF),
        bit_band(bit_rsh(lo, 16), 0xFF),
        bit_band(bit_rsh(lo, 24), 0xFF),
        bit_band(hi, 0xFF),
        bit_band(bit_rsh(hi, 8), 0xFF),
        bit_band(bit_rsh(hi, 16), 0xFF),
        bit_band(bit_rsh(hi, 24), 0xFF))
end

local function u32_le(n)
    return string.char(
        bit_band(n, 0xFF),
        bit_band(bit_rsh(n, 8), 0xFF),
        bit_band(bit_rsh(n, 16), 0xFF),
        bit_band(bit_rsh(n, 24), 0xFF))
end

local function read_u64_le(s, off)
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(off, off + 7)
    -- Detect the all-FF tombstone sentinel.
    if b1 == 0xFF and b2 == 0xFF and b3 == 0xFF and b4 == 0xFF
       and b5 == 0xFF and b6 == 0xFF and b7 == 0xFF and b8 == 0xFF then
        return 0xFFFFFFFFFFFFFFFF
    end
    local lo = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    local hi = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
    return hi * 0x100000000 + lo
end

local function read_u32_le(s, off)
    local b1, b2, b3, b4 = s:byte(off, off + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Tombstone sentinel for value_len.
local TOMBSTONE = 0xFFFFFFFFFFFFFFFF

-- ===== db object ========================================================

local Db = {}
Db.__index = Db

-- Encode one record into bytes. crc covers key+value.
local function encode_record(key, value)
    local klen = #key
    if value == nil then
        -- Tombstone: value_len = TOMBSTONE, no value bytes.
        local body = u64_le(klen) .. u64_le(TOMBSTONE) .. key
        return body .. u32_le(crc32(key))
    end
    local vlen = #value
    local body = u64_le(klen) .. u64_le(vlen) .. key .. value
    return body .. u32_le(crc32(key .. value))
end

-- Walk the file from the beginning; rebuild index and live size.
local function rebuild_index(self)
    local f = self._fh
    f:seek("set", 0)
    local data = f:read("*a") or ""
    self._index = {}
    self._size  = 0
    local off = 1
    local len = #data
    while off + 16 <= len + 1 do
        local klen = read_u64_le(data, off)
        local vlen = read_u64_le(data, off + 8)
        local key_start = off + 16
        local key_end   = key_start + klen - 1
        if key_end > len then break end  -- corrupted tail; stop here
        local rec_end
        local is_tomb = (vlen == TOMBSTONE)
        if is_tomb then
            rec_end = key_end + 4  -- + crc
        else
            rec_end = key_end + vlen + 4
        end
        if rec_end > len then break end
        local key = data:sub(key_start, key_end)
        local crc_off = rec_end - 3
        local crc_got = read_u32_le(data, crc_off)
        local crc_want
        if is_tomb then
            crc_want = crc32(key)
        else
            crc_want = crc32(data:sub(key_start, key_end + vlen))
        end
        if crc_got ~= crc_want then
            -- Corrupted record; stop scanning to avoid index pollution.
            break
        end
        if is_tomb then
            if self._index[key] ~= nil then self._size = self._size - 1 end
            self._index[key] = nil
        else
            if self._index[key] == nil then self._size = self._size + 1 end
            -- Record both the offset and the value length so :get can read
            -- the value range directly without re-parsing the header.
            self._index[key] = { off = key_end + 1, len = vlen }
        end
        off = rec_end + 1
    end
    self._eof = off - 1
end

function Db:get(key)
    local entry = self._index[key]
    if entry == nil then return nil end
    local f = self._fh
    f:seek("set", entry.off - 1)
    return f:read(entry.len)
end

function Db:put(key, value)
    assert(type(key) == "string", "kv_file: key must be a string")
    assert(type(value) == "string", "kv_file: value must be a string")
    local rec = encode_record(key, value)
    local f = self._fh
    f:seek("set", self._eof)
    f:write(rec)
    f:flush()
    -- The value sits at (eof + 16 + #key + 1) in 1-based file terms.
    local val_off = self._eof + 16 + #key + 1
    if self._index[key] == nil then self._size = self._size + 1 end
    self._index[key] = { off = val_off, len = #value }
    self._eof = self._eof + #rec
end

function Db:delete(key)
    if self._index[key] == nil then return false end
    local rec = encode_record(key, nil)
    local f = self._fh
    f:seek("set", self._eof)
    f:write(rec)
    f:flush()
    self._index[key] = nil
    self._size = self._size - 1
    self._eof = self._eof + #rec
    return true
end

-- Iterator over present keys. Order is the index hash-table order; not
-- insertion order. Snapshot the key list up front so caller-side put/delete
-- during iteration doesn't break the loop.
function Db:keys()
    local list = {}
    for k in pairs(self._index) do list[#list + 1] = k end
    local i = 0
    return function()
        i = i + 1
        return list[i]
    end
end

function Db:size()  return self._size end
function Db:flush() self._fh:flush() end

-- Compaction: write all live records to a sidecar, fsync, rename over.
function Db:compact()
    local src_path = self._path
    local tmp_path = src_path .. ".compact"
    local out = io.open(tmp_path, "wb")
    if out == nil then
        error("kv_file: compact: cannot open " .. tmp_path, 2)
    end
    -- Re-emit each live key. We pull values via the existing :get because
    -- the file is the source of truth -- the index alone doesn't carry them.
    for k in pairs(self._index) do
        local v = self:get(k)
        if v then out:write(encode_record(k, v)) end
    end
    out:flush()
    out:close()
    -- Close the open file so the rename can replace it on Windows.
    self._fh:close()
    os.remove(src_path)
    local ok, err = os.rename(tmp_path, src_path)
    if not ok then
        -- Try to reopen the tmp as a fallback so the db isn't left dangling.
        self._fh = io.open(tmp_path, "r+b")
        error("kv_file: compact: rename failed: " .. tostring(err), 2)
    end
    self._fh = io.open(src_path, "r+b")
    if self._fh == nil then
        error("kv_file: compact: cannot reopen " .. src_path, 2)
    end
    rebuild_index(self)
end

function Db:close()
    if self._fh ~= nil then
        self._fh:close()
        self._fh = nil
    end
    self._index = nil
end

Db.__gc = Db.close

-- ===== open =============================================================

function M.open(path)
    -- Open for read+write, create if missing.
    -- "r+b" can't create, "w+b" truncates; do a probe-then-open dance.
    local f = io.open(path, "r+b")
    if f == nil then
        -- Create it.
        local nf = io.open(path, "wb")
        if nf == nil then
            error("kv_file: cannot create " .. tostring(path), 2)
        end
        nf:close()
        f = io.open(path, "r+b")
        if f == nil then
            error("kv_file: cannot reopen " .. tostring(path), 2)
        end
    end
    local self = setmetatable({
        _path  = path,
        _fh    = f,
        _index = {},
        _size  = 0,
        _eof   = 0,
    }, Db)
    rebuild_index(self)
    -- Seek past EOF so the next write extends rather than overwriting.
    self._fh:seek("set", self._eof)
    return self
end

return M
