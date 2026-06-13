-- thread -- worker spawn over real OS threads, with a cooperative fallback.
--
-- Public surface:
--   thread.spawn(fn, args?, opts?)   -> thread handle
--   thread.current()                 -> handle for the calling thread
--   thread.cpu_count()               -> number of logical processors
--   thread.lua_api_available()       -> bool (native OS threads supported?)
--
-- spawn parameters:
--   fn       worker function. Native mode requires it to be "shippable": a
--            compiled function that captures nothing but its environment
--            (no upvalues over locals). Such a function runs on a real OS
--            thread in its own lua_State, resolved by its compile-time
--            function-id -- no string.dump, so it works in a closed-world AOT
--            program. A function that captures upvalues (or any non-AOT build)
--            runs COOPERATIVELY instead: driven on a coroutine, executed when
--            the handle is joined. Pass opts.cooperative = true to force it.
--   args     table of arguments, unpacked into the worker's varargs. Native
--            mode serializes them across the thread boundary (nil / boolean /
--            number / string / table); a value that cannot be serialized
--            forces cooperative mode for that call.
--   opts     { cooperative = false }
--
-- Native-mode limits: the worker runs the standard library + any compiled
-- function it calls + pure-Lua `require`s, but NOT the FFI (its callback
-- dispatch is a single shared state), so a native worker must be ffi-free.
--
-- Thread handle methods:
--   :join(timeout_ms?)  -> result | nil, err     blocks until the worker exits
--   :alive()            -> bool
--   :detach()                                     drop ownership
--   :id()               -> number                 (0 for cooperative workers)
--
-- ===== Implementation =========================================
-- Native spawning is driven by the `_clua` internal library the runtime
-- installs (fn_id / resolve_fn / spawn_native / join_native / serialize). The
-- OS thread runs a tiny Lua trampoline (`worker_main`) so argument/result
-- (de)serialization reuses _clua's serializer on both sides; worker_main must
-- itself be shippable, so it touches only globals (no captured upvalues).

local ffi = ffi

ffi.cdef[[
typedef struct _SYSTEM_INFO {
    union {
        DWORD dwOemId;
        struct {
            WORD wProcessorArchitecture;
            WORD wReserved;
        };
    };
    DWORD     dwPageSize;
    void     *lpMinimumApplicationAddress;
    void     *lpMaximumApplicationAddress;
    void     *dwActiveProcessorMask;
    DWORD     dwNumberOfProcessors;
    DWORD     dwProcessorType;
    DWORD     dwAllocationGranularity;
    WORD      wProcessorLevel;
    WORD      wProcessorRevision;
} SYSTEM_INFO;

void   GetSystemInfo(SYSTEM_INFO *lpSystemInfo);
HANDLE GetCurrentThread(void);
DWORD  GetCurrentThreadId(void);
]]

local C = ffi.C
local M = {}

-- Native OS threads are available when the runtime exposes the `_clua` library
-- (every AOT exe and the shared runtime do). The reference interpreter does
-- not, so it runs everything cooperatively -- identical results, different
-- timing.
local NATIVE = (type(_clua) == "table"
                and type(_clua.spawn_native) == "function"
                and type(_clua.fn_id) == "function")

function M.lua_api_available()
    return NATIVE
end

