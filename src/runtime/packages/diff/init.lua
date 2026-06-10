-- diff -- Myers diff (line / word / char) + unified-diff output + merge.
--
-- Public surface:
--   diff.lines(a, b)             -> { {kind=, text=, ...}, ... }
--   diff.words(a, b)             -> word-level edit script
--   diff.chars(a, b)             -> char-level edit script
--   diff.unified(a, b, opts?)    -> string  (opts: context=3, fromfile, tofile)
--   diff.patch(s, diff_text)     -> new_string  (apply unified-diff text)
--   diff.apply(orig, hunks)      -> new_string  (apply structured hunks)
--   diff.merge(base, ours, theirs) -> { merged=, conflicts={...} }
--
-- Edit-script element shape:
--   { kind = "equal" | "insert" | "delete", text = <line/word/char>,
--     a_line = <1-based source line>, b_line = <1-based dest line> }
--   `a_line` is set on "equal" / "delete"; `b_line` on "equal" / "insert".

local M = {}

-- ===== Tokenizers ======================================================

local function split_lines(s)
    -- Preserve trailing newline as part of each line so reassembly is exact.
    local out, np = {}, 0
    local i, len = 1, #s
    while i <= len do
        local nl = s:find("\n", i, true)
        if nl == nil then
            np = np + 1; out[np] = s:sub(i)
            break
        end
        np = np + 1; out[np] = s:sub(i, nl)
        i = nl + 1
    end
    return out
end

local function split_words(s)
    -- "Word" = a run of word chars OR a run of non-word chars; we keep
    -- whitespace runs as separate tokens so diffs read naturally.
    local out, np = {}, 0
    local i, len = 1, #s
    while i <= len do
        local c = s:sub(i, i)
        local j = i
        if c:match("[%w_]") then
            while j <= len and s:sub(j, j):match("[%w_]") do j = j + 1 end
        elseif c:match("%s") then
            while j <= len and s:sub(j, j):match("%s") do j = j + 1 end
        else
            -- single punctuation char per token; keeps diff aligned tightly
            j = j + 1
        end
        np = np + 1; out[np] = s:sub(i, j - 1)
        i = j
    end
    return out
end

local function split_chars(s)
    local out = {}
    for i = 1, #s do out[i] = s:sub(i, i) end
    return out
end

-- ===== Myers diff core =================================================
-- Cormen-style O(ND). Returns a list of edit operations from `a` to `b`
-- expressed over arrays of tokens, not the original strings.

