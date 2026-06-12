return {
    name        = "sqlite",
    version     = "1.0",
    description = "SQLite3 bindings via ffi.load(\"sqlite3\"). Full surface: open/close, exec, prepare/step/finalize, bind_int/double/text/blob/null (named :k/@k/$k and positional ?), column_int/double/text/blob/type/count, errmsg, changes, last_insert_rowid, transactions, online backup API, busy_timeout. Returns row arrays keyed by column name. Detect-and-load order: $LUAVM_SQLITE_DLL, sqlite3, sqlite3.dll, sqlite.dll, sqlite3-0.dll. The compiler will eventually embed sqlite3.dll; for now it loads via system search path. Module always require()s cleanly; methods raise a descriptive error if the DLL is missing.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["sqlite"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "sqlite3.dll", mode_default = "embed", env_var = "LUAVM_SQLITE_DLL" },
    },
}
