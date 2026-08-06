-- tests/differential/stdlib_reach.lua
--
-- The optional standard libraries are linked on demand: lc_module_used_libs()
-- (opt/passes.c) scans for the NAME of each library and the driver force-undefs
-- only those anchors, one translation unit each (runtime/stdlib_anchor.h). A
-- program that never says "os" does not carry loslib.o.
--
-- That is only sound while a program cannot reach a library it never named. It
-- can, three ways, and each one is here:
--
--   1. package.loaded[k] with a computed k
--   2. _G[k] / _ENV[k] with a computed k
--   3. enumerating the loaded table
--
-- All three make the mask give up and link everything. Before that escape
-- existed, splitting the anchors made `package.loaded["o".."s"]` return nil in
-- the compiled exe and a table under the interpreter -- a silent wrong answer,
-- which is why the split sat blocked for the whole size arc rather than being
-- shipped and documented as a caveat.
--
-- The runner diffs this against clua-interp.exe at -O0 and -O1, so a regression
-- shows up as a stdout difference rather than as a subtly smaller binary.

-- 1. computed key into package.loaded
local n = "o" .. "s"
print("package.loaded[computed]", type(package.loaded[n]))

-- 2. computed key into the global table
local g = "ma" .. "th"
print("_G[computed]", type(_G[g]))
print("_G[computed].floor", _G[g].floor(3.7))

-- Same through _ENV, which compiles to a different opcode shape (GETUPVAL of
-- the _ENV upvalue rather than GETTABUP _ENV "_G").
local e = _ENV
print("_ENV[computed]", type(e["ut" .. "f8"]))

-- 3. enumerate. Names only, sorted -- the values are addresses.
local keys = {}
for k in pairs(package.loaded) do keys[#keys + 1] = k end
table.sort(keys)
print("loaded", table.concat(keys, ","))

-- The libraries reached only through a computed name must actually WORK, not
-- merely be present: a stub table would satisfy the type() checks above.
print("os.difftime", os.difftime(100, 40))
print("utf8.char", utf8.char(65, 66, 67))
print("string.rep", ("ab"):rep(3, "-"))
print("table.concat", table.concat({ 1, 2, 3 }, "+"))
print("math.max", math.max(2, 9, 4))
print("io.type", io.type(io.stdout))
print("debug.getinfo", type(debug.getinfo(1, "l")))
