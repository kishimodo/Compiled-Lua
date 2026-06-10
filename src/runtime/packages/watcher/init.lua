-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- watcher -- filesystem change notifications via ReadDirectoryChangesW.
--
-- Public surface:
--   watcher.watch(path, opts?, handler?) -> watcher_obj | nil, err
--
--     opts = {
--       recursive = true,                                -- watch subtree
--       events    = {"create","modify","delete","rename"}, -- filter
--       buffer_size = 64 * 1024,                          -- driver buffer
--     }
--
--     handler = function(kind, path, old_path?)
--       called from :wait() / :poll() once per decoded event.
--
--   w:poll(timeout_ms?) -> n_events_dispatched | nil, err
--       Drains all pending events, dispatching to the handler. timeout_ms
--       defaults to 0 (non-blocking peek). Pass nil or -1 for infinite.
--
--   w:wait(timeout_ms?) -> like :poll() but blocks; useful for loops.
--
--   w:stop()  -> true
--
-- Event kinds:
--   "create"    file or dir added
--   "modify"    contents changed
--   "delete"    file or dir removed
--   "rename"    old_path -> path. We emit a single rename event whenever
--               we see the FILE_ACTION_RENAMED_OLD_NAME / NEW_NAME pair.
--
-- The watcher uses asynchronous IO (FILE_FLAG_OVERLAPPED + an Event)
-- and re-issues ReadDirectoryChangesW immediately after each completion,
-- so no events are lost between polls.

local W   = require "windows"
local _FSW = require "windows.filesystem"
local path = require "path"

local C   = ffi.C
local M   = {}

-- ===== cdefs (local, namespaced) =======================================

ffi.cdef[[
typedef struct _watcher_OVERLAPPED {
    ULONGLONG  Internal;
    ULONGLONG  InternalHigh;
    ULONGLONG  Offset;
    HANDLE     hEvent;
} watcher_OVERLAPPED;

HANDLE  CreateFileW(unsigned short *, DWORD, DWORD, SECURITY_ATTRIBUTES *, DWORD, DWORD, HANDLE);
HANDLE  CreateEventW(SECURITY_ATTRIBUTES *, BOOL, BOOL, unsigned short *);
BOOL    ResetEvent(HANDLE);
BOOL    SetEvent(HANDLE);
BOOL    CloseHandle(HANDLE);
DWORD   WaitForSingleObject(HANDLE, DWORD);
BOOL    GetOverlappedResult(HANDLE, watcher_OVERLAPPED *, DWORD *, BOOL);
BOOL    CancelIoEx(HANDLE, watcher_OVERLAPPED *);
BOOL    ReadDirectoryChangesW(HANDLE, void *, DWORD, BOOL, DWORD, DWORD *, watcher_OVERLAPPED *, void *);
]]

-- ===== Constants ========================================================

local GENERIC_READ              = 0x80000000
local FILE_SHARE_READ           = 0x00000001
local FILE_SHARE_WRITE          = 0x00000002
local FILE_SHARE_DELETE         = 0x00000004
local OPEN_EXISTING             = 3
local FILE_FLAG_BACKUP_SEMANTICS= 0x02000000
local FILE_FLAG_OVERLAPPED      = 0x40000000
local FILE_LIST_DIRECTORY       = 0x0001
local INVALID_HANDLE_VALUE      = ffi.cast("HANDLE", -1)

local WAIT_OBJECT_0     = 0x00000000
local WAIT_TIMEOUT      = 0x00000102
local INFINITE          = 0xFFFFFFFF

local ERROR_IO_PENDING  = 997
local ERROR_OPERATION_ABORTED = 995

local FILE_NOTIFY_CHANGE_FILE_NAME   = 0x00000001
local FILE_NOTIFY_CHANGE_DIR_NAME    = 0x00000002
local FILE_NOTIFY_CHANGE_ATTRIBUTES  = 0x00000004
local FILE_NOTIFY_CHANGE_SIZE        = 0x00000008
local FILE_NOTIFY_CHANGE_LAST_WRITE  = 0x00000010
local FILE_NOTIFY_CHANGE_CREATION    = 0x00000040
local FILE_NOTIFY_CHANGE_SECURITY    = 0x00000100

