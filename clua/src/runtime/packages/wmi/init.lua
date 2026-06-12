-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- wmi -- Windows Management Instrumentation queries via COM.
--
-- Implementation strategy mirrors how vbscript / powershell talk to WMI:
-- get a SWbemLocator (CLSID), call ConnectServer to get a SWbemServices,
-- then ExecQuery -> SWbemObjectSet -> iterate SWbemObject. Every object
-- speaks IDispatch, so we drive it with GetIDsOfNames + Invoke instead of
-- redeclaring 20 COM interface vtables.
--
-- Public surface:
--   wmi.connect(namespace?)            -> service (default: root\\cimv2)
--   service:query(wql)                 -> iterator over result records
--   service:get(class, key_values)     -> record
--   service:execute_method(path, name, params?) -> result table
--   wmi.q.select{ class=, where=, properties= }  -> WQL helper
--   wmi.processes() / .services() / .disks() / .network_adapters()
--     / .installed_software()         -> array of records
--
-- A "record" is a plain Lua table -- property names mapped to Lua values
-- (strings, numbers, booleans, nil). Nested object refs are returned as
-- their string __PATH so callers can fetch them explicitly if needed.
--
-- COM apartments: we CoInitialize on every public entrypoint and tear
-- down on return. Callers don't have to know COM exists.

local W   = require "windows"
local COM = require "windows.com"

