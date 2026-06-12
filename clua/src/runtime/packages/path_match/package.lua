return {
    name        = "path_match",
    version     = "1.0",
    description = "Find-style boolean predicates over filesystem paths. path_match.pred namespace builds composable path->bool predicates: name(glob), path(glob), ext(ext_or_list), type(kind), size_above(n), size_below(n), mtime_after(t), mtime_before(t), exec(), readable(). Combinators and_/or_/not_/any/all. path_match.find(root, predicate, opts?) walks a tree and returns matches. Legacy size/mtime spec-string forms remain. compile_find(str) parses GNU find-style strings. Soft requires fs.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["path_match"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
