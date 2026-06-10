-- tests/packages/test_cab.lua : Microsoft Cabinet reader (setupapi) + FCI create.
-- Deterministic: a fixed 138-byte real .cab (built once with makecab, MSZIP) is
-- embedded and written to a temp file; we assert exact member names/sizes/bytes.
--
-- History: this round-trip was blocked by CAB-FFI-001 (cast'd function-pointer
-- calls raised "function pointer not resolved") plus three cab-package bugs it
-- masked (32-bit Param1 truncating the notification pointer, WORD-vs-UINT DOS
-- stamp fields, and a FILEOP_DOIT fall-through that aborted the iteration).
-- All fixed 2026-06-09; the functional section now runs unconditionally so a
-- regression in cast'd funcptr calls or callbacks FAILS here instead of
-- silently skipping.
local ok_req, cab = pcall(require, "cab")
if not ok_req then print("[~] SKIP test_cab (" .. tostring(cab) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_cab: " .. tostring(m)) end end

-- ===== API surface (no native cabinet I/O required) =====
ok(type(cab.is_available) == "function",       "is_available is a function")
ok(type(cab.fci_available) == "function",       "fci_available is a function")
ok(type(cab.list) == "function",                "list is a function")
ok(type(cab.read) == "function",                "read is a function")
ok(type(cab.extract) == "function",             "extract is a function")
ok(type(cab.extract_to_memory) == "function",   "extract_to_memory is a function")
ok(type(cab.create) == "function",              "create is a function")

local avail = cab.is_available()
ok(type(avail) == "boolean",                    "is_available returns a boolean")
ok(type(cab.fci_available()) == "boolean",       "fci_available returns a boolean")

-- ===== argument validation (errors before any native call) =====
ok(select(2, pcall(cab.extract, "x.cab", "")) ~= nil,  "extract rejects empty dest_dir")
ok(select(2, pcall(cab.extract, "x.cab", nil)) ~= nil, "extract rejects nil dest_dir")
ok(select(2, pcall(cab.create, 123, {})) ~= nil,       "create rejects non-string path")
ok(select(2, pcall(cab.create, "x.cab", "notatable")) ~= nil, "create rejects non-table files")

if not avail then
  -- setupapi missing entirely: surface + validation covered, nothing more to do.
  print("[~] SKIP test_cab (setupapi.dll / SetupIterateCabinetA unavailable -- surface checks passed)")
  os.exit(0)
end

-- ===== embedded fixture: a real 2-member MSZIP cabinet (138 bytes) =====
-- Members: readme.txt = "Hello CAB member!" (17 bytes)
--          data.bin   = "second-member-body" (18 bytes)
local CAB_BYTES = ""
  .. "\77\83\67\70\0\0\0\0\138\0\0\0\0\0\0\0\44\0\0\0\0\0\0\0\3\1\1\0\2\0"
  .. "\0\0\253\6\0\0\96\0\0\0\1\0\1\0\17\0\0\0\0\0\0\0\0\0\201\92\105\133\32\0"
  .. "\114\101\97\100\109\101\46\116\120\116\0\18\0\0\0\17\0\0\0\0\0\201\92\105\133\32\0\100\97\116"
  .. "\97\46\98\105\110\0\46\177\75\64\34\0\35\0\67\75\243\72\205\201\201\87\112\118\116\82\200\77\205\77"
  .. "\74\45\82\44\78\77\206\207\75\209\133\240\116\147\242\83\42\1"

local EXPECT = { ["readme.txt"] = "Hello CAB member!", ["data.bin"] = "second-member-body" }

local cab_path = os.tmpname() .. ".cab"
do
  local f = assert(io.open(cab_path, "wb"))
  f:write(CAB_BYTES); f:close()
end

-- Sanity: the cabinet magic 'MSCF' must be the first 4 bytes.
ok(CAB_BYTES:sub(1, 4) == "MSCF",               "embedded fixture has MSCF magic")
ok(#CAB_BYTES == 138,                           "embedded fixture is 138 bytes")

local list_ok, lst = pcall(cab.list, cab_path)
ok(list_ok,                                     "cab.list succeeded on fixture: " .. tostring(list_ok and "" or lst))

if list_ok then
  ok(#lst == 2,                                 "cab.list reports 2 members")
  local byname = {}
  for _, e in ipairs(lst) do byname[e.name] = e end
  ok(byname["readme.txt"] ~= nil,               "readme.txt member listed")
  ok(byname["data.bin"] ~= nil,                 "data.bin member listed")
  ok(byname["readme.txt"] and byname["readme.txt"].size == 17, "readme.txt size = 17")
  ok(byname["data.bin"] and byname["data.bin"].size == 18,     "data.bin size = 18")

  -- read each member
  ok(cab.read(cab_path, "readme.txt") == EXPECT["readme.txt"], "cab.read readme round-trips")
  ok(cab.read(cab_path, "data.bin") == EXPECT["data.bin"],     "cab.read data round-trips")
  ok(select(2, pcall(cab.read, cab_path, "missing.txt")) ~= nil, "cab.read errors on missing member")

  -- extract_to_memory returns name->bytes for every member
  local mem = cab.extract_to_memory(cab_path)
  ok(mem["readme.txt"] == EXPECT["readme.txt"], "extract_to_memory readme matches")
  ok(mem["data.bin"] == EXPECT["data.bin"],     "extract_to_memory data matches")
end

os.remove(cab_path)
if fails == 0 then print("[+] PASS test_cab") os.exit(0) else os.exit(1) end
