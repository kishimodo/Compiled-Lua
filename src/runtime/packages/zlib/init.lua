-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- zlib -- DEFLATE / zlib / gzip compress + decompress in pure Lua.
--
-- Reference documents:
--   RFC 1951 -- DEFLATE
--   RFC 1950 -- zlib container
--   RFC 1952 -- gzip container
--
-- Public surface:
--   zlib.deflate(bytes, level?)        -> bytes   (raw DEFLATE)
--   zlib.inflate(bytes)                -> bytes   (raw DEFLATE)
--   zlib.zlib_compress(bytes, level?)  -> bytes   (zlib wrapper -- 2-byte header + adler32)
--   zlib.zlib_decompress(bytes)        -> bytes
--   zlib.gzip_compress(bytes, level?, opts?)   -> bytes  (RFC 1952 wrapper + CRC32)
--   zlib.gzip_decompress(bytes)        -> bytes, info_table
--   zlib.crc32(bytes, init?)           -> u32
--   zlib.adler32(bytes, init?)         -> u32
--   zlib.deflate_stream()              -> stream object {:write(s), :finish()->bytes}
--   zlib.inflate_stream()              -> stream object {:write(s), :finish()->bytes}
--
-- level: 0 emits stored blocks (no compression), 1..9 use a LZ77+Huffman
-- encoder. Level numbers above 1 increase the match-search window but
-- otherwise use the same algorithm -- ratio improvement plateaus quickly
-- on a Lua impl. Default level is 6 (matches stock zlib).
--
-- Native path:
--   On first use, the module tries ffi.load("zlib1") (Windows stock name
--   for zlib's DLL build). If that succeeds, all zlib_/gzip_/inflate/
--   deflate calls dispatch to the native compress2/uncompress entry
--   points. Falls back to the pure-Lua path otherwise.

local ffi      = ffi
local bit_band = bit.band
local bit_bor  = bit.bor
local bit_bxor = bit.bxor
local bit_lsh  = bit.lshift
local bit_rsh  = bit.rshift

local M = {}

-- ===== CRC-32 / adler32 ==================================================

local _crc_table
local function build_crc_table()
    _crc_table = {}
    for n = 0, 255 do
        local c = n
        for _ = 1, 8 do
            if bit_band(c, 1) == 1 then
                c = bit_bxor(bit_rsh(c, 1), 0xEDB88320)
            else
                c = bit_rsh(c, 1)
            end
        end
        _crc_table[n] = c
    end
end

function M.crc32(bytes, init)
    if _crc_table == nil then build_crc_table() end
    local c = bit_bxor(init or 0, 0xFFFFFFFF)
    for i = 1, #bytes do
        c = bit_bxor(bit_rsh(c, 8), _crc_table[bit_band(bit_bxor(c, bytes:byte(i)), 0xFF)])
    end
    return bit_band(bit_bxor(c, 0xFFFFFFFF), 0xFFFFFFFF)
end

function M.adler32(bytes, init)
    -- adler32 modulo 65521. Loop unrolled per 5552-byte run to avoid
    -- the mod inside the inner loop (Mark Adler's NMAX trick).
    local s1, s2
    if init then
        s1 = bit_band(init, 0xFFFF)
        s2 = bit_band(bit_rsh(init, 16), 0xFFFF)
    else
        s1, s2 = 1, 0
    end
    local len = #bytes
    local i = 1
    while i <= len do
        local n = math.min(5552, len - i + 1)
        local last = i + n - 1
        for j = i, last do
            s1 = s1 + bytes:byte(j)
            s2 = s2 + s1
        end
        s1 = s1 % 65521
        s2 = s2 % 65521
        i = last + 1
    end
    return bit_bor(bit_lsh(s2, 16), s1)
end

-- ===== bit-level reader (LSB-first, as required by DEFLATE) ==============

local function make_bitreader(s)
    local pos   = 1   -- 1-based byte index of NEXT byte to consume
    local buf   = 0   -- accumulator
    local nbits = 0   -- valid bits in accumulator
    return {
        -- Fill at least n bits into the accumulator.
        fill = function(n)
            while nbits < n do
                if pos > #s then
                    -- Treat past-EOF as zeros; the caller's structural
                    -- error path catches genuine truncation when it
                    -- runs out of literals or hits an invalid code.
                    break
                end
                buf = bit_bor(buf, bit_lsh(s:byte(pos), nbits))
                pos = pos + 1
                nbits = nbits + 8
            end
        end,
        -- Read n bits (n <= 24) LSB-first and consume them.
        read = function(self, n)
            self.fill(n)
            local v = bit_band(buf, bit_lsh(1, n) - 1)
            buf   = bit_rsh(buf, n)
            nbits = nbits - n
            if nbits < 0 then nbits = 0 end
            return v
        end,
        -- Drop fractional bits and return the current 1-based byte cursor.
        byte_align = function()
            local drop = nbits % 8
            buf   = bit_rsh(buf, drop)
            nbits = nbits - drop
            -- buf now holds 0..3 whole bytes we already consumed off the
            -- stream; unread them so byte ops see fresh bytes.
            while nbits >= 8 do
                pos   = pos - 1
                nbits = nbits - 8
            end
            buf = 0; nbits = 0
            return pos
        end,
        -- Return current 1-based byte position (advance only via consume).
        get_pos = function() return pos end,
        consume_bytes = function(self, n)
            buf = 0; nbits = 0
            local start = pos
            pos = pos + n
            return s:sub(start, pos - 1)
        end,
    }
end

-- ===== Huffman decoding ==================================================
--
-- DEFLATE Huffman codes are canonical: derived solely from each symbol's
-- bit length. Build a (length, code) -> symbol table and decode by
-- reading one bit at a time until a match is found. This is naive but
-- correct; an inflate of 1MB is sub-second on LuaJIT which is fine
-- given native fast-path covers anyone who cares about speed.

local function build_huffman_table(lengths)
    -- Returns a function decode(reader) -> symbol
    local max_len = 0
    for _, l in ipairs(lengths) do if l > max_len then max_len = l end end
    if max_len == 0 then
        return function() error("inflate: empty huffman table") end
    end
    -- bl_count[l] = number of codes of length l
    local bl_count = {}
    for l = 0, max_len do bl_count[l] = 0 end
    for _, l in ipairs(lengths) do
        if l > 0 then bl_count[l] = bl_count[l] + 1 end
    end
    -- next_code[l] = smallest code of length l, canonical
    local code = 0
    local next_code = {}
    for l = 1, max_len do
        code = (code + bl_count[l - 1]) * 2
        next_code[l] = code
    end
    -- code -> sym map, indexed by length
    local by_len = {}  -- by_len[l] = { [code] = sym }
    for l = 1, max_len do by_len[l] = {} end
    for sym = 1, #lengths do
        local l = lengths[sym]
        if l > 0 then
            by_len[l][next_code[l]] = sym - 1
            next_code[l] = next_code[l] + 1
        end
    end
    return function(br)
        -- Read bit by bit, MSB-first within the code (DEFLATE quirk:
        -- bits are stored LSB-first in the byte stream, but Huffman
        -- codes are reconstructed MSB-first as they would be packed).
        local c = 0
        for l = 1, max_len do
            c = bit_bor(bit_lsh(c, 1), br:read(1))
            local s = by_len[l][c]
            if s ~= nil then return s end
        end
        error("inflate: invalid huffman code")
    end
end

-- Fixed Huffman tables (RFC 1951 section 3.2.6).
local _fixed_lit_decode, _fixed_dist_decode
local function build_fixed_tables()
    local lit_lens = {}
    for s = 0, 287 do
        if     s <= 143 then lit_lens[s + 1] = 8
        elseif s <= 255 then lit_lens[s + 1] = 9
        elseif s <= 279 then lit_lens[s + 1] = 7
        else                 lit_lens[s + 1] = 8 end
    end
    local dist_lens = {}
    for s = 1, 30 do dist_lens[s] = 5 end
    _fixed_lit_decode  = build_huffman_table(lit_lens)
    _fixed_dist_decode = build_huffman_table(dist_lens)
end

-- DEFLATE length / distance tables (RFC 1951 section 3.2.5).
local _LEN_BASE = {
    [257] = 3,  [258] = 4,  [259] = 5,  [260] = 6,  [261] = 7,  [262] = 8,
    [263] = 9,  [264] = 10, [265] = 11, [266] = 13, [267] = 15, [268] = 17,
    [269] = 19, [270] = 23, [271] = 27, [272] = 31, [273] = 35, [274] = 43,
    [275] = 51, [276] = 59, [277] = 67, [278] = 83, [279] = 99, [280] = 115,
    [281] = 131, [282] = 163, [283] = 195, [284] = 227, [285] = 258,
}
local _LEN_EXTRA = {
    [257]=0,[258]=0,[259]=0,[260]=0,[261]=0,[262]=0,[263]=0,[264]=0,
    [265]=1,[266]=1,[267]=1,[268]=1,
    [269]=2,[270]=2,[271]=2,[272]=2,
    [273]=3,[274]=3,[275]=3,[276]=3,
    [277]=4,[278]=4,[279]=4,[280]=4,
    [281]=5,[282]=5,[283]=5,[284]=5,
    [285]=0,
}
local _DIST_BASE = {
    [0]=1,[1]=2,[2]=3,[3]=4,[4]=5,[5]=7,[6]=9,[7]=13,
    [8]=17,[9]=25,[10]=33,[11]=49,[12]=65,[13]=97,[14]=129,[15]=193,
    [16]=257,[17]=385,[18]=513,[19]=769,[20]=1025,[21]=1537,
    [22]=2049,[23]=3073,[24]=4097,[25]=6145,[26]=8193,[27]=12289,
    [28]=16385,[29]=24577,
}
local _DIST_EXTRA = {
    [0]=0,[1]=0,[2]=0,[3]=0,
    [4]=1,[5]=1,
    [6]=2,[7]=2,
    [8]=3,[9]=3,
    [10]=4,[11]=4,
    [12]=5,[13]=5,
    [14]=6,[15]=6,
    [16]=7,[17]=7,
    [18]=8,[19]=8,
    [20]=9,[21]=9,
    [22]=10,[23]=10,
    [24]=11,[25]=11,
    [26]=12,[27]=12,
    [28]=13,[29]=13,
}

-- Code-length-code permutation for dynamic huffman headers (RFC 1951
-- section 3.2.7).
local _CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function decode_block(br, out, get_lit, get_dist)
    while true do
        local sym = get_lit(br)
        if sym < 256 then
            out[#out + 1] = string.char(sym)
        elseif sym == 256 then
            return  -- end of block
        else
            local lbase  = _LEN_BASE[sym]
            local lextra = _LEN_EXTRA[sym]
            local length = lbase + (lextra > 0 and br:read(lextra) or 0)
            local dsym   = get_dist(br)
            local dbase  = _DIST_BASE[dsym]
            local dextra = _DIST_EXTRA[dsym]
            local dist   = dbase + (dextra > 0 and br:read(dextra) or 0)
            -- Need to materialise from the already-emitted output. Out
            -- is a table of single-character chunks (or longer chunks
            -- when we replay a back-reference); flatten to a string
            -- view by walking from the tail. For correctness simplicity
            -- we just concat the tail enough times to satisfy the
            -- look-back -- inflater perf isn't a target here.
            local current = table.concat(out)
            local total = #current
            if dist > total then
                error("inflate: distance out of range")
            end
            local start = total - dist + 1
            local copy
            if length <= dist then
                -- Pure back-reference, no self-overlap.
                copy = current:sub(start, start + length - 1)
            else
                -- Run-length style overlap (length > dist): each output byte
                -- references a byte `dist` positions back, INCLUDING bytes we
                -- emit during this very copy. Read from a fixed anchor
                -- (total - dist) into the growing `src` so the freshly written
                -- bytes are visible. The previous version advanced the read
                -- index twice per iteration (it added `i` AND incremented
                -- src_len), so it raced past the data and corrupted every
                -- overlapping match (e.g. deflate->inflate of "aaaa" gave "aa").
                local pieces = {}
                local src = current
                for i = 1, length do
                    local p = ( total - dist ) + i
                    pieces[i] = src:sub(p, p)
                    src = src .. pieces[i]
                end
                copy = table.concat(pieces)
            end
            out[#out + 1] = copy
        end
    end
end

local function decode_dynamic_tables(br)
    local hlit  = br:read(5) + 257
    local hdist = br:read(5) + 1
    local hclen = br:read(4) + 4
    -- Read code-length code lengths in _CL_ORDER permutation.
    local cl_lens = {}
    for i = 1, 19 do cl_lens[i] = 0 end
    for i = 1, hclen do
        cl_lens[_CL_ORDER[i]] = br:read(3)
    end
    local cl_decode = build_huffman_table(cl_lens)
    -- Now read hlit+hdist code lengths, with run-length escapes.
    local total = hlit + hdist
    local lens  = {}
    local i = 1
    while i <= total do
        local sym = cl_decode(br)
        if sym < 16 then
            lens[i] = sym
            i = i + 1
        elseif sym == 16 then
            local repeat_count = 3 + br:read(2)
            local v = lens[i - 1] or 0
            for _ = 1, repeat_count do lens[i] = v; i = i + 1 end
        elseif sym == 17 then
            local repeat_count = 3 + br:read(3)
            for _ = 1, repeat_count do lens[i] = 0; i = i + 1 end
        elseif sym == 18 then
            local repeat_count = 11 + br:read(7)
            for _ = 1, repeat_count do lens[i] = 0; i = i + 1 end
        else
            error("inflate: bad code-length code " .. sym)
        end
    end
    -- Split into lit-len + dist length arrays.
    local lit_lens, dist_lens = {}, {}
    for k = 1, hlit do lit_lens[k] = lens[k] end
    for k = 1, hdist do dist_lens[k] = lens[hlit + k] end
    return build_huffman_table(lit_lens), build_huffman_table(dist_lens)
end

-- ===== inflate ===========================================================

local function inflate_pure(bytes)
    if _fixed_lit_decode == nil then build_fixed_tables() end
    local br  = make_bitreader(bytes)
    local out = {}
    while true do
        local bfinal = br:read(1)
        local btype  = br:read(2)
        if btype == 0 then
            -- Stored block: align to byte, then LEN, NLEN, raw bytes.
            local pos = br.byte_align()
            if pos + 3 > #bytes then error("inflate: stored header truncated") end
            local b0, b1, b2, b3 = bytes:byte(pos, pos + 3)
            local len  = b0 + b1 * 256
            local nlen = b2 + b3 * 256
            if bit_band(bit_bxor(len, 0xFFFF), 0xFFFF) ~= nlen then
                error("inflate: stored LEN/NLEN mismatch")
            end
            -- Advance the reader past the 4 header bytes + len data bytes.
            -- We rebuild the bitreader to resume after the raw payload.
            local data_start = pos + 4
            out[#out + 1] = bytes:sub(data_start, data_start + len - 1)
            br = make_bitreader(bytes:sub(data_start + len))
        elseif btype == 1 then
            decode_block(br, out, _fixed_lit_decode, _fixed_dist_decode)
        elseif btype == 2 then
            local lit, dist = decode_dynamic_tables(br)
            decode_block(br, out, lit, dist)
        else
            error("inflate: reserved block type")
        end
        if bfinal == 1 then break end
    end
    return table.concat(out)
end

-- ===== deflate -- level 0 (stored) =======================================
--
-- A stored block is byte-aligned. Header bits: BFINAL(1), BTYPE=00(2),
-- pad to byte, then u16 LEN, u16 NLEN (one's complement), then raw
-- bytes. Max LEN per block is 65535. For empty input, emit one
-- zero-length final block.

local function deflate_stored(bytes)
    local out, n = {}, 0
    local pos, total = 1, #bytes
    if total == 0 then
        return string.char(0x01, 0x00, 0x00, 0xFF, 0xFF)
    end
    while pos <= total do
        local remaining = total - pos + 1
        local chunk = math.min(65535, remaining)
        local is_final = (chunk == remaining) and 1 or 0
        n = n + 1; out[n] = string.char(is_final)  -- BFINAL + BTYPE=00 in low 3 bits
        n = n + 1; out[n] = string.char(
            bit_band(chunk, 0xFF),
            bit_band(bit_rsh(chunk, 8), 0xFF),
            bit_band(bit_bxor(chunk, 0xFFFF), 0xFF),
            bit_band(bit_rsh(bit_bxor(chunk, 0xFFFF), 8), 0xFF))
        n = n + 1; out[n] = bytes:sub(pos, pos + chunk - 1)
        pos = pos + chunk
    end
    return table.concat(out)
end

-- ===== deflate -- level >= 1: LZ77 + fixed Huffman =======================
--
-- Uses fixed Huffman tables (BTYPE=01) so we don't need to emit the
-- table description. That sacrifices a few percent of ratio versus
-- dynamic Huffman but keeps the encoder tractable in pure Lua.
--
-- Sliding-window LZ77:
--   * Window size 32 KiB (DEFLATE max distance is 32768).
--   * Hash table maps 3-byte prefix -> linked list of positions.
--   * Greedy parse with lazy matching disabled (simpler, slightly worse).

-- Fixed Huffman bit lengths for symbol -> (code, nbits). Computed once.
local _fixed_codes  -- [sym] = { code, nbits }  (literal/length alphabet 0..287)
local _fixed_dcodes -- [sym] = 5-bit code        (distance alphabet 0..29)

local function reverse_bits(v, n)
    local r = 0
    for _ = 1, n do
        r = bit_bor(bit_lsh(r, 1), bit_band(v, 1))
        v = bit_rsh(v, 1)
    end
    return r
end

local function build_fixed_codes()
    -- Canonical code lengths (RFC 1951 section 3.2.6).
    local lengths = {}
    for s = 0, 287 do
        if     s <= 143 then lengths[s] = 8
        elseif s <= 255 then lengths[s] = 9
        elseif s <= 279 then lengths[s] = 7
        else                 lengths[s] = 8 end
    end
    -- Assign canonical codes.
    local max_len = 9
    local bl_count = {}
    for l = 0, max_len do bl_count[l] = 0 end
    for s = 0, 287 do bl_count[lengths[s]] = bl_count[lengths[s]] + 1 end
    local code = 0
    local next_code = {}
    for l = 1, max_len do
        code = (code + bl_count[l - 1]) * 2
        next_code[l] = code
    end
    _fixed_codes = {}
    for s = 0, 287 do
        local l = lengths[s]
        if l > 0 then
            _fixed_codes[s] = { reverse_bits(next_code[l], l), l }
            next_code[l] = next_code[l] + 1
        end
    end
    -- Distance alphabet: 30 codes of 5 bits each, canonical order.
    _fixed_dcodes = {}
    for s = 0, 29 do
        _fixed_dcodes[s] = reverse_bits(s, 5)
    end
end

local function length_symbol(len)
    -- Walk _LEN_BASE in reverse to find the symbol whose base <= len.
    for sym = 285, 257, -1 do
        if _LEN_BASE[sym] <= len then return sym end
    end
    error("deflate: bad length " .. len)
end

local function distance_symbol(dist)
    for sym = 29, 0, -1 do
        if _DIST_BASE[sym] <= dist then return sym end
    end
    error("deflate: bad distance " .. dist)
end

-- A tiny bit-writer (LSB-first to match DEFLATE).
local function make_bitwriter()
    local out, n = {}, 0
    local buf, nbits = 0, 0
    return {
        write = function(_, v, k)
            buf   = bit_bor(buf, bit_lsh(bit_band(v, bit_lsh(1, k) - 1), nbits))
            nbits = nbits + k
            while nbits >= 8 do
                n = n + 1; out[n] = string.char(bit_band(buf, 0xFF))
                buf   = bit_rsh(buf, 8)
                nbits = nbits - 8
            end
        end,
        align_byte = function()
            if nbits > 0 then
                n = n + 1; out[n] = string.char(bit_band(buf, 0xFF))
                buf, nbits = 0, 0
            end
        end,
        emit_raw = function(s)
            n = n + 1; out[n] = s
        end,
        finish = function()
            if nbits > 0 then
                n = n + 1; out[n] = string.char(bit_band(buf, 0xFF))
            end
            return table.concat(out)
        end,
    }
end

local function deflate_fixed(bytes, level)
    if _fixed_codes == nil then build_fixed_codes() end
    local bw = make_bitwriter()
    bw:write(1, 1)  -- BFINAL = 1 (single block; simple)
    bw:write(1, 2)  -- BTYPE = 01 -- fixed Huffman
    local len   = #bytes
    if len == 0 then
        local eob = _fixed_codes[256]
        bw:write(eob[1], eob[2])
        return bw:finish()
    end
    -- Build a position table: hash 3-byte prefix -> list of positions.
    local heads = {}  -- hash -> most-recent position
    local prev  = {}  -- position -> previous position with same hash
    local function hash3(b1, b2, b3)
        -- Rolling-ish hash: pack bytes into 17 bits then fold to 15.
        local h = bit_band(b1 * 65536 + b2 * 256 + b3, 0xFFFFFF)
        return bit_band(bit_bxor(h, bit_rsh(h, 11)), 0x7FFF)
    end
    local max_chain
    if     level <= 1 then max_chain = 4
    elseif level <= 3 then max_chain = 16
    elseif level <= 5 then max_chain = 64
    elseif level <= 7 then max_chain = 256
    else                   max_chain = 1024 end
    local pos = 1
    while pos <= len do
        local b1, b2, b3 = bytes:byte(pos, pos + 2)
        if b3 == nil or pos + 2 > len then
            -- Tail: emit remaining bytes as literals.
            for i = pos, len do
                local c = _fixed_codes[bytes:byte(i)]
                bw:write(c[1], c[2])
            end
            break
        end
        local h = hash3(b1, b2, b3)
        local best_len, best_dist = 0, 0
        local cand = heads[h]
        local chain_left = max_chain
        while cand ~= nil and chain_left > 0 do
            local dist = pos - cand
            if dist > 32768 then break end
            -- Try to extend match
            local m = 0
            local max_m = math.min(258, len - pos + 1)
            while m < max_m and bytes:byte(pos + m) == bytes:byte(cand + m) do
                m = m + 1
            end
            if m > best_len and m >= 3 then
                best_len  = m
                best_dist = dist
                if m >= 258 then break end
            end
            cand = prev[cand]
            chain_left = chain_left - 1
        end
        if best_len >= 3 then
            local lsym = length_symbol(best_len)
            local lc = _fixed_codes[lsym]
            bw:write(lc[1], lc[2])
            local lextra = _LEN_EXTRA[lsym]
            if lextra > 0 then
                bw:write(best_len - _LEN_BASE[lsym], lextra)
            end
            local dsym = distance_symbol(best_dist)
            bw:write(_fixed_dcodes[dsym], 5)
            local dextra = _DIST_EXTRA[dsym]
            if dextra > 0 then
                bw:write(best_dist - _DIST_BASE[dsym], dextra)
            end
            -- Insert hash entries for all bytes covered by the match.
            -- Only need to record the first few to keep future lookups.
            for k = 0, math.min(best_len - 1, 2) do
                local p = pos + k
                if p + 2 <= len then
                    local h2 = hash3(bytes:byte(p), bytes:byte(p + 1), bytes:byte(p + 2))
                    prev[p] = heads[h2]
                    heads[h2] = p
                end
            end
            pos = pos + best_len
        else
            -- Emit literal.
            local c = _fixed_codes[b1]
            bw:write(c[1], c[2])
            prev[pos] = heads[h]
            heads[h]  = pos
            pos = pos + 1
        end
    end
    -- End-of-block.
    local eob = _fixed_codes[256]
    bw:write(eob[1], eob[2])
    return bw:finish()
end

local function deflate_pure(bytes, level)
    level = level or 6
    if level == 0 then return deflate_stored(bytes) end
    return deflate_fixed(bytes, level)
end

-- ===== zlib container ====================================================
-- RFC 1950: CMF(1) | FLG(1) | DEFLATE | ADLER32 BE (4)

local function zlib_compress_pure(bytes, level)
    level = level or 6
    -- CMF: low nibble = method (8 = deflate), high nibble = window-size log2 minus 8.
    -- We always advertise 32k window (CINFO = 7) so CMF = 0x78.
    local cmf = 0x78
    -- FLG: level bits (FLEVEL) | FDICT=0; FCHECK chosen so (cmf*256+flg) % 31 == 0.
    local flevel
    if     level <= 1 then flevel = 0
    elseif level <= 5 then flevel = 1
    elseif level == 6 then flevel = 2
    else                   flevel = 3 end
    local flg = bit_lsh(flevel, 6)
    local check = (cmf * 256 + flg) % 31
    if check ~= 0 then flg = flg + (31 - check) end
    local raw = deflate_pure(bytes, level)
    local a = M.adler32(bytes)
    local trailer = string.char(
        bit_band(bit_rsh(a, 24), 0xFF),
        bit_band(bit_rsh(a, 16), 0xFF),
        bit_band(bit_rsh(a,  8), 0xFF),
        bit_band(a, 0xFF))
    return string.char(cmf, flg) .. raw .. trailer
end

local function zlib_decompress_pure(bytes)
    if #bytes < 6 then error("zlib: input too short") end
    local cmf = bytes:byte(1)
    local flg = bytes:byte(2)
    if bit_band(cmf, 0x0F) ~= 8 then
        error(string.format("zlib: unknown method %d", bit_band(cmf, 0x0F)))
    end
    if (cmf * 256 + flg) % 31 ~= 0 then
        error("zlib: header checksum invalid")
    end
    if bit_band(flg, 0x20) ~= 0 then
        error("zlib: preset dictionary not supported")
    end
    local raw = bytes:sub(3, #bytes - 4)
    return inflate_pure(raw)
end

-- ===== gzip container ====================================================
-- RFC 1952: fixed 10-byte header + optional extras + DEFLATE + CRC32 + ISIZE

local function gzip_compress_pure(bytes, level, opts)
    opts = opts or {}
    level = level or 6
    local hdr = string.char(
        0x1F, 0x8B,            -- magic
        0x08,                  -- method = deflate
        0x00,                  -- flags (no extras / no name / no comment)
        0, 0, 0, 0,            -- mtime = 0 (caller can override via opts)
        level >= 9 and 0x02 or (level <= 1 and 0x04 or 0x00),
        0xFF)                  -- OS = unknown
    if opts.mtime then
        local mt = opts.mtime
        hdr = string.char(0x1F, 0x8B, 0x08, 0x00,
            bit_band(mt, 0xFF),
            bit_band(bit_rsh(mt,  8), 0xFF),
            bit_band(bit_rsh(mt, 16), 0xFF),
            bit_band(bit_rsh(mt, 24), 0xFF),
            level >= 9 and 0x02 or (level <= 1 and 0x04 or 0x00),
            0xFF)
    end
    local raw  = deflate_pure(bytes, level)
    local crc  = M.crc32(bytes)
    local size = #bytes
    local trailer = string.char(
        bit_band(crc, 0xFF),
        bit_band(bit_rsh(crc,  8), 0xFF),
        bit_band(bit_rsh(crc, 16), 0xFF),
        bit_band(bit_rsh(crc, 24), 0xFF),
        bit_band(size, 0xFF),
        bit_band(bit_rsh(size,  8), 0xFF),
        bit_band(bit_rsh(size, 16), 0xFF),
        bit_band(bit_rsh(size, 24), 0xFF))
    return hdr .. raw .. trailer
end

local function gzip_decompress_pure(bytes)
    if #bytes < 18 then error("gzip: input too short") end
    if bytes:byte(1) ~= 0x1F or bytes:byte(2) ~= 0x8B then
        error("gzip: bad magic")
    end
    if bytes:byte(3) ~= 0x08 then
        error("gzip: only deflate method supported")
    end
    local flg = bytes:byte(4)
    local mtime = bytes:byte(5) + bytes:byte(6) * 256
                + bytes:byte(7) * 65536 + bytes:byte(8) * 16777216
    local pos = 11
    local info = { mtime = mtime, name = nil, comment = nil }
    if bit_band(flg, 0x04) ~= 0 then  -- FEXTRA
        local xlen = bytes:byte(pos) + bytes:byte(pos + 1) * 256
        pos = pos + 2 + xlen
    end
    if bit_band(flg, 0x08) ~= 0 then  -- FNAME (zero-terminated)
        local s = pos
        while bytes:byte(pos) ~= 0 do pos = pos + 1 end
        info.name = bytes:sub(s, pos - 1)
        pos = pos + 1
    end
    if bit_band(flg, 0x10) ~= 0 then  -- FCOMMENT
        local s = pos
        while bytes:byte(pos) ~= 0 do pos = pos + 1 end
        info.comment = bytes:sub(s, pos - 1)
        pos = pos + 1
    end
    if bit_band(flg, 0x02) ~= 0 then  -- FHCRC -- 2 bytes
        pos = pos + 2
    end
    local raw = bytes:sub(pos, #bytes - 8)
    local out = inflate_pure(raw)
    -- Verify trailer.
    local t = #bytes - 7
    local crc_stored = bytes:byte(t) + bytes:byte(t+1) * 256
                     + bytes:byte(t+2) * 65536 + bytes:byte(t+3) * 16777216
    local isize      = bytes:byte(t+4) + bytes:byte(t+5) * 256
                     + bytes:byte(t+6) * 65536 + bytes:byte(t+7) * 16777216
    if isize ~= #out then
        error(string.format("gzip: ISIZE mismatch (%d vs %d)", isize, #out))
    end
    local crc_calc = M.crc32(out)
    if crc_calc ~= crc_stored then
        error("gzip: CRC mismatch")
    end
    info.crc32 = crc_stored
    info.isize = isize
    return out, info
end

-- ===== Native dispatch (zlib1.dll if present) ============================
-- We use the standard compress2 / uncompress entry points which take a
-- Bytef* in/out + uLongf* len. compress2 lets us choose level; for
-- gzip we still wrap the DEFLATE output by hand to control headers.

local _native_state -- nil = unprobed, false = absent, table = loaded fns

ffi.cdef[[
typedef unsigned char  zlib_Bytef;
typedef unsigned long  zlib_uLongf;
typedef unsigned long  zlib_uLong;
typedef unsigned int   zlib_uInt;
typedef int            zlib_int;

zlib_int compress (zlib_Bytef *dest, zlib_uLongf *destLen,
                   const zlib_Bytef *source, zlib_uLong sourceLen);
zlib_int compress2(zlib_Bytef *dest, zlib_uLongf *destLen,
                   const zlib_Bytef *source, zlib_uLong sourceLen,
                   zlib_int level);

zlib_int uncompress (zlib_Bytef *dest, zlib_uLongf *destLen,
                     const zlib_Bytef *source, zlib_uLong sourceLen);
zlib_int uncompress2(zlib_Bytef *dest, zlib_uLongf *destLen,
                     const zlib_Bytef *source, zlib_uLongf *sourceLen);

zlib_uLong compressBound(zlib_uLong sourceLen);

zlib_uLong adler32(zlib_uLong adler, const zlib_Bytef *buf, zlib_uLong len);
zlib_uLong crc32  (zlib_uLong crc,   const zlib_Bytef *buf, zlib_uLong len);

/* Streaming z_stream structure -- layout per zlib.h. We only touch a
   handful of fields (next_in/avail_in/next_out/avail_out/total_in/total_out)
   but the full struct has to be declared so the size is right. */
typedef struct zlib_z_stream_s {
    const zlib_Bytef *next_in;
    zlib_uInt         avail_in;
    zlib_uLong        total_in;
    zlib_Bytef       *next_out;
    zlib_uInt         avail_out;
    zlib_uLong        total_out;
    const char       *msg;
    void             *state;
    void             *zalloc;
    void             *zfree;
    void             *opaque;
    zlib_int          data_type;
    zlib_uLong        adler;
    zlib_uLong        reserved;
} zlib_z_stream;

zlib_int deflateInit2_(zlib_z_stream *strm, zlib_int level, zlib_int method,
                       zlib_int windowBits, zlib_int memLevel, zlib_int strategy,
                       const char *version, zlib_int stream_size);
zlib_int deflate     (zlib_z_stream *strm, zlib_int flush);
zlib_int deflateEnd  (zlib_z_stream *strm);
zlib_uLong deflateBound(zlib_z_stream *strm, zlib_uLong sourceLen);

zlib_int inflateInit2_(zlib_z_stream *strm, zlib_int windowBits,
                       const char *version, zlib_int stream_size);
zlib_int inflate     (zlib_z_stream *strm, zlib_int flush);
zlib_int inflateEnd  (zlib_z_stream *strm);

const char *zlibVersion(void);
]]

local function probe_native()
    if _native_state ~= nil then return _native_state end
    local override = os.getenv("LUAVM_ZLIB_DLL")
    local names    = { "zlibwapi", "zlib1", "zlib", "libz" }
    if override and override ~= "" then
        table.insert(names, 1, override)
    end
    local lib
    for _, n in ipairs(names) do
        local ok, l = pcall(ffi.load, n)
        if ok then lib = l; break end
    end
    if lib == nil then
        _native_state = false
        return false
    end
    _native_state = { lib = lib }
    return _native_state
end

local function zlib_compress_native(bytes, level)
    local ns = probe_native()
    if not ns then return nil end
    level = level or 6
    local bound = tonumber(ns.lib.compressBound(#bytes))
    local out   = ffi.new("zlib_Bytef[?]", bound)
    local olen  = ffi.new("zlib_uLongf[1]", bound)
    local rc    = ns.lib.compress2(out, olen, bytes, #bytes, level)
    if rc ~= 0 then return nil end
    return ffi.string(out, olen[0])
end

local function zlib_decompress_native(bytes, max_size)
    local ns = probe_native()
    if not ns then return nil end
    max_size = max_size or (#bytes * 1024)  -- generous default
    local out  = ffi.new("zlib_Bytef[?]", max_size)
    local olen = ffi.new("zlib_uLongf[1]", max_size)
    local rc = ns.lib.uncompress(out, olen, bytes, #bytes)
    if rc ~= 0 then return nil end
    return ffi.string(out, olen[0])
end

-- ===== Public API ========================================================

function M.deflate(bytes, level)
    return deflate_pure(bytes, level)
end

function M.inflate(bytes)
    return inflate_pure(bytes)
end

function M.zlib_compress(bytes, level)
    local n = zlib_compress_native(bytes, level)
    if n ~= nil then return n end
    return zlib_compress_pure(bytes, level)
end

function M.zlib_decompress(bytes, max_size)
    local n = zlib_decompress_native(bytes, max_size)
    if n ~= nil then return n end
    return zlib_decompress_pure(bytes)
end

function M.gzip_compress(bytes, level, opts)
    return gzip_compress_pure(bytes, level, opts)
end

function M.gzip_decompress(bytes)
    return gzip_decompress_pure(bytes)
end

-- ===== Stream API ========================================================
-- Buffers all writes then runs the single-shot encoder on :finish().
-- Real streaming would need an inflate/deflate state machine which is
-- a much larger undertaking; this API keeps callers compatible with
-- a future incremental implementation.

function M.deflate_stream(level)
    local parts, n = {}, 0
    return {
        write = function(self, s)
            n = n + 1; parts[n] = s
            return self
        end,
        finish = function() return M.deflate(table.concat(parts), level) end,
    }
end

function M.inflate_stream()
    local parts, n = {}, 0
    return {
        write = function(self, s)
            n = n + 1; parts[n] = s
            return self
        end,
        finish = function() return M.inflate(table.concat(parts)) end,
    }
end

function M.has_native()
    local ns = probe_native()
    return ns and ns ~= false and true or false
end

-- ===== Unified compress / decompress with format selector ================
-- format = "deflate" (raw, default), "zlib", "gzip"

local function _check_format(fmt)
    if fmt == nil or fmt == "deflate" or fmt == "zlib" or fmt == "gzip" then
        return fmt or "deflate"
    end
    error("zlib: unknown format '" .. tostring(fmt) .. "' (want deflate/zlib/gzip)")
end

-- Native streaming helpers used by both single-shot wrappers and the
-- stream objects below. windowBits encodes format choice in zlib:
--   8..15      -> zlib container (RFC 1950)
--  -8..-15     -> raw DEFLATE    (RFC 1951; no wrapper)
--   16+(8..15) -> gzip container (RFC 1952)

local function _window_bits(fmt)
    if fmt == "zlib"   then return 15 end
    if fmt == "gzip"   then return 31 end  -- 15 + 16
    return -15                              -- raw deflate
end

local Z_OK            = 0
local Z_STREAM_END    = 1
local Z_NEED_DICT     = 2
local Z_BUF_ERROR     = -5
local Z_NO_FLUSH      = 0
local Z_SYNC_FLUSH    = 2
local Z_FINISH        = 4
local Z_DEFLATED      = 8
local Z_DEFAULT_STRAT = 0

local function _deflate_native(bytes, level, fmt)
    local ns = probe_native()
    if not ns then return nil end
    local lib = ns.lib
    local strm = ffi.new("zlib_z_stream")
    local ver  = lib.zlibVersion()
    local rc = lib.deflateInit2_(strm, level or 6, Z_DEFLATED,
                                 _window_bits(fmt), 8, Z_DEFAULT_STRAT,
                                 ver, ffi.sizeof("zlib_z_stream"))
    if rc ~= Z_OK then return nil end
    local in_len = #bytes
    local in_buf = ffi.new("zlib_Bytef[?]", in_len > 0 and in_len or 1)
    if in_len > 0 then ffi.copy(in_buf, bytes, in_len) end
    local out_cap = tonumber(lib.deflateBound(strm, in_len))
    local out_buf = ffi.new("zlib_Bytef[?]", out_cap > 0 and out_cap or 1)
    strm.next_in   = in_buf
    strm.avail_in  = in_len
    strm.next_out  = out_buf
    strm.avail_out = out_cap
    rc = lib.deflate(strm, Z_FINISH)
    local total = tonumber(strm.total_out)
    lib.deflateEnd(strm)
    if rc ~= Z_STREAM_END then return nil end
    return ffi.string(out_buf, total)
end

local function _inflate_native(bytes, fmt)
    local ns = probe_native()
    if not ns then return nil end
    local lib = ns.lib
    local strm = ffi.new("zlib_z_stream")
    local ver  = lib.zlibVersion()
    local rc = lib.inflateInit2_(strm, _window_bits(fmt), ver,
                                 ffi.sizeof("zlib_z_stream"))
    if rc ~= Z_OK then return nil end
    local in_len = #bytes
    local in_buf = ffi.new("zlib_Bytef[?]", in_len > 0 and in_len or 1)
    if in_len > 0 then ffi.copy(in_buf, bytes, in_len) end
    strm.next_in  = in_buf
    strm.avail_in = in_len
    local CHUNK = 64 * 1024
    local pieces, np = {}, 0
    local out_chunk = ffi.new("zlib_Bytef[?]", CHUNK)
    while true do
        strm.next_out  = out_chunk
        strm.avail_out = CHUNK
        rc = lib.inflate(strm, Z_NO_FLUSH)
        if rc ~= Z_OK and rc ~= Z_STREAM_END then
            lib.inflateEnd(strm)
            return nil
        end
        local got = CHUNK - tonumber(strm.avail_out)
        if got > 0 then
            np = np + 1; pieces[np] = ffi.string(out_chunk, got)
        end
        if rc == Z_STREAM_END then break end
        if got == 0 and strm.avail_in == 0 then break end
    end
    lib.inflateEnd(strm)
    return table.concat(pieces)
end

function M.compress(bytes, level, format)
    format = _check_format(format)
    -- Try the native path first; fall back to the pure-Lua variants.
    local out = _deflate_native(bytes, level, format)
    if out ~= nil then return out end
    if format == "deflate" then
        return deflate_pure(bytes, level)
    elseif format == "zlib" then
        return zlib_compress_pure(bytes, level)
    else
        return gzip_compress_pure(bytes, level)
    end
end

function M.decompress(bytes, format)
    format = _check_format(format)
    local out = _inflate_native(bytes, format)
    if out ~= nil then return out end
    if format == "deflate" then
        return inflate_pure(bytes)
    elseif format == "zlib" then
        return zlib_decompress_pure(bytes)
    else
        return (gzip_decompress_pure(bytes))
    end
end

-- ===== Streaming compressor / decompressor ===============================
-- compressor(opts) -- opts = { level=6, format="deflate"|"zlib"|"gzip" }
-- The returned object has :update(chunk) -> bytes, and :final() -> bytes.
-- Native path drives a real z_stream so memory stays bounded; pure-Lua
-- fallback buffers internally until :final() (the existing limitation).

local _compressor_mt = {}
_compressor_mt.__index = _compressor_mt

function _compressor_mt:update(chunk)
    if self._done then error("zlib.compressor: already finalised") end
    if chunk == nil or chunk == "" then return "" end
    if self._native then
        local lib = self._native.lib
        local strm = self._strm
        local in_len = #chunk
        -- Keep the input buffer alive while in-flight.
        self._in_buf = ffi.new("zlib_Bytef[?]", in_len)
        ffi.copy(self._in_buf, chunk, in_len)
        strm.next_in  = self._in_buf
        strm.avail_in = in_len
        local CHUNK = 32 * 1024
        local pieces, np = {}, 0
        local out_chunk = ffi.new("zlib_Bytef[?]", CHUNK)
        while strm.avail_in > 0 do
            strm.next_out  = out_chunk
            strm.avail_out = CHUNK
            local rc = lib.deflate(strm, Z_NO_FLUSH)
            if rc < 0 then
                error("zlib.compressor: deflate rc=" .. rc)
            end
            local got = CHUNK - tonumber(strm.avail_out)
            if got > 0 then np = np + 1; pieces[np] = ffi.string(out_chunk, got) end
            if got == 0 then break end
        end
        return table.concat(pieces)
    else
        self._buf[#self._buf + 1] = chunk
        return ""
    end
end

function _compressor_mt:final()
    if self._done then error("zlib.compressor: already finalised") end
    self._done = true
    if self._native then
        local lib = self._native.lib
        local strm = self._strm
        strm.avail_in = 0
        local CHUNK = 32 * 1024
        local pieces, np = {}, 0
        local out_chunk = ffi.new("zlib_Bytef[?]", CHUNK)
        while true do
            strm.next_out  = out_chunk
            strm.avail_out = CHUNK
            local rc = lib.deflate(strm, Z_FINISH)
            local got = CHUNK - tonumber(strm.avail_out)
            if got > 0 then np = np + 1; pieces[np] = ffi.string(out_chunk, got) end
            if rc == Z_STREAM_END then break end
            if got == 0 then break end
        end
        lib.deflateEnd(strm)
        return table.concat(pieces)
    else
        return M.compress(table.concat(self._buf), self._level, self._format)
    end
end

function M.compressor(opts)
    opts = opts or {}
    local fmt   = _check_format(opts.format)
    local level = opts.level or 6
    local ns    = probe_native()
    local obj   = setmetatable({
        _format = fmt,
        _level  = level,
        _done   = false,
    }, _compressor_mt)
    if ns then
        local strm = ffi.new("zlib_z_stream")
        local ver  = ns.lib.zlibVersion()
        local rc = ns.lib.deflateInit2_(strm, level, Z_DEFLATED,
                                        _window_bits(fmt), 8, Z_DEFAULT_STRAT,
                                        ver, ffi.sizeof("zlib_z_stream"))
        if rc == Z_OK then
            obj._native = ns
            obj._strm   = strm
        end
    end
    if not obj._native then
        obj._buf = {}
    end
    return obj
end

local _decompressor_mt = {}
_decompressor_mt.__index = _decompressor_mt

function _decompressor_mt:update(chunk)
    if self._done then error("zlib.decompressor: already finalised") end
    if chunk == nil or chunk == "" then return "" end
    if self._native then
        local lib = self._native.lib
        local strm = self._strm
        local in_len = #chunk
        self._in_buf = ffi.new("zlib_Bytef[?]", in_len)
        ffi.copy(self._in_buf, chunk, in_len)
        strm.next_in  = self._in_buf
        strm.avail_in = in_len
        local CHUNK = 64 * 1024
        local pieces, np = {}, 0
        local out_chunk = ffi.new("zlib_Bytef[?]", CHUNK)
        while true do
            strm.next_out  = out_chunk
            strm.avail_out = CHUNK
            local rc = lib.inflate(strm, Z_NO_FLUSH)
            local got = CHUNK - tonumber(strm.avail_out)
            if got > 0 then np = np + 1; pieces[np] = ffi.string(out_chunk, got) end
            if rc == Z_STREAM_END then self._stream_end = true; break end
            if rc < 0 and rc ~= Z_BUF_ERROR then
                error("zlib.decompressor: inflate rc=" .. rc)
            end
            if got == 0 and strm.avail_in == 0 then break end
        end
        return table.concat(pieces)
    else
        self._buf[#self._buf + 1] = chunk
        return ""
    end
end

function _decompressor_mt:final()
    if self._done then error("zlib.decompressor: already finalised") end
    self._done = true
    if self._native then
        local lib = self._native.lib
        lib.inflateEnd(self._strm)
        return ""
    else
        return M.decompress(table.concat(self._buf), self._format)
    end
end

function M.decompressor(opts)
    opts = opts or {}
    local fmt = _check_format(opts.format)
    local ns  = probe_native()
    local obj = setmetatable({
        _format = fmt,
        _done   = false,
    }, _decompressor_mt)
    if ns then
        local strm = ffi.new("zlib_z_stream")
        local ver  = ns.lib.zlibVersion()
        local rc = ns.lib.inflateInit2_(strm, _window_bits(fmt), ver,
                                        ffi.sizeof("zlib_z_stream"))
        if rc == Z_OK then
            obj._native = ns
            obj._strm   = strm
        end
    end
    if not obj._native then
        obj._buf = {}
    end
    return obj
end

return M
