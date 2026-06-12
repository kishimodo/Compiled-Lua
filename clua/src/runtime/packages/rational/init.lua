-- rational -- exact rational numbers (Q).
--
-- Internal form: { num = bignum, den = bignum } where:
--   - den is always positive (sign lives on num)
--   - gcd(num, den) == 1 after construction (canonical reduced form)
--   - the rational 0 is { num = 0, den = 1 }
--
-- Public surface:
--   rational.new(num, den?)              -- den defaults to 1
--   rational.from_decimal("3.1415")      -- exact parse
--   r:to_decimal(precision)              -- truncating decimal expansion
--   r:numer(), r:denom(), r:simplify()
--   Operators: + - * / ^ < <= == unary-minus
--
-- The exponent for r^n must be an integer (positive or negative). Fractional
-- powers leave Q -- caller should use complex / float instead.

local bn = require "bignum"

local M = {}
local mt = {}

local function is_q(x) return type(x) == "table" and getmetatable(x) == mt end

local function to_bn(x)
    -- duck-type: bignum tables carry .limbs + .sign
    if type(x) == "table" and x.limbs and x.sign then return x end
    return bn.new(x)
end

local function alloc(num, den)
    return setmetatable({ num = num, den = den }, mt)
end

local function normalize(num, den)
    if bn.is_zero(den) then error("rational: zero denominator") end
    -- move sign onto numerator
    if bn.sign(den) < 0 then
        num = bn.neg(num)
        den = bn.neg(den)
    end
    if bn.is_zero(num) then
        return alloc(bn.new(0), bn.new(1))
    end
    local g = bn.gcd(num, den)
    if not bn.eq(g, bn.new(1)) then
        num = bn.div(num, g)
        den = bn.div(den, g)
    end
    return alloc(num, den)
end

function M.new(num, den)
    if is_q(num) and den == nil then
        return alloc(bn.new(num.num), bn.new(num.den))
    end
    local n = to_bn(num)
    local d = den ~= nil and to_bn(den) or bn.new(1)
    return normalize(n, d)
end

function M.numer(r) return bn.new(r.num) end
function M.denom(r) return bn.new(r.den) end
function M.simplify(r) return M.new(r.num, r.den) end  -- already canonical

-- ===== Arithmetic ======================================================

local function coerce(x)
    if is_q(x) then return x end
    return M.new(x)
end

function M.add(a, b)
    a, b = coerce(a), coerce(b)
    -- (an*bd + bn*ad) / (ad*bd) -- gcd reduce is done by normalize
    local num = bn.add(bn.mul(a.num, b.den), bn.mul(b.num, a.den))
    local den = bn.mul(a.den, b.den)
    return normalize(num, den)
end

function M.sub(a, b)
    a, b = coerce(a), coerce(b)
    local num = bn.sub(bn.mul(a.num, b.den), bn.mul(b.num, a.den))
    local den = bn.mul(a.den, b.den)
    return normalize(num, den)
end

function M.mul(a, b)
    a, b = coerce(a), coerce(b)
    return normalize(bn.mul(a.num, b.num), bn.mul(a.den, b.den))
end

function M.div(a, b)
    a, b = coerce(a), coerce(b)
    if bn.is_zero(b.num) then error("rational: divide by zero") end
    return normalize(bn.mul(a.num, b.den), bn.mul(a.den, b.num))
end

function M.neg(a) return alloc(bn.neg(a.num), bn.new(a.den)) end
function M.abs(a) return alloc(bn.abs(a.num), bn.new(a.den)) end

function M.pow(a, n)
    -- n must be an integer; if negative, invert first
    a = coerce(a)
    local ni
    if type(n) == "number" then
        if n ~= math.floor(n) then error("rational.pow: exponent must be integer") end
        ni = n
    else
        n = to_bn(n)
        ni = bn.to_int(n)
    end
    if ni == 0 then return M.new(1) end
    if ni < 0 then
        if bn.is_zero(a.num) then error("rational.pow: 0 to negative power") end
        return M.new(bn.pow(a.den, -ni), bn.pow(a.num, -ni))
    end
    return M.new(bn.pow(a.num, ni), bn.pow(a.den, ni))
end

function M.cmp(a, b)
    a, b = coerce(a), coerce(b)
    -- sign(a - b) without subtraction (avoids reducing a giant intermediate)
    return bn.cmp(bn.mul(a.num, b.den), bn.mul(b.num, a.den))
end

function M.eq(a, b) return M.cmp(a, b) == 0 end
function M.lt(a, b) return M.cmp(a, b) <  0 end
function M.le(a, b) return M.cmp(a, b) <= 0 end

function M.sign(r)
    if bn.is_zero(r.num) then return 0 end
    return bn.sign(r.num)
end

function M.is_integer(r)
    return bn.eq(r.den, bn.new(1))
end

function M.floor(r)
    -- floor division on signed numerator
    local q, rem = bn.divmod(r.num, r.den)
    if bn.sign(rem) < 0 then q = bn.sub(q, bn.new(1)) end
    return q
end

function M.ceil(r)
    local q, rem = bn.divmod(r.num, r.den)
    if bn.sign(rem) > 0 then q = bn.add(q, bn.new(1)) end
    return q
end

function M.trunc(r)
    local q = bn.div(r.num, r.den)
    return q
end

-- ===== Decimal IO ======================================================

