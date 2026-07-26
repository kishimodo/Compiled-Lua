-- CLua bundled Windows API cdefs.
-- Provides ffi.cdef'd APIs from kernel32, user32, advapi32, ntdll, msvcrt,
-- plus the most-used struct typedefs and named constants.
-- Usage:
--   local W = require "windows"
--   local h = ffi.C.OpenProcess(W.PROCESS_ALL_ACCESS, false, 1234)

ffi.cdef[[

/* ===== Primitive typedefs ===== */
typedef int                 BOOL;
typedef unsigned char       BYTE;
typedef unsigned short      WORD;
typedef unsigned long       DWORD;
typedef unsigned long       ULONG;
typedef long                LONG;
typedef long long           LONGLONG;
typedef unsigned long long  ULONGLONG;
typedef void               *HANDLE;
typedef void               *HMODULE;
typedef void               *HINSTANCE;
typedef void               *HWND;
typedef void               *HKEY;
typedef void               *PVOID;
typedef void               *LPVOID;
typedef const void         *LPCVOID;
typedef char               *LPSTR;
typedef const char         *LPCSTR;
typedef unsigned short     *LPWSTR;
typedef const unsigned short *LPCWSTR;
typedef unsigned long      *LPDWORD;
typedef unsigned int        UINT;
typedef long                NTSTATUS;
typedef long                HRESULT;
typedef long                SCODE;
typedef int                 VARIANT_BOOL;
typedef int                 INT;
typedef unsigned long long  UINT_PTR;
typedef short               SHORT;
typedef unsigned short      USHORT;
typedef long                LSTATUS;
typedef void              (*FARPROC)(void);

/* ===== Common structs ===== */
typedef struct _FILETIME {
    DWORD dwLowDateTime;
    DWORD dwHighDateTime;
} FILETIME;

typedef struct _SYSTEMTIME {
    WORD wYear;
    WORD wMonth;
    WORD wDayOfWeek;
    WORD wDay;
    WORD wHour;
    WORD wMinute;
    WORD wSecond;
    WORD wMilliseconds;
} SYSTEMTIME;

typedef struct _OVERLAPPED {
    ULONGLONG  Internal;
    ULONGLONG  InternalHigh;
    ULONGLONG  Offset;
    HANDLE     hEvent;
} OVERLAPPED;

typedef struct _SECURITY_ATTRIBUTES {
    DWORD  nLength;
    LPVOID lpSecurityDescriptor;
    BOOL   bInheritHandle;
} SECURITY_ATTRIBUTES;

typedef struct _STARTUPINFOW {
    DWORD  cb;
    LPWSTR lpReserved;
    LPWSTR lpDesktop;
    LPWSTR lpTitle;
    DWORD  dwX;
    DWORD  dwY;
    DWORD  dwXSize;
    DWORD  dwYSize;
    DWORD  dwXCountChars;
    DWORD  dwYCountChars;
    DWORD  dwFillAttribute;
    DWORD  dwFlags;
    WORD   wShowWindow;
    WORD   cbReserved2;
    LPVOID lpReserved2;
    HANDLE hStdInput;
    HANDLE hStdOutput;
    HANDLE hStdError;
} STARTUPINFOW;

typedef struct _STARTUPINFOA {
    DWORD  cb;
    LPSTR  lpReserved;
    LPSTR  lpDesktop;
    LPSTR  lpTitle;
    DWORD  dwX;
    DWORD  dwY;
    DWORD  dwXSize;
    DWORD  dwYSize;
    DWORD  dwXCountChars;
    DWORD  dwYCountChars;
    DWORD  dwFillAttribute;
    DWORD  dwFlags;
    WORD   wShowWindow;
    WORD   cbReserved2;
    LPVOID lpReserved2;
    HANDLE hStdInput;
    HANDLE hStdOutput;
    HANDLE hStdError;
} STARTUPINFOA;

typedef struct _PROCESS_INFORMATION {
    HANDLE hProcess;
    HANDLE hThread;
    DWORD  dwProcessId;
    DWORD  dwThreadId;
} PROCESS_INFORMATION;

typedef struct _MEMORY_BASIC_INFORMATION {
    PVOID  BaseAddress;
    PVOID  AllocationBase;
    DWORD  AllocationProtect;
    WORD   PartitionId;
    WORD   _Pad0;
    ULONGLONG RegionSize;
    DWORD  State;
    DWORD  Protect;
    DWORD  Type;
    DWORD  _Pad1;
} MEMORY_BASIC_INFORMATION;

typedef struct _POINT {
    LONG x;
    LONG y;
} POINT;

typedef struct _RECT {
    LONG left;
    LONG top;
    LONG right;
    LONG bottom;
} RECT;

typedef struct _MSG {
    HWND      hwnd;
    UINT      message;
    ULONGLONG wParam;
    LONGLONG  lParam;
    DWORD     time;
    POINT     pt;
    DWORD     lPrivate;
} MSG;

/* ===== kernel32 ===== */
BOOL    CreateProcessW(LPCWSTR, LPWSTR, SECURITY_ATTRIBUTES *,
                       SECURITY_ATTRIBUTES *, BOOL, DWORD, LPVOID,
                       LPCWSTR, STARTUPINFOW *, PROCESS_INFORMATION *);
BOOL    CreateProcessA(LPCSTR, LPSTR, SECURITY_ATTRIBUTES *,
                       SECURITY_ATTRIBUTES *, BOOL, DWORD, LPVOID,
                       LPCSTR, STARTUPINFOA *, PROCESS_INFORMATION *);
HANDLE  CreateFileW(LPCWSTR, DWORD, DWORD, SECURITY_ATTRIBUTES *,
                    DWORD, DWORD, HANDLE);
HANDLE  CreateFileA(LPCSTR, DWORD, DWORD, SECURITY_ATTRIBUTES *,
                    DWORD, DWORD, HANDLE);
BOOL    ReadFile(HANDLE, LPVOID, DWORD, LPDWORD, OVERLAPPED *);
BOOL    WriteFile(HANDLE, LPCVOID, DWORD, LPDWORD, OVERLAPPED *);
BOOL    CloseHandle(HANDLE);
HANDLE  GetCurrentProcess(void);
HANDLE  GetCurrentThread(void);
DWORD   GetCurrentProcessId(void);
DWORD   GetCurrentThreadId(void);
HANDLE  OpenProcess(DWORD, BOOL, DWORD);
LPVOID  VirtualAlloc(LPVOID, ULONGLONG, DWORD, DWORD);
BOOL    VirtualFree(LPVOID, ULONGLONG, DWORD);
BOOL    VirtualProtect(LPVOID, ULONGLONG, DWORD, LPDWORD);
ULONGLONG VirtualQuery(LPCVOID, MEMORY_BASIC_INFORMATION *, ULONGLONG);
HMODULE LoadLibraryW(LPCWSTR);
HMODULE LoadLibraryA(LPCSTR);
HMODULE GetModuleHandleW(LPCWSTR);
HMODULE GetModuleHandleA(LPCSTR);
FARPROC GetProcAddress(HMODULE, LPCSTR);
BOOL    FreeLibrary(HMODULE);
void    Sleep(DWORD);
DWORD   WaitForSingleObject(HANDLE, DWORD);
DWORD   WaitForMultipleObjects(DWORD, const HANDLE *, BOOL, DWORD);
BOOL    GetExitCodeProcess(HANDLE, LPDWORD);
BOOL    TerminateProcess(HANDLE, UINT);
DWORD   GetLastError(void);
void    SetLastError(DWORD);
void    ExitProcess(UINT);
DWORD   GetTickCount(void);
ULONGLONG GetTickCount64(void);
void    GetSystemTime(SYSTEMTIME *);
void    GetLocalTime(SYSTEMTIME *);
BOOL    QueryPerformanceCounter(LONGLONG *);
BOOL    QueryPerformanceFrequency(LONGLONG *);
DWORD   GetEnvironmentVariableW(LPCWSTR, LPWSTR, DWORD);
DWORD   GetEnvironmentVariableA(LPCSTR, LPSTR, DWORD);
LPWSTR  GetCommandLineW(void);
LPSTR   GetCommandLineA(void);
DWORD   GetCurrentDirectoryW(DWORD, LPWSTR);
DWORD   GetCurrentDirectoryA(DWORD, LPSTR);
BOOL    SetCurrentDirectoryW(LPCWSTR);
DWORD   GetTempPathW(DWORD, LPWSTR);
int     MultiByteToWideChar(UINT, DWORD, LPCSTR, int, LPWSTR, int);
int     WideCharToMultiByte(UINT, DWORD, LPCWSTR, int, LPSTR, int, LPCSTR, BOOL *);
HANDLE  CreateThread(SECURITY_ATTRIBUTES *, ULONGLONG, LPVOID, LPVOID, DWORD, LPDWORD);
HANDLE  CreateMutexW(SECURITY_ATTRIBUTES *, BOOL, LPCWSTR);
BOOL    ReleaseMutex(HANDLE);
HANDLE  CreateEventW(SECURITY_ATTRIBUTES *, BOOL, BOOL, LPCWSTR);
BOOL    SetEvent(HANDLE);
BOOL    ResetEvent(HANDLE);

/* ===== user32 ===== */
int     MessageBoxW(HWND, LPCWSTR, LPCWSTR, UINT);
int     MessageBoxA(HWND, LPCSTR, LPCSTR, UINT);
HWND    FindWindowW(LPCWSTR, LPCWSTR);
HWND    FindWindowA(LPCSTR, LPCSTR);
HWND    GetForegroundWindow(void);
BOOL    SetForegroundWindow(HWND);
BOOL    ShowWindow(HWND, int);
int     GetWindowTextW(HWND, LPWSTR, int);
int     GetWindowTextA(HWND, LPSTR, int);
BOOL    GetCursorPos(POINT *);
BOOL    SetCursorPos(int, int);
BOOL    GetWindowRect(HWND, RECT *);

/* ===== advapi32 ===== */
LSTATUS RegOpenKeyExW(HKEY, LPCWSTR, DWORD, DWORD, HKEY *);
LSTATUS RegOpenKeyExA(HKEY, LPCSTR, DWORD, DWORD, HKEY *);
LSTATUS RegQueryValueExW(HKEY, LPCWSTR, LPDWORD, LPDWORD, BYTE *, LPDWORD);
LSTATUS RegQueryValueExA(HKEY, LPCSTR, LPDWORD, LPDWORD, BYTE *, LPDWORD);
LSTATUS RegCloseKey(HKEY);
LSTATUS RegEnumKeyExW(HKEY, DWORD, LPWSTR, LPDWORD, LPDWORD, LPWSTR, LPDWORD, FILETIME *);
BOOL    OpenProcessToken(HANDLE, DWORD, HANDLE *);
BOOL    LookupPrivilegeValueW(LPCWSTR, LPCWSTR, LONGLONG *);

/* ===== ntdll ===== */
NTSTATUS NtQuerySystemInformation(DWORD, PVOID, ULONG, ULONG *);
NTSTATUS NtCreateThreadEx(HANDLE *, DWORD, PVOID, HANDLE, PVOID, PVOID,
                          DWORD, ULONGLONG, ULONGLONG, ULONGLONG, PVOID);
PVOID    RtlAddVectoredExceptionHandler(ULONG, PVOID);
ULONG    RtlRemoveVectoredExceptionHandler(PVOID);
void     RtlZeroMemory(PVOID, ULONGLONG);
void     RtlCopyMemory(PVOID, const void *, ULONGLONG);

/* ===== msvcrt (numeric helpers) ===== */
/* NOTE: printf(const char *, ...) is intentionally omitted from the bundle.
 * The cdef parser accepts C variadic '...' parameters, but the FFI runtime
 * explicitly rejects calls through a variadic signature. Use Lua's built-in
 * print() / string.format() instead. */
double   pow(double, double);
double   sqrt(double);
double   sin(double);
double   cos(double);
double   fabs(double);
void    *malloc(ULONGLONG);
void     free(void *);
void    *memcpy(void *, const void *, ULONGLONG);
int      memcmp(const void *, const void *, ULONGLONG);
ULONGLONG strlen(const char *);

/* Extended surfaces (psapi, ntdll Nt*, bcrypt, ole32/oleaut32, shell32,
   iphlpapi, winhttp, dbghelp, security, toolhelp) now live in
   per-area sub-packages under packages/windows/<area>.lua. Require
   them explicitly when you need that area:

     local crypto    = require "windows.bcrypt"
     local com       = require "windows.com"
     local netadapt  = require "windows.network"
     local nt        = require "windows.ntdll"
     local toolhelp  = require "windows.toolhelp"
     local sec       = require "windows.security"
     local dbg       = require "windows.dbghelp"
     local enum      = require "windows.psapi"
     local shell     = require "windows.shell"

   See docs/packages.md for the full inventory + rationale (tree-
   shaking: pay for what you require, not for what the package could
   theoretically expose). */

/* (extended cdefs deleted -- see sub-packages listed above) */
]]

