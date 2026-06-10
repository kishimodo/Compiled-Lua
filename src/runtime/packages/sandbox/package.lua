return {
    name        = "sandbox",
    version     = "1.0",
    description = "App-container / Job-object sandboxing primitives. Job objects (CreateJobObjectW, SetInformationJobObject) with CPU / memory / process-count / UI restrictions and kill-on-close semantics. Restricted tokens (CreateRestrictedToken). App containers (CreateAppContainerProfile + DeriveAppContainerSidFromAppContainerName) for low-privilege child processes. Process mitigations (SetProcessMitigationPolicy / UpdateProcThreadAttribute) for DEP, ASLR, CFG, ACG, dynamic-code, child-process, font-disable, image-load policy.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["sandbox"] = "init.lua",
    },
    requires        = { "windows", "windows.security", "process" },
    requires_native = {},
}
