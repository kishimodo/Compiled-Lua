-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- usb -- USB device enumeration via SetupAPI.
--
-- Public surface:
--   usb.devices()                    -> { { vendor_id, product_id, vendor,
--                                           manufacturer, product_name, serial_number,
--                                           device_class, device_path, parent,
--                                           hub_port, speed, hardware_id }, ... }
--   usb.hubs()                       -> list of USB hub records
--   usb.find(vid, pid?)              -> matching devices
--   usb.by_class(class_guid_string)  -> devices in a specific setup class
--
-- The "speed" field is best-effort. SetupAPI doesn't expose the link speed
-- directly; we leave it nil. (Reaching it requires opening the parent hub
-- via DeviceIoControl + IOCTL_USB_GET_NODE_CONNECTION_INFORMATION, which
-- requires admin and is out of scope for this package.)

local W = require "windows"

ffi.cdef[[
typedef struct _SP_DEVINFO_DATA {
    DWORD     cbSize;
    GUID_W    ClassGuid;
    DWORD     DevInst;
    UINT_PTR  Reserved;
} SP_DEVINFO_DATA;

typedef struct _SP_DEVICE_INTERFACE_DATA {
    DWORD     cbSize;
    GUID_W    InterfaceClassGuid;
    DWORD     Flags;
    UINT_PTR  Reserved;
} SP_DEVICE_INTERFACE_DATA;

typedef struct _SP_DEVICE_INTERFACE_DETAIL_DATA_W {
    DWORD          cbSize;
    unsigned short DevicePath[1];
} SP_DEVICE_INTERFACE_DETAIL_DATA_W;

HANDLE SetupDiGetClassDevsW(GUID_W *ClassGuid, LPCWSTR Enumerator,
    HWND hwndParent, DWORD Flags);
BOOL   SetupDiDestroyDeviceInfoList(HANDLE DeviceInfoSet);

BOOL   SetupDiEnumDeviceInfo(HANDLE DeviceInfoSet, DWORD MemberIndex,
    SP_DEVINFO_DATA *DeviceInfoData);

BOOL   SetupDiEnumDeviceInterfaces(HANDLE DeviceInfoSet,
    SP_DEVINFO_DATA *DeviceInfoData, GUID_W *InterfaceClassGuid,
    DWORD MemberIndex, SP_DEVICE_INTERFACE_DATA *DeviceInterfaceData);

BOOL   SetupDiGetDeviceInterfaceDetailW(HANDLE DeviceInfoSet,
    SP_DEVICE_INTERFACE_DATA *DeviceInterfaceData,
    SP_DEVICE_INTERFACE_DETAIL_DATA_W *DeviceInterfaceDetailData,
    DWORD DeviceInterfaceDetailDataSize, DWORD *RequiredSize,
    SP_DEVINFO_DATA *DeviceInfoData);

BOOL   SetupDiGetDeviceRegistryPropertyW(HANDLE DeviceInfoSet,
    SP_DEVINFO_DATA *DeviceInfoData, DWORD Property, DWORD *PropertyRegDataType,
    BYTE *PropertyBuffer, DWORD PropertyBufferSize, DWORD *RequiredSize);

DWORD  CM_Get_Parent(DWORD *pdnDevInst, DWORD dnDevInst, ULONG ulFlags);
DWORD  CM_Get_Device_IDW(DWORD dnDevInst, LPWSTR Buffer, ULONG BufferLen, ULONG ulFlags);
]]

-- Lazy load to keep the package usable even when SetupAPI isn't reachable
-- (e.g. nano-server). Failure raises only at first call.
local _setupapi, _cfgmgr
local function setupapi()
    if _setupapi then return _setupapi end
    _setupapi = ffi.load("setupapi")
    return _setupapi
end
local function cfgmgr()
    if _cfgmgr then return _cfgmgr end
    _cfgmgr = ffi.load("cfgmgr32")
    return _cfgmgr
end

local C = ffi.C
local M = {}

-- ===== GUIDs ==============================================================

local function make_guid(d1, d2, d3, d4)
    local g = ffi.new("GUID_W")
    g.Data1 = d1; g.Data2 = d2; g.Data3 = d3
    for i = 0, 7 do g.Data4[i] = d4[i + 1] end
    return g
end

-- GUID_DEVINTERFACE_USB_DEVICE = A5DCBF10-6530-11D2-901F-00C04FB951ED
local GUID_DEVINTERFACE_USB_DEVICE = make_guid(0xA5DCBF10, 0x6530, 0x11D2,
    { 0x90, 0x1F, 0x00, 0xC0, 0x4F, 0xB9, 0x51, 0xED })

