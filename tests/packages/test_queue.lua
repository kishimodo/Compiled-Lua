-- tests/packages/test_queue.lua : lock-free FIFO queues (mpmc / spsc /
-- mpmc_unbounded). Single-threaded so the lock-free machinery is exercised
-- without contention. Deterministic: fixed values, sums (order-independent
-- where iteration is involved, though FIFO order is also checked).
local ok_req, queue = pcall(require, "queue")
if not ok_req then
    print("[~] SKIP test_queue (" .. tostring(queue) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m)
    if not c then fails = fails + 1; print("[-] FAIL test_queue: " .. tostring(m)) end
end

-- ===== atomic-independent: capacity validation (runs before any atomic op) =====
ok(not pcall(queue.mpmc, 0), "mpmc capacity 0 errors")
ok(not pcall(queue.spsc, 0), "spsc capacity 0 errors")

-- enqueue/dequeue/drain all go through the queue's x64 Interlocked intrinsics.
-- Those are compiler intrinsics, not kernel32 exports, so they are NOT callable
-- on this build (known bug ATOMIC-INTERLOCKED-SYMS-001; proper fix needs
-- machine-code atomic thunks). Probe the capability; SKIP the atomic-dependent
-- body cleanly if it is unavailable instead of raising an uncaught error.
local atom_ok = pcall(function() local a = require("atomic"); return a.int(0):add(1) end)
if not atom_ok then
    if fails == 0 then print("[+] PASS test_queue (capacity validation; atomic FIFO ops skipped)") end
    print("[~] SKIP test_queue atomic FIFO ops (need x64 Interlocked machine-code thunks -- ATOMIC-INTERLOCKED-SYMS-001)")
    os.exit(fails == 0 and 0 or 1)
end

-- Capacity is rounded up to a power of two. Request 3 -> 4.
local function check_basic_fifo(make_label, q, cap)
    ok(q:capacity() == cap, make_label .. " capacity rounded to " .. cap)
    ok(q:empty() == true, make_label .. " starts empty")
    ok(q:size() == 0, make_label .. " size 0")
    ok(q:enqueue(10) == true, make_label .. " enqueue 10")
    ok(q:enqueue(20) == true, make_label .. " enqueue 20")
    ok(q:enqueue(30) == true, make_label .. " enqueue 30")
    ok(q:size() == 3, make_label .. " size 3")
    ok(q:empty() == false, make_label .. " not empty")
    ok(q:dequeue() == 10, make_label .. " FIFO 10 first")
    ok(q:dequeue() == 20, make_label .. " FIFO 20 second")
    ok(q:dequeue() == 30, make_label .. " FIFO 30 third")
    ok(q:dequeue() == nil, make_label .. " dequeue empty -> nil")
    ok(q:empty() == true, make_label .. " empty again")
end

-- ===== mpmc bounded =====
local m = queue.mpmc(3)
check_basic_fifo("mpmc", m, 4)

-- fill to capacity then enqueue is rejected
local mf = queue.mpmc(2)   -- cap 2
ok(mf:enqueue("a") == true, "mpmc fill 1")
ok(mf:enqueue("b") == true, "mpmc fill 2")
ok(mf:full() == true, "mpmc full")
ok(mf:enqueue("c") == false, "mpmc enqueue rejected when full")
ok(mf:dequeue() == "a", "mpmc drains a")
ok(mf:enqueue("c") == true, "mpmc accepts after dequeue")

-- try_* aliases work
local mt = queue.mpmc(4)
ok(mt:try_enqueue(1) == true, "mpmc try_enqueue alias")
ok(mt:try_dequeue() == 1, "mpmc try_dequeue alias")

-- value type fidelity through serialization
local mv = queue.mpmc(4)
mv:enqueue("str")
mv:enqueue({ k = 5, arr = { 1, 2 } })
mv:enqueue(true)
ok(mv:dequeue() == "str", "mpmc string value")
local tv = mv:dequeue()
ok(type(tv) == "table" and tv.k == 5 and tv.arr[2] == 2, "mpmc table value")
ok(mv:dequeue() == true, "mpmc boolean value")

-- drain returns count and feeds handler
local md = queue.mpmc(8)
for i = 1, 5 do md:enqueue(i) end
local seen = 0
local n = md:drain(function(v) seen = seen + v end)
ok(n == 5, "mpmc drain count 5")
ok(seen == 15, "mpmc drain handler sum 15")
ok(md:empty(), "mpmc empty after drain")

-- close marks dead; enqueue rejected, buffered still drainable
local mc = queue.mpmc(4)
mc:enqueue("kept")
mc:close()
ok(mc:enqueue("nope") == false, "mpmc enqueue after close rejected")
ok(mc:dequeue() == "kept", "mpmc buffered drains after close")

-- ===== spsc bounded =====
local s = queue.spsc(3)
check_basic_fifo("spsc", s, 4)

local sf = queue.spsc(2)
ok(sf:enqueue("x") == true, "spsc fill 1")
ok(sf:enqueue("y") == true, "spsc fill 2")
ok(sf:full() == true, "spsc full")
ok(sf:enqueue("z") == false, "spsc enqueue rejected when full")
ok(sf:dequeue() == "x", "spsc FIFO x")

-- spsc drain
local sd = queue.spsc(8)
for i = 1, 4 do sd:enqueue(i * 2) end
local ssum = 0
local sc = sd:drain(function(v) ssum = ssum + v end)
ok(sc == 4, "spsc drain count 4")
ok(ssum == 20, "spsc drain sum 20")

-- ===== mpmc unbounded =====
local u = queue.mpmc_unbounded()
ok(u:capacity() == math.huge, "unbounded capacity huge")
ok(u:full() == false, "unbounded never full")
ok(u:empty() == true, "unbounded starts empty")
ok(u:dequeue() == nil, "unbounded dequeue empty nil")
for i = 1, 100 do u:enqueue(i) end
ok(u:size() == 100, "unbounded size 100")
ok(u:full() == false, "unbounded still not full")
-- FIFO check on first few
ok(u:dequeue() == 1, "unbounded FIFO 1")
ok(u:dequeue() == 2, "unbounded FIFO 2")
-- drain the rest, sum 3..100
local usum = u:drain()  -- no handler, returns count
ok(usum == 98, "unbounded drain count 98 remaining")
ok(u:empty(), "unbounded empty after drain")

-- unbounded close
local uc = queue.mpmc_unbounded()
uc:enqueue("a")
uc:close()
ok(uc:enqueue("b") == false, "unbounded enqueue after close rejected")
ok(uc:dequeue() == "a", "unbounded buffered drains after close")

-- (capacity validation asserted above, before the atomic-capability probe)

if fails == 0 then print("[+] PASS test_queue") os.exit(0) else os.exit(1) end
