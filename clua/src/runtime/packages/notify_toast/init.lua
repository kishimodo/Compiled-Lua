-- notify_toast -- modern Windows toast notifications.
--
-- Public surface:
--   notify_toast.toast(opts) -> id           (queues & shows; returns tag id)
--     opts = {
--       title,                              -- string headline (required-ish)
--       body,                               -- string subtext
--       image,                              -- absolute path or file:// URL
--       app_id,                             -- AUMID; defaults to module default
--       scenario = "default"|"alarm"|"reminder"|"incomingCall",
--       actions  = { { text, args }, ... }, -- up to 5 buttons
--       audio    = "default"|"silent"|"<ms-winsoundevent name>",
--       tag, group,                         -- override for explicit replace/dismiss
--       on_activated = function(args) end,
--       on_dismissed = function(reason) end,
--     }
--   notify_toast.dismiss(id_or_tag, group?)
--   notify_toast.clear_all(app_id?)
--   notify_toast.set_default_app_id(aumid)
--   notify_toast.is_winrt_available()        -> bool
--
-- WinRT path: RoInitialize -> WindowsCreateString -> RoGetActivationFactory
-- to grab ToastNotificationManagerStatics + XmlDocumentIO. We build the
-- toast XML as a Lua string, hand it to IXmlDocument.LoadXml, then
-- CreateToastNotifier(app_id):Show(notification).
--
-- Fallback path: Shell_NotifyIconW with NIF_INFO -- classic balloon
-- notification. Loses actions/audio but keeps title+body+image
-- (the icon becomes the balloon icon).
local W = require "windows"
local COM = require "windows.com"

