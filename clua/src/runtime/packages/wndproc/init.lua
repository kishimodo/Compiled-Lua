-- wndproc -- Win32 window class + message loop wrapper.
--
-- Public surface:
--   wndproc.register_class(name, opts?)        -> registered (__gc on drop)
--   wndproc.create_window(opts)                -> hwnd
--   wndproc.set_handler(hwnd, msg, handler)
--   wndproc.clear_handler(hwnd, msg)
--   wndproc.set_default_handler(hwnd, handler) -- fires for messages with no exact match
--   wndproc.pump_messages(opts?)               -- blocks until WM_QUIT (opts.max_iters)
--   wndproc.peek_messages()                    -- single non-blocking flush
--   wndproc.post_quit(code?)                   -- PostQuitMessage
--   wndproc.destroy_window(hwnd)
--   wndproc.paint(hwnd, fn)                    -- helper: WM_PAINT -> BeginPaint/EndPaint
--   wndproc.mouse(hwnd, on_move, on_click)     -- convenience for the common WM_MOUSE* trio
--
-- Handler signature: function(hwnd, msg, wparam, lparam) -> integer | nil
-- Returning nil delegates to DefWindowProcW (the right default for any
-- message you don't have an opinion on).
local W = require "windows"

ffi.cdef[[
/* user32 -- window class + window + message loop ---------------------- */
typedef LONGLONG (__stdcall *WNDPROC)(HWND, UINT, ULONGLONG, LONGLONG);

typedef struct tagWNDCLASSEXW {
    UINT      cbSize;
    UINT      style;
    WNDPROC   lpfnWndProc;
    int       cbClsExtra;
    int       cbWndExtra;
    HINSTANCE hInstance;
    HANDLE    hIcon;
    HANDLE    hCursor;
    HANDLE    hbrBackground;
    LPCWSTR   lpszMenuName;
    LPCWSTR   lpszClassName;
    HANDLE    hIconSm;
} WNDCLASSEXW;

typedef struct tagPAINTSTRUCT {
    void *hdc;
    BOOL  fErase;
    RECT  rcPaint;
    BOOL  fRestore;
    BOOL  fIncUpdate;
    BYTE  rgbReserved[32];
} PAINTSTRUCT;

unsigned short RegisterClassExW(WNDCLASSEXW *);
BOOL    UnregisterClassW(LPCWSTR, HINSTANCE);
HWND    CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD,
                        int, int, int, int,
                        HWND, HANDLE, HINSTANCE, LPVOID);
BOOL    DestroyWindow(HWND);
LONGLONG DefWindowProcW(HWND, UINT, ULONGLONG, LONGLONG);
BOOL    GetMessageW(MSG *, HWND, UINT, UINT);
BOOL    PeekMessageW(MSG *, HWND, UINT, UINT, UINT);
BOOL    TranslateMessage(MSG *);
LONGLONG DispatchMessageW(MSG *);
void    PostQuitMessage(int);
BOOL    PostMessageW(HWND, UINT, ULONGLONG, LONGLONG);
LONGLONG SendMessageW(HWND, UINT, ULONGLONG, LONGLONG);
BOOL    UpdateWindow(HWND);
BOOL    InvalidateRect(HWND, RECT *, BOOL);

void   *BeginPaint(HWND, PAINTSTRUCT *);
BOOL    EndPaint(HWND, PAINTSTRUCT *);
HANDLE  LoadCursorW(HINSTANCE, LPCWSTR);
HANDLE  LoadIconW(HINSTANCE, LPCWSTR);

HINSTANCE GetModuleHandleW(LPCWSTR);
]]

local C = ffi.C

-- ===== Constants the API exports for callers ============================
local M = {}

-- Class styles
M.CS_VREDRAW    = 0x0001
M.CS_HREDRAW    = 0x0002
M.CS_DBLCLKS    = 0x0008
M.CS_OWNDC      = 0x0020

