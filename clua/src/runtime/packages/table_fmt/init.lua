-- table_fmt -- ASCII / box / markdown / CSV / TSV table formatting.
--
-- Public surface:
--   table_fmt.format(rows, opts?) -> string
--   table_fmt.style(name)         -> style table (so callers can fork/customize)
--   table_fmt.styles              -- builtin style table
--
-- opts:
--   headers   = { ... }                 column titles, optional
--   style     = "ascii"|"box"|"markdown"|"github"|"csv"|"tsv"|"plain"
--   align     = { "left"|"right"|"center", ... }  per column
--   max_width = number                  cap on per-cell display width
--   truncate  = true | false | string   true = "...", string = custom ellipsis
--   pad       = number (default 1)      cells get this many spaces on each side
--   wrap      = bool                    soft-wrap cells instead of truncating
--
-- Rows may be:
--   array-of-arrays   {{"a","b"}, {"c","d"}}
--   array-of-maps     {{name="a", age=1}, ...}  -- headers determine column order
--   array-of-strings  treats each as a single-column row

local M = {}

-- Per-style glyph table. The blanks for some styles (csv/tsv) are sentinels
-- pulled into the printers below as "skip this rule".
M.styles = {
    ascii = {
        h="-", v="|", tl="+", tr="+", bl="+", br="+",
        tm="+", bm="+", lm="+", rm="+", cm="+",
        rule = true,
    },
    box = {
        h="\u{2500}", v="\u{2502}",
        tl="\u{250c}", tr="\u{2510}", bl="\u{2514}", br="\u{2518}",
        tm="\u{252c}", bm="\u{2534}", lm="\u{251c}", rm="\u{2524}", cm="\u{253c}",
        rule = true,
    },
    markdown = {
        -- Plain pipes; markdown renderer aligns colon-cues in the header sep.
        h="-", v="|",
        rule = "md",
    },
    github = {
        h="-", v="|",
        rule = "md",
    },
    plain = {
        h="", v="  ",
        rule = false,
    },
    csv = { rule = "csv" },
    tsv = { rule = "tsv" },
}

function M.style(name)
    return M.styles[name] or M.styles.ascii
end

-- ===== Row normalization ============================================

