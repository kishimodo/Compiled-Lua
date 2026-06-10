return {
    name        = "oniguruma",
    version     = "1.0",
    description = "Onigmo / Oniguruma regex bindings via onig.dll. Perl-compatible regex with Ruby extensions and multi-encoding support; an alternative to PCRE2 with broader syntax. Surface: compile(pattern, opts?) -> regex with :match / :find / :gmatch / :gsub / :split / :test. opts: { encoding = 'utf8'|'ascii'|'utf16le'|'sjis' (default utf8), syntax = 'ruby'|'perl'|'posix-ere'|'posix-bre'|'java' (default ruby), options = { i, m, s, x, ignore_case, multiline, dotall, extend, find_longest, find_not_empty } }. Loads onig.dll lazily; raises a descriptive error if absent.",
    license     = "MIT (bindings), BSD-2 (Oniguruma upstream)",
    main        = "init.lua",
    modules     = {
        ["oniguruma"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "onig.dll", mode_default = "embed", env_var = "LUAVM_ONIG_DLL" },
    },
}