-- Window styles (subset; callers can | in others freely)
M.WS_OVERLAPPED       = 0x00000000
M.WS_POPUP            = 0x80000000
M.WS_CHILD            = 0x40000000
M.WS_VISIBLE          = 0x10000000
M.WS_DISABLED         = 0x08000000
M.WS_BORDER           = 0x00800000
M.WS_CAPTION          = 0x00C00000
M.WS_SYSMENU          = 0x00080000
M.WS_THICKFRAME       = 0x00040000
M.WS_MINIMIZEBOX      = 0x00020000
M.WS_MAXIMIZEBOX      = 0x00010000
M.WS_OVERLAPPEDWINDOW = 0x00CF0000  -- = OVERLAPPED|CAPTION|SYSMENU|THICKFRAME|MINBOX|MAXBOX

-- Extended styles
M.WS_EX_TOPMOST       = 0x00000008
M.WS_EX_TOOLWINDOW    = 0x00000080
M.WS_EX_LAYERED       = 0x00080000
M.WS_EX_NOACTIVATE    = 0x08000000

-- Common WM_* messages exposed for handler-binding ergonomics.
M.WM_CREATE         = 0x0001
M.WM_DESTROY        = 0x0002
M.WM_MOVE           = 0x0003
M.WM_SIZE           = 0x0005
M.WM_ACTIVATE       = 0x0006
M.WM_PAINT          = 0x000F
M.WM_CLOSE          = 0x0010
M.WM_QUIT           = 0x0012
M.WM_ERASEBKGND     = 0x0014
M.WM_SETCURSOR      = 0x0020
M.WM_KEYDOWN        = 0x0100
M.WM_KEYUP          = 0x0101
M.WM_CHAR           = 0x0102
M.WM_SYSKEYDOWN     = 0x0104
M.WM_SYSKEYUP       = 0x0105
M.WM_COMMAND        = 0x0111
M.WM_TIMER          = 0x0113
M.WM_MOUSEMOVE      = 0x0200
M.WM_LBUTTONDOWN    = 0x0201
M.WM_LBUTTONUP      = 0x0202
M.WM_LBUTTONDBLCLK  = 0x0203
M.WM_RBUTTONDOWN    = 0x0204
M.WM_RBUTTONUP      = 0x0205
M.WM_RBUTTONDBLCLK  = 0x0206
M.WM_MBUTTONDOWN    = 0x0207
M.WM_MBUTTONUP      = 0x0208
M.WM_MOUSEWHEEL     = 0x020A
M.WM_USER           = 0x0400
M.WM_APP            = 0x8000

-- LoadCursor stock IDs (cast at the call site; MAKEINTRESOURCE)
M.IDC_ARROW = 32512
M.IDC_IBEAM = 32513
M.IDC_HAND  = 32649

-- PeekMessage remove flags
local PM_REMOVE = 0x0001

-- CW_USEDEFAULT for window position/size
local CW_USEDEFAULT = 0x80000000

-- ===== Handler registry =================================================
-- Per-hwnd handler tables. Keyed by msg number; nil falls back to a
-- per-window default, then to DefWindowProcW. Using string keys on the
-- top level (hwnd-as-integer) lets us tolerate cdata HWND comparison
-- quirks across LuaJIT/MoonJIT releases.
local _handlers = {}   -- hwnd_key -> { [msg] = fn, _default = fn }
local _classes  = {}   -- name -> { atom, instance } (keeps cdef alive for __gc)
local _hwnd_keys = setmetatable({}, { __mode = "v" })  -- hwnd_key -> hwnd cdata

local function key_for(hwnd)
    -- Cast to uintptr_t then to a Lua number for a stable table key.
    return tonumber(ffi.cast("uintptr_t", hwnd))
end

local function dispatch(hwnd, msg, wparam, lparam)
    local k = key_for(hwnd)
    local tab = _handlers[k]
    if not tab then return nil end
    local fn = tab[msg] or tab._default
    if not fn then return nil end
    local ok, result = pcall(fn, hwnd, msg, wparam, lparam)
    if not ok then
        -- Never let Lua errors propagate into Win32 -- the DispatchMessage
        -- frame can't unwind a Lua longjmp. Surface them via the runtime
        -- print() and tell the OS the message was unhandled (returns to
        -- DefWindowProcW), which is the safest default.
        print("[wndproc] handler error in WM=" .. msg .. ": " .. tostring(result))
        return nil
    end
    return result
end

