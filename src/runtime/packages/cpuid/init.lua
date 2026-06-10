-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- cpuid -- x86 / x86-64 CPUID feature detection.
--
-- Public surface:
--   cpuid.vendor()          -> "GenuineIntel" | "AuthenticAMD" | ...
--   cpuid.brand()           -> processor brand string ("Intel(R) Core(TM) ...")
--   cpuid.family()          -> displayed family (extended family folded in)
--   cpuid.model()           -> displayed model  (extended model folded in)
--   cpuid.stepping()        -> stepping id
--   cpuid.features()        -> { sse=, sse2=, avx=, avx2=, avx512f=, ... }
--   cpuid.has(name)         -> bool shortcut over features()
--   cpuid.cache_info()      -> { l1d=, l1d_line=, l1i=, l1i_line=, l2=, l2_line=, l3=, l3_line= }
--   cpuid.topology()        -> { logical=, physical=, smt_per_core=, cores= }
--   cpuid.os_support()      -> { xsave=, avx=, avx512= }  (XCR0 + OSXSAVE check)
--   cpuid.raw(leaf, subleaf?) -> { eax, ebx, ecx, edx }
--
-- Implementation:
--   We can't call CPUID from Lua directly, so we hand-roll a tiny x64
--   stub, allocate it via VirtualAlloc(MEM_COMMIT, PAGE_EXECUTE_READWRITE),
--   and call it through an ffi.cast'd function pointer.
--
-- W^X note: we leave the trampoline RWX. That's a real concern for malware
-- distribution but this package is for *local introspection* and the page
-- is process-private. If a caller wants W^X they can flip the trampoline
-- to PAGE_EXECUTE_READ after copy via mem.self_protect.

require "windows"
local W = require "windows"

ffi.cdef[[
typedef void (*cpuid_fn_t)(uint32_t leaf, uint32_t subleaf, uint32_t *out);
typedef uint64_t (*xgetbv_fn_t)(uint32_t xcr);
]]

local M = {}

-- ===== x86-64 stub =====================================================
--
--   ; void cpuid_fn(uint32_t leaf, uint32_t subleaf, uint32_t *out)
--   ; Microsoft x64: rcx=leaf, rdx=subleaf, r8=out
--   push rbx
--   mov  eax, ecx       ; leaf
--   mov  ecx, edx       ; subleaf
--   cpuid               ; -> eax ebx ecx edx
--   mov  [r8+ 0], eax
--   mov  [r8+ 4], ebx
--   mov  [r8+ 8], ecx
--   mov  [r8+12], edx
--   pop  rbx
--   ret

local STUB_X64 = string.char(
    0x53,                         -- push rbx
    0x89, 0xC8,                   -- mov  eax, ecx
    0x89, 0xD1,                   -- mov  ecx, edx
    0x0F, 0xA2,                   -- cpuid
    0x41, 0x89, 0x40, 0x00,       -- mov  [r8+0], eax
    0x41, 0x89, 0x58, 0x04,       -- mov  [r8+4], ebx
    0x41, 0x89, 0x48, 0x08,       -- mov  [r8+8], ecx
    0x41, 0x89, 0x50, 0x0C,       -- mov  [r8+12], edx
    0x5B,                         -- pop  rbx
    0xC3                          -- ret
)

-- ===== x86 stub =====================================================
--
--   ; void __cdecl cpuid_fn(uint32_t leaf, uint32_t subleaf, uint32_t *out)
--   ; stack: [esp+4]=leaf, [esp+8]=subleaf, [esp+12]=out
--   push ebx
--   mov  eax, [esp+8]
--   mov  ecx, [esp+12]
--   cpuid
--   mov  edi, [esp+16]    -- out (with extra +4 for the push)
--   ... actually edi needs saving too; keep it simple via a push/pop pair.

local STUB_X86 = string.char(
    0x53, 0x57,                    -- push ebx; push edi
    0x8B, 0x44, 0x24, 0x0C,        -- mov  eax, [esp+12] (leaf)
    0x8B, 0x4C, 0x24, 0x10,        -- mov  ecx, [esp+16] (subleaf)
    0x8B, 0x7C, 0x24, 0x14,        -- mov  edi, [esp+20] (out)
    0x0F, 0xA2,                    -- cpuid
    0x89, 0x07,                    -- mov  [edi], eax
    0x89, 0x5F, 0x04,              -- mov  [edi+4], ebx
    0x89, 0x4F, 0x08,              -- mov  [edi+8], ecx
    0x89, 0x57, 0x0C,              -- mov  [edi+12], edx
    0x5F, 0x5B,                    -- pop edi; pop ebx
    0xC3                           -- ret
)

local _is_x64 = ffi.sizeof("void *") == 8
local STUB = _is_x64 and STUB_X64 or STUB_X86

