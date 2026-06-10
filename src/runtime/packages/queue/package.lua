return {
    name        = "queue",
    version     = "0.2",
    description = "Lock-free FIFO queues: queue.mpmc(capacity) bounded Vyukov ring (multi-producer / multi-consumer), queue.spsc(capacity) cheaper single-producer / single-consumer variant, and queue.mpmc_unbounded() Michael-Scott linked list. Payloads cross threads via channel.serialize / deserialize so the supported value set matches `channel`.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["queue"] = "init.lua",
    },
    requires        = { "windows", "windows.threading", "atomic", "channel" },
    requires_native = {},
}
