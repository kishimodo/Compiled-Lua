-- semver -- Semantic Versioning 2.0.0 + npm-style range matching.
--
-- Public surface:
--   semver.parse(s)             -> { major, minor, patch, prerelease, build } | nil, err
--   semver.compare(a, b)        -> -1 | 0 | 1   (a/b can be strings or parsed)
--   semver.eq / lt / gt / lte / gte (a, b) -> bool
--   semver.satisfies(version, range) -> bool
--   semver.inc(version, kind)   -> string
--       kind = "major" | "minor" | "patch" | "prerelease" | "build"
--   semver.clean(s)             -> normalised string (or nil, err)
--   semver.valid(s)             -> bool
--   semver.max_satisfying(list, range) -> string?
--   semver.min_satisfying(list, range) -> string?

local M = {}

local sub  = string.sub
local fmt  = string.format
local tonum = tonumber

-- ===== Parse a single version ===========================================

local function split(s, sep)
    local out, last = {}, 1
    for i = 1, #s do
        if sub(s, i, i) == sep then
            out[#out + 1] = sub(s, last, i - 1)
            last = i + 1
        end
    end
    out[#out + 1] = sub(s, last)
    return out
end

local function parse(s)
    if type(s) == "table" and s.__semver then return s end
    if type(s) ~= "string" then return nil, "version must be a string" end
    local v = s
    -- Strip optional leading "v" or "V" -- this is loose but useful.
    if sub(v, 1, 1) == "v" or sub(v, 1, 1) == "V" then v = sub(v, 2) end

    -- Split off build metadata first (everything after first '+').
    local plus = v:find("+", 1, true)
    local build = nil
    if plus then
        build = sub(v, plus + 1)
        v = sub(v, 1, plus - 1)
    end

    -- Then pre-release (everything after first '-').
    local prerelease = nil
    local dash = v:find("-", 1, true)
    if dash then
        prerelease = sub(v, dash + 1)
        v = sub(v, 1, dash - 1)
    end

    local parts = split(v, ".")
    if #parts < 1 or #parts > 3 then
        return nil, "expected major[.minor[.patch]]"
    end
    local function num(p)
        if not p or p == "" then return nil end
        if p:find("^%d+$") and (p == "0" or sub(p, 1, 1) ~= "0") then return tonum(p) end
        return nil
    end
    local maj = num(parts[1]); if maj == nil then return nil, "bad major: " .. tostring(parts[1]) end
    local min = parts[2] and num(parts[2]) or 0
    local pat = parts[3] and num(parts[3]) or 0
    if (parts[2] and min == nil) or (parts[3] and pat == nil) then
        return nil, "bad minor/patch"
    end

    -- Validate prerelease identifiers per the 2.0 spec.
    local pre_ids = nil
    if prerelease and prerelease ~= "" then
        pre_ids = split(prerelease, ".")
        for i, id in ipairs(pre_ids) do
            if id == "" then return nil, "empty pre-release identifier" end
            if id:find("^%d+$") then
                if #id > 1 and sub(id, 1, 1) == "0" then return nil, "leading zero in numeric pre-release id" end
                pre_ids[i] = tonum(id)  -- numeric ids stored as numbers
            elseif id:find("^[0-9A-Za-z%-]+$") then
                -- alphanumeric stays as string
            else
                return nil, "bad pre-release id: " .. id
            end
        end
    end

    -- Build metadata: split but never participate in precedence.
    local build_ids = nil
    if build and build ~= "" then
        build_ids = split(build, ".")
        for _, id in ipairs(build_ids) do
            if id == "" or not id:find("^[0-9A-Za-z%-]+$") then return nil, "bad build id: " .. id end
        end
    end

    return setmetatable({
        __semver   = true,
        major      = maj,
        minor      = min,
        patch      = pat,
        prerelease = pre_ids,   -- array of strings/numbers or nil
        build      = build_ids,
        raw        = s,
    }, { __tostring = function(self)
        local r = fmt("%d.%d.%d", self.major, self.minor, self.patch)
        if self.prerelease then
            local parts = {}
            for i, p in ipairs(self.prerelease) do parts[i] = tostring(p) end
            r = r .. "-" .. table.concat(parts, ".")
        end
        if self.build then r = r .. "+" .. table.concat(self.build, ".") end
        return r
    end })
end
M.parse = parse

function M.valid(s)
    local v = parse(s)
    return v ~= nil
end

-- ===== Compare ==========================================================

local function compare_pre(a, b)
    -- Per spec: a version without pre-release has higher precedence than one
    -- with. So nil > non-nil.
    if a == nil and b == nil then return 0 end
    if a == nil then return 1 end
    if b == nil then return -1 end
    local m = math.min(#a, #b)
    for i = 1, m do
        local ai, bi = a[i], b[i]
        local ta, tb = type(ai), type(bi)
        if ta == "number" and tb == "number" then
            if ai < bi then return -1 elseif ai > bi then return 1 end
        elseif ta == "number" then
            return -1  -- numeric ids have lower precedence than alphanumeric
        elseif tb == "number" then
            return 1
        else
            if ai < bi then return -1 elseif ai > bi then return 1 end
        end
    end
    if #a < #b then return -1 end
    if #a > #b then return 1 end
    return 0
end

local function compare(a, b)
    a = type(a) == "string" and parse(a) or a
    b = type(b) == "string" and parse(b) or b
    if not a or not b then error("semver.compare: invalid version") end
    if a.major ~= b.major then return a.major < b.major and -1 or 1 end
    if a.minor ~= b.minor then return a.minor < b.minor and -1 or 1 end
    if a.patch ~= b.patch then return a.patch < b.patch and -1 or 1 end
    return compare_pre(a.prerelease, b.prerelease)
end
M.compare = compare

function M.eq(a, b)  return compare(a, b) == 0 end
function M.lt(a, b)  return compare(a, b) <  0 end
function M.gt(a, b)  return compare(a, b) >  0 end
function M.lte(a, b) return compare(a, b) <= 0 end
function M.gte(a, b) return compare(a, b) >= 0 end

-- ===== inc() / clean() ==================================================

function M.inc(version, kind)
    local v = parse(version)
    if not v then return nil, "invalid version" end
    if kind == "major" then v.major = v.major + 1; v.minor = 0; v.patch = 0; v.prerelease = nil
    elseif kind == "minor" then v.minor = v.minor + 1; v.patch = 0; v.prerelease = nil
    elseif kind == "patch" then
        -- If there is a pre-release, "patch" strips it without bumping.
        if v.prerelease then v.prerelease = nil
        else v.patch = v.patch + 1 end
    elseif kind == "prerelease" then
        if not v.prerelease then
            v.patch = v.patch + 1
            v.prerelease = { 0 }
        else
            -- Bump the trailing numeric identifier; append "0" if no numeric exists.
            local idx
            for i = #v.prerelease, 1, -1 do
                if type(v.prerelease[i]) == "number" then idx = i; break end
            end
            if idx then v.prerelease[idx] = v.prerelease[idx] + 1
            else v.prerelease[#v.prerelease + 1] = 0 end
        end
    elseif kind == "build" then
        -- Build metadata bump: numeric counter inside build array.
        if not v.build then v.build = { "0" } else
            local idx
            for i = #v.build, 1, -1 do
                if v.build[i]:find("^%d+$") then idx = i; break end
            end
            if idx then v.build[idx] = tostring(tonum(v.build[idx]) + 1)
            else v.build[#v.build + 1] = "0" end
        end
    else
        return nil, "unknown inc kind: " .. tostring(kind)
    end
    return tostring(v)
end

function M.clean(s)
    if type(s) ~= "string" then return nil, "expected string" end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if sub(s, 1, 1) == "=" then s = sub(s, 2):gsub("^%s+", "") end
    if sub(s, 1, 1) == "v" or sub(s, 1, 1) == "V" then s = sub(s, 2) end
    -- Accept "1", "1.2" by padding to three components.
    local body, pre = s:match("^([^%-+]+)(.*)$")
    if not body then return nil, "bad version" end
    local parts = split(body, ".")
    while #parts < 3 do parts[#parts + 1] = "0" end
    if #parts > 3 then return nil, "too many components" end
    for _, p in ipairs(parts) do if not p:find("^%d+$") then return nil, "non-numeric component" end end
    local out = parts[1] .. "." .. parts[2] .. "." .. parts[3] .. (pre or "")
    -- Final validation.
    if not parse(out) then return nil, "result not a valid version: " .. out end
    return out
end

-- ===== Range parser =====================================================
--
-- The grammar follows node-semver:
--   range-set  ::= range ( '||' range )*
--   range      ::= hyphen | simple ( ' ' simple )* | ''
--   hyphen     ::= partial ' - ' partial
--   simple     ::= primitive | partial | tilde | caret
--   primitive  ::= ( '<' | '>' | '>=' | '<=' | '=' ) ( ' ' )* partial
--   partial    ::= xr ( '.' xr ( '.' xr qualifier? )? )?
--   xr         ::= 'x' | 'X' | '*' | nr
--
-- We compile each set entry to a list of comparator clauses { op, ver };
-- a version satisfies the range if every clause in some OR-branch holds.

local X = -1  -- sentinel for x-range component

local function parse_partial(s)
    local parts = split(s, ".")
    local out = {}
    for i = 1, 3 do
        local p = parts[i]
        if p == nil or p == "" or p == "x" or p == "X" or p == "*" then
            out[i] = X
        elseif p:find("^%d+$") then
            out[i] = tonum(p)
        else
            -- Trailing pre-release attached? Take only the leading digits.
            local num = p:match("^(%d+)[%-+]")
            if num then out[i] = tonum(num); break end
            return nil
        end
    end
    -- Capture trailing pre-release/build for the patch slot if applicable.
    local extra = s:match("^[%dxX%*]+%.[%dxX%*]+%.[%dxX%*]+([%-+].+)$")
    out.extra = extra
    return out
end

local function partial_to_version(p, default_pre)
    -- Materialise a partial as a concrete version for comparison.
    local maj = p[1] == X and 0 or p[1]
    local min = p[2] == X and 0 or p[2]
    local pat = p[3] == X and 0 or p[3]
    local pre = default_pre or ""
    return parse(fmt("%d.%d.%d", maj, min, pat) .. pre)
end

local function expand_simple(token)
    -- Returns a list of { op = ">=" | "<" | "=" | ..., ver = parsed } clauses.
    local op = ""
    local body = token
    local m = body:match("^(<=)") or body:match("^(>=)") or body:match("^(<)")
        or body:match("^(>)") or body:match("^(=)")
    if m then op = m; body = sub(body, #m + 1) end

    -- ^ and ~ prefixes.
    local prefix = sub(body, 1, 1)
    if prefix == "^" or prefix == "~" then
        body = sub(body, 2)
        local p = parse_partial(body); if not p then return nil end
        local maj = p[1] == X and 0 or p[1]
        local min = p[2] == X and 0 or p[2]
        local pat = p[3] == X and 0 or p[3]
        if prefix == "^" then
            local lower = parse(fmt("%d.%d.%d", maj, min, pat) .. (p.extra or ""))
            -- ^ allows changes that don't modify the leftmost non-zero element.
            local upper
            if maj > 0 then upper = parse(fmt("%d.0.0", maj + 1))
            elseif min > 0 then upper = parse(fmt("0.%d.0", min + 1))
            else upper = parse(fmt("0.0.%d", pat + 1)) end
            return { { op = ">=", ver = lower }, { op = "<", ver = upper } }
        else  -- '~'
            local lower = parse(fmt("%d.%d.%d", maj, min, pat) .. (p.extra or ""))
            local upper
            if p[2] ~= X then upper = parse(fmt("%d.%d.0", maj, min + 1))
            else upper = parse(fmt("%d.0.0", maj + 1)) end
            return { { op = ">=", ver = lower }, { op = "<", ver = upper } }
        end
    end

    -- Plain partial (may contain X). The op modifies behaviour.
    local p = parse_partial(body); if not p then return nil end

    if op == "" or op == "=" then
        if p[1] == X then
            return {}  -- "*", x.x.x -> any
        elseif p[2] == X then
            local lo = parse(fmt("%d.0.0", p[1]))
            local hi = parse(fmt("%d.0.0", p[1] + 1))
            return { { op = ">=", ver = lo }, { op = "<", ver = hi } }
        elseif p[3] == X then
            local lo = parse(fmt("%d.%d.0", p[1], p[2]))
            local hi = parse(fmt("%d.%d.0", p[1], p[2] + 1))
            return { { op = ">=", ver = lo }, { op = "<", ver = hi } }
        else
            return { { op = "=", ver = partial_to_version(p, p.extra) } }
        end
    end

    -- Comparator forms: substitute X -> 0 then apply the operator. Different
    -- comparators may want different X-coercion (e.g. >1.x is >=2.0.0); we
    -- handle those explicitly.
    if op == ">" then
        if p[2] == X then return { { op = ">=", ver = parse(fmt("%d.0.0", p[1] + 1)) } } end
        if p[3] == X then return { { op = ">=", ver = parse(fmt("%d.%d.0", p[1], p[2] + 1)) } } end
        return { { op = ">", ver = partial_to_version(p, p.extra) } }
    elseif op == ">=" then
        return { { op = ">=", ver = partial_to_version(p, p.extra) } }
    elseif op == "<" then
        return { { op = "<", ver = partial_to_version(p, p.extra) } }
    elseif op == "<=" then
        if p[2] == X then return { { op = "<", ver = parse(fmt("%d.0.0", p[1] + 1)) } } end
        if p[3] == X then return { { op = "<", ver = parse(fmt("%d.%d.0", p[1], p[2] + 1)) } } end
        return { { op = "<=", ver = partial_to_version(p, p.extra) } }
    end
    return nil
end

local function expand_hyphen(left, right)
    local lp = parse_partial(left)
    local rp = parse_partial(right)
    if not lp or not rp then return nil end
    -- Left side: X -> 0; "1.2 - 1.5" means ">=1.2.0".
    local lo = parse(fmt("%d.%d.%d",
        lp[1] == X and 0 or lp[1],
        lp[2] == X and 0 or lp[2],
        lp[3] == X and 0 or lp[3]) .. (lp.extra or ""))
    -- Right side: if any component is X, it bumps the next non-X component.
    local clauses = { { op = ">=", ver = lo } }
    if rp[2] == X then
        clauses[#clauses + 1] = { op = "<", ver = parse(fmt("%d.0.0", rp[1] + 1)) }
    elseif rp[3] == X then
        clauses[#clauses + 1] = { op = "<", ver = parse(fmt("%d.%d.0", rp[1], rp[2] + 1)) }
    else
        clauses[#clauses + 1] = { op = "<=", ver = partial_to_version(rp, rp.extra) }
    end
    return clauses
end

local function parse_range(range)
    range = range:gsub("^%s+", ""):gsub("%s+$", "")
    if range == "" or range == "*" or range == "x" or range == "X" then
        return { { } }  -- one always-true alternative
    end

    -- Normalise multi-space; respect " - " hyphen ranges (must be space-dash-space).
    range = range:gsub("%s+", " ")
    -- Split into OR-branches on "||".
    local branches = {}
    local last = 1
    while true do
        local p = range:find("||", last, true)
        if not p then branches[#branches + 1] = sub(range, last); break end
        branches[#branches + 1] = sub(range, last, p - 1)
        last = p + 2
    end

    local sets = {}
    for _, b in ipairs(branches) do
        b = b:gsub("^%s+", ""):gsub("%s+$", "")
        local clauses = {}
        -- Hyphen?
        local lhs, rhs = b:match("^(%S+ ?%S* ?%S*) %- (.+)$")
        if not lhs then
            lhs, rhs = b:match("^(%S+) %- (.+)$")
        end
        if lhs and rhs then
            local hc = expand_hyphen(lhs, rhs)
            if not hc then return nil, "bad hyphen range" end
            for _, c in ipairs(hc) do clauses[#clauses + 1] = c end
        else
            -- Tokenise on spaces.
            for tok in b:gmatch("%S+") do
                local list = expand_simple(tok)
                if not list then return nil, "bad range token: " .. tok end
                for _, c in ipairs(list) do clauses[#clauses + 1] = c end
            end
        end
        sets[#sets + 1] = clauses
    end

    return sets
end

local function clause_satisfied(ver, clause)
    local cmp = compare(ver, clause.ver)
    if clause.op == "="  then return cmp == 0
    elseif clause.op == ">"  then return cmp > 0
    elseif clause.op == ">=" then return cmp >= 0
    elseif clause.op == "<"  then return cmp < 0
    elseif clause.op == "<=" then return cmp <= 0
    end
    return false
end

function M.satisfies(version, range)
    local v = type(version) == "string" and parse(version) or version
    if not v then return false end
    local sets, err = parse_range(range)
    if not sets then error("semver: bad range -- " .. tostring(err)) end
    for _, clauses in ipairs(sets) do
        local ok = true
        for _, c in ipairs(clauses) do
            if not clause_satisfied(v, c) then ok = false; break end
        end
        if ok then return true end
    end
    return false
end

function M.max_satisfying(list, range)
    local best
    for _, s in ipairs(list) do
        if M.satisfies(s, range) then
            if not best or compare(s, best) > 0 then best = s end
        end
    end
    return best
end

function M.min_satisfying(list, range)
    local best
    for _, s in ipairs(list) do
        if M.satisfies(s, range) then
            if not best or compare(s, best) < 0 then best = s end
        end
    end
    return best
end

-- ===== Object-style API =================================================
--
-- The original parse() returns a table with literal fields (major, minor,
-- ...). The user-facing API wants method-style access: v:major(), v:tostring(),
-- and comparison metamethods (==, <, <=). A naive approach -- adding methods
-- of the same name -- would conflict because Lua's `:method()` syntax first
-- reads the field, finds a number, then tries to call it. The fix here is
-- to wrap the parsed version in a thin proxy that delegates field reads
-- via __index but exposes the methods separately.

local VersionMethods = {}

function VersionMethods.major(self)      return self._inner.major end
function VersionMethods.minor(self)      return self._inner.minor end
function VersionMethods.patch(self)      return self._inner.patch end
function VersionMethods.prerelease(self) return self._inner.prerelease end
function VersionMethods.build(self)      return self._inner.build end
function VersionMethods.tostring(self)   return tostring(self._inner) end

local VersionMT = {
    __tostring = function(self) return tostring(self._inner) end,
    __eq = function(a, b) return compare(a._inner or a, b._inner or b) == 0 end,
    __lt = function(a, b) return compare(a._inner or a, b._inner or b) <  0 end,
    __le = function(a, b) return compare(a._inner or a, b._inner or b) <= 0 end,
}

-- __index falls back to the inner table so legacy `.major` field access
-- still works, AND VersionMethods lookups succeed first for method calls.
VersionMT.__index = function(t, k)
    local m = VersionMethods[k]
    if m ~= nil then return m end
    return t._inner[k]
end

local function wrap(v)
    if v._inner then return v end  -- already wrapped
    return setmetatable({ _inner = v }, VersionMT)
end

-- Make compare() accept wrapped versions transparently.
local _legacy_compare = compare
compare = function(a, b)
    if type(a) == "table" and a._inner then a = a._inner end
    if type(b) == "table" and b._inner then b = b._inner end
    return _legacy_compare(a, b)
end
M.compare = compare

-- Re-wrap parse so every returned version carries methods + ops.
local _legacy_parse = M.parse
function M.parse(s)
    -- Accept already-wrapped values for idempotence.
    if type(s) == "table" and s._inner then return s end
    if type(s) == "table" and s.__semver then return wrap(s) end
    local v, err = _legacy_parse(s)
    if not v then return nil, err end
    return wrap(v)
end

-- Spec wants both names; satisfies/inc are already on M from earlier.
function M.is_valid(s) return M.valid(s) end

-- ===== Range object =====================================================
--
-- The procedural M.satisfies takes a range string; this wraps that into an
-- object so callers can pre-compile and reuse.

local Range = {}
Range.__index = Range
function Range:matches(v)
    return M.satisfies(v, self._src)
end
function Range:tostring() return self._src end
Range.__tostring = function(self) return self._src end

function M.range(s)
    if type(s) ~= "string" then return nil, "range must be a string" end
    -- Parse eagerly to surface errors at construction time.
    local sets, err = parse_range(s)
    if not sets then return nil, err end
    return setmetatable({ _src = s, _sets = sets }, Range)
end

return M
