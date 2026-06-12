-- socket -- high-level TCP/UDP over Winsock2.
--
-- Public surface:
--   socket.tcp.connect(host, port, opts?)      -> conn
--   socket.tcp.listen(host, port, backlog?)    -> server
--   server:accept()                            -> conn
--   conn:read(n?)                              -> string | nil, err
--   conn:read_line(opts?)                      -> string | nil, err  (LF or CRLF terminated; line returned WITHOUT terminator)
--   conn:read_until(delim)                     -> string | nil, err
--   conn:read_exact(n)                         -> string | nil, err  (errors on premature eof)
--   conn:read_frame(opts?)                     -> string | nil, err  (length-prefixed; opts.size=1|2|4|8, opts.endian="be"|"le")
--   conn:write(s)                              -> n  | nil, err
--   conn:write_frame(s, opts?)                 -> n  | nil, err
--   conn:close()
--   conn:set_timeout(ms)
--   conn:set_blocking(yes)
--   conn:peer_addr()                           -> host, port
--   conn:local_addr()                          -> host, port
--   conn:shutdown(how?)                        ("r"|"w"|"rw")
--
--   socket.udp.bind(host, port)                -> udp
--   udp:send_to(data, host, port)              -> n
--   udp:recv_from(maxlen?)                     -> data, host, port
--   udp:close()
--
--   socket.resolve(host)                       -> { "1.2.3.4", "::1", ... }
--
-- Why hand-rolled instead of just using async.tcp:
--   * async's TCP path is event-driven (good for a scheduler but ties
--     callers to coroutines + the event loop). socket presents a plain
--     blocking-style API that the http/tls/redis/etc. packages can use
--     without forcing their users into async-land.
--   * socket exposes line/frame/exact readers + timeouts + getaddrinfo
--     (IPv6 + name resolution), which async deliberately omits.

local ffi = ffi
require "windows"   -- baseline typedefs (BOOL, DWORD, HANDLE, ...)

-- ============================================================
-- cdef: winsock2 + ws2tcpip surface we touch
-- ============================================================
-- SOCKET is UINT_PTR but we type it as int64 so winsock return values
-- land as plain Lua integers (no cdata boxing); INVALID_SOCKET
-- round-trips as -1.

