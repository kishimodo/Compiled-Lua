-- string_extra -- Algorithms over strings.
--
-- Surface:
--   levenshtein(a, b)           -- classic edit distance (ins/del/sub)
--   damerau_levenshtein(a, b)   -- + transposition
--   hamming(a, b)               -- errors when #a ~= #b
--   jaro(a, b)                  -- 0..1 similarity
--   jaro_winkler(a, b, p?)      -- jaro + common-prefix bonus
--   soundex(s)                  -- 4-char American Soundex code
--   metaphone(s)                -- classic Lawrence Philips Metaphone
--   double_metaphone(s)         -> primary, alternate
--   cosine_similarity(a, b, n?) -- character n-gram cosine, default n=2
--   fuzzy_match(query, target)  -> matched_bool, score
--   tokenize(s, opts?)          -> { token, token, ... }
--   ngrams(s, n)                -> { ngram, ngram, ... }
--   longest_common_substring(a, b)   -> string, len, ai, bi
--   longest_common_subsequence(a, b) -> string
--
-- All numeric inputs are byte-oriented; pre-normalize Unicode if needed.

local M = {}

-- ===== Edit distances ==================================================

function M.levenshtein(a, b)
    if a == b then return 0 end
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    -- two rolling rows; cheaper than the full matrix
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local ai = a:byte(i)
        for j = 1, lb do
            local cost = (ai == b:byte(j)) and 0 or 1
            local del = prev[j]     + 1
            local ins = cur[j - 1]  + 1
            local sub = prev[j - 1] + cost
            local m = del < ins and del or ins
            if sub < m then m = sub end
            cur[j] = m
        end
        prev, cur = cur, prev
    end
    return prev[lb]
end

function M.damerau_levenshtein(a, b)
    -- Optimal string alignment (restricted Damerau): single-pass DP that
    -- allows transposing adjacent characters at unit cost. Cheaper to
    -- implement than full Damerau and good enough for typo detection.
    if a == b then return 0 end
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    -- Full matrix; we need d[i-2][j-2] for the transpose case.
    local d = {}
    for i = 0, la do d[i] = { [0] = i } end
    for j = 0, lb do d[0][j] = j end
    for i = 1, la do
        local ai = a:byte(i)
        for j = 1, lb do
            local bj = b:byte(j)
            local cost = (ai == bj) and 0 or 1
            local del = d[i - 1][j] + 1
            local ins = d[i][j - 1] + 1
            local sub = d[i - 1][j - 1] + cost
            local m = del < ins and del or ins
            if sub < m then m = sub end
            if i > 1 and j > 1 and ai == b:byte(j - 1) and a:byte(i - 1) == bj then
                local tr = d[i - 2][j - 2] + 1
                if tr < m then m = tr end
            end
            d[i][j] = m
        end
    end
    return d[la][lb]
end

function M.hamming(a, b)
    if #a ~= #b then
        error("string_extra.hamming: inputs differ in length", 2)
    end
    local n = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then n = n + 1 end
    end
    return n
end

-- ===== Jaro / Jaro-Winkler =============================================

