-- gc_weak.lua : weak-table clearing and __gc finalizer behavior. Run under the
-- JIT and the interpreter; the runner diffs stdout. A divergence would mean the
-- JIT keeps an object reachable (e.g. alive in a register past its source death)
-- when the interpreter has already let it go -- a real codegen/GC bug.

-- Weak-VALUE table: only the entry whose value is still strongly referenced
-- survives a full collection.
local wv = setmetatable({}, { __mode = "v" })
local keep
do
  local a, b = { tag = "a" }, { tag = "b" }
  wv.a, wv.b = a, b
  keep = a                     -- strong ref to a only
end
collectgarbage("collect")
print("weak-value kept a:", wv.a ~= nil)
print("weak-value dropped b:", wv.b == nil)
print("keep still valid:", keep.tag)

-- Weak-KEY table: the entry whose key object is unreferenced is cleared.
local wk = setmetatable({}, { __mode = "k" })
local kkeep
do
  local k1, k2 = {}, {}
  wk[k1] = "one"; wk[k2] = "two"
  kkeep = k1
end
collectgarbage("collect")
print("weak-key kept:", wk[kkeep])
local count = 0
for _ in pairs(wk) do count = count + 1 end
print("weak-key remaining entries:", count)

-- __gc finalizers: every collectable with a __gc runs exactly once on a full
-- collection of unreachable objects.
local ran = 0
do
  for i = 1, 5 do
    setmetatable({}, { __gc = function() ran = ran + 1 end })
  end
end
collectgarbage("collect")
print("finalizers ran:", ran)

-- A resurrecting finalizer runs once; the object is collected on the next cycle.
local resurrected
do
  setmetatable({ id = 42 }, { __gc = function(self) resurrected = self end })
end
collectgarbage("collect")
print("resurrected id:", resurrected and resurrected.id)
resurrected = nil
collectgarbage("collect")
print("done")