ffi.cdef[[
typedef long long sock_SOCKET;

typedef struct sock_sockaddr {
    unsigned short sa_family;
    char           sa_data[14];
} sock_sockaddr;

typedef struct sock_in_addr {
    unsigned long s_addr;
} sock_in_addr;

typedef struct sock_sockaddr_in {
    short              sin_family;
    unsigned short     sin_port;
    sock_in_addr       sin_addr;
    char               sin_zero[8];
} sock_sockaddr_in;

typedef struct sock_in6_addr {
    unsigned char s6_addr[16];
} sock_in6_addr;

typedef struct sock_sockaddr_in6 {
    short          sin6_family;
    unsigned short sin6_port;
    unsigned long  sin6_flowinfo;
    sock_in6_addr  sin6_addr;
    unsigned long  sin6_scope_id;
} sock_sockaddr_in6;

typedef struct sock_sockaddr_storage {
    short  ss_family;
    char   __ss_pad1[6];
    long long __ss_align;
    char   __ss_pad2[112];
} sock_sockaddr_storage;

typedef struct sock_addrinfo {
    int                    ai_flags;
    int                    ai_family;
    int                    ai_socktype;
    int                    ai_protocol;
    size_t                 ai_addrlen;
    char                  *ai_canonname;
    sock_sockaddr         *ai_addr;
    struct sock_addrinfo  *ai_next;
} sock_addrinfo;

typedef struct sock_timeval {
    long tv_sec;
    long tv_usec;
} sock_timeval;

typedef struct sock_WSAData {
    unsigned short wVersion;
    unsigned short wHighVersion;
    unsigned short iMaxSockets;
    unsigned short iMaxUdpDg;
    char          *lpVendorInfo;
    char           szDescription[257];
    char           szSystemStatus[129];
} sock_WSAData;

typedef struct sock_fd_set_one {
    unsigned int fd_count;
    sock_SOCKET  fd_array[64];
} sock_fd_set_one;

int            WSAStartup(unsigned short, sock_WSAData *);
int            WSACleanup(void);
int            WSAGetLastError(void);
sock_SOCKET    socket(int, int, int);
int            closesocket(sock_SOCKET);
int            bind(sock_SOCKET, const sock_sockaddr *, int);
int            listen(sock_SOCKET, int);
sock_SOCKET    accept(sock_SOCKET, sock_sockaddr *, int *);
int            connect(sock_SOCKET, const sock_sockaddr *, int);
int            recv(sock_SOCKET, char *, int, int);
int            send(sock_SOCKET, const char *, int, int);
int            recvfrom(sock_SOCKET, char *, int, int, sock_sockaddr *, int *);
int            sendto(sock_SOCKET, const char *, int, int, const sock_sockaddr *, int);
int            shutdown(sock_SOCKET, int);
int            getpeername(sock_SOCKET, sock_sockaddr *, int *);
int            getsockname(sock_SOCKET, sock_sockaddr *, int *);
int            getsockopt(sock_SOCKET, int, int, char *, int *);
int            setsockopt(sock_SOCKET, int, int, const char *, int);
int            select(int, sock_fd_set_one *, sock_fd_set_one *, sock_fd_set_one *, const sock_timeval *);
int            ioctlsocket(sock_SOCKET, long, unsigned long *);
unsigned short htons(unsigned short);
unsigned short ntohs(unsigned short);
unsigned long  htonl(unsigned long);
unsigned long  ntohl(unsigned long);
unsigned long  inet_addr(const char *);
int            getaddrinfo(const char *, const char *, const sock_addrinfo *, sock_addrinfo **);
void           freeaddrinfo(sock_addrinfo *);
int            getnameinfo(const sock_sockaddr *, int, char *, unsigned long, char *, unsigned long, int);
int            WSAStringToAddressA(const char *, int, void *, sock_sockaddr *, int *);
int            WSAAddressToStringA(const sock_sockaddr *, unsigned long, void *, char *, unsigned long *);
]]

pcall(ffi.load, "ws2_32")
local C = ffi.C

-- ============================================================
-- constants
-- ============================================================
local AF_UNSPEC      = 0
local AF_INET        = 2
local AF_INET6       = 23
local SOCK_STREAM    = 1
local SOCK_DGRAM     = 2
local IPPROTO_TCP    = 6
local IPPROTO_UDP    = 17
local SOL_SOCKET     = 0xFFFF
local IPPROTO_IPV6   = 41
local IPV6_V6ONLY    = 27
local SO_ERROR       = 0x1007
local SO_REUSEADDR   = 0x0004
local SO_KEEPALIVE   = 0x0008
local SO_RCVTIMEO    = 0x1006
local SO_SNDTIMEO    = 0x1005
local SO_RCVBUF      = 0x1002
local SO_SNDBUF      = 0x1001
local TCP_NODELAY    = 0x0001
local FIONBIO        = 0x8004667e -- _IOW('f', 126, u_long)
local SOCKET_ERROR   = -1
local INVALID_SOCKET = -1
local SD_RECV        = 0
local SD_SEND        = 1
local SD_BOTH        = 2
local WSAEWOULDBLOCK = 10035
local WSAEINPROGRESS = 10036
local WSAEALREADY    = 10037
local WSAEISCONN     = 10056
local WSAETIMEDOUT   = 10060
local WSAECONNRESET  = 10054
local NI_MAXHOST     = 1025
local NI_MAXSERV     = 32
local NI_NUMERICHOST = 0x02
local NI_NUMERICSERV = 0x08

-- WSAStartup is process-wide and idempotent (refcounted internally).
-- We call once at module load; any prior async.init has already done
-- this and the kernel just bumps the refcount.
do
    local wsa = ffi.new("sock_WSAData")
    if C.WSAStartup(0x0202, wsa) ~= 0 then
        error("socket: WSAStartup failed")
    end
end

-- Cache the error-retrieval function pointer: every ffi.C.X lookup
-- calls GetProcAddress which itself sets LastError, clobbering the
-- exact value we're trying to read. (async/init.lua documents this.)
local WSAGetLastError = C.WSAGetLastError
local function wsa_err() return tonumber(WSAGetLastError()) end

