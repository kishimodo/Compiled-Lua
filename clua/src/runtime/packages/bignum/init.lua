-- bignum -- arbitrary-precision integers.
--
-- Internals:
--   sign  -- +1 or -1 (zero is +1)
--   limbs -- array of base-2^24 limbs, least-significant first
--
-- Why 24-bit limbs: a Lua double has 53 bits of mantissa, so integer values
-- up to 2^53 are exact. Two 24-bit limbs produce a 48-bit product; adding a
-- 24-bit accumulator entry plus a 24-bit carry leaves the running sum below
-- 2^49 -- well inside the exact range. Larger limbs (e.g. 28 bits) would
-- push limb*limb past 2^53, breaking exact arithmetic in pure Lua.
--
-- Public surface:
--   bignum.new(value_or_string, base?)   -> bn
--   bignum.from_bytes(bytes, sign?)      -> bn  (big-endian unsigned magnitude)
--   bignum.to_bytes(bn)                  -> string (big-endian magnitude)
--   bn:tostring(base?)                   -> string
--   Module functions mirror methods: bignum.add(a, b) == a:add(b)
--   Operator metatable: + - * / % ^ < <= == unary-minus

local M = {}

local BASE       = 0x1000000      -- 2^24
local BASE_BITS  = 24
local MASK       = BASE - 1
local KARATSUBA  = 40             -- threshold (in limbs) for splitting into 3 multiplies

local mt = {}

-- ===== Construction ====================================================

local function alloc(sign, limbs)
    return setmetatable({ sign = sign, limbs = limbs }, mt)
end

local function trim(bn)
    -- strip leading zero limbs; preserve a single zero
    local n = #bn.limbs
    while n > 1 and bn.limbs[n] == 0 do
        bn.limbs[n] = nil
        n = n - 1
    end
    -- canonicalise zero as +0
    if n == 1 and bn.limbs[1] == 0 then bn.sign = 1 end
    return bn
end

local function is_bn(x)
    return type(x) == "table" and getmetatable(x) == mt
end

local function zero()  return alloc(1, { 0 }) end
local function one()   return alloc(1, { 1 }) end

local function from_int(n)
    if n ~= n or n == math.huge or n == -math.huge then
        error("bignum: non-finite number")
    end
    local sign = 1
    if n < 0 then sign = -1; n = -n end
    n = math.floor(n)
    if n == 0 then return zero() end
    local limbs = {}
    local i = 0
    while n > 0 do
        i = i + 1
        limbs[i] = n % BASE
        n = math.floor(n / BASE)
    end
    return alloc(sign, limbs)
end

local _DIGIT = {}
for i = 0, 9  do _DIGIT[string.byte("0") + i] = i end
for i = 0, 25 do _DIGIT[string.byte("a") + i] = 10 + i; _DIGIT[string.byte("A") + i] = 10 + i end

