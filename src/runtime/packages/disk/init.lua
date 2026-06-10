-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- disk -- volume + physical-drive enumeration, SMART attribute decoding.
--
-- Public surface:
--   disk.volumes()                -> { { root, label, fs_type, serial,
--                                        total_gb, free_gb, available_gb,
--                                        max_component_length, flags,
--                                        drive_type }, ... }
--   disk.free_space(path)         -> { total_bytes, free_bytes, available_bytes }
--   disk.drive_type(path)         -> "fixed"|"removable"|"network"|"cdrom"|"ramdisk"|"unknown"
--   disk.physical_drives()        -> { { index, model, serial, size_gb,
--                                        sector_size, media_type, partitions }, ... }
--   disk.smart(drive_index)       -> { health, temperature_c, power_on_hours,
--                                       attributes = { { id, value, worst, raw }, ... } }
--                                  | nil  (admin required / unsupported)

local W = require "windows"

ffi.cdef[[
DWORD  GetLogicalDriveStringsW(DWORD, LPWSTR);
DWORD  GetLogicalDriveStringsA(DWORD, LPSTR);
UINT   GetDriveTypeW(LPCWSTR);
BOOL   GetVolumeInformationW(LPCWSTR, LPWSTR, DWORD, LPDWORD, LPDWORD, LPDWORD, LPWSTR, DWORD);
BOOL   GetDiskFreeSpaceExW(LPCWSTR, ULONGLONG *, ULONGLONG *, ULONGLONG *);

BOOL   DeviceIoControl(HANDLE, DWORD, LPVOID, DWORD, LPVOID, DWORD, LPDWORD, OVERLAPPED *);

typedef struct _DISK_GEOMETRY {
    LONGLONG  Cylinders;
    DWORD     MediaType;
    DWORD     TracksPerCylinder;
    DWORD     SectorsPerTrack;
    DWORD     BytesPerSector;
} DISK_GEOMETRY;

typedef struct _DISK_GEOMETRY_EX {
    DISK_GEOMETRY Geometry;
    LONGLONG      DiskSize;
    BYTE          Data[1];
} DISK_GEOMETRY_EX;

/* IOCTL_STORAGE_QUERY_PROPERTY plumbing */
typedef struct _STORAGE_PROPERTY_QUERY {
    DWORD PropertyId;
    DWORD QueryType;
    BYTE  AdditionalParameters[1];
} STORAGE_PROPERTY_QUERY;

typedef struct _STORAGE_DEVICE_DESCRIPTOR {
    DWORD Version;
    DWORD Size;
    BYTE  DeviceType;
    BYTE  DeviceTypeModifier;
    BYTE  RemovableMedia;
    BYTE  CommandQueueing;
    DWORD VendorIdOffset;
    DWORD ProductIdOffset;
    DWORD ProductRevisionOffset;
    DWORD SerialNumberOffset;
    DWORD BusType;
    DWORD RawPropertiesLength;
    BYTE  RawDeviceProperties[1];
} STORAGE_DEVICE_DESCRIPTOR;

/* SMART -- the legacy IDE-style path, still works for most SATA via libata
   translation. NVMe needs StorageDeviceProtocolSpecificProperty (omitted). */
typedef struct _GETVERSIONINPARAMS {
    BYTE  bVersion;
    BYTE  bRevision;
    BYTE  bReserved;
    BYTE  bIDEDeviceMap;
    DWORD fCapabilities;
    DWORD dwReserved[4];
} GETVERSIONINPARAMS;

typedef struct _IDEREGS {
    BYTE bFeaturesReg;
    BYTE bSectorCountReg;
    BYTE bSectorNumberReg;
    BYTE bCylLowReg;
    BYTE bCylHighReg;
    BYTE bDriveHeadReg;
    BYTE bCommandReg;
    BYTE bReserved;
} IDEREGS;

typedef struct _SENDCMDINPARAMS {
    DWORD    cBufferSize;
    IDEREGS  irDriveRegs;
    BYTE     bDriveNumber;
    BYTE     bReserved[3];
    DWORD    dwReserved[4];
    BYTE     bBuffer[1];
} SENDCMDINPARAMS;

typedef struct _DRIVERSTATUS {
    BYTE  bDriverError;
    BYTE  bIDEError;
    BYTE  bReserved[2];
    DWORD dwReserved[2];
} DRIVERSTATUS;

typedef struct _SENDCMDOUTPARAMS {
    DWORD        cBufferSize;
    DRIVERSTATUS DriverStatus;
    BYTE         bBuffer[1];
} SENDCMDOUTPARAMS;
]]

local C = ffi.C
local M = {}