local function is_invalid_socket(s) return s == INVALID_SOCKET end

-- ============================================================
-- address helpers
-- ============================================================

-- inet_ntop equivalent for v4 (network-order uint32).
local function format_ipv4_naddr(n_order)
    local h = tonumber(C.ntohl(n_order))
    return string.format("%d.%d.%d.%d",
        (h >> 24) & 0xFF, (h >> 16) & 0xFF,
        (h >>  8) & 0xFF,  h        & 0xFF)
end

-- inet_ntop equivalent for v6: use WSAAddressToStringA so we don't
-- need to re-implement the canonical "::" rule.
local function format_ipv6_from_sockaddr(sa6)
    local out = ffi.new("char[?]", 128)
    local outlen = ffi.new("unsigned long[1]"); outlen[0] = 128
    if C.WSAAddressToStringA(ffi.cast("sock_sockaddr *", sa6),
            ffi.sizeof("sock_sockaddr_in6"), nil, out, outlen) ~= 0 then
        return nil
    end
    -- WSAAddressToString appends ":port" -- strip it (substring before
    -- last ':' if and only if the string ends with ":<digits>").
    local s = ffi.string(out)
    local prefix = s:match("^%[?([^%]]+)%]?:%d+$")
    return prefix or s
end

-- Decode any sockaddr (v4 or v6) into (host, port) pair.
local function sockaddr_to_host_port(psa)
    local fam = psa[0].sa_family
    if fam == AF_INET then
        local sin = ffi.cast("sock_sockaddr_in *", psa)
        return format_ipv4_naddr(sin.sin_addr.s_addr),
               tonumber(C.ntohs(sin.sin_port))
    elseif fam == AF_INET6 then
        local sin6 = ffi.cast("sock_sockaddr_in6 *", psa)
        return format_ipv6_from_sockaddr(sin6),
               tonumber(C.ntohs(sin6.sin6_port))
    end
    return nil, nil
end

-- Resolve a hostname (or IP literal) to a list of sock_addrinfo *
-- entries. Caller MUST freeaddrinfo. We expose this as an iterator
-- so use-sites can short-circuit after the first successful connect.
local function getaddrinfo_list(host, port, family, socktype)
    local hints = ffi.new("sock_addrinfo")
    hints.ai_family   = family or AF_UNSPEC
    hints.ai_socktype = socktype or SOCK_STREAM
    hints.ai_protocol = (socktype == SOCK_DGRAM) and IPPROTO_UDP or IPPROTO_TCP
    local out  = ffi.new("sock_addrinfo *[1]")
    local pstr = port and tostring(port) or nil
    if C.getaddrinfo(host, pstr, hints, out) ~= 0 then
        return nil, "getaddrinfo failed: " .. wsa_err()
    end
    return out[0]
end

-- ============================================================
-- TCP connection object
-- ============================================================

local tcp_mt = { __index = {} }
local tcp_methods = tcp_mt.__index

-- Set blocking / non-blocking. We default to blocking with timeouts so
-- the high-level API matches LuaSocket / Python's socket conventions;
-- callers that want true non-blocking pass opts.blocking=false.
local function set_blocking_impl(fd, yes)
    local arg = ffi.new("unsigned long[1]")
    arg[0] = yes and 0 or 1
    return C.ioctlsocket(fd, FIONBIO, arg) == 0
end

local function set_timeout_impl(fd, ms)
    -- SO_RCVTIMEO/SO_SNDTIMEO on Windows takes DWORD ms, not timeval.
    local v = ffi.new("unsigned long[1]"); v[0] = ms or 0
    C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ffi.cast("const char *", v), 4)
    C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ffi.cast("const char *", v), 4)
end

