-- windows.dbghelp -- stack walks, mini-dumps, symbol resolution.
local W = require "windows"

ffi.cdef[[
typedef struct _SYMBOL_INFO {
    ULONG SizeOfStruct;
    ULONG TypeIndex;
    ULONGLONG Reserved[2];
    ULONG Index;
    ULONG Size;
    ULONGLONG ModBase;
    ULONG Flags;
    ULONGLONG Value;
    ULONGLONG Address;
    ULONG Register;
    ULONG Scope;
    ULONG Tag;
    ULONG NameLen;
    ULONG MaxNameLen;
    char  Name[1];
} SYMBOL_INFO;
BOOL    SymInitialize(HANDLE, LPCSTR, BOOL);
BOOL    SymCleanup(HANDLE);
BOOL    SymFromAddr(HANDLE, ULONGLONG, ULONGLONG *, SYMBOL_INFO *);
BOOL    MiniDumpWriteDump(HANDLE, DWORD, HANDLE, DWORD, void *, void *, void *);
unsigned short RtlCaptureStackBackTrace(DWORD, DWORD, PVOID *, DWORD *);
]]
pcall(ffi.load, "dbghelp")

return {
    -- MiniDumpType flags (subset)
    MiniDumpNormal              = 0x00000000,
    MiniDumpWithDataSegs        = 0x00000001,
    MiniDumpWithFullMemory      = 0x00000002,
    MiniDumpWithHandleData      = 0x00000004,
    MiniDumpWithUnloadedModules = 0x00000020,
    MiniDumpWithThreadInfo      = 0x00001000,
    MiniDumpWithCodeSegs        = 0x00002000,
}