ffi.load("kernel32")
ffi.load("user32")
ffi.load("advapi32")
ffi.load("ntdll")
ffi.load("msvcrt")

local M = {}

M.VERSION = "m13-v1"

-- ===== HANDLEs / sentinels =====
M.INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)
M.NULL_HANDLE          = ffi.cast("HANDLE", 0)
M.NULL                 = ffi.cast("LPVOID", 0)

-- ===== HKEY predefined roots =====
M.HKEY_CLASSES_ROOT     = ffi.cast("HKEY", 0x80000000)
M.HKEY_CURRENT_USER     = ffi.cast("HKEY", 0x80000001)
M.HKEY_LOCAL_MACHINE    = ffi.cast("HKEY", 0x80000002)
M.HKEY_USERS            = ffi.cast("HKEY", 0x80000003)
M.HKEY_CURRENT_CONFIG   = ffi.cast("HKEY", 0x80000005)

-- ===== Access rights =====
M.GENERIC_READ    = 0x80000000
M.GENERIC_WRITE   = 0x40000000
M.GENERIC_EXECUTE = 0x20000000
M.GENERIC_ALL     = 0x10000000

M.PROCESS_TERMINATE         = 0x0001
M.PROCESS_CREATE_THREAD     = 0x0002
M.PROCESS_VM_OPERATION      = 0x0008
M.PROCESS_VM_READ           = 0x0010
M.PROCESS_VM_WRITE          = 0x0020
M.PROCESS_DUP_HANDLE        = 0x0040
M.PROCESS_CREATE_PROCESS    = 0x0080
M.PROCESS_QUERY_INFORMATION = 0x0400
M.PROCESS_SUSPEND_RESUME    = 0x0800
M.PROCESS_ALL_ACCESS        = 0x1F0FFF

