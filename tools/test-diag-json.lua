-- tools/test-diag-json.lua : --diagnostics-format=json emits one rustc-shaped
-- JSON object per diagnostic on stderr.
--
-- Auto-discovered by tools/run-tests.lua. Skips if compiler.exe hasn't been
-- built. Shells out to compiler.exe with a deliberate syntax-error fixture,
-- captures stderr, splits on '\n', and parses each non-empty line as JSON --
-- we roll a tiny purpose-built parser here so the test doesn't depend on any
-- Lua JSON module. Then we assert the schema-critical fields: at least one
-- "severity":"error" object, a `spans` array with a primary span carrying
-- file+line, and (critically) the Windows path in `file` uses escaped
-- backslashes (`\\`), not raw ones.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT     = abscwd()
local COMPILER = ROOT .. "\\build\\bin\\compiler.exe"
local TMP      = (os.getenv("TEMP") or ".") .. "\\clua-diag-json-test"

local function sh(cmd)
  local ok, _, c = os.execute('"' .. cmd .. '"')
  return (ok == true) or (ok == 0) or (c == 0)
end
local function spit(p, s)
  local f = io.open(p, "wb"); if not f then return false end
  f:write(s); f:close(); return true
end
local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end
  return false
end
local function fail(m) print("[-] FAIL test-diag-json: " .. m); os.exit(1) end

if not exists(COMPILER) then
  print("[~] SKIP test-diag-json: " .. COMPILER .. " not found (run `make compiler` first)")
  os.exit(0)
end

-- Capture combined output + exit code from compiler.exe. Mirrors the
-- io.popen quoting trick used across the other tools/test-*.lua files.
local function compile(args)
  local full = '"' .. COMPILER .. '" ' .. args .. ' 2>&1'
  local p = io.popen('"' .. full .. '"')
  if not p then return "", -1 end
  local o = p:read("*a") or ""
  local _, _, code = p:close()
  return o, (code or 0)
end