local FILE_ACTION_ADDED            = 0x00000001
local FILE_ACTION_REMOVED          = 0x00000002
local FILE_ACTION_MODIFIED         = 0x00000003
local FILE_ACTION_RENAMED_OLD_NAME = 0x00000004
local FILE_ACTION_RENAMED_NEW_NAME = 0x00000005

-- ===== Utility ==========================================================

local function wide_path(p)
    local q = p
    if #p > 240 and path.is_absolute(p) then q = path.long_prefix(p) end
    local need = C.MultiByteToWideChar(65001, 0, q, -1, nil, 0)
    if need <= 0 then return nil, "MultiByteToWideChar failed sizing" end
    local buf = ffi.new("unsigned short[?]", need)
    if C.MultiByteToWideChar(65001, 0, q, -1, buf, need) <= 0 then
        return nil, "MultiByteToWideChar failed"
    end
    return buf
end

local function last_err(action)
    return string.format("%s failed (Win32 error %d)", action, tonumber(C.GetLastError()))
end

local function utf16_to_utf8(wbuf, wchars)
    if wchars == 0 then return "" end
    local need = C.WideCharToMultiByte(65001, 0, wbuf, wchars, nil, 0, nil, nil)
    if need <= 0 then return "" end
    local out = ffi.new("char[?]", need)
    C.WideCharToMultiByte(65001, 0, wbuf, wchars, out, need, nil, nil)
    return ffi.string(out, need)
end

local function build_filter(events)
    -- Default: everything we know how to surface.
    if not events then
        return bit.bor(
            FILE_NOTIFY_CHANGE_FILE_NAME,
            FILE_NOTIFY_CHANGE_DIR_NAME,
            FILE_NOTIFY_CHANGE_ATTRIBUTES,
            FILE_NOTIFY_CHANGE_SIZE,
            FILE_NOTIFY_CHANGE_LAST_WRITE,
            FILE_NOTIFY_CHANGE_CREATION
        )
    end
    local f = 0
    local want = {}
    for _, e in ipairs(events) do want[e] = true end
    if want.create or want.delete or want.rename then
        f = bit.bor(f, FILE_NOTIFY_CHANGE_FILE_NAME, FILE_NOTIFY_CHANGE_DIR_NAME)
    end
    if want.modify then
        f = bit.bor(f, FILE_NOTIFY_CHANGE_SIZE, FILE_NOTIFY_CHANGE_LAST_WRITE,
                    FILE_NOTIFY_CHANGE_ATTRIBUTES, FILE_NOTIFY_CHANGE_CREATION)
    end
    if f == 0 then
        return nil, "watcher: events list resolves to empty filter"
    end
    return f
end

-- Decode the kernel's buffer. Walks records by NextEntryOffset. Returns
-- a list of decoded entries -- we then post-process to coalesce rename
-- pairs.
local function decode_buffer(buf, length)
    local entries, n = {}, 0
    local off = 0
    while off < length do
        local p = ffi.cast("char *", buf) + off
        -- FILE_NOTIFY_INFORMATION layout:
        --   DWORD NextEntryOffset   (off + 0)
        --   DWORD Action            (off + 4)
        --   DWORD FileNameLength    (off + 8)   in BYTES
        --   WCHAR FileName[1]       (off + 12)
        local next_off  = ffi.cast("DWORD *", p)[0]
        local action    = ffi.cast("DWORD *", p + 4)[0]
        local name_len  = ffi.cast("DWORD *", p + 8)[0]   -- bytes
        local wname_ptr = ffi.cast("unsigned short *", p + 12)
        local wchars    = name_len / 2
        local name      = utf16_to_utf8(wname_ptr, tonumber(wchars))
        n = n + 1
        entries[n] = { action = tonumber(action), name = name }
        if next_off == 0 then break end
        off = off + tonumber(next_off)
    end
    return entries
end

-- ===== Object methods ===================================================

local mt = { __index = {} }

