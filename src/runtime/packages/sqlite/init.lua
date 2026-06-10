-- sqlite -- full SQLite3 bindings via ffi.load("sqlite3").
--
-- Public surface:
--   sqlite.open(path, opts?)         -> db
--     opts: { mode="rwc"|"rw"|"ro", flags?, uri=false }
--   sqlite.is_available()            -> bool
--   sqlite.libversion()              -> string
--
-- db methods:
--   db:exec(sql, params?)            -- DDL/DML; returns affected_count or rows if SELECT
--   db:query(sql, params?)           -- rows array (each row is a {col=value} table)
--   db:query_one(sql, params?)       -- first row or nil
--   db:prepare(sql)                  -> stmt
--   db:transaction(fn)               -- BEGIN/COMMIT, ROLLBACK on error
--   db:close()
--   db:backup_to(dst_path)           -- online backup via sqlite3_backup_*
--   db:changes()                     -- rows touched by last write
--   db:last_insert_rowid()
--   db:busy_timeout(ms)
--   db:errmsg()
--
-- stmt methods:
--   stmt:bind(params)                -- table: named (:k/@k/$k) or positional (?, ?1)
--   stmt:step()                      -> "row" | "done"
--   stmt:row()                       -- {col=value} table from current row
--   stmt:reset()
--   stmt:finalize()
--
-- DLL load order (first hit wins):
--   1. $LUAVM_SQLITE_DLL env var (full path or bare name)
--   2. "sqlite3"
--   3. "sqlite3.dll"
--   4. "sqlite.dll"
--   5. "sqlite3-0.dll"
-- The compiler will eventually embed/sidecar sqlite3.dll, but that
-- infra isn't wired yet -- for now we probe the system path lazily.

local ffi = ffi

local M = {}

ffi.cdef[[
/* ===== Opaque handles ===== */
typedef struct sqlite3       sqlite3;
typedef struct sqlite3_stmt  sqlite3_stmt;
typedef struct sqlite3_backup sqlite3_backup;
typedef long long            sqlite3_int64;
typedef unsigned long long   sqlite3_uint64;

/* ===== Result codes (subset) ===== */
/* Defined in code: SQLITE_OK=0, ROW=100, DONE=101 etc. */

/* ===== Open / close ===== */
int sqlite3_open(const char *filename, sqlite3 **ppDb);
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close(sqlite3 *db);
int sqlite3_close_v2(sqlite3 *db);

/* ===== Error reporting ===== */
const char *sqlite3_errmsg(sqlite3 *db);
const char *sqlite3_errstr(int rc);
int sqlite3_errcode(sqlite3 *db);
int sqlite3_extended_errcode(sqlite3 *db);
const char *sqlite3_libversion(void);
int sqlite3_libversion_number(void);

/* ===== Exec / callback ===== */
int sqlite3_exec(sqlite3 *db, const char *sql,
                 int (*callback)(void *, int, char **, char **),
                 void *arg, char **errmsg);
void sqlite3_free(void *ptr);

/* ===== Prepared statements ===== */
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                       sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_prepare_v3(sqlite3 *db, const char *zSql, int nByte,
                       unsigned int prepFlags,
                       sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_reset(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_clear_bindings(sqlite3_stmt *stmt);
const char *sqlite3_sql(sqlite3_stmt *stmt);

/* ===== Bindings ===== */
int sqlite3_bind_int(sqlite3_stmt *stmt, int idx, int value);
int sqlite3_bind_int64(sqlite3_stmt *stmt, int idx, sqlite3_int64 value);
int sqlite3_bind_double(sqlite3_stmt *stmt, int idx, double value);
int sqlite3_bind_text(sqlite3_stmt *stmt, int idx, const char *text,
                      int nByte, void (*destructor)(void *));
int sqlite3_bind_blob(sqlite3_stmt *stmt, int idx, const void *data,
                      int nByte, void (*destructor)(void *));
int sqlite3_bind_null(sqlite3_stmt *stmt, int idx);
int sqlite3_bind_zeroblob(sqlite3_stmt *stmt, int idx, int n);
int sqlite3_bind_parameter_count(sqlite3_stmt *stmt);
int sqlite3_bind_parameter_index(sqlite3_stmt *stmt, const char *name);
const char *sqlite3_bind_parameter_name(sqlite3_stmt *stmt, int idx);

/* ===== Column readers ===== */
int sqlite3_column_count(sqlite3_stmt *stmt);
int sqlite3_column_type(sqlite3_stmt *stmt, int col);
const char *sqlite3_column_name(sqlite3_stmt *stmt, int col);
const char *sqlite3_column_decltype(sqlite3_stmt *stmt, int col);
int sqlite3_column_bytes(sqlite3_stmt *stmt, int col);
int sqlite3_column_int(sqlite3_stmt *stmt, int col);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt *stmt, int col);
double sqlite3_column_double(sqlite3_stmt *stmt, int col);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int col);
const void *sqlite3_column_blob(sqlite3_stmt *stmt, int col);

/* ===== Misc ===== */
int sqlite3_changes(sqlite3 *db);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *db);
int sqlite3_busy_timeout(sqlite3 *db, int ms);
int sqlite3_total_changes(sqlite3 *db);
int sqlite3_get_autocommit(sqlite3 *db);
int sqlite3_threadsafe(void);
int sqlite3_enable_shared_cache(int enable);
sqlite3_int64 sqlite3_memory_used(void);

/* ===== Online backup API ===== */
sqlite3_backup *sqlite3_backup_init(sqlite3 *dst, const char *dstName,
                                    sqlite3 *src, const char *srcName);
int sqlite3_backup_step(sqlite3_backup *p, int nPage);
int sqlite3_backup_finish(sqlite3_backup *p);
int sqlite3_backup_remaining(sqlite3_backup *p);
int sqlite3_backup_pagecount(sqlite3_backup *p);
]]