-- XGETBV stub (x64 MSFT ABI):
--   uint64_t xgetbv(uint32_t xcr)
--   ; rcx = xcr -> ecx
--   mov ecx, ecx          ; (already, but normalize)
--   xgetbv                ; -> EDX:EAX
--   shl rdx, 32
--   or  rax, rdx
--   ret
local XGETBV_STUB_X64 = string.char(
    0x89, 0xC9,             -- mov ecx, ecx
    0x0F, 0x01, 0xD0,       -- xgetbv
    0x48, 0xC1, 0xE2, 0x20, -- shl rdx, 32
    0x48, 0x09, 0xD0,       -- or  rax, rdx
    0xC3                    -- ret
)

-- ===== trampoline allocation ===========================================

local _cpuid_fn  -- typed function pointer; lazy-init
local _stub_mem  -- VirtualAlloc'd block, kept alive for the process lifetime

local _xgetbv_fn

local function init_cpuid()
    if _cpuid_fn then return _cpuid_fn end
    local size = 4096
    local mem = ffi.C.VirtualAlloc(nil, size,
        bit.bor(W.MEM_COMMIT, W.MEM_RESERVE), W.PAGE_EXECUTE_READWRITE)
    if mem == nil then error("cpuid: VirtualAlloc failed") end
    ffi.copy(mem, STUB, #STUB)
    -- Lay XGETBV stub after CPUID stub with 16-byte alignment.
    if _is_x64 then
        local off = math.floor((#STUB + 15) / 16) * 16
        ffi.copy(ffi.cast("uint8_t *", mem) + off, XGETBV_STUB_X64, #XGETBV_STUB_X64)
        _xgetbv_fn = ffi.cast("xgetbv_fn_t", ffi.cast("uint8_t *", mem) + off)
    end
    _stub_mem = mem
    _cpuid_fn = ffi.cast("cpuid_fn_t", mem)
    return _cpuid_fn
end

-- ===== raw leaf invocation =============================================

local function call(leaf, subleaf)
    local fn = init_cpuid()
    local out = ffi.new("uint32_t[4]")
    fn(leaf, subleaf or 0, out)
    return { eax = tonumber(out[0]), ebx = tonumber(out[1]),
             ecx = tonumber(out[2]), edx = tonumber(out[3]) }
end
M.raw = call

-- ===== vendor / brand / family / model / stepping ======================

local function regs_to_str(r1, r2, r3)
    -- Pack three 32-bit regs little-endian as a 12-byte ASCII string.
    local out = {}
    for _, r in ipairs({ r1, r2, r3 }) do
        out[#out + 1] = string.char(r % 256,
            math.floor(r / 0x100) % 256,
            math.floor(r / 0x10000) % 256,
            math.floor(r / 0x1000000) % 256)
    end
    return table.concat(out)
end

local _cache = {}

function M.vendor()
    if _cache.vendor then return _cache.vendor end
    local r = call(0, 0)
    _cache.vendor = regs_to_str(r.ebx, r.edx, r.ecx)
    _cache.max_basic = r.eax
    return _cache.vendor
end

function M.brand()
    if _cache.brand then return _cache.brand end
    -- Check support: leaf 0x80000000 returns max extended in eax.
    local r = call(0x80000000, 0)
    if r.eax < 0x80000004 then
        _cache.brand = ""
        return ""
    end
    local parts = {}
    for leaf = 0x80000002, 0x80000004 do
        local rr = call(leaf, 0)
        -- Brand uses all four regs eax/ebx/ecx/edx.
        parts[#parts + 1] = string.char(
            rr.eax % 256, math.floor(rr.eax / 0x100) % 256,
            math.floor(rr.eax / 0x10000) % 256, math.floor(rr.eax / 0x1000000) % 256,
            rr.ebx % 256, math.floor(rr.ebx / 0x100) % 256,
            math.floor(rr.ebx / 0x10000) % 256, math.floor(rr.ebx / 0x1000000) % 256,
            rr.ecx % 256, math.floor(rr.ecx / 0x100) % 256,
            math.floor(rr.ecx / 0x10000) % 256, math.floor(rr.ecx / 0x1000000) % 256,
            rr.edx % 256, math.floor(rr.edx / 0x100) % 256,
            math.floor(rr.edx / 0x10000) % 256, math.floor(rr.edx / 0x1000000) % 256)
    end
    -- Strip trailing NULs and leading spaces.
    local s = table.concat(parts)
    s = s:gsub("%z+$", ""):gsub("^%s+", "")
    _cache.brand = s
    return s
end

local function decode_version(eax)
    -- AMD/Intel-style version word decode (CPUID basic leaf 1, EAX).
    local stepping = eax % 16
    local model    = math.floor(eax / 0x10) % 16
    local family   = math.floor(eax / 0x100) % 16
    local ext_model = math.floor(eax / 0x10000) % 16
    local ext_family = math.floor(eax / 0x100000) % 256
    if family == 15 then family = family + ext_family end
    if family == 6 or family == 15 then
        model = model + ext_model * 16
    end
    return family, model, stepping
end

local function ensure_version()
    if _cache.family then return end
    local r = call(1, 0)
    _cache.family, _cache.model, _cache.stepping = decode_version(r.eax)
    _cache.leaf1 = r
end

function M.family()   ensure_version() return _cache.family end
function M.model()    ensure_version() return _cache.model end
function M.stepping() ensure_version() return _cache.stepping end

-- ===== features ========================================================

local function bit_set(v, b) return bit.band(v, bit.lshift(1, b)) ~= 0 end

function M.features()
    if _cache.features then return _cache.features end
    ensure_version()
    M.vendor() -- populate max_basic
    local l1 = _cache.leaf1
    local f = {}

    -- Leaf 1 EDX bits
    f.fpu      = bit_set(l1.edx, 0)
    f.tsc      = bit_set(l1.edx, 4)
    f.cx8      = bit_set(l1.edx, 8)
    f.cmov     = bit_set(l1.edx, 15)
    f.mmx      = bit_set(l1.edx, 23)
    f.fxsr     = bit_set(l1.edx, 24)
    f.sse      = bit_set(l1.edx, 25)
    f.sse2     = bit_set(l1.edx, 26)
    f.htt      = bit_set(l1.edx, 28)

    -- Leaf 1 ECX bits
    f.sse3     = bit_set(l1.ecx, 0)
    f.pclmulqdq= bit_set(l1.ecx, 1)
    f.ssse3    = bit_set(l1.ecx, 9)
    f.fma      = bit_set(l1.ecx, 12)
    f.cx16     = bit_set(l1.ecx, 13)
    f.sse4_1   = bit_set(l1.ecx, 19)
    f.sse4_2   = bit_set(l1.ecx, 20)
    f.movbe    = bit_set(l1.ecx, 22)
    f.popcnt   = bit_set(l1.ecx, 23)
    f.aes      = bit_set(l1.ecx, 25)
    f.xsave    = bit_set(l1.ecx, 26)
    f.osxsave  = bit_set(l1.ecx, 27)
    f.avx      = bit_set(l1.ecx, 28)
    f.f16c     = bit_set(l1.ecx, 29)
    f.rdrand   = bit_set(l1.ecx, 30)
    f.hypervisor = bit_set(l1.ecx, 31)

    -- Leaf 7 / sub 0 -- AVX2, BMI1, BMI2, AVX512 family, SHA, RDSEED, ...
    if _cache.max_basic >= 7 then
        local r = call(7, 0)
        f.fsgsbase  = bit_set(r.ebx, 0)
        f.bmi1      = bit_set(r.ebx, 3)
        f.avx2      = bit_set(r.ebx, 5)
        f.bmi2      = bit_set(r.ebx, 8)
        f.erms      = bit_set(r.ebx, 9)
        f.rdseed    = bit_set(r.ebx, 18)
        f.adx       = bit_set(r.ebx, 19)
        f.sha       = bit_set(r.ebx, 29)
        f.avx512f   = bit_set(r.ebx, 16)
        f.avx512dq  = bit_set(r.ebx, 17)
        f.avx512ifma= bit_set(r.ebx, 21)
        f.avx512pf  = bit_set(r.ebx, 26)
        f.avx512er  = bit_set(r.ebx, 27)
        f.avx512cd  = bit_set(r.ebx, 28)
        f.avx512bw  = bit_set(r.ebx, 30)
        f.avx512vl  = bit_set(r.ebx, 31)

        f.avx512vbmi   = bit_set(r.ecx, 1)
        f.avx512vbmi2  = bit_set(r.ecx, 6)
        f.vaes         = bit_set(r.ecx, 9)
        f.vpclmulqdq   = bit_set(r.ecx, 10)
        f.avx512vnni   = bit_set(r.ecx, 11)
        f.gfni         = bit_set(r.ecx, 8)
    end

    -- Leaf 0x80000001 -- AMD-specific bits we still care about.
    local x = call(0x80000000, 0)
    if x.eax >= 0x80000001 then
        local r = call(0x80000001, 0)
        f.lahf_lm  = bit_set(r.ecx, 0)
        f.lzcnt    = bit_set(r.ecx, 5)
        f.prefetchw= bit_set(r.ecx, 8)
        f.nx       = bit_set(r.edx, 20)
        f.mmxext   = bit_set(r.edx, 22)
        f.lm       = bit_set(r.edx, 29)  -- long mode (x86-64)
        f._3dnowext= bit_set(r.edx, 30)
        f._3dnow   = bit_set(r.edx, 31)
    end

    _cache.features = f
    return f
end

function M.has(name)
    local f = M.features()
    return f[name] == true
end

-- ===== cache info ======================================================

function M.cache_info()
    if _cache.cache_info then return _cache.cache_info end
    local out = {}

    -- AMD-style: leaf 0x80000005 (L1) + 0x80000006 (L2/L3).
    local x = call(0x80000000, 0)
    if x.eax >= 0x80000006 then
        local r5 = call(0x80000005, 0)
        out.l1d      = math.floor(r5.ecx / 0x1000000) * 1024
        out.l1d_line = r5.ecx % 256
        out.l1i      = math.floor(r5.edx / 0x1000000) * 1024
        out.l1i_line = r5.edx % 256

        local r6 = call(0x80000006, 0)
        out.l2      = math.floor(r6.ecx / 0x10000) * 1024
        out.l2_line = r6.ecx % 256
        -- L3 size unit on AMD is 512 KiB blocks.
        out.l3      = math.floor(r6.edx / 0x40000) * 512 * 1024
        out.l3_line = r6.edx % 256
    end

    -- Intel deterministic cache: leaf 4, walking subleaves.
    if M.vendor():find("Intel") and _cache.max_basic >= 4 then
        for sub = 0, 7 do
            local r = call(4, sub)
            local ctype = r.eax % 32
            if ctype == 0 then break end
            local level = math.floor(r.eax / 0x20) % 8
            local line  = (r.ebx % 4096) + 1
            local part  = (math.floor(r.ebx / 0x1000) % 1024) + 1
            local ways  = math.floor(r.ebx / 0x400000) + 1
            local sets  = r.ecx + 1
            local size  = ways * part * line * sets
            if level == 1 and ctype == 1 then
                out.l1d, out.l1d_line = size, line
            elseif level == 1 and ctype == 2 then
                out.l1i, out.l1i_line = size, line
            elseif level == 2 then
                out.l2, out.l2_line = size, line
            elseif level == 3 then
                out.l3, out.l3_line = size, line
            end
        end
    end

    _cache.cache_info = out
    return out
end

-- ===== topology ========================================================
--
-- We don't try to be perfectly correct across every vendor. The "good
-- enough for introspection" approach:
--   1. logical_in_package from leaf 1 EBX[23:16]
--   2. physical core count via leaf 4 sub 0 EAX[31:26] (Intel) or
--      0x80000008 ECX[7:0] + 1 (AMD)
--   3. smt_per_core = logical / physical (or 1 if no HTT)

function M.topology()
    if _cache.topology then return _cache.topology end
    M.vendor() -- populate max_basic
    ensure_version()
    local out = {}
    local l1 = _cache.leaf1
    out.logical = math.floor(l1.ebx / 0x10000) % 256
    if out.logical == 0 then out.logical = 1 end

    local v = M.vendor()
    if v:find("Intel") and _cache.max_basic >= 4 then
        local r = call(4, 0)
        local cores = math.floor(r.eax / 0x4000000) + 1
        out.physical = cores
    else
        local x = call(0x80000000, 0)
        if x.eax >= 0x80000008 then
            local r = call(0x80000008, 0)
            out.physical = (r.ecx % 256) + 1
        else
            out.physical = out.logical
        end
    end

    if out.physical < 1 then out.physical = 1 end
    out.cores = out.physical
    out.smt_per_core = math.max(1, math.floor(out.logical / out.physical))
    _cache.topology = out
    return out
end

-- ===== OS support state (XSAVE / XGETBV) ===============================

function M.os_support()
    if _cache.os_support then return _cache.os_support end
    local out = { xsave = false, avx = false, avx512 = false }
    init_cpuid()
    local f = M.features()
    if f.osxsave and f.xsave and _xgetbv_fn then
        out.xsave = true
        local ok, xcr0 = pcall(function() return _xgetbv_fn(0) end)
        if ok and xcr0 then
            -- The bits we care about (XMM/YMM/opmask/ZMM-hi-256/Hi16-ZMM)
            -- all live in the low 16 bits of XCR0. Coerce via tonumber;
            -- LuaJIT's uint64_t cdata supports __tonumber, but for safety
            -- mask first to a 32-bit window.
            local low
            if type(xcr0) == "cdata" then
                low = tonumber(ffi.cast("uint32_t", xcr0))
            else
                low = tonumber(xcr0) % 4294967296
            end
            -- XMM (bit 1) + YMM (bit 2) for AVX. ZMM upper (bit 5..7) for AVX-512.
            if bit.band(low, 0x6) == 0x6 then out.avx = true end
            if bit.band(low, 0xE6) == 0xE6 then out.avx512 = true end
        end
    end
    _cache.os_support = out
    return out
end

return M
