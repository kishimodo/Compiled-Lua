-- glob -- bash-style pattern matching.
--
-- Public surface:
--   glob.match(path, pattern)   -> bool
--   glob.compile(pattern)       -> matcher fn (path -> bool)
--   glob.expand(pattern)        -> { alternative1, alternative2, ... }
--                                  -- expands brace alternatives only.
--   glob.translate(pattern)     -> Lua pattern string
--                                  -- diagnostic/escape-hatch helper.
--
-- Supported syntax:
--   *        any run of chars except path separator
--   ?        any single char except path separator
--   [abc]    char class (supports ranges a-z and negation [!abc] or [^abc])
--   **       zero or more path components (matches across separators)
--   {a,b,c}  brace alternatives (nested allowed)
--   \\x      escape literal x
--
-- Path separators: both '\\' and '/' are treated as separators in the input
-- so a single matcher works for Windows + POSIX-style paths.

local M = {}

-- Split a pattern on top-level commas inside braces. Used by expand().
local function split_braces(s)
    -- Find the first '{...}' group at brace-depth 0.
    local n = #s
    local i = 1
    while i <= n do
        local b = s:byte(i)
        if b == 92 then       -- '\\' escape -- skip next char
            i = i + 2
        elseif b == 123 then  -- '{'
            -- Find the matching '}', and the comma positions at depth 0.
            local depth   = 1
            local commas  = { i }
            local j = i + 1
            while j <= n and depth > 0 do
                local c = s:byte(j)
                if c == 92 then
                    j = j + 2
                elseif c == 123 then
                    depth = depth + 1
                    j = j + 1
                elseif c == 125 then
                    depth = depth - 1
                    if depth == 0 then commas[#commas + 1] = j end
                    j = j + 1
                elseif c == 44 and depth == 1 then
                    commas[#commas + 1] = j
                    j = j + 1
                else
                    j = j + 1
                end
            end
            if depth == 0 and #commas >= 3 then
                -- We have a real "{a,b,...}" group with at least one comma.
                local before = s:sub(1, i - 1)
                local after  = s:sub(commas[#commas] + 1)
                local alts   = {}
                for k = 1, #commas - 1 do
                    alts[k] = s:sub(commas[k] + 1, commas[k + 1] - 1)
                end
                return before, alts, after
            end
            -- Unmatched or empty -- skip past this '{'.
            i = i + 1
        else
            i = i + 1
        end
    end
    return nil
end

function M.expand(pattern)
    local before, alts, after = split_braces(pattern)
    if not before then return { pattern } end
    local out, ni = {}, 0
    for _, a in ipairs(alts) do
        for _, x in ipairs(M.expand(before .. a .. after)) do
            ni = ni + 1; out[ni] = x
        end
    end
    return out
end

-- Translate a glob (no brace expansion -- caller must expand first) into a
-- Lua pattern that matches the entire input.
--
-- Implementation notes:
--   * '*' becomes "[^/\\]*"
--   * '?' becomes "[^/\\]"
--   * '**' becomes ".*"  (but with care around adjacent separators)
--   * char class [abc] -> "[abc]", [!abc] -> "[^abc]"
--   * everything else is Lua-escaped
function M.translate(pattern)
    local buf = { "^" }
    local n = #pattern
    local i = 1
    while i <= n do
        local b = pattern:byte(i)
        if b == 42 then  -- '*'
            -- Check for '**'.
            if i + 1 <= n and pattern:byte(i + 1) == 42 then
                buf[#buf + 1] = ".*"
                i = i + 2
                -- Eat a following separator so "a/**/b" matches "a/b" too.
                if i <= n and (pattern:byte(i) == 47 or pattern:byte(i) == 92) then
                    -- Make the trailing separator optional in the regex.
                    -- We already accept ".*", which can include the sep, so
                    -- just skip the literal sep.
                    i = i + 1
                end
            else
                buf[#buf + 1] = "[^/\\\\]*"
                i = i + 1
            end
        elseif b == 63 then  -- '?'
            buf[#buf + 1] = "[^/\\\\]"
            i = i + 1
        elseif b == 91 then  -- '['
            -- Char class. Find matching ']'.
            local j = i + 1
            local negate = false
            if j <= n and (pattern:byte(j) == 33 or pattern:byte(j) == 94) then
                negate = true
                j = j + 1
            end
            -- ']' as the first char in the class is literal.
            if j <= n and pattern:byte(j) == 93 then j = j + 1 end
            while j <= n and pattern:byte(j) ~= 93 do j = j + 1 end
            if j > n then
                -- Unmatched '[' -- treat literally.
                buf[#buf + 1] = "%["
                i = i + 1
            else
                local cls = pattern:sub(i + (negate and 2 or 1), j - 1)
                -- Escape Lua-magic chars inside class.
                cls = cls:gsub("%%", "%%%%")
                buf[#buf + 1] = negate and ("[^" .. cls .. "]") or ("[" .. cls .. "]")
                i = j + 1
            end
        elseif b == 92 then  -- '\\' -- escape next char (or treat as sep on Windows?)
            -- We treat '\\' as a path separator -- backslash-escape is rarely
            -- intended in path globs. Use [] to escape a literal '*' etc.
            buf[#buf + 1] = "[/\\\\]"
            i = i + 1
        elseif b == 47 then  -- '/' separator
            buf[#buf + 1] = "[/\\\\]"
            i = i + 1
        else
            -- Lua-pattern escape for magic chars.
            local c = pattern:sub(i, i)
            if c:find("[%^%$%(%)%.%[%]%+%-%%]") then
                buf[#buf + 1] = "%" .. c
            else
                buf[#buf + 1] = c
            end
            i = i + 1
        end
    end
    buf[#buf + 1] = "$"
    return table.concat(buf)
end

local function match_one(pattern, path)
    local lp = M.translate(pattern)
    return path:find(lp) ~= nil
end

function M.compile(pattern)
    local alts = M.expand(pattern)
    -- Pre-translate every alternative once.
    local translated = {}
    for i, a in ipairs(alts) do translated[i] = M.translate(a) end
    return function(p)
        for i = 1, #translated do
            if p:find(translated[i]) ~= nil then return true end
        end
        return false
    end
end

function M.match(path, pattern)
    -- Detect the (pattern, path) call order used by fs.glob and friends.
    -- Heuristic: if the second argument has any glob metacharacter and the
    -- first doesn't, swap them. This keeps both call shapes working.
    if type(path) == "string" and type(pattern) == "string" then
        local function has_meta(s)
            return s:find("[%*%?%[%]{}]") ~= nil
        end
        if has_meta(path) and not has_meta(pattern) then
            path, pattern = pattern, path
        end
    end
    local alts = M.expand(pattern)
    for _, a in ipairs(alts) do
        if match_one(a, path) then return true end
    end
    return false
end

-- iter(root, pattern, opts?) -- walk `root` recursively and yield every
-- path matching the glob pattern. opts = { dot=false, follow_symlinks=false,
-- max_depth=nil }. Returns a stateless iterator.
function M.iter(root, pattern, opts)
    opts = opts or {}
    -- Lazy-require fs to avoid circular load on startup. fs requires glob.
    local fs = require "fs"
    local path = require "path"

    local matcher = M.compile(pattern)
    local include_dot = opts.dot == true
    local follow = opts.follow_symlinks == true
    local max_depth = opts.max_depth
    local root_native = path.to_native(root)

    -- Build a relative-to-root matcher too -- patterns like "*.lua" should
    -- match against the basename, not the full anchored path.
    local pattern_has_sep = pattern:find("[/\\]") ~= nil

    local walker = fs.walk(root_native, {
        recursive       = true,
        follow_symlinks = follow,
        filter          = function(_name, full, _is_dir)
            if not include_dot then
                local _, base = path.split(full)
                if base:sub(1, 1) == "." then return false end
            end
            if max_depth then
                -- Count separators between root and full.
                local rel = full:sub(#root_native + 1)
                local depth = 0
                for _ in rel:gmatch("[/\\]") do depth = depth + 1 end
                if depth > max_depth then return false end
            end
            return true
        end,
    })

    return function()
        while true do
            local full = walker()
            if not full then return nil end
            local candidate = full
            if not pattern_has_sep then
                local _, base = path.split(full)
                candidate = base
            end
            if matcher(candidate) or matcher(full) then
                return full
            end
        end
    end
end

return M
