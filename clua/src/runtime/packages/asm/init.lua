-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- asm -- Keystone-backed assembler.
--
-- Public surface:
--   asm.new(opts?)                 -> asm object
--                                     opts = { arch="x86_64", syntax="intel"|"att"|"nasm"|"masm" }
--   asm.x86_64(source, addr?)      -> bytes, insn_count
--   asm.x86_32(source, addr?)      -> bytes, insn_count
--   asm.arm64(source, addr?)       -> bytes, insn_count
--   asm.is_available()             -> bool
--
-- asm object:
--   :assemble(text, address?)      -> bytes, insn_count
--   :assemble_to_bytes(text)       -> bytes (no count, addr=0)
--   :close()
--
-- Env override: CLUA_KEYSTONE_DLL=<path>.
--
-- Backend detection:
--   Looks for keystone.dll, then keystone-0.dll (the version-suffixed
--   name used by the official Windows builds). Override via CLUA_ASM_DLL.
--   If absent, every API throws an error directing the user to drop the
--   DLL alongside the binary or set the env var.
--
-- Sample input the user can paste:
--   "mov rax, 1; mov rdi, 2; syscall; ret"
--   "bl _start; nop; ret"
-- Multiple instructions are separated by `;` or newline (Keystone handles
-- both natively).

local ffi = ffi

ffi.cdef[[
typedef void * ks_engine;
typedef int    ks_err;

enum ks_arch_e {
    KS_ARCH_ARM    = 1,
    KS_ARCH_ARM64  = 2,
    KS_ARCH_MIPS   = 3,
    KS_ARCH_X86    = 4,
    KS_ARCH_PPC    = 5,
    KS_ARCH_SPARC  = 6,
    KS_ARCH_SYSTEMZ= 7,
    KS_ARCH_HEXAGON= 8,
    KS_ARCH_EVM    = 9
};
enum ks_mode_e {
    KS_MODE_LITTLE_ENDIAN = 0,
    KS_MODE_BIG_ENDIAN    = 0x40000000,
    KS_MODE_16            = 2,
    KS_MODE_32            = 4,
    KS_MODE_64            = 8,
    KS_MODE_ARM           = 1,
    KS_MODE_THUMB         = 16
};

ks_err  ks_open(int arch, int mode, ks_engine **ks);
ks_err  ks_close(ks_engine *ks);
int     ks_asm(ks_engine *ks, const char *str, uint64_t address,
               uint8_t **encoding, size_t *encoding_size,
               size_t *stat_count);
void    ks_free(uint8_t *p);
const char *ks_strerror(ks_err code);
ks_err  ks_errno(ks_engine *ks);
ks_err  ks_option(ks_engine *ks, int type, size_t value);
unsigned int ks_version(unsigned int *major, unsigned int *minor);
]]

-- KS_OPT_SYNTAX = 1
local KS_OPT_SYNTAX = 1
local KS_OPT_SYNTAX_INTEL = 1
local KS_OPT_SYNTAX_ATT   = 2
local KS_OPT_SYNTAX_NASM  = 4
local KS_OPT_SYNTAX_MASM  = 8
local KS_OPT_SYNTAX_GAS   = 16

local M = {}

local _lib
local _last_error

local function env(name)
    local ok, v = pcall(os.getenv, name)
    if ok and v and v ~= "" then return v end
    return nil
end

