-- dpapi -- Windows Data Protection API: CryptProtectData / CryptUnprotectData.
--
-- Public surface:
--   dpapi.protect(data, opts?)            -> blob (bytes)
--   dpapi.unprotect(blob, opts?)          -> data, description
--   dpapi.protect_string(s, opts?)        -> blob       (convenience)
--   dpapi.unprotect_string(blob, opts?)   -> s, description
--   dpapi.ngc_protect(data, opts?)        -> blob       (Win10+ vault, PIN/biometric-tied)
--   dpapi.ngc_unprotect(blob, opts?)      -> data
--   dpapi.round_trip(data, opts?)         -> bool, err  (encrypt+decrypt sanity check)
--
-- opts (protect):
--   scope        = "user" | "machine"            default "user"
--   entropy      = string | nil                  optional secondary entropy
--   description  = string                        embedded label, returned by unprotect
--   prompt_flags = { on_protect=bool, on_unprotect=bool,
--                    strong=bool, require_strong=bool }
--
-- opts (unprotect):
--   entropy      = string | nil                  must match protect-side entropy
--   prompt_flags = (same shape as protect)
--   want_description = bool                      default true
--
-- DPAPI's protect output is opaque -- a versioned blob that includes the
-- master-key GUID, IV, MAC, and ciphertext. Treat blob as a black box and
-- only feed it back to CryptUnprotectData.

local W = require "windows"

ffi.cdef[[
typedef struct _DATA_BLOB_DP {
    DWORD cbData;
    BYTE *pbData;
} DATA_BLOB_DP;

typedef struct _CRYPTPROTECT_PROMPTSTRUCT {
    DWORD   cbSize;
    DWORD   dwPromptFlags;
    HWND    hwndApp;
    LPCWSTR szPrompt;
} CRYPTPROTECT_PROMPTSTRUCT;

BOOL CryptProtectData(DATA_BLOB_DP *pDataIn, LPCWSTR szDataDescr,
                      DATA_BLOB_DP *pOptionalEntropy, PVOID pvReserved,
                      CRYPTPROTECT_PROMPTSTRUCT *pPromptStruct, DWORD dwFlags,
                      DATA_BLOB_DP *pDataOut);

BOOL CryptUnprotectData(DATA_BLOB_DP *pDataIn, LPWSTR *ppszDataDescr,
                        DATA_BLOB_DP *pOptionalEntropy, PVOID pvReserved,
                        CRYPTPROTECT_PROMPTSTRUCT *pPromptStruct, DWORD dwFlags,
                        DATA_BLOB_DP *pDataOut);

HANDLE LocalFree(HANDLE hMem);

/* NgcProtect / NgcUnprotect (Win10 1607+, ncrypt.dll).
 * The protector descriptor "LOCAL=user" routes through the Microsoft
 * Software Key Storage Provider and is decryptable only by the logged-on
 * user once they've completed an interactive credential (PIN/biometric)
 * gesture. */
HRESULT NCryptCreateProtectionDescriptor(LPCWSTR pwszDescriptorString,
                                         DWORD dwFlags, PVOID *phDescriptor);
HRESULT NCryptCloseProtectionDescriptor(PVOID hDescriptor);
HRESULT NCryptProtectSecret(PVOID hDescriptor, DWORD dwFlags,
                            const BYTE *pbData, ULONG cbData,
                            PVOID pMemPara, HWND hWnd,
                            BYTE **ppbProtectedBlob, ULONG *pcbProtectedBlob);
HRESULT NCryptUnprotectSecret(PVOID *phDescriptor, DWORD dwFlags,
                              const BYTE *pbProtectedBlob, ULONG cbProtectedBlob,
                              PVOID pMemPara, HWND hWnd,
                              BYTE **ppbData, ULONG *pcbData);
]]

-- crypt32 is in-box but not in the windows core ffi.load list.
pcall(ffi.load, "crypt32")
pcall(ffi.load, "kernel32")
pcall(ffi.load, "ncrypt")

local C = ffi.C
local M = {}

-- ===== CryptProtectData flags ==========================================
M.CRYPTPROTECT_UI_FORBIDDEN       = 0x1
M.CRYPTPROTECT_LOCAL_MACHINE      = 0x4
M.CRYPTPROTECT_CRED_SYNC          = 0x8
M.CRYPTPROTECT_AUDIT              = 0x10
M.CRYPTPROTECT_NO_RECOVERY        = 0x20
M.CRYPTPROTECT_VERIFY_PROTECTION  = 0x40
M.CRYPTPROTECT_CRED_REGENERATE    = 0x80

