-- test-doc-comments.lua -- ldoc-tag extraction inside gen-package-docs.lua.
--
-- The generator's public entry (main()) needs a checked-out packages tree
-- to run end-to-end, and a `docs/site/api/` sink directory. This test
-- exercises the scanner without either: it loads the generator's helpers
-- via `dofile` (which populates two globals for our benefit), feeds a
-- synthetic in-memory source through the scanner, and asserts the rendered
-- markdown carries the expected @param / @return / @throws / @deprecated
-- sections plus a `## <fnname>` heading per function.
--
-- Runs everywhere -- no external binary required.

-- Load the generator: main() will os.exit if the on-disk trees are missing,
-- so we shim os.exit before the dofile and restore it after. The scanner
-- and page renderer are captured off the two _G.__gen_package_docs_* globals
-- the generator installs on load.
local real_exit = os.exit
local exited_with = nil
os.exit = function(code) exited_with = code or 0; error("_test_stop_") end

-- Route stdout/stderr writes through a sink so main()'s progress prints do
-- not clutter the test log.
local real_out = io.output
local real_err = io.stderr

local sink = { data = {} }
function sink:write(...)
  for _, v in ipairs({ ... }) do self.data[#self.data + 1] = tostring(v) end
  return self
end
io.stderr = sink

-- pcall the dofile: main() will raise "_test_stop_" when it hits our fake
-- os.exit. We only care about the side effect of defining the globals.
local ok_load, err = pcall(function()
  dofile("tools/gen-package-docs.lua")
end)
io.stderr = real_err
os.exit = real_exit
-- ok_load will be false because main() raised via our fake exit; that's
-- expected. The globals must exist regardless.
if type(_G.__gen_package_docs_scan_ldoc) ~= "function" or
   type(_G.__gen_package_docs_ldoc_page) ~= "function" then
  print("[-] FAIL test-doc-comments: gen-package-docs.lua did not expose "
        .. "the scanner globals -- did an early os.exit prevent evaluation?")
  print("  load err: " .. tostring(err))
  os.exit(1)
end

local scan = _G.__gen_package_docs_scan_ldoc
local render = _G.__gen_package_docs_ldoc_page

-- Synthetic package: mixes free-form description lines with @param,
-- @return, @throws, @see, @deprecated. Includes a table-scope @field
-- example and a bare `function` with no doc-block (must NOT emit an entry).
local synth = [[
-- synthetic module for the test.

--- Greets the given user.
--- The description spans multiple triple-dash lines to check that
--- the scanner concatenates them.
--- @param who string the name of the greeter target
--- @param polite boolean optional politeness flag
--- @return string the greeting line
--- @throws when who is nil
--- @see farewell
local function greet(who, polite)
  return "hi " .. who
end

-- undocumented helper -- must not appear in the api page
local function _internal(x) return x end

--- Says goodbye.
--- @param who string the departing party
--- @return string the closing line
--- @deprecated use `part(who, "bye")` instead
local function farewell(who)
  return "bye " .. who
end

--- Constants exposed by the module.
--- @field MAX_SIZE number cap on the outbound buffer
--- @field NAME string the module tag
local M = {}
]]

local entries = scan(synth)

-- Expected: greet + farewell + 2 field entries = 4 total.
local function count_of(kind)
  local n = 0
  for _, e in ipairs(entries) do
    if e.kind == kind then n = n + 1 end
  end
  return n
end

local n_fn = count_of("function")
local n_fld = count_of("field")

local fails = 0
local function check(cond, name, detail)
  if cond then
    print("[+] " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

check(n_fn == 2, "extracted 2 documented functions",
      "got " .. tostring(n_fn) .. "; entries=" .. tostring(#entries))
check(n_fld == 2, "extracted 2 field entries",
      "got " .. tostring(n_fld))

-- Rendered page must carry the tag headings.
local page = render("synth", entries)
check(page:find("# API: synth", 1, true) ~= nil,
      "page has the top-level API heading")
check(page:find("## greet", 1, true) ~= nil,
      "page has a `## greet` function heading")
check(page:find("## farewell", 1, true) ~= nil,
      "page has a `## farewell` function heading")
check(page:find("### @param", 1, true) ~= nil,
      "page has @param sections")
check(page:find("### @return", 1, true) ~= nil,
      "page has @return sections")
check(page:find("### @throws", 1, true) ~= nil,
      "page has an @throws section")
check(page:find("### @see", 1, true) ~= nil,
      "page has an @see section")
check(page:find("Deprecated", 1, true) ~= nil,
      "page marks the deprecated function")
check(page:find("MAX_SIZE", 1, true) ~= nil,
      "page includes an @field entry")

-- Undocumented helper MUST NOT leak through.
check(page:find("_internal", 1, true) == nil,
      "undocumented helper is NOT emitted")

if fails > 0 then
  print("[-] FAIL test-doc-comments: " .. tostring(fails) .. " assertion(s) failed")
  os.exit(1)
end
print("[+] PASS test-doc-comments (ldoc-tag scanner + renderer)")
os.exit(0)
