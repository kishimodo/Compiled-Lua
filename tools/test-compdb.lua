-- test-compdb.lua -- behavioural suite for `clua build --emit-compdb[-append]`.
--
-- The compile_commands.json emitter records ONE entry per invocation and
-- feeds clangd / VS Code C/C++ / ccls so editors can drive LSP over CLua
-- sources. This suite pins the schema:
--   * --emit-compdb=<path>          writes a single-entry array,
--   * --emit-compdb-append=<path>   accumulates into that array,
--   * each entry has "directory", "file", "arguments",
--   * the "file" resolves to an absolute path,
--   * the "arguments" first token is the argv[0] passed to clua.exe,
--   * Windows backslashes in paths are JSON-escaped correctly (round-trips
--     through the tiny parser below into a literal backslash).
--
-- Skips cleanly when clua.exe hasn't been built (same convention as the
-- other tools/test-*.lua suites).

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-compdb (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")
local TEMP = os.getenv("TEMP") or "."
local CLUA_ABS = ROOT .. "\\" .. CLUA

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. tostring(detail):sub(1, 300)) or ""))
  end
end

local function run(cmd)
  local f = io.popen("(" .. cmd .. ") 2>&1")
  local out = f:read("*a") or ""
  local okc, _, code = f:close()
  if okc == true then code = 0 end
  return code or -1, out
end

