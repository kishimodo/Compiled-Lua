-- vuln_scan -- pattern scanner for known unsafe / vuln-fingerprint bytes.
--
-- Public surface:
--   vuln_scan.patterns                       -- named pattern library
--   vuln_scan.compile(pattern_string)        -> compiled pattern
--   vuln_scan.scan_buffer(bytes, opts?)      -> { finding, ... }
--   vuln_scan.scan_process(pid, opts?)       -> { finding, ... }
--   vuln_scan.scan_module(pid, mod, opts?)   -> { finding, ... }
--   vuln_scan.find_ropgadgets(bytes, opts?)  -> { gadget, ... }
--
-- Pattern syntax:
--   Spaced hex with "?" / "??" / "*" wildcards.
--   "48 8B ? ? ? ? 48 89"     -- 8 bytes, 4 wildcards in the middle
--   "B8 ?? ?? ?? ?? 0F 05"    -- mov eax, ssn; syscall (x64)
--
-- opts (scan_buffer / scan_process):
--   patterns       = { "syscall_stub", "shellcode_egg", ... }   names from .patterns
--   custom         = { name = pattern_string, ... }             one-off additions
--   limit          = max findings per pattern                   default 64
--   module         = "name.dll" (scan_process only)             default whole proc
--   exec_only      = bool (scan_process only)                   default true
--   base           = number (scan_buffer only) -- address to add to offsets
--
-- finding:
--   { address, pattern_name, offset_in_buf, snippet (16 bytes hex), context (40 bytes hex) }

local M = {}

-- ===== pattern compilation =============================================

local function hex_nibble(c)
    if c >= 0x30 and c <= 0x39 then return c - 0x30 end
    if c >= 0x41 and c <= 0x46 then return c - 0x41 + 10 end
    if c >= 0x61 and c <= 0x66 then return c - 0x61 + 10 end
    return nil
end

