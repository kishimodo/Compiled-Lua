-- dis -- x86 / x86-64 disassembler with Capstone + Zydis backends.
--
-- Public surface:
--   dis.new(opts?)              -> dis object
--                                  opts = { backend="capstone"|"zydis"|"auto",
--                                           arch="x86_64"|"x86_32",
--                                           syntax="intel"|"att" }
--   dis.available_backends()    -> { "capstone", "zydis" }  (whichever loaded)
--   dis.is_available()          -> bool (true if any backend present)
--
--   -- legacy convenience:
--   dis.x86_64(bytes, address?) -> array of insns
--   dis.x86_32(bytes, address?) -> array of insns
--
-- dis object methods:
--   :decode(bytes, addr?)       -> iterator yielding insn tables
--   :decode_all(bytes, addr?)   -> array of insn tables
--   :decode_one(bytes, addr?, offset?) -> single insn
--   :format(insn)               -> formatted "mnemonic op_str" string
--   :backend()                  -> "capstone" | "zydis"
--   :close()
--
-- Insn shape:
--   { address, bytes, mnemonic, op_str, size, groups? }
--
-- Backend selection:
--   opts.backend = "capstone" or "zydis" forces that backend, raising if
--   it isn't loaded. "auto" (default) tries capstone first, then zydis.
--   The CLUA_CAPSTONE_DLL / CLUA_ZYDIS_DLL env vars pin a specific DLL.
--
-- DLL distribution:
--   Each backend is probed independently. requires_native lists both as
--   embed candidates. At runtime we ffi.load each independently and let
--   the caller choose. If neither loads, dis.new raises with a clear
--   pointer to the env vars and the "drop next to exe" hint.

local ffi = ffi

local M = {}

-- ===== Capstone cdef ==================================================

ffi.cdef[[
typedef size_t  cs_handle;
typedef int     cs_err;

enum cs_arch_e { CS_ARCH_X86 = 3 };
enum cs_mode_e { CS_MODE_16 = 2, CS_MODE_32 = 4, CS_MODE_64 = 8 };
enum cs_opt_type_e {
    CS_OPT_SYNTAX = 1, CS_OPT_DETAIL = 2, CS_OPT_MODE = 3
};
enum cs_opt_value_e {
    CS_OPT_SYNTAX_DEFAULT = 0, CS_OPT_SYNTAX_INTEL = 1, CS_OPT_SYNTAX_ATT = 2,
    CS_OPT_OFF = 0, CS_OPT_ON = 3
};

typedef struct cs_insn {
    unsigned int  id;
    uint64_t      address;
    uint16_t      size;
    uint8_t       bytes[24];
    char          mnemonic[32];
    char          op_str[160];
    void *        detail;
} cs_insn;

cs_err  cs_open(int arch, int mode, cs_handle *handle);
cs_err  cs_close(cs_handle *handle);
cs_err  cs_option(cs_handle handle, int type, size_t value);
size_t  cs_disasm(cs_handle handle, const uint8_t *code, size_t code_size,
                  uint64_t address, size_t count, cs_insn **insn);
void    cs_free(cs_insn *insn, size_t count);
const char *cs_strerror(cs_err code);
unsigned int cs_version(int *major, int *minor);
]]

-- ===== Zydis cdef =====================================================

ffi.cdef[[
enum ZyanStatus { ZYAN_STATUS_SUCCESS = 0 };
enum ZydisMachineMode {
    ZYDIS_MACHINE_MODE_LONG_64 = 1,
    ZYDIS_MACHINE_MODE_LONG_COMPAT_32 = 2,
    ZYDIS_MACHINE_MODE_LEGACY_32 = 3
};
enum ZydisStackWidth {
    ZYDIS_STACK_WIDTH_16 = 0,
    ZYDIS_STACK_WIDTH_32 = 1,
    ZYDIS_STACK_WIDTH_64 = 2
};
typedef struct ZydisDisassembledInstructionStub {
    uint64_t  runtime_address;
    uint8_t   info[256];      /* opaque ZydisDecodedInstruction */
    char      text[96];       /* formatted mnemonic + operands */
} ZydisDisassembledInstructionStub;

uint32_t ZydisDisassembleIntel(int machine_mode, uint64_t runtime_address,
                               const void *buffer, size_t length,
                               void *instruction);
uint32_t ZydisDisassembleATT(int machine_mode, uint64_t runtime_address,
                             const void *buffer, size_t length,
                             void *instruction);
]]

-- ===== independent backend probes =====================================

local _cs_lib       -- capstone handle (false if probed, missing)
local _zd_lib       -- zydis handle (false if probed, missing)
local _cs_error
local _zd_error

local function env(name)
    local ok, v = pcall(os.getenv, name)
    if ok and v and v ~= "" then return v end
    return nil
end

