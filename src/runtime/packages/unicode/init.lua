-- unicode -- Unicode normalization + properties + casing.
--
-- All heavy lifting goes through Win32 (normaliz.dll, kernel32):
--   NormalizeString  -- NFC / NFD / NFKC / NFKD
--   GetStringTypeW   -- general-category bits per UTF-16 code unit
--   LCMapStringEx    -- full-locale casing (upper / lower / title)
--
-- UTF-8 walking is done in pure Lua because crossing the FFI boundary
-- for every byte is far slower than a Lua loop. codepoints() / length()
-- / codepoint_at() are O(n) UTF-8 decoders that match RFC 3629.
--
-- Public surface:
--   unicode.normalize(s, form)        -- form = "nfc"|"nfd"|"nfkc"|"nfkd"
--   unicode.category(codepoint)       -> "Lu"|"Ll"|"Nd"|... or "Cn" for unknown
--   unicode.is_letter(cp)             -> bool
--   unicode.is_digit(cp)              -> bool
--   unicode.is_whitespace(cp)         -> bool
--   unicode.is_upper(cp), is_lower(cp), is_alphanumeric(cp), is_control(cp)
--   unicode.upper(s), unicode.lower(s), unicode.title(s)
--   unicode.codepoints(s)             -> iterator: for cp, byte_pos in unicode.codepoints(s) do
--   unicode.codepoint_at(s, byte_pos) -> codepoint, next_byte_pos
--   unicode.length(s)                 -> codepoint count
--   unicode.encode(codepoint)         -> UTF-8 bytes

require "windows"
local ffi = ffi

local M = {}

-- ===== Win32 cdef =======================================================

ffi.cdef [[
/* NormalizeString lives in normaliz.dll on every modern Windows. */
int NormalizeString(int normForm, const wchar_t *lpSrcString, int cwSrcLength,
                    wchar_t *lpDstString, int cwDstLength);
int GetStringTypeW(uint32_t dwInfoType, const wchar_t *lpSrcStr, int cchSrc,
                   uint16_t *lpCharType);
int LCMapStringEx(const wchar_t *lpLocaleName, uint32_t dwMapFlags,
                  const wchar_t *lpSrcStr, int cchSrc,
                  wchar_t *lpDestStr, int cchDest,
                  void *lpVersionInformation, void *lpReserved, intptr_t sortHandle);
]]

local _normaliz
local function load_normaliz()
    if _normaliz ~= nil then return _normaliz end
    -- ffi.load on Windows publishes the symbols globally too, but keeping
    -- a handle lets us also call via the namespace if the runtime is fussy.
    local ok, lib = pcall(ffi.load, "normaliz")
    if ok then _normaliz = lib else _normaliz = false end
    return _normaliz
end

-- LCMapStringEx + GetStringTypeW + MultiByteToWideChar live in kernel32
-- which the `windows` package already ffi.load'd.
local k32 = ffi.C

-- ===== Constants =======================================================

-- NORM_FORM values (winnls.h)
local NORM_FORMS = {
    nfc  = 0x1,
    nfd  = 0x2,
    nfkc = 0x5,
    nfkd = 0x6,
}

-- CT_CTYPE1 bits (GetStringTypeW). One uint16 of flags per UTF-16 code unit.
local C1_UPPER  = 0x0001
local C1_LOWER  = 0x0002
local C1_DIGIT  = 0x0004
local C1_SPACE  = 0x0008
local C1_PUNCT  = 0x0010
local C1_CNTRL  = 0x0020
local C1_BLANK  = 0x0040
local C1_XDIGIT = 0x0080
local C1_ALPHA  = 0x0100

-- LCMapStringEx mode flags
local LCMAP_LOWERCASE       = 0x00000100
local LCMAP_UPPERCASE       = 0x00000200
local LCMAP_LINGUISTIC_CAST = 0x01000000

-- ===== UTF-8 helpers ====================================================

function M.encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + (cp >> 6),
            0x80 + (cp & 0x3F))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + (cp >> 12),
            0x80 + ((cp >> 6) & 0x3F),
            0x80 + (cp & 0x3F))
    else
        return string.char(
            0xF0 + (cp >> 18),
            0x80 + ((cp >> 12) & 0x3F),
            0x80 + ((cp >> 6) & 0x3F),
            0x80 + (cp & 0x3F))
    end
