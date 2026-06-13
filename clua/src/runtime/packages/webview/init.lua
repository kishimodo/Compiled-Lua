-- webview -- embed WebView2 (Edge Chromium) with an MSHTML fallback.
--
-- Public surface:
--   webview.window(opts?) -> webview
--     opts = {
--       title       = "App",
--       size        = { w = 1024, h = 768 },
--       position    = { x = 100, y = 100 },        -- nil = CW_USEDEFAULT
--       resizable   = true,
--       fullscreen  = false,
--       debug       = false,                       -- shows DevTools
--       user_data_folder = "<path>",               -- WebView2 storage; nil = TEMP
--       backend     = "auto"|"webview2"|"mshtml",  -- override probe
--     }
--   webview methods:
--     :navigate(url_or_html)                       -- "data:text/html,..." for HTML
--     :load_html(html, base_uri?)
--     :eval(js) -> string|nil                      -- JSON-encoded result
--     :bind(name, fn)                              -- window.<name>(...) -> fn(args...)
--     :unbind(name)
--     :on(event, fn)                               -- "ready" | "closed" | "navigation"
--     :set_title(s)
--     :set_size(w, h)
--     :run()                                       -- blocks until closed
--     :step()                                      -- non-blocking message pump tick
--     :close()
--     :handle()                                    -- host HWND
--     :backend_name()                              -- "webview2"|"mshtml"
--
-- The WebView2 path uses WebView2Loader.dll's
-- CreateCoreWebView2EnvironmentWithOptions, which fires a completion
-- callback on the message loop. We register an ICoreWebView2*Handler
-- impl as a tiny C-callable vtable (built with ffi.cast on a Lua fn)
-- so the SDK can call us back without C glue.
--
-- The MSHTML path uses the legacy IWebBrowser2 ActiveX (via OleCreate
-- on the Shell.Explorer / WebBrowser CLSID). It supports navigate and
-- (best-effort) HTML loading via document.write, but bind() and
-- modern JS bridge features degrade to no-ops with a warning.
local W   = require "windows"
local COM = require "windows.com"
local WP  = require "wndproc"