-- CRYPTPROTECT_PROMPTSTRUCT.dwPromptFlags
M.CRYPTPROTECT_PROMPT_ON_UNPROTECT = 0x1
M.CRYPTPROTECT_PROMPT_ON_PROTECT   = 0x2
M.CRYPTPROTECT_PROMPT_STRONG       = 0x8
M.CRYPTPROTECT_PROMPT_REQUIRE_STRONG = 0x10

-- ===== helpers =========================================================

local function fill_blob(blob, s)
    -- Caller-owned buffer (anchored to keep cdata alive for the API call).
    local n = s and #s or 0
    blob.cbData = n
    if n > 0 then
        local buf = ffi.new("uint8_t[?]", n)
        ffi.copy(buf, s, n)
        blob.pbData = buf
        return buf  -- return for anchor lifetime
    else
        blob.pbData = nil
        return nil
    end
end

local function build_prompt(opts_pf)
    if not opts_pf then return nil, nil end
    local flags = 0
    if opts_pf.on_unprotect   then flags = flags + M.CRYPTPROTECT_PROMPT_ON_UNPROTECT end
    if opts_pf.on_protect     then flags = flags + M.CRYPTPROTECT_PROMPT_ON_PROTECT end
    if opts_pf.strong         then flags = flags + M.CRYPTPROTECT_PROMPT_STRONG end
    if opts_pf.require_strong then flags = flags + M.CRYPTPROTECT_PROMPT_REQUIRE_STRONG end
    if flags == 0 then return nil, nil end
    local prompt = ffi.new("CRYPTPROTECT_PROMPTSTRUCT")
    prompt.cbSize = ffi.sizeof("CRYPTPROTECT_PROMPTSTRUCT")
    prompt.dwPromptFlags = flags
    prompt.hwndApp = nil
    -- szPrompt left null -- DPAPI shows a default dialog.
    prompt.szPrompt = nil
    return prompt, nil
end

local function blob_to_string(blob)
    if blob.cbData == 0 then return "" end
    local s = ffi.string(blob.pbData, blob.cbData)
    C.LocalFree(blob.pbData)
    return s
end

-- ===== protect / unprotect =============================================

function M.protect(data, opts)
    if type(data) ~= "string" then error("dpapi.protect: data must be string") end
    opts = opts or {}

    local din = ffi.new("DATA_BLOB_DP")
    local din_anchor = fill_blob(din, data)

    local ent = nil
    local ent_anchor
    if opts.entropy then
        ent = ffi.new("DATA_BLOB_DP")
        ent_anchor = fill_blob(ent, opts.entropy)
    end

    local desc_w = nil
    if opts.description and #opts.description > 0 then
        desc_w = W.ToWide(opts.description)
    end

    local prompt = build_prompt(opts.prompt_flags)

    local flags = M.CRYPTPROTECT_UI_FORBIDDEN
    if opts.scope == "machine" then
        flags = flags + M.CRYPTPROTECT_LOCAL_MACHINE
    end

    local dout = ffi.new("DATA_BLOB_DP")
    local ok = C.CryptProtectData(din, desc_w, ent, nil, prompt, flags, dout)
    if ok == 0 then
        local gle = tonumber(C.GetLastError())
        error(string.format("dpapi.protect: CryptProtectData failed (GLE=%d)", gle))
    end
    -- Keep anchors alive past the call.
    if din_anchor or ent_anchor then end
    return blob_to_string(dout)
end

function M.unprotect(blob, opts)
    if type(blob) ~= "string" then error("dpapi.unprotect: blob must be string") end
    opts = opts or {}
    local want_desc = opts.want_description
    if want_desc == nil then want_desc = true end

    local din = ffi.new("DATA_BLOB_DP")
    local din_anchor = fill_blob(din, blob)

    local ent = nil
    local ent_anchor
    if opts.entropy then
        ent = ffi.new("DATA_BLOB_DP")
        ent_anchor = fill_blob(ent, opts.entropy)
    end

    local prompt = build_prompt(opts.prompt_flags)

    local flags = M.CRYPTPROTECT_UI_FORBIDDEN
    if opts.scope == "machine" then
        flags = flags + M.CRYPTPROTECT_LOCAL_MACHINE
    end

    local dout = ffi.new("DATA_BLOB_DP")
    local desc_ptr = ffi.new("LPWSTR[1]")
    local ok = C.CryptUnprotectData(din, want_desc and desc_ptr or nil, ent,
                                    nil, prompt, flags, dout)
    if ok == 0 then
        local gle = tonumber(C.GetLastError())
        error(string.format("dpapi.unprotect: CryptUnprotectData failed (GLE=%d)", gle))
    end
    if din_anchor or ent_anchor then end

    local data = blob_to_string(dout)
    local description = nil
    if want_desc and desc_ptr[0] ~= nil then
        description = W.FromWide(desc_ptr[0])
        C.LocalFree(desc_ptr[0])
    end
    return data, description