local function probe()
    if _lib ~= nil then return _lib end
    local candidates = {}
    local override = env("CLUA_KEYSTONE_DLL") or env("CLUA_ASM_DLL")
    if override then candidates[#candidates + 1] = override end
    candidates[#candidates + 1] = "keystone"
    candidates[#candidates + 1] = "keystone-0"
    candidates[#candidates + 1] = "keystone.dll"

    for _, name in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            -- Confirm it's keystone by probing for ks_open. ffi.load
            -- happily loads any DLL, so we need a symbol-presence check.
            local found = pcall(function() local _ = lib.ks_open end)
            if found then
                _lib = lib
                return _lib
            end
        end
    end
    _last_error = "keystone.dll not found: tried keystone.dll, keystone-0.dll. "
        .. "Set CLUA_KEYSTONE_DLL=<path> or drop the DLL alongside the exe."
    _lib = false
    return _lib
end

function M.is_available()
    return probe() ~= false
end

local function require_lib()
    local lib = probe()
    if lib == false then error("asm: " .. _last_error) end
    return lib
end

-- ===== arch / mode parsing ============================================
--
-- The Keystone arch enum is a single int; mode is a bitmask. We restrict
-- the public surface to the dialects we care about and let advanced users
-- drop down to asm.new("arm", "arm|thumb") if they need to flip Thumb.

local ARCH_NAMES = {
    x86 = 4, arm = 1, arm64 = 2, mips = 3, ppc = 5,
    sparc = 6, sysz = 7, hexagon = 8, evm = 9,
}

local MODE_TOKS = {
    ["16"] = 2, ["32"] = 4, ["64"] = 8,
    arm = 1, thumb = 16, little = 0, big = 0x40000000,
}

-- Maps "x86_64" / "x86_32" / etc -> (arch, mode_string)
local ARCH_ALIAS = {
    x86_64 = { "x86", "64" },
    x64    = { "x86", "64" },
    amd64  = { "x86", "64" },
    x86_32 = { "x86", "32" },
    i386   = { "x86", "32" },
    x86_16 = { "x86", "16" },
    arm    = { "arm", "arm" },
    arm64  = { "arm64", "little" },
    aarch64= { "arm64", "little" },
    thumb  = { "arm", "thumb" },
}

local SYNTAX_VAL = {
    intel = KS_OPT_SYNTAX_INTEL, att = KS_OPT_SYNTAX_ATT,
    nasm  = KS_OPT_SYNTAX_NASM,  masm = KS_OPT_SYNTAX_MASM,
    gas   = KS_OPT_SYNTAX_GAS,
}

local function parse_mode(s)
    if type(s) == "number" then return s end
    if s == nil then return 8 end
    local m = 0
    for tok in tostring(s):gmatch("[^|%s]+") do
        local v = MODE_TOKS[tok]
        if v == nil then
            error("asm: unknown mode token '" .. tok .. "'")
        end
        m = bit.bor(m, v)
    end
    return m
end

-- ===== engine wrapper =================================================

local Ks = {}
Ks.__index = Ks

function M.new(arch, mode)
    local syntax
    -- Accept either a table opts or the legacy two-arg form.
    if type(arch) == "table" then
        local opts = arch
        local a = opts.arch or "x86_64"
        if ARCH_ALIAS[a] then
            arch, mode = ARCH_ALIAS[a][1], ARCH_ALIAS[a][2]
        else
            arch = a
            mode = opts.mode
        end
        syntax = opts.syntax
    end
    arch = arch or "x86"
    if ARCH_ALIAS[arch] then
        local pair = ARCH_ALIAS[arch]
        arch, mode = pair[1], mode or pair[2]
    end
    local lib = require_lib()
    local arch_id = ARCH_NAMES[arch]
    if not arch_id then error("asm.new: unknown arch '" .. tostring(arch) .. "'") end
    local mode_val = parse_mode(mode)

    local eng = ffi.new("ks_engine *[1]")
    local err = lib.ks_open(arch_id, mode_val, eng)
    if err ~= 0 then
        local msg = ffi.string(lib.ks_strerror(err))
        error("asm: ks_open failed: " .. msg)
    end
    if syntax and SYNTAX_VAL[syntax] then
        lib.ks_option(eng[0], KS_OPT_SYNTAX, SYNTAX_VAL[syntax])
    end
    return setmetatable({ _eng = eng, _lib = lib, _arch = arch, _syntax = syntax }, Ks)
end

function Ks:close()
    if self._eng and self._eng[0] ~= nil then
        self._lib.ks_close(self._eng[0])
        self._eng = nil
    end
end

function Ks:assemble(source, address)
    if type(source) ~= "string" then
        error("asm:assemble expects a string source")
    end
    address = address or 0
    local enc = ffi.new("uint8_t *[1]")
    local sz  = ffi.new("size_t[1]")
    local cnt = ffi.new("size_t[1]")
    local rc = self._lib.ks_asm(self._eng[0], source, address, enc, sz, cnt)
    if rc ~= 0 then
        local errno = self._lib.ks_errno(self._eng[0])
        local msg = ffi.string(self._lib.ks_strerror(errno))
        error(string.format("asm: ks_asm failed (errno=%d): %s", tonumber(errno), msg))
    end
    local bytes = ffi.string(enc[0], tonumber(sz[0]))
    self._lib.ks_free(enc[0])
    return bytes, tonumber(cnt[0])
end

function Ks:assemble_to_bytes(source)
    local b = self:assemble(source, 0)
    return b
end

-- ===== module-level shortcuts =========================================

function M.x86_64(source, addr)
    local a = M.new("x86", "64")
    local b, n = a:assemble(source, addr)
    a:close()
    return b, n
end

function M.x86_32(source, addr)
    local a = M.new("x86", "32")
    local b, n = a:assemble(source, addr)
    a:close()
    return b, n
end

function M.arm64(source, addr)
    local a = M.new("arm64", "little")
    local b, n = a:assemble(source, addr)
    a:close()
    return b, n
end

return M
