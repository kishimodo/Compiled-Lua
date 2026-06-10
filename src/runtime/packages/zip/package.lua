return {
    name        = "zip",
    version     = "1.0",
    description = "PKZIP archive reader + writer. open() returns a reader with :list / :read / :extract_all; create() returns a writer with :add_file / :add_path / :close. Parses the End Of Central Directory record, walks the Central Directory, decodes local file headers and reads stored / deflated entries. Handles ZIP64 for archives over 4 GiB / 65535 entries. Uses the zlib package for inflate / deflate where available; gracefully falls back to stored-only mode if zlib isn't on the load path.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["zip"] = "init.lua",
    },
    requires        = { "zlib" },
    requires_native = {},
}
