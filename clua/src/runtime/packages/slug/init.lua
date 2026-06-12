-- slug -- URL-safe slug builder.
--
-- Public surface:
--   slug.slugify(s, opts?)        -- ASCII-only, transliterates Latin-Ext
--   slug.unicode_slug(s, opts?)   -- keeps non-Latin scripts intact
--
-- opts:
--   separator      (default "-")
--   lowercase      (default true)
--   max_length     (default 80)
--   transliterate  (default true) -- Latin-Ext -> ASCII via table
--
-- The transliteration table covers the Latin-1 Supplement, Latin Extended-A
-- and -B, common Romanian / Polish / Vietnamese / Croatian / Czech
-- characters. It does *not* try to romanize CJK or Cyrillic -- callers who
-- need that should use unicode_slug() or a dedicated romanizer.

local M = {}

-- ===== Transliteration table ============================================
-- Keys are UTF-8 byte sequences; values are ASCII replacements. We use
-- raw UTF-8 in the source to keep the table compact. Add common
-- decorated forms; the slug pipeline strips anything it can't translate.

local TRANSLIT = {
    -- A
    ["À"]="A",["Á"]="A",["Â"]="A",["Ã"]="A",["Ä"]="A",["Å"]="A",["Ā"]="A",["Ă"]="A",["Ą"]="A",["Ǎ"]="A",
    ["à"]="a",["á"]="a",["â"]="a",["ã"]="a",["ä"]="a",["å"]="a",["ā"]="a",["ă"]="a",["ą"]="a",["ǎ"]="a",
    ["Æ"]="AE",["æ"]="ae",
    -- B/C
    ["Ç"]="C",["Ć"]="C",["Č"]="C",["Ĉ"]="C",["Ċ"]="C",
    ["ç"]="c",["ć"]="c",["č"]="c",["ĉ"]="c",["ċ"]="c",
    -- D
    ["Ð"]="D",["Ď"]="D",["Đ"]="D",
    ["ð"]="d",["ď"]="d",["đ"]="d",
    -- E
    ["È"]="E",["É"]="E",["Ê"]="E",["Ë"]="E",["Ē"]="E",["Ĕ"]="E",["Ė"]="E",["Ę"]="E",["Ě"]="E",
    ["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",["ē"]="e",["ĕ"]="e",["ė"]="e",["ę"]="e",["ě"]="e",
    -- G
    ["Ĝ"]="G",["Ğ"]="G",["Ġ"]="G",["Ģ"]="G",
    ["ĝ"]="g",["ğ"]="g",["ġ"]="g",["ģ"]="g",
    -- H
    ["Ĥ"]="H",["Ħ"]="H",
    ["ĥ"]="h",["ħ"]="h",
    -- I
    ["Ì"]="I",["Í"]="I",["Î"]="I",["Ï"]="I",["Ĩ"]="I",["Ī"]="I",["Ĭ"]="I",["Į"]="I",["İ"]="I",
    ["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",["ĩ"]="i",["ī"]="i",["ĭ"]="i",["į"]="i",["ı"]="i",
    -- J/K
    ["Ĵ"]="J",["ĵ"]="j",
    ["Ķ"]="K",["ķ"]="k",
    -- L
    ["Ĺ"]="L",["Ļ"]="L",["Ľ"]="L",["Ł"]="L",
    ["ĺ"]="l",["ļ"]="l",["ľ"]="l",["ł"]="l",
    -- N
    ["Ñ"]="N",["Ń"]="N",["Ņ"]="N",["Ň"]="N",
    ["ñ"]="n",["ń"]="n",["ņ"]="n",["ň"]="n",
    -- O
    ["Ò"]="O",["Ó"]="O",["Ô"]="O",["Õ"]="O",["Ö"]="O",["Ø"]="O",["Ō"]="O",["Ŏ"]="O",["Ő"]="O",
    ["ò"]="o",["ó"]="o",["ô"]="o",["õ"]="o",["ö"]="o",["ø"]="o",["ō"]="o",["ŏ"]="o",["ő"]="o",
    ["Œ"]="OE",["œ"]="oe",
    -- R
    ["Ŕ"]="R",["Ŗ"]="R",["Ř"]="R",
    ["ŕ"]="r",["ŗ"]="r",["ř"]="r",
    -- S
    ["Ś"]="S",["Ŝ"]="S",["Ş"]="S",["Š"]="S",
    ["ś"]="s",["ŝ"]="s",["ş"]="s",["š"]="s",["ß"]="ss",
    -- T
    ["Ţ"]="T",["Ť"]="T",["Ŧ"]="T",
    ["ţ"]="t",["ť"]="t",["ŧ"]="t",
    -- U
    ["Ù"]="U",["Ú"]="U",["Û"]="U",["Ü"]="U",["Ũ"]="U",["Ū"]="U",["Ŭ"]="U",["Ů"]="U",["Ű"]="U",["Ų"]="U",
    ["ù"]="u",["ú"]="u",["û"]="u",["ü"]="u",["ũ"]="u",["ū"]="u",["ŭ"]="u",["ů"]="u",["ű"]="u",["ų"]="u",
    -- W
    ["Ŵ"]="W",["ŵ"]="w",
    -- Y
    ["Ý"]="Y",["Ÿ"]="Y",["Ŷ"]="Y",
    ["ý"]="y",["ÿ"]="y",["ŷ"]="y",
    -- Z
    ["Ź"]="Z",["Ż"]="Z",["Ž"]="Z",
    ["ź"]="z",["ż"]="z",["ž"]="z",
    -- Currency / misc
    ["€"]="EUR", ["£"]="GBP", ["¥"]="JPY", ["©"]="(c)", ["®"]="(r)",
    ["™"]="TM", ["¶"]="P", ["§"]="S",
}

-- ===== UTF-8 walker =====================================================

local function utf8_iter(s)
    local i = 1
    local len = #s
    return function()
        if i > len then return nil end
        local b1 = s:byte(i)
        local size
        if b1 < 0x80 then size = 1
        elseif b1 < 0xE0 then size = 2
        elseif b1 < 0xF0 then size = 3
        else                  size = 4 end
        local chunk = s:sub(i, i + size - 1)
        local start = i
        i = i + size
        return chunk, start
    end
end

-- ===== Separator escaping ===============================================
-- The separator is interpolated into Lua patterns (to collapse/trim runs)
-- and used as a gsub replacement. Both sides need escaping: a digit sep
-- like "5" -> pattern "%5" is an invalid capture index; an alpha sep like
-- "x" -> "%x" becomes a character class; and a "%" in the replacement is a
-- capture reference. Escape for each context so any single-byte sep works.

local function pat_escape(ch)
    return (ch:gsub("%W", "%%%0"))   -- escape non-alphanumerics for pattern use
end

local function repl_escape(ch)
    return (ch:gsub("%%", "%%%%"))   -- escape % for gsub replacement use
end

-- ===== ASCII slug =======================================================

function M.slugify(s, opts)
    if s == nil then return "" end
    opts = opts or {}
    local sep   = opts.separator or "-"
    local lower = opts.lowercase ~= false
    local mlen  = opts.max_length or 80
    local trans = opts.transliterate ~= false

    -- Pass 1: translate / map each codepoint.
    local out, np = {}, 0
    for chunk in utf8_iter(s) do
        if #chunk == 1 then
            -- ASCII byte: keep alphanumerics, replace anything else with separator
            local b = chunk:byte()
            if (b >= 48 and b <= 57)
            or (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122) then
                np = np + 1; out[np] = chunk
            else
                np = np + 1; out[np] = sep
            end
        else
            local mapped = trans and TRANSLIT[chunk] or nil
            if mapped then
                np = np + 1; out[np] = mapped
            else
                -- unknown multi-byte char becomes a separator so we can dedupe later
                np = np + 1; out[np] = sep
            end
        end
    end

    local joined = table.concat(out)
    if lower then joined = joined:lower() end

    -- Collapse runs of separators and trim.
    local sep1      = sep:sub(1, 1)
    local sep_pat   = pat_escape(sep1)      -- escaped sep for gsub patterns
    local sep_repl  = repl_escape(sep1)     -- escaped sep for gsub replacement
    local doubled   = sep_pat .. "+"
    joined = joined:gsub(doubled, sep_repl)
    -- trim leading + trailing sep
    joined = joined:gsub("^" .. sep_pat .. "+", ""):gsub(sep_pat .. "+$", "")

    if #joined > mlen then
        joined = joined:sub(1, mlen)
        -- avoid cutting off mid-separator
        joined = joined:gsub(sep_pat .. "+$", "")
    end
    return joined
end

-- ===== Unicode-preserving slug =========================================
-- Keeps any byte sequence the OS considers a letter or digit by lightweight
-- heuristic (high-bit bytes that aren't whitespace / control), and only
-- collapses the ASCII non-alphanumerics into the separator. Useful for
-- search-friendly slugs in non-Latin content.

function M.unicode_slug(s, opts)
    if s == nil then return "" end
    opts = opts or {}
    local sep   = opts.separator or "-"
    local lower = opts.lowercase ~= false
    local mlen  = opts.max_length or 80

    local out, np = {}, 0
    for chunk in utf8_iter(s) do
        if #chunk == 1 then
            local b = chunk:byte()
            if (b >= 48 and b <= 57)
            or (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122) then
                np = np + 1; out[np] = chunk
            else
                np = np + 1; out[np] = sep
            end
        else
            -- assume multi-byte non-control input is "letter-ish"; keep it
            np = np + 1; out[np] = chunk
        end
    end

    local joined = table.concat(out)
    if lower then joined = joined:lower() end

    local sep1     = sep:sub(1, 1)
    local sep_pat  = pat_escape(sep1)
    local sep_repl = repl_escape(sep1)
    joined = joined:gsub(sep_pat .. "+", sep_repl)
    joined = joined:gsub("^" .. sep_pat .. "+", ""):gsub(sep_pat .. "+$", "")

    if #joined > mlen then
        -- Don't slice in the middle of a UTF-8 sequence.
        local cut = mlen
        while cut > 0 do
            local b = joined:byte(cut + 1)
            -- if next byte is a continuation byte, back up one
            if b == nil or (b & 0xC0) ~= 0x80 then break end
            cut = cut - 1
        end
        joined = joined:sub(1, cut)
        joined = joined:gsub(sep_pat .. "+$", "")
    end
    return joined
end

-- ===== Spec-compatible top-level entry =================================
-- The user spec calls the main entry `slug.slug(s, opts?)` rather than
-- `slug.slugify`. Map it through; if `opts.transliterate == false` we
-- delegate to unicode_slug so non-Latin scripts pass through intact.
-- opts.allowed is supported as a character-class string (e.g. "a-z0-9")
-- which we apply as a final whitelist pass.

function M.slug(s, opts)
    opts = opts or {}
    local trans = opts.transliterate
    if trans == nil then trans = true end
    local first
    if trans == false then
        first = M.unicode_slug(s, opts)
    else
        first = M.slugify(s, opts)
    end
    if opts.allowed then
        -- Build a Lua pattern that matches a single allowed byte and keep
        -- only those (plus the separator so collapse-runs still works).
        local sep  = opts.separator or "-"
        local sep1 = sep:sub(1, 1)
        local esc  = pat_escape(sep1)
        first = (first:gsub("[^" .. opts.allowed .. esc .. "]", ""))
        -- Dropping disallowed bytes can leave adjacent / leading / trailing
        -- separators (e.g. "a-x-b" with 'x' disallowed -> "a--b"); collapse
        -- runs and trim, mirroring slugify's own separator handling.
        first = (first:gsub(esc .. "+", repl_escape(sep1)))
        first = (first:gsub("^" .. esc .. "+", ""))
        first = (first:gsub(esc .. "+$", ""))
    end
    return first
end

return M
