return {
    name        = "kv_file",
    version     = "1.0",
    description = "Append-log key-value store in pure Lua. Each record carries an 8-byte key_len, 8-byte value_len, key + value bytes, and a 4-byte CRC32. Tombstone records mark deletes. In-memory index of key -> file offset is rebuilt on open by linear scan. Single-writer, multiple-readers safe within a process. Compact() rewrites to a sidecar with only the latest record per key, then atomically renames over the original. Suitable for small-to-medium datasets where SQLite/LMDB would be overkill.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["kv_file"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