local function reissue(self)
    if self._stopped then return false end
    -- Reset OVERLAPPED and event for the next ReadDirectoryChangesW.
    ffi.fill(self._ov, ffi.sizeof("watcher_OVERLAPPED"), 0)
    self._ov.hEvent = self._event
    C.ResetEvent(self._event)
    self._bytes_returned[0] = 0
    local ok = C.ReadDirectoryChangesW(
        self._handle, self._buffer, self._buf_size,
        self._recursive and 1 or 0, self._filter,
        self._bytes_returned, self._ov, nil)
    if ok == 0 then
        local code = tonumber(C.GetLastError())
        if code == ERROR_IO_PENDING then return true end
        self._error = last_err("ReadDirectoryChangesW")
        return false
    end
    return true
end

local function dispatch_entries(self, entries)
    local handler = self._handler
    if not handler then return 0 end
    local n = 0
    local i, count = 1, #entries
    -- Pair RENAMED_OLD_NAME with the immediately-following RENAMED_NEW_NAME.
    while i <= count do
        local e = entries[i]
        local full = path.join(self._root, e.name)
        if e.action == FILE_ACTION_ADDED then
            handler("create", full); n = n + 1
        elseif e.action == FILE_ACTION_REMOVED then
            handler("delete", full); n = n + 1
        elseif e.action == FILE_ACTION_MODIFIED then
            handler("modify", full); n = n + 1
        elseif e.action == FILE_ACTION_RENAMED_OLD_NAME then
            local nxt = entries[i + 1]
            if nxt and nxt.action == FILE_ACTION_RENAMED_NEW_NAME then
                local newfull = path.join(self._root, nxt.name)
                handler("rename", newfull, full)
                i = i + 1   -- consume both
                n = n + 1
            else
                -- Orphaned old name -- emit as delete.
                handler("delete", full); n = n + 1
            end
        elseif e.action == FILE_ACTION_RENAMED_NEW_NAME then
            -- Orphan (we lost the old-name) -- treat as create.
            handler("create", full); n = n + 1
        end
        i = i + 1
    end
    return n
end

-- Drain one completion (if signaled). Returns n_events, ok flag.
local function drain_one(self, timeout_ms)
    if self._stopped then return 0 end
    local wait = C.WaitForSingleObject(self._event, timeout_ms)
    if wait == WAIT_TIMEOUT then return 0 end
    if wait ~= WAIT_OBJECT_0 then
        return nil, last_err("WaitForSingleObject")
    end
    -- Completion ready.
    local got = ffi.new("DWORD[1]")
    if C.GetOverlappedResult(self._handle, self._ov, got, 1) == 0 then
        local code = tonumber(C.GetLastError())
        if code == ERROR_OPERATION_ABORTED then
            return 0   -- stop() canceled the IO
        end
        return nil, last_err("GetOverlappedResult")
    end
    local nbytes = tonumber(got[0])
    local count = 0
    if nbytes > 0 then
        local entries = decode_buffer(self._buffer, nbytes)
        count = dispatch_entries(self, entries)
    end
    -- Re-arm.
    if not reissue(self) then
        return count, self._error or "watcher: re-issue failed"
    end
    return count
end

function mt.__index:poll(timeout_ms)
    if self._stopped then return nil, "watcher: stopped" end
    timeout_ms = timeout_ms or 0
    if timeout_ms < 0 then timeout_ms = INFINITE end
    local total = 0
    -- Drain everything available.
    while true do
        local got, err = drain_one(self, total == 0 and timeout_ms or 0)
        if got == nil then return nil, err end
        if got == 0 then return total end
        total = total + got
    end
end

function mt.__index:wait(timeout_ms)
    if self._stopped then return nil, "watcher: stopped" end
    timeout_ms = timeout_ms or INFINITE
    if timeout_ms < 0 then timeout_ms = INFINITE end
    local got, err = drain_one(self, timeout_ms)
    if got == nil then return nil, err end
    -- Drain anything that piled up while we processed.
    if got > 0 then
        while true do
            local more, more_err = drain_one(self, 0)
            if more == nil then return nil, more_err end
            if more == 0 then break end
            got = got + more
        end
    end
    return got
end

function mt.__index:set_handler(fn)
    self._handler = fn
end

function mt.__index:stop()
    if self._stopped then return true end
    self._stopped = true
    if self._handle ~= nil and self._handle ~= INVALID_HANDLE_VALUE then
        -- Cancel any pending IO so the handle can close cleanly.
        C.CancelIoEx(self._handle, nil)
        C.CloseHandle(self._handle)
        self._handle = nil
    end
    if self._event ~= nil then
        C.CloseHandle(self._event)
        self._event = nil
    end
    return true
