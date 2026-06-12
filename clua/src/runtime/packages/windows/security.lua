-- windows.security -- tokens, privileges, impersonation (advapi32 extras).
local W = require "windows"

ffi.cdef[[
BOOL    OpenProcessToken(HANDLE, DWORD, HANDLE *);
BOOL    OpenThreadToken(HANDLE, DWORD, BOOL, HANDLE *);
BOOL    GetTokenInformation(HANDLE, ULONG, PVOID, DWORD, DWORD *);
BOOL    DuplicateTokenEx(HANDLE, DWORD, void *, ULONG, ULONG, HANDLE *);
BOOL    AdjustTokenPrivileges(HANDLE, BOOL, void *, DWORD, void *, DWORD *);
BOOL    LookupPrivilegeValueA(LPCSTR, LPCSTR, LONGLONG *);
BOOL    LookupPrivilegeValueW(LPCWSTR, LPCWSTR, LONGLONG *);
BOOL    ImpersonateLoggedOnUser(HANDLE);
BOOL    RevertToSelf(void);
BOOL    CreateProcessWithTokenW(HANDLE, DWORD, LPCWSTR, LPWSTR, DWORD,
                                LPVOID, LPCWSTR, void *, void *);
BOOL    LogonUserA(LPCSTR, LPCSTR, LPCSTR, DWORD, DWORD, HANDLE *);
BOOL    LogonUserW(LPCWSTR, LPCWSTR, LPCWSTR, DWORD, DWORD, HANDLE *);

/* Legacy CryptoAPI random (bcrypt preferred -- see windows.bcrypt) */
typedef ULONGLONG HCRYPTPROV;
BOOL    CryptAcquireContextA(HCRYPTPROV *, LPCSTR, LPCSTR, DWORD, DWORD);
BOOL    CryptReleaseContext(HCRYPTPROV, DWORD);
BOOL    CryptGenRandom(HCRYPTPROV, DWORD, BYTE *);
]]

return {
    -- Token access rights
    TOKEN_QUERY              = 0x0008,
    TOKEN_ADJUST_PRIVILEGES  = 0x0020,
    TOKEN_DUPLICATE          = 0x0002,
    TOKEN_ALL_ACCESS         = 0xF01FF,
    TOKEN_ASSIGN_PRIMARY     = 0x0001,
    TOKEN_IMPERSONATE        = 0x0004,
    -- Privilege attribute bits (for LUID_AND_ATTRIBUTES)
    SE_PRIVILEGE_ENABLED            = 0x00000002,
    SE_PRIVILEGE_ENABLED_BY_DEFAULT = 0x00000001,
    SE_PRIVILEGE_REMOVED            = 0x00000004,
    -- LogonUser logon types
    LOGON32_LOGON_INTERACTIVE       = 2,
    LOGON32_LOGON_NETWORK           = 3,
    LOGON32_LOGON_BATCH             = 4,
    LOGON32_LOGON_SERVICE           = 5,
    LOGON32_LOGON_NEW_CREDENTIALS   = 9,
    -- Logon providers
    LOGON32_PROVIDER_DEFAULT        = 0,
    LOGON32_PROVIDER_WINNT50        = 3,
    -- Token information classes (commonly used)
    TokenUser                 = 1,
    TokenGroups               = 2,
    TokenPrivileges           = 3,
    TokenElevation            = 20,
    TokenIntegrityLevel       = 25,
    -- Provider types (legacy CryptoAPI)
    PROV_RSA_FULL             = 1,
    PROV_RSA_AES              = 24,
    CRYPT_VERIFYCONTEXT       = 0xF0000000,
    CRYPT_SILENT              = 0x00000040,
}
