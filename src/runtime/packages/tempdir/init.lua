-- tempdir -- RAII temp file / directory helpers.
--
-- Public surface:
--   tempdir.tempfile(opts?)  -> path, handle
--   tempdir.tempdir(opts?)   -> path, handle
--   tempdir.with_tempdir(fn) -> result of fn(path); cleans up afterwards
--   tempdir.with_tempfile(fn)
--   tempdir.cleanup()        -> remove every tracked entry now
--
-- opts = { prefix=, suffix=, dir=, keep=false }
--   prefix : leading text of the temp name (default "lvm_")
--   suffix : trailing text/extension (default "" for dir, ".tmp" for file)
--   dir    : parent directory (default GetTempPathW)
--   keep   : if true, do not delete on close/exit
--
-- The handle has :path() and :close_and_remove() (file) or :remove() (dir).

local W   = require "windows"
local _FSW = require "windows.filesystem"
local fs   = require "fs"
local path = require "path"

local C   = ffi.C
local M   = {}

ffi.cdef[[
DWORD GetTempPathW(DWORD, unsigned short *);
]]

-- Tracked entries -- a weak-keyed map would lose them as soon as the
-- handle is gc'd, but we want to *also* clean up at process exit. So we
-- keep a strong list of {path=, kind=, removed=, keep=} records and a
-- separate finalizer object attached to each handle that removes the
-- entry from the list.

local _entries = {}     -- index -> entry table
local _next_id = 0

local function default_temp_dir()
    local buf = ffi.new("unsigned short[260]")
    local n = C.GetTempPathW(260, buf)
    if n == 0 then return "." end
    -- Convert to UTF-8.
    local need = C.WideCharToMultiByte(65001, 0, buf, n, nil, 0, nil, nil)
    if need <= 0 then return "." end
    local out = ffi.new("char[?]", need + 1)
    C.WideCharToMultiByte(65001, 0, buf, n, out, need, nil, nil)
    return ffi.string(out, need)
end

