-- windows.toolhelp -- Toolhelp32 snapshot APIs (process/thread/module enumeration).
local W = require "windows"

ffi.cdef[[
HANDLE  CreateToolhelp32Snapshot(DWORD, DWORD);
typedef struct _PROCESSENTRY32W {
    DWORD dwSize;
    DWORD cntUsage;
    DWORD th32ProcessID;
    ULONGLONG th32DefaultHeapID;
    DWORD th32ModuleID;
    DWORD cntThreads;
    DWORD th32ParentProcessID;
    LONG  pcPriClassBase;
    DWORD dwFlags;
    unsigned short szExeFile[260];
} PROCESSENTRY32W;
BOOL    Process32FirstW(HANDLE, PROCESSENTRY32W *);
BOOL    Process32NextW(HANDLE, PROCESSENTRY32W *);

typedef struct _THREADENTRY32 {
    DWORD dwSize;
    DWORD cntUsage;
    DWORD th32ThreadID;
    DWORD th32OwnerProcessID;
    LONG  tpBasePri;
    LONG  tpDeltaPri;
    DWORD dwFlags;
} THREADENTRY32;
BOOL    Thread32First(HANDLE, THREADENTRY32 *);
BOOL    Thread32Next(HANDLE, THREADENTRY32 *);

typedef struct _MODULEENTRY32W {
    DWORD     dwSize;
    DWORD     th32ModuleID;
    DWORD     th32ProcessID;
    DWORD     GlblcntUsage;
    DWORD     ProccntUsage;
    BYTE     *modBaseAddr;
    DWORD     modBaseSize;
    HMODULE   hModule;
    unsigned short szModule[256];
    unsigned short szExePath[260];
} MODULEENTRY32W;
BOOL    Module32FirstW(HANDLE, MODULEENTRY32W *);
BOOL    Module32NextW(HANDLE, MODULEENTRY32W *);
]]

return {
    -- CreateToolhelp32Snapshot flags
    TH32CS_SNAPHEAPLIST = 0x00000001,
    TH32CS_SNAPPROCESS  = 0x00000002,
    TH32CS_SNAPTHREAD   = 0x00000004,
    TH32CS_SNAPMODULE   = 0x00000008,
    TH32CS_SNAPMODULE32 = 0x00000010,
    TH32CS_SNAPALL      = 0x0000001F,
}