-- Coerce arbitrary input shape into rows-of-strings + final headers.
local function normalize(rows, opts)
    local headers = opts.headers
    if #rows == 0 then return {}, headers or {} end

    -- Detect shape from first row.
    local first = rows[1]
    if type(first) == "string" or type(first) == "number" or type(first) == "boolean" then
        local out = {}
        for i, r in ipairs(rows) do out[i] = { tostring(r) } end
        return out, headers or { "value" }
    elseif type(first) == "table" then
        -- Array (positional) vs map (keyed)?
        local is_array = (#first > 0) or (next(first) == nil)
        if is_array then
            local out = {}
            for i, r in ipairs(rows) do
                local cells = {}
                for j, v in ipairs(r) do cells[j] = (v == nil) and "" or tostring(v) end
                out[i] = cells
            end
            -- If no explicit headers, leave them empty (or skip the header
            -- band entirely if the caller passed nothing).
            return out, headers
        else
            -- Map rows. Determine column order: explicit headers, else keys
            -- from the first row in their iteration order (deterministic via
            -- sorted keys for reproducibility).
            local cols = headers
            if not cols then
                cols = {}
                for k in pairs(first) do cols[#cols+1] = k end
                table.sort(cols)
            end
            local out = {}
            for i, r in ipairs(rows) do
                local cells = {}
                for j, k in ipairs(cols) do
                    cells[j] = r[k] == nil and "" or tostring(r[k])
                end
                out[i] = cells
            end
            return out, cols
        end
    end
    error("table_fmt: unsupported row type " .. type(first))
end

-- ===== Width / wrapping =============================================

local function strip_ansi(s)
    local ok, c = pcall(require, "color")
    if ok then return c.strip(s) end
    return (s:gsub(string.char(27) .. "%[[%d;]*[%a]", ""))
end

local function disp_width(s)
    return #strip_ansi(s)
end

local function pad_to(s, w, align)
    local sw = disp_width(s)
    if sw >= w then return s end
    local diff = w - sw
    if align == "right" then
        return string.rep(" ", diff) .. s
    elseif align == "center" then
        local l = math.floor(diff / 2)
        local r = diff - l
        return string.rep(" ", l) .. s .. string.rep(" ", r)
    end
    return s .. string.rep(" ", diff)
end

local function truncate_cell(s, w, ell)
    if disp_width(s) <= w then return s end
    -- Naive on bytes -- safe for ASCII + escape-stripped paths. For UTF-8
    -- columns the caller should pre-format or strip.
    local plain = strip_ansi(s)
    if w <= #ell then return plain:sub(1, w) end
    return plain:sub(1, w - #ell) .. ell
end

local function wrap_cell(s, w)
    -- Soft-wrap on spaces, falling back to hard splits.
    local lines = {}
    for paragraph in s:gmatch("([^\n]*)\n?") do
        if paragraph == "" then
            if #lines == 0 or lines[#lines] ~= "" then lines[#lines+1] = "" end
        else
            local cur = ""
            for word in paragraph:gmatch("%S+") do
                if cur == "" then
                    cur = word
                elseif disp_width(cur) + 1 + disp_width(word) <= w then
                    cur = cur .. " " .. word
                else
                    lines[#lines+1] = cur
                    cur = word
                end
                while disp_width(cur) > w do
                    -- single long word; hard split
                    lines[#lines+1] = cur:sub(1, w)
                    cur = cur:sub(w + 1)
                end
            end
            if cur ~= "" then lines[#lines+1] = cur end
        end
    end
    if #lines == 0 then lines[1] = "" end
    return lines
end

-- ===== Render core ==================================================

local function compute_widths(rows, headers)
    local n = 0
    if headers then for i in ipairs(headers) do if i > n then n = i end end end
    for _, r in ipairs(rows) do
        for i in ipairs(r) do if i > n then n = i end end
    end
    local w = {}
    for i = 1, n do w[i] = 0 end
    if headers then
        for i, h in ipairs(headers) do
            local d = disp_width(tostring(h))
            if d > w[i] then w[i] = d end
        end
    end
    for _, r in ipairs(rows) do
        for i, c in ipairs(r) do
            local d = disp_width(c)
            if d > w[i] then w[i] = d end
        end
    end
    return w
end

local function build_rule(widths, style, kind, pad)
    -- kind is "top" | "mid" | "bottom".
    if not style.rule or style.rule == "md" or style.rule == "csv" or style.rule == "tsv" then
        return nil
    end
    local L, M_, R
    if kind == "top" then    L, M_, R = style.tl, style.tm, style.tr
    elseif kind == "bot" then L, M_, R = style.bl, style.bm, style.br
    else                     L, M_, R = style.lm, style.cm, style.rm end
    local parts = { L }
    for i, w in ipairs(widths) do
        parts[#parts+1] = string.rep(style.h, w + pad * 2)
        parts[#parts+1] = (i < #widths) and M_ or R
    end
    return table.concat(parts)
end

local function render_row(cells, widths, style, aligns, pad)
    if style.rule == "csv" then
        local out = {}
        for i, c in ipairs(cells) do
            local s = c
            if s:find("[,\"\n\r]") then
                s = '"' .. s:gsub('"', '""') .. '"'
            end
            out[i] = s
        end
        return table.concat(out, ",")
    elseif style.rule == "tsv" then
        local out = {}
        for i, c in ipairs(cells) do
            out[i] = c:gsub("\t", " "):gsub("\n", " ")
        end
        return table.concat(out, "\t")
    end
    local v = style.v or ""
    local p = string.rep(" ", pad)
    local parts = { v }
    for i, w in ipairs(widths) do
        local cell = cells[i] or ""
        parts[#parts+1] = p .. pad_to(cell, w, aligns and aligns[i] or "left") .. p
        parts[#parts+1] = v
    end
    return table.concat(parts)
end

function M.format(rows, opts)
    opts = opts or {}
    local style_name = opts.style or "ascii"
    local style = M.styles[style_name] or M.styles.ascii
    local pad = opts.pad or 1
    local aligns = opts.align or {}

    local normalized, headers = normalize(rows, opts)

    -- Truncate / wrap before computing widths so the column widths reflect
    -- the final display content.
    local ell = (opts.truncate == true and "...") or (type(opts.truncate) == "string" and opts.truncate) or nil
    if opts.max_width and ell and not opts.wrap then
        local mw = opts.max_width
        for _, r in ipairs(normalized) do
            for i, c in ipairs(r) do r[i] = truncate_cell(c, mw, ell) end
        end
        if headers then
            for i, h in ipairs(headers) do headers[i] = truncate_cell(tostring(h), mw, ell) end
        end
    end

    if opts.max_width and opts.wrap then
        -- Expand each row of cells into possibly-many display rows.
        local mw = opts.max_width
        local expanded = {}
        for _, r in ipairs(normalized) do
            local wrapped, max_lines = {}, 1
            for i, c in ipairs(r) do
                local lines = wrap_cell(c, mw)
                wrapped[i] = lines
                if #lines > max_lines then max_lines = #lines end
            end
            for li = 1, max_lines do
                local row = {}
                for i, lines in ipairs(wrapped) do row[i] = lines[li] or "" end
                expanded[#expanded+1] = row
            end
        end
        normalized = expanded
    end

    local widths = compute_widths(normalized, headers)
    local out = {}

    if style.rule == "csv" or style.rule == "tsv" then
        if headers then
            out[#out+1] = render_row(headers, widths, style, aligns, pad)
        end
        for _, r in ipairs(normalized) do
            out[#out+1] = render_row(r, widths, style, aligns, pad)
        end
        return table.concat(out, "\n")
    end

    if style.rule == "md" then
        if not headers then
            -- Fabricate empty headers so the markdown structure is valid.
            headers = {}
            for i = 1, #widths do headers[i] = "" end
        end
        out[#out+1] = render_row(headers, widths, style, aligns, pad)
        -- Separator line with colon cues for alignment.
        local sep = { "|" }
        for i, w in ipairs(widths) do
            local seg = string.rep("-", w + pad * 2)
            local a = aligns[i]
            if a == "right" then seg = seg:sub(1, -2) .. ":"
            elseif a == "center" then seg = ":" .. seg:sub(2, -2) .. ":"
            elseif a == "left" then seg = ":" .. seg:sub(2) end
            sep[#sep+1] = seg
            sep[#sep+1] = "|"
        end
        out[#out+1] = table.concat(sep)
        for _, r in ipairs(normalized) do
            out[#out+1] = render_row(r, widths, style, aligns, pad)
        end
        return table.concat(out, "\n")
    end

    local top = build_rule(widths, style, "top", pad)
    local mid = build_rule(widths, style, "mid", pad)
    local bot = build_rule(widths, style, "bot", pad)
    if top then out[#out+1] = top end
    if headers then
        out[#out+1] = render_row(headers, widths, style, aligns, pad)
        if mid then out[#out+1] = mid end
    end
    for _, r in ipairs(normalized) do
        out[#out+1] = render_row(r, widths, style, aligns, pad)
    end
    if bot then out[#out+1] = bot end
    return table.concat(out, "\n")
end

return M