-- Read up to `n` bytes. Returns chunk on success (may be shorter than
-- n), nil+"eof" on clean peer close, nil+err on error.
function tcp_methods:read(n)
    if self._closed then return nil, "socket closed" end
    n = n or 4096
    -- Drain transport-level buffer first (set by read_line/read_until
    -- when they overshoot the delimiter).
    if self._rbuf and #self._rbuf > 0 then
        if #self._rbuf >= n then
            local out = self._rbuf:sub(1, n)
            self._rbuf = self._rbuf:sub(n + 1)
            return out
        end
        -- Drain whatever's buffered immediately; caller can re-call
        -- for more. Matches POSIX read() short-read semantics.
        local out = self._rbuf
        self._rbuf = ""
        return out
    end
    local buf = ffi.new("char[?]", n)
    local got = C.recv(self.fd, buf, n, 0)
    local got_n = tonumber(got)
    if got_n > 0 then
        return ffi.string(buf, got_n)
    end
    if got_n == 0 then return nil, "eof" end
    local err = wsa_err()
    if err == WSAETIMEDOUT then return nil, "timeout" end
    return nil, "recv error " .. err
end

-- Read exactly n bytes; nil+err if connection closes early.
function tcp_methods:read_exact(n)
    local parts, total = {}, 0
    while total < n do
        local chunk, err = self:read(n - total)
        if not chunk then
            if err == "eof" and total > 0 then return nil, "short read" end
            return nil, err
        end
        parts[#parts + 1] = chunk
        total = total + #chunk
    end
    return table.concat(parts)
end

-- Read until a delimiter substring (returned WITHOUT the delimiter).
-- We over-read into self._rbuf and stash leftover bytes for future
-- reads. max_bytes caps the search to bound memory.
function tcp_methods:read_until(delim, max_bytes)
    if self._closed then return nil, "socket closed" end
    max_bytes = max_bytes or 1048576
    self._rbuf = self._rbuf or ""
    while true do
        local idx = self._rbuf:find(delim, 1, true)
        if idx then
            local out = self._rbuf:sub(1, idx - 1)
            self._rbuf = self._rbuf:sub(idx + #delim)
            return out
        end
        if #self._rbuf > max_bytes then
            return nil, "read_until: max_bytes exceeded"
        end
        local n = 4096
        local buf = ffi.new("char[?]", n)
        local got = tonumber(C.recv(self.fd, buf, n, 0))
        if got > 0 then
            self._rbuf = self._rbuf .. ffi.string(buf, got)
        elseif got == 0 then
            return nil, "eof"
        else
            local err = wsa_err()
            if err == WSAETIMEDOUT then return nil, "timeout" end
            return nil, "recv error " .. err
        end
    end
end

-- Read a line. opts.crlf=true requires "\r\n" (HTTP-style); default
-- accepts either "\n" or "\r\n" and strips the terminator.
function tcp_methods:read_line(opts)
    opts = opts or {}
    local delim = opts.crlf and "\r\n" or "\n"
    local s, err = self:read_until(delim, opts.max_bytes)
    if not s then return nil, err end
    if not opts.crlf and #s > 0 and s:sub(-1) == "\r" then
        s = s:sub(1, -2)
    end
    return s
end

-- Read a length-prefixed frame. opts.size = 1|2|4|8, opts.endian="be"|"le".
function tcp_methods:read_frame(opts)
    opts = opts or {}
    local size = opts.size or 4
    local endian = opts.endian or "be"
    local hdr, err = self:read_exact(size)
    if not hdr then return nil, err end
    local len = 0
    if endian == "be" then
        for i = 1, size do len = (len << 8) | hdr:byte(i) end
    else
        for i = size, 1, -1 do len = (len << 8) | hdr:byte(i) end
    end
    if opts.max_size and len > opts.max_size then
        return nil, "read_frame: oversize (" .. len .. " > " .. opts.max_size .. ")"
    end
    if len == 0 then return "" end
    return self:read_exact(len)
end

-- Send all bytes (loops on partial sends).
-- Allocates a managed char buffer per call because our ffi.cast doesn't
-- accept Lua strings (a known gap vs LuaJIT). Explicit pointer cast on
-- the buffer because our FFI also doesn't auto-decay arrays to pointers
-- for arithmetic.
function tcp_methods:write(data)
    if self._closed then return nil, "socket closed" end
    local n    = #data
    local cbuf = ffi.new("char[?]", n)
    ffi.copy(cbuf, data, n)
    local cptr = ffi.cast("char *", cbuf)
    local sent = 0
    while sent < n do
        local r = tonumber(C.send(self.fd, cptr + sent, n - sent, 0))
        if r > 0 then
            sent = sent + r
        else
            local err = wsa_err()
            if err == WSAETIMEDOUT then return nil, "timeout" end
            return nil, "send error " .. err
        end
    end
    return sent
end

function tcp_methods:write_frame(data, opts)
    opts = opts or {}
    local size = opts.size or 4
    local endian = opts.endian or "be"
    local len = #data
    local hdr_bytes = {}
    if endian == "be" then
        for i = size, 1, -1 do hdr_bytes[i] = string.char((len >> ((size - i) * 8)) & 0xFF) end
    else
        for i = 1, size do hdr_bytes[i] = string.char((len >> ((i - 1) * 8)) & 0xFF) end
    end
    local hdr = table.concat(hdr_bytes)
    local ok, err = self:write(hdr)
    if not ok then return nil, err end
    if len > 0 then
        ok, err = self:write(data)
        if not ok then return nil, err end
    end
    return len
end

function tcp_methods:set_timeout(ms)
    self._timeout = ms
    set_timeout_impl(self.fd, ms)
end

function tcp_methods:set_blocking(yes)
    self._blocking = yes and true or false
    return set_blocking_impl(self.fd, yes)
end

-- Disable Nagle. Useful for redis / http when we want each write to
-- hit the wire promptly.
function tcp_methods:set_nodelay(yes)
    local v = ffi.new("int[1]"); v[0] = yes and 1 or 0
    C.setsockopt(self.fd, IPPROTO_TCP, TCP_NODELAY,
        ffi.cast("const char *", v), 4)
end

function tcp_methods:set_keepalive(yes)
    local v = ffi.new("int[1]"); v[0] = yes and 1 or 0
    C.setsockopt(self.fd, SOL_SOCKET, SO_KEEPALIVE,
        ffi.cast("const char *", v), 4)
end

function tcp_methods:peer_addr()
    local sa = ffi.new("sock_sockaddr_storage")
    local len = ffi.new("int[1]"); len[0] = ffi.sizeof("sock_sockaddr_storage")
    if C.getpeername(self.fd, ffi.cast("sock_sockaddr *", sa), len) ~= 0 then
        return nil, "getpeername failed: " .. wsa_err()
    end
    return sockaddr_to_host_port(ffi.cast("sock_sockaddr *", sa))
end

function tcp_methods:local_addr()
    local sa = ffi.new("sock_sockaddr_storage")
    local len = ffi.new("int[1]"); len[0] = ffi.sizeof("sock_sockaddr_storage")
    if C.getsockname(self.fd, ffi.cast("sock_sockaddr *", sa), len) ~= 0 then
        return nil, "getsockname failed: " .. wsa_err()
    end
    return sockaddr_to_host_port(ffi.cast("sock_sockaddr *", sa))
end

function tcp_methods:shutdown(how)
    local h = SD_BOTH
    if     how == "r" then h = SD_RECV
    elseif how == "w" then h = SD_SEND end
    C.shutdown(self.fd, h)
end

function tcp_methods:close()
    if not self._closed then
        C.closesocket(self.fd)
        self._closed = true
    end
end

function tcp_methods:fileno() return self.fd end

tcp_mt.__gc = tcp_methods.close

-- ============================================================
-- listener / server object (reuses tcp_mt for accept'd peer)
-- ============================================================

local server_mt = { __index = {} }
local server_methods = server_mt.__index

function server_methods:accept()
    if self._closed then return nil, "server closed" end
    local sa = ffi.new("sock_sockaddr_storage")
    local len = ffi.new("int[1]"); len[0] = ffi.sizeof("sock_sockaddr_storage")
    local client = C.accept(self.fd, ffi.cast("sock_sockaddr *", sa), len)
    if is_invalid_socket(client) then
        local err = wsa_err()
        if err == WSAETIMEDOUT then return nil, "timeout" end
        return nil, "accept failed: " .. err
    end
    -- Inherit listener's timeout setting onto the accepted peer; matches
    -- behavior callers expect (set on server, applies to children).
    local peer = setmetatable({
        fd        = client,
        _closed   = false,
        _blocking = self._blocking,
        _timeout  = self._timeout,
        _rbuf     = "",
    }, tcp_mt)
    if self._timeout then set_timeout_impl(client, self._timeout) end
    return peer
end

function server_methods:close()
    if not self._closed then
        C.closesocket(self.fd)
        self._closed = true
    end
end

function server_methods:local_addr() return tcp_methods.local_addr(self) end
function server_methods:set_timeout(ms)
    self._timeout = ms
    set_timeout_impl(self.fd, ms)
end

server_mt.__gc = server_methods.close

-- ============================================================
-- TCP factory: connect / listen
-- ============================================================

local M = {}
M.tcp = {}
M.udp = {}

-- Build a socket, apply timeout + nodelay defaults, return cdata fd
-- and the resolved sockaddr we'll bind/connect with.
local function open_stream_socket(family)
    local fd = C.socket(family, SOCK_STREAM, IPPROTO_TCP)
    if is_invalid_socket(fd) then
        return nil, "socket() failed: " .. wsa_err()
    end
    return fd
end

-- Try each getaddrinfo result until one connects. Returns the
-- successfully connected SOCKET + family + sockaddr length.
local function connect_first(host, port, opts)
    local ai_head, err = getaddrinfo_list(host, port,
        (opts and opts.family) or AF_UNSPEC, SOCK_STREAM)
    if not ai_head then return nil, err end
    local last_err = "no address"
    local cur = ai_head
    while cur ~= nil do
        -- Explicit [0] deref: our FFI doesn't auto-deref struct
        -- pointers for `.field` access the way LuaJIT does. Without
        -- this we get "no field 'ai_family' in struct/union" because
        -- the field lookup runs on the POINTER type rather than the
        -- pointee.
        local node = cur[0]
        local fd = C.socket(node.ai_family, node.ai_socktype, node.ai_protocol)
        if not is_invalid_socket(fd) then
            -- Apply blocking-style timeout (ms) BEFORE the connect so
            -- a hung SYN-ACK doesn't pin the caller forever.
            if opts and opts.timeout then
                set_timeout_impl(fd, opts.timeout)
            end
            if C.connect(fd, node.ai_addr, node.ai_addrlen) == 0 then
                C.freeaddrinfo(ai_head)
                return fd, node.ai_family
            end
            last_err = "connect failed: " .. wsa_err()
            C.closesocket(fd)
        else
            last_err = "socket() failed: " .. wsa_err()
        end
        cur = node.ai_next
    end
    C.freeaddrinfo(ai_head)
    return nil, last_err
end

-- socket.tcp.connect(host, port, opts?):
--   opts.timeout    -- ms, applied as SO_RCVTIMEO / SO_SNDTIMEO
--   opts.nodelay    -- disable Nagle
--   opts.keepalive  -- enable SO_KEEPALIVE
--   opts.family     -- "v4" | "v6" (default: dual)
--   opts.blocking   -- default true; pass false for FIONBIO non-block
function M.tcp.connect(host, port, opts)
    opts = opts or {}
    local family
    if     opts.family == "v4" then family = AF_INET
    elseif opts.family == "v6" then family = AF_INET6
    else                            family = AF_UNSPEC end
    opts.family = family
    local fd, err = connect_first(host, port, opts)
    if not fd then return nil, err end
    local conn = setmetatable({
        fd        = fd,
        _closed   = false,
        _blocking = (opts.blocking ~= false),
        _timeout  = opts.timeout,
        _rbuf     = "",
    }, tcp_mt)
    if opts.nodelay   then conn:set_nodelay(true) end
    if opts.keepalive then conn:set_keepalive(true) end
    if opts.blocking == false then conn:set_blocking(false) end
    return conn
end

-- socket.tcp.listen(host, port, backlog?):
--   "0.0.0.0" / "::" binds to all interfaces. We pick the family from
--   the literal: a ':' in host -> v6, else v4. For dual-stack, callers
--   pass "::" and we clear IPV6_V6ONLY so the v6 socket accepts v4 too.
function M.tcp.listen(host, port, backlog)
    host = host or "0.0.0.0"
    backlog = backlog or 16
    local family = host:find(":", 1, true) and AF_INET6 or AF_INET
    local fd, err = open_stream_socket(family)
    if not fd then return nil, err end
    -- SO_REUSEADDR -- standard "let me re-bind quickly after restart"
    local on = ffi.new("int[1]"); on[0] = 1
    C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
        ffi.cast("const char *", on), 4)
    if family == AF_INET6 then
        -- Make v6 listeners accept v4 mapped addresses too.
        local off = ffi.new("int[1]"); off[0] = 0
        C.setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY,
            ffi.cast("const char *", off), 4)
    end
    local ai_head, gerr = getaddrinfo_list(host, port, family, SOCK_STREAM)
    if not ai_head then
        C.closesocket(fd)
        return nil, gerr
    end
    if C.bind(fd, ai_head.ai_addr, ai_head.ai_addrlen) ~= 0 then
        local e = wsa_err()
        C.freeaddrinfo(ai_head)
        C.closesocket(fd)
        return nil, "bind failed: " .. e
    end
    C.freeaddrinfo(ai_head)
    if C.listen(fd, backlog) ~= 0 then
        local e = wsa_err()
        C.closesocket(fd)
        return nil, "listen failed: " .. e
    end
    return setmetatable({
        fd        = fd,
        _closed   = false,
        _blocking = true,
    }, server_mt)
end

-- ============================================================
-- UDP socket
-- ============================================================

local udp_mt = { __index = {} }
local udp_methods = udp_mt.__index

function udp_methods:recv_from(maxlen)
    if self._closed then return nil, "socket closed" end
    maxlen = maxlen or 65536
    local buf = ffi.new("char[?]", maxlen)
    local sa  = ffi.new("sock_sockaddr_storage")
    local salen = ffi.new("int[1]"); salen[0] = ffi.sizeof("sock_sockaddr_storage")
    local got = tonumber(C.recvfrom(self.fd, buf, maxlen, 0,
        ffi.cast("sock_sockaddr *", sa), salen))
    if got < 0 then
        local err = wsa_err()
        if err == WSAETIMEDOUT then return nil, "timeout" end
        return nil, "recvfrom error " .. err
    end
    local host, port = sockaddr_to_host_port(ffi.cast("sock_sockaddr *", sa))
    return ffi.string(buf, got), host, port
end

function udp_methods:send_to(data, host, port)
    if self._closed then return nil, "socket closed" end
    local ai_head, err = getaddrinfo_list(host, port, AF_UNSPEC, SOCK_DGRAM)
    if not ai_head then return nil, err end
    local r = tonumber(C.sendto(self.fd, data, #data, 0,
        ai_head.ai_addr, ai_head.ai_addrlen))
    C.freeaddrinfo(ai_head)
    if r < 0 then
        local e = wsa_err()
        if e == WSAETIMEDOUT then return nil, "timeout" end
        return nil, "sendto error " .. e
    end
    return r
end

function udp_methods:set_timeout(ms)
    self._timeout = ms
    set_timeout_impl(self.fd, ms)
end

function udp_methods:set_broadcast(yes)
    -- SO_BROADCAST = 0x20
    local v = ffi.new("int[1]"); v[0] = yes and 1 or 0
    C.setsockopt(self.fd, SOL_SOCKET, 0x20,
        ffi.cast("const char *", v), 4)
end

function udp_methods:local_addr() return tcp_methods.local_addr(self) end

function udp_methods:close()
    if not self._closed then
        C.closesocket(self.fd)
        self._closed = true
    end
end

udp_mt.__gc = udp_methods.close

function M.udp.bind(host, port)
    host = host or "0.0.0.0"
    port = port or 0
    local family = host:find(":", 1, true) and AF_INET6 or AF_INET
    local fd = C.socket(family, SOCK_DGRAM, IPPROTO_UDP)
    if is_invalid_socket(fd) then
        return nil, "socket() failed: " .. wsa_err()
    end
    local ai_head, err = getaddrinfo_list(host, port, family, SOCK_DGRAM)
    if not ai_head then
        C.closesocket(fd)
        return nil, err
    end
    if C.bind(fd, ai_head.ai_addr, ai_head.ai_addrlen) ~= 0 then
        local e = wsa_err()
        C.freeaddrinfo(ai_head)
        C.closesocket(fd)
        return nil, "bind failed: " .. e
    end
    C.freeaddrinfo(ai_head)
    return setmetatable({
        fd      = fd,
        _closed = false,
    }, udp_mt)
end

-- Unbound UDP sender (no local port reservation -- ephemeral on first send).
function M.udp.new()
    return M.udp.bind("0.0.0.0", 0)
end

-- ============================================================
-- DNS-style helper (system resolver via getaddrinfo)
-- ============================================================

-- socket.resolve("example.com") -> { "93.184.216.34", "2606:..." }
-- Returns IP literals as strings. Use the `dns` package for typed
-- records (MX, TXT, SRV...).
function M.resolve(host)
    local ai_head, err = getaddrinfo_list(host, 0, AF_UNSPEC, SOCK_STREAM)
    if not ai_head then return nil, err end
    local out, seen = {}, {}
    local cur = ai_head
    while cur ~= nil do
        local h = sockaddr_to_host_port(cur.ai_addr)
        if h and not seen[h] then
            seen[h] = true
            out[#out + 1] = h
        end
        cur = cur.ai_next
    end
    C.freeaddrinfo(ai_head)
    return out
end

-- Reverse resolve an IP literal back to a hostname via getnameinfo.
function M.resolve_addr(ip)
    local ai_head, err = getaddrinfo_list(ip, 0, AF_UNSPEC, SOCK_STREAM)
    if not ai_head then return nil, err end
    local host = ffi.new("char[?]", NI_MAXHOST)
    local rc = C.getnameinfo(ai_head.ai_addr, ai_head.ai_addrlen,
        host, NI_MAXHOST, nil, 0, 0)
    C.freeaddrinfo(ai_head)
    if rc ~= 0 then return nil, "getnameinfo failed: " .. rc end
    return ffi.string(host)
end

-- ============================================================
-- select() wrapper (helper for the http server keep-alive loop)
-- ============================================================

-- socket.select(read_socks, write_socks, timeout_ms?) -> readables, writables
-- timeout_ms == nil means wait forever; 0 means poll.
function M.select(read_socks, write_socks, timeout_ms)
    read_socks  = read_socks  or {}
    write_socks = write_socks or {}
    if #read_socks > 64 or #write_socks > 64 then
        return nil, "select: max 64 sockets per set (Windows fd_set limit)"
    end
    local rs = ffi.new("sock_fd_set_one")
    local ws = ffi.new("sock_fd_set_one")
    rs.fd_count = #read_socks
    for i, s in ipairs(read_socks)  do rs.fd_array[i - 1] = s.fd end
    ws.fd_count = #write_socks
    for i, s in ipairs(write_socks) do ws.fd_array[i - 1] = s.fd end
    local tv_ptr
    if timeout_ms then
        local tv = ffi.new("sock_timeval")
        tv.tv_sec  = timeout_ms // 1000
        tv.tv_usec = (timeout_ms % 1000) * 1000
        tv_ptr = tv
    end
    local r = C.select(0, rs, ws, nil, tv_ptr)
    if r < 0 then return nil, "select error " .. wsa_err() end
    local rout, wout = {}, {}
    for i, s in ipairs(read_socks)  do
        for j = 0, rs.fd_count - 1 do
            if rs.fd_array[j] == s.fd then rout[#rout + 1] = s; break end
        end
    end
    for i, s in ipairs(write_socks) do
        for j = 0, ws.fd_count - 1 do
            if ws.fd_array[j] == s.fd then wout[#wout + 1] = s; break end
        end
    end
    return rout, wout
end

-- ============================================================
-- Constants exposed for higher-level packages
-- ============================================================

M.AF_INET     = AF_INET
M.AF_INET6    = AF_INET6
M.SOCK_STREAM = SOCK_STREAM
M.SOCK_DGRAM  = SOCK_DGRAM

return M