local function try_load_symbol(name, sym)
    local ok, lib = pcall(ffi.load, name)
    if not ok or not lib then return nil end
    -- Symbol-presence check so a name collision (zydis dropped under
    -- capstone's name) doesn't claim it loaded.
    local has_sym = pcall(function() local _ = lib[sym] end)
    if not has_sym then return nil end
    return lib
end

local function probe_capstone()
    if _cs_lib ~= nil then return _cs_lib end
    local candidates = {}
    local override = env("CLUA_CAPSTONE_DLL")
    if override then candidates[#candidates + 1] = override end
    candidates[#candidates + 1] = "capstone"
    candidates[#candidates + 1] = "capstone-5"
    candidates[#candidates + 1] = "capstone.dll"
    for _, name in ipairs(candidates) do
        local lib = try_load_symbol(name, "cs_open")
        if lib then _cs_lib = lib; return _cs_lib end
    end
    _cs_lib = false
    _cs_error = "capstone.dll not found (tried " .. table.concat(candidates, ", ") .. ")"
    return _cs_lib
end

local function probe_zydis()
    if _zd_lib ~= nil then return _zd_lib end
    local candidates = {}
    local override = env("CLUA_ZYDIS_DLL")
    if override then candidates[#candidates + 1] = override end
    candidates[#candidates + 1] = "Zydis"
    candidates[#candidates + 1] = "zydis"
    candidates[#candidates + 1] = "Zydis.dll"
    candidates[#candidates + 1] = "zydis.dll"
    for _, name in ipairs(candidates) do
        local lib = try_load_symbol(name, "ZydisDisassembleIntel")
        if lib then _zd_lib = lib; return _zd_lib end
    end
    _zd_lib = false
    _zd_error = "zydis.dll not found (tried " .. table.concat(candidates, ", ") .. ")"
    return _zd_lib
end

function M.available_backends()
    local out = {}
    if probe_capstone() then out[#out + 1] = "capstone" end
    if probe_zydis()    then out[#out + 1] = "zydis"    end
    return out
end

function M.is_available()
    return probe_capstone() ~= false or probe_zydis() ~= false
end

-- ===== option parsing =================================================

local function parse_arch(arch)
    arch = arch or "x86_64"
    if arch == "x86_64" or arch == "x64" or arch == "amd64" then
        return 64
    elseif arch == "x86_32" or arch == "x86" or arch == "i386" then
        return 32
    elseif arch == "x86_16" then
        return 16
    end
    error("dis.new: unsupported arch '" .. tostring(arch) .. "' (use x86_64 / x86_32)")
end

-- ===== Capstone wrapper ===============================================

local Cs = {}
Cs.__index = Cs

local function cs_new(bits, syntax)
    local lib = probe_capstone()
    if not lib then error("dis: " .. (_cs_error or "capstone missing")) end
    local cs_mode
    if bits == 64 then cs_mode = 8
    elseif bits == 32 then cs_mode = 4
    else cs_mode = 2 end
    local h = ffi.new("cs_handle[1]")
    local err = lib.cs_open(3, cs_mode, h)  -- 3 == CS_ARCH_X86
    if err ~= 0 then
        local msg = ffi.string(lib.cs_strerror(err))
        error("dis: cs_open failed: " .. msg)
    end
    if syntax == "att" then
        lib.cs_option(h[0], 1, 2)  -- CS_OPT_SYNTAX_ATT
    end
    return setmetatable({
        _backend = "capstone",
        _h = h,
        _lib = lib,
        _bits = bits,
        _syntax = syntax or "intel",
    }, Cs)
end

function Cs:backend() return "capstone" end

function Cs:close()
    if self._h then
        self._lib.cs_close(self._h)
        self._h = nil
    end
end

function Cs:decode_all(bytes, address)
    if type(bytes) ~= "string" then error("dis:decode expects byte string") end
    address = address or 0
    local insn = ffi.new("cs_insn *[1]")
    local n = tonumber(self._lib.cs_disasm(self._h[0],
        ffi.cast("const uint8_t *", bytes), #bytes, address, 0, insn))
    if n == 0 then return {} end
    local out = {}
    for i = 0, n - 1 do
        local ins = insn[0] + i
        out[#out + 1] = {
            address  = tonumber(ins.address),
            mnemonic = ffi.string(ins.mnemonic),
            op_str   = ffi.string(ins.op_str),
            size     = tonumber(ins.size),
            bytes    = ffi.string(ins.bytes, ins.size),
        }
    end
    self._lib.cs_free(insn[0], n)
    return out
end

function Cs:decode(bytes, address)
    local arr = self:decode_all(bytes, address)
    local i = 0
    return function()
        i = i + 1
        return arr[i]
    end
end

function Cs:decode_one(bytes, address, offset)
    address = address or 0
    if offset then
        bytes = bytes:sub(offset + 1)
        address = address + offset
    end
    local insn = ffi.new("cs_insn *[1]")
    local n = tonumber(self._lib.cs_disasm(self._h[0],
        ffi.cast("const uint8_t *", bytes), #bytes, address, 1, insn))
    if n == 0 then return nil end
    local ins = insn[0]
    local r = {
        address  = tonumber(ins.address),
        mnemonic = ffi.string(ins.mnemonic),
        op_str   = ffi.string(ins.op_str),
        size     = tonumber(ins.size),
        bytes    = ffi.string(ins.bytes, ins.size),
    }
    self._lib.cs_free(ins, 1)
    return r
end

function Cs:format(insn)
    if insn.op_str and insn.op_str ~= "" then
        return insn.mnemonic .. " " .. insn.op_str
    end
    return insn.mnemonic or ""
end

-- ===== Zydis wrapper ==================================================

local Zd = {}
Zd.__index = Zd

local function zd_new(bits, syntax)
    local lib = probe_zydis()
    if not lib then error("dis: " .. (_zd_error or "zydis missing")) end
    local mode
    if bits == 64 then mode = 1
    elseif bits == 32 then mode = 3
    else mode = 3 end
    return setmetatable({
        _backend = "zydis",
        _lib = lib,
        _mode = mode,
        _bits = bits,
        _syntax = syntax or "intel",
    }, Zd)
end

function Zd:backend() return "zydis" end
function Zd:close() end

function Zd:decode_one(bytes, address, offset)
    address = address or 0
    if offset then
        bytes = bytes:sub(offset + 1)
        address = address + offset
    end
    if #bytes == 0 then return nil end
    local out = ffi.new("ZydisDisassembledInstructionStub")
    local fn = (self._syntax == "att") and self._lib.ZydisDisassembleATT
        or self._lib.ZydisDisassembleIntel
    local status = fn(self._mode, address,
        ffi.cast("const void *", bytes), #bytes, out)
    if status ~= 0 then return nil end
    local text = ffi.string(out.text)
    local mn, ops = text:match("^(%S+)%s+(.+)$")
    if not mn then mn, ops = text, "" end
    -- ZydisDecodedInstruction.length is at byte offset 10 in 4.x (a uint8).
    -- This is a known pin-point; the structure prefix is stable in 4.x.
    local size = ffi.cast("uint8_t *", out.info)[10]
    if size == 0 then size = math.min(15, #bytes) end
    return {
        address  = address,
        mnemonic = mn,
        op_str   = ops,
        size     = size,
        bytes    = bytes:sub(1, size),
    }
end

function Zd:decode_all(bytes, address)
    address = address or 0
    local out = {}
    local off = 0
    while off < #bytes do
        local ins = self:decode_one(bytes, address + off, off)
        if not ins or ins.size == 0 then break end
        out[#out + 1] = ins
        off = off + ins.size
    end
    return out
end

function Zd:decode(bytes, address)
    address = address or 0
    local off = 0
    return function()
        if off >= #bytes then return nil end
        local ins = self:decode_one(bytes, address + off, off)
        if not ins or ins.size == 0 then return nil end
        off = off + ins.size
        return ins
    end
end

Zd.format = Cs.format

-- ===== public ctor ====================================================

function M.new(opts)
    opts = opts or {}
    local backend = opts.backend or "auto"
    local bits = parse_arch(opts.arch or "x86_64")
    local syntax = opts.syntax or "intel"

    if backend == "capstone" then
        if probe_capstone() then return cs_new(bits, syntax) end
        if probe_zydis() then return zd_new(bits, syntax) end
        error("dis: capstone requested but unavailable: " .. (_cs_error or ""))
    elseif backend == "zydis" then
        if probe_zydis() then return zd_new(bits, syntax) end
        if probe_capstone() then return cs_new(bits, syntax) end
        error("dis: zydis requested but unavailable: " .. (_zd_error or ""))
    else
        if probe_capstone() then return cs_new(bits, syntax) end
        if probe_zydis()    then return zd_new(bits, syntax) end
        error("dis: no disassembler available. " ..
              "Tried capstone (" .. (_cs_error or "") .. ") and zydis (" .. (_zd_error or "") .. "). " ..
              "Set CLUA_CAPSTONE_DLL or CLUA_ZYDIS_DLL, or drop the DLL alongside the exe.")
    end
end

-- ===== legacy module-level convenience ================================

function M.x86_64(bytes, address)
    local d = M.new({ arch = "x86_64" })
    local r = d:decode_all(bytes, address)
    d:close()
    return r
end

function M.x86_32(bytes, address)
    local d = M.new({ arch = "x86_32" })
    local r = d:decode_all(bytes, address)
    d:close()
    return r
end

-- Backend tag for callers that want to know which backend is the default.
do
    local mt = getmetatable(M) or {}
    mt.__index = function(t, k)
        if k == "backend" then
            if probe_capstone() then return "capstone" end
            if probe_zydis()    then return "zydis"    end
            return nil
        end
    end
    setmetatable(M, mt)
end

return M