-- Registry access
M.KEY_QUERY_VALUE        = 0x0001
M.KEY_SET_VALUE          = 0x0002
M.KEY_CREATE_SUB_KEY     = 0x0004
M.KEY_ENUMERATE_SUB_KEYS = 0x0008
M.KEY_NOTIFY             = 0x0010
M.KEY_READ               = 0x20019
M.KEY_WRITE              = 0x20006
M.KEY_ALL_ACCESS         = 0xF003F

-- File / pipe access shares
M.FILE_SHARE_READ   = 0x00000001
M.FILE_SHARE_WRITE  = 0x00000002
M.FILE_SHARE_DELETE = 0x00000004

-- CreateFile dwCreationDisposition
M.CREATE_NEW        = 1
M.CREATE_ALWAYS     = 2
M.OPEN_EXISTING     = 3
M.OPEN_ALWAYS       = 4
M.TRUNCATE_EXISTING = 5

-- CreateFile dwFlagsAndAttributes (subset)
M.FILE_ATTRIBUTE_NORMAL  = 0x00000080
M.FILE_FLAG_OVERLAPPED   = 0x40000000

-- CreateProcess flags
M.CREATE_NEW_CONSOLE        = 0x00000010
M.CREATE_NO_WINDOW          = 0x08000000
M.CREATE_SUSPENDED          = 0x00000004
M.DETACHED_PROCESS          = 0x00000008

