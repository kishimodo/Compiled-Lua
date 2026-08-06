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
-- ldoc-style API pages (one per package) land alongside the doc-fence pages,
-- so tooling that reads either directory finds one canonical location. The
-- fence pages are the human-authored prose; the api pages are auto-extracted
-- from `--- @tag` comments on function definitions.
local API_ROOT = "docs/site/api"

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

-- ---- ldoc-tag scanner ------------------------------------------------------
--
-- Walks a lua source file line by line, collecting contiguous `--- ...`
-- comment blocks. When a `function` (or `local function`) definition
-- immediately follows one of those blocks, the block's content becomes the
-- documentation for that function. Table-scope fields carry `--- @field`
-- annotations against a preceding `TABLE = {` line.
--
-- Recognised tags (case-sensitive):
--   ---  <description>              free-form summary text before any tag
--   --- @param NAME TYPE description
--   --- @return TYPE description
--   --- @throws MSG
--   --- @field NAME TYPE description
--   --- @see OTHER_NAME
--   --- @deprecated <note>
--
-- The scanner is line-based on purpose: a real Lua parser would drag in
-- much more machinery, and the tag conventions are already line-oriented.
-- Nothing here executes the source, so a broken package still yields a
-- usable page (with any prose written above the definitions).

-- Extract the function name from a `function` line. Returns nil for
-- multi-line function definitions and inline function-expressions the
-- scanner does not try to name.
local function parse_function_line(ln)
  local nm = ln:match("^%s*function%s+([%w_%.:]+)%s*%(") or
             ln:match("^%s*local%s+function%s+([%w_]+)%s*%(") or
             ln:match("^%s*([%w_%.:]+)%s*=%s*function%s*%(")
  return nm
end