function M.jaro(a, b)
    if a == b then return 1.0 end
    local la, lb = #a, #b
    if la == 0 or lb == 0 then return 0.0 end
    local search_range = (math.max(la, lb) // 2) - 1
    if search_range < 0 then search_range = 0 end
    local a_match = {}
    local b_match = {}
    local matches = 0
    for i = 1, la do
        local lo = math.max(1, i - search_range)
        local hi = math.min(lb, i + search_range)
        for j = lo, hi do
            if not b_match[j] and a:byte(i) == b:byte(j) then
                a_match[i] = true
                b_match[j] = true
                matches = matches + 1
                break
            end
        end
    end
    if matches == 0 then return 0.0 end
    -- count transpositions (half the count of matched but out-of-order pairs)
    local trans = 0
    local k = 1
    for i = 1, la do
        if a_match[i] then
            while not b_match[k] do k = k + 1 end
            if a:byte(i) ~= b:byte(k) then trans = trans + 1 end
            k = k + 1
        end
    end
    trans = trans / 2
    return (matches / la + matches / lb + (matches - trans) / matches) / 3
end

function M.jaro_winkler(a, b, p)
    p = p or 0.1
    local j = M.jaro(a, b)
    -- common prefix up to 4 chars
    local l = 0
    local max_l = math.min(4, #a, #b)
    while l < max_l and a:byte(l + 1) == b:byte(l + 1) do
        l = l + 1
    end
    return j + l * p * (1 - j)
end

-- ===== Phonetic algorithms =============================================

local _soundex_map = {
    [66]=1,[70]=1,[80]=1,[86]=1,                              -- BFPV
    [67]=2,[71]=2,[74]=2,[75]=2,[81]=2,[83]=2,[88]=2,[90]=2,  -- CGJKQSXZ
    [68]=3,[84]=3,                                            -- DT
    [76]=4,                                                   -- L
    [77]=5,[78]=5,                                            -- MN
    [82]=6,                                                   -- R
}

function M.soundex(s)
    if s == nil or #s == 0 then return "0000" end
    local up = s:upper()
    local first = up:byte(1)
    if first < 65 or first > 90 then return "0000" end
    -- Bind string.char(...) to a local so we don't emit OP_SETLIST(B=0).
    local first_ch = string.char(first)
    local out = { first_ch }
    local prev_code = _soundex_map[first] or 0
    for i = 2, #up do
        local b = up:byte(i)
        if b >= 65 and b <= 90 then
            local code = _soundex_map[b] or 0
            if code ~= 0 and code ~= prev_code then
                out[#out + 1] = tostring(code)
                if #out == 4 then break end
            end
            -- H and W don't reset prev_code (Soundex rule)
            if b ~= 72 and b ~= 87 then prev_code = code end
        end
    end
    while #out < 4 do out[#out + 1] = "0" end
    return table.concat(out)
end

-- Classic Lawrence Philips metaphone. The algorithm walks the string
-- left-to-right, peeking at neighbours to pick the right phoneme.
local function _is_vowel_byte(b)
    return b == 65 or b == 69 or b == 73 or b == 79 or b == 85
end

function M.metaphone(s)
    if s == nil or #s == 0 then return "" end
    local up = s:upper():gsub("[^A-Z]", "")
    if #up == 0 then return "" end
    local n = #up
    local i = 1
    local out = {}

    -- initial dropping rules
    local pair = up:sub(1, 2)
    if pair == "AE" or pair == "GN" or pair == "KN" or pair == "PN" or pair == "WR" then
        i = 2
    elseif up:sub(1, 1) == "X" then
        out[#out + 1] = "S"; i = 2
    end

    local function at(k) return up:sub(k, k) end
    local function ch(k) return up:byte(k) end

    while i <= n do
        local c = at(i)
        local next_c = i < n and at(i + 1) or ""
        if c == next_c and c ~= "C" then
            -- collapse runs of duplicates (except CC which has its own rule)
            i = i + 1
        elseif c == "A" or c == "E" or c == "I" or c == "O" or c == "U" then
            if i == 1 then out[#out + 1] = c end
            i = i + 1
        elseif c == "B" then
            out[#out + 1] = "B"
            -- silent B at end after M (e.g. DUMB)
            if i == n and i > 1 and at(i - 1) == "M" then out[#out] = nil end
            i = i + 1
        elseif c == "C" then
            if next_c == "I" and i + 2 <= n and at(i + 2) == "A" then
                out[#out + 1] = "X"
            elseif next_c == "H" then
                out[#out + 1] = "X"; i = i + 1
            elseif next_c == "I" or next_c == "E" or next_c == "Y" then
                out[#out + 1] = "S"
            else
                out[#out + 1] = "K"
            end
            i = i + 1
        elseif c == "D" then
            if next_c == "G" and i + 2 <= n and (at(i + 2) == "E" or at(i + 2) == "I" or at(i + 2) == "Y") then
                out[#out + 1] = "J"; i = i + 2
            else
                out[#out + 1] = "T"; i = i + 1
            end
        elseif c == "F" then
            out[#out + 1] = "F"; i = i + 1
        elseif c == "G" then
            if next_c == "H" then
                -- silent GH unless at start
                if i == 1 then out[#out + 1] = "K" end
                i = i + 2
            elseif next_c == "N" then
                out[#out + 1] = "N"; i = i + 2
            elseif next_c == "E" or next_c == "I" or next_c == "Y" then
                out[#out + 1] = "J"; i = i + 1
            else
                out[#out + 1] = "K"; i = i + 1
            end
        elseif c == "H" then
            if i > 1 and _is_vowel_byte(ch(i - 1)) and (i == n or not _is_vowel_byte(ch(i + 1))) then
                -- silent
            else
                out[#out + 1] = "H"
            end
            i = i + 1
        elseif c == "J" then
            out[#out + 1] = "J"; i = i + 1
        elseif c == "K" then
            if i == 1 or at(i - 1) ~= "C" then out[#out + 1] = "K" end
            i = i + 1
        elseif c == "L" then
            out[#out + 1] = "L"; i = i + 1
        elseif c == "M" then
            out[#out + 1] = "M"; i = i + 1
        elseif c == "N" then
            out[#out + 1] = "N"; i = i + 1
        elseif c == "P" then
            if next_c == "H" then out[#out + 1] = "F"; i = i + 2
            else out[#out + 1] = "P"; i = i + 1 end
        elseif c == "Q" then
            out[#out + 1] = "K"; i = i + 1
        elseif c == "R" then
            out[#out + 1] = "R"; i = i + 1
        elseif c == "S" then
            if next_c == "H" then out[#out + 1] = "X"; i = i + 2
            elseif next_c == "I" and i + 2 <= n and (at(i + 2) == "O" or at(i + 2) == "A") then
                out[#out + 1] = "X"; i = i + 1
            else
                out[#out + 1] = "S"; i = i + 1
            end
        elseif c == "T" then
            if next_c == "H" then out[#out + 1] = "0"; i = i + 2
            elseif next_c == "I" and i + 2 <= n and (at(i + 2) == "O" or at(i + 2) == "A") then
                out[#out + 1] = "X"; i = i + 1
            else
                out[#out + 1] = "T"; i = i + 1
            end
        elseif c == "V" then
            out[#out + 1] = "F"; i = i + 1
        elseif c == "W" or c == "Y" then
            if i < n and _is_vowel_byte(ch(i + 1)) then out[#out + 1] = c end
            i = i + 1
        elseif c == "X" then
            out[#out + 1] = "KS"; i = i + 1
        elseif c == "Z" then
            out[#out + 1] = "S"; i = i + 1
        else
            i = i + 1
        end
    end
    return table.concat(out)
end

function M.double_metaphone(s)
    -- A simplified double metaphone: we return the classic metaphone as the
    -- primary code and a slightly perturbed code (germanic / latinate
    -- pronunciation of c/g/j) as the alternate. Pure double-metaphone is
    -- ~600 LoC of branch tables which is overkill for this package; the
    -- variant we emit is enough to power "either pronunciation" matching.
    local primary = M.metaphone(s)
    if s == nil or #s == 0 then return primary, primary end
    -- For the alternate, force C/G/J/X to harder phonemes (germanic-style).
    local alt = M.metaphone(s
        :gsub("[Jj]", "Y")        -- J -> Y (latinate)
        :gsub("[Xx]", "S"))       -- X -> S
    return primary, alt
end

-- ===== Cosine similarity over character n-grams =======================

local function ngram_counts(s, n)
    local t = {}
    if #s < n then return t, 0 end
    local total = 0
    for i = 1, #s - n + 1 do
        local g = s:sub(i, i + n - 1)
        t[g] = (t[g] or 0) + 1
        total = total + 1
    end
    return t, total
end

function M.cosine_similarity(a, b, n)
    n = n or 2
    local ca = ngram_counts(a, n)
    local cb = ngram_counts(b, n)
    local dot, mag_a, mag_b = 0, 0, 0
    for g, va in pairs(ca) do
        mag_a = mag_a + va * va
        local vb = cb[g]
        if vb then dot = dot + va * vb end
    end
    for _, vb in pairs(cb) do mag_b = mag_b + vb * vb end
    if mag_a == 0 or mag_b == 0 then return 0.0 end
    return dot / (math.sqrt(mag_a) * math.sqrt(mag_b))
end

-- ===== Fuzzy subsequence match with bonus =============================

function M.fuzzy_match(query, target)
    if query == nil or query == "" then return true, 0 end
    if target == nil or target == "" then return false, 0 end
    local q  = query:lower()
    local t  = target:lower()
    local qi = 1
    local last_matched = 0
    local score = 0
    local prev_was_separator = true   -- start of string acts as a separator
    for ti = 1, #t do
        if qi > #q then break end
        if q:byte(qi) == t:byte(ti) then
            -- consecutive matches earn a bonus
            if ti == last_matched + 1 then score = score + 5 end
            -- start-of-word matches earn a bonus
            if prev_was_separator then score = score + 8 end
            -- case-match bonus over the lowercased compare
            if query:byte(qi) == target:byte(ti) then score = score + 2 end
            score = score + 1
            last_matched = ti
            qi = qi + 1
        else
            -- small leading-distance penalty so close matches outrank scattered ones
            score = score - 1
        end
        local cb = target:byte(ti)
        prev_was_separator = (cb == 32 or cb == 95 or cb == 45 or cb == 46 or cb == 47)
    end
    if qi <= #q then return false, 0 end
    return true, score
end

-- ===== Tokenize / ngrams ===============================================

local DEFAULT_STOPWORDS = {
    a=true, an=true, the=true, and_=true, or_=true, but=true, if_=true,
    of=true, to=true, in_=true, on=true, at=true, by=true, for_=true,
    is=true, it=true, this=true, that=true, with=true, as=true, be=true,
    are=true, was=true, were=true,
}
-- Trailing-underscore keys are workarounds because Lua treats `or`, `if`,
-- `for`, `in` as reserved words. We rewrite them below.
local _stop = {}
for k, v in pairs(DEFAULT_STOPWORDS) do
    local clean = k:gsub("_$", "")
    _stop[clean] = v
end

function M.tokenize(s, opts)
    opts = opts or {}
    local lowercase = opts.lowercase ~= false
    local remove_stopwords = opts.stopwords
    local stop = opts.stopword_set or _stop
    local out = {}
    local np = 0
    -- split on runs of non-letter, non-digit bytes (ASCII view; callers
    -- that need Unicode segmentation should pre-tokenize)
    for tok in s:gmatch("[%w']+") do
        local t = lowercase and tok:lower() or tok
        if not (remove_stopwords and stop[t]) then
            np = np + 1; out[np] = t
        end
    end
    return out
end

function M.ngrams(s, n)
    local out = {}
    if #s < n then return out end
    local np = 0
    for i = 1, #s - n + 1 do
        np = np + 1; out[np] = s:sub(i, i + n - 1)
    end
    return out
end

-- ===== LCS / LCSubstring ==============================================

function M.longest_common_substring(a, b)
    local la, lb = #a, #b
    if la == 0 or lb == 0 then return "", 0, 0, 0 end
    -- Two-row DP. Track best (len, end-index in a).
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = 0 end
    local best_len = 0
    local best_end_a = 0
    local best_end_b = 0
    for i = 1, la do
        cur[0] = 0
        local ai = a:byte(i)
        for j = 1, lb do
            if ai == b:byte(j) then
                local v = prev[j - 1] + 1
                cur[j] = v
                if v > best_len then
                    best_len = v
                    best_end_a = i
                    best_end_b = j
                end
            else
                cur[j] = 0
            end
        end
        prev, cur = cur, prev
    end
    if best_len == 0 then return "", 0, 0, 0 end
    local start_a = best_end_a - best_len + 1
    return a:sub(start_a, best_end_a), best_len, start_a, best_end_b - best_len + 1
end

function M.longest_common_subsequence(a, b)
    local la, lb = #a, #b
    if la == 0 or lb == 0 then return "" end
    -- Full DP table; we walk it backwards to reconstruct the LCS string.
    local d = {}
    for i = 0, la do d[i] = {} ; d[i][0] = 0 end
    for j = 0, lb do d[0][j] = 0 end
    for i = 1, la do
        local ai = a:byte(i)
        for j = 1, lb do
            if ai == b:byte(j) then
                d[i][j] = d[i - 1][j - 1] + 1
            else
                local u, l = d[i - 1][j], d[i][j - 1]
                d[i][j] = u > l and u or l
            end
        end
    end
    local i, j = la, lb
    local rev, rn = {}, 0
    while i > 0 and j > 0 do
        if a:byte(i) == b:byte(j) then
            rn = rn + 1; rev[rn] = a:sub(i, i)
            i = i - 1; j = j - 1
        elseif d[i - 1][j] >= d[i][j - 1] then
            i = i - 1
        else
            j = j - 1
        end
    end
    -- reverse rev[]
    local out, on = {}, 0
    for k = rn, 1, -1 do on = on + 1; out[on] = rev[k] end
    return table.concat(out)
end

-- ===== Spec-compatible aliases ========================================
-- The user spec uses shorter names; we expose them as wrappers around
-- the more descriptive implementations above so both styles work.

M.damerau = M.damerau_levenshtein

-- ===== Whitespace + layout =============================================

function M.ltrim(s)
    return (s:gsub("^[%s]+", ""))
end

function M.rtrim(s)
    return (s:gsub("[%s]+$", ""))
end

function M.trim(s)
    return (s:gsub("^[%s]+", ""):gsub("[%s]+$", ""))
end

function M.pad_left(s, n, ch)
    ch = ch or " "
    if #s >= n then return s end
    return ch:rep(n - #s) .. s
end

function M.pad_right(s, n, ch)
    ch = ch or " "
    if #s >= n then return s end
    return s .. ch:rep(n - #s)
end

function M.center(s, n, ch)
    ch = ch or " "
    if #s >= n then return s end
    local pad = n - #s
    local left = pad // 2
    local right = pad - left
    return ch:rep(left) .. s .. ch:rep(right)
end

function M.splitlines(s)
    -- Splits on \r\n, \r, or \n. Drops the terminators from each line.
    local out, np = {}, 0
    local i = 1
    local len = #s
    local start = 1
    while i <= len do
        local b = s:byte(i)
        if b == 13 or b == 10 then
            np = np + 1; out[np] = s:sub(start, i - 1)
            -- consume \r\n as a single break
            if b == 13 and s:byte(i + 1) == 10 then i = i + 2 else i = i + 1 end
            start = i
        else
            i = i + 1
        end
    end
    if start <= len then
        np = np + 1; out[np] = s:sub(start)
    end
    return out
end

function M.wordwrap(s, width)
    if width == nil or width < 1 then width = 80 end
    local out_lines = {}
    for _, raw_line in ipairs(M.splitlines(s)) do
        local words = {}
        for w in raw_line:gmatch("%S+") do words[#words + 1] = w end
        if #words == 0 then
            out_lines[#out_lines + 1] = ""
        else
            local cur = words[1]
            for i = 2, #words do
                local w = words[i]
                if #cur + 1 + #w <= width then
                    cur = cur .. " " .. w
                else
                    out_lines[#out_lines + 1] = cur
                    cur = w
                end
            end
            out_lines[#out_lines + 1] = cur
        end
    end
    return table.concat(out_lines, "\n")
end

function M.dedent(s)
    -- Remove the common leading whitespace from every non-empty line.
    local lines = M.splitlines(s)
    local min_indent
    for _, line in ipairs(lines) do
        if line:match("%S") then
            local indent = #line:match("^%s*")
            if min_indent == nil or indent < min_indent then
                min_indent = indent
            end
        end
    end
    if min_indent == nil or min_indent == 0 then return s end
    for i, line in ipairs(lines) do
        if line:match("%S") then lines[i] = line:sub(min_indent + 1) end
    end
    -- Preserve a trailing newline if the original ended on one.
    local tail = (s:sub(-1) == "\n") and "\n" or ""
    return table.concat(lines, "\n") .. tail
end

function M.indent(s, prefix)
    prefix = prefix or "    "
    local lines = M.splitlines(s)
    for i, line in ipairs(lines) do lines[i] = prefix .. line end
    local tail = (s:sub(-1) == "\n") and "\n" or ""
    return table.concat(lines, "\n") .. tail
end

-- words(s) -> iterator yielding successive whitespace-separated words.
function M.words(s)
    return s:gmatch("%S+")
end

function M.capitalize(s)
    if s == nil or s == "" then return s end
    return s:sub(1, 1):upper() .. s:sub(2):lower()
end

function M.count_substring(s, sub)
    if sub == nil or sub == "" then return 0 end
    local n = 0
    local i = 1
    while true do
        local p = s:find(sub, i, true)
        if p == nil then return n end
        n = n + 1
        i = p + #sub
    end
end

-- replace_all(s, from, to) -- plain-text replace (no Lua-pattern magic).
function M.replace_all(s, from, to)
    if from == nil or from == "" then return s end
    local out, np = {}, 0
    local i = 1
    while true do
        local p = s:find(from, i, true)
        if p == nil then
            np = np + 1; out[np] = s:sub(i)
            break
        end
        if p > i then np = np + 1; out[np] = s:sub(i, p - 1) end
        np = np + 1; out[np] = to
        i = p + #from
    end
    return table.concat(out)
end

-- ===== Fuzzy_match against a list ======================================
-- Spec-form: fuzzy_match(needle, candidates, opts?) -> sorted results.
-- The earlier two-arg form `fuzzy_match(query, target)` is also kept; we
-- distinguish based on whether the second arg is a table.

local _fuzzy_one = M.fuzzy_match

function M.fuzzy_match(needle, target_or_candidates, opts)
    if type(target_or_candidates) == "string" then
        return _fuzzy_one(needle, target_or_candidates)
    end
    opts = opts or {}
    local min_score = opts.min_score or 1
    local limit     = opts.limit
    local results = {}
    for _, cand in ipairs(target_or_candidates) do
        local ok, score = _fuzzy_one(needle, cand)
        if ok and score >= min_score then
            results[#results + 1] = { candidate = cand, score = score }
        end
    end
    table.sort(results, function(a, b) return a.score > b.score end)
    if limit and #results > limit then
        for i = limit + 1, #results do results[i] = nil end
    end
    return results
end

return M