-- VirtualAlloc / VirtualFree
M.MEM_COMMIT      = 0x00001000
M.MEM_RESERVE     = 0x00002000
M.MEM_RESET       = 0x00080000
M.MEM_RELEASE     = 0x00008000
M.MEM_DECOMMIT    = 0x00004000

-- PAGE protect flags
M.PAGE_NOACCESS          = 0x01
M.PAGE_READONLY          = 0x02
M.PAGE_READWRITE         = 0x04
M.PAGE_WRITECOPY         = 0x08
M.PAGE_EXECUTE           = 0x10
M.PAGE_EXECUTE_READ      = 0x20
M.PAGE_EXECUTE_READWRITE = 0x40

-- WaitForSingleObject
M.INFINITE       = 0xFFFFFFFF
M.WAIT_OBJECT_0  = 0x00000000
M.WAIT_TIMEOUT   = 0x00000102
M.WAIT_ABANDONED = 0x00000080
M.WAIT_FAILED    = 0xFFFFFFFF

-- MessageBox
M.MB_OK               = 0x00000000
M.MB_OKCANCEL         = 0x00000001
M.MB_YESNO            = 0x00000004
M.MB_YESNOCANCEL      = 0x00000003
M.MB_RETRYCANCEL      = 0x00000005
M.MB_ICONERROR        = 0x00000010
M.MB_ICONWARNING      = 0x00000030
M.MB_ICONINFORMATION  = 0x00000040
M.MB_ICONQUESTION     = 0x00000020
M.MB_DEFBUTTON1       = 0x00000000
M.MB_DEFBUTTON2       = 0x00000100