ffi.cdef[[
typedef struct wmi_IDispatch     wmi_IDispatch;
typedef struct wmi_IDispatchVtbl wmi_IDispatchVtbl;

typedef struct wmi_VARIANT {
    unsigned short vt;
    unsigned short wReserved1;
    unsigned short wReserved2;
    unsigned short wReserved3;
    long long      data0;
    long long      data1;
} wmi_VARIANT;

typedef struct wmi_DISPPARAMS {
    wmi_VARIANT *rgvarg;
    long        *rgdispidNamedArgs;
    unsigned int cArgs;
    unsigned int cNamedArgs;
} wmi_DISPPARAMS;

typedef struct wmi_EXCEPINFO {
    unsigned short wCode;
    unsigned short wReserved;
    LPWSTR         bstrSource;
    LPWSTR         bstrDescription;
    LPWSTR         bstrHelpFile;
    DWORD          dwHelpContext;
    void          *pvReserved;
    void          *pfnDeferredFillIn;
    long           scode;
} wmi_EXCEPINFO;

struct wmi_IDispatchVtbl {
    HRESULT (__stdcall *QueryInterface)(wmi_IDispatch *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(wmi_IDispatch *);
    ULONG   (__stdcall *Release)(wmi_IDispatch *);
    HRESULT (__stdcall *GetTypeInfoCount)(wmi_IDispatch *, unsigned int *);
    HRESULT (__stdcall *GetTypeInfo)(wmi_IDispatch *, unsigned int, DWORD, void **);
    HRESULT (__stdcall *GetIDsOfNames)(wmi_IDispatch *, GUID_W *, LPWSTR *,
                                       unsigned int, DWORD, long *);
    HRESULT (__stdcall *Invoke)(wmi_IDispatch *, long, GUID_W *, DWORD,
                                unsigned short, wmi_DISPPARAMS *,
                                wmi_VARIANT *, wmi_EXCEPINFO *,
                                unsigned int *);
};
struct wmi_IDispatch { wmi_IDispatchVtbl *lpVtbl; };

void  VariantInit(wmi_VARIANT *pvarg);
HRESULT VariantClear(wmi_VARIANT *pvarg);

/* SAFEARRAY accessors -- we read the property-name SAFEARRAY when
   walking a record's properties. */
typedef struct wmi_SAFEARRAYBOUND {
    ULONG cElements;
    long  lLbound;
} wmi_SAFEARRAYBOUND;

typedef struct wmi_SAFEARRAY {
    unsigned short cDims;
    unsigned short fFeatures;
    ULONG          cbElements;
    ULONG          cLocks;
    void          *pvData;
    wmi_SAFEARRAYBOUND rgsabound[1];
} wmi_SAFEARRAY;

HRESULT SafeArrayGetLBound(wmi_SAFEARRAY *psa, ULONG nDim, long *plLbound);
HRESULT SafeArrayGetUBound(wmi_SAFEARRAY *psa, ULONG nDim, long *plUbound);
HRESULT SafeArrayGetElement(wmi_SAFEARRAY *psa, long *rgIndices, void *pv);

/* COM init / instance creation */
HRESULT CoInitializeSecurity(void *, long, void *, void *, DWORD, DWORD, void *, DWORD, void *);
]]

local C      = ffi.C
local oleaut = ffi.load("oleaut32")

-- ===== VARIANT type tags =================================================
local VT_EMPTY    = 0
local VT_NULL     = 1
local VT_I2       = 2
local VT_I4       = 3
local VT_R4       = 4
local VT_R8       = 5
local VT_BSTR     = 8
local VT_DISPATCH = 9
local VT_BOOL     = 11
local VT_VARIANT  = 12
local VT_UI1      = 17
local VT_UI2      = 18
local VT_UI4      = 19
local VT_I8       = 20
local VT_UI8      = 21
local VT_ARRAY    = 0x2000
local VT_BYREF    = 0x4000

local DISPATCH_METHOD         = 0x1
local DISPATCH_PROPERTYGET    = 0x2
local DISPATCH_PROPERTYPUT    = 0x4

local LOCALE_USER_DEFAULT = 0x0400
local CLSCTX_INPROC_SERVER = 0x1
local COINIT_APARTMENTTHREADED = 0x2
local IID_NULL = ffi.new("GUID_W")

-- RPC_C_AUTHN_LEVEL_PKT_PRIVACY = 6, RPC_C_IMP_LEVEL_IMPERSONATE = 3
local RPC_C_AUTHN_LEVEL_PKT_PRIVACY = 6
local RPC_C_IMP_LEVEL_IMPERSONATE   = 3
local EOAC_NONE = 0

-- CLSID_WbemLocator = 4590F811-1D3A-11D0-891F-00AA004B2E24
-- IID_IWbemLocator  = DC12A687-737F-11CF-884D-00AA004B2E24
-- We talk to the script-friendly automation layer instead -- ProgID
-- "WbemScripting.SWbemLocator" -- because it returns IDispatch* already.

local function make_guid(s)
    local g = ffi.new("GUID_W")
    local d1, d2, d3, d4hi, d4lo = s:match(
        "^(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x+)$")
    if not d1 then error("bad GUID: " .. s) end
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

-- SWbemLocator -- the automation surface (returns IDispatch directly)
local CLSID_SWbemLocator = make_guid("76A64158-CB41-11D1-8B02-00600806D9B6")
local IID_IDispatch      = make_guid("00020400-0000-0000-C000-000000000046")

-- ===== helpers ===========================================================

local function fail(msg) error("wmi: " .. msg, 2) end

local function hrcheck(hr, ctx)
    if hr ~= 0 then
        local u = ffi.cast("unsigned long", hr)
        fail(string.format("%s failed (HRESULT 0x%08X)", ctx, tonumber(u)))
    end
end

local function bstr(s)
    if s == nil then return nil end
    local w = W.ToWide(s)
    return C.SysAllocString(w)
end

local function from_bstr(b)
    if b == nil then return nil end
    return W.FromWide(b)
end

local function release(p)
    if p ~= nil and p[0] ~= nil then
        p[0].lpVtbl.Release(p[0])
    end
end

-- VARIANT byte-offset accessors (payload at offset 8).
local function v_payload_p(v, ctype)
    return ffi.cast(ctype, ffi.cast("char *", v) + 8)
end

local function variant_init(v)  oleaut.VariantInit(v)  end
local function variant_clear(v) oleaut.VariantClear(v) end

local function v_set_bstr(v, b)
    variant_init(v); v.vt = VT_BSTR
    v_payload_p(v, "LPWSTR *")[0] = b
end
local function v_set_i4(v, n)
    variant_init(v); v.vt = VT_I4
    v_payload_p(v, "long *")[0] = n
end
local function v_set_bool(v, b)
    variant_init(v); v.vt = VT_BOOL
    v_payload_p(v, "short *")[0] = b and -1 or 0
end
local function v_set_dispatch(v, d)
    variant_init(v); v.vt = VT_DISPATCH
    v_payload_p(v, "void * *")[0] = d
end

local function v_get_bstr(v)
    if v.vt ~= VT_BSTR then return nil end
    local p = v_payload_p(v, "LPWSTR *")[0]
    if p == nil then return nil end
    return from_bstr(p)
end

local function v_get_dispatch(v)
    if v.vt ~= VT_DISPATCH then return nil end
    return v_payload_p(v, "void * *")[0]
end

-- Convert a VARIANT into a Lua-side value. Caller still owns the VARIANT
-- (we don't call VariantClear here -- that's the caller's job).
local function v_to_lua(v)
    local vt = v.vt
    -- Strip BYREF (we don't follow refs -- caller would need a special API)
    if bit.band(vt, VT_BYREF) ~= 0 then return nil end
    -- Strip ARRAY -- for SAFEARRAYs we yield a Lua list of scalars when
    -- the element type is a primitive we can read out of pvData. For more
    -- exotic arrays we yield nil (caller can re-query the property).
    if bit.band(vt, VT_ARRAY) ~= 0 then
        local elem_vt = bit.band(vt, 0x0FFF)
        local sap = v_payload_p(v, "wmi_SAFEARRAY * *")[0]
        if sap == nil then return nil end
        if sap.cDims ~= 1 then return nil end
        local lb = ffi.new("long[1]")
        local ub = ffi.new("long[1]")
        oleaut.SafeArrayGetLBound(sap, 1, lb)
        oleaut.SafeArrayGetUBound(sap, 1, ub)
        local lo, hi = tonumber(lb[0]), tonumber(ub[0])
        local out = {}
        for i = lo, hi do
            local idx = ffi.new("long[1]", i)
            if elem_vt == VT_BSTR then
                local out_b = ffi.new("LPWSTR[1]")
                if oleaut.SafeArrayGetElement(sap, idx, out_b) == 0 then
                    out[#out + 1] = from_bstr(out_b[0])
                    if out_b[0] ~= nil then C.SysFreeString(out_b[0]) end
                end
            elseif elem_vt == VT_I4 or elem_vt == VT_UI4 then
                local out_n = ffi.new("long[1]")
                if oleaut.SafeArrayGetElement(sap, idx, out_n) == 0 then
                    out[#out + 1] = tonumber(out_n[0])
                end
            elseif elem_vt == VT_I2 or elem_vt == VT_UI2 then
                local out_n = ffi.new("short[1]")
                if oleaut.SafeArrayGetElement(sap, idx, out_n) == 0 then
                    out[#out + 1] = tonumber(out_n[0])
                end
            elseif elem_vt == VT_UI1 then
                local out_n = ffi.new("unsigned char[1]")
                if oleaut.SafeArrayGetElement(sap, idx, out_n) == 0 then
                    out[#out + 1] = tonumber(out_n[0])
                end
            elseif elem_vt == VT_VARIANT then
                local out_v = ffi.new("wmi_VARIANT")
                variant_init(out_v)
                if oleaut.SafeArrayGetElement(sap, idx, out_v) == 0 then
                    out[#out + 1] = v_to_lua(out_v)
                    variant_clear(out_v)
                end
            else
                -- unsupported element type
                out[#out + 1] = nil
            end
        end
        return out
    end
    if vt == VT_EMPTY or vt == VT_NULL then
        return nil
    elseif vt == VT_BSTR then
        return v_get_bstr(v)
    elseif vt == VT_I2 then
        return tonumber(v_payload_p(v, "short *")[0])
    elseif vt == VT_I4 then
        return tonumber(v_payload_p(v, "long *")[0])
    elseif vt == VT_I8 then
        return tonumber(v_payload_p(v, "long long *")[0])
    elseif vt == VT_UI1 then
        return tonumber(v_payload_p(v, "unsigned char *")[0])
    elseif vt == VT_UI2 then
        return tonumber(v_payload_p(v, "unsigned short *")[0])
    elseif vt == VT_UI4 then
        return tonumber(v_payload_p(v, "unsigned long *")[0])
    elseif vt == VT_UI8 then
        return tonumber(v_payload_p(v, "unsigned long long *")[0])
    elseif vt == VT_R4 then
        return tonumber(v_payload_p(v, "float *")[0])
    elseif vt == VT_R8 then
        return tonumber(v_payload_p(v, "double *")[0])
    elseif vt == VT_BOOL then
        return v_payload_p(v, "short *")[0] ~= 0
    elseif vt == VT_DISPATCH then
        -- Return the raw pointer; caller can wrap it via wrap_object()
        return v_payload_p(v, "void * *")[0]
    end
    return nil
end

-- ===== generic IDispatch invoke ==========================================

local function disp_invoke(disp, name, flags, args)
    if disp == nil then fail("disp_invoke: nil dispatch (" .. name .. ")") end
    args = args or {}
    local nargs = #args
    local namew = W.ToWide(name)
    local names_arr = ffi.new("LPWSTR[1]")
    names_arr[0] = ffi.cast("LPWSTR", namew)
    local dispid = ffi.new("long[1]")
    local hr = disp[0].lpVtbl.GetIDsOfNames(disp[0], IID_NULL,
        names_arr, 1, LOCALE_USER_DEFAULT, dispid)
    hrcheck(hr, "GetIDsOfNames(" .. name .. ")")

    local varg, bstrs
    if nargs > 0 then
        varg  = ffi.new("wmi_VARIANT[?]", nargs)
        bstrs = {}
        for i, val in ipairs(args) do
            local slot = varg[nargs - i]
            local t = type(val)
            if val == nil then
                variant_init(slot); slot.vt = VT_EMPTY
            elseif t == "string" then
                local b = bstr(val)
                v_set_bstr(slot, b)
                bstrs[#bstrs + 1] = b
            elseif t == "number" then
                v_set_i4(slot, val)
            elseif t == "boolean" then
                v_set_bool(slot, val)
            elseif t == "cdata" then
                v_set_dispatch(slot, val)
            else
                fail("disp_invoke: unsupported arg type " .. t .. " for " .. name)
            end
        end
    end

    local dp = ffi.new("wmi_DISPPARAMS")
    dp.cArgs = nargs
    dp.rgvarg = varg ~= nil and varg or nil

    local named
    if flags == DISPATCH_PROPERTYPUT then
        named = ffi.new("long[1]", -3)
        dp.cNamedArgs = 1
        dp.rgdispidNamedArgs = named
    end

    local result = ffi.new("wmi_VARIANT")
    variant_init(result)
    local excep = ffi.new("wmi_EXCEPINFO")
    local arg_err = ffi.new("unsigned int[1]")

    hr = disp[0].lpVtbl.Invoke(disp[0], dispid[0], IID_NULL,
        LOCALE_USER_DEFAULT, flags, dp, result, excep, arg_err)

    if bstrs then
        for _, b in ipairs(bstrs) do
            if b ~= nil then C.SysFreeString(b) end
        end
    end

    if hr ~= 0 then
        local detail = ""
        if excep.bstrDescription ~= nil then
            detail = " :: " .. from_bstr(excep.bstrDescription)
            C.SysFreeString(excep.bstrDescription)
            if excep.bstrSource ~= nil then C.SysFreeString(excep.bstrSource) end
            if excep.bstrHelpFile ~= nil then C.SysFreeString(excep.bstrHelpFile) end
        end
        local u = ffi.cast("unsigned long", hr)
        fail(string.format("Invoke(%s) failed (HRESULT 0x%08X)%s",
            name, tonumber(u), detail))
    end

    return result
end

local function call_method(disp, name, ...)
    return disp_invoke(disp, name, DISPATCH_METHOD, { ... })
end
local function get_prop(disp, name, ...)
    return disp_invoke(disp, name, DISPATCH_PROPERTYGET + DISPATCH_METHOD, { ... })
end

local function dispatch_of(v)
    local raw = v_get_dispatch(v)
    if raw == nil then return nil end
    local p = ffi.new("wmi_IDispatch *[1]")
    p[0] = ffi.cast("wmi_IDispatch *", raw)
    v.vt = VT_EMPTY  -- take ownership; VariantClear will skip
    return p
end

-- ===== apartment + security init =========================================

local g_security_done = false

local function co_init()
    local hr = C.CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
    if hr ~= 0 and hr ~= 1 then hrcheck(hr, "CoInitializeEx") end
    -- WMI requires CoInitializeSecurity once per process. Calling it
    -- twice on the same process returns RPC_E_TOO_LATE (0x80010119),
    -- which is fine -- we just remember we tried.
    if not g_security_done then
        local hr2 = C.CoInitializeSecurity(nil, -1, nil, nil,
            RPC_C_AUTHN_LEVEL_PKT_PRIVACY, RPC_C_IMP_LEVEL_IMPERSONATE,
            nil, EOAC_NONE, nil)
        -- ignore RPC_E_TOO_LATE
        if hr2 ~= 0 and ffi.cast("unsigned long", hr2) ~= 0x80010119 then
            -- non-fatal; some WMI namespaces still work without it.
        end
        g_security_done = true
    end
end

local function co_uninit() C.CoUninitialize() end

-- ===== record (SWbemObject) -> Lua table =================================
--
-- Each SWbemObject exposes a Properties_ collection. We iterate it via the
-- _NewEnum dispatch -- the standard COM enumerator pattern. To keep things
-- simple we don't enumerate methods; callers can call execute_method when
-- they need that.

local function read_record(obj)
    -- obj is an IDispatch* for a SWbemObject. The Properties_ collection
    -- has a Count property + an Item method indexed by property name. The
    -- straightforward way is via the GetObjectText_ method which dumps a
    -- MOF-style string, but we want native Lua values, so we iterate the
    -- Properties_ collection by index.
    local props_v = get_prop(obj, "Properties_")
    local props = dispatch_of(props_v)
    if props == nil then variant_clear(props_v); return {} end
    -- Count_
    local count_v = get_prop(props, "Count")
    local count = v_to_lua(count_v) or 0
    variant_clear(count_v)

    local out = {}
    -- ItemIndex(int) is non-standard; use the _NewEnum-based iteration via
    -- the .Name + .Value subobjects. The most portable way is "for each
    -- property in obj.Properties_": SWbemProperty has Name + Value props.
    -- We synthesize that loop by calling _NewEnum on the collection.
    local enum_v = get_prop(props, "_NewEnum")
    -- _NewEnum returns an IEnumVARIANT (IUnknown* really). For the
    -- SWbemPropertySet collection, the more reliable path is to fall back
    -- to GetNames_(...) which yields a SAFEARRAY of BSTR property names.
    variant_clear(enum_v)

    local names_v = call_method(obj, "GetNames_", "", 0, nil)
    local names = v_to_lua(names_v)
    variant_clear(names_v)

    if type(names) == "table" then
        for _, n in ipairs(names) do
            -- Properties_.Item(name) -> SWbemProperty -> .Value
            local item_v = get_prop(props, "Item", n)
            local item = dispatch_of(item_v)
            if item ~= nil then
                local val_v = get_prop(item, "Value")
                out[n] = v_to_lua(val_v)
                variant_clear(val_v)
                release(item)
            else
                variant_clear(item_v)
            end
        end
    end

    release(props)
    return out
end

-- ===== service object ====================================================

local service_mt = { __index = {} }
local service_methods = service_mt.__index

function service_methods:close()
    if self._svc then release(self._svc); self._svc = nil end
    if self._loc then release(self._loc); self._loc = nil end
    co_uninit()
end

service_mt.__gc = service_methods.close

function service_methods:query(wql)
    -- ExecQuery(wql, queryLanguage?, flags?, ctx?) -> SWbemObjectSet
    local set_v = call_method(self._svc, "ExecQuery", wql)
    local set = dispatch_of(set_v)
    if set == nil then fail("ExecQuery returned no set") end

    -- Walk via the collection's Count + ItemIndex. SWbemObjectSet supports
    -- ItemIndex(i) directly (1-based), which avoids dealing with IEnumVARIANT.
    local count_v = get_prop(set, "Count")
    local count = v_to_lua(count_v) or 0
    variant_clear(count_v)
    local i = 0
    return function()
        i = i + 1
        if i > count then
            release(set)
            return nil
        end
        local item_v = call_method(set, "ItemIndex", i - 1)  -- 0-based
        local item = dispatch_of(item_v)
        if item == nil then return nil end
        local rec = read_record(item)
        release(item)
        return rec
    end
end

function service_methods:query_all(wql)
    local out, n = {}, 0
    for r in self:query(wql) do n = n + 1; out[n] = r end
    return out
end

function service_methods:get(path)
    -- SWbemServices.Get(strObjectPath, flags?, ctx?) -> SWbemObject
    local obj_v = call_method(self._svc, "Get", path)
    local obj = dispatch_of(obj_v)
    if obj == nil then return nil, "no object" end
    local rec = read_record(obj)
    release(obj)
    return rec
end

function service_methods:execute_method(path, method_name, params)
    -- ExecMethod_(objectPath, methodName, inParameters?, flags?, ctx?)
    -- inParameters is a SWbemNamedValueSet or nil; for the simple case of
    -- "fire and forget" we pass nil. Output is a SWbemObject we read like
    -- any record.
    -- In-parameter packing isn't implemented yet. Rather than SILENTLY dropping
    -- a caller's params (which makes a no-arg method run and mislead them into
    -- thinking their arguments were applied), reject them with a clear error.
    if params ~= nil then
        if type(params) ~= "table" then
            error("wmi.execute_method: params must be a table or nil", 2)
        end
        if next(params) ~= nil then
            error("wmi.execute_method: in-parameters are not supported yet; only "
                .. "no-argument methods can be invoked (pass nil)", 2)
        end
    end
    local out_v = call_method(self._svc, "ExecMethod_", path, method_name)
    local out = dispatch_of(out_v)
    if out == nil then return {} end
    local rec = read_record(out)
    release(out)
    return rec
end

-- ===== public entry ======================================================

local M = {}

function M.connect(namespace)
    co_init()
    namespace = namespace or "root\\cimv2"
    local loc = ffi.new("wmi_IDispatch *[1]")
    local hr = C.CoCreateInstance(CLSID_SWbemLocator, nil,
        CLSCTX_INPROC_SERVER, IID_IDispatch, ffi.cast("void **", loc))
    hrcheck(hr, "CoCreateInstance(SWbemLocator)")

    -- ConnectServer(strServer, strNamespace, ...) -> SWbemServices
    local svc_v = call_method(loc, "ConnectServer", ".", namespace)
    local svc = dispatch_of(svc_v)
    if svc == nil then
        release(loc); co_uninit()
        return nil, "ConnectServer returned no service"
    end

    return setmetatable({ _loc = loc, _svc = svc }, service_mt)
end

-- ===== WQL builder =======================================================

M.q = {}

-- wmi.q.select{ class="Win32_Process", where="Name='lua.exe'", properties={"Name","ProcessId"} }
function M.q.select(opts)
    assert(opts.class, "wmi.q.select: opts.class required")
    local cols = "*"
    if opts.properties and #opts.properties > 0 then
        cols = table.concat(opts.properties, ", ")
    end
    local q = "SELECT " .. cols .. " FROM " .. opts.class
    if opts.where then q = q .. " WHERE " .. opts.where end
    return q
end

-- Escape a string value so it can be embedded in a WQL WHERE clause as
-- "field='value'". WQL uses single-quoted strings with backslash escapes.
function M.q.escape(s)
    return (s:gsub("\\", "\\\\"):gsub("'", "\\'"))
end

-- ===== predefined collections ============================================

local function with_default_namespace(fn)
    local svc, err = M.connect()
    if not svc then return nil, err end
    local ok, result = pcall(fn, svc)
    svc:close()
    if not ok then return nil, result end
    return result
end

function M.processes()
    return with_default_namespace(function(svc)
        return svc:query_all("SELECT Name, ProcessId, ParentProcessId, " ..
            "ExecutablePath, CommandLine, SessionId, WorkingSetSize, " ..
            "CreationDate FROM Win32_Process")
    end)
end

function M.services()
    return with_default_namespace(function(svc)
        return svc:query_all("SELECT Name, DisplayName, State, StartMode, " ..
            "Status, ProcessId, PathName, StartName FROM Win32_Service")
    end)
end

function M.disks()
    return with_default_namespace(function(svc)
        return svc:query_all("SELECT DeviceID, VolumeName, FileSystem, " ..
            "Size, FreeSpace, DriveType, MediaType FROM Win32_LogicalDisk")
    end)
end

function M.network_adapters()
    return with_default_namespace(function(svc)
        return svc:query_all("SELECT Description, MACAddress, IPAddress, " ..
            "IPSubnet, DefaultIPGateway, DHCPEnabled, DNSServerSearchOrder " ..
            "FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=TRUE")
    end)
end

function M.installed_software()
    return with_default_namespace(function(svc)
        return svc:query_all("SELECT Name, Vendor, Version, InstallDate, " ..
            "InstallLocation, IdentifyingNumber FROM Win32_Product")
    end)
end

-- Convenience: get OS info as a single record.
function M.os_info()
    return with_default_namespace(function(svc)
        for rec in svc:query("SELECT * FROM Win32_OperatingSystem") do
            return rec  -- first hit
        end
        return nil
    end)
end

-- Convenience: get computer system info.
function M.system_info()
    return with_default_namespace(function(svc)
        for rec in svc:query("SELECT * FROM Win32_ComputerSystem") do
            return rec
        end
        return nil
    end)
end

-- Convenience: BIOS info.
function M.bios()
    return with_default_namespace(function(svc)
        for rec in svc:query("SELECT * FROM Win32_BIOS") do
            return rec
        end
        return nil
    end)
end

-- Convenience: physical memory layout.
function M.memory_modules()
    return with_default_namespace(function(svc)
        return svc:query_all("SELECT DeviceLocator, Capacity, Speed, " ..
            "Manufacturer, PartNumber FROM Win32_PhysicalMemory")
    end)
end

-- Convenience: CPU info.
function M.processors()
    return with_default_namespace(function(svc)
        return svc:query_all("SELECT Name, Manufacturer, NumberOfCores, " ..
            "NumberOfLogicalProcessors, MaxClockSpeed, Architecture, " ..
            "ProcessorId FROM Win32_Processor")
    end)
end

return M