-- Cryptographically OK-enough name generator. We mix the process id,
-- a per-call counter, and math.random.
local _counter = 0
local function random_suffix(nbytes)
    _counter = _counter + 1
    local parts = {}
    parts[#parts + 1] = string.format("%x", tonumber(C.GetCurrentProcessId()))
    parts[#parts + 1] = string.format("%x", _counter)
    parts[#parts + 1] = string.format("%x", math.random(1, 2^31))
    -- Mix in a fast tick for variety.
    parts[#parts + 1] = string.format("%x", tonumber(C.GetTickCount64()) % 0xFFFFFFFF)
    return table.concat(parts, "")
end

local function unique_path(base_dir, prefix, suffix)
    -- Try up to N times; collisions are virtually impossible but the loop is cheap.
    for _ = 1, 64 do
        local name = (prefix or "lvm_") .. random_suffix() .. (suffix or "")
        local full = path.join(base_dir, name)
        if not fs.exists(full) then return full end
    end
    return nil, "tempdir: could not generate unique path after 64 tries"
end

local function track(p, kind, keep)
    _next_id = _next_id + 1
    local id = _next_id
    local entry = { id = id, path = p, kind = kind, removed = false, keep = keep }
    _entries[id] = entry
    return entry
end

local function remove_entry(entry)
    if entry.removed then return true end
    entry.removed = true
    _entries[entry.id] = nil
    if entry.keep then return true end
    if entry.kind == "file" then
        return fs.remove(entry.path)
    else
        return fs.rmdir(entry.path, true)
    end
end

-- ===== Handle metatables ================================================

local file_mt = { __index = {} }

function file_mt.__index:path() return self._entry.path end
function file_mt.__index:close_and_remove()
    return remove_entry(self._entry)
end
file_mt.__index.remove = file_mt.__index.close_and_remove
file_mt.__gc = function(self)
    -- Best-effort cleanup; ignore errors during GC.
    pcall(remove_entry, self._entry)
end

local dir_mt = { __index = {} }

function dir_mt.__index:path() return self._entry.path end
function dir_mt.__index:remove()
    return remove_entry(self._entry)
end
dir_mt.__gc = function(self)
    pcall(remove_entry, self._entry)
end

-- ===== Public API =======================================================

function M.tempfile(opts)
    opts = opts or {}
    local dir = opts.dir or default_temp_dir()
    local p, err = unique_path(dir, opts.prefix or "lvm_", opts.suffix or ".tmp")
    if not p then return nil, err end
    -- Create an empty file so the path is reserved against TOCTOU collisions.
    local ok, werr = fs.write(p, "")
    if not ok then return nil, werr end
    local entry = track(p, "file", opts.keep == true)
    local handle = setmetatable({ _entry = entry }, file_mt)
    return p, handle
end

function M.tempdir(opts)
    opts = opts or {}
    local parent = opts.dir or default_temp_dir()
    local p, err = unique_path(parent, opts.prefix or "lvm_", opts.suffix or "")
    if not p then return nil, err end
    local ok, werr = fs.mkdir(p)
    if not ok then return nil, werr end
    local entry = track(p, "dir", opts.keep == true)
    local handle = setmetatable({ _entry = entry }, dir_mt)
    return p, handle
end

function M.with_tempdir(fn, opts)
    local p, handle = M.tempdir(opts)
    if not p then return nil, handle end
    local ok, result = pcall(fn, p)
    remove_entry(handle._entry)
    if not ok then error(result, 2) end
    return result
end

function M.with_tempfile(fn, opts)
    local p, handle = M.tempfile(opts)
    if not p then return nil, handle end
    local ok, result = pcall(fn, p)
    remove_entry(handle._entry)
    if not ok then error(result, 2) end
    return result
end

function M.cleanup()
    -- Snapshot the entries (remove_entry mutates the table).
    local snap = {}
    for k, v in pairs(_entries) do snap[k] = v end
    for _, e in pairs(snap) do
        pcall(remove_entry, e)
    end
end

-- ===== Modern object-oriented API =======================================
--
-- M.new(opts?) returns a tempdir object with the convenience methods
-- :path(), :join(...), :file(name?), :cleanup(). Cleanup runs automatically
-- via __gc unless opts.cleanup is set to false.

local rich_dir_mt = { __index = {} }

function rich_dir_mt.__index:path() return self._entry.path end

function rich_dir_mt.__index:join(...)
    return path.join(self._entry.path, ...)
end

function rich_dir_mt.__index:file(name)
    -- Create a unique file under the temp dir. If `name` is provided we
    -- use it as-is (no uniquification); else we generate one.
    local p
    if name then
        p = path.join(self._entry.path, name)
        local ok, werr = fs.write(p, "")
        if not ok then return nil, werr end
    else
        local p_uniq, err = unique_path(self._entry.path, "f_", ".tmp")
        if not p_uniq then return nil, err end
        local ok, werr = fs.write(p_uniq, "")
        if not ok then return nil, werr end
        p = p_uniq
    end
    return p
end

function rich_dir_mt.__index:write(name, content)
    local p = path.join(self._entry.path, name)
    -- Ensure parent dirs exist.
    local parent = path.dirname(p)
    if parent ~= "" and not fs.is_dir(parent) then
        local ok, werr = fs.mkdir(parent, true)
        if not ok then return nil, werr end
    end
    local ok, werr = fs.write(p, content)
    if not ok then return nil, werr end
    return p
end

function rich_dir_mt.__index:cleanup()
    return remove_entry(self._entry)
end
rich_dir_mt.__index.remove = rich_dir_mt.__index.cleanup

rich_dir_mt.__gc = function(self)
    if self._auto_cleanup then
        pcall(remove_entry, self._entry)
    end
end

function M.new(opts)
    opts = opts or {}
    local parent = opts.root or opts.dir or default_temp_dir()
    local p, err = unique_path(parent, opts.prefix or "luavm_", opts.suffix or "")
    if not p then return nil, err end
    local ok, werr = fs.mkdir(p)
    if not ok then return nil, werr end
    local entry = track(p, "dir", opts.keep == true)
    local handle = setmetatable({
        _entry = entry,
        _auto_cleanup = opts.cleanup ~= false and opts.keep ~= true,
    }, rich_dir_mt)
    return handle
end

-- with(fn, opts?) -- runs fn(tempdir_obj) with auto cleanup.
function M.with(fn, opts)
    local td, err = M.new(opts)
    if not td then return nil, err end
    local ok, result = pcall(fn, td)
    -- Always cleanup, regardless of error.
    pcall(remove_entry, td._entry)
    if not ok then error(result, 2) end
    return result
end

-- ===== Process-exit hook ===============================================
--
-- LuaJIT doesn't expose os.atexit. We register a sentinel userdata whose
-- __gc runs at VM shutdown -- as long as the entries table is still
-- reachable, this fires before final teardown and lets us scrub.
local _exit_sentinel = newproxy and newproxy(true) or setmetatable({}, {})
if newproxy then
    debug.setmetatable(_exit_sentinel, { __gc = function() pcall(M.cleanup) end })
else
    getmetatable(_exit_sentinel).__gc = function() pcall(M.cleanup) end
end
M._exit_sentinel = _exit_sentinel  -- keep a reference

return M
