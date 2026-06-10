-- snapshot -- snapshot / golden testing.
--
-- Compares a value to a previously-stored snapshot file. On the first run the
-- snapshot is created automatically; subsequent runs must match or the
-- assertion fails. Updating an existing snapshot requires the user to set
-- the UPDATE_SNAPSHOTS env var or pass `update=true` to `match`.
--
-- Public surface:
--   snapshot.match(actual, name?, opts?)      auto-derives `name` from caller info if absent
--   snapshot.match(name, value, opts?)        legacy/explicit form (kept for back-compat)
--   snapshot.set_dir(path)                    override default __snapshots__ dir
--   snapshot.set_test_file(path)              override auto-detected caller file
--   snapshot.serialize(value, fmt?)           value -> string in the chosen format
--   snapshot.update(on?)                      force "update on mismatch" mode for the session
--   snapshot.is_update_mode()                 -> bool (env var or update() flag set)
--
-- Env var: LUAVM_UPDATE_SNAPSHOTS=1 (preferred), UPDATE_SNAPSHOTS=1 (legacy) -> overwrite stored snapshots.
--
-- opts:
--   format     "json" | "text" | "lua_repr"   default "lua_repr"
--   normalize  fn(value) -> normalized       run before serialize (mask volatile fields)
--   update     bool                          force overwrite (overrides env)
--   dir        string                        snapshot directory override
--   ext        string                        file extension (default per format)
--
-- File layout: <dir>/<test_file_stem>.snap.lua holds a single returned table
-- keyed by snapshot name. We always store text inside Lua tables so a single
-- file holds many snapshots and is checked into source control.

local M = {}

local _state = {
    dir         = nil,
    test_file   = nil,
    update_mode = false,
    snap_counts = {},  -- per-file counter for auto-named snapshots
}

function M.set_dir(path)        _state.dir       = path end
function M.set_test_file(path)  _state.test_file = path end

-- Force "update on mismatch" mode programmatically (env var also works).
function M.update(on)
    if on == nil then on = true end
    _state.update_mode = on and true or false
end

function M.is_update_mode()
    if _state.update_mode then return true end
    local g = os.getenv
    if not g then return false end
    local a = g("LUAVM_UPDATE_SNAPSHOTS")
    if a == "1" or a == "true" then return true end
    local b = g("UPDATE_SNAPSHOTS")
    if b == "1" or b == "true" then return true end
    return false
end

-- ===== Serializers ====================================================

