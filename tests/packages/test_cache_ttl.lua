-- tests/packages/test_cache_ttl.lua : TTL cache behavior.
-- Deterministic: never asserts current time; uses ttl=0 (expires immediately:
-- expires_at = now + 0 = now, and the check is expires_at <= now) for the
-- expiry path, and a very large ttl for the live path.
local ok_req, cache_ttl = pcall(require, "cache_ttl")
if not ok_req then
    print("[~] SKIP test_cache_ttl (" .. tostring(cache_ttl) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m)
    if not c then fails = fails + 1; print("[-] FAIL test_cache_ttl: " .. tostring(m)) end
end

-- Default cache (default_ttl=300, max_size=10000). 300s is plenty for the test.
local c = cache_ttl.new()
ok(c:size() == 0, "empty size 0")
c:set("a", 1)
c:set("b", 2)
ok(c:size() == 2, "size 2 after two sets")
ok(c:get("a") == 1, "get a")
ok(c:get("b") == 2, "get b")
ok(c:get("missing") == nil, "missing returns nil")

-- contains / delete
ok(c:contains("a") == true, "contains present")
ok(c:contains("nope") == false, "contains absent")
ok(c:delete("a") == true, "delete present true")
ok(c:delete("a") == false, "delete absent false")
ok(c:size() == 1, "size 1 after delete")

-- default_ttl applies when set() is called without an explicit ttl: the entry
-- gets a numeric expiry (now + default). (The package coerces a falsy
-- default_ttl back to 300, so every entry created via new() has an expiry.)
local cdef = cache_ttl.new({ default_ttl = 100000 })
cdef:set("k", 42)
ok(type(cdef:expires_at("k")) == "number", "default_ttl gives numeric expiry")
ok(cdef:get("k") == 42, "default-ttl entry retrievable")

-- ttl=0 expires immediately
local ce = cache_ttl.new()
ce:set("x", 9, 0)
ok(ce:get("x") == nil, "ttl=0 expires on get")
ok(ce:contains("x") == false, "ttl=0 not contained")

-- large ttl stays live; expires_at returns a timestamp (> 0)
local cl = cache_ttl.new()
cl:set("y", 5, 100000)
ok(cl:get("y") == 5, "large ttl live")
local exp = cl:expires_at("y")
ok(type(exp) == "number" and exp > 0, "expires_at returns timestamp")

-- touch resets expiry; touch absent returns false
local ct = cache_ttl.new()
ct:set("t", 1, 100000)
ok(ct:touch("t", 200000) == true, "touch present true")
ok(ct:touch("absent") == false, "touch absent false")
-- touch with no ttl on a default(300) cache leaves a numeric expiry
ok(type(ct:expires_at("t")) == "number", "touched entry still has expiry")

-- peek returns value without expiry check (ttl=0 entry still peekable
-- until a get/contains/cleanup drops it)
local cp = cache_ttl.new()
cp:set("p", 7, 0)
ok(cp:peek("p") == 7, "peek ignores expiry")
ok(cp:get("p") == nil, "get honours expiry")

-- cleanup() sweeps expired and returns drop count
local cc = cache_ttl.new()
cc:set("e1", 1, 0)
cc:set("e2", 2, 0)
cc:set("live", 3, 100000)
local dropped = cc:cleanup()
ok(dropped == 2, "cleanup drops 2 expired")
ok(cc:get("live") == 3, "cleanup keeps live entry")

-- stats accounting
local cs = cache_ttl.new()
cs:set("a", 1)          -- sets=1
cs:get("a")             -- hit
cs:get("zz")            -- miss
local st = cs:stats()
ok(st.hits == 1, "stats hits 1")
ok(st.misses == 1, "stats misses 1")
ok(st.sets == 1, "stats sets 1")

-- max_size capacity eviction: max_size=2, insert 3 -> one eviction.
local cm = cache_ttl.new({ max_size = 2 })
cm:set("a", 1, 100000)
cm:set("b", 2, 100000)
cm:set("c", 3, 100000)  -- evicts the soonest-expiry entry
ok(cm:size() == 2, "max_size caps size at 2")
local mst = cm:stats()
ok(mst.evictions == 1, "one eviction recorded")
ok(mst.max_size == 2, "stats reports max_size")

-- pairs() iterates live entries; aggregate (sum) to stay order-independent
local cpi = cache_ttl.new()
cpi:set("a", 10, 100000)
cpi:set("b", 20, 100000)
cpi:set("dead", 99, 0)   -- expired, must not appear
local sum, count = 0, 0
for k, v in cpi:pairs() do sum = sum + v; count = count + 1 end
ok(count == 2, "pairs yields 2 live entries")
ok(sum == 30, "pairs sum of live values == 30")

-- clear
cpi:clear()
ok(cpi:size() == 0, "clear resets size")

if fails == 0 then print("[+] PASS test_cache_ttl") os.exit(0) else os.exit(1) end
