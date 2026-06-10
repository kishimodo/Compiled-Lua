local ndjson = require "ndjson"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_ndjson: " .. tostring(m)) end end

-- ---- encode: shape of the produced text -------------------------------------
-- A list of objects with float fields. 3.14 and 1e300 must survive as floats
-- (they carry fractional/exponent parts, so %.17g keeps them non-integer).
local records = {
    { id = 1, ratio = 3.14,  tag = "alpha" },
    { id = 2, ratio = 1e300, tag = "beta"  },
    { id = 3, ratio = 2.5,   tag = "gamma" },
}

local text = ndjson.encode(records)

-- The result ends with exactly one trailing newline.
ok(type(text) == "string", "encode returns a string")
ok(text:sub(-1) == "\n", "encoded text ends with a newline")
ok(text:sub(-2) ~= "\n\n", "encoded text has no double trailing newline")

-- Splitting on \n yields one JSON object per non-empty line.
local lines = {}
for line in (text):gmatch("([^\n]*)\n") do
    if line ~= "" then lines[#lines + 1] = line end
end
ok(#lines == 3, "three records produce three non-empty lines, got " .. #lines)
for i, line in ipairs(lines) do
    ok(line:sub(1, 1) == "{", "line " .. i .. " is a JSON object (starts with '{')")
    ok(line:find("\n", 1, true) == nil, "line " .. i .. " contains no embedded newline")
end

-- ---- round-trip: floats recovered exactly -----------------------------------
local back = ndjson.decode(text)
ok(type(back) == "table", "decode returns a table")
ok(#back == 3, "decode recovers three records, got " .. tostring(#back))

ok(back[1].id == 1, "record 1 id preserved")
ok(back[1].ratio == 3.14, "record 1 float 3.14 round-trips exactly")
ok(back[1].tag == "alpha", "record 1 string preserved")

ok(back[2].id == 2, "record 2 id preserved")
ok(back[2].ratio == 1e300, "record 2 float 1e300 round-trips exactly")
ok(back[2].tag == "beta", "record 2 string preserved")

ok(back[3].ratio == 2.5, "record 3 float 2.5 round-trips exactly")

-- Floats stay floats (math.type), integers stay integers.
ok(math.type(back[1].ratio) == "float", "3.14 decodes as a float")
ok(math.type(back[2].ratio) == "float", "1e300 decodes as a float")
ok(math.type(back[1].id) == "integer", "integer id decodes as an integer")

-- ---- encode of a single scalar value per line -------------------------------
local scalars = ndjson.encode({ 10, "hi", true })
local sback = ndjson.decode(scalars)
ok(#sback == 3, "scalar list round-trips to three values")
ok(sback[1] == 10 and sback[2] == "hi" and sback[3] == true, "scalar values preserved")

-- ---- blank lines are skipped on decode --------------------------------------
local with_blanks = ndjson.decode('{"a":1}\n\n   \n{"a":2}\n')
ok(#with_blanks == 2, "blank/whitespace-only lines are skipped, got " .. #with_blanks)
ok(with_blanks[1].a == 1 and with_blanks[2].a == 2, "non-blank records survive blank skipping")

-- ---- CRLF separators accepted -----------------------------------------------
local crlf = ndjson.decode('{"x":1}\r\n{"x":2}\r\n')
ok(#crlf == 2, "CRLF separators yield two records, got " .. #crlf)
ok(crlf[1].x == 1 and crlf[2].x == 2, "CRLF records decode without trailing \\r corruption")

-- ---- empty input -> empty list ----------------------------------------------
ok(type(ndjson.decode("")) == "table" and #ndjson.decode("") == 0, "empty string decodes to empty list")
local empty_enc = ndjson.encode({})
ok(ndjson.decode(empty_enc) ~= nil and #ndjson.decode(empty_enc) == 0, "encode({}) round-trips to empty list")

if fails == 0 then print("[+] PASS test_ndjson") os.exit(0) else os.exit(1) end
