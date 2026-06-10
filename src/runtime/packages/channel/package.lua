return {
    name        = "channel",
    version     = "0.2",
    description = "Go-style channels: channel.make(capacity?), :send(v,t?)/:receive(t?)/:try_send/:try_receive/:close/:iter, channel.select{{ch,'send',v},{ch,'receive'},default=fn}. Bounded + unbounded, broadcast close, timeout support, and a binary serializer that round-trips nil / bool / int64 / double / string / table (with cycle handling).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["channel"] = "init.lua",
    },
    requires        = { "windows", "windows.threading", "atomic" },
    requires_native = {},
}
