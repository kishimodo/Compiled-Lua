-- lmdb -- LMDB (Lightning Memory-Mapped Database) bindings via ffi.load("lmdb").
--
-- LMDB is a B+tree key-value store backed by mmap. Reads are zero-copy and
-- non-blocking (MVCC; readers don't block writers and vice versa). Writes
-- are serialized through a single writer lock. The on-disk format is the
-- file itself plus a lock file -- no journal, no WAL.
--
-- Public surface:
--   lmdb.open(path, opts?)           -> env
--     opts: { map_size_mb=128, max_dbs=8, readonly=false, no_subdir=false,
--             no_sync=false, no_meta_sync=false, write_map=false }
--   lmdb.is_available()              -> bool
--   lmdb.version()                   -> "major.minor.patch"
--
-- env:
--   env:open_db(name?, opts?)        -> db    (opts: {create=true, dupsort=false})
--   env:transaction(opts?, fn)       -- opts: {write=true|false}; rolls back on error
--   env:begin_txn(opts?)             -> txn   (manual transaction; commit/abort)
--   env:close()
--   env:stat()                       -> {entries=, depth=, branch_pages=, ...}
--   env:sync(force?)
--
-- txn:
--   txn:commit() / txn:abort() / txn:reset() / txn:renew()
--
-- db:
--   db:get(key, txn?)                -> value | nil
--   db:put(key, value, txn?)
--   db:delete(key, txn?)
--   db:cursor(txn?)                  -> cursor
--   db:stat(txn?)
--
-- cursor:
--   :first() / :last() / :next() / :prev() / :seek(key) / :seek_range(key)
--   :get()                           -> key, value (current position)
--   :put(key, value) / :delete()
--   :close()
--
-- Strings, binary blobs (Lua 8-bit-clean strings), and integers (coerced
-- to ASCII text) are all valid keys/values. LMDB itself is agnostic.
--
-- DLL load order (first hit wins):
--   1. $LUAVM_LMDB_DLL env var
--   2. "lmdb"
--   3. "lmdb.dll"
--   4. "liblmdb.dll"
-- The compiler will eventually embed lmdb.dll; for now we probe lazily.

local ffi = ffi

local M = {}

ffi.cdef[[
/* ===== Opaque handles ===== */
typedef struct MDB_env   MDB_env;
typedef struct MDB_txn   MDB_txn;
typedef struct MDB_cursor MDB_cursor;
typedef unsigned int     MDB_dbi;

/* ===== MDB_val: pointer + length, used for both keys and values ===== */
typedef struct MDB_val {
    size_t mv_size;
    void  *mv_data;
} MDB_val;

/* ===== MDB_stat ===== */
typedef struct MDB_stat {
    unsigned int ms_psize;
    unsigned int ms_depth;
    size_t       ms_branch_pages;
    size_t       ms_leaf_pages;
    size_t       ms_overflow_pages;
    size_t       ms_entries;
} MDB_stat;

/* ===== Environment ===== */
int  mdb_env_create(MDB_env **env);
int  mdb_env_open(MDB_env *env, const char *path, unsigned int flags, unsigned int mode);
void mdb_env_close(MDB_env *env);
int  mdb_env_set_mapsize(MDB_env *env, size_t size);
int  mdb_env_set_maxdbs(MDB_env *env, MDB_dbi dbs);
int  mdb_env_set_maxreaders(MDB_env *env, unsigned int readers);
int  mdb_env_sync(MDB_env *env, int force);
int  mdb_env_stat(MDB_env *env, MDB_stat *stat);

/* ===== Transactions ===== */
int  mdb_txn_begin(MDB_env *env, MDB_txn *parent, unsigned int flags, MDB_txn **txn);
int  mdb_txn_commit(MDB_txn *txn);
void mdb_txn_abort(MDB_txn *txn);
void mdb_txn_reset(MDB_txn *txn);
int  mdb_txn_renew(MDB_txn *txn);

/* ===== Database (named subtree of env) ===== */
int  mdb_dbi_open(MDB_txn *txn, const char *name, unsigned int flags, MDB_dbi *dbi);
void mdb_dbi_close(MDB_env *env, MDB_dbi dbi);
int  mdb_drop(MDB_txn *txn, MDB_dbi dbi, int del);
int  mdb_stat(MDB_txn *txn, MDB_dbi dbi, MDB_stat *stat);

/* ===== CRUD ===== */
int  mdb_get(MDB_txn *txn, MDB_dbi dbi, MDB_val *key, MDB_val *data);
int  mdb_put(MDB_txn *txn, MDB_dbi dbi, MDB_val *key, MDB_val *data, unsigned int flags);
int  mdb_del(MDB_txn *txn, MDB_dbi dbi, MDB_val *key, MDB_val *data);

/* ===== Cursor ===== */
int  mdb_cursor_open(MDB_txn *txn, MDB_dbi dbi, MDB_cursor **cursor);
void mdb_cursor_close(MDB_cursor *cursor);
int  mdb_cursor_renew(MDB_txn *txn, MDB_cursor *cursor);
int  mdb_cursor_get(MDB_cursor *cursor, MDB_val *key, MDB_val *data, int op);
int  mdb_cursor_put(MDB_cursor *cursor, MDB_val *key, MDB_val *data, unsigned int flags);
int  mdb_cursor_del(MDB_cursor *cursor, unsigned int flags);

/* ===== Misc ===== */
const char *mdb_strerror(int err);
char       *mdb_version(int *major, int *minor, int *patch);
]]

-- ===== Constants ========================================================

-- mdb_env_open flags.
M.MDB_FIXEDMAP   = 0x01
M.MDB_NOSUBDIR   = 0x4000
M.MDB_NOSYNC     = 0x10000
M.MDB_RDONLY     = 0x20000
M.MDB_NOMETASYNC = 0x40000
M.MDB_WRITEMAP   = 0x80000
M.MDB_MAPASYNC   = 0x100000
M.MDB_NOTLS      = 0x200000
M.MDB_NOLOCK     = 0x400000
M.MDB_NORDAHEAD  = 0x800000
M.MDB_NOMEMINIT  = 0x1000000

-- mdb_dbi_open flags.
M.MDB_REVERSEKEY = 0x02
M.MDB_DUPSORT    = 0x04
M.MDB_INTEGERKEY = 0x08
M.MDB_DUPFIXED   = 0x10
M.MDB_INTEGERDUP = 0x20
M.MDB_REVERSEDUP = 0x40
M.MDB_CREATE     = 0x40000

-- mdb_put / mdb_cursor_put flags.
M.MDB_NOOVERWRITE = 0x10
M.MDB_NODUPDATA   = 0x20
M.MDB_CURRENT     = 0x40
M.MDB_RESERVE     = 0x10000
M.MDB_APPEND      = 0x20000
M.MDB_APPENDDUP   = 0x40000
M.MDB_MULTIPLE    = 0x80000

-- Cursor op codes (MDB_cursor_op enum).
M.MDB_FIRST          = 0
M.MDB_FIRST_DUP      = 1
M.MDB_GET_BOTH       = 2
M.MDB_GET_BOTH_RANGE = 3
M.MDB_GET_CURRENT    = 4
M.MDB_GET_MULTIPLE   = 5
M.MDB_LAST           = 6
M.MDB_LAST_DUP       = 7
M.MDB_NEXT           = 8
M.MDB_NEXT_DUP       = 9
M.MDB_NEXT_MULTIPLE  = 10
M.MDB_NEXT_NODUP     = 11
M.MDB_PREV           = 12
M.MDB_PREV_DUP       = 13
M.MDB_PREV_NODUP     = 14
M.MDB_SET            = 15
M.MDB_SET_KEY        = 16
M.MDB_SET_RANGE      = 17

-- Common return codes.
M.MDB_SUCCESS         = 0
M.MDB_KEYEXIST        = -30799
M.MDB_NOTFOUND        = -30798
M.MDB_PAGE_NOTFOUND   = -30797
M.MDB_CORRUPTED       = -30796
M.MDB_PANIC           = -30795
M.MDB_VERSION_MISMATCH = -30794
M.MDB_INVALID         = -30793
M.MDB_MAP_FULL        = -30792
M.MDB_DBS_FULL        = -30791
M.MDB_READERS_FULL    = -30790
M.MDB_TXN_FULL        = -30788

-- ===== DLL probe ========================================================

local _lib_state

local function probe()
    if _lib_state ~= nil then return _lib_state end
    local names = {}
    local override = os.getenv("LUAVM_LMDB_DLL")
    if override and #override > 0 then names[#names + 1] = override end
    names[#names + 1] = "lmdb"
    names[#names + 1] = "lmdb.dll"
    names[#names + 1] = "liblmdb.dll"
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
        error("lmdb: lmdb.dll not found on the search path. "
            .. "Set LUAVM_LMDB_DLL, drop lmdb.dll next to LuaVM, or install LMDB.")
    end
    return st.lib
end

function M.is_available() return probe() ~= false end

function M.version()
    local L = require_lib()
    local maj = ffi.new("int[1]")
    local mn  = ffi.new("int[1]")
    local pt  = ffi.new("int[1]")
    L.mdb_version(maj, mn, pt)
    return string.format("%d.%d.%d", maj[0], mn[0], pt[0])
end

local function check(L, rc, what)
    if rc ~= 0 then
        error("lmdb: " .. what .. ": " .. ffi.string(L.mdb_strerror(rc)), 3)
    end
end

-- ===== Internal val helpers ============================================

-- Build an MDB_val pointing at a Lua string. We MUST keep the source string
-- alive across the FFI call -- LMDB doesn't copy keys/values during put.
-- LuaJIT pins strings during a single Lua call, so this is safe inside one
-- C call but NOT if the val outlives the function returning it.
local function make_val(s)
    local v = ffi.new("MDB_val")
    v.mv_size = #s
    v.mv_data = ffi.cast("void *", s)
    return v
end

local function val_to_string(v)
    return ffi.string(v.mv_data, tonumber(v.mv_size))
end

-- ===== txn object ======================================================

local Txn = {}
Txn.__index = Txn

function Txn:commit()
    if self._txn ~= nil then
        local rc = self._lib.mdb_txn_commit(self._txn)
        self._txn = nil
        check(self._lib, rc, "txn_commit")
    end
end

function Txn:abort()
    if self._txn ~= nil then
        self._lib.mdb_txn_abort(self._txn)
        self._txn = nil
    end
end

function Txn:reset() self._lib.mdb_txn_reset(self._txn) end

function Txn:renew()
    local rc = self._lib.mdb_txn_renew(self._txn)
    check(self._lib, rc, "txn_renew")
end

Txn.__gc = function(self)
    if self._txn ~= nil then self._lib.mdb_txn_abort(self._txn) end
end

-- ===== cursor object ===================================================

local Cursor = {}
Cursor.__index = Cursor

local function cursor_op(self, op)
    local k = ffi.new("MDB_val")
    local v = ffi.new("MDB_val")
    local rc = self._lib.mdb_cursor_get(self._cur, k, v, op)
    if rc == M.MDB_NOTFOUND then return nil end
    if rc ~= 0 then
        error("lmdb: cursor op " .. op .. ": " .. ffi.string(self._lib.mdb_strerror(rc)), 2)
    end
    return val_to_string(k), val_to_string(v)
end

function Cursor:first()      return cursor_op(self, M.MDB_FIRST) end
function Cursor:last()       return cursor_op(self, M.MDB_LAST)  end
function Cursor:next()       return cursor_op(self, M.MDB_NEXT)  end
function Cursor:prev()       return cursor_op(self, M.MDB_PREV)  end
function Cursor:get()        return cursor_op(self, M.MDB_GET_CURRENT) end

-- Exact-key seek; nil if not found.
function Cursor:seek(key)
    local k = make_val(key)
    local v = ffi.new("MDB_val")
    local rc = self._lib.mdb_cursor_get(self._cur, k, v, M.MDB_SET_KEY)
    if rc == M.MDB_NOTFOUND then return nil end
    if rc ~= 0 then
        error("lmdb: cursor seek: " .. ffi.string(self._lib.mdb_strerror(rc)), 2)
    end
    return val_to_string(k), val_to_string(v)
end

-- Range seek; positions at the first key >= the input.
function Cursor:seek_range(key)
    local k = make_val(key)
    local v = ffi.new("MDB_val")
    local rc = self._lib.mdb_cursor_get(self._cur, k, v, M.MDB_SET_RANGE)
    if rc == M.MDB_NOTFOUND then return nil end
    if rc ~= 0 then
        error("lmdb: cursor seek_range: " .. ffi.string(self._lib.mdb_strerror(rc)), 2)
    end
    return val_to_string(k), val_to_string(v)
end

function Cursor:put(key, value, flags)
    local k = make_val(key)
    local v = make_val(value)
    local rc = self._lib.mdb_cursor_put(self._cur, k, v, flags or 0)
    check(self._lib, rc, "cursor_put")
end

function Cursor:delete()
    local rc = self._lib.mdb_cursor_del(self._cur, 0)
    check(self._lib, rc, "cursor_del")
end

function Cursor:close()
    if self._cur ~= nil then
        self._lib.mdb_cursor_close(self._cur)
        self._cur = nil
    end
end

Cursor.__gc = Cursor.close

-- ===== db object =======================================================

local Db = {}
Db.__index = Db

-- Resolve a transaction: explicit arg, or self._env's "current" txn.
local function tx_of(self, txn)
    if txn then return txn._txn end
    if self._env._cur_txn then return self._env._cur_txn._txn end
    error("lmdb: db op outside a transaction (pass txn or use env:transaction())", 3)
end

function Db:get(key, txn)
    local L = self._lib
    local k = make_val(key)
    local v = ffi.new("MDB_val")
    local rc = L.mdb_get(tx_of(self, txn), self._dbi, k, v)
    if rc == M.MDB_NOTFOUND then return nil end
    if rc ~= 0 then error("lmdb: get: " .. ffi.string(L.mdb_strerror(rc)), 2) end
    return val_to_string(v)
end

function Db:put(key, value, txn, flags)
    local L = self._lib
    local k = make_val(key)
    local v = make_val(value)
    local rc = L.mdb_put(tx_of(self, txn), self._dbi, k, v, flags or 0)
    check(L, rc, "put")
end

function Db:delete(key, txn)
    local L = self._lib
    local k = make_val(key)
    local rc = L.mdb_del(tx_of(self, txn), self._dbi, k, nil)
    if rc == M.MDB_NOTFOUND then return false end
    check(L, rc, "del")
    return true
end

function Db:cursor(txn)
    local L = self._lib
    local pp = ffi.new("MDB_cursor*[1]")
    local rc = L.mdb_cursor_open(tx_of(self, txn), self._dbi, pp)
    check(L, rc, "cursor_open")
    return setmetatable({ _lib = L, _cur = pp[0] }, Cursor)
end

function Db:stat(txn)
    local L = self._lib
    local st = ffi.new("MDB_stat")
    local rc = L.mdb_stat(tx_of(self, txn), self._dbi, st)
    check(L, rc, "stat")
    return {
        psize          = st.ms_psize,
        depth          = st.ms_depth,
        branch_pages   = tonumber(st.ms_branch_pages),
        leaf_pages     = tonumber(st.ms_leaf_pages),
        overflow_pages = tonumber(st.ms_overflow_pages),
        entries        = tonumber(st.ms_entries),
    }
end

-- ===== env object ======================================================

local Env = {}
Env.__index = Env

local function begin_raw_txn(env, flags)
    local L = env._lib
    local pp = ffi.new("MDB_txn*[1]")
    local rc = L.mdb_txn_begin(env._env, nil, flags or 0, pp)
    check(L, rc, "txn_begin")
    return setmetatable({ _lib = L, _txn = pp[0], _env = env }, Txn)
end

function Env:begin_txn(opts)
    opts = opts or {}
    local flags = (opts.write == false or opts.readonly) and M.MDB_RDONLY or 0
    return begin_raw_txn(self, flags)
end

-- transaction(opts, fn) or transaction(fn). The fn is called with (txn).
function Env:transaction(opts, fn)
    if type(opts) == "function" then fn = opts; opts = {} end
    opts = opts or {}
    local txn = self:begin_txn(opts)
    self._cur_txn = txn
    local ok, ret = pcall(fn, txn)
    self._cur_txn = nil
    if not ok then
        txn:abort()
        error(ret, 2)
    end
    if ret == false then
        txn:abort()
        return false
    end
    txn:commit()
    return ret == nil and true or ret
end

-- Opens (or creates) a named database inside the env.
function Env:open_db(name, opts)
    opts = opts or {}
    local L = self._lib
    -- dbi_open must be called inside a transaction. We open a temporary
    -- write txn, take the dbi, commit so the dbi is registered persistently.
    local txn = self:begin_txn({ write = true })
    local flags = 0
    if opts.create ~= false then flags = flags + M.MDB_CREATE end
    if opts.dupsort then flags = flags + M.MDB_DUPSORT end
    if opts.reverse_key then flags = flags + M.MDB_REVERSEKEY end
    if opts.integer_key then flags = flags + M.MDB_INTEGERKEY end
    local dbi_p = ffi.new("MDB_dbi[1]")
    local rc = L.mdb_dbi_open(txn._txn, name, flags, dbi_p)
    if rc ~= 0 then
        txn:abort()
        error("lmdb: dbi_open: " .. ffi.string(L.mdb_strerror(rc)), 2)
    end
    txn:commit()
    return setmetatable({ _lib = L, _env = self, _dbi = dbi_p[0], _name = name }, Db)
end

function Env:sync(force) self._lib.mdb_env_sync(self._env, force and 1 or 0) end

function Env:stat()
    local L = self._lib
    local st = ffi.new("MDB_stat")
    local rc = L.mdb_env_stat(self._env, st)
    check(L, rc, "env_stat")
    return {
        psize          = st.ms_psize,
        depth          = st.ms_depth,
        branch_pages   = tonumber(st.ms_branch_pages),
        leaf_pages     = tonumber(st.ms_leaf_pages),
        overflow_pages = tonumber(st.ms_overflow_pages),
        entries        = tonumber(st.ms_entries),
    }
end

function Env:close()
    if self._env ~= nil then
        self._lib.mdb_env_close(self._env)
        self._env = nil
    end
end

Env.__gc = Env.close

-- ===== Top-level open =================================================

function M.open(path, opts)
    opts = opts or {}
    local L = require_lib()

    local pp = ffi.new("MDB_env*[1]")
    local rc = L.mdb_env_create(pp)
    check(L, rc, "env_create")
    local env = pp[0]

    local map_bytes = (opts.map_size_mb or 128) * 1024 * 1024
    rc = L.mdb_env_set_mapsize(env, map_bytes)
    if rc ~= 0 then L.mdb_env_close(env); check(L, rc, "set_mapsize") end

    rc = L.mdb_env_set_maxdbs(env, opts.max_dbs or 8)
    if rc ~= 0 then L.mdb_env_close(env); check(L, rc, "set_maxdbs") end

    if opts.max_readers then
        rc = L.mdb_env_set_maxreaders(env, opts.max_readers)
        if rc ~= 0 then L.mdb_env_close(env); check(L, rc, "set_maxreaders") end
    end

    local flags = 0
    if opts.readonly      then flags = flags + M.MDB_RDONLY end
    if opts.no_subdir     then flags = flags + M.MDB_NOSUBDIR end
    if opts.no_sync       then flags = flags + M.MDB_NOSYNC end
    if opts.no_meta_sync  then flags = flags + M.MDB_NOMETASYNC end
    if opts.write_map     then flags = flags + M.MDB_WRITEMAP end
    if opts.map_async     then flags = flags + M.MDB_MAPASYNC end
    if opts.no_tls        then flags = flags + M.MDB_NOTLS end

    rc = L.mdb_env_open(env, path, flags, tonumber(opts.mode or 0x1B6)) -- 0666
    if rc ~= 0 then
        L.mdb_env_close(env)
        error("lmdb: env_open '" .. tostring(path) .. "': " .. ffi.string(L.mdb_strerror(rc)), 2)
    end

    return setmetatable({ _lib = L, _env = env, _path = path }, Env)
end

return M
