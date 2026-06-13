-- aot_pool_thread.lua — pool + thread compile AOT and match the interpreter.
-- Real OS threading was never wired up (the native bootstrap does not exist),
-- so thread runs cooperatively and pool runs inline; both used to reference
-- string.dump/load to ship a worker across lua_States, which the closed world
-- forbids — that dead round-trip is gone, so a program requiring them now
-- compiles. Every op here is deterministic, so the compiled exe and
-- `clua-interp -i` must print identical stdout.
--
-- The path prepend serves the interpreter oracle (CWD = repo root); the
-- compiled exe satisfies each require from package.preload.
package.path = "clua\\src\\runtime\\packages\\?\\init.lua;"
            .. "clua\\src\\runtime\\packages\\?.lua;" .. package.path

local thread = require "thread"
local pool   = require "pool"

-- thread.spawn: cooperative worker driven on join(); upvalues survive (no
-- bytecode round-trip), so a closed-over constant is visible to the worker.
local base = 100
local t = thread.spawn(function(a, b) return base + a + b end, { 3, 4 })
print("thread.join", t:join())                 -- 107
print("thread.cpu>=1", thread.cpu_count() >= 1) -- true
print("thread.coop-alive", (function()
    local h = thread.spawn(function() return 1 end)
    local before = h:alive()                    -- true (not yet joined)
    h:join()
    return tostring(before) .. "/" .. tostring(h:alive())
end)())                                         -- true/false

-- pool: inline dispatch, futures born resolved.
local p = pool.new({ workers = 2 })
local f = p:submit(function(x) return x * x end, { 6 })
print("pool.submit", f:done(), f:result())     -- true 36

local futs = p:map(function(x) return x + 10 end, { 1, 2, 3 })
local vals = p:wait_all(futs)
print("pool.map", vals[1], vals[2], vals[3])   -- 11 12 13

-- error propagation through a future
local fe = p:submit(function() error("boom") end)
local ev, eerr = fe:result()
print("pool.error", ev, eerr:find("boom", 1, true) ~= nil)  -- nil true

-- cancel on an already-resolved (inline) future is a no-op
local fc = p:submit(function() return 5 end)
print("pool.cancel", fc:cancel(), fc:result())  -- false 5

p:close()
print("pool.closed-submit", (function()
    local af = p:submit(function() return 1 end)
    local _, err = af:result()
    return err
end)())                                          -- pool closed

-- pool.parallel convenience
local par = pool.parallel(function(x) return x * 3 end, { 1, 2, 3 })
print("pool.parallel", par[1], par[2], par[3])  -- 3 6 9
