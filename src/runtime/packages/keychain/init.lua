-- keychain -- Windows Credential Manager (Vault) password storage.
--
-- Public surface:
--   keychain.set(target, username, password, opts?)   -> true
--   keychain.get(target)                              -> entry | nil
--   keychain.delete(target)                           -> true | nil, err
--   keychain.exists(target)                           -> bool
--   keychain.list(filter?)                            -> { entry, ... }
--
-- opts (set):
--   type     = "generic" | "domain" | "domain_visible" | "domain_extended"
--                  | "generic_certificate" | "domain_certificate"   default "generic"
--   persist  = "session" | "local" | "enterprise"                   default "local"
--   comment  = string
--   attributes = { { keyword="...", value=... }, ... }              optional
--
-- entry:
--   { target, username, password, type, persist, comment, last_written }
--
-- Credentials are encrypted by Windows under the calling user's DPAPI key.
-- "generic" is the right type for app-level secrets (API keys, tokens).

local W = require "windows"

ffi.cdef[[
typedef struct _CREDENTIAL_ATTRIBUTE_W {
    LPWSTR Keyword;
    DWORD  Flags;
    DWORD  ValueSize;
    BYTE  *Value;
} CREDENTIAL_ATTRIBUTE_W;

typedef struct _CREDENTIAL_W {
    DWORD     Flags;
    DWORD     Type;
    LPWSTR    TargetName;
    LPWSTR    Comment;
    FILETIME  LastWritten;
    DWORD     CredentialBlobSize;
    BYTE     *CredentialBlob;
    DWORD     Persist;
    DWORD     AttributeCount;
    CREDENTIAL_ATTRIBUTE_W *Attributes;
    LPWSTR    TargetAlias;
    LPWSTR    UserName;
} CREDENTIAL_W;

BOOL CredReadW(LPCWSTR TargetName, DWORD Type, DWORD Flags, CREDENTIAL_W **Credential);
BOOL CredWriteW(CREDENTIAL_W *Credential, DWORD Flags);
BOOL CredDeleteW(LPCWSTR TargetName, DWORD Type, DWORD Flags);
BOOL CredEnumerateW(LPCWSTR Filter, DWORD Flags, DWORD *Count, CREDENTIAL_W ***Credentials);
void CredFree(void *Buffer);
]]

pcall(ffi.load, "advapi32")

local C = ffi.C
local M = {}

-- ===== type / persist constants ========================================
M.TYPE_GENERIC                 = 1
M.TYPE_DOMAIN_PASSWORD         = 2
M.TYPE_DOMAIN_CERTIFICATE      = 3
M.TYPE_DOMAIN_VISIBLE_PASSWORD = 4
M.TYPE_GENERIC_CERTIFICATE     = 5
M.TYPE_DOMAIN_EXTENDED         = 6
M.TYPE_MAXIMUM                 = 7

M.PERSIST_SESSION              = 1
M.PERSIST_LOCAL_MACHINE        = 2
M.PERSIST_ENTERPRISE           = 3

M.ENUMERATE_ALL_CREDENTIALS    = 0x1

-- Error codes (winerror.h)
local ERROR_NOT_FOUND          = 1168
local ERROR_NO_SUCH_LOGON_SESSION = 1312
local ERROR_INVALID_PARAMETER  = 87
local ERROR_INVALID_FLAGS      = 1004

-- ===== option -> constant maps =========================================
local _TYPE_MAP = {
    generic              = M.TYPE_GENERIC,
    domain               = M.TYPE_DOMAIN_PASSWORD,
    domain_visible       = M.TYPE_DOMAIN_VISIBLE_PASSWORD,
    domain_extended      = M.TYPE_DOMAIN_EXTENDED,
    generic_certificate  = M.TYPE_GENERIC_CERTIFICATE,
    domain_certificate   = M.TYPE_DOMAIN_CERTIFICATE,
}

local _PERSIST_MAP = {
    session    = M.PERSIST_SESSION,
    local_     = M.PERSIST_LOCAL_MACHINE,
    ["local"]  = M.PERSIST_LOCAL_MACHINE,
    enterprise = M.PERSIST_ENTERPRISE,
}

local _TYPE_NAME = {
    [M.TYPE_GENERIC]                 = "generic",
    [M.TYPE_DOMAIN_PASSWORD]         = "domain",
    [M.TYPE_DOMAIN_VISIBLE_PASSWORD] = "domain_visible",
    [M.TYPE_DOMAIN_EXTENDED]         = "domain_extended",
    [M.TYPE_GENERIC_CERTIFICATE]     = "generic_certificate",
    [M.TYPE_DOMAIN_CERTIFICATE]      = "domain_certificate",
}

