-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- network_info -- adapter / routing / ARP tables.
--
-- Public surface:
--   network_info.adapters()         -> { { name, friendly_name, mac, ips={...},
--                                          gateway, dns_servers={...},
--                                          dhcp_enabled, mtu, link_speed_mbps,
--                                          status, type, dns_suffix }, ... }
--   network_info.interfaces()       -> alias for adapters()
--   network_info.default_gateway()  -> string (IPv4) | nil
--   network_info.dns_servers()      -> { ip, ... }   (union of per-adapter DNS)
--   network_info.routing_table()    -> { { destination, mask, gateway,
--                                          interface, metric, family }, ... }
--   network_info.arp_table()        -> { { ip, mac, interface, state, family }, ... }
--   network_info.hostname()         -> string
--   network_info.domain_name()      -> string | ""
--
-- IP element layout in adapters().ips:
--   { ip = "192.168.1.5", prefix_length = 24, family = "ipv4" }

local W = require "windows"
require "windows.network"

ffi.cdef[[
/* sockaddr family + storage; we only ever read fields we cast to AF-specific
   structures, so a generic 16-byte sa_data + 32-byte slack is enough. */
typedef struct _SOCKADDR_NI {
    unsigned short sa_family;
    char           sa_data[126];
} SOCKADDR_NI;

typedef struct _SOCKET_ADDRESS_NI {
    SOCKADDR_NI *lpSockaddr;
    int          iSockaddrLength;
} SOCKET_ADDRESS_NI;

typedef struct _IP_ADAPTER_UNICAST_ADDRESS_NI IP_ADAPTER_UNICAST_ADDRESS_NI;
typedef struct _IP_ADAPTER_UNICAST_ADDRESS_NI {
    union {
        ULONGLONG Alignment;
        struct {
            ULONG Length;
            DWORD Flags;
        } sub;
    } u;
    IP_ADAPTER_UNICAST_ADDRESS_NI *Next;
    SOCKET_ADDRESS_NI Address;
    int    PrefixOrigin;
    int    SuffixOrigin;
    int    DadState;
    ULONG  ValidLifetime;
    ULONG  PreferredLifetime;
    ULONG  LeaseLifetime;
    BYTE   OnLinkPrefixLength;
} IP_ADAPTER_UNICAST_ADDRESS_NI;

typedef struct _IP_ADAPTER_ADDR_GEN_NI IP_ADAPTER_ADDR_GEN_NI;
typedef struct _IP_ADAPTER_ADDR_GEN_NI {
    ULONGLONG _hdr;
    IP_ADAPTER_ADDR_GEN_NI *Next;
    SOCKET_ADDRESS_NI Address;
} IP_ADAPTER_ADDR_GEN_NI;

typedef struct _IP_ADAPTER_DNS_SERVER_NI IP_ADAPTER_DNS_SERVER_NI;
typedef struct _IP_ADAPTER_DNS_SERVER_NI {
    ULONGLONG _hdr;
    IP_ADAPTER_DNS_SERVER_NI *Next;
    SOCKET_ADDRESS_NI Address;
} IP_ADAPTER_DNS_SERVER_NI;

typedef struct _IP_ADAPTER_PREFIX_NI IP_ADAPTER_PREFIX_NI;
typedef struct _IP_ADAPTER_PREFIX_NI {
    ULONGLONG _hdr;
    IP_ADAPTER_PREFIX_NI *Next;
    SOCKET_ADDRESS_NI Address;
    ULONG PrefixLength;
} IP_ADAPTER_PREFIX_NI;

typedef struct _IP_ADAPTER_GATEWAY_NI IP_ADAPTER_GATEWAY_NI;
typedef struct _IP_ADAPTER_GATEWAY_NI {
    ULONGLONG _hdr;
    IP_ADAPTER_GATEWAY_NI *Next;
    SOCKET_ADDRESS_NI Address;
} IP_ADAPTER_GATEWAY_NI;

/* IP_ADAPTER_ADDRESSES (Vista+). Fields beyond what we read are kept as a
   payload-sized char tail so total size matches the system layout. */
typedef struct _IP_ADAPTER_ADDRESSES_NI IP_ADAPTER_ADDRESSES_NI;
typedef struct _IP_ADAPTER_ADDRESSES_NI {
    union {
        ULONGLONG Alignment;
        struct { ULONG Length; DWORD IfIndex; } sub;
    } u;
    IP_ADAPTER_ADDRESSES_NI *Next;
    char    *AdapterName;
    IP_ADAPTER_UNICAST_ADDRESS_NI *FirstUnicastAddress;
    IP_ADAPTER_ADDR_GEN_NI *FirstAnycastAddress;
    IP_ADAPTER_ADDR_GEN_NI *FirstMulticastAddress;
    IP_ADAPTER_DNS_SERVER_NI *FirstDnsServerAddress;
    LPCWSTR  DnsSuffix;
    LPCWSTR  Description;
    LPCWSTR  FriendlyName;
    BYTE     PhysicalAddress[8];
    DWORD    PhysicalAddressLength;
    DWORD    Flags;
    DWORD    Mtu;
    DWORD    IfType;
    DWORD    OperStatus;
    DWORD    Ipv6IfIndex;
    DWORD    ZoneIndices[16];
    IP_ADAPTER_PREFIX_NI *FirstPrefix;
    ULONGLONG TransmitLinkSpeed;
    ULONGLONG ReceiveLinkSpeed;
    void    *FirstWinsServerAddress;
    IP_ADAPTER_GATEWAY_NI *FirstGatewayAddress;
    /* Conservative tail to absorb post-Vista additions (Ipv4Metric,
       Ipv6Metric, Luid, Dhcpv4/6 server, NetworkGuid, ...). 256 bytes
       comfortably covers every Windows 10/11 build. */
    char    _tail[256];
} IP_ADAPTER_ADDRESSES_NI;

DWORD GetAdaptersAddresses(ULONG Family, ULONG Flags, PVOID Reserved,
    IP_ADAPTER_ADDRESSES_NI *AdapterAddresses, ULONG *SizePointer);

BOOL GetComputerNameExW(int NameType, LPWSTR lpBuffer, DWORD *nSize);

/* Routing table (Vista+).
   SOCKADDR_INET is a union of SOCKADDR_IN / SOCKADDR_IN6; its largest arm
   (IN6) carries ULONG fields, so the real type is 28 bytes with 4-byte
   alignment. Modelling it as { u16; char[26] } gives only 2-byte alignment,
   which shrinks IP_ADDRESS_PREFIX from 32 to 30 bytes and so mis-sizes every
   struct that embeds it -- the routing-row stride drifts and Table[i>=1]
   decodes garbage (bug NET-ROUTE-002). The members below reproduce the IN6
   byte layout (family@0, addr@4 for IPv4 / @8 for IPv6) and force size 28 /
   align 4 to match the platform ABI exactly. */
typedef struct _SOCKADDR_INET_NI {
    unsigned short si_family;    /* offset 0  (sa_family)                    */
    unsigned short si_port;      /* offset 2  (IPv4 addr begins at offset 4) */
    unsigned long  si_flowinfo;  /* offset 4  -- forces 4-byte alignment     */
    unsigned char  si_addr[16];  /* offset 8  (IPv6 addr lives here)         */
    unsigned long  si_scope;     /* offset 24                                */
} SOCKADDR_INET_NI;              /* size 28, align 4                          */

typedef struct _IP_ADDRESS_PREFIX_NI {
    SOCKADDR_INET_NI Prefix;
    BYTE             PrefixLength;
} IP_ADDRESS_PREFIX_NI;

typedef struct _MIB_IPFORWARD_ROW2_NI {
    ULONGLONG InterfaceLuid;
    ULONG     InterfaceIndex;
    IP_ADDRESS_PREFIX_NI DestinationPrefix;
    SOCKADDR_INET_NI NextHop;
    BYTE      SitePrefixLength;
    ULONG     ValidLifetime;
    ULONG     PreferredLifetime;
    ULONG     Metric;
    ULONG     Protocol;
    /* The real fields are BOOLEAN (1 byte each), not BOOL (int, 4 bytes).
       Using BOOL added 12 bytes and pushed Age/Origin past the row, blowing
       the array stride (NET-ROUTE-002). */
    BYTE      Loopback;
    BYTE      AutoconfigureAddress;
    BYTE      Publish;
    BYTE      Immortal;
    ULONG     Age;
    ULONG     Origin;
} MIB_IPFORWARD_ROW2_NI;

typedef struct _MIB_IPFORWARD_TABLE2_NI {
    ULONG NumEntries;
    MIB_IPFORWARD_ROW2_NI Table[1];
} MIB_IPFORWARD_TABLE2_NI;

DWORD GetIpForwardTable2(unsigned short Family, MIB_IPFORWARD_TABLE2_NI **Table);
void  FreeMibTable(void *Memory);

/* Neighbor / ARP cache. */
typedef struct _MIB_IPNET_ROW2_NI {
    SOCKADDR_INET_NI Address;
    ULONG     InterfaceIndex;
    ULONGLONG InterfaceLuid;
    BYTE      PhysicalAddress[32];
    ULONG     PhysicalAddressLength;
    ULONG     State;
    union {
        ULONG Flags;
        struct {
            unsigned char IsRouter;
            unsigned char IsUnreachable;
        } sub;
    } u;
    ULONG     ReachabilityTime;
} MIB_IPNET_ROW2_NI;

typedef struct _MIB_IPNET_TABLE2_NI {
    ULONG NumEntries;
    MIB_IPNET_ROW2_NI Table[1];
} MIB_IPNET_TABLE2_NI;

DWORD GetIpNetTable2(unsigned short Family, MIB_IPNET_TABLE2_NI **Table);

int  WSAStartup(WORD wVersionRequested, void *lpWSAData);
int  WSACleanup(void);
LPSTR inet_ntoa(DWORD in);
const char * inet_ntop(int af, const void *src, char *dst, ULONGLONG size);
]]