local function diff_tokens(a, b)
    local n, m = #a, #b
    if n == 0 and m == 0 then return {} end
    if n == 0 then
        local r = {}
        for i = 1, m do r[i] = { kind = "insert", text = b[i], b_line = i } end
        return r
    end
    if m == 0 then
        local r = {}
        for i = 1, n do r[i] = { kind = "delete", text = a[i], a_line = i } end
        return r
    end
    local max = n + m
    local v = {}  -- map from k -> furthest x reached on diagonal k
    -- Lua tables tolerate negative indices via string keys; we use plain
    -- numeric indices offset by max so the storage stays contiguous.
    local function vget(k)  return v[k + max] end
    local function vset(k, x) v[k + max] = x end
    local trace = {}
    vset(1, 0)
    local found_d
    for d = 0, max do
        -- snapshot current v[] so we can walk back later
        local snap = {}
        for k = -d, d do snap[k + max] = vget(k) end
        trace[d + 1] = snap
        for k = -d, d, 2 do
            local x
            if k == -d or (k ~= d and (vget(k - 1) or -1) < (vget(k + 1) or -1)) then
                x = vget(k + 1) or 0
            else
                x = (vget(k - 1) or 0) + 1
            end
            local y = x - k
            while x < n and y < m and a[x + 1] == b[y + 1] do
                x = x + 1; y = y + 1
            end
            vset(k, x)
            if x >= n and y >= m then
                found_d = d
                break
            end
        end
        if found_d ~= nil then break end
    end
    if found_d == nil then return {} end

    -- Backtrack to produce the edit script.
    local script = {}
    local x, y = n, m
    for d = found_d, 1, -1 do
        local snap = trace[d + 1]
        local k = x - y
        local prev_k
        if k == -d or (k ~= d and (snap[k - 1 + max] or -1) < (snap[k + 1 + max] or -1)) then
            prev_k = k + 1
        else
            prev_k = k - 1
        end
        local prev_x = snap[prev_k + max] or 0
        local prev_y = prev_x - prev_k
        while x > prev_x and y > prev_y do
            script[#script + 1] = { kind = "equal", text = a[x], a_line = x, b_line = y }
            x = x - 1; y = y - 1
        end
        if d > 0 then
            if x == prev_x then
                script[#script + 1] = { kind = "insert", text = b[y], b_line = y }
                y = y - 1
            else
                script[#script + 1] = { kind = "delete", text = a[x], a_line = x }
                x = x - 1
            end
        end
    end
    while x > 0 and y > 0 do
        script[#script + 1] = { kind = "equal", text = a[x], a_line = x, b_line = y }
        x = x - 1; y = y - 1
    end
    -- reverse to chronological order
    local rev = {}
    for i = #script, 1, -1 do rev[#rev + 1] = script[i] end
    return rev
end

-- ===== Public per-level helpers ========================================

function M.lines(a, b)
    return diff_tokens(split_lines(a), split_lines(b))
end

function M.words(a, b)
    return diff_tokens(split_words(a), split_words(b))
end

function M.chars(a, b)
    return diff_tokens(split_chars(a), split_chars(b))
end

-- ===== Unified diff text ===============================================

local function strip_newline(line)
    -- strip a single trailing \n or \r\n so we can re-prefix with +/-/' '
    if line:sub(-2) == "\r\n" then return line:sub(1, -3), "\r\n" end
    if line:sub(-1) == "\n"   then return line:sub(1, -2), "\n" end
    return line, ""
end

function M.unified(a, b, opts)
    opts = opts or {}
    local context  = opts.context  or 3
    local fromfile = opts.fromfile or "a"
    local tofile   = opts.tofile   or "b"
    local ops = M.lines(a, b)

    -- Group runs of operations into hunks separated by stretches of
    -- `equal` that exceed 2*context.
    local hunks = {}
    local i = 1
    local op_count = #ops
    while i <= op_count do
        -- Skip leading equals until we find a change (insert/delete).
        while i <= op_count and ops[i].kind == "equal" do i = i + 1 end
        if i > op_count then break end
        -- Walk back up to `context` equals for leading context.
        local hunk_start = i
        local pre = 0
        while hunk_start > 1 and pre < context and ops[hunk_start - 1].kind == "equal" do
            hunk_start = hunk_start - 1; pre = pre + 1
        end
        -- Find end: walk forward, including trailing context. We break
        -- whenever we see 2*context+1 equals in a row.
        local hunk_end = i
        while hunk_end <= op_count do
            if ops[hunk_end].kind ~= "equal" then
                hunk_end = hunk_end + 1
            else
                local run_start = hunk_end
                local run = 0
                while hunk_end <= op_count and ops[hunk_end].kind == "equal" do
                    run = run + 1; hunk_end = hunk_end + 1
                end
                if hunk_end > op_count or run > 2 * context then
                    hunk_end = run_start + math.min(run, context)
                    break
                end
            end
        end
        if hunk_end > op_count + 1 then hunk_end = op_count + 1 end
        hunks[#hunks + 1] = { hunk_start, hunk_end - 1 }
        i = hunk_end
    end

    if #hunks == 0 then return "" end

    local out = {}
    out[#out + 1] = "--- " .. fromfile
    out[#out + 1] = "+++ " .. tofile

    for _, h in ipairs(hunks) do
        local h_start, h_end = h[1], h[2]
        local a_start, a_count, b_start, b_count = 0, 0, 0, 0
        local first_a, first_b
        for k = h_start, h_end do
            local op = ops[k]
            if op.a_line and first_a == nil then first_a = op.a_line end
            if op.b_line and first_b == nil then first_b = op.b_line end
            if op.kind == "equal" then
                a_count = a_count + 1; b_count = b_count + 1
            elseif op.kind == "delete" then
                a_count = a_count + 1
            elseif op.kind == "insert" then
                b_count = b_count + 1
            end
        end
        a_start = first_a or 1
        b_start = first_b or 1
        out[#out + 1] = string.format("@@ -%d,%d +%d,%d @@",
            a_start, a_count, b_start, b_count)
        for k = h_start, h_end do
            local op = ops[k]
            local text, _ = strip_newline(op.text)
            local prefix = (op.kind == "equal" and " ")
                        or (op.kind == "delete" and "-")
                        or (op.kind == "insert" and "+")
            out[#out + 1] = prefix .. text
        end
    end
    return table.concat(out, "\n") .. "\n"
end

-- ===== Apply (structured edit script) =================================

function M.apply(orig, hunks)
    -- `hunks` here = an edit script produced by M.lines() (or any of the
    -- token-level diffs). Walks through emitting equals + inserts, skipping
    -- deletes. Caller is responsible for ensuring the script was produced
    -- against `orig` (we don't double-check line numbers).
    local out, np = {}, 0
    for _, op in ipairs(hunks) do
        if op.kind == "equal" or op.kind == "insert" then
            np = np + 1; out[np] = op.text
        end
    end
    -- If the caller passed in line-level ops the text already includes
    -- newlines; if they passed word/char ops we just concatenate.
    if hunks[1] and hunks[1].text:sub(-1) == "\n" then
        return table.concat(out)
    end
    -- For non-line ops, ignore `orig` and emit the rebuilt sequence.
    return table.concat(out)
end

-- ===== Apply unified-diff text ========================================

function M.patch(s, diff_text)
    local orig_lines = split_lines(s)
    local out, np = {}, 0
    local src_i = 1
    local i = 1
    local dlines = split_lines(diff_text)
    -- strip the trailing \n on each diff line for matching
    for k = 1, #dlines do
        if dlines[k]:sub(-1) == "\n" then dlines[k] = dlines[k]:sub(1, -2) end
        if dlines[k]:sub(-1) == "\r" then dlines[k] = dlines[k]:sub(1, -2) end
    end
    while i <= #dlines do
        local line = dlines[i]
        if line:sub(1, 3) == "---" or line:sub(1, 3) == "+++" then
            i = i + 1
        elseif line:sub(1, 2) == "@@" then
            -- @@ -a,b +c,d @@
            local a_start = line:match("@@ %-(%d+)")
            if a_start == nil then
                error("diff.patch: malformed hunk header: " .. line, 2)
            end
            a_start = tonumber(a_start)
            -- copy untouched source lines up to (and excluding) a_start
            while src_i < a_start do
                np = np + 1; out[np] = orig_lines[src_i]
                src_i = src_i + 1
            end
            i = i + 1
            -- consume hunk body
            while i <= #dlines do
                local hl = dlines[i]
                local p = hl:sub(1, 1)
                if p == "@" or p == "-" or p == "+" or p == " " then
                    if p == "@" then break end
                    if p == " " then
                        np = np + 1; out[np] = orig_lines[src_i]
                        src_i = src_i + 1
                    elseif p == "-" then
                        src_i = src_i + 1
                    elseif p == "+" then
                        np = np + 1; out[np] = hl:sub(2) .. "\n"
                    end
                    i = i + 1
                else
                    break
                end
            end
        else
            i = i + 1
        end
    end
    -- copy any remaining source lines
    while src_i <= #orig_lines do
        np = np + 1; out[np] = orig_lines[src_i]
        src_i = src_i + 1
    end
    -- The final inserted line may or may not have ended with \n in the
    -- original; we trust the caller's source unchanged.
    local joined = table.concat(out)
    -- The above appends \n to each + line but src copies preserve their
    -- own line terminators, so no further normalization is needed.
    return joined
end

-- ===== Three-way merge ================================================
-- Token-level merge: any token where ours and theirs diverged becomes
-- a conflict; matching changes stand.

function M.merge(base, ours, theirs)
    local base_lines   = split_lines(base)
    local ours_lines   = split_lines(ours)
    local theirs_lines = split_lines(theirs)
    local ours_ops   = diff_tokens(base_lines, ours_lines)
    local theirs_ops = diff_tokens(base_lines, theirs_lines)

    -- Build per-base-line edit summary: each base line maps to a "what
    -- ours did" + "what theirs did" pair. Walk both ops streams in
    -- lock-step indexed on a_line.
    local function build_map(ops)
        local map = {}     -- map[a_line] = { kept = bool, inserts_after = { text, ... } }
        local last_a = 0
        for _, op in ipairs(ops) do
            if op.kind == "equal" then
                last_a = op.a_line
                map[last_a] = map[last_a] or { kept = true, inserts = {} }
                map[last_a].kept = true
            elseif op.kind == "delete" then
                last_a = op.a_line
                map[last_a] = map[last_a] or { kept = false, inserts = {} }
                map[last_a].kept = false
            elseif op.kind == "insert" then
                map[last_a] = map[last_a] or { kept = true, inserts = {} }
                local ins = map[last_a].inserts
                ins[#ins + 1] = op.text
            end
        end
        return map
    end

    local m_ours   = build_map(ours_ops)
    local m_theirs = build_map(theirs_ops)

    local out, np = {}, 0
    local conflicts = {}
    -- handle inserts before the first base line (last_a = 0)
    local function emit_inserts(idx)
        local oi = (m_ours[idx]   or {}).inserts or {}
        local ti = (m_theirs[idx] or {}).inserts or {}
        if #oi == 0 and #ti == 0 then return end
        if #oi == 0 then
            for _, t in ipairs(ti) do np = np + 1; out[np] = t end
        elseif #ti == 0 then
            for _, t in ipairs(oi) do np = np + 1; out[np] = t end
        else
            local same = (#oi == #ti)
            if same then for k = 1, #oi do if oi[k] ~= ti[k] then same = false; break end end end
            if same then
                for _, t in ipairs(oi) do np = np + 1; out[np] = t end
            else
                np = np + 1; out[np] = "<<<<<<< ours\n"
                for _, t in ipairs(oi) do np = np + 1; out[np] = t end
                np = np + 1; out[np] = "=======\n"
                for _, t in ipairs(ti) do np = np + 1; out[np] = t end
                np = np + 1; out[np] = ">>>>>>> theirs\n"
                conflicts[#conflicts + 1] = { after_base_line = idx, ours = oi, theirs = ti }
            end
        end
    end

    emit_inserts(0)
    for i = 1, #base_lines do
        local o = m_ours[i]   or { kept = true, inserts = {} }
        local t = m_theirs[i] or { kept = true, inserts = {} }
        local ok, tk = o.kept, t.kept
        if ok and tk then
            np = np + 1; out[np] = base_lines[i]
        elseif (not ok) and (not tk) then
            -- both deleted; drop
        elseif ok and not tk then
            -- theirs deleted; honor deletion (silent)
        elseif (not ok) and tk then
            -- ours deleted; honor deletion (silent)
        end
        emit_inserts(i)
    end
    return { merged = table.concat(out), conflicts = conflicts }
end

-- ===== Legacy aliases ==================================================
-- Earlier callers used diff_lines / word_diff / char_diff / unified
-- with the older `ctx | add | del` kind labels; keep them working.

local _kind_legacy = { equal = "ctx", insert = "add", delete = "del" }
local function relabel(ops)
    local out = {}
    for i, op in ipairs(ops) do
        out[i] = {
            kind   = _kind_legacy[op.kind] or op.kind,
            text   = op.text,
            a_line = op.a_line,
            b_line = op.b_line,
        }
    end
    return out
end

function M.diff_lines(a, b) return relabel(M.lines(a, b)) end
function M.word_diff(a, b)  return relabel(M.words(a, b)) end
function M.char_diff(a, b)  return relabel(M.chars(a, b)) end

return M
