-- ndjson -- newline-delimited JSON (a.k.a. JSON Lines).
--
-- Public surface:
--   ndjson.decode(text, opts?)      -> { values }     (eager full-buffer parse)
--   ndjson.decode_iter(reader)      -> iterator       (reader is fn() -> string|nil)
--   ndjson.encode(values, opts?)    -> string
--   ndjson.line_encoder(emit_fn, opts?) -> fn(value)  (write a single line)
--
-- Each NDJSON record is a single JSON value on its own line. Blank lines
-- are skipped. CR-LF and bare-LF are both accepted as record separators.

local json = require("json")

local M = {}

local sub  = string.sub
local find = string.find
local concat = table.concat

function M.decode(text, opts)
    opts = opts or {}
    if type(text) ~= "string" then error("ndjson.decode: expected string") end
    local out, n = {}, 0
    local i, len = 1, #text
    if sub(text, 1, 3) == "\xEF\xBB\xBF" then i = 4 end
    while i <= len do
        local nl = find(text, "\n", i, true) or (len + 1)
        local line = sub(text, i, nl - 1)
        if sub(line, -1) == "\r" then line = sub(line, 1, -2) end
        if line:match("%S") then
            n = n + 1; out[n] = json.decode(line, opts.json_opts)
        end
        i = nl + 1
    end
    return out
end

function M.decode_iter(reader)
    local buf = ""
    local eof = false
    local function pump()
        local chunk = reader()
        if chunk == nil then eof = true; return false end
        buf = buf .. chunk
        return true
    end
    return function()
        while true do
            local nl = find(buf, "\n", 1, true)
            if not nl then
                if eof then
                    if buf:match("%S") then
                        local line = buf
                        if sub(line, -1) == "\r" then line = sub(line, 1, -2) end
                        buf = ""
                        return json.decode(line)
                    end
                    return nil
                end
                if not pump() then
                    if buf:match("%S") then
                        local line = buf
                        if sub(line, -1) == "\r" then line = sub(line, 1, -2) end
                        buf = ""
                        return json.decode(line)
                    end
                    return nil
                end
            else
                local line = sub(buf, 1, nl - 1)
                buf = sub(buf, nl + 1)
                if sub(line, -1) == "\r" then line = sub(line, 1, -2) end
                if line:match("%S") then
                    return json.decode(line)
                end
            end
        end
    end
end

function M.encode(values, opts)
    opts = opts or {}
    local lines = {}
    for i, v in ipairs(values) do
        -- A line MUST NOT contain a literal newline -- json.encode without
        -- "indent" satisfies that.
        lines[i] = json.encode(v, opts.json_opts)
    end
    return concat(lines, "\n") .. "\n"
end

function M.line_encoder(emit_fn, opts)
    opts = opts or {}
    return function(v)
        emit_fn(json.encode(v, opts.json_opts) .. "\n")
    end
end

return M