-- The worker trampoline. Runs in the worker's lua_State; resolves the user
-- function by id, unpacks the serialized args, runs it, and serializes the
-- result back. Must be SHIPPABLE: it references only globals (_clua, pcall,
-- table, tostring), never an upvalue, so the runtime can rebuild it in the
-- worker state.
local function worker_main(fn_id, args_blob)
    local fn = _clua.resolve_fn(fn_id)
    if not fn then
        return _clua.serialize({ ok = false, err = "thread worker: cannot resolve function" })
    end
    local args = _clua.deserialize(args_blob) or {}
    local ok, v = pcall(fn, table.unpack(args, 1, args.n or #args))
    local payload, serr
    if ok then
        payload, serr = _clua.serialize({ ok = true, value = v })
        if not payload then
            payload = _clua.serialize({ ok = false,
                err = "thread worker: result not serializable (" .. tostring(serr) .. ")" })
        end
    else
        payload = _clua.serialize({ ok = false, err = tostring(v) })
    end
    return payload
end

-- ===== handle ==================================================

local thread_mt = { __index = {} }
local methods   = thread_mt.__index

-- ===== spawn ===================================================

function M.spawn(fn, args, opts)
    if type(fn) ~= "function" then
        return nil, "thread.spawn: fn must be a function"
    end
    args = args or {}
    if type(args) ~= "table" then
        return nil, "thread.spawn: args must be a table (becomes varargs)"
    end
    opts = opts or {}

    -- Native path: real OS thread, when supported + the function is shippable +
    -- the caller didn't force cooperative. Any failure falls through cleanly.
    if NATIVE and opts.cooperative ~= true and _clua.fn_id(fn) ~= nil then
        local blob = _clua.serialize(args)
        if blob then
            local h = _clua.spawn_native(worker_main, fn, blob)
            if h then
                return setmetatable({
                    nhandle  = h,
                    mode     = "native",
                    joined   = false,
                    detached = false,
                    tid      = 0,
                }, thread_mt)
            end
        end
        -- args not serializable, or spawn failed: fall back to cooperative,
        -- which keeps upvalues and handles any argument type.
    end

    -- Cooperative path: drive the worker on a coroutine.
    local co = coroutine.create(function()
        return fn(table.unpack(args, 1, args.n or #args))
    end)
    return setmetatable({
        co       = co,
        mode     = "coop",
        joined   = false,
        detached = false,
        tid      = 0,
    }, thread_mt)
end

function methods:id() return self.tid end

function methods:alive()
    if self.mode == "self" then return true end   -- the calling thread
    if self.joined then return false end
    if self.mode == "native" then
        return self.nhandle ~= nil and _clua.alive_native(self.nhandle)
    end
    return self.co ~= nil and coroutine.status(self.co) ~= "dead"
end

function methods:detach()
    if self.detached then return end
    self.detached = true
    if self.mode == "native" then
        -- Fire-and-forget: drop our reference. The worker runs to completion;
        -- its result is discarded (the C-side context is reclaimed at exit).
        self.nhandle = nil
    else
        self.co = nil
    end
end

function methods:join(timeout_ms)
    if self.joined then
        return self._cached_result, self._cached_err
    end
    if self.mode == "native" then
        if self.nhandle == nil then return nil, "detached" end
        local ok, payload = _clua.join_native(self.nhandle, timeout_ms or -1)
        if ok == nil then
            -- timeout / wait failure: not joined, the handle stays valid.
            return nil, payload
        end
        self.joined  = true
        self.nhandle = nil                 -- the C side freed it
        if not ok then                     -- worker bring-up / trampoline failed
            self._cached_err = payload
            return nil, payload
        end
        local res = _clua.deserialize(payload)
        if type(res) == "table" and res.ok then
            self._cached_result = res.value
            return res.value
        end
        self._cached_err = (type(res) == "table" and res.err) or "thread worker error"
        return nil, self._cached_err
    end

    -- Cooperative: drive the coroutine to completion (no real timeout).
    if self.co == nil then return nil, "cancelled" end
    local ok, r1 = coroutine.resume(self.co)
    if coroutine.status(self.co) ~= "dead" then
        return nil, "still running (cooperative)"
    end
    self.joined = true
    if ok then
        self._cached_result = r1
        return r1
    end
    self._cached_err = r1
    return nil, r1
end

-- ===== module-level helpers ====================================

-- thread.current(): a handle for the calling thread. Supports :id() and
-- :alive() (always true) only -- :join would deadlock.
function M.current()
    return setmetatable({
        tid      = tonumber(C.GetCurrentThreadId()),
        mode     = "self",
        joined   = false,
        detached = true,
    }, thread_mt)
end

function M.current_id()
    return tonumber(C.GetCurrentThreadId())
end

-- thread.cpu_count(): number of logical processors.
function M.cpu_count()
    local si = ffi.new("SYSTEM_INFO")
    C.GetSystemInfo(si)
    return tonumber(si.dwNumberOfProcessors)
end

return M
