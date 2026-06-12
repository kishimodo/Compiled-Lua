-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- qrcode -- pure-Lua QR Code generator.
--
-- ISO/IEC 18004 reference; supports the full 1..40 version range,
-- ECC L/M/Q/H, automatic mode pick (numeric / alphanumeric / byte),
-- automatic mask selection (penalty scoring on all 8 masks), and
-- bitmap / SVG render.
--
-- Public surface:
--   qrcode.generate(text, opts?) -> matrix
--       matrix = { size, modules, version, ecc, mask }
--       modules is a 2D array of booleans (true = dark module)
--   qrcode.to_svg(matrix, opts?) -> string
--   qrcode.to_image(matrix, scale, padding?) -> bgra bytes, width, height
--   qrcode.numeric_capacity(version, ecc) / .alphanumeric_capacity / .byte_capacity
--
-- opts:
--   ecc      -- "L" | "M" | "Q" | "H"           (default "M")
--   version  -- 1..40                            (default: smallest that fits)
--   mode     -- "numeric"|"alphanumeric"|"byte"  (default: auto)
--   mask     -- 0..7                             (default: best by penalty)
--   eci      -- ECI designator (only used in byte mode)

local bit = bit or require "bit"
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local M = {}

-- ===== Galois Field GF(2^8) with primitive polynomial 0x11D ============
-- Tables for Reed-Solomon arithmetic.
local _gf_exp = {}
local _gf_log = {}
do
    local x = 1
    for i = 0, 255 do
        _gf_exp[i] = x
        _gf_log[x] = i
        x = lshift(x, 1)
        if x >= 256 then x = bxor(x, 0x11D) end
    end
    -- Pad exp table so we can index without modular reduction.
    for i = 256, 511 do _gf_exp[i] = _gf_exp[i - 255] end
end

local function gf_mul(a, b)
    if a == 0 or b == 0 then return 0 end
    return _gf_exp[_gf_log[a] + _gf_log[b]]
end

-- Build the RS generator polynomial of degree `n` (coefficients in GF(256)).
local function rs_generator(n)
    local g = { 1 }
    for i = 0, n - 1 do
        local nextg = { 0 }
        for j = 1, #g + 1 do nextg[j] = 0 end
        for j = 1, #g do
            nextg[j]     = bxor(nextg[j], g[j])
            nextg[j + 1] = bxor(nextg[j + 1] or 0, gf_mul(g[j], _gf_exp[i]))
        end
        g = nextg
    end
    return g
end

