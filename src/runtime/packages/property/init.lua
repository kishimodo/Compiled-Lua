-- property -- QuickCheck-style property testing with shrinking.
--
-- A generator is a function (rng, size) -> value, exposed via constructors
-- like int / string / array_of. Each generator also carries an optional
-- `shrink` method (value) -> iterator of candidate smaller values.
--
-- Public surface:
--   property.int(min?, max?)
--   property.string(opts?)              opts: {min_len=, max_len=, alphabet=}
--   property.bool()
--   property.float(min?, max?)
--   property.array_of(gen, min_len?, max_len?)
--   property.record({ k = gen, ... })
--   property.one_of(gens)
--   property.frequency({ {w1, g1}, {w2, g2}, ... })
--   property.map(gen, fn)
--   property.filter(gen, pred)
--   property.recursive(builder_fn)      builder_fn(self) -> generator
--   property.check(prop_fn, gens, opts?)
--
-- `check` returns a result table:
--   { ok=bool, tests_run=, counterexample=, shrunk=, seed=, error= }

local M = {}

-- ===== PRNG ==========================================================
--
-- xorshift64 -- deterministic given a seed, replayable across runs.

local function _rng(seed)
    local state = seed
    if state == 0 then state = 0x9E3779B97F4A7C15 end
    return {
        next = function()
            state = state ~ (state << 13)
            state = state & 0xFFFFFFFFFFFFFFFF
            state = state ~ (state >> 7)
            state = state ~ (state << 17)
            state = state & 0xFFFFFFFFFFFFFFFF
            return state
        end,
        int = function(lo, hi)
            -- range inclusive
            state = state ~ (state << 13); state = state & 0xFFFFFFFFFFFFFFFF
            state = state ~ (state >> 7)
            state = state ~ (state << 17); state = state & 0xFFFFFFFFFFFFFFFF
            local span = hi - lo + 1
            if span <= 0 then return lo end
            return lo + (state % span)
        end,
        float = function()
            state = state ~ (state << 13); state = state & 0xFFFFFFFFFFFFFFFF
            state = state ~ (state >> 7)
            state = state ~ (state << 17); state = state & 0xFFFFFFFFFFFFFFFF
            return (state >> 11) * (1.0 / 2^53)
        end,
        state = function() return state end,
    }
end

-- ===== Generator constructors ========================================

local function mk_gen(generate, shrink)
    return { generate = generate, shrink = shrink or function() return function() return nil end end }
end