-- IOCTLs (computed once)
local function CTL_CODE(devtype, fn, method, access)
    return (devtype * 0x10000) + (access * 0x4000) + (fn * 4) + method
end
local FILE_DEVICE_DISK    = 7
local FILE_DEVICE_CONTROLLER = 4
local METHOD_BUFFERED     = 0
local FILE_ANY_ACCESS     = 0
local FILE_READ_ACCESS    = 1
local FILE_WRITE_ACCESS   = 2

local IOCTL_DISK_GET_DRIVE_GEOMETRY    = CTL_CODE(FILE_DEVICE_DISK, 0x0000, METHOD_BUFFERED, FILE_ANY_ACCESS)
local IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = CTL_CODE(FILE_DEVICE_DISK, 0x0028, METHOD_BUFFERED, FILE_ANY_ACCESS)
local IOCTL_STORAGE_QUERY_PROPERTY     = CTL_CODE(0x002d,             0x0500, METHOD_BUFFERED, FILE_ANY_ACCESS)
local SMART_GET_VERSION                = CTL_CODE(FILE_DEVICE_CONTROLLER, 0x0020, METHOD_BUFFERED, FILE_READ_ACCESS)
local SMART_RCV_DRIVE_DATA             = CTL_CODE(FILE_DEVICE_CONTROLLER, 0x0022, METHOD_BUFFERED, FILE_READ_ACCESS + FILE_WRITE_ACCESS)

local DRIVE_TYPES = {
    [0] = "unknown", [1] = "no_root", [2] = "removable",
    [3] = "fixed",   [4] = "network", [5] = "cdrom", [6] = "ramdisk",
}
local DRIVE_TYPE_SHORT = {
    [2] = "removable", [3] = "fixed", [4] = "network",
    [5] = "cdrom",     [6] = "ramdisk",
}

-- BusTypeUnknown = 0; the most useful values:
local BUS_TYPES = {
    [0]="unknown",[1]="scsi",[2]="atapi",[3]="ata",[4]="1394",[5]="ssa",
    [6]="fibre",[7]="usb",[8]="raid",[9]="iscsi",[10]="sas",[11]="sata",
    [12]="sd",[13]="mmc",[14]="virtual",[15]="filebackedvirtual",
    [16]="spaces",[17]="nvme",[18]="scm",[19]="ufs",
}

-- ===== helpers =============================================================

local function wide(s) return W.ToWide(s) end

local function strip_trailing_null(s)
    return (s:gsub("%z+$", ""):gsub("%s+$", ""))
end

local function ascii_from_offset(base_ptr, base_len, offset)
    if offset == 0 or offset >= base_len then return nil end
    local p = ffi.cast("char *", base_ptr) + offset
    return strip_trailing_null(ffi.string(p))
end

-- ===== volumes() ===========================================================

function M.drive_type(path)
    local w = wide(path)
    local t = tonumber(C.GetDriveTypeW(w))
    return DRIVE_TYPES[t] or "unknown"
end

local function get_volume_info(root_wide)
    local label = ffi.new("unsigned short[260]")
    local fs    = ffi.new("unsigned short[64]")
    local serial = ffi.new("DWORD[1]")
    local mcl    = ffi.new("DWORD[1]")
    local flags  = ffi.new("DWORD[1]")
    if C.GetVolumeInformationW(root_wide, label, 260,
            serial, mcl, flags, fs, 64) == 0 then
        return nil
    end
    return {
        label                = W.FromWide(label),
        fs_type              = W.FromWide(fs),
        serial               = string.format("%08X", tonumber(serial[0])),
        max_component_length = tonumber(mcl[0]),
        flags                = tonumber(flags[0]),
    }
end

local function get_free_space(root_wide)
    local avail = ffi.new("ULONGLONG[1]")
    local total = ffi.new("ULONGLONG[1]")
    local free  = ffi.new("ULONGLONG[1]")
    if C.GetDiskFreeSpaceExW(root_wide, avail, total, free) == 0 then
        return nil
    end
    return {
        available_bytes = tonumber(avail[0]),
        total_bytes     = tonumber(total[0]),
        free_bytes      = tonumber(free[0]),
    }
end

function M.free_space(path)
    return get_free_space(wide(path))
end

