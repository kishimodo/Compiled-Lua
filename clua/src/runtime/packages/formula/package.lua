return {
    name        = "formula",
    version     = "1.0",
    description = "Spreadsheet-style formula parser and evaluator with optional cell-store engine. Handles cell refs (A1, $B$2, Sheet1!A1), ranges (A1:C10), arithmetic, comparisons, string concat with &, and a broad function library (SUM/AVG/IF/VLOOKUP/MATCH/INDEX/text + math + date helpers). Errors propagate as standard #VALUE! / #DIV/0! / #N/A / #REF! / #NAME? / #NUM! sentinels. formula.engine() returns a self-contained store with set/get/formula/dependencies/recalculate plus CSV import/export.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["formula"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