function M.int(min, max)
    min = min or -100
    max = max or 100
    return mk_gen(
        function(rng) return rng.int(min, max) end,
        function(v)
            -- Shrink toward zero (or toward min if zero is out of range).
            local target = 0
            if target < min then target = min end
            if target > max then target = max end
            local seen = { [v] = true }
            local candidates = {}
            if v ~= target then candidates[#candidates + 1] = target end
            -- halving sequence
            local cur = v
            while true do
                local step = (cur - target) // 2
                if step == 0 then break end
                cur = cur - step
                if not seen[cur] then candidates[#candidates + 1] = cur; seen[cur] = true end
            end
            -- adjacent moves
            if v > target and not seen[v - 1] then candidates[#candidates + 1] = v - 1 end
            if v < target and not seen[v + 1] then candidates[#candidates + 1] = v + 1 end
            local i = 0
            return function()
                i = i + 1; return candidates[i]
            end
        end)
end

function M.float(min, max)
    min = min or -1.0
    max = max or 1.0
    return mk_gen(
        function(rng) return min + rng.float() * (max - min) end,
        function(v)
            local candidates = { 0.0, math.floor(v), v / 2 }
            local i = 0
            return function()
                i = i + 1; return candidates[i]
            end
        end)
end

function M.bool()
    return mk_gen(
        function(rng) return rng.int(0, 1) == 1 end,
        function(v)
            -- false is "simpler"
            if v then return (function() local d = false; return function() local r = d; d = nil; return r end end)() end
            return function() return nil end
        end)
end

function M.string(opts)
    opts = opts or {}
    local min_len = opts.min_len or 0
    local max_len = opts.max_len or 32
    local alphabet = opts.alphabet or "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "
    local alen = #alphabet
    return mk_gen(
        function(rng, size)
            local cap = size and math.min(max_len, size) or max_len
            if cap < min_len then cap = min_len end
            local n = rng.int(min_len, cap)
            if n <= 0 then return "" end
            local out = {}
            for i = 1, n do
                out[i] = alphabet:sub(rng.int(1, alen), rng.int(1, alen))
            end
            return table.concat(out)
        end,
        function(v)
            local candidates = {}
            -- empty (if allowed)
            if min_len == 0 and v ~= "" then candidates[#candidates + 1] = "" end
            -- halving lengths
            local n = #v
            while n > min_len do
                n = n // 2
                if n >= min_len then candidates[#candidates + 1] = v:sub(1, n) end
            end
            -- drop the last char
            if #v > min_len then candidates[#candidates + 1] = v:sub(1, #v - 1) end
            local i = 0
            return function() i = i + 1; return candidates[i] end
        end)
end

function M.array_of(gen, min_len, max_len)
    min_len = min_len or 0
    max_len = max_len or 16
    return mk_gen(
        function(rng, size)
            local cap = size and math.min(max_len, size) or max_len
            if cap < min_len then cap = min_len end
            local n = rng.int(min_len, cap)
            local out = {}
            for i = 1, n do
                out[i] = gen.generate(rng, size and (size // 2) or nil)
            end
            return out
        end,
        function(v)
            local candidates = {}
            local n = #v
            -- empty (if allowed)
            if min_len == 0 and n > 0 then candidates[#candidates + 1] = {} end
            -- drop each element once
            for i = 1, n do
                if n - 1 >= min_len then
                    local copy = {}
                    for j = 1, n do if j ~= i then copy[#copy + 1] = v[j] end end
                    candidates[#candidates + 1] = copy
                end
            end
            -- shrink first element
            if n > 0 then
                local first_shrink = gen.shrink(v[1])
                for sv in first_shrink do
                    local copy = { sv }
                    for j = 2, n do copy[#copy + 1] = v[j] end
                    candidates[#candidates + 1] = copy
                end
            end
            local i = 0
            return function() i = i + 1; return candidates[i] end
        end)
end

function M.record(spec)
    return mk_gen(
        function(rng, size)
            local out = {}
            for k, g in pairs(spec) do
                out[k] = g.generate(rng, size)
            end
            return out
        end,
        function(v)
            -- Shrink one field at a time, deterministic key order.
            local keys = {}
            for k in pairs(spec) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local cand = {}
            for _, k in ipairs(keys) do
                for sv in spec[k].shrink(v[k]) do
                    local copy = {}
                    for kk, vv in pairs(v) do copy[kk] = vv end
                    copy[k] = sv
                    cand[#cand + 1] = copy
                end
            end
            local i = 0
            return function() i = i + 1; return cand[i] end
        end)
end

function M.one_of(gens)
    return mk_gen(
        function(rng, size)
            local pick = gens[rng.int(1, #gens)]
            return pick.generate(rng, size)
        end,
        function(v)
            -- No principled shrinker without type tags; try each gen's shrinker.
            local i = 0
            local current
            return function()
                while true do
                    if current then
                        local x = current()
                        if x ~= nil then return x end
                        current = nil
                    end
                    i = i + 1
                    if i > #gens then return nil end
                    current = gens[i].shrink(v)
                end
            end
        end)
end

function M.frequency(weighted)
    local total = 0
    for _, p in ipairs(weighted) do total = total + p[1] end
    return mk_gen(
        function(rng, size)
            local r = rng.int(1, total)
            local accum = 0
            for _, p in ipairs(weighted) do
                accum = accum + p[1]
                if r <= accum then return p[2].generate(rng, size) end
            end
            return weighted[#weighted][2].generate(rng, size)
        end,
        function(v)
            -- Use the highest-weight gen's shrinker as best guess.
            local best = weighted[1]
            for _, p in ipairs(weighted) do
                if p[1] > best[1] then best = p end
            end
            return best[2].shrink(v)
        end)
end

function M.map(gen, fn)
    -- Cannot shrink reliably after mapping (no inverse), but we still try by
    -- shrinking the underlying value and mapping each candidate.
    return mk_gen(
        function(rng, size) return fn(gen.generate(rng, size)) end,
        function(_v)
            -- We don't know the pre-image, so just return empty.
            return function() return nil end
        end)
end

function M.filter(gen, pred)
    return mk_gen(
        function(rng, size)
            for _ = 1, 100 do
                local v = gen.generate(rng, size)
                if pred(v) then return v end
            end
            error("property.filter: predicate rejected 100 candidates -- generator likely too narrow")
        end,
        function(v)
            -- Filter the underlying shrinker by the same predicate.
            local inner = gen.shrink(v)
            return function()
                while true do
                    local cand = inner()
                    if cand == nil then return nil end
                    if pred(cand) then return cand end
                end
            end
        end)
end

-- Spec alias.
M.such_that = M.filter

-- ===== Additional combinators =========================================

-- Tuple of fixed length, heterogeneous generators.
function M.tuple(gens)
    return mk_gen(
        function(rng, size)
            local out = {}
            for i = 1, #gens do
                out[i] = gens[i].generate(rng, size)
            end
            return out
        end,
        function(v)
            local cand = {}
            for i = 1, #gens do
                for sv in gens[i].shrink(v[i]) do
                    local copy = {}
                    for j = 1, #v do copy[j] = v[j] end
                    copy[i] = sv
                    cand[#cand + 1] = copy
                end
            end
            local i = 0
            return function() i = i + 1; return cand[i] end
        end)
end

-- Bind: monadic chain. `bind(gen, fn)` produces a generator whose body
-- depends on the previously-generated value.
function M.bind(gen, fn)
    return mk_gen(
        function(rng, size)
            local v = gen.generate(rng, size)
            local next_gen = fn(v)
            return next_gen.generate(rng, size)
        end,
        function(_v)
            -- Shrinking after bind is intractable in general.
            return function() return nil end
        end)
end

-- Spec aliases.
M.list_of = M.array_of

-- table_of: random-keyed map. Spec calls it table_of(key_gen, val_gen, size?).
function M.table_of(key_gen, val_gen, size_range)
    local lo, hi
    if type(size_range) == "table" then
        lo, hi = size_range[1] or 0, size_range[2] or 8
    else
        lo, hi = 0, size_range or 8
    end
    return mk_gen(
        function(rng, sz)
            local cap = sz and math.min(hi, sz) or hi
            if cap < lo then cap = lo end
            local n = rng.int(lo, cap)
            local out = {}
            for _ = 1, n do
                local k = key_gen.generate(rng, sz)
                local v = val_gen.generate(rng, sz)
                out[k] = v
            end
            return out
        end,
        function(v)
            local cand = {}
            -- Try empty if allowed.
            local count = 0
            for _ in pairs(v) do count = count + 1 end
            if lo == 0 and count > 0 then cand[#cand + 1] = {} end
            -- Drop one key at a time.
            for drop in pairs(v) do
                if count - 1 >= lo then
                    local copy = {}
                    for kk, vv in pairs(v) do if kk ~= drop then copy[kk] = vv end end
                    cand[#cand + 1] = copy
                end
            end
            local i = 0
            return function() i = i + 1; return cand[i] end
        end)
end

-- Spec alias for one_of.
M.oneof = M.one_of

-- ===== Property registration + integration ============================

-- prop(name, gens, body) -- a property is a record { name, gens, body }.
-- Accepts either prop(name, {gen1, gen2}, fn) or prop(name, gen1, gen2, ..., fn).
function M.prop(name, ...)
    local n = select("#", ...)
    if n == 0 then error("property.prop: missing body", 2) end
    -- Materialise vararg slot-by-slot to avoid the `{ ... }` JIT-unfriendly
    -- mixed constructor pattern.
    local args = {}
    for i = 1, n do args[i] = select(i, ...) end
    local fn = args[n]
    if type(fn) ~= "function" then
        error("property.prop: last argument must be a function", 2)
    end
    local gens = {}
    if n == 2 and type(args[1]) == "table" and not args[1].generate then
        local list = args[1]
        for i = 1, #list do gens[i] = list[i] end
    else
        for i = 1, n - 1 do gens[i] = args[i] end
    end
    return {
        kind = "property",
        name = name,
        gens = gens,
        body = fn,
        run  = function(opts) return M.check(fn, gens, opts) end,
    }
end

-- it_prop(name, prop, opts?) -- bridges into the `test` package if loaded.
function M.it_prop(name, p, opts)
    opts = opts or {}
    local ok, test_pkg = pcall(require, "test")
    if not ok then
        -- Stand-alone fallback: just run it now.
        local res = p.run(opts)
        if not res.ok then
            error(string.format("property '%s' failed after %d tests (seed=%s): %s",
                p.name or name, res.tests_run, tostring(res.seed), tostring(res.error)), 2)
        end
        return res
    end
    test_pkg.it(name, function()
        local res = p.run(opts)
        if not res.ok then
            local ce = res.counterexample
            local rendered
            if type(ce) == "table" then
                local parts = {}
                for i, v in ipairs(ce) do parts[i] = tostring(v) end
                rendered = "(" .. table.concat(parts, ", ") .. ")"
            else
                rendered = tostring(ce)
            end
            error(string.format(
                "property failed after %d tests (seed=%s)\n  counterexample: %s\n  error: %s",
                res.tests_run, tostring(res.seed), rendered, tostring(res.error)))
        end
    end, opts)
end

function M.recursive(builder)
    -- Builder receives a "self" stub (returns recursively-bound generator).
    local self_gen
    self_gen = mk_gen(
        function(rng, size)
            local depth = size or 5
            if depth <= 0 then
                -- base case -- builder is expected to terminate when size hits 0
                return builder(self_gen, 0).generate(rng, 0)
            end
            return builder(self_gen, depth).generate(rng, depth - 1)
        end,
        function(_v) return function() return nil end end)
    return self_gen
end

-- ===== check + shrink ================================================

local function safe_run(prop_fn, args)
    -- Hand-unroll up to 8 positional args; fall back to table.unpack beyond
    -- that. Avoids a JIT codegen issue with the (vararg + table.unpack)
    -- combined pattern in tight loops.
    local n = #args
    local ok, result
    if     n == 0 then ok, result = pcall(prop_fn)
    elseif n == 1 then ok, result = pcall(prop_fn, args[1])
    elseif n == 2 then ok, result = pcall(prop_fn, args[1], args[2])
    elseif n == 3 then ok, result = pcall(prop_fn, args[1], args[2], args[3])
    elseif n == 4 then ok, result = pcall(prop_fn, args[1], args[2], args[3], args[4])
    elseif n == 5 then ok, result = pcall(prop_fn, args[1], args[2], args[3], args[4], args[5])
    elseif n == 6 then ok, result = pcall(prop_fn, args[1], args[2], args[3], args[4], args[5], args[6])
    elseif n == 7 then ok, result = pcall(prop_fn, args[1], args[2], args[3], args[4], args[5], args[6], args[7])
    elseif n == 8 then ok, result = pcall(prop_fn, args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])
    else               ok, result = pcall(prop_fn, table.unpack(args, 1, n)) end
    if not ok then return false, result end
    -- prop must return strictly true; anything else (nil/false) is a failure.
    return result == true, result
end

function M.check(prop_fn, gens, opts)
    opts = opts or {}
    local num_tests   = opts.num_tests or 100
    local max_shrinks = opts.max_shrinks or 100
    local max_size    = opts.max_size or 100
    -- Seed defaults to a time-based value but is recorded so the user can replay.
    local seed = opts.seed or (os.time() ~ (os.clock() * 1e6))
    local rng = _rng(seed)

    local function gen_args(size)
        local args = {}
        for i, g in ipairs(gens) do
            args[i] = g.generate(rng, size)
        end
        return args
    end

    -- Random testing loop.
    for i = 1, num_tests do
        local size = 1 + ((i - 1) * max_size) // num_tests
        local args = gen_args(size)
        local ok, err = safe_run(prop_fn, args)
        if not ok then
            -- Shrink.
            local best = args
            local best_err = err
            local shrinks_done = 0
            local progress = true
            while progress and shrinks_done < max_shrinks do
                progress = false
                for j = 1, #gens do
                    local sh = gens[j].shrink(best[j])
                    for cand in sh do
                        shrinks_done = shrinks_done + 1
                        if shrinks_done > max_shrinks then break end
                        local trial = {}
                        for k = 1, #best do trial[k] = best[k] end
                        trial[j] = cand
                        local ok2, err2 = safe_run(prop_fn, trial)
                        if not ok2 then
                            best = trial
                            best_err = err2
                            progress = true
                            break  -- restart shrink with new best
                        end
                    end
                    if progress then break end
                    if shrinks_done > max_shrinks then break end
                end
            end
            return {
                ok            = false,
                tests_run     = i,
                counterexample = best,
                original      = args,
                shrunk        = shrinks_done,
                seed          = seed,
                error         = best_err,
            }
        end
    end
    return { ok = true, tests_run = num_tests, seed = seed }
end

return M