local C = ffi.C
local M = {}

-- ===== loaders =============================================================

local iphlp = ffi.load("iphlpapi")
pcall(ffi.load, "ws2_32")
local ws2 = (function() local ok, l = pcall(ffi.load, "ws2_32") if ok then return l end return nil end)()

-- Make sure WSAStartup has been called once; many of the address helpers
-- (inet_ntop) won't work otherwise.
local function ws_startup_once()
    local wsadata = ffi.new("char[512]")
    if ws2 then pcall(function() ws2.WSAStartup(0x0202, wsadata) end) end
end
ws_startup_once()

-- ===== AF / status / type tables ==========================================

local AF_INET   = 2
local AF_INET6  = 23

local OPER_STATUS = {
    [1] = "up", [2] = "down", [3] = "testing",
    [4] = "unknown", [5] = "dormant", [6] = "not_present",
    [7] = "lower_layer_down",
}

local IF_TYPE = {
    [1]  = "other",     [6]  = "ethernet",  [9]  = "tokenring",
    [23] = "ppp",       [24] = "loopback",  [37] = "atm",
    [71] = "wireless",  [131]= "tunnel",    [144]= "ieee1394",
}

-- ===== address formatting =================================================

local function sockaddr_to_string(saptr, len)
    if saptr == nil then return nil end
    local fam = saptr.sa_family
    if fam == AF_INET then
        -- bytes 2..5 are the IPv4 address (in network order = MSB-first).
        local p = ffi.cast("unsigned char *", saptr) + 4
        return string.format("%d.%d.%d.%d", p[0], p[1], p[2], p[3])
    elseif fam == AF_INET6 then
        local p = ffi.cast("unsigned char *", saptr) + 8
        -- Build a colon-separated hex string. ::-collapse is convenient
        -- but not strictly necessary; we emit the full form for clarity.
        local parts = {}
        for i = 0, 7 do
            parts[#parts + 1] = string.format("%x", p[i * 2] * 256 + p[i * 2 + 1])
        end
        return table.concat(parts, ":")
    end
    return nil
end

local function sockaddr_inet_to_string(siptr)
    -- SOCKADDR_INET layout: first 2 bytes family; payload starts at the
    -- offset documented by sockaddr_in / sockaddr_in6. We re-use the same
    -- byte-walk approach since we built SOCKADDR_NI to mirror that layout.
    return sockaddr_to_string(ffi.cast("SOCKADDR_NI *", siptr), 0)
end

local function mac_to_string(bytes, len)
    if len == 0 then return nil end
    local parts = {}
    for i = 0, tonumber(len) - 1 do
        parts[#parts + 1] = string.format("%02X", bytes[i])
    end
    return table.concat(parts, ":")
end

-- ===== adapters() =========================================================

local GAA_FLAG_INCLUDE_GATEWAYS     = 0x0080
local GAA_FLAG_INCLUDE_PREFIX       = 0x0010
local GAA_FLAG_SKIP_ANYCAST         = 0x0002
local GAA_FLAG_SKIP_MULTICAST       = 0x0004
local IF_FLAG_DHCP_ENABLED          = 0x0004

local function query_adapters()
    local size = ffi.new("ULONG[1]", 32 * 1024)
    local buf  = ffi.new("char[?]", size[0])
    local flags = bit.bor(GAA_FLAG_INCLUDE_GATEWAYS,
        GAA_FLAG_INCLUDE_PREFIX,
        GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_MULTICAST)
    local r = iphlp.GetAdaptersAddresses(0, flags, nil,
        ffi.cast("IP_ADAPTER_ADDRESSES_NI *", buf), size)
    if r == 0 then return buf end
    -- ERROR_BUFFER_OVERFLOW = 111
    if r == 111 then
        buf = ffi.new("char[?]", size[0])
        r = iphlp.GetAdaptersAddresses(0, flags, nil,
            ffi.cast("IP_ADAPTER_ADDRESSES_NI *", buf), size)
        if r == 0 then return buf end
    end
    return nil
end

local function lpcwstr(p)
    if p == nil then return "" end
    return W.FromWide(ffi.cast("unsigned short *", p))
end

function M.adapters()
    local buf = query_adapters()
    if not buf then return {} end
    local out = {}
    local a = ffi.cast("IP_ADAPTER_ADDRESSES_NI *", buf)
    while a ~= nil do
        local ips = {}
        local u = a.FirstUnicastAddress
        while u ~= nil do
            local s = sockaddr_to_string(u.Address.lpSockaddr, u.Address.iSockaddrLength)
            if s then
                local fam = u.Address.lpSockaddr.sa_family
                ips[#ips + 1] = {
                    ip            = s,
                    prefix_length = tonumber(u.OnLinkPrefixLength),
                    family        = (fam == AF_INET) and "ipv4" or "ipv6",
                }
            end
            u = u.Next
        end

        local dns = {}
        local d = a.FirstDnsServerAddress
        while d ~= nil do
            local s = sockaddr_to_string(d.Address.lpSockaddr, d.Address.iSockaddrLength)
            if s then dns[#dns + 1] = s end
            d = d.Next
        end

        local gateway
        local g = a.FirstGatewayAddress
        if g ~= nil then
            gateway = sockaddr_to_string(g.Address.lpSockaddr, g.Address.iSockaddrLength)
        end

        local mac = mac_to_string(a.PhysicalAddress, a.PhysicalAddressLength)
        local oper = OPER_STATUS[tonumber(a.OperStatus)] or "unknown"
        local iftype = IF_TYPE[tonumber(a.IfType)] or "other"
        local dhcp_on = bit.band(tonumber(a.Flags), IF_FLAG_DHCP_ENABLED) ~= 0

        out[#out + 1] = {
            name           = a.AdapterName ~= nil and ffi.string(a.AdapterName) or "",
            friendly_name  = lpcwstr(a.FriendlyName),
            description    = lpcwstr(a.Description),
            dns_suffix     = lpcwstr(a.DnsSuffix),
            mac            = mac,
            ips            = ips,
            gateway        = gateway,
            dns_servers    = dns,
            dhcp_enabled   = dhcp_on,
            mtu            = tonumber(a.Mtu),
            link_speed_mbps = math.floor(tonumber(a.TransmitLinkSpeed) / 1e6),
            status         = oper,
            type           = iftype,
            if_index       = tonumber(a.u.sub.IfIndex),
        }
        a = a.Next
    end
    return out
end

M.interfaces = M.adapters

function M.default_gateway()
    for _, a in ipairs(M.adapters()) do
        if a.status == "up" and a.gateway and not a.gateway:find(":") then
            return a.gateway
        end
    end
    for _, a in ipairs(M.adapters()) do
        if a.gateway then return a.gateway end
    end
    return nil
end

function M.dns_servers()
    local out, seen = {}, {}
    for _, a in ipairs(M.adapters()) do
        for _, d in ipairs(a.dns_servers) do
            if not seen[d] then
                seen[d] = true
                out[#out + 1] = d
            end
        end
    end
    return out
end

-- ===== routing_table() ====================================================

local function ipv4_prefix_to_mask(prefix_length)
    if prefix_length == 0 then return "0.0.0.0" end
    if prefix_length >= 32 then return "255.255.255.255" end
    local mask = 0xFFFFFFFF - (2 ^ (32 - prefix_length) - 1)
    return string.format("%d.%d.%d.%d",
        math.floor(mask / 0x1000000) % 256,
        math.floor(mask / 0x10000) % 256,
        math.floor(mask / 0x100) % 256,
        mask % 256)
end

local function format_route_table(family)
    local tab = ffi.new("MIB_IPFORWARD_TABLE2_NI *[1]")
    if iphlp.GetIpForwardTable2(family, tab) ~= 0 then return {} end
    local out = {}
    local n = tonumber(tab[0].NumEntries)
    for i = 0, n - 1 do
        local r = tab[0].Table[i]
        local dest = sockaddr_inet_to_string(r.DestinationPrefix.Prefix)
        local gw   = sockaddr_inet_to_string(r.NextHop)
        local fam  = (family == AF_INET) and "ipv4" or "ipv6"
        local mask = (fam == "ipv4") and ipv4_prefix_to_mask(tonumber(r.DestinationPrefix.PrefixLength)) or nil
        out[#out + 1] = {
            destination = dest,
            prefix_length = tonumber(r.DestinationPrefix.PrefixLength),
            mask        = mask,
            gateway     = gw,
            interface   = tonumber(r.InterfaceIndex),
            metric      = tonumber(r.Metric),
            family      = fam,
        }
    end
    iphlp.FreeMibTable(tab[0])
    return out
end

function M.routing_table()
    local v4 = format_route_table(AF_INET)
    local v6 = format_route_table(AF_INET6)
    for _, r in ipairs(v6) do v4[#v4 + 1] = r end
    return v4
end

-- ===== arp_table() ========================================================

local NEIGHBOR_STATE = {
    [0] = "unreachable", [1] = "incomplete", [2] = "probe",
    [3] = "delay", [4] = "stale", [5] = "reachable", [6] = "permanent",
}

local function format_neigh_table(family)
    local tab = ffi.new("MIB_IPNET_TABLE2_NI *[1]")
    if iphlp.GetIpNetTable2(family, tab) ~= 0 then return {} end
    local out = {}
    local n = tonumber(tab[0].NumEntries)
    for i = 0, n - 1 do
        local r = tab[0].Table[i]
        local ip = sockaddr_inet_to_string(r.Address)
        local mac = mac_to_string(r.PhysicalAddress, r.PhysicalAddressLength)
        out[#out + 1] = {
            ip        = ip,
            mac       = mac,
            interface = tonumber(r.InterfaceIndex),
            state     = NEIGHBOR_STATE[tonumber(r.State)] or "unknown",
            family    = (family == AF_INET) and "ipv4" or "ipv6",
        }
    end
    iphlp.FreeMibTable(tab[0])
    return out
end

function M.arp_table()
    local v4 = format_neigh_table(AF_INET)
    local v6 = format_neigh_table(AF_INET6)
    for _, r in ipairs(v6) do v4[#v4 + 1] = r end
    return v4
end

-- ===== hostname / domain ==================================================

local function computer_name_ex(t)
    local sz = ffi.new("DWORD[1]", 256)
    local buf = ffi.new("unsigned short[256]")
    if C.GetComputerNameExW(t, buf, sz) == 0 then return "" end
    return W.FromWide(buf)
end

function M.hostname()
    return computer_name_ex(1)  -- ComputerNameDnsHostname
end

function M.domain_name()
    return computer_name_ex(2)  -- ComputerNameDnsDomain
end

return M
