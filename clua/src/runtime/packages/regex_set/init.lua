-- regex_set -- Aho-Corasick multi-pattern (literal string) matcher.
--
-- Public surface:
--   regex_set.compile(patterns, opts?)
--     patterns : array of strings (literal needles)
--     opts     : { case_insensitive = false }
--   matcher:find_all(text)      -> array of { pattern = s, index = i,
--                                              start = a, finish = b }
--   matcher:contains_any(text)  -> bool
--   matcher:matches(text)       -> array of pattern indices (unique, sorted)
--
-- Implementation:
--   Trie with a `fail` pointer on each node (BFS over the trie root's
--   children) and an `output` list collecting every pattern that ends at
--   the node (or via the failure link). Per-node `goto` table is sparse
--   (Lua table keyed by byte 0..255). Matching is a single pass over the
--   input bytes; on each byte we follow goto or chase fail until we hit
--   a transition (or fall back to root).

local M = {}

local Matcher = {}
Matcher.__index = Matcher

-- ===== Compile =========================================================

local function new_node(id)
    return { id = id, goto_ = {}, fail = 1, out = {} }
end

local function lower_byte(b)
    if b >= 65 and b <= 90 then return b + 32 end
    return b
end

function M.compile(patterns, opts)
    opts = opts or {}
    local ci = opts.case_insensitive and true or false

    local nodes = { new_node(1) }  -- 1 = root
    local pat_meta = {}            -- pattern info: original, length

    -- Build trie.
    for idx, raw in ipairs(patterns) do
        if type(raw) ~= "string" or raw == "" then
            error("regex_set: pattern #" .. idx .. " must be a non-empty string")
        end
        local p = ci and raw:lower() or raw
        local cur = 1
        for i = 1, #p do
            local b = p:byte(i)
            local nx = nodes[cur].goto_[b]
            if not nx then
                nx = #nodes + 1
                nodes[nx] = new_node(nx)
                nodes[cur].goto_[b] = nx
            end
            cur = nx
        end
        local out = nodes[cur].out
        out[#out + 1] = idx
        pat_meta[idx] = { pattern = raw, length = #p }
    end

    -- BFS to set failure links and merge outputs along the chain.
    local queue, head, tail = {}, 1, 0
    -- Root's direct children all fail to root.
    for b, child in pairs(nodes[1].goto_) do
        nodes[child].fail = 1
        tail = tail + 1; queue[tail] = child
    end
    while head <= tail do
        local u = queue[head]; head = head + 1
        for b, v in pairs(nodes[u].goto_) do
            -- Find failure for v.
            local f = nodes[u].fail
            while f ~= 1 and not nodes[f].goto_[b] do
                f = nodes[f].fail
            end
            local nxt = nodes[f].goto_[b]
            if nxt and nxt ~= v then
                nodes[v].fail = nxt
            else
                nodes[v].fail = 1
            end
            -- Inherit outputs along the failure chain.
            local f_out = nodes[nodes[v].fail].out
            if #f_out > 0 then
                local own = nodes[v].out
                for _, p in ipairs(f_out) do own[#own + 1] = p end
            end
            tail = tail + 1; queue[tail] = v
        end
    end

    return setmetatable({
        _nodes = nodes,
        _meta  = pat_meta,
        _ci    = ci,
    }, Matcher)
end

-- ===== Step helper =====================================================
--
-- Given current state and input byte, return next state (following fail
-- links as needed).

local function step(nodes, state, b)
    while state ~= 1 and not nodes[state].goto_[b] do
        state = nodes[state].fail
    end
    return nodes[state].goto_[b] or 1
end

-- ===== find_all ========================================================

function Matcher:find_all(text)
    local nodes = self._nodes
    local meta  = self._meta
    local out   = {}
    local state = 1
    for i = 1, #text do
        local b = text:byte(i)
        if self._ci then b = lower_byte(b) end
        state = step(nodes, state, b)
        local node_out = nodes[state].out
        if #node_out > 0 then
            for _, pid in ipairs(node_out) do
                local m = meta[pid]
                out[#out + 1] = {
                    pattern = m.pattern,
                    index   = pid,
                    start   = i - m.length + 1,
                    finish  = i,
                }
            end
        end
    end
    return out
end

-- ===== contains_any ===================================================

function Matcher:contains_any(text)
    local nodes = self._nodes
    local state = 1
    for i = 1, #text do
        local b = text:byte(i)
        if self._ci then b = lower_byte(b) end
        state = step(nodes, state, b)
        if #nodes[state].out > 0 then return true end
    end
    return false
end

-- ===== matches (unique pattern indices) ===============================

function Matcher:matches(text)
    local nodes = self._nodes
    local seen  = {}
    local state = 1
    for i = 1, #text do
        local b = text:byte(i)
        if self._ci then b = lower_byte(b) end
        state = step(nodes, state, b)
        local node_out = nodes[state].out
        if #node_out > 0 then
            for _, pid in ipairs(node_out) do seen[pid] = true end
        end
    end
    local out = {}
    for pid in pairs(seen) do out[#out + 1] = pid end
    table.sort(out)
    return out
end

function Matcher:pattern_count() return #self._meta end

return M
