return {
    name        = "table_fmt",
    version     = "1.0",
    description = "ASCII / box-drawing / markdown / github / CSV / TSV table formatter. Auto-sizes columns, supports per-column alignment, max-width truncation with ellipsis, soft wrapping, and ANSI-aware width calculation. Accepts array-of-arrays or array-of-maps row shapes.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["table_fmt"] = "init.lua",
    },
    requires        = { "color" },
    requires_native = {},
}
