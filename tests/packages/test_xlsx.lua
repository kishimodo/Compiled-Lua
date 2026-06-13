-- tests/packages/test_xlsx.lua : xlsx writer -> reader round-trip + A1 helpers.
-- The runner compiles this with compiler.exe (bundling xlsx + zip + xml + zlib)
-- and runs it under JIT and -i, byte-comparing stdout. Keep output deterministic.
local ok_req, xlsx = pcall(require, "xlsx")
if not ok_req then print("[~] SKIP test_xlsx (" .. tostring(xlsx) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_xlsx: " .. tostring(m)) end end

-- ===== A1 helpers (pure, no I/O) =========================================
ok(xlsx.col_letter(1)  == "A",   "col_letter(1)=A")
ok(xlsx.col_letter(26) == "Z",   "col_letter(26)=Z")
ok(xlsx.col_letter(27) == "AA",  "col_letter(27)=AA")
ok(xlsx.col_letter(28) == "AB",  "col_letter(28)=AB")
ok(xlsx.col_letter(52) == "AZ",  "col_letter(52)=AZ")
ok(xlsx.col_index("A")  == 1,    "col_index(A)=1")
ok(xlsx.col_index("Z")  == 26,   "col_index(Z)=26")
ok(xlsx.col_index("AA") == 27,   "col_index(AA)=27")
-- round-trip every column index through letter and back
do
    local round_ok = true
    for i = 1, 200 do
        if xlsx.col_index(xlsx.col_letter(i)) ~= i then round_ok = false; break end
    end
    ok(round_ok, "col index<->letter round-trips 1..200")
end
do
    local r, c = xlsx.parse_a1("C5")
    ok(r == 5 and c == 3, "parse_a1(C5)={row=5,col=3}")
end
ok(xlsx.build_a1(5, 3) == "C5",  "build_a1(5,3)=C5")
ok(xlsx.parse_a1("not-a1") == nil, "parse_a1 rejects junk")

-- ===== Writer -> reader round trip =======================================
local path = os.getenv("TEMP") .. "/clua_test_xlsx_rt.xlsx"

local wb = xlsx.create()
local sh = wb:add_sheet("Data")
-- header row + two data rows via add_row
sh:add_row({ "name", "age", "active" })
sh:add_row({ "alice", 30, true })
sh:add_row({ "bob", 25, false })
-- explicit cell set + A1 set
sh:set(5, 1, "manual")        -- row 5 col 1
sh:set_a1("B5", 3.5)          -- row 5 col 2
local n = wb:save(path)
ok(type(n) == "number" and n > 0, "save returns positive byte count")

local rb = xlsx.open(path)
local names = rb:sheet_names()
ok(#names == 1 and names[1] == "Data", "sheet_names round-trips one 'Data' sheet")

local rs = rb:sheet("Data")
ok(rs ~= nil, "sheet('Data') resolves by name")
ok(rb:sheet(1) ~= nil, "sheet(1) resolves by index")

-- cells round-trip with correct types
ok(rs:cell("A1") == "name",  "A1 string round-trips")
ok(rs:cell("B2") == 30,      "B2 number 30 round-trips as number")
ok(rs:cell("C2") == true,    "C2 boolean true round-trips")
ok(rs:cell("C3") == false,   "C3 boolean false round-trips")
ok(rs:cell(1, 2) == "age",   "cell(row,col) numeric addressing works")
ok(rs:cell("A5") == "manual","A5 explicit set round-trips")
ok(rs:cell("B5") == 3.5,     "B5 set_a1 number round-trips")

-- dimensions: rows 1..5, cols 1..3
local dim = rs:dimensions()
ok(dim.min_row == 1 and dim.max_row == 5, "dimensions row span 1..5")
ok(dim.min_col == 1 and dim.max_col == 3, "dimensions col span 1..3")

-- column extraction
local col_a = rs:column("A")
ok(col_a[1] == "name" and col_a[2] == "alice" and col_a[3] == "bob", "column A values")

-- to_records: header -> keyed records
local recs = rs:to_records()
ok(#recs == 4, "to_records yields 4 data rows (rows 2..5)")
ok(recs[1].name == "alice" and recs[1].age == 30, "first record keyed by header")
ok(recs[2].name == "bob" and recs[2].active == false, "second record keyed by header")

-- to_csv: deterministic first line
local csv = rb:to_csv("Data")
local first_line = csv:match("^([^\n]*)")
ok(first_line == "name,age,active", "to_csv header line")

-- error path: bad A1 on a write sheet
local sh2 = wb:add_sheet("S2")
local err_ok = not pcall(function() sh2:set_a1("ZZZ", 1) end)
ok(err_ok, "set_a1 errors on malformed address")

os.remove(path)
if fails == 0 then print("[+] PASS test_xlsx") os.exit(0) else os.exit(1) end