local function lua_repr(v, depth, seen)
    depth = depth or 0
    seen  = seen or {}
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v then return "0/0"  -- NaN
        elseif v == math.huge then return "math.huge"
        elseif v == -math.huge then return "-math.huge" end
        return tostring(v)
    end
    if t == "string" then return string.format("%q", v) end
    if t == "table" then
        if seen[v] then return '"<cycle>"' end
        seen[v] = true
        if depth > 32 then return '"<too deep>"' end
        local pad = string.rep("  ", depth)
        local inner_pad = string.rep("  ", depth + 1)
        -- Array portion first.
        local n = #v
        local has_only_array = true
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                has_only_array = false; break
            end
        end
        local parts = {}
        if has_only_array then
            for i = 1, n do
                parts[#parts + 1] = inner_pad .. lua_repr(v[i], depth + 1, seen) .. ","
            end
        else
            -- emit array part
            for i = 1, n do
                parts[#parts + 1] = inner_pad .. lua_repr(v[i], depth + 1, seen) .. ","
            end
            -- collect non-numeric keys, sort them
            local skeys = {}
            for k in pairs(v) do
                if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                    skeys[#skeys + 1] = k
                end
            end
            table.sort(skeys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(skeys) do
                local key_str
                if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then
                    key_str = k .. " = "
                else
                    key_str = "[" .. lua_repr(k, depth + 1, seen) .. "] = "
                end
                parts[#parts + 1] = inner_pad .. key_str .. lua_repr(v[k], depth + 1, seen) .. ","
            end
        end
        seen[v] = nil
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, "\n") .. "\n" .. pad .. "}"
    end
    return string.format("%q", "<" .. t .. ">")
end

local function serialize(value, fmt)
    fmt = fmt or "lua_repr"
    if fmt == "text" then
        if type(value) == "string" then return value end
        return tostring(value)
    elseif fmt == "json" then
        -- Lightweight JSON emitter to avoid hard-coupling to the `json` package.
        local function enc(v)
            local t = type(v)
            if t == "nil" then return "null"
            elseif t == "boolean" then return tostring(v)
            elseif t == "number" then
                if v ~= v or v == math.huge or v == -math.huge then return "null" end
                return tostring(v)
            elseif t == "string" then
                local esc = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                                :gsub('\r', '\\r'):gsub('\t', '\\t')
                return '"' .. esc .. '"'
            elseif t == "table" then
                local n = #v
                local is_arr = true
                for k in pairs(v) do
                    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                        is_arr = false; break
                    end
                end
                if is_arr then
                    local parts = {}
                    for i = 1, n do parts[i] = enc(v[i]) end
                    return "[" .. table.concat(parts, ",") .. "]"
                else
                    local keys = {}
                    for k in pairs(v) do keys[#keys + 1] = k end
                    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
                    local parts = {}
                    for _, k in ipairs(keys) do
                        parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(v[k])
                    end
                    return "{" .. table.concat(parts, ",") .. "}"
                end
            end
            return "null"
        end
        return enc(value)
    end
    return lua_repr(value, 0)
end

M.serialize = serialize

-- ===== Caller resolution =============================================

-- Walk back through debug.getinfo to find the first caller outside this file.
local function detect_test_file()
    if _state.test_file then return _state.test_file end
    if not debug or not debug.getinfo then return "unknown" end
    local me = debug.getinfo(1, "S").source
    local level = 2
    while true do
        local info = debug.getinfo(level, "S")
        if not info then break end
        if info.source ~= me and info.source:sub(1, 1) == "@" then
            return info.source:sub(2)
        end
        level = level + 1
    end
    return "unknown"
end

local function file_stem(path)
    local stem = path:match("([^/\\]+)$") or path
    stem = stem:gsub("%.lua$", "")
    return stem
end

local function dir_of(path)
    local d = path:match("^(.*[/\\])")
    if d then return d end
    return "./"
end

-- ===== Snapshot store I/O ============================================
--
-- File format is itself executable Lua. Each snapshot is one entry in a
-- table that the file returns. We escape `]]` cleverly by using a unique
-- equals-padded long-bracket level.

local function escape_long(s)
    -- Find a long-bracket level not present in s.
    local level = 0
    while true do
        local closer = "]" .. string.rep("=", level) .. "]"
        if not string.find(s, closer, 1, true) then return level end
        level = level + 1
    end
end

local function load_store(path)
    local f = io.open(path, "rb")
    if not f then return {} end
    local body = f:read("*a")
    f:close()
    local chunk, err = load(body, "@" .. path, "t", {})
    if not chunk then
        error("snapshot: failed to load store: " .. tostring(err))
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then return {} end
    return result
end

local function save_store(path, store)
    -- Ensure directory exists. We use mkdir via os.execute as a best effort.
    local d = dir_of(path)
    if d and d ~= "" and d ~= "./" then
        -- Probe by trying to open a sentinel; create dir if needed.
        local probe = io.open(d .. ".snapshot_probe", "wb")
        if not probe then
            -- Try mkdir; on Windows this is fine.
            os.execute('mkdir "' .. d:gsub("/", "\\"):gsub("\\$", "") .. '" 2>nul')
        else
            probe:close()
            os.remove(d .. ".snapshot_probe")
        end
    end
    local f, err = io.open(path, "wb")
    if not f then error("snapshot: cannot write store " .. path .. ": " .. tostring(err)) end
    f:write("-- snapshot store (auto-generated; commit this file)\n")
    f:write("return {\n")
    -- Sort keys for deterministic output.
    local keys = {}
    for k in pairs(store) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local body = store[k]
        local lvl = escape_long(body)
        local pad = string.rep("=", lvl)
        f:write(string.format("    [%q] = [%s[\n%s]%s],\n", k, pad, body, pad))
    end
    f:write("}\n")
    f:close()
end

-- ===== Diff ==========================================================

local function line_split(s)
    local lines, n = {}, 0
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1; lines[n] = line
    end
    return lines, n
end

local function diff(expected, actual)
    local e_lines, en = line_split(expected)
    local a_lines, an = line_split(actual)
    local out = {}
    local i, j = 1, 1
    local max = math.max(en, an)
    for k = 1, max do
        local e = e_lines[k]
        local a = a_lines[k]
        if e == a then
            out[#out + 1] = "  " .. (e or "")
        else
            if e ~= nil then out[#out + 1] = "- " .. e end
            if a ~= nil then out[#out + 1] = "+ " .. a end
        end
    end
    return table.concat(out, "\n")
end

-- ===== match =========================================================

local function should_update(opts)
    if opts.update == true then return true end
    if opts.update == false then return false end
    if _state.update_mode then return true end
    -- Env var fallback (LUAVM_UPDATE_SNAPSHOTS preferred; UPDATE_SNAPSHOTS legacy).
    local g = os.getenv
    if not g then return false end
    local a = g("LUAVM_UPDATE_SNAPSHOTS")
    if a == "1" or a == "true" then return true end
    local b = g("UPDATE_SNAPSHOTS")
    return b == "1" or b == "true"
end

-- Auto-derive a snapshot name from caller's line + per-file counter so calls
-- like `snapshot.match(value)` work without explicit naming.
local function auto_name(test_file)
    local n = (_state.snap_counts[test_file] or 0) + 1
    _state.snap_counts[test_file] = n
    return string.format("snap_%03d", n)
end

-- Detect call style: snapshot.match(actual, name?, opts?) or legacy
--                    snapshot.match(name, value, opts?).
-- We treat first-arg-is-string + second-arg-not-nil-or-table as legacy.
function M.match(a, b, c)
    local name, value, opts
    if type(a) == "string" and b ~= nil and type(b) ~= "table" then
        -- legacy form: (name, value, opts?)
        name, value, opts = a, b, c
    elseif type(a) == "string" and (b == nil or type(b) == "table") and c == nil then
        -- ambiguous: could be (actual_string, opts?) -- prefer new form.
        value, opts = a, b
    else
        value, name, opts = a, b, c
    end
    opts = opts or {}
    local v = value
    if opts.normalize then v = opts.normalize(v) end
    local serialized = serialize(v, opts.format)

    local test_file = detect_test_file()
    local dir = opts.dir or _state.dir or (dir_of(test_file) .. "__snapshots__/")
    -- normalize separator
    dir = dir:gsub("\\", "/")
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    local store_path = dir .. file_stem(test_file) .. ".snap.lua"

    -- Auto-name when caller omitted the name argument.
    if not name then name = auto_name(store_path) end

    local store = load_store(store_path)
    local existing = store[name]

    if existing == nil then
        store[name] = serialized
        save_store(store_path, store)
        return {
            ok      = true,
            created = true,
            path    = store_path,
            name    = name,
        }
    end

    if existing == serialized then
        return { ok = true, path = store_path, name = name }
    end

    if should_update(opts) then
        store[name] = serialized
        save_store(store_path, store)
        return {
            ok      = true,
            updated = true,
            path    = store_path,
            name    = name,
        }
    end

    local d = diff(existing, serialized)
    local msg = string.format(
        "snapshot mismatch: %s [%s]\n%s\n(rerun with LUAVM_UPDATE_SNAPSHOTS=1 to overwrite)",
        name, store_path, d)
    error(msg, 2)
end

return M
