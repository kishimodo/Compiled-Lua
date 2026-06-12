-- path -- Windows-aware path manipulation. No disk IO.
--
-- Public surface:
--   path.sep            -- "\\"
--   path.altsep         -- "/"
--   path.join(...)      -- concatenate components, inserting separators
--   path.normalize(p)   -- collapse "." and "..", dedup separators
--   path.resolve(...)   -- join + normalize
--   path.split(p)       -- dir, file
--   path.basename(p)    -- final component
--   path.dirname(p)     -- everything but final component
--   path.extname(p)     -- ".ext" (with leading dot) or ""
--   path.stem(p)        -- basename minus extname
--   path.is_absolute(p) -- true for "C:\\", "\\\\server\\share\\", "\\foo", "/foo"
--   path.is_relative(p)
--   path.relative(from, to)
--   path.to_posix(p)    -- forward slashes
--   path.to_native(p)   -- back slashes
--   path.equals(a, b)   -- case-insensitive comparison after normalize
--   path.has_drive(p), path.drive(p), path.strip_drive(p)
--   path.is_unc(p), path.unc_root(p)
--   path.is_long_prefixed(p) -- "\\\\?\\..."
--   path.is_device(p)        -- "\\\\.\\..."
--   path.long_prefix(p)      -- prepend "\\\\?\\" if missing (for >MAX_PATH paths)
--   path.strip_long_prefix(p)

local M = {}

M.sep    = "\\"
M.altsep = "/"

-- Is c a separator byte (\ or /)?
local function is_sep_byte(c)
    return c == 92 or c == 47   -- '\\' or '/'
end

-- Normalize every separator to backslash. Used internally; doesn't dedup.
local function to_back(p)
    return (p:gsub("/", "\\"))
end

-- Windows is case-insensitive for paths. Lower-case ASCII A-Z.
local function ci_byte(b)
    if b >= 65 and b <= 90 then return b + 32 end
    return b
end

local function ci_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if ci_byte(a:byte(i)) ~= ci_byte(b:byte(i)) then return false end
    end
    return true
end

-- ===== Prefix detection =================================================

-- Returns the byte-length of the "anchor" part that should not be touched
-- by normalize. Examples:
--   "C:\\foo"        -> 3  ("C:\\")
--   "C:foo"          -> 2  ("C:")    drive-relative
--   "\\\\?\\C:\\x"   -> 7  ("\\\\?\\C:\\")
--   "\\\\?\\UNC\\s\\sh\\x" -> matched as long-UNC, returns len through "\\sh\\"
--   "\\\\.\\PhysicalDrive0" -> 4 + name + 1
--   "\\\\server\\share\\x"  -> ends just after share name + separator
--   "\\foo"          -> 1  (rooted)
--   "/foo"           -> 1
--   "foo"            -> 0
local function anchor_len(p)
    local n = #p
    if n == 0 then return 0 end

    local b1 = p:byte(1)
    local b2 = n >= 2 and p:byte(2) or 0
    local b3 = n >= 3 and p:byte(3) or 0
    local b4 = n >= 4 and p:byte(4) or 0

    -- "\\\\?\\..." long-path prefix or "\\\\.\\..." device prefix.
    if is_sep_byte(b1) and is_sep_byte(b2)
       and (b3 == 63 or b3 == 46)              -- '?' or '.'
       and is_sep_byte(b4) then
        -- Check for "\\\\?\\UNC\\server\\share\\" -- treat that UNC as the anchor.
        if b3 == 63 and n >= 8 then
            local tag = p:sub(5, 7)
            if ci_equal(tag, "UNC") and is_sep_byte(p:byte(8)) then
                -- Skip past server and share names.
                local i = 9
                -- server
                while i <= n and not is_sep_byte(p:byte(i)) do i = i + 1 end
                if i <= n then i = i + 1 end
                -- share
                while i <= n and not is_sep_byte(p:byte(i)) do i = i + 1 end
                if i <= n then i = i + 1 end
                return i - 1
            end
        end
        -- "\\\\?\\C:\\..." or "\\\\?\\Volume{...}\\..." -- anchor through first sep after the tag.
        local i = 5
        while i <= n and not is_sep_byte(p:byte(i)) do i = i + 1 end
        if i <= n then i = i + 1 end
        return i - 1
    end

    -- "\\\\server\\share\\..." UNC.
    if is_sep_byte(b1) and is_sep_byte(b2) and b3 ~= 0 and not is_sep_byte(b3) then
        local i = 3
        while i <= n and not is_sep_byte(p:byte(i)) do i = i + 1 end
        if i <= n then i = i + 1 end
        -- share
        while i <= n and not is_sep_byte(p:byte(i)) do i = i + 1 end
        if i <= n then i = i + 1 end
        return i - 1
    end

    -- Drive letter "C:".
    if b2 == 58 and ((b1 >= 65 and b1 <= 90) or (b1 >= 97 and b1 <= 122)) then
        if n >= 3 and is_sep_byte(b3) then
            return 3   -- "C:\\"
        end
        return 2       -- "C:" drive-relative
    end

    -- Rooted but no drive: "\\foo" or "/foo".
    if is_sep_byte(b1) then return 1 end

    return 0