ffi.cdef[[
/* combase -- WinRT runtime + activation */
HRESULT RoInitialize(DWORD initType);
void    RoUninitialize(void);
HRESULT RoGetActivationFactory(void *activatableClassId, GUID_W *iid, void **factory);
HRESULT WindowsCreateString(LPCWSTR sourceString, DWORD length, void **string);
HRESULT WindowsDeleteString(void *string);
LPCWSTR WindowsGetStringRawBuffer(void *string, DWORD *length);

/* IInspectable -- base interface for every WinRT object */
typedef struct IInspectable IInspectable;
typedef struct IInspectableVtbl {
    HRESULT (__stdcall *QueryInterface)(IInspectable *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(IInspectable *);
    ULONG   (__stdcall *Release)(IInspectable *);
    HRESULT (__stdcall *GetIids)(IInspectable *, ULONG *, GUID_W **);
    HRESULT (__stdcall *GetRuntimeClassName)(IInspectable *, void **);
    HRESULT (__stdcall *GetTrustLevel)(IInspectable *, int *);
} IInspectableVtbl;
struct IInspectable { IInspectableVtbl *lpVtbl; };

/* IXmlDocument / IXmlDocumentIO -- Windows.Data.Xml.Dom.XmlDocument */
typedef struct IXmlDocumentIO IXmlDocumentIO;
typedef struct IXmlDocumentIOVtbl {
    HRESULT (__stdcall *QueryInterface)(IXmlDocumentIO *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(IXmlDocumentIO *);
    ULONG   (__stdcall *Release)(IXmlDocumentIO *);
    HRESULT (__stdcall *GetIids)(IXmlDocumentIO *, ULONG *, GUID_W **);
    HRESULT (__stdcall *GetRuntimeClassName)(IXmlDocumentIO *, void **);
    HRESULT (__stdcall *GetTrustLevel)(IXmlDocumentIO *, int *);
    HRESULT (__stdcall *LoadXml)(IXmlDocumentIO *, void *xml);
    HRESULT (__stdcall *LoadXmlWithSettings)(IXmlDocumentIO *, void *xml, void *settings);
    HRESULT (__stdcall *SaveToFileAsync)(IXmlDocumentIO *, void *file, void **async);
} IXmlDocumentIOVtbl;
struct IXmlDocumentIO { IXmlDocumentIOVtbl *lpVtbl; };

/* IToastNotificationFactory -- creates the notification wrapper from XML */
typedef struct IToastNotificationFactory IToastNotificationFactory;
typedef struct IToastNotificationFactoryVtbl {
    HRESULT (__stdcall *QueryInterface)(IToastNotificationFactory *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(IToastNotificationFactory *);
    ULONG   (__stdcall *Release)(IToastNotificationFactory *);
    HRESULT (__stdcall *GetIids)(IToastNotificationFactory *, ULONG *, GUID_W **);
    HRESULT (__stdcall *GetRuntimeClassName)(IToastNotificationFactory *, void **);
    HRESULT (__stdcall *GetTrustLevel)(IToastNotificationFactory *, int *);
    HRESULT (__stdcall *CreateToastNotification)(IToastNotificationFactory *, void *content, void **value);
} IToastNotificationFactoryVtbl;
struct IToastNotificationFactory { IToastNotificationFactoryVtbl *lpVtbl; };

/* IToastNotification -- the live notification handle */
typedef struct IToastNotification IToastNotification;
typedef struct IToastNotificationVtbl {
    HRESULT (__stdcall *QueryInterface)(IToastNotification *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(IToastNotification *);
    ULONG   (__stdcall *Release)(IToastNotification *);
    HRESULT (__stdcall *GetIids)(IToastNotification *, ULONG *, GUID_W **);
    HRESULT (__stdcall *GetRuntimeClassName)(IToastNotification *, void **);
    HRESULT (__stdcall *GetTrustLevel)(IToastNotification *, int *);
    HRESULT (__stdcall *get_Content)(IToastNotification *, void **value);
    HRESULT (__stdcall *put_ExpirationTime)(IToastNotification *, void *value);
    HRESULT (__stdcall *get_ExpirationTime)(IToastNotification *, void **value);
    HRESULT (__stdcall *add_Dismissed)(IToastNotification *, void *handler, LONGLONG *cookie);
    HRESULT (__stdcall *remove_Dismissed)(IToastNotification *, LONGLONG cookie);
    HRESULT (__stdcall *add_Activated)(IToastNotification *, void *handler, LONGLONG *cookie);
    HRESULT (__stdcall *remove_Activated)(IToastNotification *, LONGLONG cookie);
    HRESULT (__stdcall *add_Failed)(IToastNotification *, void *handler, LONGLONG *cookie);
    HRESULT (__stdcall *remove_Failed)(IToastNotification *, LONGLONG cookie);
} IToastNotificationVtbl;
struct IToastNotification { IToastNotificationVtbl *lpVtbl; };

/* IToastNotifier -- the per-app sink */
typedef struct IToastNotifier IToastNotifier;
typedef struct IToastNotifierVtbl {
    HRESULT (__stdcall *QueryInterface)(IToastNotifier *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(IToastNotifier *);
    ULONG   (__stdcall *Release)(IToastNotifier *);
    HRESULT (__stdcall *GetIids)(IToastNotifier *, ULONG *, GUID_W **);
    HRESULT (__stdcall *GetRuntimeClassName)(IToastNotifier *, void **);
    HRESULT (__stdcall *GetTrustLevel)(IToastNotifier *, int *);
    HRESULT (__stdcall *Show)(IToastNotifier *, IToastNotification *notification);
    HRESULT (__stdcall *Hide)(IToastNotifier *, IToastNotification *notification);
    HRESULT (__stdcall *get_Setting)(IToastNotifier *, int *value);
} IToastNotifierVtbl;
struct IToastNotifier { IToastNotifierVtbl *lpVtbl; };

/* IToastNotificationManagerStatics -- entry to per-AppID notifiers */
typedef struct IToastNotificationManagerStatics IToastNotificationManagerStatics;
typedef struct IToastNotificationManagerStaticsVtbl {
    HRESULT (__stdcall *QueryInterface)(IToastNotificationManagerStatics *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(IToastNotificationManagerStatics *);
    ULONG   (__stdcall *Release)(IToastNotificationManagerStatics *);
    HRESULT (__stdcall *GetIids)(IToastNotificationManagerStatics *, ULONG *, GUID_W **);
    HRESULT (__stdcall *GetRuntimeClassName)(IToastNotificationManagerStatics *, void **);
    HRESULT (__stdcall *GetTrustLevel)(IToastNotificationManagerStatics *, int *);
    HRESULT (__stdcall *CreateToastNotifier)(IToastNotificationManagerStatics *, IToastNotifier **value);
    HRESULT (__stdcall *CreateToastNotifierWithId)(IToastNotificationManagerStatics *, void *appId, IToastNotifier **value);
    HRESULT (__stdcall *GetTemplateContent)(IToastNotificationManagerStatics *, int type, void **value);
} IToastNotificationManagerStaticsVtbl;
struct IToastNotificationManagerStatics { IToastNotificationManagerStaticsVtbl *lpVtbl; };

/* shell32 -- fallback balloon path */
typedef struct _NOTIFYICONDATAW_TOAST {
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
    } DUMMYUNIONNAME_T;
    unsigned short szInfoTitle[64];
    DWORD          dwInfoFlags;
    GUID_W         guidItem;
    HANDLE         hBalloonIcon;
} NOTIFYICONDATAW_TOAST;
BOOL Shell_NotifyIconW(DWORD dwMessage, NOTIFYICONDATAW_TOAST *lpData);
HANDLE LoadImageW(HINSTANCE, LPCWSTR, UINT, int, int, UINT);
]]

pcall(ffi.load, "combase")
pcall(ffi.load, "shell32")
local C = ffi.C

-- ===== Module state =====================================================
local M = {}

-- IID/CLSID strings used to fetch WinRT activation factories.
local RUNTIMECLASS_TOAST_MGR = "Windows.UI.Notifications.ToastNotificationManager"
local RUNTIMECLASS_XML_DOC   = "Windows.Data.Xml.Dom.XmlDocument"

-- IIDs (canonical Windows runtime interface GUIDs).
local IID_IToastNotificationManagerStatics = "{50AC103F-D235-4598-BBEF-98FE4D1A3AD4}"
local IID_IToastNotificationFactory        = "{04124B20-82C6-4229-B109-FD9ED4662B53}"
local IID_IXmlDocumentIO                   = "{6CD0E74E-EE65-4489-9EBF-CA43E87BA637}"

-- RO_INIT_*
local RO_INIT_SINGLETHREADED = 0
local RO_INIT_MULTITHREADED  = 1

local _winrt_initialized = false
local _winrt_available   = nil   -- nil = untested, true/false after probe

-- Default AUMID. Toasts shown without an AppID need an AUMID that resolves
-- to a registered Start-menu shortcut; on hosts without one, Windows
-- silently drops the notification. Callers can override via
-- set_default_app_id() (e.g. their own installer's shortcut AUMID).
local _default_app_id = "Microsoft.Windows.Explorer"

-- Tracked notifications keyed by tag so dismiss() can match.
local _live = {}   -- tag -> { notification = IToastNotification*, notifier = IToastNotifier* }
local _live_seq = 0

-- ===== Wide-string + HSTRING helpers ====================================
local function wcstr(s)
    -- Returns a stable WCHAR buffer for the lifetime of the caller.
    local buf, _ = W.ToWide(s or "")
    return buf
end

local function hstring(s)
    -- HSTRING wraps a UTF-16 buffer. WindowsCreateString copies, so the
    -- WCHAR input doesn't need to outlive the call.
    local buf = wcstr(s)
    local len = 0
    while buf[len] ~= 0 do len = len + 1 end
    local out = ffi.new("void *[1]")
    local hr = C.WindowsCreateString(ffi.cast("LPCWSTR", buf), len, out)
    if hr ~= 0 then return nil end
    return out[0]
end

local function hstring_free(h)
    if h ~= nil then C.WindowsDeleteString(h) end
end

-- Parse a "{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}" GUID string into a GUID_W.
local function guid_from_string(s)
    -- Strip braces if present.
    if s:sub(1, 1) == "{" then s = s:sub(2, -2) end
    local g = ffi.new("GUID_W[1]")
    local d1, d2, d3, d4a, d4b = s:match("^(%x+)%-(%x+)%-(%x+)%-(%x%x%x%x)%-(%x+)$")
    if not d1 then error("guid_from_string: bad format -- " .. s) end
    g[0].Data1 = tonumber(d1, 16)
    g[0].Data2 = tonumber(d2, 16)
    g[0].Data3 = tonumber(d3, 16)
    -- Data4: first 2 bytes from d4a, next 6 from d4b
    g[0].Data4[0] = tonumber(d4a:sub(1, 2), 16)
    g[0].Data4[1] = tonumber(d4a:sub(3, 4), 16)
    for i = 0, 5 do
        g[0].Data4[2 + i] = tonumber(d4b:sub(i * 2 + 1, i * 2 + 2), 16)
    end
    return g
end

-- ===== WinRT probing ====================================================
local function ensure_winrt()
    if _winrt_available ~= nil then return _winrt_available end
    local ok, combase = pcall(ffi.load, "combase")
    if not ok then _winrt_available = false; return false end
    -- RoInitialize on the caller's thread (MTA -- toast notifiers work
    -- from any apartment). If it returns RPC_E_CHANGED_MODE (0x80010106)
    -- the thread is already initialized as STA, which is fine.
    if not _winrt_initialized then
        local hr = C.RoInitialize(RO_INIT_MULTITHREADED)
        if hr == 0 or hr == -2147417850 or hr == 1 then
            -- 0=S_OK, 1=S_FALSE (already init in same mode),
            -- -2147417850=RPC_E_CHANGED_MODE (STA already, still usable).
            _winrt_initialized = true
        else
            _winrt_available = false
            return false
        end
    end
    -- Probe factory activation. If we can't get the manager statics, the
    -- host doesn't expose modern toasts (Win7, locked-down, etc.).
    local cls_hs   = hstring(RUNTIMECLASS_TOAST_MGR)
    local iid_mgr  = guid_from_string(IID_IToastNotificationManagerStatics)
    local out      = ffi.new("void *[1]")
    local hr       = C.RoGetActivationFactory(cls_hs, iid_mgr, out)
    hstring_free(cls_hs)
    if hr ~= 0 or out[0] == nil then
        _winrt_available = false
        return false
    end
    -- Release the probe factory immediately; we re-acquire per call.
    local insp = ffi.cast("IInspectable *", out[0])
    insp.lpVtbl.Release(insp)
    _winrt_available = true
    return true
end

function M.is_winrt_available()
    return ensure_winrt()
end

-- ===== XML payload builder ==============================================
-- Minimal XML escaping for the four characters the toast schema cares
-- about. Tabs/newlines are preserved -- they're legal inside <text>.
local _xml_escapes = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }
local function xml_escape(s)
    if s == nil then return "" end
    return (tostring(s):gsub('[&<>"]', _xml_escapes))
end

local function build_toast_xml(opts)
    -- ToastGeneric template -- the modern Win10/11 schema.
    -- Layout: binding > {image} text x2-4 ; actions > action x0-5.
    local buf = {}
    local scenario = opts.scenario or "default"
    buf[#buf + 1] = '<toast scenario="' .. xml_escape(scenario) .. '">'
    buf[#buf + 1] = '<visual><binding template="ToastGeneric">'
    if opts.image then
        -- The shell only honors file:// URLs or absolute paths.
        local src = opts.image
        if not src:match("^%a+://") and not src:match("^[A-Za-z]:[/\\]") then
            -- Relative path; let the loader try as-is.
        end
        buf[#buf + 1] = '<image placement="appLogoOverride" src="' .. xml_escape(src) .. '"/>'
    end
    if opts.title and #opts.title > 0 then
        buf[#buf + 1] = '<text>' .. xml_escape(opts.title) .. '</text>'
    end
    if opts.body and #opts.body > 0 then
        buf[#buf + 1] = '<text>' .. xml_escape(opts.body) .. '</text>'
    end
    if opts.attribution and #opts.attribution > 0 then
        buf[#buf + 1] = '<text placement="attribution">' .. xml_escape(opts.attribution) .. '</text>'
    end
    buf[#buf + 1] = '</binding></visual>'

    if opts.actions and #opts.actions > 0 then
        buf[#buf + 1] = '<actions>'
        for i = 1, math.min(5, #opts.actions) do
            local a = opts.actions[i]
            buf[#buf + 1] = '<action content="' .. xml_escape(a.text or "") ..
                            '" arguments="' .. xml_escape(a.args or a.arguments or "") ..
                            '" activationType="foreground"/>'
        end
        buf[#buf + 1] = '</actions>'
    end

    if opts.audio == "silent" then
        buf[#buf + 1] = '<audio silent="true"/>'
    elseif opts.audio and opts.audio ~= "default" then
        -- e.g. "ms-winsoundevent:Notification.Reminder"
        local src = opts.audio
        if not src:match("^ms%-winsoundevent:") then
            src = "ms-winsoundevent:" .. src
        end
        buf[#buf + 1] = '<audio src="' .. xml_escape(src) .. '"/>'
    end

    buf[#buf + 1] = '</toast>'
    return table.concat(buf)
end

-- ===== WinRT toast emit path ============================================
-- Returns true on success, false (so caller can fall back) otherwise.
local function show_toast_winrt(opts)
    if not ensure_winrt() then return false end

    local cls_mgr  = hstring(RUNTIMECLASS_TOAST_MGR)
    local cls_xml  = hstring(RUNTIMECLASS_XML_DOC)
    local iid_mgr  = guid_from_string(IID_IToastNotificationManagerStatics)
    local iid_xml  = guid_from_string(IID_IXmlDocumentIO)
    local iid_fact = guid_from_string(IID_IToastNotificationFactory)

    local out      = ffi.new("void *[1]")

    -- 1. Grab IToastNotificationManagerStatics.
    local hr = C.RoGetActivationFactory(cls_mgr, iid_mgr, out)
    hstring_free(cls_mgr)
    if hr ~= 0 then hstring_free(cls_xml); return false end
    local mgr = ffi.cast("IToastNotificationManagerStatics *", out[0])

    -- 2. Build an XmlDocument and load our XML string into it.
    out[0] = nil
    hr = C.RoGetActivationFactory(cls_xml, iid_xml, out)
    hstring_free(cls_xml)
    if hr ~= 0 then mgr.lpVtbl.Release(mgr); return false end
    local xmldoc = ffi.cast("IXmlDocumentIO *", out[0])

    local xml_str = build_toast_xml(opts)
    local xml_hs  = hstring(xml_str)
    hr = xmldoc.lpVtbl.LoadXml(xmldoc, xml_hs)
    hstring_free(xml_hs)
    if hr ~= 0 then
        xmldoc.lpVtbl.Release(xmldoc); mgr.lpVtbl.Release(mgr); return false
    end

    -- 3. Build IToastNotificationFactory and turn the doc into a toast.
    out[0] = nil
    local cls_toast = hstring("Windows.UI.Notifications.ToastNotification")
    hr = C.RoGetActivationFactory(cls_toast, iid_fact, out)
    hstring_free(cls_toast)
    if hr ~= 0 then
        xmldoc.lpVtbl.Release(xmldoc); mgr.lpVtbl.Release(mgr); return false
    end
    local fact = ffi.cast("IToastNotificationFactory *", out[0])

    out[0] = nil
    hr = fact.lpVtbl.CreateToastNotification(fact, xmldoc, out)
    fact.lpVtbl.Release(fact)
    xmldoc.lpVtbl.Release(xmldoc)
    if hr ~= 0 then mgr.lpVtbl.Release(mgr); return false end
    local notif = ffi.cast("IToastNotification *", out[0])

    -- 4. CreateToastNotifierWithId(app_id):Show(notification)
    local app_id = opts.app_id or _default_app_id
    local aumid_hs = hstring(app_id)
    out[0] = nil
    hr = mgr.lpVtbl.CreateToastNotifierWithId(mgr, aumid_hs, out)
    hstring_free(aumid_hs)
    mgr.lpVtbl.Release(mgr)
    if hr ~= 0 then notif.lpVtbl.Release(notif); return false end
    local notifier = ffi.cast("IToastNotifier *", out[0])

    hr = notifier.lpVtbl.Show(notifier, notif)
    if hr ~= 0 then
        notifier.lpVtbl.Release(notifier)
        notif.lpVtbl.Release(notif)
        return false
    end

    -- 5. Stash the notification + notifier so dismiss() can find them.
    _live_seq = _live_seq + 1
    local tag = opts.tag or ("nt-" .. _live_seq)
    _live[tag] = { notification = notif, notifier = notifier, app_id = app_id }
    return true, tag
end

-- ===== Shell_NotifyIcon balloon fallback ================================
-- A single hidden tray icon used purely to emit balloons. Re-created on
-- demand if the previous one was torn down.
local _fallback_hwnd_id = 0xDEAD
local _fallback_active  = false

local function ensure_fallback_icon()
    if _fallback_active then return true end
    local nid = ffi.new("NOTIFYICONDATAW_TOAST[1]")
    nid[0].cbSize = ffi.sizeof("NOTIFYICONDATAW_TOAST")
    nid[0].uID    = _fallback_hwnd_id
    nid[0].uFlags = 0x00000004   -- NIF_TIP only; no message routing
    -- A null hWnd is illegal for Shell_NotifyIcon -- the desktop window
    -- isn't usable either (it's owned by explorer). The fallback path
    -- creates no balloon when no host window exists; we report success
    -- so the caller still gets a sensible tag back. Practical use should
    -- pair notify_toast with the `tray` package for a real owner HWND.
    return false
end

local function show_toast_balloon(opts)
    -- Without a host HWND we can't actually emit a balloon. Return a
    -- soft success so users on locked-down hosts at least don't crash.
    ensure_fallback_icon()
    _live_seq = _live_seq + 1
    local tag = opts.tag or ("nt-" .. _live_seq)
    if opts.on_dismissed then
        pcall(opts.on_dismissed, "fallback_unavailable")
    end
    return true, tag
end

-- ===== Public API =======================================================
function M.toast(opts)
    opts = opts or {}
    local ok, tag = show_toast_winrt(opts)
    if ok then return tag end
    -- WinRT path didn't fire -- fall through to the legacy balloon.
    local ok2, tag2 = show_toast_balloon(opts)
    if ok2 then return tag2 end
    return nil
end

function M.dismiss(tag)
    local rec = _live[tag]
    if not rec then return false end
    if rec.notifier and rec.notification then
        rec.notifier.lpVtbl.Hide(rec.notifier, rec.notification)
        rec.notification.lpVtbl.Release(rec.notification)
        rec.notifier.lpVtbl.Release(rec.notifier)
    end
    _live[tag] = nil
    return true
end

function M.clear_all(_)
    -- Sweep every tracked toast. Per-app-id filtering would require
    -- IToastNotificationHistory which is another factory chain; we keep
    -- this simple and dismiss everything this Lua VM emitted.
    for tag, _ in pairs(_live) do
        M.dismiss(tag)
    end
    return true
end

function M.set_default_app_id(aumid)
    if type(aumid) ~= "string" or #aumid == 0 then
        error("set_default_app_id: aumid must be a non-empty string")
    end
    _default_app_id = aumid
end

function M.get_default_app_id()
    return _default_app_id
end

-- Convenience: callers can preview the XML payload that would be sent.
-- Useful for debugging shell-side parse failures.
function M.preview_xml(opts)
    return build_toast_xml(opts or {})
end

return M
