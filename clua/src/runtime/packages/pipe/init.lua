-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- pipe -- Win32 anonymous + named pipes.
--
-- Public surface:
--   pipe.anon(opts?)                      -> read_handle, write_handle
--   pipe.named_server(name, opts?)        -> server (with :accept(), :close())
--   pipe.named_client(name, opts?)        -> pipe
--   pipe object:
--     :read(n) -> string | nil, "eof"|err
--     :write(bytes) -> nbytes | nil, err
--     :close()
--     :handle()  -- raw cdata HANDLE (e.g. to pass to WaitForSingleObject)
--
-- Pipe naming convention: callers pass just the leaf name, e.g.
-- "clua_demo"; this module prepends "\\\\.\\pipe\\" automatically. Pass
-- the full \\.\pipe\foo path if you need an unusual one (we don't try
-- to be clever about detecting that).

local W = require "windows"

ffi.cdef[[
BOOL CreatePipe(HANDLE *hReadPipe, HANDLE *hWritePipe,
                SECURITY_ATTRIBUTES *lpPipeAttributes, DWORD nSize);
HANDLE CreateNamedPipeW(LPCWSTR lpName, DWORD dwOpenMode, DWORD dwPipeMode,
                        DWORD nMaxInstances, DWORD nOutBufSize,
                        DWORD nInBufSize, DWORD nDefaultTimeOut,
                        SECURITY_ATTRIBUTES *lpSecurityAttributes);
BOOL ConnectNamedPipe(HANDLE hNamedPipe, OVERLAPPED *lpOverlapped);
BOOL DisconnectNamedPipe(HANDLE hNamedPipe);
BOOL WaitNamedPipeW(LPCWSTR lpNamedPipeName, DWORD nTimeOut);
BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
]]

local C = ffi.C
local M = {}

-- ===== constants ========================================================

local PIPE_ACCESS_INBOUND  = 0x00000001
local PIPE_ACCESS_OUTBOUND = 0x00000002
local PIPE_ACCESS_DUPLEX   = 0x00000003

local PIPE_TYPE_BYTE       = 0x00000000
local PIPE_TYPE_MESSAGE    = 0x00000004
local PIPE_READMODE_BYTE   = 0x00000000
local PIPE_READMODE_MSG    = 0x00000002
local PIPE_WAIT            = 0x00000000

local PIPE_UNLIMITED_INSTANCES = 255

local NMPWAIT_USE_DEFAULT_WAIT = 0
local NMPWAIT_WAIT_FOREVER     = 0xFFFFFFFF

local HANDLE_FLAG_INHERIT = 0x00000001

local INVALID_HANDLE = W.INVALID_HANDLE_VALUE
local ERROR_PIPE_CONNECTED = 535

-- ===== pipe object ======================================================

local pipe_mt = { __index = {} }
local pipe_methods = pipe_mt.__index

function pipe_methods:read(n)
    if self.handle == nil then return nil, "pipe closed" end
    n = n or 4096
    local buf = ffi.new("char[?]", n)
    local got = ffi.new("DWORD[1]")
    if C.ReadFile(self.handle, buf, n, got, nil) == 0 then
        local e = tonumber(C.GetLastError())
        -- 109 = ERROR_BROKEN_PIPE (peer closed), 38 = ERROR_HANDLE_EOF
        if e == 109 or e == 38 then return nil, "eof" end
        return nil, "ReadFile failed: " .. e
    end
    local bytes = tonumber(got[0])
    if bytes == 0 then return nil, "eof" end
    return ffi.string(buf, bytes)
end

function pipe_methods:write(data)
    if self.handle == nil then return nil, "pipe closed" end
    local n = #data
    local got = ffi.new("DWORD[1]")
    -- WriteFile takes const void*; ffi marshals strings to const char*
    -- which converts implicitly. Copy to a buffer if you hit issues with
    -- the JIT folding the constant out from under you.
    local buf = ffi.new("char[?]", n)
    ffi.copy(buf, data, n)
    if C.WriteFile(self.handle, buf, n, got, nil) == 0 then
        return nil, "WriteFile failed: " .. tonumber(C.GetLastError())
    end
    return tonumber(got[0])
end

function pipe_methods:close()
    if self.handle ~= nil then
        C.CloseHandle(self.handle)
        self.handle = nil
    end
end

function pipe_methods:handle() return self.handle end

local function wrap(handle)
    return setmetatable({ handle = handle }, pipe_mt)
end

-- ===== anonymous pipes ==================================================

function M.anon(opts)
    opts = opts or {}
    local rh = ffi.new("HANDLE[1]")
    local wh = ffi.new("HANDLE[1]")
    local sa = ffi.new("SECURITY_ATTRIBUTES")
    sa.nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
    sa.lpSecurityDescriptor = nil
    -- default: handles ARE inheritable (matches POSIX expectation
    -- and the common subprocess-pipe usage). Pass inheritable=false
    -- to explicitly opt out (rare; useful for sandboxing).
    sa.bInheritHandle = (opts.inheritable == false) and 0 or 1
    local size = opts.buffer_size or 0  -- 0 = system default (~4 KB)
    if C.CreatePipe(rh, wh, sa, size) == 0 then
        return nil, nil, "CreatePipe failed: " .. tonumber(C.GetLastError())
    end
    return wrap(rh[0]), wrap(wh[0])
