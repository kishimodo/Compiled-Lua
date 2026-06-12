-- build-package-readmes.lua — generate a package-level README.md for every
-- staged registry package, mechanically, from the ORIGINAL (commented) source
-- under clua/src/runtime/packages/<name>/init.lua.
--
--   build\bin\luavm.exe tools\build-package-readmes.lua <staged-registry-dir>
--
-- Writes <staged-registry-dir>\<name>\README.md (PACKAGE level, NOT inside the
-- version dir — rover's publish hashes only version dirs, so these files must
-- not change index.json; verify by re-running `rover publish` afterwards).
--
-- Per README: title; description = the header comment block of init.lua
-- (consecutive leading `--` lines; the BIT_SHIM_COMPAT marker + shim line are
-- skipped); Install; Usage (require + first description line); API = function
-- names scanned from the source (`function M.x(...)`, `M.x = function(...)`,
-- and `local function f` re-exported as `M.x = f`), with args when cheaply
-- extractable; a footer when the source itself touches the FFI.

local SRC = "clua\\src\\runtime\\packages"

local out = ({ ... })[1] or (arg and arg[1])
if not out then print("usage: build-package-readmes.lua <staged-registry-dir>") os.exit(2) end

local function slurp(p) local f = io.open(p, "rb") if not f then return nil end local s = f:read("*a") f:close() return s end
local function spit(p, s) local f = assert(io.open(p, "wb")) f:write(s) f:close() end
local function isdir(p) local ok = os.rename(p, p) return ok ~= nil end

local function list(cmd)
  local t, p = {}, io.popen(cmd .. " 2>nul")
  if p then for l in p:lines() do if l ~= "" then t[#t + 1] = l end end p:close() end
  return t
end

-- ---- header comment block ---------------------------------------------------
-- Collect the leading run of `--` lines. If that block is the BIT_SHIM_COMPAT
-- marker, skip it (and the shim code line) and collect the next comment block.
local function header_block(src)
  local lines = {}
  for line in (src:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local function collect(from)
    local block, i = {}, from
    while i <= #lines do
      local body = lines[i]:match("^%s*%-%-+(.*)$")
      if not body then break end
      block[#block + 1] = body:gsub("^ ", "")    -- drop ONE space after the dashes
      i = i + 1
    end
    return block, i
  end
  local block, nxt = collect(1)
  if block[1] and block[1]:match("^%s*BIT_SHIM_COMPAT") then
    local i = nxt
    while i <= #lines and not lines[i]:match("^%s*%-%-") do i = i + 1 end
    block = collect(i)
  end
  -- trim leading/trailing blank lines
  while block[1] == "" do table.remove(block, 1) end
  while block[#block] == "" do table.remove(block) end
  return block
end

-- First line of the description, with the `<name> --` prefix removed.
local function first_line(block, name)
  local l = block[1] or ""
  local rest = l:match("^" .. name:gsub("%W", "%%%0") .. "%s*%-%-+%s*(.+)$")
  return rest or l
end

-- ---- API scan ----------------------------------------------------------------
local function scan_api(src)
  src = src:gsub("\r\n", "\n")
  local names, args, order = {}, {}, {}
  local function add(name, a)
    if not names[name] then names[name] = true order[#order + 1] = name end
    if a and not args[name] then args[name] = a end
  end
  for name, a in src:gmatch("function%s+M%.([%w_]+)%s*(%b())") do add(name, a) end
  for name, a in src:gmatch("M%.([%w_]+)%s*=%s*function%s*(%b())") do add(name, a) end
  -- local function f(...) later exported as M.x = f
  local largs = {}
  for name, a in src:gmatch("local%s+function%s+([%w_]+)%s*(%b())") do
    if not largs[name] then largs[name] = a end
  end
  for ename, lname in src:gmatch("M%.([%w_]+)%s*=%s*([%a_][%w_]*)%s") do
    if largs[lname] then add(ename, largs[lname]) end
  end
  table.sort(order)
  return order, args
end

-- ---- README assembly -----------------------------------------------------------
local function render(name, src)
  local block = header_block(src)
  local desc1 = first_line(block, name)
  local md = {}
  md[#md + 1] = "# " .. name
  md[#md + 1] = ""
  if desc1 ~= "" then
    md[#md + 1] = desc1
    md[#md + 1] = ""
  end
  local rest_from = 2
  while block[rest_from] == "" do rest_from = rest_from + 1 end
  if block[rest_from] then
    md[#md + 1] = "```text"
    for i = rest_from, #block do md[#md + 1] = block[i] end
    md[#md + 1] = "```"
    md[#md + 1] = ""
  end
  md[#md + 1] = "## Install"
  md[#md + 1] = ""
  md[#md + 1] = "```"
  md[#md + 1] = "rover install " .. name
  md[#md + 1] = "```"
  md[#md + 1] = ""
  md[#md + 1] = "## Usage"
  md[#md + 1] = ""
  local var = name:match("^[%a_][%w_]*$") and name or ("pkg_" .. name:gsub("%W", "_"))
  md[#md + 1] = "```lua"
  md[#md + 1] = ('local %s = require "%s"'):format(var, name)
  md[#md + 1] = "```"
  md[#md + 1] = ""
  if desc1 ~= "" then
    md[#md + 1] = desc1
    md[#md + 1] = ""
  end
  local order, args = scan_api(src)
  if #order > 0 then
    md[#md + 1] = "## API"
    md[#md + 1] = ""
    for _, fn in ipairs(order) do
      local a = args[fn]
      if a then
        md[#md + 1] = ("- `%s.%s%s`"):format(name, fn, a)
      else
        md[#md + 1] = ("- `%s.%s`"):format(name, fn)
      end
    end
    md[#md + 1] = ""
  end
  if src:match("ffi%.") or src:match('require%s*%(?%s*["\']ffi["\']') then
    md[#md + 1] = "---"
    md[#md + 1] = ""
    md[#md + 1] = "Note: this package is FFI-backed and runs under the LuaVM host only."
    md[#md + 1] = ""
  end
  return table.concat(md, "\n")
end

-- ---- main ---------------------------------------------------------------------
local names = list('dir /b /ad "' .. SRC .. '"')
table.sort(names)
local written, skipped = 0, 0
for _, name in ipairs(names) do
  local src = slurp(SRC .. "\\" .. name .. "\\init.lua")
  local pkgdir = out .. "\\" .. name
  if src and isdir(pkgdir) then
    spit(pkgdir .. "\\README.md", render(name, src))
    written = written + 1
  else
    skipped = skipped + 1
    print("[-] skip " .. name .. (src and " (not staged)" or " (no init.lua)"))
  end
end
print(("[+] wrote %d README.md file(s), %d skipped"):format(written, skipped))
os.exit(skipped == 0 and 0 or 1)
