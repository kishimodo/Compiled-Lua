-- tests/packages/test_kv_file.lua : kv_file append-log KV store round-trips.
-- Pure-Lua package (no native deps). Compiled to a standalone exe by the
-- runner, then run. Uses a temp file via os.tmpname() so it is cwd-independent.
local ok_req, kv_file = pcall(require, "kv_file")
if not ok_req then print("[~] SKIP test_kv_file") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_kv_file: " .. tostring(m)) end end

local path = os.tmpname()
os.remove(path) -- ensure open() creates fresh; some platforms pre-create the temp file

-- ===== basic put/get round-trip + missing key =====
local db = kv_file.open(path)
ok(db ~= nil, "open returns a db")
ok(db:size() == 0, "fresh db is empty")

db:put("alpha", "one")
db:put("beta", "two")
ok(db:get("alpha") == "one", "get returns put value (alpha)")
ok(db:get("beta") == "two", "get returns put value (beta)")
ok(db:size() == 2, "size counts 2 live keys")
ok(db:get("nope") == nil, "missing key returns nil")

-- overwrite same key keeps latest, does not double-count
db:put("alpha", "ONE-updated")
ok(db:get("alpha") == "ONE-updated", "overwrite returns latest value")
ok(db:size() == 2, "overwrite does not increase size")

-- ===== type/binary preservation: values are 8-bit clean strings =====
local bin = string.char(0, 1, 2, 255, 254, 0, 65, 66)
db:put("binkey", bin)
ok(db:get("binkey") == bin, "binary value with NUL/high bytes round-trips")
ok(#db:get("binkey") == #bin, "binary value length preserved")

db:put("emptyval", "")
ok(db:get("emptyval") == "", "empty-string value round-trips")
ok(db:size() == 4, "size now counts 4 live keys")

-- non-string args rejected (format only stores 8-bit-clean strings)
ok(not pcall(function() db:put("k", 123) end), "put rejects non-string value")
ok(not pcall(function() db:put(7, "v") end), "put rejects non-string key")

-- ===== delete / tombstone semantics =====
ok(db:delete("beta") == true, "delete of existing key returns true")
ok(db:get("beta") == nil, "deleted key reads back nil")
ok(db:size() == 3, "delete decrements size")
ok(db:delete("ghost") == false, "delete of missing key returns false")
ok(db:size() == 3, "missing delete does not change size")

-- ===== keys() iterator yields exactly the live keys =====
local seen, cnt = {}, 0
for k in db:keys() do seen[k] = true; cnt = cnt + 1 end
ok(cnt == 3, "keys() yields 3 keys")
ok(seen["alpha"] and seen["binkey"] and seen["emptyval"], "keys() yields the live key names")
ok(not seen["beta"], "keys() excludes deleted key")

db:close()

-- ===== persistence across reopen (index rebuilt by scanning the file) =====
local db2 = kv_file.open(path)
ok(db2:size() == 3, "reopen rebuilds size from disk")
ok(db2:get("alpha") == "ONE-updated", "reopen sees latest overwrite, not stale value")
ok(db2:get("binkey") == bin, "reopen round-trips binary value")
ok(db2:get("emptyval") == "", "reopen round-trips empty value")
ok(db2:get("beta") == nil, "reopen honors tombstone")

-- ===== compaction: drops stale/tombstone records, preserves live data =====
db2:put("gamma", "three")
db2:delete("gamma")          -- live-then-deleted: must be absent after compact
db2:put("delta", "four")
local before = db2:size()
db2:compact()
ok(db2:size() == before, "compact preserves live key count")
ok(db2:get("alpha") == "ONE-updated", "compact keeps latest alpha value")
ok(db2:get("binkey") == bin, "compact keeps binary value intact")
ok(db2:get("delta") == "four", "compact keeps delta value")
ok(db2:get("gamma") == nil, "compact drops deleted key")
db2:close()

-- reopen after compaction: data intact, no stale records resurrected
local db3 = kv_file.open(path)
ok(db3:size() == before, "post-compact reopen size matches")
ok(db3:get("alpha") == "ONE-updated", "post-compact reopen keeps alpha")
ok(db3:get("delta") == "four", "post-compact reopen keeps delta")
ok(db3:get("gamma") == nil, "post-compact reopen: gamma absent")
db3:close()

os.remove(path)

if fails == 0 then print("[+] PASS test_kv_file") os.exit(0) else os.exit(1) end