-- Compute n RS check bytes for the given data bytes.
local function rs_encode(data, n)
    local g = rs_generator(n)
    local buf = {}
    for i = 1, #data do buf[i] = data[i] end
    for i = 1, n do buf[#data + i] = 0 end
    for i = 1, #data do
        local coef = buf[i]
        if coef ~= 0 then
            for j = 1, #g do
                buf[i + j - 1] = bxor(buf[i + j - 1], gf_mul(g[j], coef))
            end
        end
    end
    local out = {}
    for i = 1, n do out[i] = buf[#data + i] end
    return out
end

-- ===== Version metadata =================================================
-- For each (version 1..40) and each ECC level L/M/Q/H:
--   total_codewords   -- total codewords for the version
--   ec_codewords      -- EC codewords per RS block
--   group1_blocks / group1_data
--   group2_blocks / group2_data

-- Table cribbed from ISO/IEC 18004:2015 table 9 (capacity tables).
-- Format: { L = {ec, g1b, g1d, g2b, g2d}, M = {...}, Q = {...}, H = {...} }
local _ecc_tbl = {
    [1]  = { L={ 7,1,19,0,0}, M={10,1,16,0,0}, Q={13,1,13,0,0}, H={17,1, 9,0,0} },
    [2]  = { L={10,1,34,0,0}, M={16,1,28,0,0}, Q={22,1,22,0,0}, H={28,1,16,0,0} },
    [3]  = { L={15,1,55,0,0}, M={26,1,44,0,0}, Q={18,2,17,0,0}, H={22,2,13,0,0} },
    [4]  = { L={20,1,80,0,0}, M={18,2,32,0,0}, Q={26,2,24,0,0}, H={16,4, 9,0,0} },
    [5]  = { L={26,1,108,0,0},M={24,2,43,0,0}, Q={18,2,15,2,16},H={22,2,11,2,12} },
    [6]  = { L={18,2,68,0,0}, M={16,4,27,0,0}, Q={24,4,19,0,0}, H={28,4,15,0,0} },
    [7]  = { L={20,2,78,0,0}, M={18,4,31,0,0}, Q={18,2,14,4,15},H={26,4,13,1,14} },
    [8]  = { L={24,2,97,0,0}, M={22,2,38,2,39},Q={22,4,18,2,19},H={26,4,14,2,15} },
    [9]  = { L={30,2,116,0,0},M={22,3,36,2,37},Q={20,4,16,4,17},H={24,4,12,4,13} },
    [10] = { L={18,2,68,2,69},M={26,4,43,1,44},Q={24,6,19,2,20},H={28,6,15,2,16} },
    [11] = { L={20,4,81,0,0}, M={30,1,50,4,51},Q={28,4,22,4,23},H={24,3,12,8,13} },
    [12] = { L={24,2,92,2,93},M={22,6,36,2,37},Q={26,4,20,6,21},H={28,7,14,4,15} },
    [13] = { L={26,4,107,0,0},M={22,8,37,1,38},Q={24,8,20,4,21},H={22,12,11,4,12}},
    [14] = { L={30,3,115,1,116},M={24,4,40,5,41},Q={20,11,16,5,17},H={24,11,12,5,13}},
    [15] = { L={22,5,87,1,88},M={24,5,41,5,42},Q={30,5,24,7,25},H={24,11,12,7,13}},
    [16] = { L={24,5,98,1,99},M={28,7,45,3,46},Q={24,15,19,2,20},H={30,3,15,13,16}},
    [17] = { L={28,1,107,5,108},M={28,10,46,1,47},Q={28,1,22,15,23},H={28,2,14,17,15}},
    [18] = { L={30,5,120,1,121},M={26,9,43,4,44},Q={28,17,22,1,23},H={28,2,14,19,15}},
    [19] = { L={28,3,113,4,114},M={26,3,44,11,45},Q={26,17,21,4,22},H={26,9,13,16,14}},
    [20] = { L={28,3,107,5,108},M={26,3,41,13,42},Q={30,15,24,5,25},H={28,15,15,10,16}},
    [21] = { L={28,4,116,4,117},M={26,17,42,0,0},Q={28,17,22,6,23},H={30,19,16,6,17}},
    [22] = { L={28,2,111,7,112},M={28,17,46,0,0},Q={30,7,24,16,25},H={24,34,13,0,0}},
    [23] = { L={30,4,121,5,122},M={28,4,47,14,48},Q={30,11,24,14,25},H={30,16,15,14,16}},
    [24] = { L={30,6,117,4,118},M={28,6,45,14,46},Q={30,11,24,16,25},H={30,30,16,2,17}},
    [25] = { L={26,8,106,4,107},M={28,8,47,13,48},Q={30,7,24,22,25},H={30,22,15,13,16}},
    [26] = { L={28,10,114,2,115},M={28,19,46,4,47},Q={28,28,22,6,23},H={30,33,16,4,17}},
    [27] = { L={30,8,122,4,123},M={28,22,45,3,46},Q={30,8,23,26,24},H={30,12,15,28,16}},
    [28] = { L={30,3,117,10,118},M={28,3,45,23,46},Q={30,4,24,31,25},H={30,11,15,31,16}},
    [29] = { L={30,7,116,7,117},M={28,21,45,7,46},Q={30,1,23,37,24},H={30,19,15,26,16}},
    [30] = { L={30,5,115,10,116},M={28,19,47,10,48},Q={30,15,24,25,25},H={30,23,15,25,16}},
    [31] = { L={30,13,115,3,116},M={28,2,46,29,47},Q={30,42,24,1,25},H={30,23,15,28,16}},
    [32] = { L={30,17,115,0,0},M={28,10,46,23,47},Q={30,10,24,35,25},H={30,19,15,35,16}},
    [33] = { L={30,17,115,1,116},M={28,14,46,21,47},Q={30,29,24,19,25},H={30,11,15,46,16}},
    [34] = { L={30,13,115,6,116},M={28,14,46,23,47},Q={30,44,24,7,25},H={30,59,16,1,17}},
    [35] = { L={30,12,121,7,122},M={28,12,47,26,48},Q={30,39,24,14,25},H={30,22,15,41,16}},
    [36] = { L={30,6,121,14,122},M={28,6,47,34,48},Q={30,46,24,10,25},H={30,2,15,64,16}},
    [37] = { L={30,17,122,4,123},M={28,29,46,14,47},Q={30,49,24,10,25},H={30,24,15,46,16}},
    [38] = { L={30,4,122,18,123},M={28,13,46,32,47},Q={30,48,24,14,25},H={30,42,15,32,16}},
    [39] = { L={30,20,117,4,118},M={28,40,47,7,48},Q={30,43,24,22,25},H={30,10,15,67,16}},
    [40] = { L={30,19,118,6,119},M={28,18,47,31,48},Q={30,34,24,34,25},H={30,20,15,61,16}},
}

-- Total data codewords by (version, ecc)
local function version_data_capacity(v, ecc)
    local row = _ecc_tbl[v][ecc]
    return row[2] * row[3] + row[4] * row[5]
end

-- Module count for a version = (V-1)*4 + 21.
local function version_size(v) return (v - 1) * 4 + 21 end

-- ===== Mode detection + capacity ========================================

local _ALPHANUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
local _ALPHANUM_IDX = {}
for i = 1, #_ALPHANUM do _ALPHANUM_IDX[_ALPHANUM:sub(i, i)] = i - 1 end

local function detect_mode(text)
    local numeric = true
    local alphanum = true
    for i = 1, #text do
        local c = text:sub(i, i)
        if not c:match("%d") then numeric = false end
        if not _ALPHANUM_IDX[c] then alphanum = false end
        if not numeric and not alphanum then return "byte" end
    end
    if numeric then return "numeric" end
    if alphanum then return "alphanumeric" end
    return "byte"
end

-- Character-count indicator bit width per mode and version range
-- (ISO/IEC 18004 table 3).
local function cci_width(mode, version)
    if version <= 9 then
        if mode == "numeric"      then return 10 end
        if mode == "alphanumeric" then return  9 end
        return 8
    elseif version <= 26 then
        if mode == "numeric"      then return 12 end
        if mode == "alphanumeric" then return 11 end
        return 16
    else
        if mode == "numeric"      then return 14 end
        if mode == "alphanumeric" then return 13 end
        return 16
    end
end

local function mode_indicator(mode)
    if mode == "numeric"      then return 1 end
    if mode == "alphanumeric" then return 2 end
    if mode == "byte"         then return 4 end
    error("qrcode: unknown mode " .. tostring(mode))
end

-- Bit count for encoded payload (without indicator + CCI + terminator).
local function payload_bits(mode, n)
    if mode == "numeric" then
        local full = math.floor(n / 3)
        local rem  = n % 3
        local extra = rem == 1 and 4 or rem == 2 and 7 or 0
        return full * 10 + extra
    elseif mode == "alphanumeric" then
        local full = math.floor(n / 2)
        local rem  = n % 2
        return full * 11 + (rem == 1 and 6 or 0)
    else
        return n * 8
    end
end

local function smallest_version(mode, n, ecc)
    for v = 1, 40 do
        local cap = version_data_capacity(v, ecc) * 8
        local need = 4 + cci_width(mode, v) + payload_bits(mode, n)
        if cap >= need then return v end
    end
    error("qrcode: payload too large for any version at ecc " .. ecc)
end

-- ===== Bit buffer =======================================================

local function new_bit_buffer()
    local self = { bits = {}, n = 0 }
    function self.push(v, w)
        for i = w - 1, 0, -1 do
            self.n = self.n + 1
            self.bits[self.n] = band(rshift(v, i), 1)
        end
    end
    function self.pad_to_codewords(target_bits)
        -- terminator
        local rem = target_bits - self.n
        if rem > 4 then rem = 4 end
        if rem > 0 then self.push(0, rem) end
        -- pad to byte boundary
        while self.n % 8 ~= 0 do self.push(0, 1) end
    end
    function self.to_bytes()
        local out = {}
        for i = 1, self.n, 8 do
            local b = 0
            for j = 0, 7 do
                b = bor(lshift(b, 1), self.bits[i + j] or 0)
            end
            out[#out + 1] = b
        end
        return out
    end
    return self
end

-- ===== Payload encoders =================================================

local function encode_numeric(buf, text)
    local i = 1
    while i <= #text do
        local len = math.min(3, #text - i + 1)
        local n = tonumber(text:sub(i, i + len - 1), 10)
        if len == 3 then buf.push(n, 10)
        elseif len == 2 then buf.push(n, 7)
        else                 buf.push(n, 4) end
        i = i + len
    end
end

local function encode_alphanumeric(buf, text)
    local i = 1
    while i <= #text do
        if i + 1 <= #text then
            local v = _ALPHANUM_IDX[text:sub(i, i)] * 45 + _ALPHANUM_IDX[text:sub(i + 1, i + 1)]
            buf.push(v, 11)
            i = i + 2
        else
            buf.push(_ALPHANUM_IDX[text:sub(i, i)], 6)
            i = i + 1
        end
    end
end

local function encode_byte(buf, text)
    for i = 1, #text do buf.push(text:byte(i), 8) end
end

-- ===== Interleave + EC ==================================================

local function build_final_codewords(data, version, ecc)
    local row = _ecc_tbl[version][ecc]
    local ec_per_block = row[1]
    local g1b, g1d, g2b, g2d = row[2], row[3], row[4], row[5]

    -- Split data into blocks
    local blocks = {}
    local idx = 1
    for _ = 1, g1b do
        local blk = {}
        for j = 1, g1d do blk[j] = data[idx]; idx = idx + 1 end
        blocks[#blocks + 1] = blk
    end
    for _ = 1, g2b do
        local blk = {}
        for j = 1, g2d do blk[j] = data[idx]; idx = idx + 1 end
        blocks[#blocks + 1] = blk
    end

    -- Compute EC for each block
    local ec_blocks = {}
    for i, b in ipairs(blocks) do ec_blocks[i] = rs_encode(b, ec_per_block) end

    -- Interleave data
    local max_data_len = math.max(g1d, (g2d > 0 and g2d) or 0)
    local out = {}
    for col = 1, max_data_len do
        for _, b in ipairs(blocks) do
            if b[col] then out[#out + 1] = b[col] end
        end
    end
    -- Interleave EC
    for col = 1, ec_per_block do
        for _, b in ipairs(ec_blocks) do out[#out + 1] = b[col] end
    end
    return out
end

-- Pad bytes appended after the terminator + zero-padding to fill capacity.
local _PAD_BYTES = { 0xEC, 0x11 }

-- ===== Matrix layout ====================================================

-- Returns alignment-pattern centre coordinates for the version.
local _align_tbl = {
    [1]={}, [2]={6,18}, [3]={6,22}, [4]={6,26}, [5]={6,30}, [6]={6,34},
    [7]={6,22,38}, [8]={6,24,42}, [9]={6,26,46}, [10]={6,28,50},
    [11]={6,30,54}, [12]={6,32,58}, [13]={6,34,62},
    [14]={6,26,46,66}, [15]={6,26,48,70}, [16]={6,26,50,74},
    [17]={6,30,54,78}, [18]={6,30,56,82}, [19]={6,30,58,86}, [20]={6,34,62,90},
    [21]={6,28,50,72,94}, [22]={6,26,50,74,98}, [23]={6,30,54,78,102},
    [24]={6,28,54,80,106}, [25]={6,32,58,84,110}, [26]={6,30,58,86,114},
    [27]={6,34,62,90,118},
    [28]={6,26,50,74,98,122}, [29]={6,30,54,78,102,126},
    [30]={6,26,52,78,104,130}, [31]={6,30,56,82,108,134},
    [32]={6,34,60,86,112,138}, [33]={6,30,58,86,114,142},
    [34]={6,34,62,90,118,146},
    [35]={6,30,54,78,102,126,150}, [36]={6,24,50,76,102,128,154},
    [37]={6,28,54,80,106,132,158}, [38]={6,32,58,84,110,136,162},
    [39]={6,26,54,82,110,138,166}, [40]={6,30,58,86,114,142,170},
}

local function new_matrix(n)
    local mod, reserved = {}, {}
    for r = 1, n do
        mod[r] = {}
        reserved[r] = {}
        for c = 1, n do mod[r][c] = false; reserved[r][c] = false end
    end
    return mod, reserved
end

local function set_module(mod, reserved, r, c, dark)
    mod[r][c] = dark
    reserved[r][c] = true
end

local function place_finder(mod, reserved, r, c)
    -- 7x7 finder + 1-module separator. r,c is top-left of the 7x7 box.
    local size = #mod
    for dr = -1, 7 do
        for dc = -1, 7 do
            local rr, cc = r + dr, c + dc
            if rr >= 1 and rr <= size and cc >= 1 and cc <= size then
                local on
                if dr == -1 or dr == 7 or dc == -1 or dc == 7 then
                    on = false  -- separator
                elseif dr == 0 or dr == 6 or dc == 0 or dc == 6 then
                    on = true
                elseif dr >= 2 and dr <= 4 and dc >= 2 and dc <= 4 then
                    on = true
                else
                    on = false
                end
                set_module(mod, reserved, rr, cc, on)
            end
        end
    end
end

local function place_alignment(mod, reserved, cr, cc)
    -- 5x5 alignment pattern centred on (cr, cc).
    for dr = -2, 2 do
        for dc = -2, 2 do
            local on
            if dr == 0 and dc == 0 then on = true
            elseif math.abs(dr) == 2 or math.abs(dc) == 2 then on = true
            else on = false end
            set_module(mod, reserved, cr + dr, cc + dc, on)
        end
    end
end

local function place_timing(mod, reserved)
    local n = #mod
    for i = 9, n - 8 do
        if not reserved[7][i] then
            set_module(mod, reserved, 7, i, i % 2 == 1)
        end
        if not reserved[i][7] then
            set_module(mod, reserved, i, 7, i % 2 == 1)
        end
    end
end

local function place_dark_module(mod, reserved, version)
    -- (4*V + 9, 8) in zero-based -> (4V+10, 9) one-based.
    set_module(mod, reserved, 4 * version + 10, 9, true)
end

local function reserve_format_areas(mod, reserved, version)
    local n = #mod
    -- Around top-left finder (rows/cols 1..9, but skip finder/timing cells).
    for i = 1, 9 do
        if not reserved[9][i] then reserved[9][i] = true; mod[9][i] = false end
        if not reserved[i][9] then reserved[i][9] = true; mod[i][9] = false end
    end
    -- Top-right format strip
    for c = n - 7, n do
        if not reserved[9][c] then reserved[9][c] = true; mod[9][c] = false end
    end
    -- Bottom-left format strip
    for r = n - 7, n do
        if not reserved[r][9] then reserved[r][9] = true; mod[r][9] = false end
    end
    -- Version info blocks (V >= 7): 6x3 top-right + 3x6 bottom-left
    if version >= 7 then
        for r = 1, 6 do
            for c = n - 10, n - 8 do
                reserved[r][c] = true; mod[r][c] = false
            end
        end
        for c = 1, 6 do
            for r = n - 10, n - 8 do
                reserved[r][c] = true; mod[r][c] = false
            end
        end
    end
end

local function place_function_patterns(version)
    local n = version_size(version)
    local mod, reserved = new_matrix(n)
    place_finder(mod, reserved, 1, 1)
    place_finder(mod, reserved, 1, n - 6)
    place_finder(mod, reserved, n - 6, 1)
    -- Alignment patterns (skip those overlapping finders)
    local centres = _align_tbl[version]
    for _, cr in ipairs(centres) do
        for _, cc in ipairs(centres) do
            local r1, c1 = cr + 1, cc + 1   -- 1-based
            -- Skip if landing on a finder area (corners).
            local skip = false
            if (cr <= 7 and cc <= 7)
            or (cr <= 7 and cc >= n - 8)
            or (cr >= n - 8 and cc <= 7) then
                skip = true
            end
            if not skip then place_alignment(mod, reserved, r1, c1) end
        end
    end
    place_timing(mod, reserved)
    place_dark_module(mod, reserved, version)
    reserve_format_areas(mod, reserved, version)
    return mod, reserved, n
end

-- Place data bits zig-zagging right-to-left up/down. Skips reserved cells
-- and the vertical timing column at column 7 (1-based).
local function place_data_bits(mod, reserved, bits)
    local n = #mod
    local idx = 1
    local going_up = true
    local col = n
    while col >= 1 do
        if col == 7 then col = col - 1 end  -- skip timing
        for step = 0, n - 1 do
            local r = going_up and (n - step) or (1 + step)
            for off = 0, 1 do
                local c = col - off
                if c >= 1 and not reserved[r][c] then
                    mod[r][c] = bits[idx] == 1
                    idx = idx + 1
                end
            end
        end
        going_up = not going_up
        col = col - 2
    end
end

-- ===== Mask + format/version info =======================================

local function mask_at(mask, r, c)
    -- r,c are 0-based here for the formula table.
    if mask == 0 then return (r + c) % 2 == 0 end
    if mask == 1 then return r % 2 == 0 end
    if mask == 2 then return c % 3 == 0 end
    if mask == 3 then return (r + c) % 3 == 0 end
    if mask == 4 then return (math.floor(r / 2) + math.floor(c / 3)) % 2 == 0 end
    if mask == 5 then return ((r * c) % 2) + ((r * c) % 3) == 0 end
    if mask == 6 then return (((r * c) % 2) + ((r * c) % 3)) % 2 == 0 end
    if mask == 7 then return (((r + c) % 2) + ((r * c) % 3)) % 2 == 0 end
end

local function apply_mask(mod, reserved, mask)
    local n = #mod
    for r = 1, n do
        for c = 1, n do
            if not reserved[r][c] then
                if mask_at(mask, r - 1, c - 1) then
                    mod[r][c] = not mod[r][c]
                end
            end
        end
    end
end

-- Format information BCH(15,5).
local function format_bits(ecc, mask)
    local ecc_bits = ({ L = 1, M = 0, Q = 3, H = 2 })[ecc]
    local data = bor(lshift(ecc_bits, 3), mask)
    -- BCH(15,5): generator 0x537. Compute remainder of (data << 10).
    local d = lshift(data, 10)
    for i = 14, 10, -1 do
        if band(d, lshift(1, i)) ~= 0 then
            d = bxor(d, lshift(0x537, i - 10))
        end
    end
    local fmt = bor(lshift(data, 10), d)
    return bxor(fmt, 0x5412)
end

-- Version information BCH(18,6). Returns 18-bit int (only for V >= 7).
local function version_info_bits(v)
    local d = lshift(v, 12)
    for i = 17, 12, -1 do
        if band(d, lshift(1, i)) ~= 0 then
            d = bxor(d, lshift(0x1F25, i - 12))
        end
    end
    return bor(lshift(v, 12), d)
end

local function place_format_info(mod, ecc, mask)
    local n = #mod
    local f = format_bits(ecc, mask)
    -- Strip 1: around top-left (rows 1..9 col 9, and row 9 cols 1..9).
    for i = 0, 5 do
        mod[i + 1][9] = band(rshift(f, i), 1) == 1
    end
    mod[7 + 1][9] = band(rshift(f, 6), 1) == 1
    mod[9][9]    = band(rshift(f, 7), 1) == 1
    mod[9][7 + 1] = band(rshift(f, 8), 1) == 1
    for i = 9, 14 do
        mod[9][15 - i] = band(rshift(f, i), 1) == 1
    end
    -- Strip 2: bottom-left col 9 (bits 0..6) + top-right row 9 (bits 7..14).
    for i = 0, 6 do
        mod[n - i][9] = band(rshift(f, i), 1) == 1
    end
    for i = 7, 14 do
        mod[9][n - 14 + i] = band(rshift(f, i), 1) == 1
    end
end

local function place_version_info(mod, version)
    if version < 7 then return end
    local n = #mod
    local vbits = version_info_bits(version)
    for i = 0, 17 do
        local b = band(rshift(vbits, i), 1) == 1
        local r = math.floor(i / 3)
        local c = i % 3 + n - 10
        mod[r + 1][c + 1] = b
        mod[c + 1][r + 1] = b
    end
end

-- ===== Mask penalty (ISO 18004 7.8.3) ===================================

local function score_mask(mod)
    local n = #mod
    local total = 0
    -- N1: runs of >=5 same-colour modules in rows/cols.
    for r = 1, n do
        local last, run = nil, 0
        for c = 1, n do
            local cur = mod[r][c]
            if cur == last then run = run + 1
            else
                if run >= 5 then total = total + 3 + (run - 5) end
                last = cur; run = 1
            end
        end
        if run >= 5 then total = total + 3 + (run - 5) end
    end
    for c = 1, n do
        local last, run = nil, 0
        for r = 1, n do
            local cur = mod[r][c]
            if cur == last then run = run + 1
            else
                if run >= 5 then total = total + 3 + (run - 5) end
                last = cur; run = 1
            end
        end
        if run >= 5 then total = total + 3 + (run - 5) end
    end
    -- N2: 2x2 blocks of the same colour.
    for r = 1, n - 1 do
        for c = 1, n - 1 do
            if mod[r][c] == mod[r][c + 1]
            and mod[r][c] == mod[r + 1][c]
            and mod[r][c] == mod[r + 1][c + 1] then
                total = total + 3
            end
        end
    end
    -- N3: 1:1:3:1:1 finder-look-alike patterns (in rows and cols).
    -- Approximate match: 7-modules sliding window check.
    local pat1 = { true, false, true, true, true, false, true,
                   false, false, false, false }
    local pat2 = { false, false, false, false,
                   true, false, true, true, true, false, true }
    local function match_window(arr, off, pat)
        for i = 1, #pat do
            if arr[off + i - 1] ~= pat[i] then return false end
        end
        return true
    end
    for r = 1, n do
        local row = mod[r]
        for c = 1, n - 10 do
            if match_window(row, c, pat1) or match_window(row, c, pat2) then
                total = total + 40
            end
        end
    end
    for c = 1, n do
        local col = {}
        for r = 1, n do col[r] = mod[r][c] end
        for r = 1, n - 10 do
            if match_window(col, r, pat1) or match_window(col, r, pat2) then
                total = total + 40
            end
        end
    end
    -- N4: balance dark/light.
    local dark = 0
    for r = 1, n do for c = 1, n do if mod[r][c] then dark = dark + 1 end end end
    local pct = math.floor(dark * 100 / (n * n))
    local prev5 = math.floor(pct / 5) * 5
    local next5 = prev5 + 5
    local k = math.min(math.abs(prev5 - 50), math.abs(next5 - 50)) / 5
    total = total + k * 10
    return total
end

-- Deep-copy a matrix (booleans only).
local function copy_matrix(m)
    local out = {}
    for r = 1, #m do
        out[r] = {}
        for c = 1, #m[r] do out[r][c] = m[r][c] end
    end
    return out
end

-- ===== Public: generate =================================================

function M.generate(text, opts)
    opts = opts or {}
    local ecc = opts.ecc or "M"
    if not _ecc_tbl[1][ecc] then error("qrcode: bad ecc " .. tostring(ecc)) end
    local mode = opts.mode or detect_mode(text)
    local version = opts.version or smallest_version(mode, #text, ecc)
    if version < 1 or version > 40 then
        error("qrcode: version out of range " .. tostring(version))
    end

    -- Build the bit stream.
    local buf = new_bit_buffer()
    buf.push(mode_indicator(mode), 4)
    buf.push(#text, cci_width(mode, version))
    if mode == "numeric" then        encode_numeric(buf, text)
    elseif mode == "alphanumeric" then encode_alphanumeric(buf, text)
    else                              encode_byte(buf, text) end

    local cap_bits = version_data_capacity(version, ecc) * 8
    if buf.n > cap_bits then
        error("qrcode: payload exceeds capacity at version " .. version
              .. " ecc " .. ecc)
    end
    buf.pad_to_codewords(cap_bits)
    local data_bytes = buf.to_bytes()
    -- Fill with alternating EC/11 pad bytes
    local need = version_data_capacity(version, ecc)
    local pi = 0
    while #data_bytes < need do
        data_bytes[#data_bytes + 1] = _PAD_BYTES[(pi % 2) + 1]
        pi = pi + 1
    end

    local interleaved = build_final_codewords(data_bytes, version, ecc)

    -- Expand bytes to bits (MSB first), then add the trailing remainder bits
    -- (the 0..7 padding bits required by versions where total bits aren't a
    -- multiple of 8 -- always present in the final codeword position).
    local bits = {}
    for i = 1, #interleaved do
        local b = interleaved[i]
        for bi = 7, 0, -1 do bits[#bits + 1] = band(rshift(b, bi), 1) end
    end
    -- Remainder bits per version (table 1).
    local rem_tbl = { [1]=0, [2]=7, [3]=7, [4]=7, [5]=7, [6]=7,
                      [7]=0, [8]=0, [9]=0, [10]=0, [11]=0, [12]=0, [13]=0,
                      [14]=3, [15]=3, [16]=3, [17]=3, [18]=3, [19]=3, [20]=3,
                      [21]=4, [22]=4, [23]=4, [24]=4, [25]=4, [26]=4, [27]=4,
                      [28]=3, [29]=3, [30]=3, [31]=3, [32]=3, [33]=3, [34]=3,
                      [35]=0, [36]=0, [37]=0, [38]=0, [39]=0, [40]=0 }
    for _ = 1, rem_tbl[version] do bits[#bits + 1] = 0 end

    local base_mod, base_reserved = place_function_patterns(version)
    place_data_bits(base_mod, base_reserved, bits)

    -- Pick mask (or use forced one).
    local best_mask, best_score, best_mod = 0, math.huge, nil
    if opts.mask then
        local mcand = copy_matrix(base_mod)
        apply_mask(mcand, base_reserved, opts.mask)
        place_format_info(mcand, ecc, opts.mask)
        place_version_info(mcand, version)
        best_mask, best_mod = opts.mask, mcand
    else
        for mask = 0, 7 do
            local mcand = copy_matrix(base_mod)
            apply_mask(mcand, base_reserved, mask)
            place_format_info(mcand, ecc, mask)
            place_version_info(mcand, version)
            local score = score_mask(mcand)
            if score < best_score then
                best_score = score
                best_mask = mask
                best_mod = mcand
            end
        end
    end

    return {
        size    = version_size(version),
        modules = best_mod,
        version = version,
        ecc     = ecc,
        mask    = best_mask,
        mode    = mode,
    }
end

-- ===== Renderers ========================================================

function M.to_svg(matrix, opts)
    opts = opts or {}
    local scale   = opts.scale or 8
    local padding = opts.padding or 4
    local fg = opts.fg or "#000000"
    local bg = opts.bg or "#FFFFFF"
    local n = matrix.size
    local total = (n + padding * 2) * scale
    local parts = {}
    parts[#parts + 1] = string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        .. 'viewBox="0 0 %d %d" shape-rendering="crispEdges">',
        total, total, total, total)
    parts[#parts + 1] = string.format(
        '<rect width="100%%" height="100%%" fill="%s"/>', bg)
    parts[#parts + 1] = string.format('<path fill="%s" d="', fg)
    for r = 1, n do
        local row = matrix.modules[r]
        local c = 1
        while c <= n do
            if row[c] then
                local start = c
                while c <= n and row[c] do c = c + 1 end
                local x = (start - 1 + padding) * scale
                local y = (r - 1 + padding) * scale
                local w = (c - start) * scale
                parts[#parts + 1] = string.format("M%d %dh%dv%dh-%dz",
                    x, y, w, scale, w)
            else
                c = c + 1
            end
        end
    end
    parts[#parts + 1] = '"/></svg>'
    return table.concat(parts)
end

function M.to_image(matrix, scale, padding)
    scale = scale or 8
    padding = padding or 4
    local n = matrix.size
    local total = (n + padding * 2) * scale
    -- BGRA, white background, black modules.
    local bytes = {}
    for i = 1, total * total * 4 do bytes[i] = 0xFF end
    local function set(x, y)
        local off = ((y - 1) * total + (x - 1)) * 4 + 1
        bytes[off]     = 0
        bytes[off + 1] = 0
        bytes[off + 2] = 0
        bytes[off + 3] = 0xFF
    end
    for r = 1, n do
        for c = 1, n do
            if matrix.modules[r][c] then
                local x0 = (c - 1 + padding) * scale + 1
                local y0 = (r - 1 + padding) * scale + 1
                for dy = 0, scale - 1 do
                    for dx = 0, scale - 1 do
                        set(x0 + dx, y0 + dy)
                    end
                end
            end
        end
    end
    return string.char(table.unpack and table.unpack(bytes) or unpack(bytes)),
           total, total
end

-- Sometimes the byte table is huge (>8000 args won't unpack). Provide an
-- explicit slow-path that builds via concat.
function M.to_image_bytes(matrix, scale, padding)
    scale = scale or 8
    padding = padding or 4
    local n = matrix.size
    local total = (n + padding * 2) * scale
    local chunks = {}
    for y = 1, total do
        local row = {}
        for x = 1, total do
            local mr = math.floor((y - 1) / scale) - padding + 1
            local mc = math.floor((x - 1) / scale) - padding + 1
            local dark = false
            if mr >= 1 and mr <= n and mc >= 1 and mc <= n then
                dark = matrix.modules[mr][mc]
            end
            if dark then row[#row + 1] = "\0\0\0\255"
            else         row[#row + 1] = "\255\255\255\255" end
        end
        chunks[#chunks + 1] = table.concat(row)
    end
    return table.concat(chunks), total, total
end

-- ===== Capacity helpers =================================================

function M.numeric_capacity(v, ecc)
    return math.floor(version_data_capacity(v, ecc) * 8 / 10) * 3
end
function M.alphanumeric_capacity(v, ecc)
    return math.floor(version_data_capacity(v, ecc) * 8 / 11) * 2
end
function M.byte_capacity(v, ecc)
    return version_data_capacity(v, ecc) - 1 -- approximate (minus mode+CCI header)
end

return M
