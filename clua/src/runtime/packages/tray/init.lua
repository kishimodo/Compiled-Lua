-- tray -- system tray icons + menus via Shell_NotifyIconW.
--
-- Public surface:
--   tray.new(opts) -> tray
--     opts = {
--       icon_path,         -- .ico path on disk (LoadImage with LR_LOADFROMFILE)
--       tooltip,           -- string, <= 127 chars
--       menu = {           -- array of items shown on right-click
--         { title, on_click, separator?, submenu?, checked?, disabled? },
--         ...
--       },
--       on_left_click,
--       on_right_click,    -- defaults to "show the menu"
--       on_double_click,
--     }
--   tray:set_icon(path)
--   tray:set_tooltip(s)
--   tray:set_menu(menu)
--   tray:notify(title, body, icon?)   -- balloon / Action-Center toast lite
--   tray:show() / :hide() / :close()
--
-- Each tray owns its own hidden HWND so multiple icons coexist without
-- crosstalk. Shell_NotifyIcon dispatches WM_USER+1 with packed wparam
-- (icon id) / lparam (mouse-button event id), which we route to the
-- corresponding Lua callback.
local W  = require "windows"
local WP = require "wndproc"

ffi.cdef[[
/* shell32 -- the only Shell_NotifyIcon call we need */
typedef struct _NOTIFYICONDATAW {
    DWORD          cbSize;
    HWND           hWnd;
    UINT           uID;
    UINT           uFlags;
    UINT           uCallbackMessage;
    HANDLE         hIcon;
    unsigned short szTip[128];
    DWORD          dwState;
    DWORD          dwStateMask;
    unsigned short szInfo[256];
    union {
        UINT  uTimeout;
        UINT  uVersion;
    } DUMMYUNIONNAME;
    unsigned short szInfoTitle[64];
    DWORD          dwInfoFlags;
    GUID_W         guidItem;
    HANDLE         hBalloonIcon;
} NOTIFYICONDATAW;

BOOL    Shell_NotifyIconW(DWORD dwMessage, NOTIFYICONDATAW *lpData);

/* user32 -- icon loading + popup menus */
HANDLE  LoadImageW(HINSTANCE, LPCWSTR, UINT type, int cx, int cy, UINT fuLoad);
BOOL    DestroyIcon(HANDLE);
HANDLE  CreatePopupMenu(void);
BOOL    DestroyMenu(HANDLE);
BOOL    AppendMenuW(HANDLE hMenu, UINT uFlags, ULONGLONG uIDNewItem, LPCWSTR lpNewItem);
BOOL    TrackPopupMenu(HANDLE hMenu, UINT uFlags, int x, int y, int nReserved, HWND, RECT *);
BOOL    SetForegroundWindow(HWND);
BOOL    GetCursorPos(POINT *);
BOOL    SetMenuItemBitmaps(HANDLE, UINT, UINT, HANDLE, HANDLE);
]]

pcall(ffi.load, "shell32")
local C = ffi.C

-- ===== Constants ========================================================
local NIM_ADD       = 0x00000000
local NIM_MODIFY    = 0x00000001
local NIM_DELETE    = 0x00000002
local NIM_SETFOCUS  = 0x00000003
local NIM_SETVERSION= 0x00000004

local NIF_MESSAGE   = 0x00000001
local NIF_ICON      = 0x00000002
local NIF_TIP       = 0x00000004
local NIF_INFO      = 0x00000010
local NIF_SHOWTIP   = 0x00000080

local NIIF_NONE     = 0
local NIIF_INFO     = 1
local NIIF_WARNING  = 2
local NIIF_ERROR    = 3

local IMAGE_ICON          = 1
local LR_LOADFROMFILE     = 0x00000010
local LR_DEFAULTSIZE      = 0x00000040
local LR_SHARED           = 0x00008000

local MF_STRING           = 0x00000000
local MF_SEPARATOR        = 0x00000800
local MF_POPUP            = 0x00000010
local MF_CHECKED          = 0x00000008
local MF_DISABLED         = 0x00000002
local MF_GRAYED           = 0x00000001

local TPM_LEFTALIGN       = 0x0000
local TPM_RIGHTBUTTON     = 0x0002
local TPM_RETURNCMD       = 0x0100

-- Our private callback message. Shell_NotifyIcon delivers tray events
-- to the owning HWND with this WM_USER offset and the icon id in wparam.
local WM_TRAY_CALLBACK = WP.WM_USER + 11

-- The class name is unique per process; if the user reloads the script
-- (and the prior __gc ran) we re-register fresh. If not, register_class()
-- short-circuits to the existing record.
local TRAY_CLASS = "LuaVM_TrayHost"

-- ===== Hidden message-only window =======================================
-- Track every live tray by uID so the shared WndProc can route events.
local _trays = {}      -- uID -> tray instance
local _next_id = 100   -- monotonically increasing icon id