-- The single FFI WNDPROC trampoline. Created once, lives forever (no __gc).
-- Every registered class points at this same function pointer.
local _wndproc_cb = ffi.cast("WNDPROC", function(hwnd, msg, wparam, lparam)
    local r = dispatch(hwnd, msg, wparam, lparam)
    if r ~= nil then return r end
    return C.DefWindowProcW(hwnd, msg, wparam, lparam)
end)

-- ===== Class registration ===============================================
-- The WNDCLASSEXW.lpszClassName is borrowed by Windows -- we have to keep
-- the WCHAR buffer alive for the lifetime of the class registration.
function M.register_class(name, opts)
    opts = opts or {}
    if _classes[name] then return _classes[name] end
    local wc       = ffi.new("WNDCLASSEXW[1]")
    local name_w   = W.ToWide(name)
    local hinst    = C.GetModuleHandleW(nil)
    wc[0].cbSize        = ffi.sizeof("WNDCLASSEXW")
    wc[0].style         = opts.style or (M.CS_HREDRAW + M.CS_VREDRAW)
    wc[0].lpfnWndProc   = _wndproc_cb
    wc[0].cbClsExtra    = 0
    wc[0].cbWndExtra    = 0
    wc[0].hInstance     = ffi.cast("HINSTANCE", hinst)
    wc[0].hIcon         = opts.icon or nil
    wc[0].hCursor       = opts.cursor or C.LoadCursorW(nil, ffi.cast("LPCWSTR", M.IDC_ARROW))
    wc[0].hbrBackground = opts.background or ffi.cast("HANDLE", 6)  -- COLOR_WINDOW+1
    wc[0].lpszMenuName  = nil
    wc[0].lpszClassName = ffi.cast("LPCWSTR", name_w)
    wc[0].hIconSm       = opts.icon_small or nil
    local atom = C.RegisterClassExW(wc)
    if atom == 0 then error("RegisterClassExW failed for " .. name) end
    local rec = {
        name     = name,
        atom     = atom,
        instance = hinst,
        _name_w  = name_w,  -- keep WCHAR buffer alive
    }
    setmetatable(rec, { __gc = function(self)
        C.UnregisterClassW(ffi.cast("LPCWSTR", self._name_w), ffi.cast("HINSTANCE", self.instance))
        _classes[self.name] = nil
    end })
    _classes[name] = rec
    return rec
end

-- ===== Window creation ==================================================
function M.create_window(opts)
    if not opts or not opts.class then error("create_window: opts.class required") end
    if not _classes[opts.class] then
        error("create_window: class '" .. opts.class .. "' not registered")
    end
    local title_w = W.ToWide(opts.title or "")
    local class_w = W.ToWide(opts.class)
    local style   = opts.style or (M.WS_OVERLAPPEDWINDOW + M.WS_VISIBLE)
    local ex      = opts.ex_style or 0
    local hwnd = C.CreateWindowExW(
        ex,
        ffi.cast("LPCWSTR", class_w),
        ffi.cast("LPCWSTR", title_w),
        style,
        opts.x or CW_USEDEFAULT,
        opts.y or CW_USEDEFAULT,
        opts.width  or CW_USEDEFAULT,
        opts.height or CW_USEDEFAULT,
        opts.parent or nil,
        nil,  -- menu
        ffi.cast("HINSTANCE", _classes[opts.class].instance),
        nil)
    if hwnd == nil then error("CreateWindowExW failed") end
    local k = key_for(hwnd)
    _handlers[k] = {}
    _hwnd_keys[k] = hwnd
    return hwnd
end

function M.destroy_window(hwnd)
    local k = key_for(hwnd)
    _handlers[k] = nil
    _hwnd_keys[k] = nil
    C.DestroyWindow(hwnd)
end

-- ===== Handler binding ==================================================
function M.set_handler(hwnd, msg, handler)
    local k = key_for(hwnd)
    if not _handlers[k] then _handlers[k] = {} end
    _handlers[k][msg] = handler
end

function M.clear_handler(hwnd, msg)
    local k = key_for(hwnd)
    if _handlers[k] then _handlers[k][msg] = nil end
end

function M.set_default_handler(hwnd, handler)
    local k = key_for(hwnd)
    if not _handlers[k] then _handlers[k] = {} end
    _handlers[k]._default = handler