-- MessageBox return codes
M.IDOK     = 1
M.IDCANCEL = 2
M.IDABORT  = 3
M.IDRETRY  = 4
M.IDIGNORE = 5
M.IDYES    = 6
M.IDNO     = 7

-- ShowWindow
M.SW_HIDE       = 0
M.SW_SHOWNORMAL = 1
M.SW_NORMAL     = 1
M.SW_MINIMIZE   = 6
M.SW_MAXIMIZE   = 3
M.SW_RESTORE    = 9
M.SW_SHOW       = 5

-- Code pages
M.CP_ACP       = 0
M.CP_OEMCP     = 1
M.CP_UTF7      = 65000
M.CP_UTF8      = 65001

-- ===== Console (kernel32) =====

M.STD_INPUT_HANDLE  = 0xFFFFFFF6   -- (DWORD)-10
M.STD_OUTPUT_HANDLE = 0xFFFFFFF5   -- (DWORD)-11
M.STD_ERROR_HANDLE  = 0xFFFFFFF4   -- (DWORD)-12

M.ENABLE_PROCESSED_INPUT             = 0x0001
M.ENABLE_LINE_INPUT                  = 0x0002
M.ENABLE_ECHO_INPUT                  = 0x0004
M.ENABLE_VIRTUAL_TERMINAL_INPUT      = 0x0200
M.ENABLE_PROCESSED_OUTPUT            = 0x0001
M.ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

-- Larger / domain-specific constant groups live in the sub-packages,
-- mirroring the cdef split:
--   require "windows.com"      -- COINIT_*, CLSCTX_*, VT_*
--   require "windows.security" -- TOKEN_*, SE_PRIVILEGE_*, LOGON32_*
--   require "windows.toolhelp" -- TH32CS_*
--   require "windows.network"  -- WINHTTP_*, MIB_IF_TYPE_*
--   require "windows.shell"    -- CSIDL_*, SW_* (ShellExecute reuse)
--   require "windows.bcrypt"   -- SHA*_ALGORITHM, AES/RSA/RNG algorithm cdata
--   require "windows.ntdll"    -- Process/System InformationClass enums
-- Pay only for what you require.

