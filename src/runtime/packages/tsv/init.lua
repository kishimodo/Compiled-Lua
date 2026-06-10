-- tsv -- tab-separated values, implemented over the csv package.
--
-- API mirrors csv exactly; the only difference is delimiter defaults to "\t".

local csv = require("csv")

local M = {}

local function with_tab(opts)
    opts = opts or {}
    if opts.delimiter == nil then opts.delimiter = "\t" end
    return opts
end

function M.decode(text, opts)       return csv.decode(text, with_tab(opts)) end
function M.encode(rows, opts)       return csv.encode(rows, with_tab(opts)) end
function M.reader(input_fn, opts)   return csv.reader(input_fn, with_tab(opts)) end
function M.writer(emit_fn, opts)    return csv.writer(emit_fn, with_tab(opts)) end

return M
