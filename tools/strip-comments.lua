-- strip-comments.lua — token-aware comment removal for the GitHub publishing
-- pipeline (the published mirrors carry no code comments; the local repo
-- stays the commented canonical source).
--
--   luavm.exe tools\strip-comments.lua <file>            (in place, by ext)
--   luavm.exe tools\strip-comments.lua --tree <dir>      (recursive, by ext)
--
-- Languages: .lua (full scanner: short/long strings, long comments),
-- .c/.h (strings, char literals, // with backslash-continuation, /* */
-- preserving contained newlines), and conservative full-line stripping for
-- Makefile/#-style (.ps1 here-string aware, .py shebang kept) and .bat rem.
-- Verification is external: parse-checks + the full test suite run against
-- the stripped trees.

local M = {}

-- ---- Lua ------------------------------------------------------------------

function M.strip_lua(src)
  local out, i, n = {}, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if c == '-' and src:sub(i + 1, i + 1) == '-' then
      local eq = src:match("^%-%-%[(=*)%[", i)
      if eq then
        local s, e = src:find("]" .. eq .. "]", i + 4 + #eq, true)
        e = e or n
        local kept = src:sub(i, e):gsub("[^\n]", "")
        out[#out + 1] = (kept == "") and " " or kept   -- never join tokens
        i = e + 1
      else
        local nl = src:find("\n", i, true)
        i = nl or (n + 1)                              -- keep the newline
      end
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == '\\' then j = j + 2
        elseif d == c or d == '\n' then break
        else j = j + 1 end
      end
      out[#out + 1] = src:sub(i, math.min(j, n))
      i = j + 1
    elseif c == '[' then
      local eq = src:match("^%[(=*)%[", i)
      if eq then
        local s, e = src:find("]" .. eq .. "]", i + 2 + #eq, true)
        e = e or n
        out[#out + 1] = src:sub(i, e)
        i = e + 1
      else
        out[#out + 1] = c; i = i + 1
      end
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end

-- ---- C --------------------------------------------------------------------

function M.strip_c(src)
  local out, i, n = {}, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    local c2 = src:sub(i, i + 1)
    if c2 == "//" then
      -- line comment; a trailing backslash continues it onto the next line
      local j = i + 2
      while j <= n do
        local nl = src:find("\n", j, true)
        if not nl then j = n + 1 break end
        local back = nl - 1
        local bs = 0
        while back >= 1 and src:sub(back, back) == '\r' do back = back - 1 end
        while back >= 1 and src:sub(back, back) == '\\' do bs = bs + 1; back = back - 1 end
        if bs % 2 == 1 then j = nl + 1 else j = nl break end
      end
      i = (j <= n) and j or (n + 1)                    -- keep the newline
    elseif c2 == "/*" then
      local s, e = src:find("*/", i + 2, true)   -- e = index of the closing '/'
      e = e or n
      local kept = src:sub(i, e):gsub("[^\n]", "")     -- preserve line count
      out[#out + 1] = (kept == "") and " " or kept     -- never join tokens
      i = e + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == '\\' then j = j + 2
        elseif d == c or d == '\n' then break
        else j = j + 1 end
      end
      out[#out + 1] = src:sub(i, math.min(j, n))
      i = j + 1
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end

-- ---- conservative full-line strippers --------------------------------------

-- '#'-comment languages: drop lines whose first non-blank char is '#'
-- (shebang on line 1 kept). PowerShell here-strings (@' .. '@ / @" .. "@)
-- are honored so commented-looking lines inside them survive.
function M.strip_hash_lines(src, keep_shebang)
  local out, lineno, here = {}, 0, nil
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    if here then
      out[#out + 1] = line
      if line:match("^%s*" .. here .. "@") then here = nil end
    else
      local h = line:match("@(['\"])%s*$")
      if h then here = h end
      local first = line:match("^%s*(.)")
      if first == "#" and not (keep_shebang and lineno == 1 and line:sub(1, 2) == "#!") then
        -- dropped
      else
        out[#out + 1] = line
      end
    end
  end
  return table.concat(out, "\n")
end

function M.strip_bat_lines(src)
  local out = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    local t = line:match("^%s*[Rr][Ee][Mm]%s") or line:match("^%s*[Rr][Ee][Mm]%s*$")
    if not t then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

-- ---- shared post-pass: trim trailing blanks, collapse blank runs ------------

function M.tidy(src)
  local out, blanks = {}, 0
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("%s+$", "")
    if line == "" then
      blanks = blanks + 1
      if blanks <= 1 and #out > 0 then out[#out + 1] = line end
    else
      blanks = 0
      out[#out + 1] = line
    end
  end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n") .. "\n"
end

-- ---- dispatch ---------------------------------------------------------------

local function lang_of(path)
  local p = path:lower()
  if p:match("%.lua$") then return "lua" end
  if p:match("%.[ch]$") then return "c" end
  if p:match("%.ps1$") or p:match("%.py$") or p:match("makefile[%.%w]*$")
     or p:match("%.gitattributes$") or p:match("%.gitignore$") then return "hash" end
  if p:match("%.bat$") then return "bat" end
  return nil
end

function M.strip_file(path)
  local lang = lang_of(path)
  if not lang then return false, "unhandled" end
  local f = io.open(path, "rb"); if not f then return false, "open" end
  local src = f:read("*a"); f:close()
  src = src:gsub("\r\n", "\n")
  local stripped
  if lang == "lua" then stripped = M.strip_lua(src)
  elseif lang == "c" then stripped = M.strip_c(src)
  elseif lang == "hash" then stripped = M.strip_hash_lines(src, true)
  else stripped = M.strip_bat_lines(src) end
  stripped = M.tidy(stripped)
  if lang == "lua" then
    local chunk, err = load(stripped, "@" .. path)
    if not chunk then return false, "parse: " .. tostring(err) end
  end
  local w = io.open(path, "wb"); if not w then return false, "write" end
  w:write(stripped); w:close()
  return true
end

-- ---- CLI --------------------------------------------------------------------

if _G.STRIP_AS_MODULE then return M end   -- dofile'd by build-registry.lua

local args = { ... }
if #args == 0 and arg then args = { arg[1], arg[2] } end  -- luavm host passes argv via `arg`
if args[1] == "--tree" and args[2] then
  local root = args[2]
  local p = io.popen('dir /b /s /a-d "' .. root .. '" 2>nul')
  local done, failed = 0, 0
  for path in p:lines() do
    if lang_of(path) then
      local ok, why = M.strip_file(path)
      if ok then done = done + 1
      elseif why ~= "unhandled" then
        failed = failed + 1
        print("[-] FAIL strip " .. path .. " -- " .. tostring(why))
      end
    end
  end
  p:close()
  print(("[+] stripped %d file(s), %d failure(s)"):format(done, failed))
  os.exit(failed == 0 and 0 or 1)
elseif args[1] and args[1] ~= "--tree" then
  local ok, why = M.strip_file(args[1])
  print(ok and ("[+] stripped " .. args[1]) or ("[-] " .. tostring(why)))
  os.exit(ok and 0 or 1)
else
  return M
end
