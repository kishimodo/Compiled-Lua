-- windows.ntdll -- comprehensive Nt* and Rt* surface from ntdll.dll.
-- The core windows package only declares the few Rt* helpers needed
-- by VEH; the rest live here so binaries that don't touch ntdll
-- directly don't carry the cdef bloat.
local W = require "windows"

ffi.cdef[[
NTSTATUS NtClose(HANDLE);
NTSTATUS NtQueryInformationProcess(HANDLE, ULONG, PVOID, ULONG, ULONG *);
NTSTATUS NtQueryInformationThread(HANDLE, ULONG, PVOID, ULONG, ULONG *);
NTSTATUS NtQuerySystemInformation(ULONG, PVOID, ULONG, ULONG *);
NTSTATUS NtQueryVirtualMemory(HANDLE, PVOID, ULONG, PVOID, ULONGLONG, ULONGLONG *);
NTSTATUS NtReadVirtualMemory(HANDLE, PVOID, PVOID, ULONGLONG, ULONGLONG *);
NTSTATUS NtWriteVirtualMemory(HANDLE, PVOID, PVOID, ULONGLONG, ULONGLONG *);
NTSTATUS NtProtectVirtualMemory(HANDLE, PVOID *, ULONGLONG *, ULONG, ULONG *);
NTSTATUS NtAllocateVirtualMemory(HANDLE, PVOID *, ULONGLONG, ULONGLONG *, ULONG, ULONG);
NTSTATUS NtFreeVirtualMemory(HANDLE, PVOID *, ULONGLONG *, ULONG);
NTSTATUS NtCreateThreadEx(HANDLE *, ULONG, PVOID, HANDLE, PVOID, PVOID,
                          ULONG, ULONGLONG, ULONGLONG, ULONGLONG, PVOID);
NTSTATUS NtOpenProcess(HANDLE *, ULONG, PVOID, void *);
NTSTATUS NtOpenThread(HANDLE *, ULONG, PVOID, void *);
NTSTATUS NtSuspendProcess(HANDLE);
NTSTATUS NtResumeProcess(HANDLE);
NTSTATUS NtSuspendThread(HANDLE, ULONG *);
NTSTATUS NtResumeThread(HANDLE, ULONG *);
NTSTATUS NtTerminateProcess(HANDLE, NTSTATUS);
NTSTATUS NtDelayExecution(BOOL, LONGLONG *);
NTSTATUS NtQueryObject(HANDLE, ULONG, PVOID, ULONG, ULONG *);
NTSTATUS RtlGetVersion(PVOID);
NTSTATUS RtlAdjustPrivilege(ULONG, BOOL, BOOL, BOOL *);
PVOID    RtlImageNtHeader(PVOID);
ULONG    RtlNtStatusToDosError(NTSTATUS);
PVOID    NtCurrentTeb(void);
]]

return {
    -- ProcessInformationClass values for NtQueryInformationProcess
    ProcessBasicInformation       = 0,
    ProcessDebugPort              = 7,
    ProcessImageFileName          = 27,
    ProcessDebugObjectHandle      = 30,
    ProcessExecuteFlags           = 34,
    -- SystemInformationClass values for NtQuerySystemInformation
    SystemBasicInformation         = 0,
    SystemProcessInformation       = 5,
    SystemModuleInformation        = 11,
    SystemHandleInformation        = 16,
    SystemExtendedHandleInformation = 64,
}
