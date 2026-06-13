-- fuzz -- coroutine-based input fuzzer.
--
-- Drives `target_fn` with randomly-generated inputs and records any case that
-- causes `target_fn` to raise an error or return false. Crashes are persisted
-- to a corpus directory so they can be replayed deterministically.
--
-- Public surface:
--   fuzz.fuzz(target_fn, opts?)
--   fuzz.replay(target_fn, corpus_path)
--   fuzz.save_seed(corpus_path, input)        -- manual seed (e.g. unit test input)
--   fuzz.load_corpus(corpus_path)             -> list of {input=, name=}
--
-- opts:
--   input_gen     a generator from the `property` package (preferred name)
--   generators    alias for input_gen (spec spelling). Single gen or list.
--   iterations    default 10000
--   n             alias for `iterations` (spec spelling)
--   time_budget_ms  stop after wall-clock budget
--   timeout_per_run_ms  per-call deadline; if exceeded the call is recorded
--                       as a "timeout" crash (best-effort, cooperative)
--   max_crashes   stop after recording this many crashes (default unlimited)
--   seed          PRNG seed for reproducibility
--   max_size      max generator size (default 256)
--   corpus_dir    path to write/read crashing inputs (default "./fuzz-corpus")
--   on_crash      fn(crash_record)  -- crash_record fields: input, error, iteration
--   on_progress   fn(iteration, total, crashes_far)  -- called every ~1000 iters
--   minimize      shrink crash inputs after discovery (default true)
--   max_shrinks   shrink attempts per crash (default 64)
--
-- Returns:
--   { iterations=, crashes=<list>, duration_ms=, seed=, stopped_reason= }

local M = {}

-- ===== PRNG (mirrors property package; intentional dup to avoid hard dep) =

local function _rng(seed)
    local state = seed
    if state == 0 then state = 0x9E3779B97F4A7C15 end
    return {
        next = function()
            state = state ~ (state << 13); state = state & 0xFFFFFFFFFFFFFFFF
            state = state ~ (state >> 7)
            state = state ~ (state << 17); state = state & 0xFFFFFFFFFFFFFFFF
            return state
        end,
        int = function(lo, hi)
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
    }
end

-- ===== Corpus serialization =========================================
--
-- We re-use snapshot-style lua_repr so the corpus is human-readable Lua and
-- the user can manually craft seeds. Each entry is one file under the corpus
-- directory.