local _PERSIST_NAME = {
    [M.PERSIST_SESSION]       = "session",
    [M.PERSIST_LOCAL_MACHINE] = "local",
    [M.PERSIST_ENTERPRISE]    = "enterprise",
}

-- ===== helpers =========================================================

local function resolve_type(opt)
    if opt == nil then return M.TYPE_GENERIC end
    if type(opt) == "number" then return opt end
    local t = _TYPE_MAP[opt]
    if not t then error("keychain: unknown credential type '" .. tostring(opt) .. "'") end
    return t
end

local function resolve_persist(opt)
    if opt == nil then return M.PERSIST_LOCAL_MACHINE end
    if type(opt) == "number" then return opt end
    local p = _PERSIST_MAP[opt]
    if not p then error("keychain: unknown persist value '" .. tostring(opt) .. "'") end
    return p
end

local function gle_to_error(prefix)
    local e = tonumber(C.GetLastError())
    if e == ERROR_NOT_FOUND then return prefix .. ": not found" end
    if e == ERROR_NO_SUCH_LOGON_SESSION then
        return prefix .. ": no logon session (run interactively)"
    end
    if e == ERROR_INVALID_PARAMETER then return prefix .. ": invalid parameter" end
    if e == ERROR_INVALID_FLAGS then return prefix .. ": invalid flags" end
    return string.format("%s: GLE=%d", prefix, e)
end

-- Convert UTF-16 LPWSTR pointer to Lua string (or nil if pointer is null).
local function wstr_to_lua(ptr)
    if ptr == nil then return nil end
    -- W.FromWide expects null-terminated; LPWSTR from CredRead always is.
    return W.FromWide(ptr)
end

local function filetime_to_unix(ft)
    -- FILETIME = 100ns intervals since 1601-01-01. Convert to seconds since
    -- 1970. (369 years gap = 11644473600 seconds.)
    local hi = tonumber(ft.dwHighDateTime)
    local lo = tonumber(ft.dwLowDateTime)
    local total = hi * 4294967296 + lo  -- 100ns units
    local secs = total / 1e7 - 11644473600
    return secs
end