local function from_string(s, base)
    base = base or 10
    if base < 2 or base > 36 then error("bignum: base out of range 2..36") end
    s = s:gsub("[%s_]", "")
    if #s == 0 then error("bignum: empty string") end
    local sign = 1
    local i = 1
    local first = s:byte(1)
    if first == 45 then sign = -1; i = 2
    elseif first == 43 then i = 2 end
    -- optional 0x/0b/0o prefixes
    if base == 10 and s:sub(i, i + 1) == "0x" then base = 16; i = i + 2
    elseif base == 10 and s:sub(i, i + 1) == "0b" then base = 2; i = i + 2
    elseif base == 10 and s:sub(i, i + 1) == "0o" then base = 8; i = i + 2 end
    if i > #s then error("bignum: no digits after sign/prefix") end
    local bn = zero()
    local bbn = from_int(base)
    for p = i, #s do
        local d = _DIGIT[s:byte(p)]
        if d == nil or d >= base then
            error("bignum: invalid digit '" .. s:sub(p, p) .. "' for base " .. base)
        end
        bn = M.mul(bn, bbn)
        if d ~= 0 then bn = M.add(bn, from_int(d)) end
    end
    bn.sign = (bn.limbs[1] == 0 and #bn.limbs == 1) and 1 or sign
    return bn
end

function M.new(v, base)
    if is_bn(v) then
        local copy = {}
        for i = 1, #v.limbs do copy[i] = v.limbs[i] end
        return alloc(v.sign, copy)
    end
    if type(v) == "number" then return from_int(v) end
    if type(v) == "string" then return from_string(v, base) end
    error("bignum.new: bad type " .. type(v))
end

function M.from_bytes(bytes, signed)
    -- Big-endian. If signed=true, the top bit of the first byte marks negative
    -- (two's complement decode). Default is unsigned magnitude.
    local negative = false
    if signed and #bytes > 0 and bytes:byte(1) >= 128 then
        -- Two's complement: invert + add 1
        negative = true
        local inv = {}
        for i = 1, #bytes do inv[i] = string.char((~bytes:byte(i)) & 0xFF) end
        bytes = table.concat(inv)
        -- need to add one to magnitude after parsing
    end
    local bn = zero()
    local b256 = from_int(256)
    for i = 1, #bytes do
        bn = M.mul(bn, b256)
        bn = M.add(bn, from_int(bytes:byte(i)))
    end
    if negative then bn = M.add(bn, one()) end
    if not M.is_zero(bn) and negative then bn.sign = -1 end
    return bn
end

function M.from_hex(s)
    -- Accepts optional "0x"/"0X" prefix and an optional sign. "_" and whitespace
    -- are stripped so the input can be groomed for readability.
    s = s:gsub("[%s_]", "")
    local sign = 1
    local i = 1
    if s:sub(1, 1) == "-" then sign = -1; i = 2
    elseif s:sub(1, 1) == "+" then i = 2 end
    if s:sub(i, i + 1) == "0x" or s:sub(i, i + 1) == "0X" then i = i + 2 end
    local body = s:sub(i)
    if #body == 0 then error("bignum.from_hex: empty body") end
    local bn = from_string(body, 16)
    if sign < 0 and not M.is_zero(bn) then bn.sign = -1 end
    return bn
end

function M.to_bytes(bn, length, signed)
    -- Big-endian magnitude. If `length` is given the output is zero-padded
    -- (or truncated). If `signed` is true the result is two's complement
    -- to `length` bytes (length is required when signed=true).
    if signed and not length then
        error("bignum.to_bytes: signed encoding requires explicit length")
    end
    if M.is_zero(bn) then
        if length then return string.rep("\0", length) end
        return "\0"
    end
    local out, n = {}, 0
    local cur = M.abs(bn)
    local b256 = from_int(256)
    while not M.is_zero(cur) do
        local q, r = M.divmod(cur, b256)
        n = n + 1; out[n] = M.to_int(r)
        cur = q
    end
    if signed and bn.sign < 0 then
        -- two's complement: invert bytes, then add 1 to the LSB with carry
        for i = 1, length do out[i] = (~(out[i] or 0)) & 0xFF end
        local carry = 1
        for i = 1, length do
            local v = out[i] + carry
            if v >= 256 then out[i] = v - 256; carry = 1
            else out[i] = v; carry = 0; break end
        end
        n = length
    end
    -- pack into big-endian string
    if length then
        if n > length then
            -- truncate to `length` low bytes (caller wanted a fixed width)
            n = length
        end
        local rev = {}
        for i = 1, length - n do rev[i] = "\0" end
        for i = 1, n do rev[length - n + i] = string.char(out[n - i + 1]) end
        return table.concat(rev)
    end
    local rev = {}
    for i = 1, n do rev[i] = string.char(out[n - i + 1]) end
    return table.concat(rev)
end

-- ===== Predicates / comparison =========================================

function M.is_zero(a) return #a.limbs == 1 and a.limbs[1] == 0 end

function M.sign(a)
    if M.is_zero(a) then return 0 end
    return a.sign
end

local function ucmp(a, b)
    -- compare unsigned magnitudes
    local na, nb = #a.limbs, #b.limbs
    if na ~= nb then return na < nb and -1 or 1 end
    for i = na, 1, -1 do
        local da, db = a.limbs[i], b.limbs[i]
        if da ~= db then return da < db and -1 or 1 end
    end
    return 0
end

function M.cmp(a, b)
    local sa, sb = M.sign(a), M.sign(b)
    if sa ~= sb then return sa < sb and -1 or 1 end
    if sa == 0 then return 0 end
    local c = ucmp(a, b)
    return sa > 0 and c or -c
end

function M.eq(a, b) return M.cmp(a, b) == 0 end
function M.lt(a, b) return M.cmp(a, b) <  0 end
function M.le(a, b) return M.cmp(a, b) <= 0 end

-- ===== Addition / subtraction (unsigned magnitude helpers) =============

local function uadd(a, b)
    local na, nb = #a.limbs, #b.limbs
    local n = na > nb and na or nb
    local out = {}
    local carry = 0
    for i = 1, n do
        local s = (a.limbs[i] or 0) + (b.limbs[i] or 0) + carry
        if s >= BASE then
            out[i] = s - BASE
            carry  = 1
        else
            out[i] = s
            carry  = 0
        end
    end
    if carry > 0 then out[n + 1] = carry end
    return out
end

local function usub(a, b)
    -- requires ucmp(a, b) >= 0
    local na = #a.limbs
    local out = {}
    local borrow = 0
    for i = 1, na do
        local s = a.limbs[i] - (b.limbs[i] or 0) - borrow
        if s < 0 then out[i] = s + BASE; borrow = 1
        else        out[i] = s;        borrow = 0 end
    end
    return out
end

function M.add(a, b)
    if a.sign == b.sign then
        return trim(alloc(a.sign, uadd(a, b)))
    end
    local c = ucmp(a, b)
    if c == 0 then return zero() end
    if c > 0 then return trim(alloc(a.sign, usub(a, b))) end
    return trim(alloc(b.sign, usub(b, a)))
end

function M.sub(a, b)
    local nb = alloc(-b.sign, b.limbs)
    return M.add(a, nb)
end

function M.neg(a)
    if M.is_zero(a) then return zero() end
    local copy = {}
    for i = 1, #a.limbs do copy[i] = a.limbs[i] end
    return alloc(-a.sign, copy)
end

function M.abs(a)
    local copy = {}
    for i = 1, #a.limbs do copy[i] = a.limbs[i] end
    return alloc(1, copy)
end

-- ===== Multiplication ==================================================

local function umul_schoolbook(a, b)
    local na, nb = #a.limbs, #b.limbs
    local out = {}
    for i = 1, na + nb do out[i] = 0 end
    for i = 1, na do
        local ai = a.limbs[i]
        if ai ~= 0 then
            local carry = 0
            for j = 1, nb do
                -- ai*bj <= (2^28-1)^2 < 2^56; plus out + carry stays exact in double
                local p = ai * b.limbs[j] + out[i + j - 1] + carry
                carry = math.floor(p / BASE)
                out[i + j - 1] = p - carry * BASE
            end
            out[i + nb] = out[i + nb] + carry
        end
    end
    return out
end

local function ushl_limbs(limbs, k)
    -- shift limbs left by k limbs (multiply by BASE^k)
    local out = {}
    for i = 1, k do out[i] = 0 end
    for i = 1, #limbs do out[i + k] = limbs[i] end
    return out
end

local function slice(limbs, lo, hi)
    -- limbs[lo..hi] (inclusive), 1-based; missing -> 0; result is its own bn-shaped table
    local out = {}
    for i = lo, hi do out[i - lo + 1] = limbs[i] or 0 end
    if #out == 0 then out[1] = 0 end
    return out
end

local function bn_from_limbs(limbs)
    -- trim and wrap
    local n = #limbs
    while n > 1 and limbs[n] == 0 do limbs[n] = nil; n = n - 1 end
    return alloc(1, limbs)
end

local function ukaratsuba(a, b)
    local na, nb = #a.limbs, #b.limbs
    if na < KARATSUBA or nb < KARATSUBA then
        return umul_schoolbook(a, b)
    end
    local m = math.floor(((na < nb and na or nb) + 1) / 2)
    local a_lo = bn_from_limbs(slice(a.limbs, 1, m))
    local a_hi = bn_from_limbs(slice(a.limbs, m + 1, na))
    local b_lo = bn_from_limbs(slice(b.limbs, 1, m))
    local b_hi = bn_from_limbs(slice(b.limbs, m + 1, nb))

    -- z0 = a_lo * b_lo
    -- z2 = a_hi * b_hi
    -- z1 = (a_lo + a_hi)(b_lo + b_hi) - z0 - z2
    local z0 = bn_from_limbs(ukaratsuba(a_lo, b_lo))
    local z2 = bn_from_limbs(ukaratsuba(a_hi, b_hi))
    local sa = trim(alloc(1, uadd(a_lo, a_hi)))
    local sb = trim(alloc(1, uadd(b_lo, b_hi)))
    local z1 = bn_from_limbs(ukaratsuba(sa, sb))
    z1 = M.sub(z1, z0)
    z1 = M.sub(z1, z2)
    -- result = z0 + z1 * BASE^m + z2 * BASE^(2m)
    local z1s = bn_from_limbs(ushl_limbs(z1.limbs, m))
    local z2s = bn_from_limbs(ushl_limbs(z2.limbs, 2 * m))
    local r = M.add(M.add(z0, z1s), z2s)
    return r.limbs
end

function M.mul(a, b)
    if M.is_zero(a) or M.is_zero(b) then return zero() end
    local sign = (a.sign == b.sign) and 1 or -1
    local limbs = ukaratsuba(a, b)
    return trim(alloc(sign, limbs))
end

-- ===== Bit length / shifts =============================================

local function ubits(a)
    if M.is_zero(a) then return 0 end
    local n = #a.limbs
    local top = a.limbs[n]
    local bits = (n - 1) * BASE_BITS
    while top > 0 do bits = bits + 1; top = math.floor(top / 2) end
    return bits
end

function M.bit_length(a) return ubits(a) end

local function ushl(a, k)
    if M.is_zero(a) or k == 0 then return M.new(a) end
    local limb_shift = math.floor(k / BASE_BITS)
    local bit_shift  = k - limb_shift * BASE_BITS
    local out = {}
    for i = 1, limb_shift do out[i] = 0 end
    local carry = 0
    local mul = 2 ^ bit_shift
    for i = 1, #a.limbs do
        local v = a.limbs[i] * mul + carry
        out[i + limb_shift] = v % BASE
        carry = math.floor(v / BASE)
    end
    if carry > 0 then out[#a.limbs + limb_shift + 1] = carry end
    return trim(alloc(a.sign, out))
end

local function ushr(a, k)
    if k == 0 then return M.new(a) end
    local limb_shift = math.floor(k / BASE_BITS)
    local bit_shift  = k - limb_shift * BASE_BITS
    if limb_shift >= #a.limbs then return zero() end
    local out = {}
    local div = 2 ^ bit_shift
    local hi_mask = BASE / div
    for i = 1, #a.limbs - limb_shift do
        local cur = a.limbs[i + limb_shift]
        local nxt = a.limbs[i + limb_shift + 1] or 0
        out[i] = math.floor(cur / div) + (nxt % div) * hi_mask
        out[i] = out[i] % BASE
    end
    return trim(alloc(a.sign, out))
end

M.shl = ushl
M.shr = ushr

-- ===== Division (long division on limbs) ===============================
--
-- Knuth Algorithm D would be faster for very large divisors, but a clean
-- per-limb long-division is plenty for typical bignum sizes and avoids the
-- normalisation gymnastics. Each step does (high*BASE + low)/div_top with
-- back-correction; numbers stay in double range.

local function udivmod(num, divisor)
    if M.is_zero(divisor) then error("bignum: divide by zero") end
    -- Operate on ABSOLUTE values so the caller's divmod() can re-apply signs.
    -- The multi-limb path below uses M.mul/M.sub/M.add on `divisor`, which carry
    -- its sign; a negative divisor whose magnitude needs the multi-limb path
    -- (|b| >= BASE) would otherwise make M.sub(rem, divisor*qhat) ADD instead of
    -- subtract, yielding a wrong q/r (BIGNUM-001). Normalising both operands to
    -- magnitude here keeps every intermediate non-negative; the single-limb fast
    -- path already used divisor.limbs[1] (a magnitude) so it was unaffected.
    num     = M.abs(num)
    divisor = M.abs(divisor)
    if ucmp(num, divisor) < 0 then return zero(), num end
    -- single-limb fast path
    if #divisor.limbs == 1 then
        local d = divisor.limbs[1]
        local q = {}
        local r = 0
        for i = #num.limbs, 1, -1 do
            local cur = r * BASE + num.limbs[i]
            q[i] = math.floor(cur / d)
            r = cur - q[i] * d
        end
        return trim(alloc(1, q)), from_int(r)
    end
    -- multi-limb long division using estimate from top two limbs of divisor
    local q = zero()
    local rem = zero()
    for i = #num.limbs, 1, -1 do
        -- rem = rem * BASE + num.limbs[i]
        rem = ushl(rem, BASE_BITS)
        rem = M.add(rem, from_int(num.limbs[i]))
        -- estimate qhat
        local qhat
        local n_d = #divisor.limbs
        if #rem.limbs < n_d then
            qhat = 0
        else
            -- use top 2 limbs of rem and top limb of divisor
            local r_top = rem.limbs[#rem.limbs]
            local r_next = #rem.limbs > 1 and rem.limbs[#rem.limbs - 1] or 0
            local d_top = divisor.limbs[n_d]
            if #rem.limbs == n_d then
                qhat = math.floor(r_top / d_top)
            else
                qhat = math.floor((r_top * BASE + r_next) / d_top)
            end
            if qhat >= BASE then qhat = BASE - 1 end
            -- Back off to the largest qhat with divisor*qhat <= rem. The
            -- single-limb top-of-divisor estimate can grossly overestimate when
            -- the divisor's top limb is small (this isn't Knuth-normalized), so
            -- BINARY-search the [0, qhat] range instead of decrementing one at a
            -- time. The linear back-off was O(qhat) multiplies -- up to BASE
            -- (~16M) per numerator limb -- which made dividing by a small-top-
            -- limb divisor (e.g. isqrt's Newton steps, `987654321`) take
            -- seconds. qhat stays an upper bound, so the search is exact.
            local lo, hi = 0, qhat
            while lo < hi do
                local mid = ( lo + hi + 1 ) // 2     -- ceil so lo can advance
                if ucmp( M.mul( divisor, from_int( mid ) ), rem ) <= 0 then
                    lo = mid
                else
                    hi = mid - 1
                end
            end
            qhat = lo
            if qhat > 0 then
                rem = M.sub(rem, M.mul(divisor, from_int(qhat)))
            end
        end
        -- prepend qhat to q (q = q * BASE + qhat)
        q = ushl(q, BASE_BITS)
        q = M.add(q, from_int(qhat))
    end
    return trim(q), trim(rem)
end

function M.divmod(a, b)
    if M.is_zero(b) then error("bignum: divide by zero") end
    local q, r = udivmod(a, b)
    -- truncate-toward-zero semantics; sign(q) = sign(a)*sign(b), sign(r) = sign(a)
    if a.sign < 0 then r = M.neg(r) end
    if a.sign ~= b.sign and not M.is_zero(q) then q = M.neg(q) end
    return q, r
end

function M.div(a, b) local q = M.divmod(a, b); return q end
function M.mod(a, b)
    local _, r = M.divmod(a, b)
    -- mathematical mod: result has the sign of b
    if not M.is_zero(r) and ((r.sign < 0) ~= (b.sign < 0)) then
        r = M.add(r, b)
    end
    return r
end

function M.to_int(a)
    -- only safe when |a| <= 2^53; check caller-side for larger
    local v = 0
    for i = #a.limbs, 1, -1 do v = v * BASE + a.limbs[i] end
    return a.sign < 0 and -v or v
end

-- ===== Power / modular exponentiation ==================================

function M.pow(a, e)
    if type(e) == "number" then e = from_int(e) end
    if e.sign < 0 then error("bignum.pow: negative exponent") end
    local result = one()
    local base   = M.new(a)
    local exp    = M.new(e)
    local two    = from_int(2)
    while not M.is_zero(exp) do
        local _, r = udivmod(exp, two)
        if r.limbs[1] == 1 then result = M.mul(result, base) end
        exp = ushr(exp, 1)
        if not M.is_zero(exp) then base = M.mul(base, base) end
    end
    return result
end

function M.powmod(a, e, m)
    if M.is_zero(m) then error("bignum.powmod: zero modulus") end
    if type(e) == "number" then e = from_int(e) end
    if e.sign < 0 then error("bignum.powmod: negative exponent") end
    local result = one()
    local base   = M.mod(a, m)
    local exp    = M.new(e)
    while not M.is_zero(exp) do
        if exp.limbs[1] % 2 == 1 then
            result = M.mod(M.mul(result, base), m)
        end
        exp = ushr(exp, 1)
        if not M.is_zero(exp) then base = M.mod(M.mul(base, base), m) end
    end
    return result
end

-- ===== GCD / LCM =======================================================

function M.gcd(a, b)
    a, b = M.abs(a), M.abs(b)
    while not M.is_zero(b) do
        local _, r = udivmod(a, b)
        a, b = b, r
    end
    return a
end

function M.lcm(a, b)
    if M.is_zero(a) or M.is_zero(b) then return zero() end
    local g = M.gcd(a, b)
    return M.abs(M.mul(M.div(a, g), b))
end

function M.egcd(a, b)
    -- extended Euclidean: returns g, x, y such that a*x + b*y = g
    local old_r, r = M.new(a), M.new(b)
    local old_s, s = one(), zero()
    local old_t, t = zero(), one()
    while not M.is_zero(r) do
        local q, rem = M.divmod(old_r, r)
        old_r, r = r, rem
        local ns = M.sub(old_s, M.mul(q, s))
        old_s, s = s, ns
        local nt = M.sub(old_t, M.mul(q, t))
        old_t, t = t, nt
    end
    return old_r, old_s, old_t
end

function M.modinv(a, m)
    -- modular inverse: returns x such that (a * x) mod m == 1
    if M.is_zero(m) or M.eq(m, one()) then
        error("bignum.modinv: modulus must be > 1")
    end
    local g, x = M.egcd(M.mod(a, m), m)
    if not M.eq(g, one()) then
        error("bignum.modinv: inputs not coprime, no inverse exists")
    end
    return M.mod(x, m)
end

function M.isqrt(n)
    -- integer square root via Newton's method
    if M.sign(n) < 0 then error("bignum.isqrt: negative input") end
    if M.is_zero(n) then return zero() end
    -- initial guess: 2^((bits+1)/2)
    local bits = ubits(n)
    local x = ushl(one(), math.floor((bits + 1) / 2))
    while true do
        local q = M.div(n, x)
        local y = ushr(M.add(x, q), 1)
        if not M.lt(y, x) then return x end
        x = y
    end
end

function M.factorial(n)
    if type(n) ~= "number" then n = M.to_int(n) end
    if n < 0 then error("bignum.factorial: negative") end
    -- subproduct tree -- multiply small ranges and combine to keep balance
    local function prod(lo, hi)
        if lo > hi then return one() end
        if lo == hi then return from_int(lo) end
        local mid = math.floor((lo + hi) / 2)
        return M.mul(prod(lo, mid), prod(mid + 1, hi))
    end
    if n == 0 then return one() end
    return prod(1, n)
end

function M.popcount(a)
    -- count of set bits in the absolute value
    local n = 0
    for i = 1, #a.limbs do
        local x = a.limbs[i]
        while x > 0 do
            n = n + (x & 1)
            x = x >> 1
        end
    end
    return n
end

-- Spec-friendly aliases are bound near the end of the file, after every
-- target function has been defined (see the block above `return M`).

-- ===== Bitwise =========================================================
--
-- Two's-complement semantics for negative numbers would need infinite-precision
-- sign extension; we operate on magnitudes and treat the result's sign based on
-- the inputs. This matches Python's behaviour for non-negative operands and
-- gives a sensible answer for negatives via XOR/AND of |a|.

local function limb_bitop(a, b, op)
    local na, nb = #a.limbs, #b.limbs
    local n = na > nb and na or nb
    local out = {}
    for i = 1, n do
        local x = a.limbs[i] or 0
        local y = b.limbs[i] or 0
        local r = 0
        local bit = 1
        for _ = 1, BASE_BITS do
            local xb = x % 2
            local yb = y % 2
            local rb = op(xb, yb)
            if rb == 1 then r = r + bit end
            x = (x - xb) / 2
            y = (y - yb) / 2
            bit = bit * 2
        end
        out[i] = r
    end
    return trim(alloc(1, out))
end

function M.band(a, b) return limb_bitop(a, b, function(x, y) return (x == 1 and y == 1) and 1 or 0 end) end
function M.bor (a, b) return limb_bitop(a, b, function(x, y) return (x == 1 or  y == 1) and 1 or 0 end) end
function M.bxor(a, b) return limb_bitop(a, b, function(x, y) return (x ~= y)            and 1 or 0 end) end

function M.bnot(a)
    -- bitwise not on a fixed-width interpretation; for bignum we model
    -- ~x = -x - 1 (Python convention)
    return M.sub(M.neg(a), one())
end

-- ===== Random / Miller-Rabin ===========================================

local function rand_below(n, rng)
    -- uniform in [0, n)
    if M.is_zero(n) then error("bignum.random: zero range") end
    rng = rng or math.random
    local bits = ubits(n)
    local limb_count = #n.limbs
    while true do
        local limbs = {}
        for i = 1, limb_count do
            limbs[i] = math.floor(rng() * BASE) % BASE
        end
        -- mask top limb to bits modulo BASE_BITS
        local extra = bits - (limb_count - 1) * BASE_BITS
        if extra < BASE_BITS then
            local mask = 2 ^ extra
            limbs[limb_count] = limbs[limb_count] % mask
        end
        local cand = trim(alloc(1, limbs))
        if ucmp(cand, n) < 0 then return cand end
    end
end

function M.random(lo, hi, rng)
    -- inclusive lo, exclusive hi
    if hi == nil then hi = lo; lo = zero() end
    local range = M.sub(hi, lo)
    if M.sign(range) <= 0 then error("bignum.random: empty range") end
    return M.add(lo, rand_below(range, rng))
end

local _SMALL_PRIMES = {
    2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,
    73,79,83,89,97,101,103,107,109,113,127,131,137,139,149,151,
    157,163,167,173,179,181,191,193,197,199,211,223,227,229,233,
    239,241,251,257,263,269,271,277,281,283,293,307,311,313,317,
}

function M.is_probable_prime(n, rounds, rng)
    rounds = rounds or 20
    if M.sign(n) <= 0 then return false end
    if M.eq(n, one()) then return false end
    for _, p in ipairs(_SMALL_PRIMES) do
        local pn = from_int(p)
        if M.eq(n, pn) then return true end
        local _, r = udivmod(n, pn)
        if M.is_zero(r) then return false end
    end
    -- write n - 1 = d * 2^s
    local n_minus_1 = M.sub(n, one())
    local d = M.new(n_minus_1)
    local s = 0
    while d.limbs[1] % 2 == 0 and not M.is_zero(d) do
        d = ushr(d, 1)
        s = s + 1
    end
    local two = from_int(2)
    local n_minus_3 = M.sub(n, from_int(3))
    if M.sign(n_minus_3) <= 0 then
        -- n in {2, 3}: handled by small-prime list, but defensively:
        return true
    end
    for _ = 1, rounds do
        local a = M.add(two, rand_below(n_minus_3, rng))
        local x = M.powmod(a, d, n)
        if not M.eq(x, one()) and not M.eq(x, n_minus_1) then
            local witness = true
            for _ = 1, s - 1 do
                x = M.powmod(x, two, n)
                if M.eq(x, n_minus_1) then witness = false; break end
            end
            if witness then return false end
        end
    end
    return true
end

-- ===== tostring ========================================================

local _DIGIT_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"

function M.tostring(a, base)
    base = base or 10
    if base < 2 or base > 36 then error("bignum.tostring: base out of range") end
    if M.is_zero(a) then return "0" end
    local digits, n = {}, 0
    local cur = M.abs(a)
    local b = from_int(base)
    while not M.is_zero(cur) do
        local q, r = udivmod(cur, b)
        n = n + 1; digits[n] = _DIGIT_CHARS:sub(r.limbs[1] + 1, r.limbs[1] + 1)
        cur = q
    end
    local rev = {}
    if a.sign < 0 then rev[1] = "-" end
    local off = a.sign < 0 and 1 or 0
    for i = 1, n do rev[i + off] = digits[n - i + 1] end
    return table.concat(rev)
end

-- ===== Metatable / sugar ===============================================

local function coerce(x)
    if is_bn(x) then return x end
    if type(x) == "number" then return from_int(x) end
    if type(x) == "string" then return from_string(x, 10) end
    error("bignum: cannot coerce " .. type(x))
end

-- Spec-friendly aliases (must come after every target function is defined).
M.tonumber = M.to_int
M.modpow   = M.powmod
M.is_prime = M.is_probable_prime
M.bits     = M.bit_length

mt.__index    = function(_, k) return M[k] end
mt.__add      = function(a, b) return M.add(coerce(a), coerce(b)) end
mt.__sub      = function(a, b) return M.sub(coerce(a), coerce(b)) end
mt.__mul      = function(a, b) return M.mul(coerce(a), coerce(b)) end
mt.__div      = function(a, b) return M.div(coerce(a), coerce(b)) end
mt.__mod      = function(a, b) return M.mod(coerce(a), coerce(b)) end
mt.__pow      = function(a, b) return M.pow(coerce(a), coerce(b)) end
mt.__unm      = function(a)    return M.neg(a) end
mt.__eq       = function(a, b) return M.eq(coerce(a), coerce(b)) end
mt.__lt       = function(a, b) return M.lt(coerce(a), coerce(b)) end
mt.__le       = function(a, b) return M.le(coerce(a), coerce(b)) end
mt.__tostring = function(a)    return M.tostring(a, 10) end

-- Module-level call sugar so `bignum(value)` mirrors `bignum.new(value)`.
setmetatable(M, { __call = function(_, v, base) return M.new(v, base) end })

return M
