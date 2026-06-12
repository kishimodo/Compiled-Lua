return {
    name        = "cab",
    version     = "1.0",
    description = "Microsoft Cabinet (CAB) archive extractor + creator. Reader uses setupapi.dll's SetupIterateCabinet to enumerate and extract entries (transparently handling MSZIP / Quantum / LZX internally). Creator uses cabinet.dll's FCI to produce single-cabinet archives from in-memory bytes or disk paths. Exposes extract(cab_path, dest_dir), extract_to_memory(cab_path) -> {name=bytes,...}, and create(cab_path, files, opts?). All deps (setupapi.dll, cabinet.dll) ship on every Windows install.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cab"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
