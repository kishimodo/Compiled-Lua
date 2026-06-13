-- aot_native_thread.lua — thread.spawn over REAL OS threads (the native path).
-- The worker functions below are "shippable" (they capture no upvalues), so a
-- compiled exe runs each on a real OS thread, resolved by its compile-time
-- function-id and run in its own lua_State; under the interpreter (which has no
-- `_clua` runtime) the SAME functions run cooperatively. Results are collected
-- in a FIXED order (each handle joined in spawn order), so the output is
-- deterministic regardless of thread scheduling -- the compiled exe and
-- `clua-interp -i` must print identical stdout.
--
-- The path prepend serves the interpreter oracle (CWD = repo root); the compiled
-- exe satisfies `require "thread"` from package.preload.
package.path = "clua\\src\\runtime\\packages\\?\\init.lua;"
            .. "clua\\src\\runtime\\packages\\?.lua;" .. package.path

local thread = require "thread"

-- shippable workers: only params + globals, no captured upvalues
local function square(x) return x * x end
local function sum_to(n) local s = 0; for i = 1, n do s = s + i end; return s end
local function concat3(a, b, c) return a .. b .. c end
local function pack3(a, b, c) return { a = a, b = b, c = c, total = a + b + c } end
local function boom(msg) error(msg) end

local t1 = thread.spawn(square,  { 9 })
local t2 = thread.spawn(sum_to,  { 100 })
local t3 = thread.spawn(concat3, { "a", "b", "c" })
print("square",  t1:join())          -- 81
print("sum_to",  t2:join())          -- 5050
print("concat3", t3:join())          -- abc

-- table args + table result cross the thread boundary (serialized)
local r = thread.spawn(pack3, { 10, 20, 30 }):join()
print("pack3", r.a, r.b, r.c, r.total)   -- 10 20 30 60

-- error propagation from a worker
local ev, eerr = thread.spawn(boom, { "native-boom" }):join()
print("boom", ev, eerr ~= nil and eerr:find("native-boom", 1, true) ~= nil)  -- nil true

-- a batch, summed in deterministic (spawn) order
local hs = {}
for i = 1, 12 do hs[i] = thread.spawn(square, { i }) end
local total = 0
for i = 1, 12 do total = total + hs[i]:join() end
print("batch-sum", total)            -- sum of squares 1..12 = 650

-- a worker that captures an upvalue is NOT shippable -> cooperative fallback,
-- still correct and identical across native/interpreted builds
local k = 1000
print("coop-fallback", thread.spawn(function(x) return k + x end, { 5 }):join())  -- 1005
