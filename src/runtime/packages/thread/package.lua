return {
    name        = "thread",
    version     = "0.2",
    description = "OS-thread spawn with an isolated lua_State per worker. spawn(fn, args?, opts?{stack_size,name}) accepts a function (string.dump'd), source, or path; args ship via msgpack (preferred) or channel.serialize. Exposes :join(timeout)/:detach()/:id()/:alive()/:raw_handle(), plus thread.current(), thread.cpu_count(). Requires the runtime to export `_luavm_thread_bootstrap` + the Lua C API; until then falls back to cooperative coroutines with the same API surface.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["thread"] = "init.lua",
    },
    requires        = { "windows", "windows.threading", "channel", "event", "msgpack" },
    requires_native = {},
}
