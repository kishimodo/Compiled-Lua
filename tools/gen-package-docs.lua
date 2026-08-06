-- tools/gen-package-docs.lua : scanner-only for the packages site section.
--
-- Reads clua/src/runtime/packages/<name>/init.lua for every subdirectory of
-- the packages tree, looks for a documentation fence in the top comment
-- block, and writes docs/site/packages/<name>.md. Packages that do not carry
-- a documentation header get a stub page with a note pointing at the source,
-- so links from other pages do not go stale while the header rollout catches
-- up.
--
-- Fence recognised at the top of a package init.lua:
--
--   --[[doc
--   short one-line summary of the package.
--
--   longer prose here, one paragraph per doc feature. hyphen bullets are
--   fine. inline `code` and ```fenced``` blocks are passed through as is.
--   ]]
--
-- The fence must be the first non-blank content in the file (leading blanks
-- and shebang-style comments are tolerated). Everything between the opening
-- `--[[doc` line and the closing `]]` on its own line becomes the body of the
-- generated markdown, after a `# <name>` heading.
--
-- Usage:
--
--   build\bin\clua-interp.exe tools\gen-package-docs.lua
--
-- Writes to docs\site\packages\<name>.md. Prints one line per package. Exit 0
-- unless the packages directory cannot be opened, in which case exit 2 with
-- a short message on stderr (the tree may legitimately not have submodules
-- checked out).

local PKG_ROOT = "clua/src/runtime/packages"
local OUT_ROOT = "docs/site/packages"

local function is_dir(path)
  -- os.rename onto itself is the standard trick for existence + type on
  -- lua without lfs. A directory succeeds, a missing path returns nil, a
  -- regular file also succeeds so callers must know the shape.
  local ok = os.rename(path, path)
  return ok ~= nil
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a") or ""
  f:close()
  return s
end

local function spit(path, s)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(s)
  f:close()
  return true
end

local function list_dirs(root)
  -- Portable-ish: shell out to `dir /b /ad` on windows, `ls -1` on posix.
  -- The two are enough because clua-interp on the target platform is
  -- windows and the fallback covers a contributor running the tool on
  -- linux out of habit.
  local names = {}
  local cmd
  if package.config:sub(1, 1) == "\\" then
    cmd = string.format('cmd /c "dir /b /ad \"%s\" 2>nul"',
                        (root:gsub("/", "\\")))
  else
    cmd = string.format("ls -1 %q 2>/dev/null", root)
  end
  local p = io.popen(cmd)
  if not p then return names end
  for line in p:lines() do
    line = line:gsub("[\r\n]+$", "")
    if line ~= "" then names[#names + 1] = line end
  end
  p:close()
  table.sort(names)
  return names
end

-- Split a whole-file blob into lines, preserving blank ones so line numbers
-- in error messages line up with an editor.
local function split_lines(s)
  local lines, start = {}, 1
  for i = 1, #s do
    if s:byte(i) == 10 then
      local ln = s:sub(start, i - 1)
      if ln:sub(-1) == "\r" then ln = ln:sub(1, -2) end
      lines[#lines + 1] = ln
      start = i + 1
    end
  end
  if start <= #s then
    local ln = s:sub(start)
    if ln:sub(-1) == "\r" then ln = ln:sub(1, -2) end
    lines[#lines + 1] = ln
  end
  return lines
end

-- Extract the body of the doc fence, if present. Returns the body string or
-- nil if the file has no fence. Leading blank lines and top-of-file `--`
-- comment banners are skipped so a header comment above the fence does not
-- disqualify a package.
local function extract_fence(src)
  local lines = split_lines(src)
  local i = 1
  while i <= #lines do
    local ln = lines[i]
    if ln:match("^%s*$") then
      i = i + 1
    elseif ln:match("^%s*%-%-[^%[]") or ln:match("^#!") then
      -- single-line comment or shebang; skip
      i = i + 1
    else
      break
    end
  end
  if i > #lines then return nil end
  local open = lines[i]:match("^%s*%-%-%[%[%s*doc%s*$")
  if not open then return nil end
  local body = {}
  i = i + 1
  while i <= #lines do
    if lines[i]:match("^%s*%]%]%s*$") then
      return table.concat(body, "\n")
    end
    body[#body + 1] = lines[i]
    i = i + 1
  end
  return nil                                    -- unterminated fence
end

local function stub_page(name, init_path)
  return string.format([[
# %s

this package does not yet carry a documentation header in its
`init.lua`. once the header is in place, `tools/gen-package-docs.lua`
will regenerate this page from the source.

source:

```
%s
```
]], name, init_path)
end

local function real_page(name, body)
  return string.format("# %s\n\n%s\n", name, body)
end

local function main()
  if not is_dir(PKG_ROOT) then
    io.stderr:write("gen-package-docs: no packages directory at "
                    .. PKG_ROOT .. " (submodule not checked out?)\n")
    os.exit(2)
  end
  if not is_dir(OUT_ROOT) then
    io.stderr:write("gen-package-docs: output directory missing: "
                    .. OUT_ROOT .. "\n")
    os.exit(2)
  end

  local names = list_dirs(PKG_ROOT)
  local wrote_real, wrote_stub, skipped = 0, 0, 0

  for _, name in ipairs(names) do
    local init = PKG_ROOT .. "/" .. name .. "/init.lua"
    local src  = slurp(init)
    local out_path = OUT_ROOT .. "/" .. name .. ".md"
    if not src then
      io.write(string.format("[=] skip %s (no init.lua)\n", name))
      skipped = skipped + 1
    else
      local body = extract_fence(src)
      local page = body and real_page(name, body) or stub_page(name, init)
      local ok, err = spit(out_path, page)
      if not ok then
        io.stderr:write(string.format("[-] write %s: %s\n", out_path, err))
        os.exit(1)
      end
      if body then
        wrote_real = wrote_real + 1
        io.write(string.format("[+] %s (from doc fence)\n", name))
      else
        wrote_stub = wrote_stub + 1
        io.write(string.format("[+] %s (stub, no fence)\n", name))
      end
    end
  end

  io.write(string.format("done: %d real, %d stub, %d skipped, %d total\n",
                         wrote_real, wrote_stub, skipped, #names))
  os.exit(0)
end

main()