-- Make sure the class exists exactly once. register_class is idempotent.
local function ensure_class()
    WP.register_class(TRAY_CLASS, {})
end

-- Convert a Lua menu table to an HMENU, recursing on submenus. Returns
-- the HMENU and a numeric->{tray, item, action} routing table so the
-- shared WM_COMMAND handler can dispatch by command id.
local function build_menu(menu, cmd_id_start, action_map)
    local hmenu = C.CreatePopupMenu()
    if hmenu == nil then error("CreatePopupMenu failed") end
    local id = cmd_id_start
    for _, item in ipairs(menu) do
        if item.separator then
            C.AppendMenuW(hmenu, MF_SEPARATOR, 0, nil)
        elseif item.submenu then
            local submenu, next_id = build_menu(item.submenu, id, action_map)
            id = next_id
            local title_w = W.ToWide(item.title or "")
            -- The submenu HMENU goes in the uIDNewItem slot when MF_POPUP
            -- is set; the documented spec hides that behind a ULONG_PTR.
            local flags = MF_POPUP
            if item.disabled then flags = flags + MF_GRAYED end
            local sub_as_int = tonumber(ffi.cast("uintptr_t", submenu))
            C.AppendMenuW(hmenu, flags, sub_as_int, ffi.cast("LPCWSTR", title_w))
        else
            local title_w = W.ToWide(item.title or "")
            local flags = MF_STRING
            if item.checked  then flags = flags + MF_CHECKED end
            if item.disabled then flags = flags + MF_GRAYED end
            action_map[id] = item.on_click
            C.AppendMenuW(hmenu, flags, id, ffi.cast("LPCWSTR", title_w))
            id = id + 1
        end
    end
    return hmenu, id
end

-- Load an icon from disk. LR_LOADFROMFILE + LR_DEFAULTSIZE asks for the
-- 16x16 small-icon entry inside the .ico (correct for the tray).
local function load_icon(path)
    if not path then return nil end
    local path_w = W.ToWide(path)
    local h = C.LoadImageW(nil, ffi.cast("LPCWSTR", path_w),
                           IMAGE_ICON, 0, 0,
                           LR_LOADFROMFILE + LR_DEFAULTSIZE + LR_SHARED)
    if h == nil then return nil end
    return h
end

-- Build (and fill) a NOTIFYICONDATAW. The struct is huge; we keep one
-- live instance per tray so :set_tooltip / :notify don't reallocate.
local function fill_nid(tray)
    local nid = tray._nid
    nid[0].cbSize           = ffi.sizeof("NOTIFYICONDATAW")
    nid[0].hWnd             = tray._hwnd
    nid[0].uID              = tray._uid
    nid[0].uCallbackMessage = WM_TRAY_CALLBACK
    nid[0].uFlags           = NIF_MESSAGE + NIF_ICON + NIF_TIP + NIF_SHOWTIP
    nid[0].hIcon            = tray._hicon or nil
    -- szTip / szInfo / szInfoTitle filled per-call.
    return nid
end

local function copy_wide_into(field, src, max_wchars)
    local wbuf = W.ToWide(src or "")
    local n = math.min(max_wchars - 1, ffi.sizeof(field) / 2 - 1)
    ffi.fill(field, ffi.sizeof(field))
    ffi.copy(field, wbuf, n * 2)
end

-- ===== Shared dispatcher attached to the hidden window ==================
-- Every tray shares one HWND-per-tray; the WndProc handler routes by
-- looking at wparam (uID) on the WM_TRAY_CALLBACK, and by the menu id
-- on WM_COMMAND.
local function attach_handlers(tray)
    -- Tray icon mouse activity. lparam tells us which event fired.
    WP.set_handler(tray._hwnd, WM_TRAY_CALLBACK, function(hwnd, _, wparam, lparam)
        local event = tonumber(lparam)
        if event == WP.WM_LBUTTONUP then
            if tray._cfg.on_left_click then tray._cfg.on_left_click(tray) end
        elseif event == WP.WM_RBUTTONUP then
            if tray._cfg.on_right_click then
                tray._cfg.on_right_click(tray)
            else
                tray:show_menu()
            end
        elseif event == WP.WM_LBUTTONDBLCLK then
            if tray._cfg.on_double_click then tray._cfg.on_double_click(tray) end
        end
        return 0
    end)
    -- Menu selections come back as WM_COMMAND with the command id in
    -- the low word of wparam.
    WP.set_handler(tray._hwnd, WP.WM_COMMAND, function(_, _, wparam, _)
        local cmd = tonumber(wparam) % 0x10000
        local fn = tray._actions[cmd]
        if fn then fn(tray) end
        return 0
    end)
    -- Final cleanup: when our hidden window dies, drop the icon too.
    WP.set_handler(tray._hwnd, WP.WM_DESTROY, function(_, _, _, _)
        if not tray._closed then tray:close() end
        return 0
    end)
