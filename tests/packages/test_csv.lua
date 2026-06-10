-- tests/packages/test_csv.lua : csv encode/decode round-trip including edge cases.
local csv = require "csv"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_csv: " .. tostring(m)) end end

-- Basic round-trip: array-of-arrays
local rows = {
    {"name", "age", "city"},
    {"Alice", "30", "New York"},
    {"Bob",   "25", "San Francisco"},
}
local encoded = csv.encode(rows)
local decoded = csv.decode(encoded)
ok(#decoded == 3, "round-trip row count == 3")
ok(decoded[1][1] == "name" and decoded[1][2] == "age" and decoded[1][3] == "city",
   "round-trip header row")
ok(decoded[2][1] == "Alice" and decoded[2][2] == "30" and decoded[2][3] == "New York",
   "round-trip data row 1")
ok(decoded[3][1] == "Bob" and decoded[3][2] == "25" and decoded[3][3] == "San Francisco",
   "round-trip data row 2")

-- Quoted field containing a comma
local with_comma = {{"hello, world", "plain"}}
local enc_comma = csv.encode(with_comma)
local dec_comma = csv.decode(enc_comma)
ok(dec_comma[1][1] == "hello, world", "round-trip field with comma")
ok(dec_comma[1][2] == "plain",        "plain field after quoted")

-- Quoted field containing a double-quote (RFC 4180 doubles the quote)
local with_quote = {{'say "hi"', "ok"}}
local enc_quote = csv.encode(with_quote)
local dec_quote = csv.decode(enc_quote)
ok(dec_quote[1][1] == 'say "hi"', "round-trip field with embedded double-quote")

-- Quoted field containing a newline
local with_nl = {{"line1\nline2", "x"}}
local enc_nl = csv.encode(with_nl)
local dec_nl = csv.decode(enc_nl)
ok(dec_nl[1][1] == "line1\nline2", "round-trip field with embedded newline")

-- Single-field round-trip
local single = {{"only"}}
ok(csv.decode(csv.encode(single))[1][1] == "only", "single-field round-trip")

-- Empty field round-trip
local empty_field = {{"a", "", "b"}}
local dec_empty = csv.decode(csv.encode(empty_field))
ok(dec_empty[1][2] == "", "empty field round-trips as empty string")

-- decode with headers option
local hdr_data = "id,name\r\n1,Alice\r\n2,Bob\r\n"
local hdr_rows = csv.decode(hdr_data, { headers = true })
ok(#hdr_rows == 2,              "headers=true gives 2 data rows")
ok(hdr_rows[1].id == "1",       "headers: row1.id == '1'")
ok(hdr_rows[1].name == "Alice", "headers: row1.name == 'Alice'")
ok(hdr_rows[2].id == "2",       "headers: row2.id == '2'")
ok(hdr_rows[2].name == "Bob",   "headers: row2.name == 'Bob'")

-- Custom delimiter
local tsv_data = "a\tb\tc"
local tsv_rows = csv.decode(tsv_data, { delimiter = "\t" })
ok(#tsv_rows[1] == 3,          "custom delimiter: 3 fields")
ok(tsv_rows[1][2] == "b",      "custom delimiter: middle field")

if fails == 0 then print("[+] PASS test_csv") os.exit(0) else os.exit(1) end