end

-- ===== string convenience ==============================================

function M.protect_string(s, opts)
    return M.protect(s, opts)
end

function M.unprotect_string(blob, opts)
    return M.unprotect(blob, opts)
end

-- ===== NgcProtect / NgcUnprotect (Win10+ credential vault) =============

local function check_hr(hr, where)
    if hr ~= 0 then
        error(string.format("dpapi.%s: HRESULT 0x%08X", where, hr % 0x100000000))
    end
end

-- Default descriptor: ties the secret to the currently logged-on user.
-- Other valid forms: "SID=S-1-...", "LOCAL=machine", "WEBCREDENTIALS=...".
local _NGC_DEFAULT_DESCRIPTOR = "LOCAL=user"

local function open_descriptor(desc_string)
    local desc_w = W.ToWide(desc_string or _NGC_DEFAULT_DESCRIPTOR)
    local handle = ffi.new("PVOID[1]")
    local hr = C.NCryptCreateProtectionDescriptor(desc_w, 0, handle)
    check_hr(tonumber(hr), "ngc_protect/CreateProtectionDescriptor")
    return handle[0]
end

function M.ngc_protect(data, opts)
    if type(data) ~= "string" then error("dpapi.ngc_protect: data must be string") end
    opts = opts or {}
    local desc = open_descriptor(opts.descriptor)

    local in_buf
    if #data > 0 then
        in_buf = ffi.new("uint8_t[?]", #data)
        ffi.copy(in_buf, data, #data)
    end
    local out_ptr = ffi.new("BYTE *[1]")
    local out_len = ffi.new("ULONG[1]")
    -- dwFlags 0 = NCRYPT_SILENT_FLAG off; pass 0x40 (NCRYPT_SILENT_FLAG) to
    -- forbid UI. Default leaves UI allowed so the user can complete the gesture.
    local flags = 0
    if opts.silent then flags = 0x40 end
    local hr = C.NCryptProtectSecret(desc, flags, in_buf, #data, nil, nil,
                                     out_ptr, out_len)
    C.NCryptCloseProtectionDescriptor(desc)
    check_hr(tonumber(hr), "ngc_protect/ProtectSecret")
    local result = ffi.string(out_ptr[0], tonumber(out_len[0]))
    C.LocalFree(out_ptr[0])
    return result
end

function M.ngc_unprotect(blob, opts)
    if type(blob) ~= "string" then error("dpapi.ngc_unprotect: blob must be string") end
    opts = opts or {}
    local in_buf
    if #blob > 0 then
        in_buf = ffi.new("uint8_t[?]", #blob)
        ffi.copy(in_buf, blob, #blob)
    end
    local out_ptr = ffi.new("BYTE *[1]")
    local out_len = ffi.new("ULONG[1]")
    local flags = 0
    if opts.silent then flags = 0x40 end
    local desc = ffi.new("PVOID[1]")
    local hr = C.NCryptUnprotectSecret(desc, flags, in_buf, #blob, nil, nil,
                                       out_ptr, out_len)
    check_hr(tonumber(hr), "ngc_unprotect/UnprotectSecret")
    if desc[0] ~= nil then C.NCryptCloseProtectionDescriptor(desc[0]) end
    local result = ffi.string(out_ptr[0], tonumber(out_len[0]))
    C.LocalFree(out_ptr[0])
    return result
end

-- ===== round-trip self-test =============================================
-- Encrypts a payload and decrypts it back; verifies byte-for-byte equality.
-- Returns (true) on success or (false, err) on any failure path.
function M.round_trip(data, opts)
    data = data or "dpapi round-trip canary :: 0xDEADBEEF"
    opts = opts or {}
    local ok, blob = pcall(M.protect, data, opts)
    if not ok then return false, "protect failed: " .. tostring(blob) end
    if type(blob) ~= "string" or #blob == 0 then
        return false, "protect returned empty blob"
    end
    local unprot_opts = {
        scope        = opts.scope,
        entropy      = opts.entropy,
        prompt_flags = opts.prompt_flags,
        want_description = true,
    }
    local ok2, recovered, desc = pcall(M.unprotect, blob, unprot_opts)
    if not ok2 then return false, "unprotect failed: " .. tostring(recovered) end
    if recovered ~= data then
        return false, string.format("mismatch: in=%d bytes, out=%d bytes",
            #data, #recovered)
    end
    if opts.description and desc ~= opts.description then
        return false, "description mismatch: in='" .. tostring(opts.description)
            .. "' out='" .. tostring(desc) .. "'"
    end
    return true
end

return M
