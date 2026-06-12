-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- process -- spawn / wait / kill / I/O wrapper over CreateProcessW.
--
-- The async package has a (more primitive) spawn helper for its event-
-- loop world. process exists for the synchronous case: scripts that just
-- want to run a child to completion, capture its output, or stream
-- input to it without setting up a coroutine scheduler.
--
-- Public surface:
--   process.spawn(cmd_or_argv, opts?)    -> proc
--   process.run(cmd, opts?)              -> { exit_code, stdout, stderr }
--   process.popen(cmd, mode?)            -> file-like object
--
-- proc methods:
--   :wait(timeout_ms?)   -> exit_code | nil, "timeout"
--   :kill(exit_code?)
--   :pid()
--   :read_stdout(n?)     -> string | nil, "eof"
--   :read_stderr(n?)
--   :write_stdin(bytes)  -> nbytes
--   :close_stdin()
--   :is_running()        -> bool
--   :exit_code()         -> int | nil  (nil if still running)
--
-- opts table:
--   stdin   = "pipe" | "inherit" | "null" | <bytes>     default "inherit"
--   stdout  = "pipe" | "inherit" | "null"               default "inherit"
--   stderr  = "pipe" | "inherit" | "null" | "merge_with_stdout"
--                                                       default "inherit"
--   cwd     = path string                               default current cwd
--   env     = { K=V, ... } | nil                        default inherited
--   hide_window = bool                                  default false
--   detached    = bool                                  default false
--   timeout_ms  = number (used by run() only)

local W = require "windows"

ffi.cdef[[
BOOL CreatePipe(HANDLE *hReadPipe, HANDLE *hWritePipe,
                SECURITY_ATTRIBUTES *lpPipeAttributes, DWORD nSize);
BOOL PeekNamedPipe(HANDLE hNamedPipe, void *lpBuffer, DWORD nBufferSize,
                   DWORD *lpBytesRead, DWORD *lpTotalBytesAvail,
                   DWORD *lpBytesLeftThisMessage);
BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
HANDLE GetStdHandle(DWORD nStdHandle);
]]

local C = ffi.C
local M = {}

-- ===== flags ============================================================

local STARTF_USESTDHANDLES = 0x00000100
local STARTF_USESHOWWINDOW = 0x00000001
local CREATE_NO_WINDOW     = 0x08000000
local DETACHED_PROCESS     = 0x00000008
local CREATE_UNICODE_ENVIRONMENT = 0x00000400
local HANDLE_FLAG_INHERIT  = 0x00000001
local STD_INPUT  = 0xFFFFFFF6
local STD_OUTPUT = 0xFFFFFFF5
local STD_ERROR  = 0xFFFFFFF4
local INFINITE   = 0xFFFFFFFF
local WAIT_OBJECT_0 = 0
local WAIT_TIMEOUT  = 0x102
local STILL_ACTIVE  = 259
local ERROR_BROKEN_PIPE = 109

local INVALID_HANDLE = W.INVALID_HANDLE_VALUE

-- ===== command-line quoting =============================================
--
-- CreateProcessW takes a single mutable command-line buffer. When the
-- caller passes a Lua table (argv form) we need to reconstruct the
-- Windows command-line escaping per "Parsing C++ Command-Line Arguments"
-- (MSVCRT rules). Arguments without whitespace or quotes pass through;
-- otherwise we wrap in double-quotes and double up internal quotes /
-- escape trailing backslashes.

local function needs_quoting(s)
    if #s == 0 then return true end
    return s:find("[ \t\"\n\v]") ~= nil
end