end

-- ===== Message loop =====================================================
function M.pump_messages(opts)
    opts = opts or {}
    local max_iters = opts.max_iters or math.huge
    local msg = ffi.new("MSG[1]")
    local i   = 0
    while i < max_iters do
        local r = C.GetMessageW(msg, nil, 0, 0)
        if r == 0 then return end           -- WM_QUIT
        if r < 0 then error("GetMessageW failed") end
        C.TranslateMessage(msg)
        C.DispatchMessageW(msg)
        if opts.on_tick then opts.on_tick() end
        i = i + 1
    end
end

function M.peek_messages()
    local msg = ffi.new("MSG[1]")
    local pumped = 0
    while C.PeekMessageW(msg, nil, 0, 0, PM_REMOVE) ~= 0 do
        if msg[0].message == M.WM_QUIT then return -1 end
        C.TranslateMessage(msg)
        C.DispatchMessageW(msg)
        pumped = pumped + 1
    end
    return pumped
end

function M.post_quit(code)
    C.PostQuitMessage(code or 0)
end

function M.post_message(hwnd, msg, wparam, lparam)
    return C.PostMessageW(hwnd, msg, wparam or 0, lparam or 0) ~= 0
end

function M.send_message(hwnd, msg, wparam, lparam)
    return tonumber(C.SendMessageW(hwnd, msg, wparam or 0, lparam or 0))
end

function M.invalidate(hwnd)
    -- Mark the whole client area dirty so the next paint cycle fires
    -- WM_PAINT. Erase = TRUE so the brush background also repaints.
    C.InvalidateRect(hwnd, nil, 1)
end

-- ===== Helpers ==========================================================
-- WM_PAINT wrapper: deals with BeginPaint / EndPaint bookkeeping and
-- gives the caller just an HDC and the dirty rect. Returning 0 from the
-- caller tells Windows the paint completed.
function M.paint(hwnd, fn)
    M.set_handler(hwnd, M.WM_PAINT, function(hw, _, _, _)
        local ps = ffi.new("PAINTSTRUCT[1]")
        local hdc = C.BeginPaint(hw, ps)
        local ok, err = pcall(fn, hw, hdc, ps[0].rcPaint)
        C.EndPaint(hw, ps)
        if not ok then print("[wndproc] paint error: " .. tostring(err)) end
        return 0
    end)
end

-- WM_MOUSE* convenience: wparam holds button-state flags, lparam packs
-- (x, y) as (low, high) WORDs of a signed 32-bit LPARAM. We unpack both
-- so the user code is plain old (hwnd, x, y, buttons).
local function unpack_xy(lparam)
    -- Cast through int32_t so x/y come out signed (negative is valid
    -- when the mouse is captured outside the client area).
    local lp = tonumber(ffi.cast("int32_t", lparam))
    local x = lp % 0x10000
    local y = math.floor(lp / 0x10000) % 0x10000
    if x >= 0x8000 then x = x - 0x10000 end
    if y >= 0x8000 then y = y - 0x10000 end
    return x, y
end

function M.mouse(hwnd, on_move, on_click)
    if on_move then
        M.set_handler(hwnd, M.WM_MOUSEMOVE, function(hw, _, wparam, lparam)
            local x, y = unpack_xy(lparam)
            on_move(hw, x, y, tonumber(wparam))
            return 0
        end)
    end
    if on_click then
        local function click(button, down)
            return function(hw, _, wparam, lparam)
                local x, y = unpack_xy(lparam)
                on_click(hw, button, down, x, y, tonumber(wparam))
                return 0
            end
        end
        M.set_handler(hwnd, M.WM_LBUTTONDOWN, click("left",   true))
        M.set_handler(hwnd, M.WM_LBUTTONUP,   click("left",   false))
        M.set_handler(hwnd, M.WM_RBUTTONDOWN, click("right",  true))
        M.set_handler(hwnd, M.WM_RBUTTONUP,   click("right",  false))
        M.set_handler(hwnd, M.WM_MBUTTONDOWN, click("middle", true))
        M.set_handler(hwnd, M.WM_MBUTTONUP,   click("middle", false))
    end
end

return M