function M.compile(pat)
    if type(pat) == "table" and pat.bytes and pat.mask then return pat end
    local bytes, mask = {}, {}
    local i, n = 1, #pat
    while i <= n do
        local c = pat:byte(i)
        if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D then
            i = i + 1
        elseif c == 0x3F or c == 0x2A then  -- ? or *
            bytes[#bytes + 1] = 0
            mask[#mask + 1]   = false
            if i + 1 <= n and (pat:byte(i + 1) == 0x3F or pat:byte(i + 1) == 0x2A) then
                i = i + 2
            else
                i = i + 1
            end
        else
            local hi = hex_nibble(c)
            local c2 = pat:byte(i + 1)
            local lo = c2 and hex_nibble(c2) or nil
            if not hi or not lo then
                error("vuln_scan.compile: bad hex at offset " .. tostring(i - 1))
            end
            bytes[#bytes + 1] = hi * 16 + lo
            mask[#mask + 1]   = true
            i = i + 2
        end
    end
    if #bytes == 0 then error("vuln_scan.compile: empty pattern") end
    return { bytes = bytes, mask = mask, len = #bytes }
end

-- ===== built-in pattern library ========================================
--
-- All x64 unless noted. Patterns are intentionally permissive (wildcards on
-- registers / immediates / displacements) so they catch the canonical form
-- of each fingerprint even after compiler-specific reordering.

M.patterns = {
    -- ntdll-style direct syscall stub (Windows x64):
    --   4C 8B D1            mov  r10, rcx
    --   B8 ?? ?? ?? ??      mov  eax, SSN
    --   F6 04 25 08 03 FE 7F 01   test byte ptr [0x7FFE0308], 1
    --   75 03                jne  +3
    --   0F 05                syscall
    --   C3                   ret
    syscall_stub = "4C 8B D1 B8 ?? ?? ?? ?? F6 04 25 08 03 FE 7F 01 75 03 0F 05 C3",

    -- Short form used by some EDRs after stripping the user-share check:
    --   mov r10, rcx ; mov eax, ssn ; syscall ; ret
    syscall_stub_short = "4C 8B D1 B8 ?? ?? ?? ?? 0F 05 C3",

    -- Indirect-syscall trampoline: instead of `syscall` at the stub, jmp
    -- back into ntdll's syscall instruction at a resolved address.
    syscall_indirect = "4C 8B D1 B8 ?? ?? ?? ?? 49 89 CA FF 25 ?? ?? ?? ??",

    -- Egg-hunter (Skape-style w00tw00t):
    --   66 81 CA FF 0F      or dx, 0FFFh
    --   42                  inc edx
    --   52                  push edx
    --   6A 02               push 2 (NtAccessCheckAndAuditAlarm)
    --   58                  pop eax
    --   CD 2E               int 2Eh
    --   3C 05               cmp al, 5
    --   5A                  pop edx
    --   74 EF               je back
    egghunter_skape = "66 81 CA FF 0F 42 52 6A 02 58 CD 2E 3C 05 5A 74 EF",

    -- Generic 8-byte egg sentinel (w00tw00t -- 0x77307774 twice).
    shellcode_egg = "77 30 30 74 77 30 30 74",

    -- AMSI bypass classic: patch AmsiScanBuffer prologue with `mov eax, 0x80070057 ; ret`.
    amsi_bypass_patch = "B8 57 00 07 80 C3",

    -- ETW patching: clobber EtwEventWrite to a quick `xor eax, eax ; ret`.
    etw_patch_xor_ret = "33 C0 C3",

    -- VEH handler body marker (RtlAddVectoredExceptionHandler call site):
    --   48 83 EC 28   sub rsp, 28h     ; standard prologue
    --   48 89 4C 24 ? mov [rsp+?], rcx ; save EXCEPTION_POINTERS
    -- Combined with an immediately following EXCEPTION_BREAKPOINT / EXCEPTION_SINGLE_STEP
    -- match (cmp eax, 80000003h / 80000004h).
    veh_handler = "8B 41 04 3D 03 00 00 80",

    -- Inline hook jump table prologue (IAT / IAT-detour stomp):
    --   FF 25 ?? ?? ?? ??    jmp qword ptr [rip+disp32]
    hook_jump_table = "FF 25 ?? ?? ?? ??",

    -- 32-bit absolute jmp trampoline (push imm32 ; ret).
    hook_push_ret = "68 ?? ?? ?? ?? C3",

    -- Direct mov+jmp inline hook (common Detours-style 5-byte patch followed
    -- by `mov rax, imm64 ; jmp rax`).
    hook_mov_jmp_rax = "48 B8 ?? ?? ?? ?? ?? ?? ?? ?? FF E0",

    -- ROP-style stack pivot: xchg eax,esp / mov rsp,rax pivots.
    rop_xchg_eax_esp = "94 C3",
    rop_mov_rsp_rax  = "48 8B E0 C3",
    rop_add_rsp_imm  = "48 81 C4 ?? ?? ?? ?? C3",

    -- VirtualProtect-on-stack pivot (used by SMEP/SMAP-aware exploits):
    --   48 89 E1                mov  rcx, rsp
    --   48 C7 C2 ?? ?? ?? ??    mov  rdx, size
    --   41 B8 40 00 00 00       mov  r8d, PAGE_EXECUTE_READWRITE
    vprotect_pivot = "48 89 E1 48 C7 C2 ?? ?? ?? ?? 41 B8 40 00 00 00",

    -- LoadLibraryA argv on stack ("KERNEL32" string fragment, then PUSH /
    -- CALL into LoadLibraryA).
    loadlib_call_stub = "4B 45 52 4E 45 4C 33 32",

    -- WriteProcessMemory + CreateRemoteThread shellcode prologue.
    rwx_alloc_call = "48 31 C9 48 81 EC 00 10 00 00 48 8D 0D",

    -- Known Cobalt-Strike beacon prologue:
    --   FC E8 ?? 00 00 00 41    cld ; call +offset ; ...
    cobalt_strike_prologue = "FC E8 ?? 00 00 00 41",

    -- Metasploit reverse_tcp x64 prologue marker:
    --   FC 48 83 E4 F0 E8 ?? 00 00 00     cld ; and rsp,-16 ; call ...
    metasploit_x64 = "FC 48 83 E4 F0 E8 ?? 00 00 00",

    -- Classic API-hashing loop (PEB walk -> ror13 hash):
    --   48 31 D2 65 48 8B 52 60 48 8B 52 18 48 8B 52 20
    peb_walk_x64 = "65 48 8B 04 25 60 00 00 00 48 8B 40 18 48 8B 40 20",

    -- CVE-2021-40444 / CVE-2022-30190 (Follina) MSDT URI fingerprint --
    -- ASCII "ms-msdt:/id" sometimes shows up in cached document bytes.
    follina_msdt = "6D 73 2D 6D 73 64 74 3A 2F 69 64",

    -- log4shell ${jndi:ldap fingerprint (ASCII).
    log4shell_jndi = "24 7B 6A 6E 64 69 3A",

    -- ASCII "rundll32.exe" -- frequently used in living-off-the-land patterns.
    lolbin_rundll32 = "72 75 6E 64 6C 6C 33 32 2E 65 78 65",

    -- ASCII "powershell -nop -w hidden -enc"
    pwsh_obfuscated = "70 6F 77 65 72 73 68 65 6C 6C 20 2D 6E 6F 70",
}

-- Compile + cache once at module load (cheap, lets scan_chunk treat them
-- as plain tables).
local _compiled_lib = {}
for name, p in pairs(M.patterns) do
    _compiled_lib[name] = M.compile(p)
end

-- ===== core scanner ====================================================

local function scan_chunk(chunk, cp)
    local len = cp.len
    if #chunk < len then return {} end
    local pbytes = cp.bytes
    local pmask  = cp.mask
    local clen = #chunk
    local out = {}
    if pmask[1] then
        local first = string.char(pbytes[1])
        local pos = 1
        while true do
            local i = chunk:find(first, pos, true)
            if not i then break end
            if i + len - 1 <= clen then
                local ok = true
                for j = 2, len do
                    if pmask[j] and chunk:byte(i + j - 1) ~= pbytes[j] then
                        ok = false; break
                    end
                end
                if ok then out[#out + 1] = i - 1 end
            else
                break
            end
            pos = i + 1
        end
    else
        for i = 1, clen - len + 1 do
            local ok = true
            for j = 1, len do
                if pmask[j] and chunk:byte(i + j - 1) ~= pbytes[j] then
                    ok = false; break
                end
            end
            if ok then out[#out + 1] = i - 1 end
        end
    end
    return out
end

local function hex_slice(bytes, off, n)
    n = math.min(n, #bytes - off)
    if n <= 0 then return "" end
    local out = {}
    for i = 1, n do
        out[i] = string.format("%02X", bytes:byte(off + i))
    end
    return table.concat(out, " ")
end

local function resolve_patterns(opts)
    opts = opts or {}
    local sel = opts.patterns
    local compiled = {}
    if sel == nil then
        for name, cp in pairs(_compiled_lib) do compiled[name] = cp end
    else
        for _, name in ipairs(sel) do
            local cp = _compiled_lib[name]
            if not cp then error("vuln_scan: unknown pattern '" .. name .. "'") end
            compiled[name] = cp
        end
    end
    if opts.custom then
        for name, pat in pairs(opts.custom) do
            compiled[name] = M.compile(pat)
        end
    end
    return compiled
end

-- ===== scan_buffer =====================================================

function M.scan_buffer(bytes, opts)
    if type(bytes) ~= "string" then error("vuln_scan.scan_buffer: bytes must be a string") end
    opts = opts or {}
    local base = opts.base or 0
    local limit = opts.limit or 64
    local out = {}
    local pats = resolve_patterns(opts)
    for name, cp in pairs(pats) do
        local hits = scan_chunk(bytes, cp)
        for i, off in ipairs(hits) do
            if i > limit then break end
            out[#out + 1] = {
                address      = base + off,
                pattern_name = name,
                offset_in_buf = off,
                snippet      = hex_slice(bytes, off, math.min(16, cp.len)),
                context      = hex_slice(bytes, math.max(0, off - 8), 40),
            }
        end
    end
    return out
end

-- ===== scan_process / scan_module ======================================

-- mem is a soft dep -- only required when the caller invokes the live-process
-- entry points. Keep the require lazy so vuln_scan still loads in environments
-- where mem isn't installed (offline buffer scanning).
local _mem
local function load_mem()
    if _mem then return _mem end
    _mem = require "mem"
    return _mem
end

local function read_region(proc, base, size, max_chunk)
    -- Read a single region in capped chunks; concatenate.
    max_chunk = max_chunk or 0x40000  -- 256 KiB at a time
    local parts = {}
    local cur = 0
    while cur < size do
        local take = math.min(max_chunk, size - cur)
        local ok, data = pcall(function() return proc:read(base + cur, take) end)
        if not ok or not data then return nil end
        parts[#parts + 1] = data
        if #data < take then break end  -- short read = end of readable
        cur = cur + take
    end
    return table.concat(parts)
end

local PAGE_EXECUTE          = 0x10
local PAGE_EXECUTE_READ     = 0x20
local PAGE_EXECUTE_READWRITE = 0x40
local PAGE_EXECUTE_WRITECOPY = 0x80
local PAGE_NOACCESS         = 0x01

local function region_is_exec(prot)
    return prot == PAGE_EXECUTE
        or prot == PAGE_EXECUTE_READ
        or prot == PAGE_EXECUTE_READWRITE
        or prot == PAGE_EXECUTE_WRITECOPY
end

function M.scan_process(pid, opts)
    opts = opts or {}
    local mem = load_mem()
    local proc
    if type(pid) == "table" and pid.regions then  -- already a proc object
        proc = pid
    else
        proc = mem.open_process(pid)
    end

    local exec_only = (opts.exec_only ~= false)
    local pats = resolve_patterns(opts)
    local limit = opts.limit or 64

    -- module-scoped scan?
    local range_start, range_stop
    if opts.module then
        local m = proc:find_module(opts.module)
        if not m then
            if proc ~= pid then proc:close() end
            error("vuln_scan.scan_process: module '" .. opts.module .. "' not found")
        end
        range_start = m.base
        range_stop  = m.base + m.size
    end

    local out = {}
    local per_pattern_count = {}
    for name in pairs(pats) do per_pattern_count[name] = 0 end

    for mbi in proc:regions() do
        local base = mbi.base_address
        local size = mbi.region_size
        local prot = mbi.protect
        local skip = false
        if prot == PAGE_NOACCESS then skip = true end
        if exec_only and not region_is_exec(prot) then skip = true end
        if range_start and (base + size <= range_start or base >= range_stop) then
            skip = true
        end
        if not skip then
            local lo = range_start and math.max(base, range_start) or base
            local hi = range_stop  and math.min(base + size, range_stop) or (base + size)
            local sz = hi - lo
            if sz > 0 then
                local data = read_region(proc, lo, sz)
                if data then
                    for name, cp in pairs(pats) do
                        if per_pattern_count[name] < limit then
                            local hits = scan_chunk(data, cp)
                            for _, off in ipairs(hits) do
                                if per_pattern_count[name] >= limit then break end
                                per_pattern_count[name] = per_pattern_count[name] + 1
                                out[#out + 1] = {
                                    address      = lo + off,
                                    pattern_name = name,
                                    offset_in_buf = off,
                                    snippet      = hex_slice(data, off, math.min(16, cp.len)),
                                    context      = hex_slice(data, math.max(0, off - 8), 40),
                                }
                            end
                        end
                    end
                end
            end
        end
        -- safety: cap the upper search address so we don't traverse the
        -- full 48-bit user-mode space waiting for VirtualQuery to fail.
        if mbi.base_address > 0x7FFFFFFEFFFF then break end
    end

    if proc ~= pid then proc:close() end
    return out
end

function M.scan_module(pid, module_name, opts)
    opts = opts or {}
    opts.module = module_name
    return M.scan_process(pid, opts)
end

-- ===== ROP gadget finder ===============================================
--
-- Walks the buffer for ret-terminated short sequences. "Ret" = c3, c2 imm16,
-- cb, ca (far-ret). Also captures indirect jumps (ff e0..ff e7, ff 25 ...)
-- since those are used as JOP-style gadgets.
--
-- opts:
--   max_len      -- max gadget length (instructions, approximated as bytes)  default 16
--   include_jop  -- include indirect-jump terminations                       default true
--   base         -- address to add to offsets                                default 0
--   limit        -- max gadgets returned                                     default 1000

function M.find_ropgadgets(bytes, opts)
    if type(bytes) ~= "string" then error("vuln_scan.find_ropgadgets: bytes must be string") end
    opts = opts or {}
    local max_len = opts.max_len or 16
    local include_jop = (opts.include_jop ~= false)
    local base = opts.base or 0
    local limit = opts.limit or 1000

    local gadgets = {}
    local n = #bytes

    -- Indexable terminator set: position -> length consumed.
    local function is_terminator(i)
        local b = bytes:byte(i)
        if b == 0xC3 then return 1 end                       -- ret
        if b == 0xCB then return 1 end                       -- retf
        if b == 0xC2 and i + 2 <= n then return 3 end        -- ret imm16
        if b == 0xCA and i + 2 <= n then return 3 end        -- retf imm16
        if include_jop and b == 0xFF and i + 1 <= n then
            local b2 = bytes:byte(i + 1)
            -- jmp r/m64: FF E0..FF E7 (jmp rax..jmp r15-low)
            if b2 >= 0xE0 and b2 <= 0xE7 then return 2 end
            -- call r/m64: FF D0..FF D7
            if b2 >= 0xD0 and b2 <= 0xD7 then return 2 end
            -- jmp [rip+disp32]: FF 25 ?? ?? ?? ??
            if b2 == 0x25 and i + 5 <= n then return 6 end
        end
        return nil
    end

    for i = 1, n do
        local tlen = is_terminator(i)
        if tlen then
            -- Walk back up to max_len bytes; emit one gadget per starting offset.
            local start_min = math.max(1, i - max_len)
            for s = start_min, i do
                if #gadgets >= limit then break end
                local g = bytes:sub(s, i + tlen - 1)
                gadgets[#gadgets + 1] = {
                    address = base + s - 1,
                    length  = #g,
                    bytes   = g,
                    hex     = hex_slice(bytes, s - 1, #g),
                    terminator = string.format("%02X", bytes:byte(i)),
                }
            end
            if #gadgets >= limit then break end
        end
    end
    return gadgets
end

return M