-- ===== Constants ========================================================

M.SQLITE_OK         = 0
M.SQLITE_ERROR      = 1
M.SQLITE_BUSY       = 5
M.SQLITE_LOCKED     = 6
M.SQLITE_NOMEM      = 7
M.SQLITE_READONLY   = 8
M.SQLITE_INTERRUPT  = 9
M.SQLITE_IOERR      = 10
M.SQLITE_CORRUPT    = 11
M.SQLITE_NOTFOUND   = 12
M.SQLITE_CONSTRAINT = 19
M.SQLITE_MISMATCH   = 20
M.SQLITE_MISUSE     = 21
M.SQLITE_RANGE      = 25
M.SQLITE_ROW        = 100
M.SQLITE_DONE       = 101

-- Column types from sqlite3_column_type.
M.SQLITE_INTEGER = 1
M.SQLITE_FLOAT   = 2
M.SQLITE_TEXT    = 3
M.SQLITE_BLOB    = 4
M.SQLITE_NULL    = 5

-- Open flags for sqlite3_open_v2.
M.SQLITE_OPEN_READONLY      = 0x00000001
M.SQLITE_OPEN_READWRITE     = 0x00000002
M.SQLITE_OPEN_CREATE        = 0x00000004
M.SQLITE_OPEN_URI           = 0x00000040
M.SQLITE_OPEN_MEMORY        = 0x00000080
M.SQLITE_OPEN_NOMUTEX       = 0x00008000
M.SQLITE_OPEN_FULLMUTEX     = 0x00010000
M.SQLITE_OPEN_SHAREDCACHE   = 0x00020000
M.SQLITE_OPEN_PRIVATECACHE  = 0x00040000

-- Special destructor sentinel; -1 cast is SQLITE_TRANSIENT (let sqlite copy).
local SQLITE_TRANSIENT = ffi.cast("void (*)(void *)", -1)

-- ===== DLL probe ========================================================

local _lib_state -- nil = unprobed, false = absent, table = loaded

