-- pe -- pure-Lua Portable Executable parser (PE32 + PE32+).
--
-- Public surface:
--   pe.parse(bytes_or_path)  -> pe object
--
-- pe object methods:
--   :header() / :headers()  -> { dos=, file=, optional=, machine=, magic=, bits=, dirs= }
--   :sections()        -> { {name, vsize, vaddr, rsize, raddr, chars}, ... }
--   :imports()         -> { {dll, functions={ {name, ordinal?, hint?}, ... }}, ... }
--   :exports()         -> { name=, base=, entries={ {name, ordinal, rva, forwarder?}, ...} }
--   :resources()       -> recursive tree { type, id|name, lang?, rva?, size?, codepage?, children?={} }
--   :relocations()     -> { {page_rva, entries={ {type, offset}, ... }}, ... }
--   :debug_directory() -> { {type, timestamp, size, rva, raddr, type_name}, ... }
--   :debug_info()      -> CodeView PDB info { pdb_path, guid, age } when present
--   :certificates()    -> { {length, revision, type, type_name, data}, ... }
--   :tls_callbacks()   -> { rva, ... }
--   :exception_data()  -> { {begin_addr, end_addr, unwind_info_rva}, ... }  (.pdata)
--   :strings(min_len?) -> { {section, offset, str}, ... }   default min_len=6
--   :rva_to_offset(rva)-> file offset or nil
--   :read_rva(rva, n)  -> raw bytes from RVA, or nil
--   :dump(opts?) / :dump_headers() -> formatted multi-line string
--
-- Why this lives in Lua: we want the parser to work without dbghelp, without
-- mapping the image into the process, and without any DLL. Useful for offline
-- triage of arbitrary blobs (compiler outputs, downloaded binaries, malware
-- samples) where reflective loading isn't safe.

local M = {}

-- ===== small binary reader =============================================

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("pe.parse: " .. tostring(err)) end
    local s = f:read("*a") or ""
    f:close()
    return s
end

local function looks_like_path(s)
    -- Heuristic: a valid PE starts with "MZ" (0x4D 0x5A). If the first two
    -- bytes are MZ assume it's already a buffer; otherwise treat as a path.
    if #s >= 2 and s:byte(1) == 0x4D and s:byte(2) == 0x5A then
        return false
    end
    return true
end

local function u8(buf, off)  return buf:byte(off + 1) end
local function u16(buf, off)
    local b1, b2 = buf:byte(off + 1), buf:byte(off + 2)
    if not b1 or not b2 then return 0 end
    return b1 + b2 * 0x100
end
local function u32(buf, off)
    local b1, b2, b3, b4 = buf:byte(off + 1), buf:byte(off + 2), buf:byte(off + 3), buf:byte(off + 4)
    if not b1 or not b2 or not b3 or not b4 then return 0 end
    return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
end
local function u64(buf, off)
    -- two halves; combine to a Lua number. Loses precision above 2^53,
    -- which is fine for PE: image bases and section sizes are well below.
    local lo = u32(buf, off)
    local hi = u32(buf, off + 4)
    return lo + hi * 4294967296
end
local function str_at(buf, off, n)
    return buf:sub(off + 1, off + n)
