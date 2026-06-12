-- cobs -- Consistent Overhead Byte Stuffing.
--
-- Public surface:
--   cobs.encode(bytes) -> string   (no trailing 0x00 sentinel)
--   cobs.decode(bytes) -> string
--
-- Encoded output never contains 0x00. Callers wanting a frame delimiter
-- should append a single 0x00 byte to the encoded result themselves.

local M = {}

function M.encode(bytes)
    if type(bytes) ~= "string" then
        error("cobs.encode: expected string, got " .. type(bytes))
    end
    local len = #bytes
    local out, n = {}, 0
    local code = 1
    local code_index = 1
    -- Reserve a slot for the first code byte.
    n = n + 1; out[n] = "\0"
    for i = 1, len do
        local b = bytes:byte(i)
        if b == 0 then
            -- Write the current code into its slot and start a new block.
            out[code_index] = string.char(code)
            n = n + 1; out[n] = "\0"
            code_index = n
            code = 1
        else
            n = n + 1; out[n] = string.char(b)
            code = code + 1
            if code == 0xFF then
                -- Block reached max length without a zero -- finalize and start next.
                out[code_index] = string.char(code)
                n = n + 1; out[n] = "\0"
                code_index = n
                code = 1
            end
        end
    end
    -- Final code byte.
    out[code_index] = string.char(code)
    return table.concat(out)
end

function M.decode(bytes)
    if type(bytes) ~= "string" then
        error("cobs.decode: expected string, got " .. type(bytes))
    end
    local len = #bytes
    local out, n = {}, 0
    local i = 1
    while i <= len do
        local code = bytes:byte(i)
        if code == 0 then
            error("cobs.decode: unexpected zero byte in encoded data")
        end
        i = i + 1
        for k = 1, code - 1 do
            if i > len then
                error("cobs.decode: truncated block")
            end
            local b = bytes:byte(i)
            if b == 0 then
                error("cobs.decode: unexpected zero inside block")
            end
            n = n + 1; out[n] = string.char(b)
            i = i + 1
        end
        -- Implicit zero between blocks, unless this was a 0xFF block (no implicit zero)
        -- or we've reached end of input.
        if code < 0xFF and i <= len then
            n = n + 1; out[n] = "\0"
        end
    end
    return table.concat(out)
end

return M
