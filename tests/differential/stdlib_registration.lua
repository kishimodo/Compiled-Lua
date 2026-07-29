-- The set of libraries a compiled binary reports must match the interpreter's.
--
-- Two bugs lived here, both invisible to the suite because nothing iterated
-- package.loaded or required a standard library by name:
--
--   1. `coroutine` was never registered in package.loaded. CLua's coroutine
--      library is the fiber-based reimplementation in runtime/coro.c, and it used
--      luaL_newlib + lua_setglobal -- which sets the global but does no
--      package.loaded bookkeeping. So `package.loaded.coroutine` was nil in a
--      compiled binary and a table in the oracle, and pairs(package.loaded)
--      listed 9 entries against the oracle's 10. Every coroutine FUNCTION worked;
--      only the registration was missing, which is exactly why it went unnoticed.
--
--   2. `pcall(require, "coroutine")` failed to COMPILE. The static require
--      scanner treated the name as a user module and went looking for
--      coroutine.lua on disk, where the oracle simply returned the table. The
--      standard libraries are registered at startup rather than through
--      package.preload, so the compiler must not do a filesystem lookup for them
--      -- the same false-positive class that `ffi` and `bit` were already exempt
--      from in compiler/resolve.c.
--
-- Both were found by asking what the two engines disagreed about, not by a
-- failing test. This file makes that disagreement a permanent check.

-- 1. The exact library set, sorted so the comparison is order-independent.
local names = {}
for k in pairs(package.loaded) do names[#names + 1] = k end
table.sort(names)
print("loaded: " .. table.concat(names, " "))

-- 2. Every standard library must be require-able BY NAME and must return the
--    same object as the global. `require` resolves these from package.loaded, so
--    this fails if registration is missing even when the global works.
--
--    Written out one literal call per library ON PURPOSE. Looping over a table of
--    names would be `require(<loop variable>)` -- a genuinely dynamic require,
--    which the closed world rejects at compile time and rightly so. Only a
--    literal argument is statically resolvable, so only a literal argument belongs
--    in a test that must compile.
local function report(name, ok, mod)
  print(("require %-9s ok=%-5s same-as-global=%s"):format(
        name, tostring(ok), tostring(ok and mod == _G[name])))
end
do local ok, m = pcall(require, "_G")        report("_G", ok, m)        end
do local ok, m = pcall(require, "coroutine") report("coroutine", ok, m) end
do local ok, m = pcall(require, "package")   report("package", ok, m)   end
do local ok, m = pcall(require, "string")    report("string", ok, m)    end
do local ok, m = pcall(require, "table")     report("table", ok, m)     end
do local ok, m = pcall(require, "math")      report("math", ok, m)      end
do local ok, m = pcall(require, "io")        report("io", ok, m)        end
do local ok, m = pcall(require, "os")        report("os", ok, m)        end
do local ok, m = pcall(require, "utf8")      report("utf8", ok, m)      end
do local ok, m = pcall(require, "debug")     report("debug", ok, m)     end

-- 3. pcall(require, <literal>) on a standard library must COMPILE as well as run
--    -- this exact shape previously failed at compile time, looking for a
--    coroutine.lua on disk.
print("pcall require coroutine:", (pcall(require, "coroutine")))

-- 4. The coroutine library must be functional as well as registered -- a fix that
--    registered an empty table would satisfy everything above.
do
  local co = coroutine.create(function(a)
    local b = coroutine.yield(a + 1)
    return b * 2
  end)
  local _, first = coroutine.resume(co, 1)
  local _, second = coroutine.resume(co, 10)
  print("coroutine works:", first, second, coroutine.status(co))
end

-- 5. package.loaded and the globals must agree in both directions for the
--    libraries that exist, so neither can drift without this failing.
do
  local mismatches = 0
  for name, mod in pairs(package.loaded) do
    if name ~= "_G" and _G[name] ~= nil and _G[name] ~= mod then
      mismatches = mismatches + 1
    end
  end
  print("loaded/global mismatches:", mismatches)
end

print("DONE")