function M.volumes()
    local buf = ffi.new("unsigned short[1024]")
    local n = C.GetLogicalDriveStringsW(1024, buf)
    if n == 0 then return {} end
    local out = {}
    local i = 0
    while i < n do
        local start = i
        while buf[i] ~= 0 do i = i + 1 end
        if i == start then break end
        -- copy the slice into a fresh zero-terminated buffer
        local slice = ffi.new("unsigned short[?]", (i - start) + 1)
        ffi.copy(slice, buf + start, (i - start) * 2)
        slice[i - start] = 0
        local root = W.FromWide(slice)
        local t = M.drive_type(root)
        local rec = { root = root, drive_type = t }
        local v = get_volume_info(slice)
        if v then for k, val in pairs(v) do rec[k] = val end end
        local s = get_free_space(slice)
        if s then
            rec.total_gb     = s.total_bytes / (1024 ^ 3)
            rec.free_gb      = s.free_bytes / (1024 ^ 3)
            rec.available_gb = s.available_bytes / (1024 ^ 3)
        end
        out[#out + 1] = rec
        i = i + 1
    end
    return out
end

-- ===== physical_drives() ==================================================

local OPEN_EXISTING = 3
local GENERIC_READ  = 0x80000000
local GENERIC_WRITE = 0x40000000
local FILE_SHARE_READ  = 0x00000001
local FILE_SHARE_WRITE = 0x00000002

local function open_physical(idx, write)
    local path = string.format("\\\\.\\PhysicalDrive%d", idx)
    local access = write and bit.bor(GENERIC_READ, GENERIC_WRITE) or 0
    -- 0 access works for IOCTLs that don't read/write data (geometry, query
    -- property). SMART needs read+write.
    local h = C.CreateFileW(wide(path), access,
        bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE),
        nil, OPEN_EXISTING, 0, nil)
    if h == W.INVALID_HANDLE_VALUE then return nil end
    return h
end

local function get_geometry(h)
    local out = ffi.new("DISK_GEOMETRY_EX[1]")
    local ret = ffi.new("DWORD[1]")
    if C.DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,
            nil, 0, out, ffi.sizeof("DISK_GEOMETRY_EX"),
            ret, nil) == 0 then
        return nil
    end
    return {
        size_bytes  = tonumber(out[0].DiskSize),
        sector_size = tonumber(out[0].Geometry.BytesPerSector),
        media_type  = tonumber(out[0].Geometry.MediaType),
    }
end

local function get_storage_descriptor(h)
    local q = ffi.new("STORAGE_PROPERTY_QUERY[1]")
    q[0].PropertyId = 0  -- StorageDeviceProperty
    q[0].QueryType  = 0  -- PropertyStandardQuery
    local cap = 4096
    local out = ffi.new("char[?]", cap)
    local ret = ffi.new("DWORD[1]")
    if C.DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY,
            q, ffi.sizeof("STORAGE_PROPERTY_QUERY"),
            out, cap, ret, nil) == 0 then
        return nil
    end
    local d = ffi.cast("STORAGE_DEVICE_DESCRIPTOR *", out)
    return {
        bus_type = BUS_TYPES[tonumber(d.BusType)] or "unknown",
        vendor   = ascii_from_offset(out, cap, tonumber(d.VendorIdOffset)),
        product  = ascii_from_offset(out, cap, tonumber(d.ProductIdOffset)),
        revision = ascii_from_offset(out, cap, tonumber(d.ProductRevisionOffset)),
        serial   = ascii_from_offset(out, cap, tonumber(d.SerialNumberOffset)),
        removable = d.RemovableMedia ~= 0,
    }
end