function M.from_decimal(s)
    -- Accepts "[-]intpart[.fracpart][e[+-]?digits]"
    -- Exact: 3.14 -> 314/100, then reduced. Exponent shifts numerator/denominator.
    s = s:gsub("[%s_]", "")
    local sign = 1
    if s:sub(1, 1) == "-" then sign = -1; s = s:sub(2)
    elseif s:sub(1, 1) == "+" then s = s:sub(2) end
    local mant, exp = s:match("^([%d%.]+)[eE]([%+%-]?%d+)$")
    if not mant then mant = s; exp = "0" end
    local int_part, frac_part = mant:match("^(%d*)%.(%d+)$")
    if not int_part then int_part = mant; frac_part = "" end
    if int_part == "" and frac_part == "" then error("rational.from_decimal: empty number") end
    local digits = int_part .. frac_part
    local scale = #frac_part
    local exp_n = tonumber(exp)
    local num = bn.new(digits, 10)
    if sign < 0 then num = bn.neg(num) end
    local den = bn.new(1)
    local power = scale - exp_n
    if power > 0 then
        den = bn.pow(bn.new(10), power)
    elseif power < 0 then
        num = bn.mul(num, bn.pow(bn.new(10), -power))
    end
    return M.new(num, den)
end

function M.to_decimal(r, precision)
    precision = precision or 20
    -- Emit integer part + '.' + 'precision' decimal digits (truncated, not rounded).
    -- Caller can pass precision = 0 for integer-only.
    local sign = M.sign(r)
    local a = M.abs(r)
    local int_q, rem = bn.divmod(a.num, a.den)
    local out = {}
    if sign < 0 then out[1] = "-" end
    out[#out + 1] = bn.tostring(int_q)
    if precision <= 0 then return table.concat(out) end
    out[#out + 1] = "."
    for _ = 1, precision do
        rem = bn.mul(rem, bn.new(10))
        local d, nr = bn.divmod(rem, a.den)
        out[#out + 1] = bn.tostring(d)
        rem = nr
    end
    return table.concat(out)
end

function M.tostring(r)
    if bn.eq(r.den, bn.new(1)) then return bn.tostring(r.num) end
    return bn.tostring(r.num) .. "/" .. bn.tostring(r.den)
end

function M.tonumber(r)
    -- best-effort conversion to Lua double. For huge numerator/denominator
    -- pairs this loses precision; callers should use to_decimal for control.
    local n = bn.to_int(r.num)
    local d = bn.to_int(r.den)
    return n / d
end

function M.round(r)
    -- round half-to-even (banker's rounding) for a stable result
    local q, rem = bn.divmod(r.num, r.den)
    if bn.is_zero(rem) then return q end
    -- compare 2*|rem| against den to decide the rounding direction
    local twice = bn.abs(bn.mul(rem, bn.new(2)))
    local cmp = bn.cmp(twice, r.den)
    if cmp < 0 then
        if bn.sign(r.num) < 0 and not bn.is_zero(rem) then return bn.sub(q, bn.new(1)) end
        return q
    elseif cmp > 0 then
        if bn.sign(r.num) < 0 then return bn.sub(q, bn.new(1)) end
        return bn.add(q, bn.new(1))
    else
        -- exactly half -- round to even
        if bn.eq(bn.mod(q, bn.new(2)), bn.new(0)) then
            if bn.sign(r.num) < 0 and not bn.is_zero(rem) then return bn.sub(q, bn.new(1)) end
            return q
        end
        if bn.sign(r.num) < 0 then return bn.sub(q, bn.new(1)) end
        return bn.add(q, bn.new(1))
    end
end

function M.from_float(f, max_den)
    -- continued-fraction approximation. Stop when denominator would exceed
    -- max_den (default 10^9) or the residue is exactly zero.
    if f ~= f or f == math.huge or f == -math.huge then
        error("rational.from_float: non-finite")
    end
    max_den = max_den or 1000000000
    local sign = 1
    if f < 0 then sign = -1; f = -f end
    -- exact integer fast path
    if f == math.floor(f) then
        local n = bn.new(math.floor(f))
        if sign < 0 then n = bn.neg(n) end
        return M.new(n, bn.new(1))
    end
    -- run continued fraction: h_k = a_k * h_{k-1} + h_{k-2}
    local h1, h0 = 1, 0
    local k1, k0 = 0, 1
    local x = f
    for _ = 1, 64 do
        local a = math.floor(x)
        local h = a * h1 + h0
        local k = a * k1 + k0
        if k > max_den then break end
        h0, h1 = h1, h
        k0, k1 = k1, k
        local frac = x - a
        if frac < 1e-15 then break end
        x = 1 / frac
    end
    local n = bn.new(sign * h1)
    local d = bn.new(k1)
    return M.new(n, d)
end

function M.from_string(s)
    -- Accepts "p/q" or a plain decimal -- choose based on the presence of '/'.
    local p, q = s:match("^([%+%-]?%d+)%s*/%s*(%d+)$")
    if p then return M.new(bn.new(p, 10), bn.new(q, 10)) end
    return M.from_decimal(s)
end

-- Method aliases requested by spec
M.decimal = M.to_decimal

-- ===== Metatable =======================================================

mt.__index    = function(_, k) return M[k] end
mt.__add      = function(a, b) return M.add(a, b) end
mt.__sub      = function(a, b) return M.sub(a, b) end
mt.__mul      = function(a, b) return M.mul(a, b) end
mt.__div      = function(a, b) return M.div(a, b) end
mt.__pow      = function(a, b) return M.pow(a, b) end
mt.__unm      = function(a)    return M.neg(a) end
mt.__eq       = function(a, b) return M.eq(a, b) end
mt.__lt       = function(a, b) return M.lt(a, b) end
mt.__le       = function(a, b) return M.le(a, b) end
mt.__tostring = function(a)    return M.tostring(a) end

setmetatable(M, { __call = function(_, num, den) return M.new(num, den) end })

return M
