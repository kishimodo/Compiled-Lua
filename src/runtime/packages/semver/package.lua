return {
    name        = "semver",
    version     = "1.0",
    description = "Semantic Versioning 2.0.0 parser, comparator, and constraint matcher. parse(s) returns a version object with :major/:minor/:patch/:prerelease/:build/:tostring accessors and < <= == metamethods. range(s) returns a range object with :matches(v)/:tostring. Plus procedural compare/eq/lt/gt/satisfies, max_satisfying/min_satisfying, inc(v, level), clean, is_valid. Handles pre-release / build metadata per spec; npm-style ranges (^, ~, x-ranges, hyphen, ||, simple operator). Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["semver"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