-- Parse one `--- @tag ...` line. Returns tag (string) and the remainder.
-- Returns nil when the line isn't a triple-dash comment.
local function parse_doc_line(ln)
  -- match `---` (exactly 3 dashes) optionally followed by content
  local rest = ln:match("^%s*%-%-%-(.*)$")
  if not rest then return nil end
  -- --[[ (a long comment) should not swallow triple-dash short comments,
  -- and Lua's `----` is `--` followed by `--`: guard against 4+ dashes
  -- being misread as an empty triple-dash.
  if ln:match("^%s*%-%-%-%-") then return nil end
  rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
  local tag, body = rest:match("^@(%w+)%s*(.*)$")
  if tag then
    return tag, body
  end
  -- plain description line
  return "_desc", rest
end

-- Collect the ldoc entities from a source blob. Returns a list of
-- { kind = "function"|"field"|"deprecated", name, params, returns, ... }.
-- `params` and `returns` are ordered lists. `see` is a list. Missing fields
-- default to empty.
local function scan_ldoc(src)
  local entries = {}
  local lines   = split_lines(src)
  local block   = nil                             -- accumulating comment block

  local function reset_block()
    block = { desc = {}, params = {}, returns = {}, throws = {},
              fields = {}, see = {}, deprecated = nil }
  end
  reset_block()
  local have_content = false

  for i = 1, #lines do
    local ln = lines[i]
    local tag, body = parse_doc_line(ln)
    if tag == "_desc" then
      block.desc[#block.desc + 1] = body
      have_content = true
    elseif tag == "param" then
      local nm, ty, rest = body:match("^([%w_%.]+)%s+(%S+)%s*(.*)$")
      if nm then
        block.params[#block.params + 1] = { name = nm, type_ = ty, desc = rest }
      else
        -- tolerate `@param NAME` with no type
        nm = body:match("^([%w_%.]+)%s*(.*)$")
        if nm then
          block.params[#block.params + 1] = { name = nm, type_ = "?", desc = "" }
        end
      end
      have_content = true
    elseif tag == "return" or tag == "returns" then
      local ty, rest = body:match("^(%S+)%s*(.*)$")
      if ty then
        block.returns[#block.returns + 1] = { type_ = ty, desc = rest }
      end
      have_content = true
    elseif tag == "throws" then
      block.throws[#block.throws + 1] = body
      have_content = true
    elseif tag == "field" then
      local nm, ty, rest = body:match("^([%w_%.]+)%s+(%S+)%s*(.*)$")
      if nm then
        block.fields[#block.fields + 1] = { name = nm, type_ = ty, desc = rest }
        have_content = true
      end
    elseif tag == "see" then
      block.see[#block.see + 1] = body
      have_content = true
    elseif tag == "deprecated" then
      block.deprecated = body ~= "" and body or "(no reason given)"
      have_content = true
    elseif tag == nil then
      -- non-doc line -- if it starts a function, emit an entry
      if have_content then
        local fnname = parse_function_line(ln)
        if fnname then
          entries[#entries + 1] = {
            kind       = "function",
            name       = fnname,
            desc       = block.desc,
            params     = block.params,
            returns    = block.returns,
            throws     = block.throws,
            see        = block.see,
            deprecated = block.deprecated,
          }
        elseif #block.fields > 0 then
          for _, f in ipairs(block.fields) do
            entries[#entries + 1] = {
              kind = "field",
              name = f.name,
              type_ = f.type_,
              desc = { f.desc },
            }
          end
        end
        reset_block()
        have_content = false
      else
        reset_block()
      end
    end
  end
  return entries
end

-- Render a list of ldoc entries as a markdown page.
local function ldoc_page(name, entries)
  local out = { "# API: " .. name, "" }
  if #entries == 0 then
    out[#out + 1] = ("_no doc-comments found in %s/init.lua_"):format(name)
    out[#out + 1] = ""
    return table.concat(out, "\n")
  end
  for _, e in ipairs(entries) do
    if e.kind == "function" then
      out[#out + 1] = "## " .. e.name
      if e.deprecated then
        out[#out + 1] = ""
        out[#out + 1] = "**Deprecated.** " .. e.deprecated
      end
      if e.desc and #e.desc > 0 then
        out[#out + 1] = ""
        out[#out + 1] = table.concat(e.desc, "\n")
      end
      if #e.params > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "### @param"
        for _, p in ipairs(e.params) do
          out[#out + 1] = ("- `%s` (%s) %s"):format(p.name, p.type_, p.desc)
        end
      end
      if #e.returns > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "### @return"
        for _, r in ipairs(e.returns) do
          out[#out + 1] = ("- (%s) %s"):format(r.type_, r.desc)
        end
      end
      if #e.throws > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "### @throws"
        for _, t in ipairs(e.throws) do
          out[#out + 1] = "- " .. t
        end
      end
      if #e.see > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "### @see"
        for _, s in ipairs(e.see) do
          out[#out + 1] = "- " .. s
        end
      end
      out[#out + 1] = ""
    elseif e.kind == "field" then
      out[#out + 1] = ("## %s (field: %s)"):format(e.name, e.type_)
      if e.desc and e.desc[1] and e.desc[1] ~= "" then
        out[#out + 1] = ""
        out[#out + 1] = e.desc[1]
      end
      out[#out + 1] = ""
    end
  end
  return table.concat(out, "\n")
end

-- Exposed for tools/test-doc-comments.lua so the doc-comment work can be
-- exercised without touching the on-disk packages tree.
_G.__gen_package_docs_scan_ldoc = scan_ldoc
_G.__gen_package_docs_ldoc_page = ldoc_page

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
  if not is_dir(API_ROOT) then
    io.stderr:write("gen-package-docs: api output directory missing: "
                    .. API_ROOT .. "\n")
    os.exit(2)
  end

  local names = list_dirs(PKG_ROOT)
  local wrote_real, wrote_stub, skipped = 0, 0, 0
  local wrote_api, api_entries_total = 0, 0

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
      -- Emit the API page whether or not the fence page was real: doc-comments
      -- can live in an init.lua that has no fenced prose header.
      local entries = scan_ldoc(src)
      local api_ok, api_err = spit(API_ROOT .. "/" .. name .. ".md",
                                    ldoc_page(name, entries))
      if not api_ok then
        io.stderr:write(string.format("[-] write api/%s.md: %s\n", name, api_err))
        os.exit(1)
      end
      wrote_api = wrote_api + 1
      api_entries_total = api_entries_total + #entries
    end
  end

  io.write(string.format("done: %d real, %d stub, %d skipped, %d total; "
                         .. "%d api pages (%d ldoc entries)\n",
                         wrote_real, wrote_stub, skipped, #names,
                         wrote_api, api_entries_total))
  os.exit(0)
end

main()