end

function M.is_long_prefixed(p)
    return #p >= 4
        and is_sep_byte(p:byte(1)) and is_sep_byte(p:byte(2))
        and p:byte(3) == 63 and is_sep_byte(p:byte(4))
end

function M.is_device(p)
    return #p >= 4
        and is_sep_byte(p:byte(1)) and is_sep_byte(p:byte(2))
        and p:byte(3) == 46 and is_sep_byte(p:byte(4))
end

function M.is_unc(p)
    if #p < 3 then return false end
    if M.is_long_prefixed(p) and #p >= 8 and ci_equal(p:sub(5, 7), "UNC")
       and is_sep_byte(p:byte(8)) then return true end
    return is_sep_byte(p:byte(1)) and is_sep_byte(p:byte(2))
       and p:byte(3) ~= 0 and not is_sep_byte(p:byte(3))
       and p:byte(3) ~= 63 and p:byte(3) ~= 46
end

function M.unc_root(p)
    if not M.is_unc(p) then return nil end
    local back = to_back(p)
    -- Skip "\\\\?\\UNC\\" if present.
    local start = 1
    if M.is_long_prefixed(back) then start = 9 end   -- past "\\\\?\\UNC\\"
    if start == 1 then start = 3 end                  -- past "\\\\"
    local i = start
    while i <= #back and back:byte(i) ~= 92 do i = i + 1 end
    if i > #back then return nil end       -- no share separator
    i = i + 1
    while i <= #back and back:byte(i) ~= 92 do i = i + 1 end
    return back:sub(1, i - 1)
end

-- ===== Drive helpers ====================================================

function M.has_drive(p)
    if #p < 2 then return false end
    local b1, b2 = p:byte(1), p:byte(2)
    return b2 == 58 and ((b1 >= 65 and b1 <= 90) or (b1 >= 97 and b1 <= 122))
end

function M.drive(p)
    if M.has_drive(p) then return p:sub(1, 2) end
    if M.is_unc(p) then return M.unc_root(p) end
    return ""
end

function M.strip_drive(p)
    if M.has_drive(p) then return p:sub(3) end
    return p
end

-- ===== Long-prefix helpers ==============================================

function M.long_prefix(p)
    if M.is_long_prefixed(p) then return p end
    if M.is_device(p) then return p end           -- never re-prefix device paths
    -- Need a back-slash absolute path. The "\\\\?\\" form disables normalization,
    -- so we should hand the kernel an already-normalized path.
    local back = to_back(M.normalize(p))
    if M.is_unc(back) then
        -- "\\\\server\\share\\..." -> "\\\\?\\UNC\\server\\share\\..."
        return "\\\\?\\UNC\\" .. back:sub(3)
    end
    if M.has_drive(back) then
        return "\\\\?\\" .. back
    end
    return back   -- relative paths can't be long-prefixed
end

function M.strip_long_prefix(p)
    if not M.is_long_prefixed(p) then return p end
    if #p >= 8 and ci_equal(p:sub(5, 7), "UNC") and is_sep_byte(p:byte(8)) then
        return "\\\\" .. p:sub(9)
    end
    return p:sub(5)
end

-- ===== is_absolute / is_relative ========================================

