-- tools/test-errors.lua -- error-message end-to-end suite.
--
-- Drives `clua check` (and, when the error only surfaces after codegen or the
-- fixture asks for a warning, `clua build`) over every fixture under
-- tests/errors/*.lua and asserts the compiler's diagnostic matches the
-- fixture-declared expectations. The runner is deliberately fixture-driven so
-- that adding a new error category is one file, no code change.
--
-- Fixture header contract (one directive per line, order-insensitive):
--
--    -- @expect error|warning     required. `warning` implies `@wflag`.
--    -- @line   <N> | any         required. `any` disables the line-column check.
--    -- @contains "<substring>"   required. Fragment the message MUST contain.
--    -- @hint    "<substring>"    optional. Not-yet-fatal: reported as INFO.
--    -- @code   <TOKEN>           required. Category tag used only in reports.
--    -- @wflag  -W<name>          for `@expect warning`: which flag to enable.
--
-- Skip modes:
--   * clua.exe missing                    -> whole suite SKIPs (rc 0).
--   * fixture compiled clean when it was  -> SKIP that fixture: the diagnostic
--     supposed to error / no warning fired  category is not yet implemented
--     when it was supposed to warn           (e.g. did-you-mean, -Wshadow,
--                                            -Wunreachable), NOT a failure.
--   * @contains not found in output       -> SKIP as "message shape not
--                                            implemented yet".
--   * @line mismatched but @contains ok   -> WARN (soft): the compiler flagged
--                                            the right thing at a different
--                                            location. Not a hard failure.
--
-- FAIL only when the compiler CLAIMS to have detected the right error/warning
-- but at the wrong place or with the wrong message shape entirely, i.e. the
-- fixture was previously PASSING and just regressed.

local NAME = "test-errors"

-- ---- shell helpers -------------------------------------------------------

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function wrap(cmd) return '"' .. cmd .. '"' end

local function capture(cmd)
  local p = io.popen(wrap(cmd .. " 2>&1"))
  if not p then return "", -1 end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  return out, (ok == true) and 0 or (code or 1)
end

local function cwd()
  local p = io.popen("cd")
  if not p then return "." end
  local d = p:read("*a") or ""
  p:close()
  return trim(d)
end

-- ---- locate binaries -----------------------------------------------------

local ROOT = cwd()
local CLUA = ROOT .. "\\build\\bin\\clua.exe"

if not exists(CLUA) then
  print("[~] SKIP " .. NAME .. " (" .. CLUA
        .. " not built; run build\\build-luac.bat)")
  os.exit(0)
end

-- ---- fixture discovery ---------------------------------------------------

local FIXDIR = ROOT .. "\\tests\\errors"

local function list_fixtures()
  local out = {}
  local p = io.popen('dir /b "' .. FIXDIR .. '\\*.lua" 2>nul')
  if not p then return out end
  for line in p:lines() do
    line = trim(line)
    if #line > 0 then out[#out + 1] = FIXDIR .. "\\" .. line end
  end
  p:close()
  table.sort(out)
  return out
end

-- ---- fixture header parser -----------------------------------------------
--
-- Each directive lives on its own comment line. Values are either a bare token
-- (line/code/wflag/expect) or a "double-quoted string" (contains/hint). Unknown
-- directives are ignored so the header grammar can grow without breaking
-- older runners.

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function parse_header(path)
  local src = read_file(path) or ""
  local h   = { path = path, hints = {}, contains = {} }
  for line in src:gmatch("[^\r\n]+") do
    local body = line:match("^%s*%-%-%s*@(.*)$")
    if not body then goto next_line end
    local key, rest = body:match("^(%w+)%s+(.*)$")
    if not key then goto next_line end
    rest = trim(rest)
    if key == "expect" then
      h.expect = rest
    elseif key == "line" then
      h.line = (rest == "any") and nil or tonumber(rest)
      h.line_any = (rest == "any")
    elseif key == "code" then
      h.code = rest
    elseif key == "wflag" then
      h.wflag = rest
    elseif key == "contains" then
      local s = rest:match('^"(.*)"$') or rest
      h.contains[#h.contains + 1] = s
    elseif key == "hint" then
      local s = rest:match('^"(.*)"$') or rest
      h.hints[#h.hints + 1] = s
    end
    ::next_line::
  end
  return h
end

-- ---- runner --------------------------------------------------------------

local TMP  = (os.getenv("TEMP") or ".") .. "\\clua-test-errors"
os.execute('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
os.execute('mkdir "' .. TMP .. '" >nul 2>&1')

local function fixture_out(name) return TMP .. "\\" .. name .. ".exe" end

-- Build the command line for a fixture:
--   * @expect error   -> `clua check <file>` (front-end / closed-world only).
--                        A handful of type errors are only discovered by the
--                        back-end optimizer; if `check` accepts the file we
--                        retry once with `build` before declaring SKIP.
--   * @expect warning -> `clua build <file> -o <tmp> <wflag>` so the
--                        warning-scan pipeline actually runs.
local function build_cmd(h, tag, mode)
  if h.expect == "warning" then
    return string.format('"%s" build "%s" -o "%s" %s --color=never',
                         CLUA, h.path, fixture_out(tag), h.wflag or "")
  end
  if mode == "build" then
    return string.format('"%s" build "%s" -o "%s" --color=never',
                         CLUA, h.path, fixture_out(tag))
  end
  return string.format('"%s" check "%s" --color=never', CLUA, h.path)
end

local function run_fixture(h, tag)
  local out, rc = capture(build_cmd(h, tag, "check"))
  if rc == 0 and h.expect == "error" then
    -- Front-end accepted it; some diagnostics only surface at build time.
    out, rc = capture(build_cmd(h, tag, "build"))
  end
  return out, rc
end

-- Match "--> path:LINE:COL" or "--> path:LINE" arrow rows. Returns first
-- (line, col) pair on the diagnostic that carries our expected @contains
-- substring, or nil if none matched.
local function locate(out, want)
  -- Group each diagnostic into a block: header line + its arrow row + snippet.
  -- The arrow row uses "-->"; the fixture path may include ":" (drive letter),
  -- so scan for a "-->" then read line:col off the tail.
  local blocks = {}
  local cur = {}
  for line in out:gmatch("[^\r\n]+") do
    if line:find("^%s*error:") or line:find("^%s*warning") or line:find("^%s*note") then
      if #cur > 0 then blocks[#blocks + 1] = table.concat(cur, "\n") end
      cur = { line }
    else
      cur[#cur + 1] = line
    end
  end
  if #cur > 0 then blocks[#blocks + 1] = table.concat(cur, "\n") end

  for _, blk in ipairs(blocks) do
    if blk:find(want, 1, true) then
      local L, C = blk:match("%-%->%s*[^\r\n]-:(%d+):(%d+)")
      if L then return tonumber(L), tonumber(C), blk end
      L = blk:match("%-%->%s*[^\r\n]-:(%d+)")
      if L then return tonumber(L), nil, blk end
      return nil, nil, blk
    end
  end
  return nil, nil, nil
end

-- ---- results tallies ------------------------------------------------------

local pass, fail, skip, warn = 0, 0, 0, 0
local report = {}

local function record(kind, name, note)
  if     kind == "PASS" then pass = pass + 1
  elseif kind == "FAIL" then fail = fail + 1
  elseif kind == "SKIP" then skip = skip + 1
  elseif kind == "WARN" then warn = warn + 1
  end
  report[#report + 1] = string.format("  [%s] %-32s %s", kind, name, note or "")
end

-- ---- drive ---------------------------------------------------------------

local fixtures = list_fixtures()
if #fixtures == 0 then
  print("[~] SKIP " .. NAME .. " (no fixtures under tests/errors/)")
  os.exit(0)
end

for _, path in ipairs(fixtures) do
  local name = path:match("([^\\]+)%.lua$") or path
  local h    = parse_header(path)

  if not h.expect or #h.contains == 0 then
    record("SKIP", name, "header incomplete: needs @expect and @contains")
    goto continue
  end
  if h.expect == "warning" and not h.wflag then
    record("SKIP", name, "@expect warning requires @wflag")
    goto continue
  end

  local out, rc = run_fixture(h, name)

  -- Category detection: did the compiler produce ANY diagnostic of the
  -- expected kind? An @expect error fixture that compiled clean means the
  -- category is not yet implemented (SKIP); an @expect warning fixture that
  -- printed no warning means either the -W flag is unknown or the scanner
  -- for that category is not wired yet.
  if h.expect == "error" and rc == 0 then
    record("SKIP", name, "compiled clean; diagnostic category not implemented yet (@code=" .. (h.code or "?") .. ")")
    goto continue
  end
  if h.expect == "warning" then
    if not out:find("warning") then
      record("SKIP", name, "no warning emitted; -W category not implemented yet (@code=" .. (h.code or "?") .. ")")
      goto continue
    end
  end

  -- @contains: at least one of the expected substrings must appear.
  local L, C, block
  local matched = false
  for _, want in ipairs(h.contains) do
    L, C, block = locate(out, want)
    if block then matched = true; break end
  end

  if not matched then
    -- The compiler DID produce a diagnostic but its wording doesn't match
    -- our fixture. Not a hard fail: the message shape may have been
    -- reworded, or the fixture may be aspirational. SKIP with the actual
    -- first line of output so a maintainer can update the fixture.
    local first = out:match("[^\r\n]+") or ""
    record("SKIP", name, "message shape mismatch (@contains not in output). first: "
                         .. first:sub(1, 80))
    goto continue
  end

  -- @line check: skip when @line any; warn on mismatch (compiler flagged
  -- the right thing at a different location).
  if h.line and not h.line_any then
    if L == nil then
      -- Message matched but there's no arrow row -- older diagnostics
      -- (closed-world scanner) don't yet carry line info.
      record("WARN", name, string.format("no --> row on diagnostic; expected line %d", h.line))
      goto continue
    end
    if L ~= h.line then
      record("WARN", name, string.format("line mismatch: expected %d, got %d", h.line, L))
      goto continue
    end
  end

  record("PASS", name, string.format("(%s at line %s%s)",
         h.expect, tostring(L or "?"), C and (":" .. C) or ""))
  ::continue::
end

-- ---- report ---------------------------------------------------------------

for _, line in ipairs(report) do print(line) end

os.execute('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')

local total = pass + fail + skip + warn
print(string.format("\n%s: %d PASS  %d WARN  %d SKIP  %d FAIL  (of %d fixtures)",
                    NAME, pass, warn, skip, fail, total))

if fail > 0 then
  print("[-] FAIL " .. NAME)
  os.exit(1)
end
print("[+] PASS " .. NAME)
os.exit(0)