end

mt.__gc = function(self) self:stop() end

-- ===== watch() ==========================================================

function M.watch(p, opts, handler)
    -- Allow watcher.watch(path, handler) shorthand.
    if type(opts) == "function" and handler == nil then
        handler = opts
        opts = nil
    end
    opts = opts or {}

    local wp, werr = wide_path(p)
    if not wp then return nil, werr end

    local filter, ferr = build_filter(opts.events)
    if not filter then return nil, ferr end

    local handle = C.CreateFileW(wp,
        FILE_LIST_DIRECTORY,
        bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE),
        nil,
        OPEN_EXISTING,
        bit.bor(FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OVERLAPPED),
        nil)
    if handle == INVALID_HANDLE_VALUE then
        return nil, last_err("CreateFileW")
    end

    -- Manual-reset event, initially non-signaled.
    local event = C.CreateEventW(nil, 1, 0, nil)
    if event == nil then
        local e = last_err("CreateEventW")
        C.CloseHandle(handle)
        return nil, e
    end

    local buf_size = opts.buffer_size or (64 * 1024)
    -- The driver writes DWORD-aligned records; the buffer must be DWORD-aligned.
    if buf_size < 4096 then buf_size = 4096 end

    local self = setmetatable({
        _root           = p,
        _handle         = handle,
        _event          = event,
        _ov             = ffi.new("watcher_OVERLAPPED"),
        _buffer         = ffi.new("uint8_t[?]", buf_size),
        _buf_size       = buf_size,
        _bytes_returned = ffi.new("DWORD[1]"),
        _filter         = filter,
        _recursive      = opts.recursive ~= false,
        _handler        = handler,
        _stopped        = false,
        _error          = nil,
    }, mt)

    if not reissue(self) then
        local err = self._error or "ReadDirectoryChangesW failed"
        self:stop()
        return nil, err
    end

    return self
end

-- ===== iter(path, opts?) ================================================
--
-- Pull-based iterator over events. Yields one event table per call
-- (blocks until at least one event arrives, or returns nil on stop).
--
-- event = { path=full_path, kind="create"|"modify"|"delete"|"rename",
--           old_path=... (rename only) }
--
-- opts: same shape as watch() plus debounce_ms which coalesces events
-- arriving inside the window for the same path+kind into a single one.

function M.iter(p, opts)
    opts = opts or {}
    local debounce_ms = opts.debounce_ms or 0

    -- Local queue of pending events.
    local queue, head, tail = {}, 1, 0
    local seen = {}   -- "<path>|<kind>" -> last_tick_ms for debounce

    -- GetTickCount64 lives in kernel32; cdef'd once here for debounce.
    ffi.cdef[[ ULONGLONG GetTickCount64(void); ]]

    local function enqueue(kind, full, old)
        if debounce_ms > 0 then
            local key = full .. "|" .. kind
            local now = tonumber(C.GetTickCount64())
            local last = seen[key]
            if last and (now - last) < debounce_ms then
                seen[key] = now
                return
            end
            seen[key] = now
        end
        tail = tail + 1
        queue[tail] = { path = full, kind = kind, old_path = old }
    end

    local w, werr = M.watch(p, opts, function(kind, full, old)
        enqueue(kind, full, old)
    end)
    if not w then return function() return nil, werr end end

    -- Return iterator + a "stopper" via a separate close key on the table.
    local stopped = false
    local iter = function()
        if stopped then return nil end
        while head > tail do
            local got, err = w:wait(opts.poll_timeout_ms or 250)
            if got == nil then return nil, err end
            if stopped then return nil end
            -- got > 0 means handler enqueued; head/tail updated.
        end
        local ev = queue[head]
        queue[head] = nil
        head = head + 1
        return ev
    end
    -- Attach a stop() method via setfenv-free pattern: the iterator is a
    -- callable. We can't add methods to a plain function, so we return a
    -- callable table with __call.
    local proxy = setmetatable({
        stop = function(self) stopped = true; w:stop() end,
        watcher = w,
    }, { __call = function() return iter() end })
    return proxy
end

return M
