return {
    name        = "apperror",
    version     = "1.0",
    description = "Structured error type: message, dotted kind, structured fields, full stack traceback, cause-chain (wrap/unwrap). Pattern matching on kind with prefix support, is() walker, kinds() builder for sealed error sets, try() that lifts thrown non-errors into the same shape, multi-line pretty rendering via __tostring, to_table() for log/JSON shipping.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["apperror"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
