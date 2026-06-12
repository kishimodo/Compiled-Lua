-- gpu -- GPU adapter / output enumeration via DXGI.
--
-- Public surface:
--   gpu.adapters()                 -> { { name, vendor_id, device_id, dedicated_vram_mb,
--                                         shared_vram_mb, system_memory_mb, driver_version,
--                                         output_count, flags, luid }, ... }
--   gpu.outputs(adapter_idx)       -> { { device_name, monitor, attached_to_desktop,
--                                         rotation, desktop_coordinates={left,top,right,bottom} }, ... }
--   gpu.nvidia_info()              -> { driver_version, ... } | nil (NVML probe)
--   gpu.amd_info()                 -> { adapter_count, ... }   | nil (ADL probe)

local W   = require "windows"
local COM = require "windows.com"

ffi.cdef[[
/* Forward decls / vtables we use. The interface signatures only cover the
   methods we actually call -- DXGI methods are stable at their slot offsets
   so we can pad earlier slots with void* placeholders. */
typedef struct gpu_IDXGIFactory1     gpu_IDXGIFactory1;
typedef struct gpu_IDXGIAdapter1     gpu_IDXGIAdapter1;
typedef struct gpu_IDXGIOutput       gpu_IDXGIOutput;
typedef struct gpu_IDXGIFactory1Vtbl gpu_IDXGIFactory1Vtbl;
typedef struct gpu_IDXGIAdapter1Vtbl gpu_IDXGIAdapter1Vtbl;
typedef struct gpu_IDXGIOutputVtbl   gpu_IDXGIOutputVtbl;

typedef struct _LUID_GPU {
    DWORD LowPart;
    LONG  HighPart;
} LUID_GPU;

typedef struct _DXGI_ADAPTER_DESC1 {
    WCHAR     Description[128];
    UINT      VendorId;
    UINT      DeviceId;
    UINT      SubSysId;
    UINT      Revision;
    ULONGLONG DedicatedVideoMemory;
    ULONGLONG DedicatedSystemMemory;
    ULONGLONG SharedSystemMemory;
    LUID_GPU  AdapterLuid;
    UINT      Flags;
} DXGI_ADAPTER_DESC1;

typedef struct _DXGI_OUTPUT_DESC {
    WCHAR  DeviceName[32];
    RECT   DesktopCoordinates;
    BOOL   AttachedToDesktop;
    DWORD  Rotation;
    HANDLE Monitor;
} DXGI_OUTPUT_DESC;

struct gpu_IDXGIFactory1Vtbl {
    /* IUnknown */
    HRESULT (__stdcall *QueryInterface)(gpu_IDXGIFactory1 *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(gpu_IDXGIFactory1 *);
    ULONG   (__stdcall *Release)(gpu_IDXGIFactory1 *);
    /* IDXGIObject -- 4 slots we ignore */
    void   *_pad_obj_0;
    void   *_pad_obj_1;
    void   *_pad_obj_2;
    void   *_pad_obj_3;
    /* IDXGIFactory -- 5 slots we ignore */
    void   *_pad_fac_0;
    void   *_pad_fac_1;
    void   *_pad_fac_2;
    void   *_pad_fac_3;
    void   *_pad_fac_4;
    /* IDXGIFactory1 */
    HRESULT (__stdcall *EnumAdapters1)(gpu_IDXGIFactory1 *, UINT, gpu_IDXGIAdapter1 **);
    BOOL    (__stdcall *IsCurrent)(gpu_IDXGIFactory1 *);
};
struct gpu_IDXGIFactory1 { gpu_IDXGIFactory1Vtbl *lpVtbl; };

struct gpu_IDXGIAdapter1Vtbl {
    HRESULT (__stdcall *QueryInterface)(gpu_IDXGIAdapter1 *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(gpu_IDXGIAdapter1 *);
    ULONG   (__stdcall *Release)(gpu_IDXGIAdapter1 *);
    void   *_pad_obj_0;
    void   *_pad_obj_1;
    void   *_pad_obj_2;
    void   *_pad_obj_3;
    /* IDXGIAdapter */
    HRESULT (__stdcall *EnumOutputs)(gpu_IDXGIAdapter1 *, UINT, gpu_IDXGIOutput **);
    void   *_pad_adp_1;
    HRESULT (__stdcall *CheckInterfaceSupport)(gpu_IDXGIAdapter1 *, GUID_W *, LONGLONG *);
    /* IDXGIAdapter1 */
    HRESULT (__stdcall *GetDesc1)(gpu_IDXGIAdapter1 *, DXGI_ADAPTER_DESC1 *);
};
struct gpu_IDXGIAdapter1 { gpu_IDXGIAdapter1Vtbl *lpVtbl; };

struct gpu_IDXGIOutputVtbl {
    HRESULT (__stdcall *QueryInterface)(gpu_IDXGIOutput *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(gpu_IDXGIOutput *);
    ULONG   (__stdcall *Release)(gpu_IDXGIOutput *);
    void   *_pad_obj_0;
    void   *_pad_obj_1;
    void   *_pad_obj_2;
    void   *_pad_obj_3;
    HRESULT (__stdcall *GetDesc)(gpu_IDXGIOutput *, DXGI_OUTPUT_DESC *);
};
struct gpu_IDXGIOutput { gpu_IDXGIOutputVtbl *lpVtbl; };

HRESULT CreateDXGIFactory1(GUID_W *, void **);
]]

local C = ffi.C
local M = {}

-- ===== GUID helpers ========================================================

local function make_guid(d1, d2, d3, d4)
    local g = ffi.new("GUID_W")
    g.Data1 = d1; g.Data2 = d2; g.Data3 = d3
    for i = 0, 7 do g.Data4[i] = d4[i + 1] end
    return g
end

-- IID_IDXGIFactory1 = 770aae78-f26f-4dba-a829-253c83d1b387
local IID_IDXGIFactory1 = make_guid(0x770aae78, 0xf26f, 0x4dba,
    { 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 })

local _dxgi_loaded
local function dxgi_load()
    if _dxgi_loaded ~= nil then return _dxgi_loaded end
    _dxgi_loaded = pcall(ffi.load, "dxgi") and true or false
    return _dxgi_loaded
end

local function wcharbuf_to_string(buf, max)
    local out = ffi.new("char[?]", max * 4)
    local n = C.WideCharToMultiByte(W.CP_UTF8, 0, ffi.cast("LPCWSTR", buf), -1, out, max * 4, nil, nil)
    if n <= 0 then return "" end
    return ffi.string(out, n - 1)
end

-- ===== DXGI adapter enumeration ===========================================

local function release(p)
    if p ~= nil then p.lpVtbl.Release(p) end
end

local function rotation_string(r)
    if r == 1 then return "identity"
    elseif r == 2 then return "rotate_90"
    elseif r == 3 then return "rotate_180"
    elseif r == 4 then return "rotate_270"
    end
    return "unspecified"
end

local function dxgi_adapters()
    if not dxgi_load() then return nil end
    local factory = ffi.new("gpu_IDXGIFactory1 *[1]")
    local hr = C.CreateDXGIFactory1(IID_IDXGIFactory1, ffi.cast("void **", factory))
    if hr ~= 0 then return nil end

    local out = {}
    local i = 0
    while true do
        local ap = ffi.new("gpu_IDXGIAdapter1 *[1]")
        hr = factory[0].lpVtbl.EnumAdapters1(factory[0], i, ap)
        -- DXGI_ERROR_NOT_FOUND = 0x887A0002
        if hr ~= 0 then break end
        local desc = ffi.new("DXGI_ADAPTER_DESC1[1]")
        if ap[0].lpVtbl.GetDesc1(ap[0], desc) == 0 then
            -- count outputs by enumerating until NOT_FOUND
            local oc = 0
            while true do
                local op = ffi.new("gpu_IDXGIOutput *[1]")
                local h2 = ap[0].lpVtbl.EnumOutputs(ap[0], oc, op)
                if h2 ~= 0 then break end
                release(op[0])
                oc = oc + 1
                if oc > 32 then break end
            end
            out[#out + 1] = {
                name              = wcharbuf_to_string(desc[0].Description, 128),
                vendor_id         = tonumber(desc[0].VendorId),
                device_id         = tonumber(desc[0].DeviceId),
                sub_sys_id        = tonumber(desc[0].SubSysId),
                revision          = tonumber(desc[0].Revision),
                dedicated_vram_mb = math.floor(tonumber(desc[0].DedicatedVideoMemory) / (1024 * 1024)),
                dedicated_system_memory_mb = math.floor(tonumber(desc[0].DedicatedSystemMemory) / (1024 * 1024)),
                shared_vram_mb    = math.floor(tonumber(desc[0].SharedSystemMemory) / (1024 * 1024)),
                system_memory_mb  = math.floor(tonumber(desc[0].SharedSystemMemory) / (1024 * 1024)),
                flags             = tonumber(desc[0].Flags),
                output_count      = oc,
                driver_version    = nil,           -- DXGI doesn't expose this
                luid              = string.format("%08x-%08x",
                                       tonumber(desc[0].AdapterLuid.HighPart) % 0x100000000,
                                       tonumber(desc[0].AdapterLuid.LowPart)),
            }
        end
        release(ap[0])
        i = i + 1
        if i > 32 then break end
    end
    release(factory[0])
    return out
end

-- ===== WMI fallback (Win32_VideoController) ================================

local function wmi_video_controllers()
    local ok, wmi = pcall(require, "wmi")
    if not ok then return {} end
    local svc, _ = wmi.connect()
    if not svc then return {} end
    local ok2, rows = pcall(function()
        return svc:query_all("SELECT Name, AdapterCompatibility, DriverVersion, " ..
            "PNPDeviceID, AdapterRAM FROM Win32_VideoController")
    end)
    svc:close()
    if not ok2 or not rows then return {} end
    local out = {}
    for _, r in ipairs(rows) do
        -- PNPDeviceID looks like "PCI\VEN_10DE&DEV_1F08&..."; try to peel it.
        local vid, did
        if r.PNPDeviceID then
            vid = r.PNPDeviceID:match("VEN_(%x%x%x%x)")
            did = r.PNPDeviceID:match("DEV_(%x%x%x%x)")
        end
        out[#out + 1] = {
            name              = r.Name,
            vendor_id         = vid and tonumber(vid, 16) or nil,
            device_id         = did and tonumber(did, 16) or nil,
            dedicated_vram_mb = r.AdapterRAM and math.floor(r.AdapterRAM / (1024 * 1024)) or nil,
            driver_version    = r.DriverVersion,
            output_count      = nil,
            shared_vram_mb    = nil,
            system_memory_mb  = nil,
            flags             = nil,
            luid              = nil,
        }
    end
    return out
end

function M.adapters()
    local d = dxgi_adapters()
    if d and #d > 0 then
        -- Patch in driver_version from WMI when possible (DXGI doesn't have it).
        local wmi_rows = wmi_video_controllers()
        for _, a in ipairs(d) do
            for _, w in ipairs(wmi_rows) do
                if a.name and w.name and a.name == w.name then
                    a.driver_version = w.driver_version
                end
            end
        end
        return d
    end
    return wmi_video_controllers()
end

-- ===== outputs(adapter_idx) ===============================================

function M.outputs(adapter_idx)
    if not dxgi_load() then return {} end
    local factory = ffi.new("gpu_IDXGIFactory1 *[1]")
    local hr = C.CreateDXGIFactory1(IID_IDXGIFactory1, ffi.cast("void **", factory))
    if hr ~= 0 then return {} end

    local out = {}
    local ap = ffi.new("gpu_IDXGIAdapter1 *[1]")
    hr = factory[0].lpVtbl.EnumAdapters1(factory[0], (adapter_idx or 1) - 1, ap)
    if hr == 0 then
        local i = 0
        while true do
            local op = ffi.new("gpu_IDXGIOutput *[1]")
            local h2 = ap[0].lpVtbl.EnumOutputs(ap[0], i, op)
            if h2 ~= 0 then break end
            local desc = ffi.new("DXGI_OUTPUT_DESC[1]")
            if op[0].lpVtbl.GetDesc(op[0], desc) == 0 then
                out[#out + 1] = {
                    device_name         = wcharbuf_to_string(desc[0].DeviceName, 32),
                    monitor             = tostring(desc[0].Monitor),
                    attached_to_desktop = desc[0].AttachedToDesktop ~= 0,
                    rotation            = rotation_string(tonumber(desc[0].Rotation)),
                    desktop_coordinates = {
                        left   = tonumber(desc[0].DesktopCoordinates.left),
                        top    = tonumber(desc[0].DesktopCoordinates.top),
                        right  = tonumber(desc[0].DesktopCoordinates.right),
                        bottom = tonumber(desc[0].DesktopCoordinates.bottom),
                    },
                }
            end
            release(op[0])
            i = i + 1
            if i > 32 then break end
        end
        release(ap[0])
    end
    release(factory[0])
    return out
end

-- ===== best-effort vendor SDK probes ======================================
--
-- We don't ship NVML / ADL bindings; if the vendor DLL happens to be in
-- the load path we surface a minimal "detected" record so callers know
-- they can deepen the probe. Anything richer should live in a dedicated
-- nvml / adl package.

function M.nvidia_info()
    local ok = pcall(ffi.load, "nvml")
    if not ok then ok = pcall(ffi.load, "nvapi64") end
    if not ok then return nil end
    return { detected = true, library = "nvml-or-nvapi" }
end

function M.amd_info()
    local ok = pcall(ffi.load, "atiadlxx")
    if not ok then ok = pcall(ffi.load, "atiadlxy") end
    if not ok then return nil end
    return { detected = true, library = "atiadlxx" }
end

return M
