-- tools/test-coro-anchor.lua : the fiber coroutine lib links only when reachable.
--
-- Auto-discovered by tools/run-tests.lua (phase 6).
--
-- Two halves of one property, and they fail in opposite directions:
--
--   THE PRUNE PAYS.  coro.o is roughly 3 KB (fiber management + the coroutine
--   luaL_Reg + the fiber-based resume/yield/status/wrap plumbing) and used to
--   ride every AOT exe unconditionally. A `print("hello")` cannot possibly
--   reach the coroutine table, so the module has no business in the exe --
--   the driver's lc_module_uses_coroutine scan lets --gc-sections drop it.
--
--   THE GATE IS SOUND.  The bit comes from NAMING the "coroutine" string,
--   which only works while the program cannot reach the coroutine table it
--   never named. `_G[k]`, `package.loaded[k]`, and `debug.getregistry()` all
--   can, so lc_module_uses_coroutine returns TRUE for those three shapes.
--   Drop that escape and a program that reaches coroutine through _G sees
--   nil where the interpreter sees a table.
--
-- Detection is by the metatable name coro.c registers in .rdata --
-- "clua-interp.coro" -- matched NUL-delimited so a substring inside some
-- longer string cannot forge a hit.

local NAME = "test-coro-anchor"
local CLUA = "build\\bin\\clua.exe"
local TMP  = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\clua-coro-anchor"

local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

os.execute('if not exist "' .. TMP .. '" mkdir "' .. TMP .. '" >nul 2>&1')

-- coro.c's registered metatable name; it appears in the exe's .rdata iff
-- the whole coro.o was linked in (and --gc-sections could not drop it).
local PROBE = "clua-interp.coro"

local FIXTURES = {
  {
    name = "hello", src = 'print("hello")\n',
    want = false,
    why  = "a bare print never names \"coroutine\" and cannot reach the "
        .. "coroutine table through any reflection shape, so coro.o must "
        .. "fall to --gc-sections",
  },
  {
    name = "wrap", src = [[
local step = coroutine.wrap(function() coroutine.yield(1) return 2 end)
print(step())
print(step())
]],
    want = true,
    why  = "coroutine.wrap plainly names \"coroutine\" -- coro.o must stay",
  },
  {
    name = "pkg", src = [[
local n = "cor" .. "outine"
print(package.loaded[n] ~= nil)
]],
    want = true,
    why  = "package.loaded[computed] can reach any library including "
        .. "coroutine, so the gate must give up and link coro.o",
  },
  {
    name = "genv", src = [[
local k = "cor" .. "outine"
print(_G[k] ~= nil)
]],
    want = true,
    why  = "_G[computed] can reach coroutine without ever naming it, "
        .. "same escape",
  },
}

local function compile(fx)
  local src = TMP .. "\\" .. fx.name .. ".lua"
  local exe = TMP .. "\\" .. fx.name .. ".exe"
  local f = io.open(src, "wb")
  if not f then return nil, "cannot write " .. src end
  f:write(fx.src); f:close()
  os.remove(exe)
  local cmd = CLUA .. ' build "' .. src .. '" -O1 -o "' .. exe .. '" >nul 2>&1'
  os.execute('"' .. cmd .. '"')
  local h = io.open(exe, "rb")
  if not h then return nil, "clua produced no exe for " .. fx.name end
  local data = h:read("*a"); h:close()
  return data
end

local function has_coro(data)
  return data:find("\0" .. PROBE .. "\0", 1, true) ~= nil
end

for _, fx in ipairs(FIXTURES) do
  local data, err = compile(fx)
  if not data then
    fail("%s: %s", fx.name, err)
  else
    local got = has_coro(data)
    if fx.want and not got then
      fail("%s: coroutine anchor is NOT linked but must be -- %s. The exe "
           .. "will see nil where the interpreter sees a table.",
           fx.name, fx.why)
    elseif not fx.want and got then
      fail("%s: coroutine anchor is linked but nothing can reach it -- %s. "
           .. "Check that lc_module_uses_coroutine still returns false for "
           .. "this shape and that the driver only force-undefs Coro_OpenLib "
           .. "under that gate.", fx.name, fx.why)
    end
  end
end

if #failures == 0 then
  print(("[+] PASS %s: %d fixtures link the coroutine anchor iff reachable")
        :format(NAME, #FIXTURES))
  os.exit(0)
end

for _, f in ipairs(failures) do print(("[-] FAIL %s: %s"):format(NAME, f)) end
os.exit(1)