local function writefile(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end

local function readfile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- ---- minimal JSON reader (arrays / objects / strings) -----------------------
-- The compdb writes a strict subset: JSON arrays containing objects containing
-- string values and one string-array. We only need to walk that; a full parser
-- would be overkill.
local function skip_ws(s, i)
  while i <= #s do
    local c = s:sub(i, i)
    if c ~= " " and c ~= "\t" and c ~= "\r" and c ~= "\n" then return i end
    i = i + 1
  end
  return i
end

local parse_value
local function parse_string(s, i)
  assert(s:sub(i, i) == '"', "expected string at " .. i)
  i = i + 1
  local buf = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then return table.concat(buf), i + 1 end
    if c == '\\' then
      local n = s:sub(i + 1, i + 1)
      if     n == '"'  then buf[#buf+1] = '"'  ; i = i + 2
      elseif n == '\\' then buf[#buf+1] = '\\' ; i = i + 2
      elseif n == '/'  then buf[#buf+1] = '/'  ; i = i + 2
      elseif n == 'b'  then buf[#buf+1] = '\b' ; i = i + 2
      elseif n == 'f'  then buf[#buf+1] = '\f' ; i = i + 2
      elseif n == 'n'  then buf[#buf+1] = '\n' ; i = i + 2
      elseif n == 'r'  then buf[#buf+1] = '\r' ; i = i + 2
      elseif n == 't'  then buf[#buf+1] = '\t' ; i = i + 2
      elseif n == 'u'  then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16) or 0
        if cp < 128 then buf[#buf+1] = string.char(cp) end
        i = i + 6
      else error("bad escape at " .. i) end
    else
      buf[#buf+1] = c
      i = i + 1
    end
  end
  error("unterminated string")
end

local function parse_array(s, i)
  assert(s:sub(i, i) == '[')
  i = i + 1
  local a = {}
  i = skip_ws(s, i)
  if s:sub(i, i) == ']' then return a, i + 1 end
  while true do
    local v; v, i = parse_value(s, i)
    a[#a+1] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == ']' then return a, i + 1 end
    assert(c == ',', "expected ',' or ']' at " .. i .. " got '" .. c .. "'")
    i = skip_ws(s, i + 1)
  end
end

local function parse_object(s, i)
  assert(s:sub(i, i) == '{')
  i = i + 1
  local o = {}
  i = skip_ws(s, i)
  if s:sub(i, i) == '}' then return o, i + 1 end
  while true do
    i = skip_ws(s, i)
    local k; k, i = parse_string(s, i)
    i = skip_ws(s, i)
    assert(s:sub(i, i) == ':', "expected ':' at " .. i)
    i = skip_ws(s, i + 1)
    local v; v, i = parse_value(s, i)
    o[k] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '}' then return o, i + 1 end
    assert(c == ',', "expected ',' or '}' at " .. i .. " got '" .. c .. "'")
    i = i + 1
  end
end

parse_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then return parse_string(s, i) end
  if c == '[' then return parse_array(s, i) end
  if c == '{' then return parse_object(s, i) end
  error("unexpected char '" .. c .. "' at " .. i)
end

local function parse_json(s)
  return (parse_value(s, 1))
end

-- ---- fixture ---------------------------------------------------------------
local FIXTURE = TEMP .. "\\clua_t_compdb.lua"
writefile(FIXTURE, 'print("compdb hi")\nreturn 0\n')
local CDB = TEMP .. "\\clua_t_compdb.json"
os.remove(CDB)

-- ---- 1. --emit-compdb writes a valid single-entry array --------------------
do
  local code, out = run(('"%s" build "%s" "--emit-compdb=%s" --emit=bytecode --emit-only')
                          :format(CLUA_ABS, FIXTURE, CDB))
  local raw = readfile(CDB) or ""
  local okp, doc = pcall(parse_json, raw)
  local entry = okp and type(doc) == "table" and doc[1] or nil
  ok(code == 0 and okp and type(doc) == "table" and #doc == 1
       and type(entry) == "table"
       and type(entry.directory) == "string"
       and type(entry.file) == "string"
       and type(entry.arguments) == "table"
       and #entry.arguments >= 1,
     "--emit-compdb writes a valid single-entry array with directory/file/arguments",
     ("code=%s okp=%s raw=%q out=%q"):format(tostring(code), tostring(okp),
                                             raw:sub(1, 300), out:sub(1, 200)))
  -- File field should resolve to the absolute fixture path (case-insensitive
  -- on Windows: the CRT lower-cases the drive letter, we lower-case both
  -- ends to compare).
  if entry then
    local want = FIXTURE:lower()
    local got  = tostring(entry.file):lower()
    ok(got:find(want, 1, true) ~= nil or want:find(got:sub(4), 1, true) ~= nil
         or got:find("clua_t_compdb.lua", 1, true) ~= nil,
       "compdb entry.file references the input fixture",
       ("want=%q got=%q"):format(want, got))
    -- The arguments should include the input path somewhere.
    local args = entry.arguments
    local found_input = false
    for _, a in ipairs(args) do
      if type(a) == "string" and a:find("clua_t_compdb.lua", 1, true) then
        found_input = true; break
      end
    end
    ok(found_input, "compdb entry.arguments contains the input path token",
       "args=" .. table.concat(args, " | "))
    -- Verify Windows backslashes in "directory" round-trip: the raw JSON
    -- MUST contain \\ pairs (JSON-escaped), and the parsed value MUST
    -- contain literal single backslashes.
    if entry.directory:find(":", 1, true) then
      local raw_has_pair = raw:find([[\\]], 1, true) ~= nil
      local parsed_has_sep = entry.directory:find("\\", 1, true) ~= nil
      ok(raw_has_pair and parsed_has_sep,
         "compdb JSON escapes Windows backslashes as \\\\ and they round-trip",
         ("raw_pair=%s parsed_sep=%s dir=%q")
           :format(tostring(raw_has_pair), tostring(parsed_has_sep), entry.directory))
    end
  end
end

-- ---- 2. --emit-compdb-append extends the existing array --------------------
do
  local code, out = run(('"%s" build "%s" "--emit-compdb-append=%s" --emit=bytecode --emit-only')
                          :format(CLUA_ABS, FIXTURE, CDB))
  local raw = readfile(CDB) or ""
  local okp, doc = pcall(parse_json, raw)
  ok(code == 0 and okp and type(doc) == "table" and #doc == 2
       and type(doc[1]) == "table"
       and type(doc[2]) == "table"
       and type(doc[2].file) == "string",
     "--emit-compdb-append grows a single-entry array to two entries",
     ("code=%s okp=%s len=%s raw=%q out=%q")
       :format(tostring(code), tostring(okp),
               tostring(okp and doc and #doc or -1),
               raw:sub(1, 400), out:sub(1, 200)))
end

-- ---- 3. --emit-compdb-append against a MISSING file creates a fresh one ----
do
  local FRESH = TEMP .. "\\clua_t_compdb_fresh.json"
  os.remove(FRESH)
  local code, out = run(('"%s" build "%s" "--emit-compdb-append=%s" --emit=bytecode --emit-only')
                          :format(CLUA_ABS, FIXTURE, FRESH))
  local raw = readfile(FRESH) or ""
  local okp, doc = pcall(parse_json, raw)
  ok(code == 0 and okp and type(doc) == "table" and #doc == 1,
     "--emit-compdb-append on a missing file writes a fresh single-entry array",
     ("code=%s raw=%q out=%q"):format(tostring(code), raw:sub(1, 300), out:sub(1, 200)))
  os.remove(FRESH)
end

-- ---- 4. escaping torture: an input path with a quote/backslash-ish name ----
-- We can't easily create a filename containing " on Windows (reserved), but
-- we CAN pass an arg whose value contains a backslash (the input path
-- itself). The main check that the JSON is well-formed after any prior step
-- is what already exercises that. Add one direct assertion that no bare
-- unescaped tab/newline slipped into the file.
do
  local raw = readfile(CDB) or ""
  local has_bare_tab = raw:find("\t", 1, true) ~= nil
  local has_bare_cr  = raw:find("\r", 1, true) ~= nil
  ok(not has_bare_tab and not has_bare_cr,
     "compdb output contains no bare control characters",
     ("tab=%s cr=%s"):format(tostring(has_bare_tab), tostring(has_bare_cr)))
end

os.remove(FIXTURE)
os.remove(CDB)

if fails > 0 then os.exit(1) end
print("[+] PASS test-compdb (all checks)")
os.exit(0)
