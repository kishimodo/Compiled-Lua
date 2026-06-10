return {
    name        = "tar",
    version     = "1.0",
    description = "POSIX ustar tape-archive reader + writer with PAX and GNU long-name extensions. open() returns a reader with :list / :read / :extract_all / :iter; create() returns a writer with :add_file / :add_path / :close. Parses 512-byte headers, checksum-validates them, and yields each entry with a ready-to-consume content slice. PAX extended headers (typeflag 'x' / 'g') are decoded so long paths and >8 GiB files round-trip cleanly. Helper gzip / gunzip wrap the zlib package for .tar.gz workflows.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tar"] = "init.lua",
    },
    requires        = { "zlib" },
    requires_native = {},
}
