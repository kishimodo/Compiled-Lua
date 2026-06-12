-- windows.network -- iphlpapi (adapters) + winhttp (HTTPS client).
local W = require "windows"

ffi.cdef[[
typedef struct _IP_ADAPTER_INFO IP_ADAPTER_INFO;
typedef struct _IP_ADAPTER_INFO {
    IP_ADAPTER_INFO *Next;
    DWORD            ComboIndex;
    char             AdapterName[260];
    char             Description[132];
    UINT             AddressLength;
    BYTE             Address[8];
    DWORD            Index;
    UINT             Type;
    UINT             DhcpEnabled;
    PVOID            CurrentIpAddress;
    BYTE             IpAddressList[1024];
    BYTE             GatewayList[256];
    BYTE             DhcpServer[256];
    BOOL             HaveWins;
    BYTE             PrimaryWinsServer[256];
    BYTE             SecondaryWinsServer[256];
    LONGLONG         LeaseObtained;
    LONGLONG         LeaseExpires;
} IP_ADAPTER_INFO;

DWORD   GetAdaptersInfo(IP_ADAPTER_INFO *, ULONG *);
DWORD   GetIpAddrTable(PVOID, ULONG *, BOOL);

/* WinHTTP -- modern HTTPS-capable client (winhttp.dll) */
PVOID   WinHttpOpen(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
PVOID   WinHttpConnect(PVOID, LPCWSTR, int, DWORD);
PVOID   WinHttpOpenRequest(PVOID, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR *, DWORD);
BOOL    WinHttpSendRequest(PVOID, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, ULONGLONG);
BOOL    WinHttpReceiveResponse(PVOID, LPVOID);
BOOL    WinHttpReadData(PVOID, LPVOID, DWORD, LPDWORD);
BOOL    WinHttpQueryDataAvailable(PVOID, LPDWORD);
BOOL    WinHttpCloseHandle(PVOID);
BOOL    WinHttpQueryHeaders(PVOID, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
]]
pcall(ffi.load, "iphlpapi")
pcall(ffi.load, "winhttp")

return {
    -- WinHttpOpen access types
    WINHTTP_ACCESS_TYPE_DEFAULT_PROXY    = 0,
    WINHTTP_ACCESS_TYPE_NO_PROXY         = 1,
    WINHTTP_ACCESS_TYPE_NAMED_PROXY      = 3,
    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY  = 4,
    -- WinHttp request flags
    WINHTTP_FLAG_SECURE             = 0x00800000,
    WINHTTP_FLAG_BYPASS_PROXY_CACHE = 0x00000100,
    -- IP adapter type
    MIB_IF_TYPE_ETHERNET = 6,
    MIB_IF_TYPE_LOOPBACK = 24,
    MIB_IF_TYPE_PPP      = 23,
    MIB_IF_TYPE_OTHER    = 1,
}