local function probe()
    if _lib_state ~= nil then return _lib_state end
    local names = {}
    -- Env var override first; supports either a full path or a bare DLL name.
    local override = os.getenv("LUAVM_SQLITE_DLL")
    if override and #override > 0 then names[#names + 1] = override end
    names[#names + 1] = "sqlite3"
    names[#names + 1] = "sqlite3.dll"
    names[#names + 1] = "sqlite.dll"
    names[#names + 1] = "sqlite3-0.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then
            _lib_state = { lib = lib, name = n }
            return _lib_state
        end
    end
    _lib_state = false
    return false
end

local function require_lib()
    local st = probe()
    if st == false then
        error("sqlite: sqlite3.dll not found on the search path. "
            .. "Set LUAVM_SQLITE_DLL, drop sqlite3.dll next to LuaVM, or install sqlite3.")
    end
    return st.lib
end

function M.is_available()
    return probe() ~= false
end

function M.libversion()
    local L = require_lib()
    return ffi.string(L.sqlite3_libversion())
end

-- ===== Helper: raise with db errmsg ====================================

local function db_error(L, db, prefix)
    local msg = ffi.string(L.sqlite3_errmsg(db))
    error("sqlite: " .. prefix .. ": " .. msg, 2)
end

-- ===== stmt object ======================================================

local Stmt = {}
Stmt.__index = Stmt

-- Bind a single value at index idx. Lua type drives the binder choice.
local function bind_one(L, stmt, idx, v)
    if v == nil or v == M.null then
        return L.sqlite3_bind_null(stmt, idx)
    end
    local t = type(v)
    if t == "number" then
        -- Distinguish integer vs float; Lua 5.3+ has math.type.
        if math.type and math.type(v) == "integer" then
            return L.sqlite3_bind_int64(stmt, idx, ffi.cast("long long", v))
        else
            -- Integer-valued float still goes through bind_int64 to keep types tidy.
            if v == math.floor(v) and v >= -2^53 and v <= 2^53 then
                return L.sqlite3_bind_int64(stmt, idx, ffi.cast("long long", v))
            end
            return L.sqlite3_bind_double(stmt, idx, v)
        end
    elseif t == "string" then
        return L.sqlite3_bind_text(stmt, idx, v, #v, SQLITE_TRANSIENT)
    elseif t == "boolean" then
        return L.sqlite3_bind_int(stmt, idx, v and 1 or 0)
    elseif t == "cdata" then
        -- Treat cdata as raw blob; caller must pass {data, len} for length.
        error("sqlite: bind cdata requires {data=ptr, len=n}; got bare cdata", 3)
    elseif t == "table" then
        -- Convention: {blob = string} or {data=ptr, len=n}.
        if v.blob then
            return L.sqlite3_bind_blob(stmt, idx, v.blob, #v.blob, SQLITE_TRANSIENT)
        elseif v.data and v.len then
            return L.sqlite3_bind_blob(stmt, idx, v.data, v.len, SQLITE_TRANSIENT)
        end
        error("sqlite: cannot bind plain table; wrap as {blob=...} or {data=,len=}", 3)
    end
    error("sqlite: cannot bind value of type " .. t, 3)
end

-- params can be array-style (positional ?) or map-style (named :k).
function Stmt:bind(params)
    if params == nil then return self end
    local L = self._lib
    local s = self._stmt
    L.sqlite3_clear_bindings(s)
    local nparams = L.sqlite3_bind_parameter_count(s)
    -- Array vs hash detection: any string key => named binding.
    local is_array = true
    for k in pairs(params) do
        if type(k) ~= "number" then is_array = false; break end
    end
    if is_array then
        for i = 1, nparams do
            bind_one(L, s, i, params[i])
        end
    else
        -- Named: try :name, @name, $name; the user typically passes "name".
        for k, v in pairs(params) do
            if type(k) == "string" then
                local idx = L.sqlite3_bind_parameter_index(s, ":" .. k)
                if idx == 0 then idx = L.sqlite3_bind_parameter_index(s, "@" .. k) end
                if idx == 0 then idx = L.sqlite3_bind_parameter_index(s, "$" .. k) end
                if idx == 0 then
                    error("sqlite: no such bind parameter ':" .. k .. "'", 2)
                end
                bind_one(L, s, idx, v)
            elseif type(k) == "number" then
                bind_one(L, s, k, v)
            end
        end
    end
    return self
end

function Stmt:step()
    local rc = self._lib.sqlite3_step(self._stmt)
    if rc == M.SQLITE_ROW then return "row" end
    if rc == M.SQLITE_DONE then return "done" end
    db_error(self._lib, self._db, "step")
end

-- Pull one row as a column-name-keyed table.
function Stmt:row()
    local L = self._lib
    local s = self._stmt
    local n = L.sqlite3_column_count(s)
    local row = {}
    for i = 0, n - 1 do
        local name = ffi.string(L.sqlite3_column_name(s, i))
        local t = L.sqlite3_column_type(s, i)
        if t == M.SQLITE_INTEGER then
            -- int64 -> Lua number; precision loss above 2^53 is accepted.
            row[name] = tonumber(L.sqlite3_column_int64(s, i))
        elseif t == M.SQLITE_FLOAT then
            row[name] = L.sqlite3_column_double(s, i)
        elseif t == M.SQLITE_TEXT then
            local len = L.sqlite3_column_bytes(s, i)
            row[name] = ffi.string(L.sqlite3_column_text(s, i), len)
        elseif t == M.SQLITE_BLOB then
            local len = L.sqlite3_column_bytes(s, i)
            row[name] = ffi.string(L.sqlite3_column_blob(s, i), len)
        else
            row[name] = nil
        end
    end
    return row
end

function Stmt:reset()
    self._lib.sqlite3_reset(self._stmt)
    return self
end

function Stmt:finalize()
    if self._stmt ~= nil then
        self._lib.sqlite3_finalize(self._stmt)
        self._stmt = nil
    end
end

Stmt.__gc = Stmt.finalize

-- ===== db object ========================================================

local Db = {}
Db.__index = Db

local function new_stmt(db_obj, sql)
    local L = db_obj._lib
    local stmt_pp = ffi.new("sqlite3_stmt*[1]")
    local rc = L.sqlite3_prepare_v2(db_obj._db, sql, #sql, stmt_pp, nil)
    if rc ~= M.SQLITE_OK then
        db_error(L, db_obj._db, "prepare")
    end
    return setmetatable({
        _lib  = L,
        _db   = db_obj._db,
        _stmt = stmt_pp[0],
    }, Stmt)
end

function Db:prepare(sql)
    return new_stmt(self, sql)
end

-- exec runs zero or more statements. For multi-statement SQL with no
-- bindings, we delegate to sqlite3_exec which handles them in a single call.
function Db:exec(sql, params)
    if params == nil then
        local L = self._lib
        local errp = ffi.new("char*[1]")
        local rc = L.sqlite3_exec(self._db, sql, nil, nil, errp)
        if rc ~= M.SQLITE_OK then
            local msg = errp[0] ~= nil and ffi.string(errp[0]) or "exec failed"
            if errp[0] ~= nil then L.sqlite3_free(errp[0]) end
            error("sqlite: exec: " .. msg, 2)
        end
        return L.sqlite3_changes(self._db)
    end
    -- With params, route through prepare/step/finalize.
    local stmt = new_stmt(self, sql)
    stmt:bind(params)
    local rows = {}
    while true do
        local s = stmt:step()
        if s == "done" then break end
        rows[#rows + 1] = stmt:row()
    end
    stmt:finalize()
    if #rows > 0 then return rows end
    return self._lib.sqlite3_changes(self._db)
end

function Db:query(sql, params)
    local stmt = new_stmt(self, sql)
    if params then stmt:bind(params) end
    local rows = {}
    while stmt:step() == "row" do
        rows[#rows + 1] = stmt:row()
    end
    stmt:finalize()
    return rows
end

function Db:query_one(sql, params)
    local stmt = new_stmt(self, sql)
    if params then stmt:bind(params) end
    local row
    if stmt:step() == "row" then row = stmt:row() end
    stmt:finalize()
    return row
end

-- Transaction wrapper. Rolls back on error / explicit false return.
function Db:transaction(fn)
    self:exec("BEGIN")
    local ok, err = pcall(fn, self)
    if not ok then
        self:exec("ROLLBACK")
        error(err, 2)
    end
    if err == false then
        self:exec("ROLLBACK")
        return false
    end
    self:exec("COMMIT")
    return true
end

function Db:changes()             return self._lib.sqlite3_changes(self._db) end
function Db:last_insert_rowid()   return tonumber(self._lib.sqlite3_last_insert_rowid(self._db)) end
function Db:busy_timeout(ms)      return self._lib.sqlite3_busy_timeout(self._db, ms) end
function Db:errmsg()              return ffi.string(self._lib.sqlite3_errmsg(self._db)) end
function Db:total_changes()       return self._lib.sqlite3_total_changes(self._db) end
function Db:memory_used()         return tonumber(self._lib.sqlite3_memory_used()) end

-- Online backup. Loops backup_step until done.
function Db:backup_to(dst_path)
    local L = self._lib
    local dst_pp = ffi.new("sqlite3*[1]")
    local rc = L.sqlite3_open(dst_path, dst_pp)
    if rc ~= M.SQLITE_OK then
        if dst_pp[0] ~= nil then L.sqlite3_close(dst_pp[0]) end
        error("sqlite: backup_to: cannot open destination", 2)
    end
    local b = L.sqlite3_backup_init(dst_pp[0], "main", self._db, "main")
    if b == nil then
        local msg = ffi.string(L.sqlite3_errmsg(dst_pp[0]))
        L.sqlite3_close(dst_pp[0])
        error("sqlite: backup_init: " .. msg, 2)
    end
    -- -1 = all pages in one shot. Loop anyway for safety on busy DBs.
    while true do
        local s = L.sqlite3_backup_step(b, -1)
        if s == M.SQLITE_DONE then break end
        if s ~= M.SQLITE_OK and s ~= M.SQLITE_BUSY and s ~= M.SQLITE_LOCKED then
            L.sqlite3_backup_finish(b)
            L.sqlite3_close(dst_pp[0])
            error("sqlite: backup_step failed: " .. tostring(s), 2)
        end
    end
    L.sqlite3_backup_finish(b)
    L.sqlite3_close(dst_pp[0])
    return true
end

function Db:close()
    if self._db ~= nil then
        self._lib.sqlite3_close_v2(self._db)
        self._db = nil
    end
end

Db.__gc = Db.close

-- ===== Top-level open =================================================

function M.open(path, opts)
    opts = opts or {}
    local L = require_lib()
    local flags = opts.flags
    if flags == nil then
        local mode = opts.mode or "rwc"
        if     mode == "ro"  then flags = M.SQLITE_OPEN_READONLY
        elseif mode == "rw"  then flags = M.SQLITE_OPEN_READWRITE
        elseif mode == "rwc" then flags = M.SQLITE_OPEN_READWRITE + M.SQLITE_OPEN_CREATE
        elseif mode == "memory" then
            flags = M.SQLITE_OPEN_READWRITE + M.SQLITE_OPEN_CREATE + M.SQLITE_OPEN_MEMORY
        else
            error("sqlite: unknown mode '" .. tostring(mode) .. "'", 2)
        end
    end
    if opts.uri then flags = flags + M.SQLITE_OPEN_URI end
    local pp = ffi.new("sqlite3*[1]")
    local rc = L.sqlite3_open_v2(path, pp, flags, nil)
    if rc ~= M.SQLITE_OK then
        local msg = pp[0] ~= nil and ffi.string(L.sqlite3_errmsg(pp[0])) or "open failed"
        if pp[0] ~= nil then L.sqlite3_close(pp[0]) end
        error("sqlite: open '" .. tostring(path) .. "': " .. msg, 2)
    end
    return setmetatable({ _lib = L, _db = pp[0], _path = path }, Db)
end

-- A null sentinel for explicit NULL binds.
M.null = setmetatable({}, { __tostring = function() return "sqlite.null" end })

return M
