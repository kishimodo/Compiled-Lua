return {
    name        = "scheduler",
    version     = "0.1",
    description = "Windows Task Scheduler v2 wrapper via COM (taskschd.dll). Create / delete / list / run / disable scheduled tasks. Supports daily, weekly, monthly, and one-shot triggers; user / system / interactive identities; lowest / highest run levels.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["scheduler"] = "init.lua",
    },
    requires        = { "windows", "windows.com" },
    requires_native = {},
}
