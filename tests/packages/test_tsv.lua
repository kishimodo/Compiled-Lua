local tsv = require "tsv"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_tsv: " .. tostring(m)) end end

-- Reference rows: includes a field with an embedded tab, a field with an
-- embedded newline, and empty fields. These must survive a round-trip.
local rows = {
  { "id", "name", "note" },
  { "1", "alpha", "plain" },
  { "2", "has\ttab", "" },                 -- embedded tab + trailing empty
  { "3", "", "line1\nline2" },             -- empty middle + embedded newline
  { "4", "quote\"inside", "comma,ok" },    -- embedded quote char; comma is NOT special for tsv
}

-- encode should quote fields containing the tab delimiter, quote char, or newline.
local text = tsv.encode(rows)
ok(type(text) == "string", "encode returns a string")

-- Spot-check the wire format against KNOWN-CORRECT expectations (tab delimiter, \r\n rows).
-- Header row: three plain fields joined by tabs.
ok(text:find("id\tname\tnote\r\n", 1, true) == 1, "header row is tab-joined with CRLF")
-- A tab-containing field must be quoted (so the tab is not seen as a separator).
ok(text:find('"has\ttab"', 1, true) ~= nil, "embedded tab field is quoted")
-- A newline-containing field must be quoted.
ok(text:find('"line1\nline2"', 1, true) ~= nil, "embedded newline field is quoted")
-- An embedded quote is doubled (RFC 4180) inside a quoted field.
ok(text:find('"quote""inside"', 1, true) ~= nil, "embedded quote is doubled and quoted")
-- A comma is NOT the tsv delimiter, so a comma-only field stays bare.
ok(text:find("comma,ok", 1, true) ~= nil, "comma is not special for tsv")

-- decode should recover the exact same row/field structure.
local back = tsv.decode(text)
ok(type(back) == "table", "decode returns a table")
ok(#back == #rows, "row count preserved (" .. tostring(#back) .. " vs " .. tostring(#rows) .. ")")

for r = 1, #rows do
  local got, want = back[r], rows[r]
  ok(type(got) == "table", "row " .. r .. " is a table")
  if type(got) == "table" then
    ok(#got == #want, "row " .. r .. " field count (" .. tostring(#got) .. " vs " .. tostring(#want) .. ")")
    for f = 1, #want do
      ok(got[f] == want[f],
        "row " .. r .. " field " .. f .. " mismatch: " ..
        string.format("%q", tostring(got[f])) .. " vs " .. string.format("%q", tostring(want[f])))
    end
  end
end

-- Explicit checks on the load-bearing recovered values.
ok(back[3] and back[3][2] == "has\ttab", "embedded tab recovered")
ok(back[3] and back[3][3] == "", "trailing empty field recovered")
ok(back[4] and back[4][2] == "", "empty middle field recovered")
ok(back[4] and back[4][3] == "line1\nline2", "embedded newline recovered")
ok(back[5] and back[5][2] == "quote\"inside", "embedded quote recovered")

if fails == 0 then print("[+] PASS test_tsv") os.exit(0) else os.exit(1) end