local function cred_to_table(cred)
    local entry = {
        target    = wstr_to_lua(cred.TargetName),
        username  = wstr_to_lua(cred.UserName),
        type      = _TYPE_NAME[tonumber(cred.Type)] or tonumber(cred.Type),
        persist   = _PERSIST_NAME[tonumber(cred.Persist)] or tonumber(cred.Persist),
        comment   = wstr_to_lua(cred.Comment),
        alias     = wstr_to_lua(cred.TargetAlias),
        last_written = filetime_to_unix(cred.LastWritten),
    }
    if cred.CredentialBlob ~= nil and cred.CredentialBlobSize > 0 then
        -- For generic creds, Windows stores the password as UTF-16LE bytes
        -- without a null terminator. Decode if length looks like UTF-16
        -- (even byte count and looks like wide-char text).
        local n = tonumber(cred.CredentialBlobSize)
        local raw = ffi.string(cred.CredentialBlob, n)
        if (n % 2) == 0 then
            -- Heuristic decode: if every other byte is null we have ASCII-in-UTF-16.
            -- For any non-ASCII data this still produces sensible UTF-8 output.
            local widen = ffi.new("unsigned short[?]", n / 2 + 1)
            ffi.copy(widen, raw, n)
            widen[n / 2] = 0
            local ok, decoded = pcall(W.FromWide, widen)
            if ok then
                entry.password = decoded
                entry.password_bytes = raw
            else
                entry.password = raw
            end
        else
            entry.password = raw
        end
    end
    if cred.AttributeCount > 0 and cred.Attributes ~= nil then
        local attrs = {}
        for i = 0, tonumber(cred.AttributeCount) - 1 do
            local a = cred.Attributes[i]
            local val = nil
            if a.Value ~= nil and a.ValueSize > 0 then
                val = ffi.string(a.Value, tonumber(a.ValueSize))
            end
            attrs[#attrs + 1] = { keyword = wstr_to_lua(a.Keyword), value = val }
        end
        entry.attributes = attrs
    end
    return entry
end

-- ===== set / get / delete / exists =====================================

function M.set(target, username, password, opts)
    if type(target) ~= "string" or #target == 0 then
        error("keychain.set: target must be non-empty string")
    end
    opts = opts or {}
    username = username or ""
    password = password or ""

    local wtarget = W.ToWide(target)
    local wuser   = W.ToWide(username)
    local wcomment = opts.comment and W.ToWide(opts.comment) or nil

    -- Password blob: UTF-16LE bytes, no null terminator (Windows convention).
    local pw_wide
    local pw_bytes = 0
    if #password > 0 then
        local wbuf, wlen = W.ToWide(password)
        -- wlen includes the trailing null; trim it -- the blob doesn't carry one.
        pw_wide = wbuf
        pw_bytes = (wlen - 1) * 2
    end

    -- Attribute array (optional)
    local attr_array = nil
    local attr_count = 0
    local attr_anchors = {}
    if opts.attributes and #opts.attributes > 0 then
        attr_count = #opts.attributes
        attr_array = ffi.new("CREDENTIAL_ATTRIBUTE_W[?]", attr_count)
        for i, a in ipairs(opts.attributes) do
            local kw = a.keyword or error("keychain.set: attribute missing keyword")
            local wk = W.ToWide(kw)
            attr_anchors[#attr_anchors + 1] = wk
            attr_array[i - 1].Keyword = ffi.cast("LPWSTR", wk)
            attr_array[i - 1].Flags   = 0
            if a.value and #a.value > 0 then
                local vbuf = ffi.new("uint8_t[?]", #a.value)
                ffi.copy(vbuf, a.value, #a.value)
                attr_anchors[#attr_anchors + 1] = vbuf
                attr_array[i - 1].Value     = vbuf
                attr_array[i - 1].ValueSize = #a.value
            else
                attr_array[i - 1].Value     = nil
                attr_array[i - 1].ValueSize = 0
            end
        end
    end

    local cred = ffi.new("CREDENTIAL_W")
    cred.Flags        = 0
    cred.Type         = resolve_type(opts.type)
    cred.TargetName   = ffi.cast("LPWSTR", wtarget)
    cred.Comment      = wcomment and ffi.cast("LPWSTR", wcomment) or nil
    cred.LastWritten.dwLowDateTime  = 0
    cred.LastWritten.dwHighDateTime = 0
    cred.CredentialBlobSize = pw_bytes
    cred.CredentialBlob     = pw_wide and ffi.cast("BYTE *", pw_wide) or nil
    cred.Persist      = resolve_persist(opts.persist)
    cred.AttributeCount = attr_count
    cred.Attributes   = attr_array
    cred.TargetAlias  = nil
    cred.UserName     = ffi.cast("LPWSTR", wuser)

    if C.CredWriteW(cred, 0) == 0 then
        error(gle_to_error("keychain.set"))
    end
    -- Anchor lifetimes through the call.
    if wtarget or wuser or wcomment or pw_wide or attr_anchors then end
    return true
end

function M.get(target)
    if type(target) ~= "string" or #target == 0 then return nil end
    local wtarget = W.ToWide(target)
    local out = ffi.new("CREDENTIAL_W *[1]")
    -- Try generic first (most common), then domain.
    if C.CredReadW(wtarget, M.TYPE_GENERIC, 0, out) == 0 then
        local e = tonumber(C.GetLastError())
        if e == ERROR_NOT_FOUND then
            if C.CredReadW(wtarget, M.TYPE_DOMAIN_PASSWORD, 0, out) == 0 then
                return nil
            end
        else
            return nil
        end
    end
    if out[0] == nil then return nil end
    local entry = cred_to_table(out[0])
    C.CredFree(out[0])
    return entry
end

function M.delete(target, opts)
    opts = opts or {}
    local wtarget = W.ToWide(target)
    local t = resolve_type(opts.type)
    if C.CredDeleteW(wtarget, t, 0) == 0 then
        local e = tonumber(C.GetLastError())
        if t == M.TYPE_GENERIC and e == ERROR_NOT_FOUND then
            -- Try domain as fallback (matches the get() lookup order).
            if C.CredDeleteW(wtarget, M.TYPE_DOMAIN_PASSWORD, 0) == 0 then
                return nil, gle_to_error("keychain.delete")
            end
        else
            return nil, gle_to_error("keychain.delete")
        end
    end
    return true
end

function M.exists(target)
    return M.get(target) ~= nil
end

function M.list(filter)
    local wfilter = filter and W.ToWide(filter) or nil
    local count = ffi.new("DWORD[1]")
    local arr   = ffi.new("CREDENTIAL_W **[1]")
    local flags = wfilter and 0 or M.ENUMERATE_ALL_CREDENTIALS
    if C.CredEnumerateW(wfilter, flags, count, arr) == 0 then
        local e = tonumber(C.GetLastError())
        if e == ERROR_NOT_FOUND then return {} end
        error(gle_to_error("keychain.list"))
    end
    local n = tonumber(count[0])
    local out = {}
    for i = 0, n - 1 do
        out[i + 1] = cred_to_table(arr[0][i])
    end
    C.CredFree(arr[0])
    return out
end

return M