local function quote_arg(s)
    if not needs_quoting(s) then return s end
    local out = { '"' }
    local i, n = 1, #s
    while i <= n do
        local bs = 0
        while i <= n and s:byte(i) == 92 do  -- backslash
            bs = bs + 1; i = i + 1
        end
        if i > n then
            -- trailing backslashes: double them so the closing quote is
            -- not escaped
            out[#out + 1] = string.rep("\\", bs * 2)
            break
        elseif s:byte(i) == 34 then  -- double-quote
            out[#out + 1] = string.rep("\\", bs * 2 + 1) .. '"'
            i = i + 1
        else
            out[#out + 1] = string.rep("\\", bs) .. s:sub(i, i)
            i = i + 1
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function build_cmdline(argv)
    local parts = {}
    for i = 1, #argv do parts[i] = quote_arg(argv[i]) end
    return table.concat(parts, " ")
end

-- ===== environment block builder ========================================
--
-- The CreateProcessW lpEnvironment block is a sequence of "NAME=VALUE\0"
-- UTF-16 strings, terminated by an extra null (so two consecutive nulls
-- mark end of block).

local function build_env_block(t)
    if t == nil then return nil end
    local pieces = {}
    -- Win32 documents env-block keys as sorted; the launcher doesn't
    -- enforce it but cmd.exe and PowerShell both expect ordered keys.
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return string.lower(a) < string.lower(b) end)
    for _, k in ipairs(keys) do
        pieces[#pieces + 1] = k .. "=" .. tostring(t[k])
    end
    -- Compute total wide-char count: each piece + null, plus a final null.
    local total = 1  -- final null
    local widens = {}
    for i, p in ipairs(pieces) do
        local wbuf, wlen = W.ToWide(p)
        widens[i] = { buf = wbuf, len = wlen }  -- wlen includes its own null
        total = total + wlen
    end
    local block = ffi.new("unsigned short[?]", total)
    local off = 0
    for _, w in ipairs(widens) do
        ffi.copy(block + off, w.buf, w.len * 2)
        off = off + w.len
    end
    block[off] = 0  -- final terminating null
    return block
end

-- ===== pipe plumbing for stdin / stdout / stderr =======================
--
-- For each of the three streams we either:
--   - create a pipe (parent keeps one end, child inherits the other)
--   - pass INVALID_HANDLE so the child has no I/O on that stream
--   - reuse the parent's std handle (inherit)
--
-- Pipe inheritance: CreatePipe gives both ends the inheritable flag from
-- SECURITY_ATTRIBUTES. We then turn it OFF on the parent-side end so
-- the child can't accidentally get duplicates of our pipe handles --
-- this is the recipe MSDN's CreateProcess sample uses.

local function make_inheritable_sa()
    local sa = ffi.new("SECURITY_ATTRIBUTES")
    sa.nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
    sa.lpSecurityDescriptor = nil
    sa.bInheritHandle = 1
    return sa
end

local function open_null()
    -- "NUL" is the Windows null device. CreateFileW with GENERIC_READ
    -- gets a read-from-empty handle; GENERIC_WRITE gets a discard-all
    -- handle. We give both directions GENERIC_READ|WRITE -- works for
    -- either side and we never actually touch the handle from Lua.
    local name = W.ToWide("NUL")
    local h = C.CreateFileW(name, 0x80000000 + 0x40000000,
                            0x00000001 + 0x00000002,  -- FILE_SHARE_READ|WRITE
                            make_inheritable_sa(),
                            3 --[[ OPEN_EXISTING ]], 0, nil)
    return h
end

local function setup_stream(spec, kind)
    -- kind: "in" | "out" | "err"
    -- Returns: parent_handle (or nil), child_handle, inheritable_child_flag
    if spec == "inherit" or spec == nil then
        local code = (kind == "in") and STD_INPUT
                   or (kind == "out") and STD_OUTPUT
                   or STD_ERROR
        return nil, C.GetStdHandle(code), false
    elseif spec == "null" then
        return nil, open_null(), true
    elseif spec == "pipe" or type(spec) == "string" and spec:sub(1,4) == "pipe" then
        local rh = ffi.new("HANDLE[1]")
        local wh = ffi.new("HANDLE[1]")
        local sa = make_inheritable_sa()
        if C.CreatePipe(rh, wh, sa, 0) == 0 then
            error("CreatePipe failed: " .. tonumber(C.GetLastError()))
        end
        if kind == "in" then
            -- child reads from rh; we keep wh (and mark it non-inheritable)
            C.SetHandleInformation(wh[0], HANDLE_FLAG_INHERIT, 0)
            return wh[0], rh[0], true
        else
            -- child writes to wh; we keep rh
            C.SetHandleInformation(rh[0], HANDLE_FLAG_INHERIT, 0)
            return rh[0], wh[0], true
        end
    elseif type(spec) == "table" and spec.is_pipe_handle then
        -- pre-built pipe (from the pipe package)
        return nil, spec.handle, true
    else
        error("invalid stream spec: " .. tostring(spec))
    end
end

-- ===== proc object ======================================================

local proc_mt = { __index = {} }
local proc_methods = proc_mt.__index

function proc_methods:pid()        return self._pid end
function proc_methods:handle()     return self.process end

function proc_methods:is_running()
    if self.process == nil then return false end
    local code = ffi.new("DWORD[1]")
    if C.GetExitCodeProcess(self.process, code) == 0 then return false end
    return tonumber(code[0]) == STILL_ACTIVE
end

function proc_methods:exit_code()
    if self.process == nil then return nil end
    local code = ffi.new("DWORD[1]")
    if C.GetExitCodeProcess(self.process, code) == 0 then return nil end
    local c = tonumber(code[0])
    if c == STILL_ACTIVE then return nil end
    return c
end

function proc_methods:wait(timeout_ms)
    if self.process == nil then return self._cached_exit_code end
    local r = tonumber(C.WaitForSingleObject(self.process,
        timeout_ms or INFINITE))
    if r == WAIT_TIMEOUT then return nil, "timeout" end
    if r ~= WAIT_OBJECT_0 then
        return nil, "WaitForSingleObject returned " .. r
    end
    local code = ffi.new("DWORD[1]")
    if C.GetExitCodeProcess(self.process, code) == 0 then
        return nil, "GetExitCodeProcess failed: " .. tonumber(C.GetLastError())
    end
    self._cached_exit_code = tonumber(code[0])
    return self._cached_exit_code
end

function proc_methods:kill(exit_code)
    if self.process == nil then return end
    C.TerminateProcess(self.process, exit_code or 1)
end

local function read_handle(h, n)
    if h == nil then return nil, "pipe not open" end
    n = n or 4096
    local buf = ffi.new("char[?]", n)
    local got = ffi.new("DWORD[1]")
    if C.ReadFile(h, buf, n, got, nil) == 0 then
        local e = tonumber(C.GetLastError())
        if e == ERROR_BROKEN_PIPE then return nil, "eof" end
        return nil, "ReadFile failed: " .. e
    end
    local bytes = tonumber(got[0])
    if bytes == 0 then return nil, "eof" end
    return ffi.string(buf, bytes)
end

function proc_methods:read_stdout(n) return read_handle(self.stdout_r, n) end
function proc_methods:read_stderr(n) return read_handle(self.stderr_r, n) end

-- Ergonomic aliases so callers can use the same conn-style methods
-- they're used to from socket / popen:
--   child:read(n)  == child:read_stdout(n)
--   child:write(s) == child:write_stdin(s)
function proc_methods:read(n)         return read_handle(self.stdout_r, n) end
function proc_methods:write(data)     return self:write_stdin(data) end

function proc_methods:write_stdin(data)
    if self.stdin_w == nil then return nil, "stdin not piped" end
    local n = #data
    local got = ffi.new("DWORD[1]")
    local buf = ffi.new("char[?]", n)
    ffi.copy(buf, data, n)
    if C.WriteFile(self.stdin_w, buf, n, got, nil) == 0 then
        return nil, "WriteFile failed: " .. tonumber(C.GetLastError())
    end
    return tonumber(got[0])
end

function proc_methods:close_stdin()
    if self.stdin_w ~= nil then
        C.CloseHandle(self.stdin_w)
        self.stdin_w = nil
    end
end

function proc_methods:close()
    if self.stdin_w  ~= nil then C.CloseHandle(self.stdin_w);  self.stdin_w  = nil end
    if self.stdout_r ~= nil then C.CloseHandle(self.stdout_r); self.stdout_r = nil end
    if self.stderr_r ~= nil then C.CloseHandle(self.stderr_r); self.stderr_r = nil end
    if self.process  ~= nil then C.CloseHandle(self.process);  self.process  = nil end
    if self.thread   ~= nil then C.CloseHandle(self.thread);   self.thread   = nil end
end

-- ===== spawn ============================================================

function M.spawn(cmd_or_argv, opts)
    opts = opts or {}

    -- Build the command line. Two acceptable forms:
    --   - string: passed through verbatim
    --   - table : first entry is the program, rest are args (we quote them)
    local cmdline
    if type(cmd_or_argv) == "string" then
        cmdline = cmd_or_argv
    elseif type(cmd_or_argv) == "table" then
        cmdline = build_cmdline(cmd_or_argv)
    else
        error("process.spawn: cmd must be string or table")
    end

    -- Stream setup (in / out / err)
    local stdin_w,  child_stdin,  _ = setup_stream(opts.stdin  or "inherit", "in")
    local stdout_r, child_stdout, _ = setup_stream(opts.stdout or "inherit", "out")
    local stderr_r, child_stderr, _
    if opts.stderr == "merge_with_stdout" then
        stderr_r, child_stderr = nil, child_stdout
    else
        stderr_r, child_stderr, _ = setup_stream(opts.stderr or "inherit", "err")
    end

    local pipes_used = (opts.stdin  == "pipe") or (opts.stdout == "pipe")
                    or (opts.stderr == "pipe") or (opts.stdin  == "null")
                    or (opts.stdout == "null") or (opts.stderr == "null")
                    or (opts.stderr == "merge_with_stdout")

    -- Bytes-as-stdin: stash the data and let the caller write it after
    -- spawn (avoids a partial-write deadlock for large inputs).
    local stdin_bytes
    if type(opts.stdin) == "string" and opts.stdin ~= "pipe"
            and opts.stdin ~= "inherit" and opts.stdin ~= "null" then
        -- treat as inline bytes -> open a pipe and write data after spawn
        if C.CloseHandle(child_stdin) == 0 then end  -- best-effort cleanup
        stdin_bytes = opts.stdin
        stdin_w, child_stdin = setup_stream("pipe", "in")
        pipes_used = true
    end

    -- STARTUPINFOW
    local si = ffi.new("STARTUPINFOW")
    si.cb = ffi.sizeof("STARTUPINFOW")
    si.dwFlags = STARTF_USESTDHANDLES
    si.hStdInput  = child_stdin  or INVALID_HANDLE
    si.hStdOutput = child_stdout or INVALID_HANDLE
    si.hStdError  = child_stderr or INVALID_HANDLE
    if opts.hide_window then
        si.dwFlags = bit.bor(si.dwFlags, STARTF_USESHOWWINDOW)
        si.wShowWindow = 0  -- SW_HIDE
    end

    -- Creation flags
    local flags = CREATE_UNICODE_ENVIRONMENT
    if opts.hide_window then flags = bit.bor(flags, CREATE_NO_WINDOW) end
    if opts.detached    then flags = bit.bor(flags, DETACHED_PROCESS) end

    -- CreateProcessW needs a writable command-line buffer (it tokenizes
    -- in-place). Convert to UTF-16 and copy.
    local wcmd_src, wcmd_len = W.ToWide(cmdline)
    local wcmd = ffi.new("unsigned short[?]", wcmd_len)
    ffi.copy(wcmd, wcmd_src, wcmd_len * 2)

    local wcwd = nil
    if opts.cwd then wcwd = W.ToWide(opts.cwd) end

    local env_block = build_env_block(opts.env)

    local pi = ffi.new("PROCESS_INFORMATION")
    local ok = C.CreateProcessW(
        nil,                     -- lpApplicationName -- parse from cmdline
        ffi.cast("LPWSTR", wcmd),
        nil, nil,
        1,                       -- bInheritHandles -- must be TRUE for pipes
        flags,
        env_block,
        wcwd,
        si,
        pi)

    -- Always close the child-side handles in the parent after CreateProcess
    -- (the child has its own duplicates). Skipping this means the parent
    -- keeps the write/read end open and never sees EOF.
    if child_stdin  ~= nil and opts.stdin  ~= "inherit" then C.CloseHandle(child_stdin)  end
    if child_stdout ~= nil and opts.stdout ~= "inherit" then C.CloseHandle(child_stdout) end
    if child_stderr ~= nil and opts.stderr ~= "inherit"
        and opts.stderr ~= "merge_with_stdout" then
        C.CloseHandle(child_stderr)
    end

    if ok == 0 then
        if stdin_w  ~= nil then C.CloseHandle(stdin_w)  end
        if stdout_r ~= nil then C.CloseHandle(stdout_r) end
        if stderr_r ~= nil then C.CloseHandle(stderr_r) end
        return nil, "CreateProcessW failed: " .. tonumber(C.GetLastError())
    end

    local p = setmetatable({
        process  = pi.hProcess,
        thread   = pi.hThread,
        _pid     = tonumber(pi.dwProcessId),
        stdin_w  = stdin_w,
        stdout_r = stdout_r,
        stderr_r = stderr_r,
    }, proc_mt)

    -- If the caller passed stdin bytes, push them now and close stdin
    -- so the child sees EOF.
    if stdin_bytes then
        p:write_stdin(stdin_bytes)
        p:close_stdin()
    end

    return p
end

-- ===== run (blocking convenience wrapper) ===============================
--
-- Drains stdout / stderr in alternation until both pipes hit EOF, then
-- waits for the child to exit. Buffered string return.

function M.run(cmd, opts)
    opts = opts or {}
    -- Force pipe redirection so we can capture.
    opts.stdout = opts.stdout or "pipe"
    opts.stderr = opts.stderr or "pipe"
    local p, err = M.spawn(cmd, opts)
    if not p then return nil, err end

    local out_chunks, err_chunks = {}, {}
    local out_done, err_done = (p.stdout_r == nil), (p.stderr_r == nil)
    while not (out_done and err_done) do
        if not out_done then
            local s, e = p:read_stdout(8192)
            if s then out_chunks[#out_chunks + 1] = s
            elseif e == "eof" then out_done = true
            else out_done = true end
        end
        if not err_done then
            local s, e = p:read_stderr(8192)
            if s then err_chunks[#err_chunks + 1] = s
            elseif e == "eof" then err_done = true
            else err_done = true end
        end
    end

    local exit_code, werr = p:wait(opts.timeout_ms)
    if exit_code == nil and werr == "timeout" then
        p:kill()
        p:close()
        return nil, "timeout"
    end
    p:close()
    return {
        exit_code = exit_code,
        stdout    = table.concat(out_chunks),
        stderr    = table.concat(err_chunks),
    }
end

-- ===== popen (file-like) ================================================
--
-- popen returns an object that behaves enough like io.popen's file handle
-- to drop into pipelines. mode "r" = read child stdout, "w" = write to
-- child stdin. No "rw" -- if you need duplex, use spawn() directly.

local popen_mt = { __index = {} }

function popen_mt.__index:read(fmt)
    fmt = fmt or "*a"
    if fmt == "*a" or fmt == "a" then
        local buf = {}
        while true do
            local s, e = self._proc:read_stdout(8192)
            if s then buf[#buf + 1] = s
            else break end
        end
        return table.concat(buf)
    elseif fmt == "*l" or fmt == "l" then
        -- naive line reader: pulls a fixed chunk; OK for popen idioms
        return self._proc:read_stdout(4096)
    elseif type(fmt) == "number" then
        return self._proc:read_stdout(fmt)
    else
        error("popen:read unsupported format " .. tostring(fmt))
    end
end

function popen_mt.__index:write(s)
    return self._proc:write_stdin(s)
end

function popen_mt.__index:close()
    self._proc:close_stdin()
    local code = self._proc:wait()
    self._proc:close()
    return code
end

function M.popen(cmd, mode)
    mode = mode or "r"
    local opts = { hide_window = true }
    if mode == "r" then
        opts.stdout = "pipe"
    elseif mode == "w" then
        opts.stdin  = "pipe"
    else
        error("process.popen: mode must be 'r' or 'w'")
    end
    local p, err = M.spawn(cmd, opts)
    if not p then return nil, err end
    return setmetatable({ _proc = p }, popen_mt)
end

return M
