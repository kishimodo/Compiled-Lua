-- aot_concurrency.lua — the concurrency/atomics cluster compiles AOT and
-- matches the interpreter. Pins ATOMIC-INTERLOCKED-SYMS-001's fix at the
-- product level: the built-in x64 Interlocked machine-code thunks
-- (clua/src/ffi/ffi_atomics.c) back atomic cells, the lock-free queue, and
-- the semaphore count hint; event/mutex/channel use Win32 primitives. All
-- ops here are single-threaded and deterministic, so the compiled exe and
-- `clua-interp -i` must print identical stdout.
--
-- (`pool` and `thread` are covered separately by
-- `tests/differential/aot_pool_thread.lua` — they now compile AOT too, running
-- inline / cooperatively rather than the never-wired native OS-thread path.)
--
-- The path prepend serves the interpreter oracle (CWD = repo root); the
-- compiled exe satisfies each require from package.preload.
package.path = "clua\\src\\runtime\\packages\\?\\init.lua;"
            .. "clua\\src\\runtime\\packages\\?.lua;" .. package.path

local atomic    = require "atomic"
local queue     = require "queue"
local semaphore = require "semaphore"
local event     = require "event"
local mutex     = require "mutex"
local channel   = require "channel"

-- atomic int: add / sub / cas / inc / dec via lock xadd / lock cmpxchg
local c = atomic.int(0)
c:add(40); c:add(5); c:sub(3)
print("atomic.int", c:get())                       -- 42
print("atomic.cas", c:cas(42, 100), c:get())       -- true  100
c:inc(); c:dec(); c:dec()
print("atomic.incdec", c:get())                    -- 99

-- atomic int64 + flag
local big = atomic.int64(0)
big:add(9007199254740000)
print("atomic.int64", big:get())                   -- 9007199254740000
local fl = atomic.flag()
print("atomic.flag", fl:test_and_set(), fl:test_and_set())  -- false true

-- lock-free FIFO (Interlocked64 head/tail)
local q = queue.mpmc(8)
for i = 1, 5 do q:enqueue(i * i) end
local sum, drained = 0, {}
while not q:empty() do drained[#drained + 1] = q:dequeue() end
for _, v in ipairs(drained) do sum = sum + v end
print("queue.fifo", table.concat(drained, ","), "sum", sum)  -- 1,4,9,16,25 sum 55
print("queue.cap", q:capacity(), q:empty())                  -- 8  true

-- semaphore: count hint via atomic int64, acquire/try/release
local s = semaphore.new(2, 4)
print("sem.acquire", s:acquire(0))                 -- true
print("sem.try", s:try_acquire())                  -- true  (count now 0)
print("sem.try2", s:try_acquire())                 -- false (would block)
s:release()
print("sem.value", s:value() >= 0)                 -- true

-- event: manual-reset signal persistence (Win32)
local e = event.manual()
print("event.initial", e:wait(0))                  -- false
e:set()
print("event.set", e:wait(0), e:wait(0))           -- true true (manual stays)
e:reset()
print("event.reset", e:wait(0))                    -- false

-- mutex: recursive CRITICAL_SECTION lock/unlock + try
local m = mutex.mutex()
m:lock()
print("mutex.try_self", m:try_lock())              -- true (recursive)
m:unlock(); m:unlock()
print("mutex.relocked", m:try_lock()); m:unlock()  -- true

-- channel: bounded send/receive + serialization round-trip
local ch = channel.make(3)
ch:send(1); ch:send("two"); ch:send({ k = 3 })
local a = ch:receive()
local b = ch:receive()
local t = ch:receive()
print("channel", a, b, t.k)                        -- 1  two  3
print("channel.len", ch:len(), ch:capacity())      -- 0  3