end

-- ===== Public API =======================================================
local Tray = {}
Tray.__index = Tray

local M = {}

function M.new(opts)
    opts = opts or {}
    ensure_class()
    local uid = _next_id
    _next_id = _next_id + 1
    local hwnd = WP.create_window({
        class    = TRAY_CLASS,
        title    = "LuaVM tray host #" .. uid,
        x = 0, y = 0, width = 0, height = 0,
        style    = 0,  -- not visible -- it's a message-only sink
        ex_style = WP.WS_EX_TOOLWINDOW,
    })
    local self = setmetatable({
        _hwnd     = hwnd,
        _uid      = uid,
        _cfg      = opts,
        _hicon    = load_icon(opts.icon_path),
        _hmenu    = nil,
        _actions  = {},
        _nid      = ffi.new("NOTIFYICONDATAW[1]"),
        _closed   = false,
    }, Tray)
    _trays[uid] = self
    if opts.menu then self:set_menu(opts.menu) end
    -- Initial Shell_NotifyIcon(NIM_ADD).
    local nid = fill_nid(self)
    if opts.tooltip then copy_wide_into(nid[0].szTip, opts.tooltip, 128) end
    if C.Shell_NotifyIconW(NIM_ADD, nid) == 0 then
        -- ADD can race against a re-entry; retry once after DELETE.
        C.Shell_NotifyIconW(NIM_DELETE, nid)
        C.Shell_NotifyIconW(NIM_ADD,    nid)
    end
    attach_handlers(self)
    return self
end

function Tray:set_icon(path)
    if self._hicon then C.DestroyIcon(self._hicon) end
    self._hicon = load_icon(path)
    local nid = fill_nid(self)
    nid[0].uFlags = NIF_ICON
    nid[0].hIcon  = self._hicon or nil
    return C.Shell_NotifyIconW(NIM_MODIFY, nid) ~= 0
end

function Tray:set_tooltip(s)
    local nid = fill_nid(self)
    nid[0].uFlags = NIF_TIP + NIF_SHOWTIP
    copy_wide_into(nid[0].szTip, s, 128)
    return C.Shell_NotifyIconW(NIM_MODIFY, nid) ~= 0
end

function Tray:set_menu(menu)
    if self._hmenu then C.DestroyMenu(self._hmenu) end
    self._actions = {}
    if menu and #menu > 0 then
        self._hmenu = build_menu(menu, 1, self._actions)
    else
        self._hmenu = nil
    end
end

function Tray:show_menu()
    if not self._hmenu then return end
    local pt = ffi.new("POINT[1]")
    C.GetCursorPos(pt)
    -- SetForegroundWindow is required by MSDN's tray-menu pattern --
    -- otherwise the menu closes on the very next message.
    C.SetForegroundWindow(self._hwnd)
    C.TrackPopupMenu(self._hmenu,
        TPM_LEFTALIGN + TPM_RIGHTBUTTON,
        pt[0].x, pt[0].y, 0, self._hwnd, nil)
    -- Per MSDN: post a null message to dismiss any stuck menu state.
    WP.post_message(self._hwnd, 0, 0, 0)
end

function Tray:notify(title, body, icon_kind)
    local kind = icon_kind or "info"
    local flag = (kind == "warning" and NIIF_WARNING)
              or (kind == "error"   and NIIF_ERROR)
              or (kind == "none"    and NIIF_NONE)
              or NIIF_INFO
    local nid = fill_nid(self)
    nid[0].uFlags     = NIF_INFO
    nid[0].dwInfoFlags = flag
    copy_wide_into(nid[0].szInfoTitle, title or "", 64)
    copy_wide_into(nid[0].szInfo,      body  or "", 256)
    return C.Shell_NotifyIconW(NIM_MODIFY, nid) ~= 0
end

function Tray:show()
    -- Re-add (NIM_ADD on an existing icon is a no-op or replaces; we
    -- prefer NIM_MODIFY which doesn't reset the icon position).
    local nid = fill_nid(self)
    return C.Shell_NotifyIconW(NIM_MODIFY, nid) ~= 0
end

function Tray:hide()
    return C.Shell_NotifyIconW(NIM_DELETE, fill_nid(self)) ~= 0
end

function Tray:close()
    if self._closed then return end
    self._closed = true
    C.Shell_NotifyIconW(NIM_DELETE, fill_nid(self))
    if self._hicon then C.DestroyIcon(self._hicon); self._hicon = nil end
    if self._hmenu then C.DestroyMenu(self._hmenu); self._hmenu = nil end
    _trays[self._uid] = nil
    WP.destroy_window(self._hwnd)
end

Tray.__gc = Tray.close

return M