-- ===== Helpers =====
--
-- m13b-followup: two JIT/FFI rough edges still bite these helpers:
--
--   1. Calling `ffi.C.<sym>(...)` from inside a JIT-compiled function
--      mis-resolves the cdata receiver. M13b Task 2 fixed the
--      pointer-arg marshaling for the fallback path, but not the
--      receiver lookup itself. Workaround: lift the FFI function to
--      a module-scope local so it appears as a plain upvalue.
--
--   2. Sizing-query calls (passing `nil` for the LPWSTR scratch + 0
--      for the count) tickle a marshal-vs-inline-FFI desynchronisation
--      that surfaces as "ffi: cannot convert nil to non-pointer type"
--      when the same proto also drives a CreateProcessW chain. Until
--      that's untangled, we size the scratch buffers conservatively
--      (4 KB / 8 KB) instead of doing a two-call sizing dance.
--
--   3. The OP_EQK string-K JIT codegen path bails on opcode 60 with
--      string constants. So no `type(x) == "string"` checks here and
--      no string-concat in error() messages.

local _MultiByteToWideChar = ffi.C.MultiByteToWideChar
local _WideCharToMultiByte = ffi.C.WideCharToMultiByte

-- Both converters ask the API for the required size, then convert into an
-- exactly sized buffer -- the standard Win32 two-call idiom.
--
-- They previously used fixed 2048-WCHAR / 4096-byte scratch buffers, and note 2
-- above said the sizing call had to be avoided because it desynchronised the
-- marshaller. That note is STALE: it blames "the JIT codegen path", and there is
-- no JIT in this tree any more. The dance was re-tested directly (a 6,000-char
-- round trip through both calls) and works, and `dotnet/init.lua:537-540` has
-- been using the same idiom in production all along.
--
-- The fixed buffers were a real bug, not just a limit: any environment variable,
-- registry value or path longer than the buffer made the conversion return 0,
-- which these functions raise as "conversion failed". It was found because
-- `env.list()` failed under `build\run-tests.bat`, whose PATH is 4,218 bytes --
-- so the `PATH=...` entry overflowed `char[4096]` by 127 bytes. Under a plain
-- shell the same PATH is 4,084 bytes and it passed, which is why this looked
-- environment-dependent rather than broken. Windows allows a single environment
-- variable up to 32,767 characters, so no fixed size would have been correct.
--
-- Exact sizing also allocates LESS than before for the common short string.

-- Convert an ASCII / UTF-8 Lua string to a UTF-16LE buffer (null-terminated).
-- Returns the cdata buffer and its length in WCHARs (including the null).
function M.ToWide(S)
    local Need = _MultiByteToWideChar(M.CP_UTF8, 0, S, -1, nil, 0)
    if Need <= 0 then error("MultiByteToWideChar failed") end
    local Buf = ffi.new("unsigned short[?]", Need)
    local N   = _MultiByteToWideChar(M.CP_UTF8, 0, S, -1, Buf, Need)
    if N <= 0 then error("MultiByteToWideChar failed") end
    return Buf, N
end

-- Convert a UTF-16LE cdata (null-terminated) to a Lua string.
function M.FromWide(Buf)
    local Need = _WideCharToMultiByte(M.CP_UTF8, 0, Buf, -1, nil, 0, nil, nil)
    if Need <= 0 then error("WideCharToMultiByte failed") end
    local Out = ffi.new("char[?]", Need)
    local N   = _WideCharToMultiByte(M.CP_UTF8, 0, Buf, -1, Out, Need, nil, nil)
    if N <= 0 then error("WideCharToMultiByte failed") end
    return ffi.string(Out, N - 1)
end

return M