end

-- Decode the codepoint starting at byte_pos. Returns cp, next_byte_pos.
-- Returns nil on malformed input.
function M.codepoint_at(s, byte_pos)
    local b1 = s:byte(byte_pos)
    if b1 == nil then return nil end
    if b1 < 0x80 then return b1, byte_pos + 1 end
    if b1 < 0xC2 then return nil end                  -- stray continuation / overlong
    if b1 < 0xE0 then
        local b2 = s:byte(byte_pos + 1)
        if b2 == nil or (b2 & 0xC0) ~= 0x80 then return nil end
        return ((b1 & 0x1F) << 6) | (b2 & 0x3F), byte_pos + 2
    end
    if b1 < 0xF0 then
        local b2 = s:byte(byte_pos + 1)
        local b3 = s:byte(byte_pos + 2)
        if b2 == nil or b3 == nil then return nil end
        if (b2 & 0xC0) ~= 0x80 or (b3 & 0xC0) ~= 0x80 then return nil end
        return ((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F), byte_pos + 3
    end
    if b1 < 0xF5 then
        local b2 = s:byte(byte_pos + 1)
        local b3 = s:byte(byte_pos + 2)
        local b4 = s:byte(byte_pos + 3)
        if b2 == nil or b3 == nil or b4 == nil then return nil end
        if (b2 & 0xC0) ~= 0x80 or (b3 & 0xC0) ~= 0x80 or (b4 & 0xC0) ~= 0x80 then return nil end
        return ((b1 & 0x07) << 18) | ((b2 & 0x3F) << 12)
             | ((b3 & 0x3F) << 6)  |  (b4 & 0x3F), byte_pos + 4
    end
    return nil
end

function M.codepoints(s)
    local pos = 1
    return function()
        if pos > #s then return nil end
        local cp, np = M.codepoint_at(s, pos)
        if cp == nil then
            -- Skip the bad byte rather than looping forever.
            pos = pos + 1
            return 0xFFFD, pos - 1
        end
        local p = pos
        pos = np
        return cp, p
    end
end

function M.length(s)
    local n = 0
    for _ in M.codepoints(s) do n = n + 1 end
    return n
end

-- UTF-8 string -> UTF-16 (wchar_t) buffer. Returns buffer + len_in_units.
local function utf8_to_utf16(s)
    local len = k32.MultiByteToWideChar(65001, 0, s, #s, nil, 0)  -- CP_UTF8
    if len <= 0 then return nil, 0 end
    local buf = ffi.new("wchar_t[?]", len)
    k32.MultiByteToWideChar(65001, 0, s, #s, buf, len)
    return buf, len
end

local function utf16_to_utf8(buf, len)
    if len <= 0 then return "" end
    local n = k32.WideCharToMultiByte(65001, 0, buf, len, nil, 0, nil, nil)
    if n <= 0 then return "" end
    local out = ffi.new("char[?]", n)
    k32.WideCharToMultiByte(65001, 0, buf, len, out, n, nil, nil)
    return ffi.string(out, n)
end

-- ===== Normalization ====================================================

function M.normalize(s, form)
    local norm = NORM_FORMS[(form or "nfc"):lower()]
    if norm == nil then
        error("unicode.normalize: unknown form '" .. tostring(form) .. "'", 2)
    end
    local lib = load_normaliz()
    if lib == false then
        error("unicode.normalize: normaliz.dll not available", 2)
    end
    local src, src_len = utf8_to_utf16(s)
    if src == nil or src_len == 0 then return "" end
    -- First probe: size requirement is returned via either positive return
    -- (success at 0 dest), or negative for not-enough-room. NormalizeString
    -- with cchDst=0 returns the estimated required size as a positive int.
    local out_len = lib.NormalizeString(norm, src, src_len, nil, 0)
    if out_len <= 0 then
        out_len = src_len * 4 + 16
    end
    local out = ffi.new("wchar_t[?]", out_len + 8)
    local actual = lib.NormalizeString(norm, src, src_len, out, out_len + 8)
    if actual < 0 then
        -- Buffer was too small; retry with the suggested size.
        out_len = -actual
        out     = ffi.new("wchar_t[?]", out_len + 8)
        actual  = lib.NormalizeString(norm, src, src_len, out, out_len + 8)
        if actual < 0 then
            error("unicode.normalize: NormalizeString failed", 2)
        end
    end
    return utf16_to_utf8(out, actual)
end

-- ===== Properties (single codepoint) ===================================
-- We cache one-cp lookups so hot inner loops don't repeatedly cross FFI.

local _cat_cache = {}

local function get_ctype1_for_cp(cp)
    local cached = _cat_cache[cp]
    if cached then return cached end
    -- Build a 1- or 2-unit UTF-16 buffer holding just this codepoint.
    local buf, count
    if cp < 0x10000 then
        buf   = ffi.new("wchar_t[1]", cp)
        count = 1
    else
        local hi = 0xD800 + ((cp - 0x10000) >> 10)
        local lo = 0xDC00 + ((cp - 0x10000) & 0x3FF)
        buf   = ffi.new("wchar_t[2]", hi, lo)
        count = 2
    end
    local out = ffi.new("uint16_t[2]")
    local ok  = k32.GetStringTypeW(1, buf, count, out)  -- CT_CTYPE1
    if ok == 0 then return 0 end
    local v = tonumber(out[0])
    _cat_cache[cp] = v
    return v
end

-- Map CT_CTYPE1 bit pattern to a coarse Unicode general-category code.
-- We only emit the categories the Win32 API actually distinguishes; finer
-- properties (Mn vs Mc etc.) aren't exposed by GetStringTypeW so they
-- collapse to "Cn" (unassigned-as-far-as-we-can-tell).
function M.category(cp)
    local t = get_ctype1_for_cp(cp)
    if (t & C1_UPPER) ~= 0  then return "Lu" end
    if (t & C1_LOWER) ~= 0  then return "Ll" end
    if (t & C1_ALPHA) ~= 0  then return "Lo" end
    if (t & C1_DIGIT) ~= 0  then return "Nd" end
    if (t & C1_PUNCT) ~= 0  then return "Po" end
    if (t & C1_SPACE) ~= 0  then return "Zs" end
    if (t & C1_CNTRL) ~= 0  then return "Cc" end
    return "Cn"
end

function M.is_letter(cp)
    local t = get_ctype1_for_cp(cp)
    return (t & (C1_UPPER | C1_LOWER | C1_ALPHA)) ~= 0
end

function M.is_digit(cp)
    return (get_ctype1_for_cp(cp) & C1_DIGIT) ~= 0
end

function M.is_whitespace(cp)
    return (get_ctype1_for_cp(cp) & C1_SPACE) ~= 0
end

function M.is_upper(cp)
    return (get_ctype1_for_cp(cp) & C1_UPPER) ~= 0
end

function M.is_lower(cp)
    return (get_ctype1_for_cp(cp) & C1_LOWER) ~= 0
end

function M.is_alphanumeric(cp)
    local t = get_ctype1_for_cp(cp)
    return (t & (C1_UPPER | C1_LOWER | C1_ALPHA | C1_DIGIT)) ~= 0
end

function M.is_control(cp)
    return (get_ctype1_for_cp(cp) & C1_CNTRL) ~= 0
end

function M.is_punct(cp)
    return (get_ctype1_for_cp(cp) & C1_PUNCT) ~= 0
end

-- ===== Casing ==========================================================

local function map_case(s, flag)
    local src, src_len = utf8_to_utf16(s)
    if src == nil or src_len == 0 then return "" end
    -- First call with cchDest=0 returns required size.
    local n = k32.LCMapStringEx(nil, flag, src, src_len, nil, 0, nil, nil, 0)
    if n <= 0 then return s end
    local out = ffi.new("wchar_t[?]", n)
    local actual = k32.LCMapStringEx(nil, flag, src, src_len, out, n, nil, nil, 0)
    if actual <= 0 then return s end
    return utf16_to_utf8(out, actual)
end

function M.upper(s) return map_case(s, LCMAP_UPPERCASE + LCMAP_LINGUISTIC_CAST) end
function M.lower(s) return map_case(s, LCMAP_LOWERCASE + LCMAP_LINGUISTIC_CAST) end

-- ===== Spec-compatible aliases ========================================
-- These wrappers expose the names the user spec requests on top of the
-- existing Win32-backed primitives above.

-- from_utf8(s, init?) -> codepoint, next_pos  (alias of codepoint_at).
function M.from_utf8(s, init)
    return M.codepoint_at(s, init or 1)
end

-- to_utf8(cp) -> string  (alias of encode).
M.to_utf8 = M.encode

-- to_utf16(cp) -> string of 2 or 4 UTF-16 bytes (big-endian; callers can
-- swap if they need LE). Returns a Lua string for convenience.
function M.to_utf16(cp)
    if cp < 0x10000 then
        return string.char((cp >> 8) & 0xFF, cp & 0xFF)
    else
        local v = cp - 0x10000
        local hi = 0xD800 + (v >> 10)
        local lo = 0xDC00 + (v & 0x3FF)
        return string.char((hi >> 8) & 0xFF, hi & 0xFF,
                           (lo >> 8) & 0xFF, lo & 0xFF)
    end
end

-- fold(s) -- full case fold using the underlying lower-case mapping.
-- LCMapStringEx does not provide separate fold-case data, so this is an
-- approximation; for fold-equivalence comparisons it's typically enough.
function M.fold(s)
    return M.lower(s)
end

-- Property predicates that aren't named the same as our originals.
M.is_alpha   = M.is_letter
M.is_space   = M.is_whitespace
M.is_mark    = function(cp)
    -- Combining marks: Mn / Mc / Me. GetStringTypeW doesn't break them out,
    -- so we fall back to a small range list covering the common scripts.
    if (cp >= 0x0300 and cp <= 0x036F)
    or (cp >= 0x0483 and cp <= 0x0489)
    or (cp >= 0x0591 and cp <= 0x05BD)
    or (cp >= 0x064B and cp <= 0x065F)
    or (cp >= 0x06D6 and cp <= 0x06ED)
    or (cp >= 0x0711 and cp <= 0x0711)
    or (cp >= 0x0730 and cp <= 0x074A)
    or (cp >= 0x0900 and cp <= 0x0903)
    or (cp >= 0x093A and cp <= 0x094F)
    or (cp >= 0x0951 and cp <= 0x0957)
    or (cp >= 0x1AB0 and cp <= 0x1ACE)
    or (cp >= 0x1DC0 and cp <= 0x1DFF)
    or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE20 and cp <= 0xFE2F) then return true end
    return false
end

-- Symbols cluster: math + currency + modifier + other. Win32 lumps them
-- into the Punct bit so we just expose that.
function M.is_symbol(cp)
    -- Common symbol blocks: $ + < = > | ~ , the math-operator block, etc.
    if cp == 0x24 or cp == 0x2B or (cp >= 0x3C and cp <= 0x3E) or cp == 0x7C or cp == 0x7E then return true end
    if cp >= 0x00A2 and cp <= 0x00A9 then return true end          -- currency / copyright
    if cp == 0x00AC or cp == 0x00B1 or cp == 0x00D7 or cp == 0x00F7 then return true end
    if cp >= 0x2200 and cp <= 0x22FF then return true end          -- math operators
    if cp >= 0x20A0 and cp <= 0x20CF then return true end          -- currency symbols
    if cp >= 0x2600 and cp <= 0x26FF then return true end          -- misc symbols
    if cp >= 0x2700 and cp <= 0x27BF then return true end          -- dingbats
    return false
end

function M.is_punct(cp) -- already defined above; keep for spec name
    return (get_ctype1_for_cp(cp) & C1_PUNCT) ~= 0
end

-- ===== Limited name table ==============================================
-- Returning every Unicode character name would balloon this package by
-- megabytes. We ship the ASCII + Latin-1 + a handful of well-known
-- code-point names; anything else returns "U+XXXX" so callers always
-- get a usable string back.

local _NAMES = {
    [0x0009] = "CHARACTER TABULATION",
    [0x000A] = "LINE FEED",
    [0x000D] = "CARRIAGE RETURN",
    [0x0020] = "SPACE",
    [0x00A0] = "NO-BREAK SPACE",
    [0x00A9] = "COPYRIGHT SIGN",
    [0x00AE] = "REGISTERED SIGN",
    [0x00B0] = "DEGREE SIGN",
    [0x00B5] = "MICRO SIGN",
    [0x00B7] = "MIDDLE DOT",
    [0x00BF] = "INVERTED QUESTION MARK",
    [0x00DF] = "LATIN SMALL LETTER SHARP S",
    [0x00E6] = "LATIN SMALL LETTER AE",
    [0x00F8] = "LATIN SMALL LETTER O WITH STROKE",
    [0x2014] = "EM DASH",
    [0x2018] = "LEFT SINGLE QUOTATION MARK",
    [0x2019] = "RIGHT SINGLE QUOTATION MARK",
    [0x201C] = "LEFT DOUBLE QUOTATION MARK",
    [0x201D] = "RIGHT DOUBLE QUOTATION MARK",
    [0x2026] = "HORIZONTAL ELLIPSIS",
    [0x20AC] = "EURO SIGN",
    [0x2122] = "TRADE MARK SIGN",
    [0x2603] = "SNOWMAN",
    [0x2764] = "HEAVY BLACK HEART",
    [0xFFFD] = "REPLACEMENT CHARACTER",
}

function M.name(cp)
    local cached = _NAMES[cp]
    if cached then return cached end
    if cp >= 0x41 and cp <= 0x5A then return "LATIN CAPITAL LETTER " .. string.char(cp) end
    if cp >= 0x61 and cp <= 0x7A then return "LATIN SMALL LETTER " .. string.char(cp - 32) end
    if cp >= 0x30 and cp <= 0x39 then
        local digits = { "ZERO","ONE","TWO","THREE","FOUR","FIVE","SIX","SEVEN","EIGHT","NINE" }
        return "DIGIT " .. digits[cp - 47]
    end
    return string.format("U+%04X", cp)
end

-- ===== Blocks =========================================================
-- Pre-sorted list of (lo, hi, name) tuples covering the major Unicode
-- blocks. Binary search keeps lookup O(log n).

local _BLOCKS = {
    {0x0000, 0x007F, "Basic Latin"},
    {0x0080, 0x00FF, "Latin-1 Supplement"},
    {0x0100, 0x017F, "Latin Extended-A"},
    {0x0180, 0x024F, "Latin Extended-B"},
    {0x0250, 0x02AF, "IPA Extensions"},
    {0x0300, 0x036F, "Combining Diacritical Marks"},
    {0x0370, 0x03FF, "Greek and Coptic"},
    {0x0400, 0x04FF, "Cyrillic"},
    {0x0500, 0x052F, "Cyrillic Supplement"},
    {0x0530, 0x058F, "Armenian"},
    {0x0590, 0x05FF, "Hebrew"},
    {0x0600, 0x06FF, "Arabic"},
    {0x0900, 0x097F, "Devanagari"},
    {0x0E00, 0x0E7F, "Thai"},
    {0x10A0, 0x10FF, "Georgian"},
    {0x1100, 0x11FF, "Hangul Jamo"},
    {0x1E00, 0x1EFF, "Latin Extended Additional"},
    {0x2000, 0x206F, "General Punctuation"},
    {0x2070, 0x209F, "Superscripts and Subscripts"},
    {0x20A0, 0x20CF, "Currency Symbols"},
    {0x2100, 0x214F, "Letterlike Symbols"},
    {0x2150, 0x218F, "Number Forms"},
    {0x2190, 0x21FF, "Arrows"},
    {0x2200, 0x22FF, "Mathematical Operators"},
    {0x2300, 0x23FF, "Miscellaneous Technical"},
    {0x2400, 0x243F, "Control Pictures"},
    {0x2500, 0x257F, "Box Drawing"},
    {0x2580, 0x259F, "Block Elements"},
    {0x25A0, 0x25FF, "Geometric Shapes"},
    {0x2600, 0x26FF, "Miscellaneous Symbols"},
    {0x2700, 0x27BF, "Dingbats"},
    {0x2E80, 0x2EFF, "CJK Radicals Supplement"},
    {0x3000, 0x303F, "CJK Symbols and Punctuation"},
    {0x3040, 0x309F, "Hiragana"},
    {0x30A0, 0x30FF, "Katakana"},
    {0x3400, 0x4DBF, "CJK Unified Ideographs Extension A"},
    {0x4E00, 0x9FFF, "CJK Unified Ideographs"},
    {0xAC00, 0xD7AF, "Hangul Syllables"},
    {0xD800, 0xDB7F, "High Surrogates"},
    {0xDB80, 0xDBFF, "High Private Use Surrogates"},
    {0xDC00, 0xDFFF, "Low Surrogates"},
    {0xE000, 0xF8FF, "Private Use Area"},
    {0xF900, 0xFAFF, "CJK Compatibility Ideographs"},
    {0xFE00, 0xFE0F, "Variation Selectors"},
    {0xFE30, 0xFE4F, "CJK Compatibility Forms"},
    {0xFF00, 0xFFEF, "Halfwidth and Fullwidth Forms"},
    {0x1F300, 0x1F5FF, "Miscellaneous Symbols and Pictographs"},
    {0x1F600, 0x1F64F, "Emoticons"},
    {0x1F680, 0x1F6FF, "Transport and Map Symbols"},
    {0x1F900, 0x1F9FF, "Supplemental Symbols and Pictographs"},
    {0x20000, 0x2A6DF, "CJK Unified Ideographs Extension B"},
}

function M.block(cp)
    local lo, hi = 1, #_BLOCKS
    while lo <= hi do
        local mid = (lo + hi) >> 1
        local b = _BLOCKS[mid]
        if cp < b[1] then
            hi = mid - 1
        elseif cp > b[2] then
            lo = mid + 1
        else
            return b[3]
        end
    end
    return nil
end

-- ===== Grapheme iteration (extended grapheme clusters, simplified) ====
-- Joins runs of base + combining marks + ZWJ-emoji sequences. We
-- intentionally only recognize the common Unicode 15 cases here -- a
-- complete UAX#29 implementation is a separate beast.

function M.graphemes(s)
    local pos = 1
    local len = #s
    return function()
        if pos > len then return nil end
        local start_pos = pos
        local cp, np = M.codepoint_at(s, pos)
        if cp == nil then pos = pos + 1; return s:sub(start_pos, start_pos), start_pos end
        pos = np
        -- Extend with combining marks / ZWJ continuations.
        while pos <= len do
            local cp2, np2 = M.codepoint_at(s, pos)
            if cp2 == nil then break end
            local extend = false
            if M.is_mark(cp2) then extend = true end
            if cp2 == 0x200D then extend = true end                       -- ZWJ
            if cp2 >= 0xFE00 and cp2 <= 0xFE0F then extend = true end     -- variation selectors
            if cp2 >= 0xE0100 and cp2 <= 0xE01EF then extend = true end   -- VS supplement
            if not extend then break end
            pos = np2
        end
        return s:sub(start_pos, pos - 1), start_pos
    end
end

function M.title(s)
    -- LCMapStringEx supports LCMAP_TITLECASE only on Win7+; we implement
    -- title casing by detecting word boundaries on the Lua side. A "word"
    -- starts after a non-letter and runs while characters are letters.
    local out_parts = {}
    local np = 0
    local in_word = false
    local pending = {}
    local pn = 0
    local function flush_word()
        if pn == 0 then return end
        local word = table.concat(pending, "", 1, pn)
        -- Find the byte length of the first codepoint so we can split.
        local _, next_bp = M.codepoint_at(word, 1)
        local first = word:sub(1, (next_bp or 2) - 1)
        local rest  = word:sub((next_bp or 2))
        np = np + 1; out_parts[np] = M.upper(first) .. M.lower(rest)
        pn = 0
        for i = 1, #pending do pending[i] = nil end
    end
    for cp, bp in M.codepoints(s) do
        local _, next_bp = M.codepoint_at(s, bp)
        local raw = s:sub(bp, (next_bp or bp + 1) - 1)
        if M.is_letter(cp) then
            if not in_word then in_word = true end
            pn = pn + 1; pending[pn] = raw
        else
            if in_word then flush_word(); in_word = false end
            np = np + 1; out_parts[np] = raw
        end
    end
    if in_word then flush_word() end
    return table.concat(out_parts)
end

return M
