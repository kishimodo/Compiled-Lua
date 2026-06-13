-- thread -- worker spawn with a coroutine-backed handle.
--
-- NOTE ON CONCURRENCY: real OS threads (one isolated lua_State each) are not
-- shipped in this build -- the native bootstrap that brings a worker lua_State
-- up on a new OS thread was never wired in, and in a closed-world AOT program
-- a function cannot be handed to another state via string.dump/load. So
-- thread.spawn runs the worker COOPERATIVELY: the function is driven on a
-- coroutine and executed when the handle is joined. The handle surface is
-- unchanged; only the timing differs. Native mode is a documented future step
-- (resolve the worker through its compile-time function-id, then bootstrap the
-- state with the proto registry).
--
-- Public surface:
--   thread.spawn(fn, args?, opts?)   -> thread handle
--   thread.current()                 -> handle for the calling thread
--   thread.cpu_count()               -> number of logical processors
--   thread.lua_api_available()       -> bool, reason?
--
-- spawn parameters:
--   fn       function value (run cooperatively, may close over upvalues)
--   args     table of arguments unpacked into the function's varargs
--   opts     { name = nil }   reserved for the future native path
--
-- Thread handle methods:
--   :join(timeout_ms?)  -> result | nil, err           blocks until exit
--   :detach()                                          drop ownership
--   :id()               -> DWORD                       thread id (0 for cooperative)
--   :alive()            -> bool                        still running?
--   :raw_handle()       -> HANDLE                      kernel handle
--
-- ===== Implementation =========================================
--
-- The OS thread runs a small native bootstrap that:
--   1. luaL_newstate() to create an isolated state
--   2. luaL_openlibs(L) to install standard libs
--   3. luaL_loadbufferx the function bytecode
--   4. unpack the serialized args and lua_pcallk
--   5. Serialize the return value (or error) into a result slot
--   6. Signal the done_event and exit
--
-- The bootstrap CANNOT be a Lua-side ffi callback (Ffi_AllocCallback
-- dispatches against a single shared lua_State). The runtime is expected
-- to export `_clua_thread_bootstrap` with signature
--   DWORD WINAPI _clua_thread_bootstrap(thread_ctx_t *ctx)
-- When that helper is missing we fall back to a cooperative coroutine
-- mode so the API stays usable for tests and single-thread programs.

local W       = require "windows"
local WT      = require "windows.threading"
local channel = require "channel"
local event   = require "event"

-- msgpack is the preferred wire format because it's a public spec and
-- the bootstrap can independently decode it. Fall back to channel's
-- internal serializer if msgpack isn't part of the build.
local msgpack_ok, msgpack = pcall(require, "msgpack")
local function pack(v)
    if msgpack_ok then return msgpack.pack(v) end
    return channel.serialize(v)
end
local function unpack_blob(s)
    if msgpack_ok then return msgpack.unpack(s) end
    return channel.deserialize(s)
end

local C = ffi.C
local M = {}

ffi.cdef[[
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
typedef int (*lua_KFunction)(lua_State *L, int status, intptr_t ctx);

lua_State *luaL_newstate(void);
void       luaL_openlibs(lua_State *L);
void       lua_close(lua_State *L);
int        luaL_loadbufferx(lua_State *L, const char *buff, size_t sz,
                            const char *name, const char *mode);
int        lua_pcallk(lua_State *L, int nargs, int nresults, int errfunc,
                      intptr_t ctx, lua_KFunction k);
void       lua_pushinteger(lua_State *L, int64_t n);
void       lua_pushlstring(lua_State *L, const char *s, size_t len);
void       lua_pushnil(lua_State *L);
void       lua_settop(lua_State *L, int idx);
int        lua_gettop(lua_State *L);
const char *lua_tolstring(lua_State *L, int idx, size_t *len);
int        lua_type(lua_State *L, int idx);

typedef struct _thread_result {
    int32_t   status;        /* 0 pending, 1 ok, 2 error */
    int32_t   _pad;
    void     *payload_ptr;
    int32_t   payload_len;
    int32_t   payload_kind;  /* 0 serialized value, 1 error string */
} thread_result_t;

typedef struct _thread_ctx {
    char            *chunk_bytes;
    int32_t          chunk_len;
    int32_t          _pad0;
    char            *chunk_name;
    char            *args_blob;
    int32_t          args_len;
    int32_t          _pad1;
    thread_result_t *result_slot;
    void            *done_event;
} thread_ctx_t;

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

void GetSystemInfo(SYSTEM_INFO *lpSystemInfo);
]]

-- ===== Lua C API availability probe ============================

local LUA_API_AVAILABLE, LUA_API_REASON
do
    local ok, err = pcall(function() return C.luaL_newstate end)
    if ok then
        LUA_API_AVAILABLE = true
    else
        LUA_API_AVAILABLE = false
        LUA_API_REASON = err
    end
end

function M.lua_api_available()
    return LUA_API_AVAILABLE, LUA_API_REASON
end

-- ===== Helpers =================================================

local thread_mt = { __index = {} }
local methods   = thread_mt.__index