end
local function asciiz(buf, off, max)
    -- read a NUL-terminated ASCII string starting at off, capped at max bytes.
    local out = {}
    local i = 0
    while i < (max or 256) do
        local b = buf:byte(off + 1 + i)
        if not b or b == 0 then break end
        out[#out + 1] = string.char(b)
        i = i + 1
    end
    return table.concat(out)
end
local function utf16z(buf, off, n_chars)
    -- UCS-2 -> UTF-8 (only the BMP fast path; resource names are ASCII anyway).
    local out = {}
    for i = 0, n_chars - 1 do
        local c = u16(buf, off + i * 2)
        if c == 0 then break end
        if c < 0x80 then
            out[#out + 1] = string.char(c)
        elseif c < 0x800 then
            out[#out + 1] = string.char(0xC0 + math.floor(c / 0x40))
            out[#out + 1] = string.char(0x80 + (c % 0x40))
        else
            out[#out + 1] = string.char(0xE0 + math.floor(c / 0x1000))
            out[#out + 1] = string.char(0x80 + (math.floor(c / 0x40) % 0x40))
            out[#out + 1] = string.char(0x80 + (c % 0x40))
        end
    end
    return table.concat(out)
end

-- ===== machine / dir / section name tables =============================

local MACHINE_NAMES = {
    [0x014c] = "I386",
    [0x0200] = "IA64",
    [0x8664] = "AMD64",
    [0x01c0] = "ARM",
    [0x01c2] = "THUMB",
    [0x01c4] = "ARMNT",
    [0xaa64] = "ARM64",
}

local DIR_NAMES = {
    [0]  = "EXPORT",  [1]  = "IMPORT",  [2]  = "RESOURCE",  [3]  = "EXCEPTION",
    [4]  = "SECURITY",[5]  = "BASERELOC",[6] = "DEBUG",     [7]  = "ARCHITECTURE",
    [8]  = "GLOBALPTR",[9] = "TLS",     [10] = "LOAD_CONFIG",[11] = "BOUND_IMPORT",
    [12] = "IAT",     [13] = "DELAY_IMPORT",[14]="COM_DESCRIPTOR",
}

local DEBUG_TYPE_NAMES = {
    [0]  = "UNKNOWN",   [1]  = "COFF",      [2]  = "CODEVIEW",  [3]  = "FPO",
    [4]  = "MISC",      [5]  = "EXCEPTION", [6]  = "FIXUP",     [7]  = "OMAP_TO_SRC",
    [8]  = "OMAP_FROM_SRC",[9]="BORLAND",   [10] = "RESERVED10",[11] = "CLSID",
    [12] = "VC_FEATURE",[13] = "POGO",      [14] = "ILTCG",     [15] = "MPX",
    [16] = "REPRO",     [20] = "EX_DLLCHARACTERISTICS",
}

local CERT_TYPE_NAMES = {
    [0x0001] = "X509",
    [0x0002] = "PKCS_SIGNED_DATA",
    [0x0003] = "RESERVED_1",
    [0x0004] = "TS_STACK_SIGNED",
}

local RELOC_TYPE_NAMES = {
    [0] = "ABSOLUTE", [1] = "HIGH",  [2] = "LOW",       [3] = "HIGHLOW",
    [4] = "HIGHADJ",  [5] = "ARM_MOV32", [7] = "THUMB_MOV32",
    [9] = "MIPS_JMPADDR16",                [10] = "DIR64",
}

-- ===== core parser =====================================================

local Pe = {}
Pe.__index = Pe

local function parse_header(buf)
    if #buf < 0x40 then error("pe.parse: too small for DOS header") end
    if u16(buf, 0) ~= 0x5A4D then error("pe.parse: not an MZ image") end

    local e_lfanew = u32(buf, 0x3C)
    if e_lfanew + 24 > #buf then error("pe.parse: NT header offset out of range") end
    if u32(buf, e_lfanew) ~= 0x00004550 then
        error("pe.parse: missing PE signature at e_lfanew")
    end

    -- COFF FILE_HEADER
    local file_off = e_lfanew + 4
    local machine = u16(buf, file_off + 0)
    local n_sections = u16(buf, file_off + 2)
    local timestamp = u32(buf, file_off + 4)
    local sym_table = u32(buf, file_off + 8)
    local n_syms = u32(buf, file_off + 12)
    local opt_size = u16(buf, file_off + 16)
    local characteristics = u16(buf, file_off + 18)

    -- OPTIONAL_HEADER
    local opt_off = file_off + 20
    local magic = u16(buf, opt_off)
    local bits, opt
    if magic == 0x010B then
        bits = 32
        opt = {
            major_linker = u8(buf, opt_off + 2),
            minor_linker = u8(buf, opt_off + 3),
            size_of_code = u32(buf, opt_off + 4),
            size_of_initialized_data = u32(buf, opt_off + 8),
            size_of_uninitialized_data = u32(buf, opt_off + 12),
            entry_point = u32(buf, opt_off + 16),
            base_of_code = u32(buf, opt_off + 20),
            base_of_data = u32(buf, opt_off + 24),
            image_base = u32(buf, opt_off + 28),
            section_alignment = u32(buf, opt_off + 32),
            file_alignment = u32(buf, opt_off + 36),
            major_os_version = u16(buf, opt_off + 40),
            minor_os_version = u16(buf, opt_off + 42),
            major_image_version = u16(buf, opt_off + 44),
            minor_image_version = u16(buf, opt_off + 46),
            major_subsystem_version = u16(buf, opt_off + 48),
            minor_subsystem_version = u16(buf, opt_off + 50),
            size_of_image = u32(buf, opt_off + 56),
            size_of_headers = u32(buf, opt_off + 60),
            checksum = u32(buf, opt_off + 64),
            subsystem = u16(buf, opt_off + 68),
            dll_characteristics = u16(buf, opt_off + 70),
            number_of_rva_and_sizes = u32(buf, opt_off + 92),
            data_dirs_off = opt_off + 96,
        }
    elseif magic == 0x020B then
        bits = 64
        opt = {
            major_linker = u8(buf, opt_off + 2),
            minor_linker = u8(buf, opt_off + 3),
            size_of_code = u32(buf, opt_off + 4),
            size_of_initialized_data = u32(buf, opt_off + 8),
            size_of_uninitialized_data = u32(buf, opt_off + 12),
            entry_point = u32(buf, opt_off + 16),
            base_of_code = u32(buf, opt_off + 20),
            image_base = u64(buf, opt_off + 24),
            section_alignment = u32(buf, opt_off + 32),
            file_alignment = u32(buf, opt_off + 36),
            major_os_version = u16(buf, opt_off + 40),
            minor_os_version = u16(buf, opt_off + 42),
            major_image_version = u16(buf, opt_off + 44),
            minor_image_version = u16(buf, opt_off + 46),
            major_subsystem_version = u16(buf, opt_off + 48),
            minor_subsystem_version = u16(buf, opt_off + 50),
            size_of_image = u32(buf, opt_off + 56),
            size_of_headers = u32(buf, opt_off + 60),
            checksum = u32(buf, opt_off + 64),
            subsystem = u16(buf, opt_off + 68),
            dll_characteristics = u16(buf, opt_off + 70),
            number_of_rva_and_sizes = u32(buf, opt_off + 108),
            data_dirs_off = opt_off + 112,
        }
    else
        error(string.format("pe.parse: unknown optional header magic 0x%04X", magic))
    end

    -- Data directories
    local dirs = {}
    for i = 0, math.min(opt.number_of_rva_and_sizes, 16) - 1 do
        dirs[i] = {
            name = DIR_NAMES[i] or ("DIR" .. i),
            rva  = u32(buf, opt.data_dirs_off + i * 8),
            size = u32(buf, opt.data_dirs_off + i * 8 + 4),
        }
    end

    -- Section headers (right after optional header)
    local sec_off = opt_off + opt_size
    local sections = {}
    for i = 0, n_sections - 1 do
        local so = sec_off + i * 40
        sections[i + 1] = {
            name  = asciiz(buf, so, 8),
            vsize = u32(buf, so + 8),
            vaddr = u32(buf, so + 12),
            rsize = u32(buf, so + 16),
            raddr = u32(buf, so + 20),
            chars = u32(buf, so + 36),
        }
    end

    return {
        dos = { e_lfanew = e_lfanew },
        file = {
            machine = machine,
            machine_name = MACHINE_NAMES[machine] or string.format("UNKNOWN(0x%04X)", machine),
            n_sections = n_sections,
            timestamp = timestamp,
            symbol_table = sym_table,
            n_symbols = n_syms,
            optional_size = opt_size,
            characteristics = characteristics,
        },
        optional = opt,
        magic = magic,
        bits = bits,
        sections = sections,
        dirs = dirs,
    }
end

-- Translate an RVA to a file offset by walking the section table.
local function rva_to_off(hdrs, rva)
    if rva == 0 then return nil end
    for _, s in ipairs(hdrs.sections) do
        if rva >= s.vaddr and rva < s.vaddr + math.max(s.vsize, s.rsize) then
            return s.raddr + (rva - s.vaddr)
        end
    end
    -- Headers themselves are mapped 1:1 below size_of_headers
    if rva < hdrs.optional.size_of_headers then return rva end
    return nil
end

function M.parse(input)
    if type(input) ~= "string" then
        error("pe.parse: expected string (path or bytes)")
    end
    local buf
    if looks_like_path(input) then
        buf = read_file(input)
    else
        buf = input
    end
    local self = setmetatable({}, Pe)
    self._buf = buf
    self._hdrs = parse_header(buf)
    return self
end

function Pe:headers()
    return {
        dos      = self._hdrs.dos,
        file     = self._hdrs.file,
        optional = self._hdrs.optional,
        magic    = self._hdrs.magic,
        bits     = self._hdrs.bits,
        machine  = self._hdrs.file.machine_name,
        dirs     = self._hdrs.dirs,
    }
end

function Pe:sections()
    -- Return a shallow copy so callers can't mutate our state.
    local out = {}
    for i, s in ipairs(self._hdrs.sections) do
        out[i] = { name = s.name, vsize = s.vsize, vaddr = s.vaddr,
                   rsize = s.rsize, raddr = s.raddr, chars = s.chars }
    end
    return out
end

-- ----- imports ---------------------------------------------------------

function Pe:imports()
    local d = self._hdrs.dirs[1]
    if not d or d.rva == 0 then return {} end
    local off = rva_to_off(self._hdrs, d.rva)
    if not off then return {} end

    local out = {}
    local buf = self._buf
    local i = 0
    while true do
        local desc = off + i * 20
        local orig_first_thunk = u32(buf, desc + 0)
        local time_stamp       = u32(buf, desc + 4)
        local forwarder_chain  = u32(buf, desc + 8)
        local name_rva         = u32(buf, desc + 12)
        local first_thunk      = u32(buf, desc + 16)
        if orig_first_thunk == 0 and name_rva == 0 and first_thunk == 0 then break end

        local name_off = rva_to_off(self._hdrs, name_rva)
        local dll_name = name_off and asciiz(buf, name_off, 256) or "?"

        -- Walk the lookup table (ILT). Fallback to IAT if ILT is null
        -- (bound imports leave ILT empty).
        local thunk_rva = orig_first_thunk ~= 0 and orig_first_thunk or first_thunk
        local thunk_off = rva_to_off(self._hdrs, thunk_rva)
        local funcs = {}
        if thunk_off then
            local j = 0
            local entry_size = self._hdrs.bits == 64 and 8 or 4
            while true do
                local val_lo = u32(buf, thunk_off + j * entry_size)
                local val_hi = self._hdrs.bits == 64
                    and u32(buf, thunk_off + j * entry_size + 4) or 0
                if val_lo == 0 and val_hi == 0 then break end
                local is_ordinal
                if self._hdrs.bits == 64 then
                    is_ordinal = (val_hi >= 0x80000000)
                else
                    is_ordinal = (val_lo >= 0x80000000)
                end
                if is_ordinal then
                    local ord = val_lo % 0x10000
                    funcs[#funcs + 1] = { ordinal = ord }
                else
                    -- val_lo is RVA to IMAGE_IMPORT_BY_NAME { Hint:WORD, Name:asciiz }
                    local hn_off = rva_to_off(self._hdrs, val_lo)
                    if hn_off then
                        local hint = u16(buf, hn_off)
                        local nm   = asciiz(buf, hn_off + 2, 512)
                        funcs[#funcs + 1] = { name = nm, hint = hint }
                    else
                        funcs[#funcs + 1] = { name = "?" }
                    end
                end
                j = j + 1
            end
        end

        out[#out + 1] = {
            dll = dll_name,
            timestamp = time_stamp,
            forwarder_chain = forwarder_chain,
            functions = funcs,
        }
        i = i + 1
    end
    return out
end

-- ----- exports ---------------------------------------------------------

function Pe:exports()
    local d = self._hdrs.dirs[0]
    if not d or d.rva == 0 then return { entries = {} } end
    local off = rva_to_off(self._hdrs, d.rva)
    if not off then return { entries = {} } end

    local buf = self._buf
    local name_rva   = u32(buf, off + 12)
    local base       = u32(buf, off + 16)
    local n_funcs    = u32(buf, off + 20)
    local n_names    = u32(buf, off + 24)
    local funcs_rva  = u32(buf, off + 28)
    local names_rva  = u32(buf, off + 32)
    local nameords_rva = u32(buf, off + 36)

    local name_off = rva_to_off(self._hdrs, name_rva)
    local dll_name = name_off and asciiz(buf, name_off, 256) or "?"

    local funcs_off    = rva_to_off(self._hdrs, funcs_rva)
    local names_off    = rva_to_off(self._hdrs, names_rva)
    local nameords_off = rva_to_off(self._hdrs, nameords_rva)

    -- Build ordinal -> name reverse map.
    local ord_to_name = {}
    if names_off and nameords_off then
        for i = 0, n_names - 1 do
            local nm_rva = u32(buf, names_off + i * 4)
            local idx    = u16(buf, nameords_off + i * 2)
            local nm_off = rva_to_off(self._hdrs, nm_rva)
            if nm_off then
                ord_to_name[idx] = asciiz(buf, nm_off, 512)
            end
        end
    end

    -- Walk the function RVA table.
    local entries = {}
    if funcs_off then
        for i = 0, n_funcs - 1 do
            local f_rva = u32(buf, funcs_off + i * 4)
            if f_rva ~= 0 then
                local entry = { ordinal = base + i, rva = f_rva, name = ord_to_name[i] }
                -- Forwarded exports point inside the export directory itself.
                if f_rva >= d.rva and f_rva < d.rva + d.size then
                    local fwd_off = rva_to_off(self._hdrs, f_rva)
                    if fwd_off then
                        entry.forwarder = asciiz(buf, fwd_off, 512)
                    end
                end
                entries[#entries + 1] = entry
            end
        end
    end

    return { name = dll_name, base = base, entries = entries }
end

-- ----- resources -------------------------------------------------------

local RESOURCE_TYPE_NAMES = {
    [1]  = "CURSOR",     [2]  = "BITMAP",     [3]  = "ICON",
    [4]  = "MENU",       [5]  = "DIALOG",     [6]  = "STRING",
    [7]  = "FONTDIR",    [8]  = "FONT",       [9]  = "ACCELERATOR",
    [10] = "RCDATA",     [11] = "MESSAGETABLE",[12] = "GROUP_CURSOR",
    [14] = "GROUP_ICON", [16] = "VERSION",    [17] = "DLGINCLUDE",
    [19] = "PLUGPLAY",   [20] = "VXD",        [21] = "ANICURSOR",
    [22] = "ANIICON",    [23] = "HTML",       [24] = "MANIFEST",
}

local function read_res_dir(buf, base_off, dir_off, depth, hdrs)
    -- IMAGE_RESOURCE_DIRECTORY: char[16] + n_named:u16 + n_id:u16
    local n_named = u16(buf, dir_off + 12)
    local n_id    = u16(buf, dir_off + 14)
    local total = n_named + n_id
    local out = {}
    for i = 0, total - 1 do
        local entry_off = dir_off + 16 + i * 8
        local name_or_id = u32(buf, entry_off + 0)
        local data_off   = u32(buf, entry_off + 4)
        local is_named = name_or_id >= 0x80000000
        local id_part = name_or_id % 0x80000000
        local node = {}
        if is_named then
            local s_off = base_off + id_part
            local n = u16(buf, s_off)
            node.name = utf16z(buf, s_off + 2, n)
        else
            node.id = id_part
            if depth == 0 then
                node.type_name = RESOURCE_TYPE_NAMES[id_part]
            end
        end
        local is_subdir = data_off >= 0x80000000
        local child_off = data_off % 0x80000000
        if is_subdir then
            node.children = read_res_dir(buf, base_off, base_off + child_off, depth + 1, hdrs)
        else
            -- Leaf: IMAGE_RESOURCE_DATA_ENTRY { rva, size, codepage, reserved }
            local data_entry = base_off + child_off
            node.rva      = u32(buf, data_entry + 0)
            node.size     = u32(buf, data_entry + 4)
            node.codepage = u32(buf, data_entry + 8)
        end
        out[#out + 1] = node
    end
    return out
end

function Pe:resources()
    local d = self._hdrs.dirs[2]
    if not d or d.rva == 0 then return {} end
    local base_off = rva_to_off(self._hdrs, d.rva)
    if not base_off then return {} end
    return read_res_dir(self._buf, base_off, base_off, 0, self._hdrs)
end

-- ----- relocations -----------------------------------------------------

function Pe:relocations()
    local d = self._hdrs.dirs[5]
    if not d or d.rva == 0 then return {} end
    local off = rva_to_off(self._hdrs, d.rva)
    if not off then return {} end
    local end_off = off + d.size
    local buf = self._buf
    local out = {}
    while off < end_off do
        local page_rva = u32(buf, off + 0)
        local blk_size = u32(buf, off + 4)
        if blk_size < 8 then break end
        local n_entries = math.floor((blk_size - 8) / 2)
        local entries = {}
        for i = 0, n_entries - 1 do
            local w = u16(buf, off + 8 + i * 2)
            local typ = math.floor(w / 4096)
            local ofs = w % 4096
            entries[i + 1] = { type = typ, type_name = RELOC_TYPE_NAMES[typ], offset = ofs }
        end
        out[#out + 1] = { page_rva = page_rva, size = blk_size, entries = entries }
        off = off + blk_size
    end
    return out
end

-- ----- debug directory -------------------------------------------------

function Pe:debug_directory()
    local d = self._hdrs.dirs[6]
    if not d or d.rva == 0 then return {} end
    local off = rva_to_off(self._hdrs, d.rva)
    if not off then return {} end
    local n = math.floor(d.size / 28)
    local out = {}
    local buf = self._buf
    for i = 0, n - 1 do
        local e = off + i * 28
        local typ = u32(buf, e + 12)
        out[#out + 1] = {
            characteristics = u32(buf, e + 0),
            timestamp = u32(buf, e + 4),
            major_version = u16(buf, e + 8),
            minor_version = u16(buf, e + 10),
            type = typ,
            type_name = DEBUG_TYPE_NAMES[typ] or "?",
            size = u32(buf, e + 16),
            rva  = u32(buf, e + 20),
            raddr = u32(buf, e + 24),
        }
    end
    return out
end

-- ----- certificates ----------------------------------------------------

function Pe:certificates()
    -- Cert table is unique: the dir.rva is a *raw file offset*, not an RVA.
    local d = self._hdrs.dirs[4]
    if not d or d.rva == 0 then return {} end
    local off = d.rva
    local end_off = off + d.size
    local buf = self._buf
    local out = {}
    while off < end_off do
        local length   = u32(buf, off + 0)
        local revision = u16(buf, off + 4)
        local typ      = u16(buf, off + 6)
        if length < 8 then break end
        out[#out + 1] = {
            length   = length,
            revision = revision,
            type     = typ,
            type_name = CERT_TYPE_NAMES[typ] or "?",
            data     = str_at(buf, off + 8, length - 8),
        }
        -- 8-byte aligned per spec.
        local advance = length
        if advance % 8 ~= 0 then advance = advance + (8 - (advance % 8)) end
        off = off + advance
    end
    return out
end

-- ----- TLS callbacks ---------------------------------------------------

function Pe:tls_callbacks()
    local d = self._hdrs.dirs[9]
    if not d or d.rva == 0 then return {} end
    local off = rva_to_off(self._hdrs, d.rva)
    if not off then return {} end
    local buf = self._buf
    -- IMAGE_TLS_DIRECTORY{32,64}. AddressOfCallBacks is a VA, not an RVA.
    local cb_va
    local image_base = self._hdrs.optional.image_base
    if self._hdrs.bits == 64 then
        cb_va = u64(buf, off + 24)
    else
        cb_va = u32(buf, off + 12)
    end
    if cb_va == 0 then return {} end
    -- Convert VA -> RVA -> file offset.
    local rva = cb_va - image_base
    local cb_off = rva_to_off(self._hdrs, rva)
    if not cb_off then return {} end
    local out = {}
    local entry_size = self._hdrs.bits == 64 and 8 or 4
    local i = 0
    while true do
        local lo = u32(buf, cb_off + i * entry_size)
        local hi = self._hdrs.bits == 64 and u32(buf, cb_off + i * entry_size + 4) or 0
        if lo == 0 and hi == 0 then break end
        local va = lo + hi * 4294967296
        out[#out + 1] = va - image_base
        i = i + 1
    end
    return out
end

-- ----- strings ---------------------------------------------------------

function Pe:strings(min_len)
    min_len = min_len or 6
    local buf = self._buf
    local out = {}
    -- Scan readable initialized-data sections, not code, to keep noise down.
    for _, s in ipairs(self._hdrs.sections) do
        local lname = s.name:lower()
        if lname:match("rdata") or lname:match("data") or lname == ".text" then
            local lo = s.raddr
            local hi = math.min(s.raddr + s.rsize, #buf)
            local run_start
            for i = lo, hi - 1 do
                local b = buf:byte(i + 1)
                if b and b >= 0x20 and b < 0x7F then
                    if not run_start then run_start = i end
                else
                    if run_start and (i - run_start) >= min_len then
                        out[#out + 1] = {
                            section = s.name,
                            offset = run_start,
                            str = buf:sub(run_start + 1, i),
                        }
                    end
                    run_start = nil
                end
            end
            if run_start and (hi - run_start) >= min_len then
                out[#out + 1] = {
                    section = s.name,
                    offset = run_start,
                    str = buf:sub(run_start + 1, hi),
                }
            end
        end
    end
    return out
end

-- ----- aliases / RVA helpers / debug_info / exception_data -------------

Pe.header = Pe.headers

function Pe:rva_to_offset(rva)
    return rva_to_off(self._hdrs, rva)
end

function Pe:read_rva(rva, n)
    local off = rva_to_off(self._hdrs, rva)
    if not off then return nil end
    if off + n > #self._buf then n = math.max(0, #self._buf - off) end
    return self._buf:sub(off + 1, off + n)
end

-- Decode CodeView (PDB7) records inside the debug directory.
function Pe:debug_info()
    local out = {}
    for _, ent in ipairs(self:debug_directory()) do
        if ent.type == 2 and ent.size >= 24 then
            -- IMAGE_DEBUG_TYPE_CODEVIEW. RSDS layout (PDB7):
            --   'RSDS'(4) GUID(16) Age(4) PdbPath(asciiz)
            local off = ent.raddr
            local buf = self._buf
            if off > 0 and off + ent.size <= #buf then
                local sig = buf:sub(off + 1, off + 4)
                if sig == "RSDS" then
                    local d1 = u32(buf, off + 4)
                    local d2 = u16(buf, off + 8)
                    local d3 = u16(buf, off + 10)
                    local b1 = buf:byte(off + 13) or 0
                    local b2 = buf:byte(off + 14) or 0
                    local b3 = buf:byte(off + 15) or 0
                    local b4 = buf:byte(off + 16) or 0
                    local b5 = buf:byte(off + 17) or 0
                    local b6 = buf:byte(off + 18) or 0
                    local b7 = buf:byte(off + 19) or 0
                    local b8 = buf:byte(off + 20) or 0
                    local guid = string.format(
                        "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                        d1, d2, d3, b1, b2, b3, b4, b5, b6, b7, b8)
                    local age = u32(buf, off + 20)
                    local pdb_path = asciiz(buf, off + 24, ent.size - 24)
                    out[#out + 1] = {
                        kind = "RSDS",
                        guid = guid,
                        age = age,
                        pdb_path = pdb_path,
                        timestamp = ent.timestamp,
                    }
                elseif sig == "NB10" then
                    out[#out + 1] = {
                        kind = "NB10",
                        timestamp = ent.timestamp,
                        pdb_path = asciiz(buf, off + 16, ent.size - 16),
                    }
                end
            end
        end
    end
    return out
end

-- .pdata: x64 RUNTIME_FUNCTION array (begin_addr/end_addr/unwind_info_rva, 12B each).
function Pe:exception_data()
    local d = self._hdrs.dirs[3]
    if not d or d.rva == 0 then return {} end
    local off = rva_to_off(self._hdrs, d.rva)
    if not off then return {} end
    local out = {}
    local n = math.floor(d.size / 12)
    local buf = self._buf
    for i = 0, n - 1 do
        local e = off + i * 12
        local ba = u32(buf, e + 0)
        local ea = u32(buf, e + 4)
        local ui = u32(buf, e + 8)
        if ba == 0 and ea == 0 then break end
        out[#out + 1] = {
            begin_addr = ba,
            end_addr = ea,
            unwind_info_rva = ui,
        }
    end
    return out
end

-- ----- dump / dump_headers ---------------------------------------------

function Pe:dump_headers()
    local h = self._hdrs
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add(string.format("PE%s -- machine %s -- %d sections",
        h.bits == 64 and "32+" or "32", h.file.machine_name, h.file.n_sections))
    add(string.format("    entry_point      = 0x%08X", h.optional.entry_point))
    add(string.format("    image_base       = 0x%X", h.optional.image_base))
    add(string.format("    size_of_image    = 0x%X", h.optional.size_of_image))
    add(string.format("    size_of_headers  = 0x%X", h.optional.size_of_headers))
    add(string.format("    subsystem        = %d", h.optional.subsystem))
    add(string.format("    dll_characteristics = 0x%04X", h.optional.dll_characteristics))
    add("")
    add("    Section          VAddr      VSize      RAddr      RSize")
    add("    -------          -----      -----      -----      -----")
    for _, s in ipairs(h.sections) do
        add(string.format("    %-16s %08X   %08X   %08X   %08X",
            s.name, s.vaddr, s.vsize, s.raddr, s.rsize))
    end
    add("")
    add("    Directory        RVA        Size")
    add("    ---------        ---        ----")
    for i = 0, 15 do
        local d = h.dirs[i]
        if d and (d.rva ~= 0 or d.size ~= 0) then
            add(string.format("    %-16s %08X   %08X", d.name, d.rva, d.size))
        end
    end
    return table.concat(lines, "\n")
end

-- Compact dump: headers + sections + imports/exports/debug summary.
function Pe:dump(opts)
    opts = opts or {}
    local lines = { self:dump_headers() }
    local function add(s) lines[#lines + 1] = s end

    if opts.imports ~= false then
        local imps = self:imports()
        if #imps > 0 then
            add("")
            add("    Imports")
            add("    -------")
            for _, im in ipairs(imps) do
                add(string.format("    %s  (%d functions)", im.dll, #im.functions))
                if opts.verbose then
                    for _, f in ipairs(im.functions) do
                        if f.name then
                            add(string.format("        %s", f.name))
                        else
                            add(string.format("        @%d", f.ordinal or 0))
                        end
                    end
                end
            end
        end
    end

    if opts.exports ~= false then
        local exp = self:exports()
        if exp.entries and #exp.entries > 0 then
            add("")
            add(string.format("    Exports of %s (base=%d, %d entries)",
                exp.name or "?", exp.base or 0, #exp.entries))
            add("    -------")
            local limit = opts.verbose and #exp.entries or math.min(#exp.entries, 16)
            for i = 1, limit do
                local e = exp.entries[i]
                add(string.format("        %5d  %08X  %s",
                    e.ordinal, e.rva, e.name or (e.forwarder or "")))
            end
            if limit < #exp.entries then
                add(string.format("        ... (%d more)", #exp.entries - limit))
            end
        end
    end

    if opts.debug ~= false then
        local di = self:debug_info()
        if #di > 0 then
            add("")
            add("    Debug")
            add("    -----")
            for _, d in ipairs(di) do
                if d.kind == "RSDS" then
                    add(string.format("        RSDS  %s  age=%d  %s",
                        d.guid, d.age, d.pdb_path or ""))
                else
                    add(string.format("        %s  %s", d.kind, d.pdb_path or ""))
                end
            end
        end
    end

    if opts.tls ~= false then
        local tls = self:tls_callbacks()
        if #tls > 0 then
            add("")
            add(string.format("    TLS callbacks (%d)", #tls))
            for _, rva in ipairs(tls) do
                add(string.format("        rva=0x%X", rva))
            end
        end
    end

    return table.concat(lines, "\n")
end

return M