-- ---- tiny JSON parser -----------------------------------------------------
-- Purpose-built for the exact shape the writer emits: objects, arrays,
-- strings (with JSON's escape set), numbers (ints), true/false/null. Errors
-- are raised via `error()` and caught by the caller with pcall; a real JSON
-- library would be overkill and would add an install-order dependency for
-- test authors, which the rest of this suite does not have.
local function parse_json(text)
  local i, n = 1, #text
  local function skipws()
    while i <= n do
      local c = text:sub(i, i)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1
      else break end
    end
  end
  local parse_value
  local function parse_string()
    if text:sub(i, i) ~= '"' then error("expected '\"' at " .. i) end
    i = i + 1
    local out = {}
    while i <= n do
      local c = text:sub(i, i)
      if c == '"' then i = i + 1; return table.concat(out) end
      if c == "\\" then
        local esc = text:sub(i + 1, i + 1)
        i = i + 2
        if     esc == '"'  then out[#out+1] = '"'
        elseif esc == "\\" then out[#out+1] = "\\"
        elseif esc == "/"  then out[#out+1] = "/"
        elseif esc == "b"  then out[#out+1] = "\b"
        elseif esc == "f"  then out[#out+1] = "\f"
        elseif esc == "n"  then out[#out+1] = "\n"
        elseif esc == "r"  then out[#out+1] = "\r"
        elseif esc == "t"  then out[#out+1] = "\t"
        elseif esc == "u"  then
          local hex = text:sub(i, i + 3)
          i = i + 4
          local cp = tonumber(hex, 16)
          if not cp then error("bad \\u escape: " .. hex) end
          -- We only see \u00XX (C0 controls) from the writer; encode as raw
          -- byte for < 0x80 so the assertion side can compare directly.
          if cp < 0x80 then
            out[#out+1] = string.char(cp)
          else
            out[#out+1] = "?"  -- lossy but we don't emit these in the test
          end
        else error("bad escape: \\" .. esc) end
      else
        out[#out+1] = c
        i = i + 1
      end
    end
    error("unterminated string")
  end
  local function parse_number()
    local j = i
    if text:sub(j, j) == "-" then j = j + 1 end
    while j <= n do
      local c = text:sub(j, j)
      if c:match("[0-9%.eE%+%-]") then j = j + 1 else break end
    end
    local s = text:sub(i, j - 1)
    i = j
    return tonumber(s)
  end
  local function parse_object()
    if text:sub(i, i) ~= "{" then error("expected '{'") end
    i = i + 1
    local obj = {}
    skipws()
    if text:sub(i, i) == "}" then i = i + 1; return obj end
    while true do
      skipws()
      local key = parse_string()
      skipws()
      if text:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
      i = i + 1
      skipws()
      obj[key] = parse_value()
      skipws()
      local c = text:sub(i, i)
      if c == "," then i = i + 1
      elseif c == "}" then i = i + 1; return obj
      else error("expected ',' or '}' at " .. i) end
    end
  end
  local function parse_array()
    if text:sub(i, i) ~= "[" then error("expected '['") end
    i = i + 1
    local arr = {}
    skipws()
    if text:sub(i, i) == "]" then i = i + 1; return arr end
    while true do
      skipws()
      arr[#arr + 1] = parse_value()
      skipws()
      local c = text:sub(i, i)
      if c == "," then i = i + 1
      elseif c == "]" then i = i + 1; return arr
      else error("expected ',' or ']' at " .. i) end
    end
  end
  parse_value = function()
    skipws()
    local c = text:sub(i, i)
    if     c == '"' then return parse_string()
    elseif c == "{" then return parse_object()
    elseif c == "[" then return parse_array()
    elseif c == "t" and text:sub(i, i+3) == "true"  then i = i + 4; return true
    elseif c == "f" and text:sub(i, i+4) == "false" then i = i + 5; return false
    elseif c == "n" and text:sub(i, i+3) == "null"  then i = i + 4; return nil
    elseif c:match("[%-0-9]") then return parse_number()
    else error("unexpected " .. c .. " at " .. i) end
  end
  return parse_value()
end

-- ---- fixture: syntax error --------------------------------------------------

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
sh('mkdir "' .. TMP .. '" >nul 2>&1')
local BAD = TMP .. "\\bad.lua"
local OUT = TMP .. "\\out.exe"
spit(BAD, "local x = 5\nlocal y = x +* 2\nprint(y)\n")

local o, c = compile('--color=never --diagnostics-format=json -o "' .. OUT .. '" "' .. BAD .. '"')
if c == 0 then fail("syntax error should fail the build (got exit 0)\n" .. o) end

-- Split output into lines and try to parse each as JSON. Some driver "banner"
-- lines (printf(...)) are NOT JSON; those go on stdout, not stderr, but the
-- popen capture we use merges them, so we tolerate lines that don't parse.
local diagnostics = {}
for line in (o .. "\n"):gmatch("([^\n]*)\n") do
  if line:sub(1, 1) == "{" then
    local ok, obj = pcall(parse_json, line)
    if ok and type(obj) == "table" and obj.severity then
      diagnostics[#diagnostics + 1] = { line = line, obj = obj }
    end
  end
end

if #diagnostics == 0 then
  fail("expected at least one JSON diagnostic on stderr, got none. Raw output:\n" .. o)
end

-- Find at least one error diagnostic with a primary span pointing at bad.lua.
local found_err = nil
for _, d in ipairs(diagnostics) do
  if d.obj.severity == "error" and type(d.obj.spans) == "table" then
    for _, sp in ipairs(d.obj.spans) do
      if sp.is_primary and type(sp.file) == "string" and sp.file:find("bad%.lua")
         and type(sp.line) == "number" and sp.line >= 1 then
        found_err = d
        break
      end
    end
  end
  if found_err then break end
end
if not found_err then
  local lines = {}
  for _, d in ipairs(diagnostics) do lines[#lines + 1] = d.line end
  fail("no error diagnostic with primary span on bad.lua found. JSON lines:\n"
       .. table.concat(lines, "\n"))
end

-- Backslash escaping: the raw JSON line for the Windows path in `file` must
-- contain `\\` sequences (JSON's escape for a literal backslash), not raw
-- backslashes. Look at the raw line so we're checking the encoder output, not
-- the post-parse string.
do
  local line = found_err.line
  -- Find the first "\"file\":\"...\"" occurrence and inspect its contents.
  local val = line:match('"file":"([^"]*)"')
  if not val then
    fail("could not locate the file field in the JSON line:\n" .. line)
  end
  -- The temp path contains at least one '\\' (Windows), so the encoded form
  -- MUST contain the two-char sequence `\\`.
  if not val:find("\\\\", 1, true) then
    fail("expected backslashes in Windows path to be encoded as `\\\\`, got:\n"
         .. val .. "\n(full line: " .. line .. ")")
  end
  -- And it must NOT contain a lone backslash followed by anything other than
  -- a JSON-legal escape char. We assert the stricter shape: every backslash
  -- run in the raw string is even-length.
  for run in val:gmatch("\\+") do
    if (#run % 2) ~= 0 then
      fail("odd-length backslash run in encoded file field: " .. val)
    end
  end
end

-- The `spans` array shape: is_primary is a boolean, col_start/col_end are
-- numbers-or-null. Check across every span we emitted so a schema drift on
-- one code path (e.g. the lint pass) fails loudly rather than at the first
-- editor that consumes the output.
for _, d in ipairs(diagnostics) do
  if type(d.obj.spans) ~= "table" then
    fail("diagnostic missing 'spans' array:\n" .. d.line)
  end
  for _, sp in ipairs(d.obj.spans) do
    if type(sp.is_primary) ~= "boolean" then
      fail("span.is_primary must be a boolean:\n" .. d.line)
    end
    if sp.col_start ~= nil and type(sp.col_start) ~= "number" then
      fail("span.col_start must be number or null:\n" .. d.line)
    end
    if sp.col_end ~= nil and type(sp.col_end) ~= "number" then
      fail("span.col_end must be number or null:\n" .. d.line)
    end
  end
  -- children and help are required keys, may be []/null.
  if d.obj.children == nil and not d.line:find('"children"') then
    fail("missing required 'children' key:\n" .. d.line)
  end
  if not d.line:find('"help"') then
    fail("missing required 'help' key:\n" .. d.line)
  end
end

-- No pretty-printing: each JSON line the emitter produced must be a single
-- line and must NOT contain embedded raw newlines (they'd be encoded as \n
-- inside string values). Walk the raw output and check that any line starting
-- with '{' also ends with '}' -- i.e. the object closed on the same line.
for line in (o .. "\n"):gmatch("([^\n]*)\n") do
  if line:sub(1, 1) == "{" then
    if line:sub(-1) ~= "}" then
      fail("JSON diagnostic split across lines (pretty-printed?):\n" .. line)
    end
  end
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
print("[+] PASS test-diag-json (rustc-shaped JSON diagnostics, one per line, "
      .. "escaped Windows paths, required schema keys present)")
os.exit(0)
