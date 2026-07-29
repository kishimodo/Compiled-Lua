-- tools/test-stdlib-anchor-split.lua : optional stdlibs link only when reachable.
--
-- Auto-discovered by tools/run-tests.lua (phase 6).
--
-- Two halves of one property, and they fail in opposite directions:
--
--   THE SPLIT PAYS.  Each optional library's anchor is its own translation unit
--   (runtime/stdlib_anchor.h), so a program needing only `string` links only
--   lstrlib.o. Merge them back into one TU and every program silently regains
--   all seven libraries -- about 30 KB on the smallest program that does
--   arithmetic. Nothing else would notice: the binary still runs, still passes
--   the differential suite, and is just fat.
--
--   THE MASK IS SOUND.  The bits come from NAMING a library, which only works
--   while a program cannot reach one it never named. `package.loaded[k]` and
--   `_G[k]` can, so lc_module_used_libs() returns LCLIB_ALL for those. Drop
--   that escape and `package.loaded["o".."s"]` returns nil in the exe and a
--   table under the interpreter. tests/differential/stdlib_reach.lua catches
--   the behaviour; this catches the LINK, which is the actual mechanism, and
--   says which library went missing.
--
-- Detection is by the registration-table name each library contributes to
-- .rdata, matched NUL-delimited so a substring inside some longer string
-- cannot forge a hit. Verified against the six fixtures below: a bare
-- `print("hello")` matches none of the seven.

local NAME = "test-stdlib-anchor-split"
local CLUA = "build\\bin\\clua.exe"
local TMP  = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\clua-anchor-split"

local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

os.execute('if not exist "' .. TMP .. '" mkdir "' .. TMP .. '" >nul 2>&1')

-- library -> a name only that library's luaL_Reg contributes
local PROBE = {
  string = "gsub",     table = "insert", math  = "randomseed", os = "difftime",
  io     = "lines",    utf8  = "codepoint", debug = "getlocal",
}
local ALL = { "string", "table", "math", "os", "io", "utf8", "debug" }

local FIXTURES = {
  {
    name = "hello", src = 'print("hello")\n',
    want = {},
    why  = "a bare print names no library and does no table/arith op",
  },
  {
    name = "add", src = 'local a,b=2,3 local c=a+b print(c)\n',
    want = { "string" },
    why  = "a+b emits MMBIN, whose metamethod path needs the string metatable; "
        .. "nothing here can reach table/math/os/io/utf8/debug",
  },
  {
    name = "pkg", src = 'local n = "o" .. "s"\nprint(package.loaded[n] ~= nil)\n',
    want = ALL,
    why  = "package.loaded[computed] can reach any library, so the mask must "
        .. "give up and link all seven",
  },
  {
    name = "genv", src = 'local k = "pri" .. "nt"\n_G[k]("via _G")\n',
    want = ALL,
    why  = "_G[computed] can reach any library, same escape",
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

local function linked_libs(data)
  local set = {}
  for lib, probe in pairs(PROBE) do
    if data:find("\0" .. probe .. "\0", 1, true) then set[lib] = true end
  end
  return set
end

for _, fx in ipairs(FIXTURES) do
  local data, err = compile(fx)
  if not data then
    fail("%s: %s", fx.name, err)
  else
    local got  = linked_libs(data)
    local want = {}
    for _, l in ipairs(fx.want) do want[l] = true end
    for _, lib in ipairs(ALL) do
      if want[lib] and not got[lib] then
        fail("%s: %s is NOT linked but must be -- %s. The exe will see nil "
             .. "where the interpreter sees a table.", fx.name, lib, fx.why)
      elseif not want[lib] and got[lib] then
        fail("%s: %s is linked but nothing can reach it -- %s. Check that "
             .. "runtime/stdlib_anchor_%s.c is still its own translation unit.",
             fx.name, lib, fx.why, lib)
      end
    end
  end
end

if #failures == 0 then
  print(("[+] PASS %s: %d fixtures link exactly the reachable libraries")
        :format(NAME, #FIXTURES))
  os.exit(0)
end

for _, f in ipairs(failures) do print(("[-] FAIL %s: %s"):format(NAME, f)) end
os.exit(1)