function M.is_absolute(p)
    if #p == 0 then return false end
    -- "C:\\foo" or "C:/foo" -- requires sep after drive.
    if M.has_drive(p) then
        return #p >= 3 and is_sep_byte(p:byte(3))
    end
    -- UNC, device, long-prefixed: all absolute.
    if M.is_unc(p) or M.is_device(p) or M.is_long_prefixed(p) then return true end
    -- "\\foo" or "/foo" is "rooted" but not technically fully-qualified
    -- (it's relative to the current drive). Most APIs treat it as absolute
    -- enough -- we follow that convention.
    return is_sep_byte(p:byte(1))
end

function M.is_relative(p)
    return not M.is_absolute(p)
end

-- ===== split / basename / dirname / extname / stem ======================

local function rfind_sep(p, stop)
    -- Find last separator in p[1..stop]. Returns 0 if none.
    for i = stop, 1, -1 do
        if is_sep_byte(p:byte(i)) then return i end
    end
    return 0
end

function M.split(p)
    -- After the anchor, find the last separator.
    local anch = anchor_len(p)
    if anch == #p then return p, "" end
    local idx = rfind_sep(p, #p)
    if idx <= anch then
        -- Filename is everything after the anchor.
        return p:sub(1, anch), p:sub(anch + 1)
    end
    return p:sub(1, idx - 1), p:sub(idx + 1)
end

function M.basename(p)
    local _, name = M.split(p)
    if name == "" and #p > 0 then
        -- p was just "C:\\" or similar -- return ""
        return ""
    end
    return name
end

function M.dirname(p)
    local d = M.split(p)
    -- Trim trailing separators except the anchor itself.
    local anch = anchor_len(d)
    local n = #d
    while n > anch and is_sep_byte(d:byte(n)) do n = n - 1 end
    return d:sub(1, n)
end

function M.extname(p)
    local name = M.basename(p)
    -- Don't treat ".name" (dotfile, no extension) as an extension.
    if name == "" or name == "." or name == ".." then return "" end
    local dot = 0
    for i = #name, 1, -1 do
        if name:byte(i) == 46 then dot = i; break end
        if is_sep_byte(name:byte(i)) then break end
    end
    if dot <= 1 then return "" end   -- leading dot or none
    return name:sub(dot)
end

function M.stem(p)
    local name = M.basename(p)
    local ext  = M.extname(p)
    if ext == "" then return name end
    return name:sub(1, #name - #ext)
end

-- ===== join / normalize / resolve =======================================

-- Join treats each absolute component as a reset (matching Python's os.path.join).
function M.join(...)
    local parts = { ... }
    local out = ""
    for i = 1, select("#", ...) do
        local p = parts[i]
        if p == nil then error("path.join: nil at position " .. i, 2) end
        if type(p) ~= "string" then
            error("path.join: expected string at position " .. i, 2)
        end
        if p ~= "" then
            if out == "" or M.is_absolute(p) then
                out = p
            else
                local last = out:byte(#out)
                if is_sep_byte(last) then
                    out = out .. p
                else
                    out = out .. M.sep .. p
                end
            end
        end
    end
    return out
end

function M.normalize(p)
    if p == "" then return "." end

    -- Preserve the original separator style by checking what dominated.
    local has_back  = p:find("\\", 1, true) ~= nil
    local sep = has_back and "\\" or "/"

    -- Convert to back-slash internally for parsing.
    local s    = to_back(p)
    local anch = anchor_len(s)
    local head = s:sub(1, anch)
    local tail = s:sub(anch + 1)

    -- Note whether the unanchored body began with a separator (only really
    -- relevant when anch == 0 -- e.g. relative path inside a normalize call).
    local body_rooted = (#tail > 0 and tail:byte(1) == 92)

    -- Split body into components.
    local comps = {}
    local n = 0
    local i = 1
    while i <= #tail do
        local j = i
        while j <= #tail and tail:byte(j) ~= 92 do j = j + 1 end
        if j > i then
            local seg = tail:sub(i, j - 1)
            if seg == "." then
                -- skip
            elseif seg == ".." then
                -- pop if possible. If the anchor is absolute, drop excess ".."
                -- silently. If relative and there's nothing to pop, keep "..".
                if n > 0 and comps[n] ~= ".." then
                    n = n - 1
                    comps[n + 1] = nil
                elseif anch == 0 then
                    n = n + 1; comps[n] = ".."
                end
                -- else: anchored, eat the ".."
            else
                n = n + 1; comps[n] = seg
            end
        end
        i = j + 1
    end

    -- Reassemble.
    local result
    if anch > 0 then
        -- Use original separator style for the joined tail; anchor itself
        -- always uses backslashes (Windows convention).
        local joined = table.concat(comps, sep)
        if joined == "" then
            result = head
        else
            -- Anchors that end in a separator stay as-is.
            if is_sep_byte(head:byte(#head)) then
                result = head .. joined
            else
                -- e.g. drive-relative "C:" -- prepend just the tail.
                result = head .. joined
            end
        end
    else
        local joined = table.concat(comps, sep)
        if body_rooted then
            result = sep .. joined
        else
            result = (joined == "") and "." or joined
        end
    end

    -- Convert anchor's backslashes back to the dominant separator if forward
    -- slashes were the originals. Anchors like "\\\\?\\" and UNC have
    -- meaning that *requires* backslashes, so only flip when there's no
    -- such prefix.
    if not has_back then
        if not (M.is_long_prefixed(result) or M.is_device(result) or M.is_unc(result)) then
            result = result:gsub("\\", "/")
        end
    end

    return result
end

function M.resolve(...)
    return M.normalize(M.join(...))
end

-- ===== relative =========================================================

-- Lower-case ASCII for case-insensitive equality check on components.
local function lower(s)
    return (s:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end))
end

function M.relative(from, to)
    local nfrom = M.normalize(to_back(from))
    local nto   = M.normalize(to_back(to))

    -- If anchors differ, no meaningful relative path -- return `to` as-is.
    local afrom = nfrom:sub(1, anchor_len(nfrom))
    local ato   = nto:sub(1, anchor_len(nto))
    if not ci_equal(afrom, ato) then return nto end

    local function split_comps(s)
        local out, k = {}, 0
        local body = s:sub(#afrom + 1)
        for seg in body:gmatch("[^\\]+") do k = k + 1; out[k] = seg end
        return out
    end

    local fc = split_comps(nfrom)
    local tc = split_comps(nto)

    -- Find common prefix (case-insensitive).
    local i = 1
    while fc[i] and tc[i] and lower(fc[i]) == lower(tc[i]) do
        i = i + 1
    end

    local parts = {}
    for _ = i, #fc do parts[#parts + 1] = ".." end
    for j = i, #tc do parts[#parts + 1] = tc[j] end
    if #parts == 0 then return "." end
    return table.concat(parts, "\\")
end

-- ===== to_posix / to_native =============================================

function M.to_posix(p)
    return (p:gsub("\\", "/"))
end

function M.to_native(p)
    return (p:gsub("/", "\\"))
end

-- modern aliases requested by the high-level filesystem API
M.posixify    = M.to_posix
M.windowsify  = M.to_native

-- ===== equals ===========================================================

function M.equals(a, b)
    -- Windows: case-insensitive on path component bytes. Normalize first
    -- so "C:\\foo\\.." and "C:\\" compare equal.
    local na = M.normalize(to_back(a))
    local nb = M.normalize(to_back(b))
    return ci_equal(na, nb)
end

-- ===== modern aliases / extra helpers ===================================

-- name(p) -- final component (alias for basename).
function M.name(p) return M.basename(p) end

-- parent(p) -- everything but the final component (alias for dirname).
function M.parent(p) return M.dirname(p) end

-- extension(p) -- ".ext" or "" (alias for extname).
function M.extension(p) return M.extname(p) end

-- parts(p) -- array of components, anchor first (if any).
function M.parts(p)
    if p == "" then return {} end
    local back = to_back(p)
    local anch = anchor_len(back)
    local out, n = {}, 0
    if anch > 0 then
        n = n + 1
        out[n] = back:sub(1, anch)
    end
    local body = back:sub(anch + 1)
    for seg in body:gmatch("[^\\]+") do
        n = n + 1
        out[n] = seg
    end
    return out
end

-- Reserved DOS device names on Windows (case-insensitive).
local _RESERVED = {
    CON=true, PRN=true, AUX=true, NUL=true,
    COM1=true, COM2=true, COM3=true, COM4=true,
    COM5=true, COM6=true, COM7=true, COM8=true, COM9=true,
    LPT1=true, LPT2=true, LPT3=true, LPT4=true,
    LPT5=true, LPT6=true, LPT7=true, LPT8=true, LPT9=true,
}

-- is_reserved(name) -- true if the basename (without extension) is a DOS
-- reserved device name. Useful for refusing dangerous path components.
function M.is_reserved(name_or_path)
    local b = M.basename(name_or_path)
    -- Strip extension for the reserved-name test.
    local dot = b:find("%.")
    if dot then b = b:sub(1, dot - 1) end
    local upper = b:upper()
    return _RESERVED[upper] == true
end

-- Split a path into directory + stem + extension (3-tuple variant).
-- The plain split(p) already returns (dir, name) for backwards compat;
-- this is the "modern" variant.
function M.split3(p)
    local dir, name = M.split(p)
    local ext = M.extname(p)
    local stem
    if ext == "" then
        stem = name
    else
        stem = name:sub(1, #name - #ext)
    end
    return dir, stem, ext
end

-- absolute(p, base?) -- resolves p against base (or the current working
-- directory) and normalizes the result. Does not touch the disk beyond
-- reading the cwd via the Win32 GetCurrentDirectoryW.
function M.absolute(p, base)
    if M.is_absolute(p) then return M.normalize(p) end
    if base == nil then
        -- Pull cwd via GetCurrentDirectoryW. ffi is injected globally by
        -- the LuaVM runtime; if it's absent (pure-Lua build), fall back to
        -- "." which still produces a reasonable normalized result.
        local ok, cwd = pcall(function()
            -- windows.lua already loads kernel32 and cdefs GetCurrentDirectoryW.
            require "windows"
            local buf = ffi.new("unsigned short[?]", 32768)
            local n = ffi.C.GetCurrentDirectoryW(32768, buf)
            if n == 0 then return nil end
            local need = ffi.C.WideCharToMultiByte(65001, 0, buf, n, nil, 0, nil, nil)
            if need <= 0 then return nil end
            local out = ffi.new("char[?]", need + 1)
            ffi.C.WideCharToMultiByte(65001, 0, buf, n, out, need, nil, nil)
            return ffi.string(out, need)
        end)
        base = (ok and cwd) or "."
    end
    return M.normalize(M.join(base, p))
end

return M