end

-- ===== named pipes ======================================================

local function normalize_name(name)
    -- Allow callers to pass the leaf only and prepend the \\.\pipe\ prefix.
    if name:sub(1, 9) == "\\\\.\\pipe\\" or name:sub(1, 2) == "\\\\" then
        return name
    end
    return "\\\\.\\pipe\\" .. name
end

-- Server: accept() blocks until a client connects, then returns a pipe
-- object hooked to that client. Multiple :accept() calls on a one-shot
-- server are illegal -- you must call named_server again (or pass
-- max_instances > 1 and pre-create the next listener inside :accept()).

local server_mt = { __index = {} }
local server_methods = server_mt.__index

function server_methods:accept()
    if self.handle == nil then return nil, "server closed" end
    -- ConnectNamedPipe with nil OVERLAPPED blocks until a client
    -- connects. ERROR_PIPE_CONNECTED means a client connected between
    -- CreateNamedPipeW and ConnectNamedPipe -- still a successful
    -- accept, just slightly racier than expected.
    if C.ConnectNamedPipe(self.handle, nil) == 0 then
        local e = tonumber(C.GetLastError())
        if e ~= ERROR_PIPE_CONNECTED then
            return nil, "ConnectNamedPipe failed: " .. e
        end
    end
    -- Hand the live connection off to the caller; null our own handle so
    -- :close() won't double-disconnect. The caller's :close() will tear
    -- down both ends.
    local h = self.handle
    self.handle = nil
    return wrap(h)
end

function server_methods:close()
    if self.handle ~= nil then
        C.DisconnectNamedPipe(self.handle)
        C.CloseHandle(self.handle)
        self.handle = nil
    end
end

function server_methods:handle() return self.handle end

function M.named_server(name, opts)
    opts = opts or {}
    local full = normalize_name(name)
    local wname = W.ToWide(full)
    local open_mode = opts.duplex == false
        and PIPE_ACCESS_INBOUND or PIPE_ACCESS_DUPLEX
    local pipe_mode = PIPE_TYPE_BYTE + PIPE_READMODE_BYTE + PIPE_WAIT
    if opts.message_mode then
        pipe_mode = PIPE_TYPE_MESSAGE + PIPE_READMODE_MSG + PIPE_WAIT
    end
    local max_inst = opts.max_instances or PIPE_UNLIMITED_INSTANCES
    local buf_size = opts.buffer_size or 4096
    local h = C.CreateNamedPipeW(wname, open_mode, pipe_mode, max_inst,
                                 buf_size, buf_size, 0, nil)
    if h == INVALID_HANDLE then
        return nil, "CreateNamedPipeW failed: " .. tonumber(C.GetLastError())
    end
    return setmetatable({ handle = h, name = full }, server_mt)
end

-- Client: open the pipe like a regular file. Block until the pipe is
-- available (or until timeout_ms elapses).

local GENERIC_READ  = 0x80000000
local GENERIC_WRITE = 0x40000000
local OPEN_EXISTING = 3

function M.named_client(name, opts)
    opts = opts or {}
    local full = normalize_name(name)
    local wname = W.ToWide(full)
    -- Wait for the server side to become available. Win32 returns ERROR_
    -- PIPE_BUSY (231) from CreateFile if all server instances are busy;
    -- WaitNamedPipe blocks until one frees up.
    local timeout = opts.timeout_ms or NMPWAIT_USE_DEFAULT_WAIT
    -- WaitNamedPipeW is best-effort: if the pipe doesn't exist yet,
    -- it returns 0 with ERROR_FILE_NOT_FOUND (2). We don't treat that
    -- as fatal -- the CreateFile call below will surface the real error.
    C.WaitNamedPipeW(wname, timeout)
    local access = opts.read_only and GENERIC_READ
        or (opts.write_only and GENERIC_WRITE)
        or bit.bor(GENERIC_READ, GENERIC_WRITE)
    local h = C.CreateFileW(wname, access, 0, nil, OPEN_EXISTING, 0, nil)
    if h == INVALID_HANDLE then
        return nil, "CreateFileW failed: " .. tonumber(C.GetLastError())
    end
    return wrap(h)
end

-- ===== misc =============================================================

-- Toggle the inheritable-by-child-process flag on a pipe handle. Useful
-- when an anonymous pipe needs only ONE of its two ends inherited (the
-- canonical subprocess-pipe pattern: parent keeps the non-inheritable
-- end, child gets the inheritable one).
function M.set_inheritable(p, on)
    if p == nil or p.handle == nil then return false, "closed" end
    local mask = HANDLE_FLAG_INHERIT
    local flags = on and HANDLE_FLAG_INHERIT or 0
    if C.SetHandleInformation(p.handle, mask, flags) == 0 then
        return false, "SetHandleInformation failed: " .. tonumber(C.GetLastError())
    end
    return true
end

return M
