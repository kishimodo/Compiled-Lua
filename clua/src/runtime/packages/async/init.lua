-- async: coroutine-driven scheduler with Windows overlapped-I/O support.
--
-- A "task" is a coroutine. Each yield carries a wait descriptor:
--   {kind="time", until_ms=N}     wake at GetTickCount()=N
--   {kind="io",   event=HANDLE}   wake when HANDLE signals
-- The single event_loop call multiplexes both via WaitForMultipleObjects
-- with a computed timeout.

local function MakeAsync()
    assert(ffi, "async needs ffi")
    ffi.cdef[[
    /* ----- handle / overlapped types (local copy; matches windows.lua) ----- */
    typedef void              *async_HANDLE;
    typedef unsigned long      async_DWORD;
    typedef int                async_BOOL;
    typedef unsigned long long async_ULONGLONG;
    /* SOCKET is UINT_PTR (64-bit) per Win64 ABI. We declare it signed so
       Marshal_CToLua pushes it as a Lua integer (no cdata box) — that
       keeps WSAGetLastError uncorrupted by lua_newuserdata between the
       Winsock call and the error retrieval. INVALID_SOCKET round-trips
       as Lua integer -1 (= 0xFFFFFFFFFFFFFFFF in 2's complement). */
    typedef long long          async_SOCKET;

    typedef struct _async_OVERLAPPED {
        async_ULONGLONG Internal;
        async_ULONGLONG InternalHigh;
        async_ULONGLONG Offset;
        async_HANDLE    hEvent;
    } async_OVERLAPPED;

    /* sockaddr_in for IPv4. sin_zero pads to sizeof(sockaddr). */
    typedef struct _async_sockaddr_in {
        short          sin_family;
        unsigned short sin_port;
        unsigned long  sin_addr;
        char           sin_zero[8];
    } async_sockaddr_in;

    /* WSANETWORKEVENTS: event mask + per-bit error codes (FD_MAX_EVENTS=10) */
    typedef struct _async_WSANETWORKEVENTS {
        long lNetworkEvents;
        int  iErrorCode[10];
    } async_WSANETWORKEVENTS;

    /* WSADATA (only the first few fields matter for WSAStartup; size 408
       on Win64 is what the kernel expects so we declare a padded buffer). */
    typedef struct _async_WSADATA {
        unsigned short wVersion;
        unsigned short wHighVersion;
        char           szDescription[257];
        char           szSystemStatus[129];
        unsigned short iMaxSockets;
        unsigned short iMaxUdpDg;
        char          *lpVendorInfo;
        char           padding[16];
    } async_WSADATA;

    /* ----- kernel32 ----- */
    async_DWORD   GetTickCount(void);
    void          Sleep(async_DWORD);
    async_HANDLE  CreateFileA(const char*, async_DWORD, async_DWORD,
                              void*, async_DWORD, async_DWORD, async_HANDLE);
    async_BOOL    ReadFile(async_HANDLE, void*, async_DWORD,
                           async_DWORD*, async_OVERLAPPED*);
    async_BOOL    WriteFile(async_HANDLE, const void*, async_DWORD,
                            async_DWORD*, async_OVERLAPPED*);
    async_BOOL    CloseHandle(async_HANDLE);
    async_HANDLE  CreateEventW(void*, async_BOOL, async_BOOL,
                               const unsigned short*);
    async_BOOL    ResetEvent(async_HANDLE);
    async_BOOL    SetEvent(async_HANDLE);
    async_DWORD   WaitForMultipleObjects(async_DWORD,
                                         const async_HANDLE*,
                                         async_BOOL, async_DWORD);
    async_DWORD   WaitForSingleObject(async_HANDLE, async_DWORD);
    async_BOOL    GetOverlappedResult(async_HANDLE, async_OVERLAPPED*,
                                      async_DWORD*, async_BOOL);
    async_DWORD   GetLastError(void);
    async_BOOL    CancelIoEx(async_HANDLE, async_OVERLAPPED*);

    /* subprocess pipes */
    typedef struct _async_SA {
        async_DWORD   nLength;
        void         *lpSecurityDescriptor;
        async_BOOL    bInheritHandle;
    } async_SECURITY_ATTRIBUTES;

    typedef struct _async_STARTUPINFOA {
        async_DWORD  cb;
        char        *lpReserved;
        char        *lpDesktop;
        char        *lpTitle;
        async_DWORD  dwX;
        async_DWORD  dwY;
        async_DWORD  dwXSize;
        async_DWORD  dwYSize;
        async_DWORD  dwXCountChars;
        async_DWORD  dwYCountChars;
        async_DWORD  dwFillAttribute;
        async_DWORD  dwFlags;
        unsigned short wShowWindow;
        unsigned short cbReserved2;
        unsigned char *lpReserved2;
        async_HANDLE hStdInput;
        async_HANDLE hStdOutput;
        async_HANDLE hStdError;
    } async_STARTUPINFOA;

    typedef struct _async_PROCESS_INFORMATION {
        async_HANDLE hProcess;
        async_HANDLE hThread;
        async_DWORD  dwProcessId;
        async_DWORD  dwThreadId;
    } async_PROCESS_INFORMATION;

    async_BOOL CreatePipe(async_HANDLE*, async_HANDLE*,
                          async_SECURITY_ATTRIBUTES*, async_DWORD);
    async_BOOL CreateProcessA(const char*, char*,
                              async_SECURITY_ATTRIBUTES*,
                              async_SECURITY_ATTRIBUTES*,
                              async_BOOL, async_DWORD, void*, const char*,
                              async_STARTUPINFOA*,
                              async_PROCESS_INFORMATION*);
    async_BOOL PeekNamedPipe(async_HANDLE, void*, async_DWORD,
                             async_DWORD*, async_DWORD*, async_DWORD*);
    async_BOOL GetExitCodeProcess(async_HANDLE, async_DWORD*);

    /* ----- ws2_32 ----- */
    int            WSAStartup(unsigned short, async_WSADATA*);
    int            WSACleanup(void);
    async_SOCKET   socket(int, int, int);
    int            closesocket(async_SOCKET);
    int            bind(async_SOCKET, const async_sockaddr_in*, int);
    int            listen(async_SOCKET, int);
    async_SOCKET   accept(async_SOCKET, async_sockaddr_in*, int*);
    int            connect(async_SOCKET, const async_sockaddr_in*, int);
    int            recv(async_SOCKET, char*, int, int);
    int            send(async_SOCKET, const char*, int, int);
    int            recvfrom(async_SOCKET, char*, int, int,
                            async_sockaddr_in*, int*);
    int            sendto(async_SOCKET, const char*, int, int,
                          const async_sockaddr_in*, int);
    unsigned long  ntohl(unsigned long);
    unsigned short ntohs(unsigned short);
    async_HANDLE   WSACreateEvent(void);
    int            WSACloseEvent(async_HANDLE);
    int            WSAEventSelect(async_SOCKET, async_HANDLE, long);
    int            WSAEnumNetworkEvents(async_SOCKET, async_HANDLE,
                                        async_WSANETWORKEVENTS*);
    int            WSAGetLastError(void);
    unsigned short htons(unsigned short);
    unsigned long  inet_addr(const char*);
    int            getsockopt(async_SOCKET, int, int, char*, int*);
    int            setsockopt(async_SOCKET, int, int, const char*, int);
    ]]

    local C = ffi.C
    local INVALID_HANDLE         = ffi.cast("async_HANDLE", -1)
    -- async_SOCKET is signed int64 so Winsock returns push as plain Lua
    -- integers (no cdata boxing — see typedef comment). INVALID_SOCKET
    -- surfaces as Lua integer -1.
    local INVALID_SOCKET         = -1
    local function is_invalid_socket(s) return s == INVALID_SOCKET end

    local GENERIC_READ           = 0x80000000
    local GENERIC_WRITE          = 0x40000000
    local FILE_SHARE_READ        = 0x00000001
    local CREATE_ALWAYS          = 2
    local OPEN_EXISTING          = 3
    local FILE_FLAG_OVERLAPPED   = 0x40000000
    local WAIT_OBJECT_0          = 0
    local WAIT_TIMEOUT           = 0x102
    local ERROR_IO_PENDING       = 997
    local ERROR_HANDLE_EOF       = 38
    local ERROR_BROKEN_PIPE      = 109

    -- socket constants
    local AF_INET                = 2
    local SOCK_STREAM            = 1
    local IPPROTO_TCP            = 6
    local SOL_SOCKET             = 0xFFFF
    local SO_ERROR               = 0x1007
    local SO_REUSEADDR           = 0x0004
    local SOCKET_ERROR           = -1
    local WSAEWOULDBLOCK         = 10035
    local WSAEISCONN             = 10056
    local WSAEALREADY            = 10037
    local FD_READ                = 0x01
    local FD_WRITE               = 0x02
    local FD_ACCEPT              = 0x08
    local FD_CONNECT             = 0x10
    local FD_CLOSE               = 0x20
    local FD_ALL                 = FD_READ | FD_WRITE | FD_ACCEPT | FD_CONNECT | FD_CLOSE

    local function tick() return tonumber(C.GetTickCount()) end

    local M             = {}
    local g_tasks       = {}     -- list of { co=..., kind=..., data=... }
    local g_inside_loop = false

    -- ===== task creation / time yield =================================

    -- async.run(fn, a, b, c): create a task that runs fn(a, b, c) in
    -- its own coroutine. Up to 3 args (avoids vararg-pack which the
    -- JIT doesn't lower yet). Wrap your own closure for more args.
    function M.run(fn, a, b, c)
        local co = coroutine.create(function() return fn(a, b, c) end)
        g_tasks[#g_tasks + 1] = { co = co, kind = "ready", data = 0 }
        return co
    end

    function M.sleep(ms)
        coroutine.yield({ kind = "time", until_ms = tick() + ms })
    end

    -- Cooperative yield with no wait condition; rescheduled next tick.
    -- The descriptor is cached -- a tight render-loop yields once per
    -- frame, so allocating { kind = "ready" } every call piles up GC
    -- pressure unnecessarily (the scheduler reads kind/data and never
    -- holds the table).
    local _ready_descriptor = { kind = "ready" }
    function M.yield()
        coroutine.yield(_ready_descriptor)
    end

    -- ===== file I/O ===================================================
    --
    -- async.open(path, mode) returns a file handle whose :read / :write
    -- methods yield until the overlapped operation completes. Each file
    -- owns one event HANDLE that's reused across operations -- a single
    -- file cannot have two simultaneous outstanding ops (matches the
    -- single-thread-of-execution semantics of one coroutine driving it).

    local file_mt = { __index = {} }
    local file_methods = file_mt.__index

    local function reissue_event(self)
        C.ResetEvent(self.event)
    end

    function file_methods:read(n)
        if self.handle == nil then return nil, "file closed" end
        n = n or 4096
        local buf = ffi.new("char[?]", n)
        local got = ffi.new("async_DWORD[1]")
        local ov  = ffi.new("async_OVERLAPPED")
        ov.Offset = self.pos
        ov.hEvent = self.event
        reissue_event(self)
        local ok = C.ReadFile(self.handle, buf, n, got, ov)
        if ok == 0 then
            local err = tonumber(C.GetLastError())
            if err == ERROR_HANDLE_EOF or err == ERROR_BROKEN_PIPE then
                return nil, "eof"
            end
            if err ~= ERROR_IO_PENDING then
                return nil, "ReadFile failed: " .. err
            end
            coroutine.yield({ kind = "io", event = self.event })
            if C.GetOverlappedResult(self.handle, ov, got, 1) == 0 then
                local err2 = tonumber(C.GetLastError())
                if err2 == ERROR_HANDLE_EOF or err2 == ERROR_BROKEN_PIPE then
                    return nil, "eof"
                end
                return nil, "ReadFile completion failed: " .. err2
            end
        end
        local bytes = tonumber(got[0])
        if bytes == 0 then return nil, "eof" end
        self.pos = self.pos + bytes
        return ffi.string(buf, bytes)
    end

    function file_methods:write(data)
        if self.handle == nil then return nil, "file closed" end
        local n = #data
        local got = ffi.new("async_DWORD[1]")
        local ov  = ffi.new("async_OVERLAPPED")
        ov.Offset = self.pos
        ov.hEvent = self.event
        reissue_event(self)
        local ok = C.WriteFile(self.handle, data, n, got, ov)
        if ok == 0 then
            local err = tonumber(C.GetLastError())
            if err ~= ERROR_IO_PENDING then
                return nil, "WriteFile failed: " .. err
            end
            coroutine.yield({ kind = "io", event = self.event })
            if C.GetOverlappedResult(self.handle, ov, got, 1) == 0 then
                return nil, "WriteFile completion failed: "
                    .. tonumber(C.GetLastError())
            end
        end
        local bytes = tonumber(got[0])
        self.pos = self.pos + bytes
        return bytes
    end

    function file_methods:close()
        if self.handle ~= nil and self.handle ~= INVALID_HANDLE then
            C.CloseHandle(self.handle)
            self.handle = nil
        end
        if self.event ~= nil then
            C.CloseHandle(self.event)
            self.event = nil
        end
    end

    function M.open(path, mode)
        mode = mode or "r"
        local access, creat
        if mode == "r" then
            access = GENERIC_READ
            creat  = OPEN_EXISTING
        elseif mode == "w" then
            access = GENERIC_WRITE
            creat  = CREATE_ALWAYS
        elseif mode == "rw" then
            access = GENERIC_READ | GENERIC_WRITE
            creat  = OPEN_EXISTING
        else
            return nil, "invalid mode '" .. tostring(mode) .. "'"
        end
        local h = C.CreateFileA(path, access, FILE_SHARE_READ, nil,
                                creat, FILE_FLAG_OVERLAPPED, nil)
        if h == INVALID_HANDLE then
            return nil, "CreateFile failed: " .. tonumber(C.GetLastError())
        end
        -- manual-reset event, initially nonsignaled
        local ev = C.CreateEventW(nil, 1, 0, nil)
        if ev == nil then
            local e = tonumber(C.GetLastError())
            C.CloseHandle(h)
            return nil, "CreateEvent failed: " .. e
        end
        return setmetatable({ handle = h, event = ev, pos = 0 }, file_mt)
    end

    -- ===== TCP sockets (ws2_32) =======================================
    --
    -- Each socket owns one auto-reset WSAEvent registered for all events
    -- (read/write/accept/connect/close). Operations try the syscall in a
    -- loop: on WSAEWOULDBLOCK yield on the event; on resume call
    -- WSAEnumNetworkEvents to consume the signal (auto-resets the event)
    -- and learn what happened, then retry.

    ffi.load("ws2_32")
    do
        local wsa_data = ffi.new("async_WSADATA")
        if C.WSAStartup(0x0202, wsa_data) ~= 0 then
            error("async: WSAStartup failed")
        end
    end

    -- Cache the resolved function pointer locally: each `ffi.C.<name>`
    -- access goes through ffi.C's __index metamethod which calls
    -- GetProcAddress, which itself sets LastError. That clobbers the
    -- value WSAGetLastError is supposed to retrieve from the *previous*
    -- Winsock call. Capturing the cdata once at module load avoids the
    -- lookup overhead AND keeps the error chain intact.
    local WSAGetLastError = C.WSAGetLastError
    local function wsa_err() return tonumber(WSAGetLastError()) end

    local function pump_socket_events(sock)
        local nev = ffi.new("async_WSANETWORKEVENTS")
        C.WSAEnumNetworkEvents(sock.handle, sock.event, nev)
        return tonumber(nev.lNetworkEvents)
    end

    local function wait_socket(sock)
        coroutine.yield({ kind = "io", event = sock.event })
        pump_socket_events(sock)
    end

    local tcp_mt = { __index = {} }
    local tcp_methods = tcp_mt.__index

    function tcp_methods:recv(n)
        if self.handle == nil then return nil, "socket closed" end
        n = n or 4096
        local buf = ffi.new("char[?]", n)
        while true do
            local rraw = C.recv(self.handle, buf, n, 0)
            local last_err = wsa_err()
            local got = tonumber(rraw)
            if got > 0 then
                return ffi.string(buf, got)
            elseif got == 0 then
                return nil, "eof"  -- peer closed
            elseif last_err == WSAEWOULDBLOCK then
                wait_socket(self)
            else
                return nil, "recv error " .. last_err
            end
        end
    end

    function tcp_methods:send(data)
        if self.handle == nil then return nil, "socket closed" end
        local n      = #data
        local sent   = 0
        local cbuf   = data  -- ffi will pass &string[0]
        while sent < n do
            local rraw = C.send(self.handle, cbuf, n - sent, 0)
            local last_err = wsa_err()
            local r = tonumber(rraw)
            if r > 0 then
                sent = sent + r
                if sent < n then
                    -- need to keep advancing the buffer; use ffi.cast
                    cbuf = ffi.cast("const char*", data) + sent
                end
            elseif last_err == WSAEWOULDBLOCK then
                wait_socket(self)
            else
                return nil, "send error " .. last_err
            end
        end
        return sent
    end

    function tcp_methods:accept()
        if self.handle == nil then return nil, "socket closed" end
        while true do
            local client = C.accept(self.handle, nil, nil)
            local last_err = wsa_err()  -- capture immediately; any Lua op below can overwrite it
            if not is_invalid_socket(client) then
                local ev = C.WSACreateEvent()
                if ev == INVALID_HANDLE then
                    C.closesocket(client)
                    return nil, "WSACreateEvent failed"
                end
                if C.WSAEventSelect(client, ev, FD_ALL) ~= 0 then
                    local e = wsa_err()
                    C.WSACloseEvent(ev); C.closesocket(client)
                    return nil, "WSAEventSelect failed: " .. e
                end
                return setmetatable(
                    { handle = client, event = ev, kind = "client" }, tcp_mt)
            end
            if last_err == WSAEWOULDBLOCK then
                wait_socket(self)
            else
                return nil, "accept error " .. last_err
            end
        end
    end

    function tcp_methods:close()
        if self.handle ~= nil then
            C.closesocket(self.handle)
            self.handle = nil
        end
        if self.event ~= nil and self.event ~= INVALID_HANDLE then
            C.WSACloseEvent(self.event)
            self.event = nil
        end
    end

    local function make_socket(host, port, is_server)
        local sock = C.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if is_invalid_socket(sock) then
            return nil, "socket() failed: " .. wsa_err()
        end
        local ev = C.WSACreateEvent()
        if ev == INVALID_HANDLE then
            local e = wsa_err()
            C.closesocket(sock)
            return nil, "WSACreateEvent failed: " .. e
        end
        if C.WSAEventSelect(sock, ev, FD_ALL) ~= 0 then
            local e = wsa_err()
            C.WSACloseEvent(ev); C.closesocket(sock)
            return nil, "WSAEventSelect failed: " .. e
        end
        local addr = ffi.new("async_sockaddr_in")
        addr.sin_family = AF_INET
        addr.sin_port   = C.htons(port)
        addr.sin_addr   = C.inet_addr(host)
        return setmetatable(
            { handle = sock, event = ev,
              kind = is_server and "server" or "client",
              addr = addr },
            tcp_mt)
    end

    M.tcp = {}

    function M.tcp.connect(host, port)
        local s, err = make_socket(host, port, false)
        if not s then return nil, err end
        local addr_len = ffi.sizeof("async_sockaddr_in")
        while true do
            local rraw = C.connect(s.handle, s.addr, addr_len)
            local last_err = wsa_err()
            local r = tonumber(rraw)
            if r == 0 then return s end
            if last_err == WSAEISCONN then return s end
            if last_err ~= WSAEWOULDBLOCK and last_err ~= WSAEALREADY then
                s:close()
                return nil, "connect failed: " .. last_err
            end
            wait_socket(s)
            -- check SO_ERROR to see if connect actually succeeded
            local sockerr = ffi.new("int[1]")
            local elen    = ffi.new("int[1]"); elen[0] = ffi.sizeof("int")
            if C.getsockopt(s.handle, SOL_SOCKET, SO_ERROR,
                            ffi.cast("char*", sockerr), elen) == 0
                    and sockerr[0] == 0 then
                return s
            end
        end
    end

    function M.tcp.listen(host, port, backlog)
        local s, err = make_socket(host, port, true)
        if not s then return nil, err end
        local on = ffi.new("int[1]"); on[0] = 1
        C.setsockopt(s.handle, SOL_SOCKET, SO_REUSEADDR,
                     ffi.cast("const char*", on), ffi.sizeof("int"))
        local addr_len = ffi.sizeof("async_sockaddr_in")
        if C.bind(s.handle, s.addr, addr_len) ~= 0 then
            local e = wsa_err()
            s:close()
            return nil, "bind failed: " .. e
        end
        if C.listen(s.handle, backlog or 8) ~= 0 then
            local e = wsa_err()
            s:close()
            return nil, "listen failed: " .. e
        end
        return s
    end

    -- ===== UDP sockets ==============================================
    --
    -- Connectionless. recvfrom/sendto carry per-datagram peer addresses.
    -- We expose host/port as "1.2.3.4" / number pairs; conversion uses
    -- inet_addr / htons (in) and ntohl-of-sin_addr / ntohs-of-sin_port
    -- (out). No DNS, IPv4 only -- matches the TCP scope above.

    local udp_mt = { __index = {} }
    local udp_methods = udp_mt.__index

    -- Format a packed IPv4 (network-order uint32) as "a.b.c.d".
    local function format_ipv4(net_order_uint32)
        local h = tonumber(C.ntohl(net_order_uint32))
        return string.format("%d.%d.%d.%d",
            (h >> 24) & 0xFF, (h >> 16) & 0xFF,
            (h >>  8) & 0xFF,  h        & 0xFF)
    end

    function udp_methods:recvfrom(n)
        if self.handle == nil then return nil, "socket closed" end
        n = n or 4096
        local buf  = ffi.new("char[?]", n)
        local addr = ffi.new("async_sockaddr_in")
        local alen = ffi.new("int[1]"); alen[0] = ffi.sizeof("async_sockaddr_in")
        while true do
            local rraw = C.recvfrom(self.handle, buf, n, 0, addr, alen)
            local last_err = wsa_err()
            local got = tonumber(rraw)
            if got >= 0 then
                return ffi.string(buf, got),
                       format_ipv4(addr.sin_addr),
                       tonumber(C.ntohs(addr.sin_port))
            elseif last_err == WSAEWOULDBLOCK then
                wait_socket(self)
            else
                return nil, "recvfrom error " .. last_err
            end
        end
    end

    function udp_methods:sendto(data, host, port)
        if self.handle == nil then return nil, "socket closed" end
        local addr = ffi.new("async_sockaddr_in")
        addr.sin_family = AF_INET
        addr.sin_port   = C.htons(port)
        addr.sin_addr   = C.inet_addr(host)
        local n = #data
        while true do
            local rraw = C.sendto(self.handle, data, n, 0, addr,
                                  ffi.sizeof("async_sockaddr_in"))
            local last_err = wsa_err()
            local r = tonumber(rraw)
            if r >= 0 then return r end
            if last_err == WSAEWOULDBLOCK then
                wait_socket(self)
            else
                return nil, "sendto error " .. last_err
            end
        end
    end

    -- close + handle reuse the TCP implementations
    udp_methods.close = tcp_methods.close

    M.udp = {}

    -- async.udp.open(host, port): create a UDP socket bound to host:port
    -- (use "0.0.0.0" and 0 for unconnected client; specific port to listen).
    function M.udp.open(host, port)
        local sock = C.socket(AF_INET, 2 --[[SOCK_DGRAM]], 17 --[[IPPROTO_UDP]])
        if is_invalid_socket(sock) then
            return nil, "socket() failed: " .. wsa_err()
        end
        local ev = C.WSACreateEvent()
        if ev == INVALID_HANDLE then
            local e = wsa_err()
            C.closesocket(sock)
            return nil, "WSACreateEvent failed: " .. e
        end
        if C.WSAEventSelect(sock, ev, FD_ALL) ~= 0 then
            local e = wsa_err()
            C.WSACloseEvent(ev); C.closesocket(sock)
            return nil, "WSAEventSelect failed: " .. e
        end
        local addr = ffi.new("async_sockaddr_in")
        addr.sin_family = AF_INET
        addr.sin_port   = C.htons(port or 0)
        addr.sin_addr   = C.inet_addr(host or "0.0.0.0")
        if C.bind(sock, addr, ffi.sizeof("async_sockaddr_in")) ~= 0 then
            local e = wsa_err()
            C.WSACloseEvent(ev); C.closesocket(sock)
            return nil, "bind failed: " .. e
        end
        return setmetatable(
            { handle = sock, event = ev, kind = "udp" },
            udp_mt)
    end

    -- ===== subprocess pipes =========================================
    --
    -- async.spawn(cmdline) → process object
    --   :read(n)       — read up to n bytes of child stdout (yields if no data)
    --   :wait()        — yield until child exits; returns exit code
    --   :close()       — close pipe + process handles
    --
    -- Reads use polling: PeekNamedPipe to check availability + async.sleep
    -- between attempts. Not zero-latency but correct, and simple -- truly
    -- async pipe reads on Windows require named pipes with OVERLAPPED,
    -- which is more setup than this preload needs to justify.
    -- :wait() IS truly async: the process handle goes into the event loop's
    -- wait set and signals on exit.

    local WAIT_OBJECT_0_LOCAL = 0
    local STARTF_USESTDHANDLES = 0x100

    local proc_mt = { __index = {} }
    local proc_methods = proc_mt.__index

    function proc_methods:read(n)
        if self.pipe_r == nil then return nil, "process closed" end
        n = n or 4096
        local buf  = ffi.new("char[?]", n)
        local got  = ffi.new("async_DWORD[1]")
        local avail = ffi.new("async_DWORD[1]")
        while true do
            if C.PeekNamedPipe(self.pipe_r, nil, 0, nil, avail, nil) == 0 then
                local e = tonumber(C.GetLastError())
                if e == ERROR_BROKEN_PIPE then return nil, "eof" end
                return nil, "PeekNamedPipe failed: " .. e
            end
            local a = tonumber(avail[0])
            if a > 0 then
                local want = ( a < n ) and a or n
                if C.ReadFile(self.pipe_r, buf, want, got, nil) == 0 then
                    local e = tonumber(C.GetLastError())
                    if e == ERROR_BROKEN_PIPE then return nil, "eof" end
                    return nil, "ReadFile failed: " .. e
                end
                return ffi.string(buf, tonumber(got[0]))
            end
            -- no data yet -- check if process exited (then drain any
            -- last bytes; PeekNamedPipe == 0 once both pipe + child gone)
            if tonumber(C.WaitForSingleObject(self.process, 0)) == WAIT_OBJECT_0_LOCAL then
                -- child exited; one more peek for trailing bytes
                if C.PeekNamedPipe(self.pipe_r, nil, 0, nil, avail, nil) ~= 0
                        and tonumber(avail[0]) == 0 then
                    return nil, "eof"
                end
                -- fall through to read trailing data
            else
                M.sleep(10)
            end
        end
    end

    function proc_methods:wait()
        if self.process == nil then return nil, "process closed" end
        coroutine.yield({ kind = "io", event = self.process })
        local code = ffi.new("async_DWORD[1]")
        if C.GetExitCodeProcess(self.process, code) == 0 then
            return nil, "GetExitCodeProcess failed: " .. tonumber(C.GetLastError())
        end
        return tonumber(code[0])
    end

    -- Write to the child's stdin. Synchronous WriteFile; assumes the pipe
    -- buffer can absorb our writes (true for small interactive commands).
    -- Only available if spawn(..., {stdin=true}) was used.
    function proc_methods:write(data)
        if self.pipe_w == nil then return nil, "stdin pipe not opened" end
        local n   = #data
        local got = ffi.new("async_DWORD[1]")
        -- WriteFile's 2nd arg is const void*; our marshaler only converts
        -- strings to char*/wchar_t*, not void*, and ffi.cast doesn't
        -- accept strings either. Copy the Lua string into a char buffer
        -- and pass that -- char* converts to void* fine.
        local buf = ffi.new("char[?]", n)
        ffi.copy(buf, data, n)
        if C.WriteFile(self.pipe_w, buf, n, got, nil) == 0 then
            return nil, "WriteFile failed: " .. tonumber(C.GetLastError())
        end
        return tonumber(got[0])
    end

    function proc_methods:close()
        if self.pipe_r ~= nil then C.CloseHandle(self.pipe_r); self.pipe_r = nil end
        if self.pipe_w ~= nil then C.CloseHandle(self.pipe_w); self.pipe_w = nil end
        if self.process ~= nil then C.CloseHandle(self.process); self.process = nil end
        if self.thread ~= nil then C.CloseHandle(self.thread); self.thread = nil end
    end

    -- async.spawn(cmdline, opts):
    --   opts.stdin = true  also open a stdin pipe and expose proc:write()
    function M.spawn(cmdline, opts)
        opts = opts or {}
        local sa = ffi.new("async_SECURITY_ATTRIBUTES")
        sa.nLength = ffi.sizeof("async_SECURITY_ATTRIBUTES")
        sa.lpSecurityDescriptor = nil
        sa.bInheritHandle = 1

        -- stdout pipe (child -> parent)
        local out_r_arr = ffi.new("async_HANDLE[1]")
        local out_w_arr = ffi.new("async_HANDLE[1]")
        if C.CreatePipe(out_r_arr, out_w_arr, sa, 0) == 0 then
            return nil, "CreatePipe(stdout) failed: " .. tonumber(C.GetLastError())
        end
        local out_r = out_r_arr[0]
        local out_w = out_w_arr[0]

        -- optional stdin pipe (parent -> child)
        local in_r, in_w = nil, nil
        if opts.stdin then
            local in_r_arr = ffi.new("async_HANDLE[1]")
            local in_w_arr = ffi.new("async_HANDLE[1]")
            if C.CreatePipe(in_r_arr, in_w_arr, sa, 0) == 0 then
                local e = tonumber(C.GetLastError())
                C.CloseHandle(out_r); C.CloseHandle(out_w)
                return nil, "CreatePipe(stdin) failed: " .. e
            end
            in_r = in_r_arr[0]
            in_w = in_w_arr[0]
        end

        local si = ffi.new("async_STARTUPINFOA")
        si.cb         = ffi.sizeof("async_STARTUPINFOA")
        si.dwFlags    = STARTF_USESTDHANDLES
        si.hStdOutput = out_w
        si.hStdError  = out_w
        si.hStdInput  = in_r or INVALID_HANDLE
        local pi = ffi.new("async_PROCESS_INFORMATION")

        -- CreateProcessA needs a mutable command-line buffer
        local cmdbuf = ffi.new("char[?]", #cmdline + 1)
        ffi.copy(cmdbuf, cmdline)

        if C.CreateProcessA(nil, cmdbuf, nil, nil, 1, 0, nil, nil, si, pi) == 0 then
            local e = tonumber(C.GetLastError())
            C.CloseHandle(out_r); C.CloseHandle(out_w)
            if in_r ~= nil then C.CloseHandle(in_r); C.CloseHandle(in_w) end
            return nil, "CreateProcess failed: " .. e
        end
        -- Close handles the child inherited but we no longer need locally:
        --   out_w: parent's write end of stdout pipe -- child has its own copy
        --   in_r:  parent's read end of stdin pipe   -- child has its own copy
        -- Without these closes, the corresponding EOFs are never observed
        -- (the parent still holds a write/read end so the kernel keeps the
        -- pipe open even after the child exits).
        C.CloseHandle(out_w)
        if in_r ~= nil then C.CloseHandle(in_r) end

        return setmetatable({
            process = pi.hProcess,
            thread  = pi.hThread,
            pipe_r  = out_r,
            pipe_w  = in_w,        -- nil unless opts.stdin was set
            pid     = tonumber(pi.dwProcessId),
        }, proc_mt)
    end

    -- ===== event loop =================================================
    --
    -- Drives all tasks. On each iteration:
    --   1. partition tasks into ready (run-now) / time-waiting / io-waiting
    --   2. if any ready, skip the wait
    --   3. otherwise WaitForMultipleObjects(io_handles, timeout=next_time)
    --   4. resume signalled / expired tasks, install new waits from their
    --      yield value, remove dead ones

    local function compact_tasks()
        local j = 1
        for i = 1, #g_tasks do
            if g_tasks[i].kind ~= "dead" then
                if j ~= i then g_tasks[j] = g_tasks[i] end
                j = j + 1
            end
        end
        for i = j, #g_tasks do g_tasks[i] = nil end
    end

    local function install_wait(t, yielded)
        if type(yielded) == "table" and yielded.kind then
            t.kind = yielded.kind
            if yielded.kind == "time" then
                t.data = tonumber(yielded.until_ms) or tick()
            elseif yielded.kind == "io" then
                t.data = yielded.event
            elseif yielded.kind == "ready" then
                t.data = 0
            else
                t.kind = "ready"; t.data = 0
            end
        elseif type(yielded) == "number" then
            t.kind = "time"; t.data = yielded  -- legacy: number = until_ms
        else
            t.kind = "ready"; t.data = 0
        end
    end

    function M.event_loop()
        if g_inside_loop then error("async.event_loop: already running") end
        g_inside_loop = true
        while #g_tasks > 0 do
            local now = tick()
            local ready_idx = {}
            local next_time = nil
            local wait_handles = {}
            local wait_task_idx = {}

            for i, t in ipairs(g_tasks) do
                if t.kind == "ready" then
                    ready_idx[#ready_idx + 1] = i
                elseif t.kind == "time" then
                    if now >= t.data then
                        ready_idx[#ready_idx + 1] = i
                    else
                        if next_time == nil or t.data < next_time then
                            next_time = t.data
                        end
                    end
                elseif t.kind == "io" then
                    wait_handles[#wait_handles + 1] = t.data
                    wait_task_idx[#wait_task_idx + 1] = i
                end
            end

            if #ready_idx == 0 then
                local wcount = #wait_handles
                if wcount > 64 then wcount = 64 end -- WfMO MAXIMUM_WAIT_OBJECTS
                if wcount > 0 then
                    local timeout
                    if next_time ~= nil then
                        local d = next_time - now
                        if d < 0 then d = 0 end
                        timeout = d
                    else
                        timeout = 0xFFFFFFFF -- INFINITE
                    end
                    local arr = ffi.new("async_HANDLE[?]", wcount)
                    for i = 1, wcount do arr[i - 1] = wait_handles[i] end
                    local r = tonumber(C.WaitForMultipleObjects(
                                          wcount, arr, 0, timeout))
                    if r ~= WAIT_TIMEOUT and r < wcount then
                        ready_idx[#ready_idx + 1] = wait_task_idx[r + 1]
                    end
                    -- collect any time-expired tasks too
                    now = tick()
                    for i, t in ipairs(g_tasks) do
                        if t.kind == "time" and now >= t.data then
                            local dup = false
                            for _, j in ipairs(ready_idx) do
                                if j == i then dup = true; break end
                            end
                            if not dup then
                                ready_idx[#ready_idx + 1] = i
                            end
                        end
                    end
                elseif next_time ~= nil then
                    local d = next_time - now
                    if d > 0 then C.Sleep(d) end
                else
                    C.Sleep(1)
                end
            end

            -- resume in a snapshot to avoid issues if resume calls async.run
            local snapshot = {}
            for k = 1, #ready_idx do snapshot[k] = g_tasks[ready_idx[k]] end
            for _, t in ipairs(snapshot) do
                if t ~= nil and coroutine.status(t.co) ~= "dead" then
                    local ok, val = coroutine.resume(t.co)
                    if not ok then
                        g_inside_loop = false
                        error(tostring(val))
                    end
                    if coroutine.status(t.co) == "dead" then
                        t.kind = "dead"; t.data = 0
                    else
                        install_wait(t, val)
                    end
                end
            end

            compact_tasks()
        end
        g_inside_loop = false
    end

    return M
end

return MakeAsync()