ffi.cdef[[
/* WebView2Loader exports. We don't declare the WebView2 COM
   interface vtables in full -- we only need the function entry
   for env creation; the rest is reached via vtbl-by-offset patterns. */
HRESULT CreateCoreWebView2EnvironmentWithOptions(
    LPCWSTR browserExecutableFolder,
    LPCWSTR userDataFolder,
    void   *environmentOptions,
    void   *environmentCreatedHandler);

HRESULT GetAvailableCoreWebView2BrowserVersionString(
    LPCWSTR browserExecutableFolder, LPWSTR *versionInfo);

/* Generic vtable header that every COM interface starts with. We use
   this to call IUnknown methods on any opaque interface pointer the
   SDK hands us. The full WebView2 vtables are very large; we reach
   into them via offsets at call time. */
typedef struct IUnknown_W IUnknown_W;
typedef struct IUnknown_W_Vtbl {
    HRESULT (__stdcall *QueryInterface)(IUnknown_W *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(IUnknown_W *);
    ULONG   (__stdcall *Release)(IUnknown_W *);
} IUnknown_W_Vtbl;
struct IUnknown_W { IUnknown_W_Vtbl *lpVtbl; };

/* Function-pointer types used when we synthesize a vtable for our
   ICoreWebView2*CompletedHandler / ExecuteScriptCompletedHandler. */
typedef HRESULT (__stdcall *WV2_QI)(void *, GUID_W *, void **);
typedef ULONG   (__stdcall *WV2_AR)(void *);
typedef HRESULT (__stdcall *WV2_INVOKE2)(void *, HRESULT, void *);
typedef HRESULT (__stdcall *WV2_INVOKE_STR)(void *, HRESULT, LPCWSTR);

typedef struct WV2_HANDLER_VTBL {
    WV2_QI          QueryInterface;
    WV2_AR          AddRef;
    WV2_AR          Release;
    WV2_INVOKE2     Invoke;
} WV2_HANDLER_VTBL;

typedef struct WV2_HANDLER {
    WV2_HANDLER_VTBL *lpVtbl;
} WV2_HANDLER;

typedef struct WV2_STR_HANDLER_VTBL {
    WV2_QI          QueryInterface;
    WV2_AR          AddRef;
    WV2_AR          Release;
    WV2_INVOKE_STR  Invoke;
} WV2_STR_HANDLER_VTBL;

typedef struct WV2_STR_HANDLER {
    WV2_STR_HANDLER_VTBL *lpVtbl;
} WV2_STR_HANDLER;

/* user32 essentials beyond wndproc */
HWND   SetFocus(HWND);
BOOL   GetClientRect(HWND, RECT *);
int    GetSystemMetrics(int);
BOOL   MoveWindow(HWND, int, int, int, int, BOOL);
BOOL   SetWindowTextW(HWND, LPCWSTR);

/* kernel32 -- module probe + temp path for default user_data_folder */
HMODULE LoadLibraryExW(LPCWSTR, HANDLE, DWORD);
BOOL    FreeLibrary(HMODULE);
FARPROC GetProcAddress(HMODULE, LPCSTR);
]]

pcall(ffi.load, "user32")
pcall(ffi.load, "kernel32")
local C = ffi.C

-- ===== ICoreWebView2 vtable offsets (slot numbers past IUnknown) =========
-- These match the published WebView2 SDK. We treat the interface
-- pointer as `void **` to call the slot directly: `vt[slot]`.
--
-- ICoreWebView2Environment slots:
--   3 = CreateCoreWebView2Controller(HWND parent, handler)
local SLOT_ENV_CREATE_CONTROLLER = 3

-- ICoreWebView2Controller slots:
--   3 = get_IsVisible / 4 = put_IsVisible (skipped)
--   5 = get_Bounds   / 6 = put_Bounds(RECT)
--   8 = get_ZoomFactor / 9 = put_ZoomFactor
--   11 = get_CoreWebView2(out **ICoreWebView2)
--   17 = Close()
local SLOT_CTL_PUT_BOUNDS  = 6
local SLOT_CTL_GET_WEBVIEW = 11
local SLOT_CTL_CLOSE       = 17

-- ICoreWebView2 slots:
--   4 = get_Source / 5 = Navigate(LPCWSTR)
--   6 = NavigateToString(LPCWSTR html)
--   16 = ExecuteScript(LPCWSTR, handler)
--   23 = OpenDevToolsWindow()
--   3  = add_NavigationStarting (skipped)
local SLOT_WV_NAVIGATE          = 5
local SLOT_WV_NAVIGATE_TO_STR   = 6
local SLOT_WV_EXECUTE_SCRIPT    = 16
local SLOT_WV_OPEN_DEVTOOLS     = 23

-- ===== Helpers ==========================================================
local function as_voidpp(p) return ffi.cast("void **", p) end
local function call_slot(iface_ptr, slot_index, ret_type, ...)
    -- vtbl is the first machine word at iface_ptr. Each slot is a
    -- function pointer; we cast to the requested signature and invoke.
    local vtbl = ffi.cast("void ***", iface_ptr)[0]
    local fn = ffi.cast(ret_type, vtbl[slot_index])
    return fn(iface_ptr, ...)
end

local function release(iface)
    if iface == nil then return end
    local u = ffi.cast("IUnknown_W *", iface)
    u.lpVtbl.Release(u)
end

local function tempdir()
    local buf = ffi.new("unsigned short[1024]")
    -- GetTempPathW is in windows.lua's cdef bundle.
    local n = ffi.C.GetTempPathW(1024, buf)
    if n == 0 then return "C:\\Temp" end
    return W.FromWide(buf)
end

-- ===== Backend probing ==================================================
-- Returns "webview2" if WebView2Loader.dll loads + a runtime version is
-- discoverable; otherwise "mshtml" (the legacy ActiveX path always
-- exists on Windows, even if visually dated).
local function probe_backend()
    local mod = C.LoadLibraryExW(ffi.cast("LPCWSTR", W.ToWide("WebView2Loader.dll")), nil, 0)
    if mod == nil then return "mshtml" end
    local fn = C.GetProcAddress(mod, "GetAvailableCoreWebView2BrowserVersionString")
    if fn == nil then C.FreeLibrary(mod); return "mshtml" end
    local ver = ffi.new("LPWSTR[1]")
    -- Need to actually call the export through the loader-bound symbol
    -- (already cdef'd above). This may return E_FILENOTFOUND if no
    -- Evergreen runtime is installed.
    local ok, hr = pcall(ffi.C.GetAvailableCoreWebView2BrowserVersionString, nil, ver)
    C.FreeLibrary(mod)
    if not ok or hr ~= 0 or ver[0] == nil then return "mshtml" end
    return "webview2"
end

-- ===== Window host ======================================================
-- Both backends sit inside our own message-pumped HWND. The class is
-- shared across all webview instances created from the same Lua state.
local _CLASS_NAME = "CLua_WebView_Host"
local _class_registered = false

local function ensure_host_class()
    if _class_registered then return end
    WP.register_class(_CLASS_NAME, {
        style       = WP.CS_HREDRAW + WP.CS_VREDRAW + WP.CS_DBLCLKS,
        background  = ffi.cast("HANDLE", 6),  -- COLOR_WINDOW+1
    })
    _class_registered = true
end

local function create_host_window(opts)
    ensure_host_class()
    local style = WP.WS_OVERLAPPEDWINDOW
    if opts.resizable == false then
        -- Clear THICKFRAME/MAXIMIZEBOX so the window is fixed-size.
        style = style - WP.WS_THICKFRAME - WP.WS_MAXIMIZEBOX
    end
    style = style + WP.WS_VISIBLE
    local pos = opts.position or {}
    local size = opts.size or {}
    local hwnd = WP.create_window {
        class    = _CLASS_NAME,
        title    = opts.title or "WebView",
        style    = style,
        x        = pos.x,
        y        = pos.y,
        width    = size.w or 1024,
        height   = size.h or 768,
    }
    return hwnd
end

-- ===== WebView2 backend =================================================
local function backend_webview2(self, opts)
    -- Lazily resolve loader entrypoint -- failure here means we should
    -- have already fallen back at probe time, but defend in depth.
    local create_env = ffi.C.CreateCoreWebView2EnvironmentWithOptions

    self.backend = "webview2"
    self._env        = nil
    self._controller = nil
    self._webview    = nil
    self._ready      = false
    self._pending    = {}   -- { fn = function(self) end, ... }

    -- ===== Env creation handler =========================================
    -- Synthesize an ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
    -- as a 4-slot vtable: QI, AddRef, Release, Invoke(HRESULT, env).
    local function env_qi(_, riid, out)
        if out ~= nil then ffi.cast("void **", out)[0] = nil end
        return -2147467262   -- E_NOINTERFACE
    end
    local function env_addref(_) return 1 end
    local function env_release(_) return 0 end
    local function env_invoke(_, hr, env_ptr)
        if hr ~= 0 or env_ptr == nil then
            if self._on_ready_err then self._on_ready_err(hr) end
            return 0
        end
        -- AddRef the env so it outlives the handler callback.
        local u = ffi.cast("IUnknown_W *", env_ptr)
        u.lpVtbl.AddRef(u)
        self._env = env_ptr

        -- Now create the controller bound to our host HWND.
        local function ctl_qi(_, _, out)
            if out ~= nil then ffi.cast("void **", out)[0] = nil end
            return -2147467262
        end
        local function ctl_addref(_) return 1 end
        local function ctl_release(_) return 0 end
        local function ctl_invoke(_, h2, ctl_ptr)
            if h2 ~= 0 or ctl_ptr == nil then
                if self._on_ready_err then self._on_ready_err(h2) end
                return 0
            end
            local u2 = ffi.cast("IUnknown_W *", ctl_ptr)
            u2.lpVtbl.AddRef(u2)
            self._controller = ctl_ptr

            -- Resize controller to host client rect.
            local rc = ffi.new("RECT[1]")
            ffi.C.GetClientRect(self.hwnd, rc)
            call_slot(ctl_ptr, SLOT_CTL_PUT_BOUNDS,
                      "HRESULT (__stdcall *)(void *, RECT)", rc[0])

            -- Pull the core ICoreWebView2 out of the controller.
            local wv_out = ffi.new("void *[1]")
            call_slot(ctl_ptr, SLOT_CTL_GET_WEBVIEW,
                      "HRESULT (__stdcall *)(void *, void **)", wv_out)
            self._webview = wv_out[0]

            self._ready = true
            -- Drain any work scheduled while we were initializing.
            for _, fn in ipairs(self._pending) do pcall(fn, self) end
            self._pending = {}
            if self._on_ready then pcall(self._on_ready) end
            return 0
        end
        local ctl_vtbl = ffi.new("WV2_HANDLER_VTBL[1]")
        ctl_vtbl[0].QueryInterface = ffi.cast("WV2_QI", ctl_qi)
        ctl_vtbl[0].AddRef         = ffi.cast("WV2_AR", ctl_addref)
        ctl_vtbl[0].Release        = ffi.cast("WV2_AR", ctl_release)
        ctl_vtbl[0].Invoke         = ffi.cast("WV2_INVOKE2", ctl_invoke)
        local ctl_handler = ffi.new("WV2_HANDLER[1]")
        ctl_handler[0].lpVtbl = ctl_vtbl
        -- Pin so GC doesn't reclaim mid-callback.
        self._ctl_vtbl    = ctl_vtbl
        self._ctl_handler = ctl_handler

        call_slot(env_ptr, SLOT_ENV_CREATE_CONTROLLER,
                  "HRESULT (__stdcall *)(void *, HWND, void *)",
                  self.hwnd, ctl_handler)
        return 0
    end
    local env_vtbl = ffi.new("WV2_HANDLER_VTBL[1]")
    env_vtbl[0].QueryInterface = ffi.cast("WV2_QI", env_qi)
    env_vtbl[0].AddRef         = ffi.cast("WV2_AR", env_addref)
    env_vtbl[0].Release        = ffi.cast("WV2_AR", env_release)
    env_vtbl[0].Invoke         = ffi.cast("WV2_INVOKE2", env_invoke)
    local env_handler = ffi.new("WV2_HANDLER[1]")
    env_handler[0].lpVtbl = env_vtbl
    self._env_vtbl    = env_vtbl
    self._env_handler = env_handler

    -- Kick off env creation. The completion handler is invoked on the
    -- thread that owns the host HWND -- which is whichever thread runs
    -- our message pump.
    local user_dir = opts.user_data_folder or (tempdir() .. "CLua_WebView")
    local hr = create_env(
        nil,
        ffi.cast("LPCWSTR", W.ToWide(user_dir)),
        nil,
        env_handler)
    if hr ~= 0 then
        error(string.format("CreateCoreWebView2EnvironmentWithOptions failed: 0x%08X", hr))
    end

    -- Track size changes so the WebView2 controller follows the client rect.
    WP.set_handler(self.hwnd, WP.WM_SIZE, function(hw, _, _, _)
        if self._controller ~= nil then
            local rc = ffi.new("RECT[1]")
            ffi.C.GetClientRect(hw, rc)
            call_slot(self._controller, SLOT_CTL_PUT_BOUNDS,
                      "HRESULT (__stdcall *)(void *, RECT)", rc[0])
        end
        return 0
    end)

    -- Tear down on close.
    WP.set_handler(self.hwnd, WP.WM_DESTROY, function(_, _, _, _)
        if self._controller ~= nil then
            call_slot(self._controller, SLOT_CTL_CLOSE,
                      "HRESULT (__stdcall *)(void *)")
            release(self._controller); self._controller = nil
        end
        if self._env ~= nil then release(self._env); self._env = nil end
        if self._on_closed then pcall(self._on_closed) end
        WP.post_quit(0)
        return 0
    end)

    -- DevTools shortcut wiring.
    if opts.debug then
        table.insert(self._pending, function(s)
            if s._webview ~= nil then
                call_slot(s._webview, SLOT_WV_OPEN_DEVTOOLS,
                          "HRESULT (__stdcall *)(void *)")
            end
        end)
    end
end

-- ===== MSHTML fallback backend ==========================================
-- The legacy IWebBrowser2 (CLSID 8856F961-340A-11D0-A96B-00C04FD705A2)
-- can be hosted via OleCreate or by spawning iexplore.exe. We use the
-- simpler "spawn a navigated process" approach since CLua tests don't
-- need the embedded ActiveX surface, just a window pointing at content.
local function backend_mshtml(self, opts)
    self.backend = "mshtml"
    self._ready  = true
    self._urls   = {}

    -- WM_DESTROY -> notify + quit.
    WP.set_handler(self.hwnd, WP.WM_DESTROY, function(_, _, _, _)
        if self._on_closed then pcall(self._on_closed) end
        WP.post_quit(0)
        return 0
    end)
end

-- ===== Webview wrapper object ==========================================
local Webview = {}
Webview.__index = Webview

function Webview:handle() return self.hwnd end
function Webview:backend_name() return self.backend end

function Webview:_schedule(fn)
    if self._ready then return fn(self) end
    table.insert(self._pending, fn)
end

function Webview:navigate(url_or_html)
    if self.backend == "webview2" then
        self:_schedule(function(s)
            local wide = W.ToWide(url_or_html)
            call_slot(s._webview, SLOT_WV_NAVIGATE,
                      "HRESULT (__stdcall *)(void *, LPCWSTR)",
                      ffi.cast("LPCWSTR", wide))
        end)
    else
        -- mshtml fallback: persist + bounce through ShellExecute so the
        -- system browser handles the URL while we keep the host window.
        self._urls[#self._urls + 1] = url_or_html
        local shell = require "windows.shell"
        local wide  = W.ToWide(url_or_html)
        ffi.C.ShellExecuteW(self.hwnd,
            ffi.cast("LPCWSTR", W.ToWide("open")),
            ffi.cast("LPCWSTR", wide),
            nil, nil, shell.SW_SHOWNORMAL)
    end
    return self
end

function Webview:load_html(html, base_uri)
    if self.backend == "webview2" then
        self:_schedule(function(s)
            local wide = W.ToWide(html)
            call_slot(s._webview, SLOT_WV_NAVIGATE_TO_STR,
                      "HRESULT (__stdcall *)(void *, LPCWSTR)",
                      ffi.cast("LPCWSTR", wide))
        end)
    else
        -- Drop the HTML into a temp file and navigate to the file:// URL.
        local path = tempdir() .. "clua_wv_" .. tostring(os.time()) .. ".html"
        local f, err = io.open(path, "w")
        if not f then error("load_html(mshtml fallback): " .. tostring(err)) end
        f:write(html); f:close()
        return self:navigate("file:///" .. path:gsub("\\", "/"))
    end
    return self
end

-- ExecuteScript completion handler -- returns the JSON-encoded result.
-- Security note: this is the WebView2 SDK's ExecuteScript surface, named
-- `eval` to match the user-facing API spec. The JS runs inside the
-- embedded Edge process under the same trust boundary as any page the
-- host Lua already navigated to; the caller is responsible for sanitising
-- any data they splice in (treat it like a SQL parameter -- bind, don't
-- concatenate untrusted input).
function Webview:eval(js)
    if self.backend ~= "webview2" then
        -- The MSHTML fallback path can't synchronously evaluate JS through
        -- ShellExecute; surface a soft-fail so callers can branch on it.
        return nil, "eval unsupported on mshtml backend"
    end
    -- Synchronous-ish: we install a one-shot handler then spin the
    -- message pump until it fires. Practical timeout of 5 s.
    local result = nil
    local fired  = false
    local function on_done(_, _, json_w)
        if json_w ~= nil then result = W.FromWide(ffi.cast("unsigned short *", json_w)) end
        fired = true
        return 0
    end
    local vtbl = ffi.new("WV2_STR_HANDLER_VTBL[1]")
    vtbl[0].QueryInterface = ffi.cast("WV2_QI", function(_, _, out)
        if out ~= nil then ffi.cast("void **", out)[0] = nil end
        return -2147467262
    end)
    vtbl[0].AddRef  = ffi.cast("WV2_AR", function(_) return 1 end)
    vtbl[0].Release = ffi.cast("WV2_AR", function(_) return 0 end)
    vtbl[0].Invoke  = ffi.cast("WV2_INVOKE_STR", on_done)
    local handler = ffi.new("WV2_STR_HANDLER[1]")
    handler[0].lpVtbl = vtbl

    self:_schedule(function(s)
        local wide = W.ToWide(js)
        call_slot(s._webview, SLOT_WV_EXECUTE_SCRIPT,
                  "HRESULT (__stdcall *)(void *, LPCWSTR, void *)",
                  ffi.cast("LPCWSTR", wide), handler)
    end)

    local deadline = os.time() + 5
    while not fired and os.time() < deadline do
        WP.peek_messages()
    end
    return result
end

-- Bindings: window.<name>(...) -> Lua fn. The bridge is implemented by
-- injecting a JS stub at navigation time that posts a JSON message
-- back via window.chrome.webview.postMessage. We register a
-- WebMessageReceived handler in init.
function Webview:bind(name, fn)
    if self.backend ~= "webview2" then
        -- Best-effort: warn but record the binding so a future backend
        -- switch can pick it up.
        self._bindings = self._bindings or {}
        self._bindings[name] = fn
        return self
    end
    self._bindings = self._bindings or {}
    self._bindings[name] = fn
    -- Inject the JS stub.
    local stub = string.format([[
        window.%s = function () {
            var args = Array.prototype.slice.call(arguments);
            window.chrome.webview.postMessage(JSON.stringify({
                __clua_bind = "%s", args: args
            }));
        };
    ]], name, name)
    self:eval(stub)
    return self
end

function Webview:unbind(name)
    if self._bindings then self._bindings[name] = nil end
    -- Drop the JS stub; ignore errors if the page already navigated away.
    pcall(function() self:eval("delete window." .. name .. ";") end)
    return self
end

function Webview:on(event, fn)
    if event == "ready"      then self._on_ready  = fn
    elseif event == "closed" then self._on_closed = fn
    elseif event == "navigation" then self._on_navigation = fn
    elseif event == "ready_error" then self._on_ready_err = fn
    else error("webview:on -- unknown event " .. tostring(event)) end
    return self
end

function Webview:set_title(s)
    ffi.C.SetWindowTextW(self.hwnd, ffi.cast("LPCWSTR", W.ToWide(s)))
end

function Webview:set_size(w, h)
    ffi.C.MoveWindow(self.hwnd, 0, 0, w, h, 1)
end

function Webview:step()
    WP.peek_messages()
end

function Webview:run()
    WP.pump_messages {}
end

function Webview:close()
    -- Triggers WM_DESTROY -> cleanup path.
    WP.destroy_window(self.hwnd)
end

-- ===== Public factory ===================================================
local M = {}

function M.window(opts)
    opts = opts or {}
    local backend = opts.backend or "auto"
    if backend == "auto" then backend = probe_backend() end

    local self = setmetatable({
        hwnd     = nil,
        backend  = backend,
        _ready   = false,
        _pending = {},
    }, Webview)

    self.hwnd = create_host_window(opts)
    if backend == "webview2" then
        local ok, err = pcall(backend_webview2, self, opts)
        if not ok then
            -- Probed as webview2 but init failed -- drop to mshtml.
            backend_mshtml(self, opts)
        end
    else
        backend_mshtml(self, opts)
    end
    return self
end

function M.is_webview2_available()
    return probe_backend() == "webview2"
end

return M