-- GUID_DEVINTERFACE_USB_HUB    = F18A0E88-C30C-11D0-8815-00A0C906BED8
local GUID_DEVINTERFACE_USB_HUB = make_guid(0xF18A0E88, 0xC30C, 0x11D0,
    { 0x88, 0x15, 0x00, 0xA0, 0xC9, 0x06, 0xBE, 0xD8 })

local function parse_guid(s)
    local d1, d2, d3, d4hi, d4lo = s:match(
        "^{?(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x+)}?$")
    if not d1 then error("usb: bad GUID string " .. tostring(s)) end
    local g = ffi.new("GUID_W")
    g.Data1 = tonumber(d1, 16)
    g.Data2 = tonumber(d2, 16)
    g.Data3 = tonumber(d3, 16)
    g.Data4[0] = tonumber(d4hi:sub(1, 2), 16)
    g.Data4[1] = tonumber(d4hi:sub(3, 4), 16)
    for i = 0, 5 do
        g.Data4[2 + i] = tonumber(d4lo:sub(i * 2 + 1, i * 2 + 2), 16)
    end
    return g
end

-- ===== SetupAPI constants =================================================

local DIGCF_PRESENT         = 0x02
local DIGCF_DEVICEINTERFACE = 0x10
local DIGCF_ALLCLASSES      = 0x04

-- SPDRP_*: device registry property identifiers we care about.
local SPDRP_DEVICEDESC               = 0x00
local SPDRP_HARDWAREID               = 0x01
local SPDRP_COMPATIBLEIDS            = 0x02
local SPDRP_CLASS                    = 0x07
local SPDRP_CLASSGUID                = 0x08
local SPDRP_DRIVER                   = 0x09
local SPDRP_MFG                      = 0x0B
local SPDRP_FRIENDLYNAME             = 0x0C
local SPDRP_LOCATION_INFORMATION     = 0x0D
local SPDRP_BUSNUMBER                = 0x15
local SPDRP_DEVTYPE                  = 0x19

-- ===== known vendors (small inline table) =================================

local VENDORS = {
    [0x05AC] = "Apple",         [0x046D] = "Logitech",
    [0x0BDA] = "Realtek",       [0x8087] = "Intel",
    [0x0CF3] = "Atheros",       [0x148F] = "Ralink",
    [0x0BB4] = "HTC",           [0x18D1] = "Google",
    [0x04E8] = "Samsung",       [0x12D1] = "Huawei",
    [0x0781] = "SanDisk",       [0x0951] = "Kingston",
    [0x174C] = "ASMedia",       [0x1532] = "Razer",
    [0x046A] = "Cherry",        [0x1A2C] = "China Resource Semico",
    [0x045E] = "Microsoft",     [0x413C] = "Dell",
    [0x03F0] = "HP",            [0x17EF] = "Lenovo",
    [0x1B1C] = "Corsair",       [0x0E0F] = "VMware",
    [0x0A5C] = "Broadcom",      [0x10DE] = "NVIDIA",
    [0x1022] = "AMD",           [0x8086] = "Intel",
}

-- ===== property reader ====================================================

local function read_property_string(h_devinfo, devinfo, prop)
    local sz = ffi.new("DWORD[1]", 0)
    setupapi().SetupDiGetDeviceRegistryPropertyW(h_devinfo, devinfo, prop,
        nil, nil, 0, sz)
    if sz[0] == 0 then return nil end
    local buf = ffi.new("BYTE[?]", sz[0] + 2)
    if setupapi().SetupDiGetDeviceRegistryPropertyW(h_devinfo, devinfo, prop,
            nil, buf, sz[0], sz) == 0 then
        return nil
    end
    -- Strings come back as UTF-16LE.
    return W.FromWide(ffi.cast("unsigned short *", buf))
end

-- ===== hardware-id parsing ===============================================

local function parse_vid_pid(s)
    if not s then return nil, nil end
    local vid = s:match("VID_(%x%x%x%x)") or s:match("VEN_(%x%x%x%x)")
    local pid = s:match("PID_(%x%x%x%x)") or s:match("DEV_(%x%x%x%x)")
    return vid and tonumber(vid, 16) or nil,
           pid and tonumber(pid, 16) or nil
end

local function get_instance_id(devinst)
    local buf = ffi.new("unsigned short[512]")
    if cfgmgr().CM_Get_Device_IDW(devinst, buf, 512, 0) ~= 0 then
        return nil
    end
    return W.FromWide(buf)