local INFINITE      = 0xFFFFFFFF
local WAIT_OBJECT_0 = 0
local WAIT_TIMEOUT  = 0x102
local STILL_ACTIVE  = 259  -- STATUS_PENDING when GetExitCodeThread is called

-- ===== spawn ===================================================
-- Real OS-thread spawning needs two pieces this build does not ship: a native
-- bootstrap (`_clua_thread_bootstrap`) that brings up a fresh lua_State on the
-- new OS thread, and a way to hand the worker function to that state. The
-- interpreter would do the latter with string.dump + load, but a closed-world
-- AOT program has neither the bytecode dumper nor the loader -- the function
-- must instead be resolved through its compile-time function-id in the proto
-- registry, which is the documented next step for native mode.
--
-- Until that lands, thread.spawn runs the worker COOPERATIVELY: the function is
-- driven on a coroutine and executed when the handle is joined. The handle API
-- is identical (:join / :alive / :detach / :id); only the timing differs
-- (join() performs the work). This is exactly what every build did before --
-- the native path was never wired up -- now without the pointless
-- string.dump -> load round-trip that broke AOT compilation.

function M.spawn(fn, args, opts)
    if type(fn) ~= "function" then
        return nil, "thread.spawn: fn must be a function"
    end
    args = args or {}
    if type(args) ~= "table" then
        return nil, "thread.spawn: args must be a table (becomes varargs)"
    end
    local co = coroutine.create(function() return fn(table.unpack(args)) end)
    return setmetatable({
        co       = co,
        joined   = false,
        detached = false,
        mode     = "coop",
        tid      = 0,
    }, thread_mt)
end

function methods:id() return self.tid end
function methods:raw_handle() return self.handle end

function methods:alive()
    if self.joined then return false end
    if self.mode == "native" then
        if self.handle == nil then return false end
        local code = ffi.new("DWORD[1]")
        if C.GetExitCodeThread(self.handle, code) == 0 then return false end
        return tonumber(code[0]) == STILL_ACTIVE
    end
    return self.co ~= nil and coroutine.status(self.co) ~= "dead"
end

function methods:detach()
    if self.detached then return end
    self.detached = true
    if self.mode == "native" then
        -- Don't free ctx / result -- the worker still owns them. Closing
        -- the handle relinquishes our wait right; the OS reclaims the
        -- thread object when it exits.
        if self.handle ~= nil then C.CloseHandle(self.handle); self.handle = nil end
        if self.done_ev ~= nil then C.CloseHandle(self.done_ev); self.done_ev = nil end
    else
        self.co = nil
    end
end

function methods:join(timeout_ms)
    if self.joined then
        return self._cached_result, self._cached_err
    end
    if self.mode == "native" then
        if self.handle == nil then return nil, "detached" end
        local r = tonumber(C.WaitForSingleObject(self.handle, timeout_ms or INFINITE))
        if r == WAIT_TIMEOUT then return nil, "timeout" end
        if r ~= WAIT_OBJECT_0 then return nil, "wait failed: " .. r end
        self.joined = true
        local res = self.result
        if res.status == 1 then
            local blob = ffi.string(res.payload_ptr, res.payload_len)
            local v = unpack_blob(blob)
            self._cached_result = v
            self._cached_err    = nil
            self:_cleanup()
            return v
        elseif res.status == 2 then
            local msg = ffi.string(res.payload_ptr, res.payload_len)
            self._cached_result = nil
            self._cached_err    = msg
            self:_cleanup()
            return nil, msg
        else
            self:_cleanup()
            return nil, "thread exited without setting result"
        end
    else
        -- Cooperative: drive the coroutine to completion. No real timeout.
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
end

function methods:_cleanup()
    if self.ctx ~= nil then
        if self.ctx.chunk_bytes ~= nil then C.free(self.ctx.chunk_bytes); self.ctx.chunk_bytes = nil end
        if self.ctx.chunk_name  ~= nil then C.free(self.ctx.chunk_name);  self.ctx.chunk_name  = nil end
        if self.ctx.args_blob   ~= nil then C.free(self.ctx.args_blob);   self.ctx.args_blob   = nil end
        C.free(self.ctx); self.ctx = nil
    end
    if self.result ~= nil then
        if self.result.payload_ptr ~= nil then
            C.free(self.result.payload_ptr); self.result.payload_ptr = nil
        end
        C.free(self.result); self.result = nil
    end
    if self.done_ev ~= nil then C.CloseHandle(self.done_ev); self.done_ev = nil end
    if self.handle ~= nil then C.CloseHandle(self.handle); self.handle = nil end
end

-- ===== module-level helpers ====================================

-- thread.current(): a handle representing the calling thread. The handle
-- doesn't support :join (would deadlock), :detach, or :_cleanup -- only
-- :id() and :alive(). Useful for naming / inspection.
function M.current()
    return setmetatable({
        handle   = C.GetCurrentThread(),
        tid      = tonumber(C.GetCurrentThreadId()),
        mode     = "self",
        joined   = false,
        detached = true,    -- can't be detached again
    }, thread_mt)
end

-- Legacy / back-compat: return just the id.
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