local function lua_repr(v, depth, seen)
    depth = depth or 0
    seen  = seen or {}
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v then return "0/0"
        elseif v == math.huge then return "math.huge"
        elseif v == -math.huge then return "-math.huge" end
        return tostring(v)
    end
    if t == "string" then return string.format("%q", v) end
    if t == "table" then
        if seen[v] then return '"<cycle>"' end
        seen[v] = true
        if depth > 32 then return '"<too deep>"' end
        local parts = {}
        local n = #v
        for i = 1, n do
            parts[#parts + 1] = lua_repr(v[i], depth + 1, seen)
        end
        local skeys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                skeys[#skeys + 1] = k
            end
        end
        table.sort(skeys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(skeys) do
            local key_str
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                key_str = k .. "="
            else
                key_str = "[" .. lua_repr(k, depth + 1, seen) .. "]="
            end
            parts[#parts + 1] = key_str .. lua_repr(v[k], depth + 1, seen)
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return string.format("%q", "<" .. t .. ">")
end

local function ensure_dir(path)
    local probe = path .. "/.probe"
    local f = io.open(probe, "wb")
    if f then f:close(); os.remove(probe); return end
    -- Windows mkdir; harmless if it fails (write will then error).
    os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
end

local function hash_str(s)
    -- FNV-1a 32-bit -- only need an unlikely-to-collide name for the corpus file.
    local h = 0x811C9DC5
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 0x01000193) & 0xFFFFFFFF
    end
    return string.format("%08x", h)
end

function M.save_seed(corpus_dir, input)
    ensure_dir(corpus_dir)
    local body = "return " .. lua_repr(input)
    local name = corpus_dir .. "/seed-" .. hash_str(body) .. ".lua"
    -- If a file with the same content hash already exists, skip.
    local existing = io.open(name, "rb")
    if existing then existing:close(); return name end
    local f, err = io.open(name, "wb")
    if not f then error("fuzz.save_seed: " .. tostring(err)) end
    f:write(body)
    f:close()
    return name
end

local function save_crash(corpus_dir, rec)
    ensure_dir(corpus_dir)
    local body = "return " .. lua_repr(rec.input)
    local name = corpus_dir .. "/crash-" .. hash_str(body) .. ".lua"
    local existing = io.open(name, "rb")
    if existing then existing:close(); return name end
    local f, err = io.open(name, "wb")
    if not f then error("fuzz.save_crash: " .. tostring(err)) end
    f:write(body)
    f:write("\n-- error: " .. (tostring(rec.error):gsub("\n", "\n-- ")) .. "\n")
    f:close()
    return name
end

function M.load_corpus(corpus_dir)
    local out = {}
    -- Portable directory listing via shell. We assume cmd.exe on the CLua
    -- host; this is a Windows-only project.
    local pipe = io.popen('dir /b "' .. corpus_dir:gsub("/", "\\") .. '" 2>nul')
    if not pipe then return out end
    for line in pipe:lines() do
        if line:match("%.lua$") then
            local path = corpus_dir .. "/" .. line
            local f = io.open(path, "rb")
            if f then
                local body = f:read("*a")
                f:close()
                local chunk, err = load(body, "@" .. path, "t", {
                    math = math, string = string,
                })
                if chunk then
                    local ok, val = pcall(chunk)
                    if ok then
                        out[#out + 1] = { input = val, name = path }
                    end
                end
            end
        end
    end
    pipe:close()
    return out
end

-- ===== Core fuzz loop ===============================================

local function safe_call(fn, input)
    local ok, ret = pcall(fn, input)
    if not ok then return false, ret end
    if ret == false then return false, "target returned false" end
    return true
end

-- Try to shrink a crashing input via the generator's shrink iterator.
local function minimize(target_fn, input, gen, max_shrinks)
    if not gen.shrink then return input, max_shrinks end
    local best = input
    local budget = max_shrinks
    local progress = true
    while progress and budget > 0 do
        progress = false
        for candidate in gen.shrink(best) do
            budget = budget - 1
            if budget <= 0 then break end
            local ok = safe_call(target_fn, candidate)
            if not ok then
                best = candidate
                progress = true
                break
            end
        end
    end
    return best, max_shrinks - budget
end

function M.fuzz(target_fn, opts)
    opts = opts or {}
    local input_gen = opts.input_gen or opts.generators
    -- `generators` can be a list of gens -- wrap as a tuple-producing gen.
    if input_gen and input_gen[1] and not input_gen.generate then
        local list = input_gen
        input_gen = {
            generate = function(rng, sz)
                local out = {}
                for i, g in ipairs(list) do out[i] = g.generate(rng, sz) end
                return out
            end,
            shrink = function(v)
                local cand = {}
                for i, g in ipairs(list) do
                    if g.shrink then
                        for sv in g.shrink(v[i]) do
                            local copy = {}
                            for j = 1, #v do copy[j] = v[j] end
                            copy[i] = sv
                            cand[#cand + 1] = copy
                        end
                    end
                end
                local i = 0
                return function() i = i + 1; return cand[i] end
            end,
        }
    end
    if not input_gen then
        error("fuzz.fuzz: opts.input_gen (or opts.generators) is required")
    end
    opts.input_gen = input_gen
    local iterations    = opts.iterations or opts.n or 10000
    local time_budget   = opts.time_budget_ms
    local per_run_ms    = opts.timeout_per_run_ms
    local max_crashes   = opts.max_crashes
    local max_size      = opts.max_size or 256
    local corpus_dir    = opts.corpus_dir or "./fuzz-corpus"
    local seed          = opts.seed or (os.time() ~ math.floor(os.clock() * 1e6))
    local rng           = _rng(seed)
    local minimize_on   = opts.minimize ~= false
    local max_shrinks   = opts.max_shrinks or 64

    local crashes = {}
    local start_ms = os.clock() * 1000
    local stopped_reason = "iterations"
    local seen_errors = {}  -- dedupe by error fingerprint

    -- Replay any pre-seeded corpus first; this is how regression coverage builds up.
    local seeded = M.load_corpus(corpus_dir)
    for _, s in ipairs(seeded) do
        local ok, err = safe_call(target_fn, s.input)
        if not ok then
            local rec = { input = s.input, error = err, iteration = 0, source = s.name }
            crashes[#crashes + 1] = rec
            if opts.on_crash then opts.on_crash(rec) end
        end
    end

    local i = 0
    while i < iterations do
        i = i + 1
        if time_budget and (os.clock() * 1000 - start_ms) >= time_budget then
            stopped_reason = "time"
            break
        end
        if max_crashes and #crashes >= max_crashes then
            stopped_reason = "max_crashes"
            break
        end
        local size = 1 + ((i - 1) * max_size) // iterations
        local ok_gen, input = pcall(opts.input_gen.generate, rng, size)
        if not ok_gen then
            -- Generator itself errored; abandon this iteration but keep going.
            input = nil
        end
        -- Per-run timeout (best-effort: check wall-clock around the call).
        local call_start = per_run_ms and (os.clock() * 1000) or nil
        local ok, err = safe_call(target_fn, input)
        if per_run_ms then
            local elapsed = os.clock() * 1000 - call_start
            if ok and elapsed > per_run_ms then
                ok, err = false, string.format("timeout: ran for %.1fms (limit %dms)",
                                               elapsed, per_run_ms)
            end
        end
        if not ok then
            local fingerprint = tostring(err):sub(1, 200)
            if not seen_errors[fingerprint] then
                seen_errors[fingerprint] = true
                local shrunk, shrink_count = input, 0
                if minimize_on then
                    shrunk, shrink_count = minimize(target_fn, input, opts.input_gen, max_shrinks)
                end
                local rec = {
                    input = shrunk, original = input, error = err,
                    iteration = i, shrinks = shrink_count,
                }
                crashes[#crashes + 1] = rec
                save_crash(corpus_dir, rec)
                if opts.on_crash then opts.on_crash(rec) end
            end
        end
        if opts.on_progress and (i % 1000 == 0) then
            opts.on_progress(i, iterations, #crashes)
        end
    end

    return {
        iterations     = i,
        crashes        = crashes,
        duration_ms    = os.clock() * 1000 - start_ms,
        seed           = seed,
        stopped_reason = stopped_reason,
        corpus_dir     = corpus_dir,
    }
end

-- Replay either a directory (replays every file in the corpus) or a single
-- saved crash file, returning per-input results.
function M.replay(target_fn, corpus_path)
    local items
    -- Single-file form: try to open it directly.
    local f = io.open(corpus_path, "rb")
    if f then
        local body = f:read("*a")
        f:close()
        local chunk = load(body, "@" .. corpus_path, "t", { math = math, string = string })
        if chunk then
            local ok, val = pcall(chunk)
            if ok then items = { { input = val, name = corpus_path } } end
        end
    end
    if not items then items = M.load_corpus(corpus_path) end
    local results = {}
    for _, item in ipairs(items) do
        local ok, err = safe_call(target_fn, item.input)
        results[#results + 1] = {
            name  = item.name,
            input = item.input,
            ok    = ok,
            error = (not ok) and err or nil,
        }
    end
    return results
end

-- ===== mutate (seed-driven mutation) ==================================
--
-- Generate a variant of an existing input. Heuristics depend on the input
-- type; if `opts.generator` is given, that generator's shrinker is used as
-- a source of "nearby" candidates (the inverse direction of shrinking).
--
-- opts:
--   seed       PRNG seed (default time-based)
--   rate       0..1 probability each mutation step fires (default 0.5)
--   generator  generator from `property` (preferred); when present, we may
--              call its `.generate` to inject a fresh sub-value
--   max_size   passed to generator

function M.mutate(seed_input, opts)
    opts = opts or {}
    local rng = _rng(opts.seed or (os.time() ~ math.floor(os.clock() * 1e6)))
    local rate = opts.rate or 0.5

    local function mutate_string(s)
        local n = #s
        if n == 0 then return string.char(rng.int(32, 126)) end
        local op = rng.int(1, 4)
        if op == 1 then
            -- flip a byte
            local i = rng.int(1, n)
            local b = (s:byte(i) ~ rng.int(1, 255)) & 0xFF
            return s:sub(1, i - 1) .. string.char(b) .. s:sub(i + 1)
        elseif op == 2 then
            -- insert a byte
            local i = rng.int(0, n)
            return s:sub(1, i) .. string.char(rng.int(0, 255)) .. s:sub(i + 1)
        elseif op == 3 then
            -- delete a byte
            if n == 1 then return "" end
            local i = rng.int(1, n)
            return s:sub(1, i - 1) .. s:sub(i + 1)
        else
            -- duplicate a slice
            local i = rng.int(1, n)
            local j = rng.int(i, n)
            return s:sub(1, j) .. s:sub(i, j) .. s:sub(j + 1)
        end
    end

    local function mutate_number(n)
        local op = rng.int(1, 6)
        if op == 1 then return 0
        elseif op == 2 then return -n
        elseif op == 3 then return n + 1
        elseif op == 4 then return n - 1
        elseif op == 5 then return n * 2
        else return math.tointeger(n) and (n ~ rng.int(0, 255)) or (n * (1 + rng.float())) end
    end

    local function mutate_table(t)
        local out = {}
        for k, v in pairs(t) do
            if rng.float() < rate then
                out[k] = M.mutate(v, { seed = rng.int(1, 2^31), rate = rate })
            else
                out[k] = v
            end
        end
        -- Occasionally drop or add a key.
        if rng.float() < rate * 0.5 then
            local keys = {}
            for k in pairs(out) do keys[#keys + 1] = k end
            if #keys > 0 then out[keys[rng.int(1, #keys)]] = nil end
        end
        return out
    end

    local t = type(seed_input)
    if t == "string"  then return mutate_string(seed_input) end
    if t == "number"  then return mutate_number(seed_input) end
    if t == "boolean" then return not seed_input end
    if t == "table"   then return mutate_table(seed_input) end
    if t == "nil"     then
        if opts.generator and opts.generator.generate then
            return opts.generator.generate(rng, opts.max_size or 64)
        end
        return nil
    end
    return seed_input
end

return M
