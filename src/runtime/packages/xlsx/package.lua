return {
    name        = "xlsx",
    version     = "1.0",
    description = "Excel .xlsx reader + writer. .xlsx is a ZIP of SpreadsheetML XML parts (xl/worksheets/sheetN.xml + xl/sharedStrings.xml + xl/workbook.xml). Reader parses sheets, dimensions, cell values (inline + shared strings + numbers + booleans + dates) and exposes them as rows / records / CSV. Writer builds workbook + shared strings + sheet XML with column letters, number formats, simple styles. A1 / row+col addressing supported. Uses zip + xml packages.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["xlsx"] = "init.lua",
    },
    requires        = { "zip", "xml" },
    requires_native = {},
}
