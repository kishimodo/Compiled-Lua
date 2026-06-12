-- display -- monitor / DPI / mode enumeration.
--
-- Public surface:
--   display.monitors()           -> { { name, rect={x,y,w,h}, work_area={...},
--                                       is_primary, dpi_x, dpi_y, scale,
--                                       refresh_hz, color_depth, adapter }, ... }
--   display.primary()            -> single monitor record (the primary one)
--   display.from_point(x, y)     -> monitor that contains (x,y) (nil if none)
--   display.from_window(hwnd)    -> monitor that hosts the window
--   display.modes(monitor)       -> { { w, h, refresh_hz, bits }, ... }
--
-- DPI uses GetDpiForMonitor (per-monitor V2) when shcore.dll is available;
-- otherwise we fall back to GetDeviceCaps(LOGPIXELSX). This matters on
-- mixed-DPI multi-monitor setups: GetDeviceCaps reports the system DPI
-- only, which is wrong if the script's process is per-monitor-aware.
local W = require "windows"

ffi.cdef[[
/* user32 -- monitor enumeration + window-to-monitor mapping */
typedef struct tagMONITORINFOEXW {
    DWORD cbSize;
    RECT  rcMonitor;
    RECT  rcWork;
    DWORD dwFlags;
    unsigned short szDevice[32];
} MONITORINFOEXW;

typedef BOOL (__stdcall *MONITORENUMPROC)(HANDLE, HANDLE, RECT*, LONGLONG);

BOOL    EnumDisplayMonitors(HANDLE hdc, RECT *lprcClip, MONITORENUMPROC, LONGLONG);
BOOL    GetMonitorInfoW(HANDLE hMonitor, MONITORINFOEXW *lpmi);
HANDLE  MonitorFromPoint(POINT pt, DWORD dwFlags);
HANDLE  MonitorFromWindow(HWND, DWORD);
HANDLE  MonitorFromRect(RECT *, DWORD);

/* EnumDisplaySettingsW returns a struct of which we only need a slice */
typedef struct _DEVMODEW {
    unsigned short dmDeviceName[32];
    WORD  dmSpecVersion;
    WORD  dmDriverVersion;
    WORD  dmSize;
    WORD  dmDriverExtra;
    DWORD dmFields;
    /* The next 64 bytes are a union {DEVMODE_PRINTER, DEVMODE_DISPLAY}.
       Padding it conservatively keeps subsequent fields at the right
       offsets without depending on a specific Windows SDK version. */
    char  _union_pad[64];
    unsigned short dmFormName[32];
    WORD  dmLogPixels;
    DWORD dmBitsPerPel;
    DWORD dmPelsWidth;
    DWORD dmPelsHeight;
    DWORD dmDisplayFlags;
    DWORD dmDisplayFrequency;
    /* Tail padding for newer fields (dmICMMethod, dmDitherType, ...). */
    char  _tail_pad[192];
} DEVMODEW;

BOOL    EnumDisplaySettingsW(LPCWSTR lpszDeviceName, DWORD iModeNum, DEVMODEW *lpDevMode);

/* gdi32 -- GetDeviceCaps fallback for DPI */
typedef void *HDC;
HDC     CreateDCW(LPCWSTR, LPCWSTR, LPCWSTR, void *);
BOOL    DeleteDC(HDC);
int     GetDeviceCaps(HDC, int);

/* shcore -- per-monitor DPI (Windows 8.1+) */
HRESULT GetDpiForMonitor(HANDLE hMonitor, int dpiType, UINT *dpiX, UINT *dpiY);
]]

pcall(ffi.load, "gdi32")
local _have_shcore = pcall(ffi.load, "shcore")

local C = ffi.C

-- Monitor info flags
local MONITORINFOF_PRIMARY = 0x00000001
-- MonitorFromX flags
local MONITOR_DEFAULTTONULL    = 0x00000000
local MONITOR_DEFAULTTOPRIMARY = 0x00000001
local MONITOR_DEFAULTTONEAREST = 0x00000002
-- GetDpiForMonitor dpiType
local MDT_EFFECTIVE_DPI = 0
-- GetDeviceCaps indices
local LOGPIXELSX = 88
local LOGPIXELSY = 90
local BITSPIXEL  = 12
-- EnumDisplaySettings sentinel
local ENUM_CURRENT_SETTINGS = 0xFFFFFFFF

-- ===== Helpers ==========================================================
-- Pull (x, y, w, h) from a RECT cdata.
local function rect_to_xywh(r)
    return {
        x = r.left,
        y = r.top,
        w = r.right  - r.left,
        h = r.bottom - r.top,
    }
end

