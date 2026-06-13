return {
    name        = "lmdb",
    version     = "1.0",
    description = "LMDB (Lightning Memory-Mapped Database) bindings via ffi.load(\"lmdb\"). mmap-backed B+tree KV store with MVCC reads, single-writer transactions, named sub-databases, cursors. Surface: env create/open/close/sync/stat, txn begin/commit/abort/reset/renew, dbi open/close/drop/stat, get/put/del, cursor open/first/last/next/prev/seek/seek_range/put/del/close. Strings and binary 8-bit-clean values. DLL load order: $CLUA_LMDB_DLL, lmdb, lmdb.dll, liblmdb.dll. Compiler will eventually embed lmdb.dll; for now probes system search path lazily and errors clearly if missing.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["lmdb"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "lmdb.dll", mode_default = "embed", env_var = "CLUA_LMDB_DLL" },
    },
}
