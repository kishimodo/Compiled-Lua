-- build-registry.lua — stage every in-tree package as a rover registry.
--
--   build\bin\clua-interp.exe tools\build-registry.lua <out-dir>
--
-- For each clua/src/runtime/packages/<name>/:
--   <out>/<name>/1.0.0/<files>   (.lua files comment-stripped + parse-checked;
--                                 other files copied byte-exact)
--   <out>/<name>/1.0.0/package.lua  (generated flat literal manifest; the
--                                    description is harvested from the
--                                    package's original header comment)
-- Then run `rover publish <out-dir>` to generate index.json (hashes computed
-- over the STRIPPED bytes — what installs verify against).

_G.STRIP_AS_MODULE = true
local strip = dofile("tools/strip-comments.lua")
_G.STRIP_AS_MODULE = nil

local SRC = "clua\\src\\runtime\\packages"
local out = ({ ... })[1] or (arg and arg[1])
if not out then print("usage: build-registry.lua <out-dir>") os.exit(2) end

local function sh(cmd) os.execute('cmd /c "' .. cmd .. '" >nul 2>nul') end
local function slurp(p) local f = io.open(p, "rb") if not f then return nil end local s = f:read("*a") f:close() return s end
local function spit(p, s) local f = assert(io.open(p, "wb")) f:write(s) f:close() end

local function list(cmd)
  local t, p = {}, io.popen(cmd .. " 2>nul")
  if p then for l in p:lines() do if l ~= "" then t[#t + 1] = l end end p:close() end
  return t
end

-- description = first header-comment line of init.lua, cleaned
local function describe(name)
  local src = slurp(SRC .. "\\" .. name .. "\\init.lua") or ""
  for line in src:gmatch("([^\n]*)\n") do
    local text = line:match("^%s*%-%-+%s*(.-)%s*$")
    if text and #text > 0 then
      text = text:gsub('^[%[%]=%-!@|]+%s*', ''):gsub('[\\"]', "")
      if #text > 3 then return text:sub(1, 120) end
    end
    if not line:match("^%s*%-%-") and line:match("%S") then break end
  end
  return name .. " package for CLua"
end

local ROOT = list("cd")[1]                 -- repo root (runner CWD), absolute

local names = list('dir /b /ad "' .. SRC .. '"')
table.sort(names)
print(("[*] staging %d package(s) -> %s"):format(#names, out))
sh('if not exist "' .. out .. '" mkdir "' .. out .. '"')

local staged, failed = 0, 0
for _, name in ipairs(names) do
  local sdir = SRC .. "\\" .. name
  local vdir = out .. "\\" .. name .. "\\1.0.0"
  local desc = describe(name)
  sh('mkdir "' .. vdir .. '"')
  local ok = true
  local absdir = ROOT .. "\\" .. sdir                     -- dir /b /s is absolute
  for _, abs in ipairs(list('dir /b /s /a-d "' .. sdir .. '"')) do
    local rel = abs:sub(#absdir + 2)                      -- path under sdir
    if rel == "" then ok = false break end
    if rel:lower() ~= "package.lua" then                  -- manifest is regenerated
      local dst = vdir .. "\\" .. rel
      local sub = rel:match("^(.*)\\[^\\]+$")
      if sub then sh('if not exist "' .. vdir .. '\\' .. sub .. '" mkdir "' .. vdir .. '\\' .. sub .. '"') end
      if rel:lower():match("%.lua$") then
        local src = (slurp(abs) or ""):gsub("\r\n", "\n")
        local stripped = strip.tidy(strip.strip_lua(src))
        local chunk, err = load(stripped, "@" .. dst)
        if not chunk then
          print("[-] FAIL parse after strip: " .. dst .. " -- " .. tostring(err))
          ok = false
        else
          spit(dst, stripped)
        end
      else
        spit(dst, slurp(abs) or "")
      end
    end
  end
  spit(vdir .. "\\package.lua",
       ('return { name = "%s", version = "1.0.0", description = "%s" }\n')
       :format(name, desc))
  if ok then staged = staged + 1 else failed = failed + 1 end
end

print(("[+] staged %d package(s), %d failure(s)"):format(staged, failed))
os.exit(failed == 0 and 0 or 1)
