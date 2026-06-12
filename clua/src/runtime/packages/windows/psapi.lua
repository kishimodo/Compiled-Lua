-- windows.psapi -- process enumeration (EnumProcesses, GetModuleBaseName, ...).
local W = require "windows"

ffi.cdef[[
BOOL    EnumProcesses(DWORD *, DWORD, DWORD *);
BOOL    EnumProcessModules(HANDLE, HMODULE *, DWORD, DWORD *);
BOOL    EnumProcessModulesEx(HANDLE, HMODULE *, DWORD, DWORD *, DWORD);
DWORD   GetModuleBaseNameA(HANDLE, HMODULE, LPSTR, DWORD);
DWORD   GetModuleBaseNameW(HANDLE, HMODULE, LPWSTR, DWORD);
DWORD   GetModuleFileNameExA(HANDLE, HMODULE, LPSTR, DWORD);
DWORD   GetModuleFileNameExW(HANDLE, HMODULE, LPWSTR, DWORD);
BOOL    GetProcessImageFileNameA(HANDLE, LPSTR, DWORD);
BOOL    GetProcessImageFileNameW(HANDLE, LPWSTR, DWORD);

typedef struct _MODULEINFO {
    LPVOID lpBaseOfDll;
    DWORD  SizeOfImage;
    LPVOID EntryPoint;
} MODULEINFO;
BOOL    GetModuleInformation(HANDLE, HMODULE, MODULEINFO *, DWORD);
]]
pcall(ffi.load, "psapi")

return {
    -- EnumProcessModulesEx filter flags
    LIST_MODULES_DEFAULT = 0,
    LIST_MODULES_32BIT   = 1,
    LIST_MODULES_64BIT   = 2,
    LIST_MODULES_ALL     = 3,
}
