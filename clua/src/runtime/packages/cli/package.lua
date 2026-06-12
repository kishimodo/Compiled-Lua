return {
    name        = "cli",
    version     = "1.0",
    description = "Argparse-style command-line parser: positionals, options (long + short), boolean flags (with --no-foo negation), subcommands, type coercion (int/float/bool/string), choices, multi-occur, custom actions. Generates --help and shell completion scripts for bash and PowerShell.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cli"] = "init.lua",
    },
    requires        = { "color" },
    requires_native = {},
}
