-- tests/packages/test_cache_lru.lua : LRU + LFU cache behavior.
-- Deterministic: no clocks/random; TTL paths use ttl=0 (immediate expiry,
-- since expires_at <= os_time() the instant it is set) and a large-ttl
-- path that is guaranteed live within the test's runtime.
local ok_req, cache_lru = pcall(require, "cache_lru")
if not ok_req then
    print("[~] SKIP test_cache_lru (" .. tostring(cache_lru) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m)
    if not c then fails = fails + 1; print("[-] FAIL test_cache_lru: " .. tostring(m)) end
end

-- ===== LRU basics =====
local c = cache_lru.lru(2)
ok(c:size() == 0, "empty cache size 0")
c:set("a", 1)
c:set("b", 2)
ok(c:size() == 2, "size 2 after two sets")
ok(c:get("b") == 2, "get b returns 2")
ok(c:get("a") == 1, "get a returns 1")   -- a is now MRU, b is LRU
ok(c:get("missing") == nil, "missing key returns nil")

-- Eviction: capacity 2, last get touched a (MRU); b is the LRU. Adding c
-- evicts b.
c:set("c", 3)
ok(c:size() == 2, "size stays at capacity 2")
ok(c:get("b") == nil, "b evicted (was LRU)")
ok(c:get("a") == 1, "a survives (recently used)")
ok(c:get("c") == 3, "c present")

-- peek / contains do not change recency
local c2 = cache_lru.lru(2)
c2:set("x", 10)
c2:set("y", 20)
ok(c2:peek("x") == 10, "peek returns value")
ok(c2:contains("y") == true, "contains true for present key")
ok(c2:contains("z") == false, "contains false for absent key")
-- x is still LRU (peek did not touch). Inserting z evicts x.
c2:set("z", 30)
ok(c2:get("x") == nil, "peek did not promote x; x evicted")
ok(c2:get("y") == 20, "y survives")

-- delete
local c3 = cache_lru.lru(3)
c3:set("k", 99)
ok(c3:delete("k") == true, "delete present returns true")
ok(c3:delete("k") == false, "delete absent returns false")
ok(c3:size() == 0, "size 0 after delete")

-- update existing key does not grow size
local c4 = cache_lru.lru(2)
c4:set("a", 1)
c4:set("a", 2)
ok(c4:size() == 1, "re-set same key keeps size 1")
ok(c4:get("a") == 2, "re-set updates value")

-- stats
local cs = cache_lru.lru(2)
cs:set("a", 1)              -- sets=1
cs:get("a")                 -- hit
cs:get("nope")              -- miss
cs:set("b", 2)              -- sets=2
cs:set("c", 3)              -- sets=3, evicts one (a or b)
local st = cs:stats()
ok(st.hits == 1, "stats hits == 1")
ok(st.misses == 1, "stats misses == 1")
ok(st.sets == 3, "stats sets == 3")
ok(st.evictions == 1, "stats evictions == 1")
ok(st.capacity == 2, "stats capacity == 2")

-- clear resets everything
cs:clear()
ok(cs:size() == 0, "clear resets size")
local st2 = cs:stats()
ok(st2.hits == 0 and st2.misses == 0, "clear resets stats")

-- TTL: ttl=0 means expires_at = now + 0 = now, and check is <= now -> expired.
local ct = cache_lru.lru(4)
ct:set("e", 5, 0)
ok(ct:get("e") == nil, "ttl=0 entry expires immediately on get")
-- large ttl stays live
ct:set("live", 7, 100000)
ok(ct:get("live") == 7, "large ttl entry is live")

-- lru_with_ttl default ttl applies
local cd = cache_lru.lru_with_ttl(4, 0)
cd:set("z", 1)              -- inherits default ttl 0 -> immediate expiry
ok(cd:get("z") == nil, "lru_with_ttl default ttl=0 expires entry")

-- ===== LFU =====
local lf = cache_lru.lfu(2)
lf:set("a", 1)
lf:set("b", 2)
ok(lf:get("a") == 1, "lfu get a")
ok(lf:get("a") == 1, "lfu get a again bumps freq")
-- a freq=3 (set counts via get? no: set is freq 1, two gets make it freq 3),
-- b freq=1. Insert c at capacity -> evict min-freq head which is b.
lf:set("c", 3)
ok(lf:get("b") == nil, "lfu evicts least-frequently-used b")
ok(lf:get("a") == 1, "lfu keeps frequently-used a")
ok(lf:get("c") == 3, "lfu keeps new c")

local lf2 = cache_lru.lfu(3)
ok(lf2:delete("nope") == false, "lfu delete absent false")
lf2:set("p", 1)
ok(lf2:delete("p") == true, "lfu delete present true")
ok(lf2:size() == 0, "lfu size 0 after delete")
ok(lf2:peek("p") == nil, "lfu peek absent nil")

local lfs = cache_lru.lfu(2)
lfs:set("x", 1)
lfs:get("x")
lfs:get("ghost")
local lst = lfs:stats()
ok(lst.hits == 1 and lst.misses == 1, "lfu stats hits/misses")
ok(lst.sets == 1, "lfu stats sets")

-- capacity must be > 0
ok(not pcall(cache_lru.lru, 0), "lru capacity 0 errors")
ok(not pcall(cache_lru.lfu, -1), "lfu negative capacity errors")

if fails == 0 then print("[+] PASS test_cache_lru") os.exit(0) else os.exit(1) end