function M.physical_drives()
    local out = {}
    for idx = 0, 31 do
        local h = open_physical(idx, false)
        if h == nil then
            if idx >= 2 then break end  -- no more drives
        else
            local geom = get_geometry(h)
            local desc = get_storage_descriptor(h)
            if geom then
                local rec = {
                    index       = idx,
                    size_gb     = geom.size_bytes / (1024 ^ 3),
                    sector_size = geom.sector_size,
                    media_type  = geom.media_type,
                    model       = nil,
                    serial      = nil,
                    bus_type    = nil,
                    partitions  = {},  -- (filled below if cheap)
                }
                if desc then
                    rec.model    = ((desc.vendor or "") .. " " .. (desc.product or "")):gsub("^%s+", ""):gsub("%s+$", "")
                    if rec.model == "" then rec.model = nil end
                    rec.serial   = desc.serial
                    rec.bus_type = desc.bus_type
                    rec.removable = desc.removable
                end
                out[#out + 1] = rec
            end
            C.CloseHandle(h)
        end
    end
    return out
end

-- ===== SMART ==============================================================

local SMART_CYL_LOW   = 0x4F
local SMART_CYL_HI    = 0xC2
local SMART_CMD       = 0xB0
local ID_CMD          = 0xEC
local READ_ATTRIBUTES = 0xD0
local READ_THRESHOLDS = 0xD1

-- SMART attribute record layout (12 bytes each, 30 records):
--   offset 0  : id          (1)
--   offset 1  : flags       (2)
--   offset 3  : value       (1)
--   offset 4  : worst       (1)
--   offset 5  : raw[6]      (6 bytes little-endian)
--   offset 11 : reserved    (1)

local KNOWN_SMART = {
    [0x05] = "reallocated_sectors",
    [0x09] = "power_on_hours",
    [0x0A] = "spin_retry_count",
    [0x0B] = "calibration_retry",
    [0x0C] = "power_cycle_count",
    [0xBB] = "uncorrectable_errors",
    [0xBE] = "airflow_temperature",
    [0xC0] = "power_off_retract",
    [0xC2] = "temperature",
    [0xC5] = "current_pending_sectors",
    [0xC6] = "offline_uncorrectable",
    [0xC7] = "udma_crc_error_count",
    [0xE7] = "ssd_life_left",
    [0xE9] = "media_wearout",
}

local function smart_decode_attributes(buf)
    -- buf is the 512-byte attribute response; offsets 2..361 hold up to 30
    -- 12-byte attribute records.
    local out = {}
    for i = 0, 29 do
        local off = 2 + i * 12
        local id  = buf[off]
        if id ~= 0 then
            local raw = 0
            for j = 0, 5 do
                raw = raw + (buf[off + 5 + j] * (256 ^ j))
            end
            out[#out + 1] = {
                id    = id,
                name  = KNOWN_SMART[id],
                value = buf[off + 3],
                worst = buf[off + 4],
                raw   = raw,
            }
        end
    end
    return out
end

function M.smart(idx)
    local h = open_physical(idx or 0, true)
    if h == nil then return nil end

    -- Step 1: confirm SMART is supported.
    local ver = ffi.new("GETVERSIONINPARAMS[1]")
    local ret = ffi.new("DWORD[1]")
    if C.DeviceIoControl(h, SMART_GET_VERSION,
            nil, 0, ver, ffi.sizeof("GETVERSIONINPARAMS"),
            ret, nil) == 0 then
        C.CloseHandle(h); return nil
    end

    -- Step 2: ask for SMART attributes.
    local READ_ATTR_BUFFER_SIZE = 512
    local in_size  = ffi.sizeof("SENDCMDINPARAMS")
    local out_size = ffi.sizeof("SENDCMDOUTPARAMS") + READ_ATTR_BUFFER_SIZE
    local in_buf   = ffi.new("char[?]", in_size)
    local out_buf  = ffi.new("char[?]", out_size)

    local sin = ffi.cast("SENDCMDINPARAMS *", in_buf)
    sin.cBufferSize = READ_ATTR_BUFFER_SIZE
    sin.bDriveNumber = idx or 0
    sin.irDriveRegs.bFeaturesReg     = READ_ATTRIBUTES
    sin.irDriveRegs.bSectorCountReg  = 1
    sin.irDriveRegs.bSectorNumberReg = 1
    sin.irDriveRegs.bCylLowReg       = SMART_CYL_LOW
    sin.irDriveRegs.bCylHighReg      = SMART_CYL_HI
    sin.irDriveRegs.bDriveHeadReg    = 0xA0
    sin.irDriveRegs.bCommandReg      = SMART_CMD

    if C.DeviceIoControl(h, SMART_RCV_DRIVE_DATA,
            in_buf, in_size, out_buf, out_size, ret, nil) == 0 then
        C.CloseHandle(h); return nil
    end

    local sout = ffi.cast("SENDCMDOUTPARAMS *", out_buf)
    local pBuf = ffi.cast("BYTE *", ffi.cast("char *", out_buf) +
        ffi.offsetof("SENDCMDOUTPARAMS", "bBuffer"))
    -- Re-cast as a uint8 array we can index directly.
    local attrs = ffi.new("uint8_t[?]", READ_ATTR_BUFFER_SIZE)
    ffi.copy(attrs, pBuf, READ_ATTR_BUFFER_SIZE)

    local list = smart_decode_attributes(attrs)
    local health = "ok"
    local temperature_c, power_on_hours
    for _, a in ipairs(list) do
        if a.name == "temperature" then
            temperature_c = a.raw % 256
        elseif a.name == "airflow_temperature" then
            temperature_c = temperature_c or (a.raw % 256)
        elseif a.name == "power_on_hours" then
            power_on_hours = a.raw
        end
        -- Pre-fail attribute threshold breach: per SMART spec, value < threshold
        -- means failure imminent. We don't have thresholds; treat low values
        -- on critical attributes (reallocated_sectors etc.) as warning.
        if a.value < 30 and (a.name == "reallocated_sectors"
                          or a.name == "current_pending_sectors"
                          or a.name == "offline_uncorrectable") then
            health = "failing"
        end
    end

    C.CloseHandle(h)
    return {
        attributes      = list,
        health          = health,
        temperature_c   = temperature_c,
        power_on_hours  = power_on_hours,
    }
end

return M