-- DPI for a given HMONITOR -- prefer the per-monitor V2 API. Falls back
-- to the system DPI via GetDeviceCaps when shcore.dll isn't loadable
-- (only matters on Windows 7).
local function monitor_dpi(hmon)
    if _have_shcore then
        local dx = ffi.new("UINT[1]")
        local dy = ffi.new("UINT[1]")
        if C.GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, dx, dy) == 0 then
            return tonumber(dx[0]), tonumber(dy[0])
        end
    end
    local hdc = C.CreateDCW(W.ToWide("DISPLAY"), nil, nil, nil)
    if hdc == nil then return 96, 96 end  -- documented default
    local x = C.GetDeviceCaps(hdc, LOGPIXELSX)
    local y = C.GetDeviceCaps(hdc, LOGPIXELSY)
    C.DeleteDC(hdc)
    return tonumber(x), tonumber(y)
end

-- Collect current display mode (refresh + color depth) for the device.
-- ENUM_CURRENT_SETTINGS is documented as "whatever the device is doing
-- right now," so this matches what the user actually sees -- even after
-- runtime mode changes.
local function current_mode(device_name_wide)
    local dm = ffi.new("DEVMODEW[1]")
    dm[0].dmSize = ffi.sizeof("DEVMODEW")
    if C.EnumDisplaySettingsW(device_name_wide, ENUM_CURRENT_SETTINGS, dm) == 0 then
        return nil, nil
    end
    return tonumber(dm[0].dmDisplayFrequency), tonumber(dm[0].dmBitsPerPel)
end

local function build_record(hmon)
    local mi = ffi.new("MONITORINFOEXW[1]")
    mi[0].cbSize = ffi.sizeof("MONITORINFOEXW")
    if C.GetMonitorInfoW(hmon, mi) == 0 then return nil end
    local device_w = ffi.new("unsigned short[32]")
    ffi.copy(device_w, mi[0].szDevice, 64)
    local device_name = W.FromWide(device_w)
    local dx, dy = monitor_dpi(hmon)
    local refresh, bits = current_mode(device_w)
    return {
        handle      = hmon,
        name        = device_name,
        adapter     = device_name,
        rect        = rect_to_xywh(mi[0].rcMonitor),
        work_area   = rect_to_xywh(mi[0].rcWork),
        is_primary  = (mi[0].dwFlags % 2) == 1,  -- bit 0 == MONITORINFOF_PRIMARY
        dpi_x       = dx,
        dpi_y       = dy,
        scale       = dx / 96.0,        -- 96 DPI = 100% scale (Windows baseline)
        refresh_hz  = refresh,
        color_depth = bits,
    }
end

-- ===== Public API =======================================================
local M = {}

-- Inside EnumDisplayMonitors the callback runs synchronously on the same
-- thread, so we stash results in a module-scope accumulator. A fresh
-- accumulator is set per monitors() call to keep the API reentrant-safe.
local _enum_collector
local _enum_cb = ffi.cast("MONITORENUMPROC", function(hmon, _hdc, _rc, _data)
    _enum_collector[#_enum_collector + 1] = hmon
    return 1  -- keep enumerating
end)

function M.monitors()
    _enum_collector = {}
    if C.EnumDisplayMonitors(nil, nil, _enum_cb, 0) == 0 then
        _enum_collector = nil
        error("EnumDisplayMonitors failed")
    end
    local handles = _enum_collector
    _enum_collector = nil
    local out = {}
    for i = 1, #handles do
        local r = build_record(handles[i])
        if r then out[#out + 1] = r end
    end
    return out
end

function M.primary()
    local all = M.monitors()
    for _, m in ipairs(all) do
        if m.is_primary then return m end
    end
    -- Defensive: if nothing was flagged primary (e.g. headless session
    -- with one cloned virtual monitor), the first entry is our best guess.
    return all[1]
end

function M.from_point(x, y)
    local pt = ffi.new("POINT[1]")
    pt[0].x = x; pt[0].y = y
    local h = C.MonitorFromPoint(pt[0], MONITOR_DEFAULTTONULL)
    if h == nil then return nil end
    return build_record(h)
end

function M.from_window(hwnd)
    local h = C.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)
    if h == nil then return nil end
    return build_record(h)
end

function M.modes(mon)
    if type(mon) ~= "table" or not mon.adapter then
        error("display.modes: expected a monitor record (from display.monitors())")
    end
    local device_w = W.ToWide(mon.adapter)
    local out = {}
    local seen = {}  -- dedupe (w,h,refresh,bits)
    local dm = ffi.new("DEVMODEW[1]")
    dm[0].dmSize = ffi.sizeof("DEVMODEW")
    local i = 0
    while C.EnumDisplaySettingsW(device_w, i, dm) ~= 0 do
        local w = tonumber(dm[0].dmPelsWidth)
        local h = tonumber(dm[0].dmPelsHeight)
        local r = tonumber(dm[0].dmDisplayFrequency)
        local b = tonumber(dm[0].dmBitsPerPel)
        local k = w .. "x" .. h .. "@" .. r .. "/" .. b
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = { w = w, h = h, refresh_hz = r, bits = b }
        end
        i = i + 1
        if i > 4096 then break end  -- safety brake; real systems list a few hundred
    end
    return out
end

return M