end

local function parse_serial(s)
    if not s then return nil end
    -- USB instance IDs look like USB\VID_xxxx&PID_yyyy\<serial-or-uniqueid>
    local serial = s:match("\\([^\\]+)$")
    if not serial then return nil end
    -- Synthetic serial numbers contain "&" and a port-derived suffix.
    if serial:find("&") then return nil end
    return serial
end

-- ===== walker =============================================================

local function enumerate(guid, opts)
    opts = opts or {}
    local h = setupapi().SetupDiGetClassDevsW(guid, nil, nil,
        bit.bor(DIGCF_PRESENT, DIGCF_DEVICEINTERFACE))
    if h == W.INVALID_HANDLE_VALUE then return {} end

    local out = {}
    local idx = 0
    local devinfo = ffi.new("SP_DEVINFO_DATA[1]")
    devinfo[0].cbSize = ffi.sizeof("SP_DEVINFO_DATA")
    while setupapi().SetupDiEnumDeviceInfo(h, idx, devinfo) ~= 0 do
        -- Pull the interface to get the device path (this is what gets
        -- passed to CreateFileW("\\?\usb#vid_...").
        local ifd = ffi.new("SP_DEVICE_INTERFACE_DATA[1]")
        ifd[0].cbSize = ffi.sizeof("SP_DEVICE_INTERFACE_DATA")
        local device_path
        if setupapi().SetupDiEnumDeviceInterfaces(h, devinfo, guid, 0, ifd) ~= 0 then
            local req = ffi.new("DWORD[1]")
            setupapi().SetupDiGetDeviceInterfaceDetailW(h, ifd, nil, 0, req, nil)
            if req[0] > 0 then
                local detail = ffi.new("char[?]", req[0])
                local pd = ffi.cast("SP_DEVICE_INTERFACE_DETAIL_DATA_W *", detail)
                pd.cbSize = ffi.sizeof("DWORD") + 2  -- documented quirk: 6 on x86, 8 on x64
                if ffi.sizeof("void *") == 8 then pd.cbSize = 8 end
                if setupapi().SetupDiGetDeviceInterfaceDetailW(h, ifd, pd,
                        req[0], req, nil) ~= 0 then
                    device_path = W.FromWide(pd.DevicePath)
                end
            end
        end

        local hwid = read_property_string(h, devinfo, SPDRP_HARDWAREID)
        local mfg  = read_property_string(h, devinfo, SPDRP_MFG)
        local desc = read_property_string(h, devinfo, SPDRP_DEVICEDESC)
        local cls  = read_property_string(h, devinfo, SPDRP_CLASS)
        local loc  = read_property_string(h, devinfo, SPDRP_LOCATION_INFORMATION)
        local friendly = read_property_string(h, devinfo, SPDRP_FRIENDLYNAME)

        local vid, pid = parse_vid_pid(hwid or device_path)

        local instance = get_instance_id(devinfo[0].DevInst)
        local parent_dev
        local p_inst = ffi.new("DWORD[1]")
        if cfgmgr().CM_Get_Parent(p_inst, devinfo[0].DevInst, 0) == 0 then
            parent_dev = get_instance_id(p_inst[0])
        end

        local rec = {
            vendor_id      = vid,
            product_id     = pid,
            vendor         = vid and VENDORS[vid] or nil,
            manufacturer   = mfg,
            product_name   = friendly or desc,
            serial_number  = parse_serial(instance),
            device_class   = cls,
            device_path    = device_path,
            hardware_id    = hwid,
            parent         = parent_dev,
            hub_port       = loc and tonumber((loc:match("Port_#(%d+)") or "")) or nil,
            speed          = nil,
            instance_id    = instance,
        }
        out[#out + 1] = rec

        idx = idx + 1
        devinfo[0].cbSize = ffi.sizeof("SP_DEVINFO_DATA")
    end

    setupapi().SetupDiDestroyDeviceInfoList(h)
    return out
end

function M.devices()
    return enumerate(GUID_DEVINTERFACE_USB_DEVICE)
end

function M.hubs()
    return enumerate(GUID_DEVINTERFACE_USB_HUB)
end

function M.find(vid, pid)
    local out = {}
    for _, d in ipairs(M.devices()) do
        if d.vendor_id == vid and (pid == nil or d.product_id == pid) then
            out[#out + 1] = d
        end
    end
    return out
end

function M.by_class(class_guid)
    return enumerate(parse_guid(class_guid))
end

-- Expose the vendor-id -> name table for caller-side lookups.
M.vendors = VENDORS

return M
