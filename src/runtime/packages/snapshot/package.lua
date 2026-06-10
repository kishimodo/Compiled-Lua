return {
    name        = "snapshot",
    version     = "1.0",
    description = "Snapshot / golden testing. Compares a value to a stored snapshot file under __snapshots__/<test_file>.snap.lua; auto-creates on first run, requires UPDATE_SNAPSHOTS=1 (or update=true) to overwrite. Formats: lua_repr (default), json, text. Normalize hook for masking volatile fields. Unified-line diff on mismatch.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["snapshot"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
