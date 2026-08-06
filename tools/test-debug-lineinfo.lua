-- test-debug-lineinfo.lua -- `clua build -g` emits a .clualn debug section.
--
-- End-to-end contract:
--   * -g / --debug: the produced PE carries a section named ".clualn"
--     containing one record per compiled function (see
--     tools/decode-clualn.lua for the on-disk layout);
--   * no flag: no such section is present, so a release build stays
--     lean and byte-identical to what shipped before -g existed;
--   * the decoded records name each compiled function (luac_fn_*),
--     carry the source path, and expose (native_off, lua_line) rows
--     whose lua_line values fall inside the fixture's line range.
--
-- Skips cleanly when the toolchain has not been built, so the suite
-- runs unaltered in a source-only tree.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-debug-lineinfo (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT     = io.popen("cd"):read("*l")
local TEMP     = os.getenv("TEMP") or "."
local CLUA_ABS = ROOT .. "\\" .. CLUA

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. tostring(detail):sub(1, 400)) or ""))
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

local function filesize(p)
  local f = io.open(p, "rb")
  if not f then return 0 end
  local n = f:seek("end") or 0
  f:close()
  return n
end

-- Fixture with several distinct lines and a nested function so the decoder
-- sees more than one luac_fn_* record.
local FIXTURE    = TEMP .. "\\clua_t_dbginfo.lua"
local EXE_NODBG  = TEMP .. "\\clua_t_dbginfo_nodebug.exe"
local EXE_DBG    = TEMP .. "\\clua_t_dbginfo_debug.exe"

local SRC = table.concat({
  '-- line 1',
  'local function inner(a, b)',       -- 2
  '  local c = a + b',                 -- 3
  '  local d = c * 2',                 -- 4
  '  return d + 1',                    -- 5
  'end',                               -- 6
  '',                                  -- 7
  'local x = inner(3, 4)',             -- 8
  'local y = x + 10',                  -- 9
  'print(x, y)',                       -- 10
  'return y',                          -- 11
}, "\n") .. "\n"
writefile(FIXTURE, SRC)
local NLINES = 11

-- --------------- 1. build WITHOUT -g -> no .clualn section ---------------
do
  os.remove(EXE_NODBG)
  -- --no-cache so a prior test that populated the cache under a different
  -- --debug flag cannot serve stale entries that lack .clualn rows.
  local code, out = run(('"%s" build --no-cache "%s" -o "%s"'):format(CLUA_ABS, FIXTURE, EXE_NODBG))
  if code ~= 0 or not exists(EXE_NODBG) then
    ok(false, "release build (no -g) succeeds",
       ("code=%s out=%q"):format(tostring(code), out))
  else
    -- Reuse the decoder as a library so we don't parse PE headers twice.
    local dec = dofile("tools\\decode-clualn.lua")
    local recs, why = dec.load_records(EXE_NODBG)
    ok(recs == nil and why == "no .clualn section",
       "release build has no .clualn section",
       ("recs=%s why=%q"):format(tostring(recs), tostring(why)))
  end
end

-- --------------- 2. build WITH -g -> .clualn section present ---------------
do
  os.remove(EXE_DBG)
  local code, out = run(('"%s" build --no-cache "%s" -o "%s" -g'):format(CLUA_ABS, FIXTURE, EXE_DBG))
  if code ~= 0 or not exists(EXE_DBG) then
    ok(false, "-g build succeeds",
       ("code=%s out=%q"):format(tostring(code), out))
  else
    local dec = dofile("tools\\decode-clualn.lua")
    local recs, meta_or_err = dec.load_records(EXE_DBG)
    if not recs then
      ok(false, "-g build produces a decodable .clualn section",
         "decode error: " .. tostring(meta_or_err))
    else
      ok(#recs >= 1, "-g build has at least one function record",
         "recs=" .. tostring(#recs))
      -- Each record must have a plausible function name (luac_fn_*), a
      -- source path that ends in our fixture name, and >=1 row whose
      -- lua_line falls inside [1..NLINES].
      local any_named, any_sourced, any_row_ok = false, false, false
      for _, r in ipairs(recs) do
        if r.name:match("^luac_fn_%d+$") then any_named = true end
        if r.source:find("clua_t_dbginfo", 1, true) then any_sourced = true end
        for _, row in ipairs(r.rows) do
          if row.lua_line >= 1 and row.lua_line <= NLINES then
            any_row_ok = true
          end
        end
      end
      ok(any_named,   "at least one record is named luac_fn_<i>")
      ok(any_sourced, "at least one record carries the fixture's source path")
      ok(any_row_ok,  "at least one row has a lua_line in [1.." .. NLINES .. "]")

      -- Sanity: rows within a record are monotone non-decreasing in
      -- native_off (the producer appends in emit order, and lower_inst
      -- can only grow the buffer forward).
      local monotone = true
      for _, r in ipairs(recs) do
        local last = -1
        for _, row in ipairs(r.rows) do
          if row.native_off < last then monotone = false break end
          last = row.native_off
        end
        if not monotone then break end
      end
      ok(monotone, "rows are monotone non-decreasing in native_off")
    end
  end
end

-- --------------- 3. -g exe is at least as large as no-g exe ---------------
-- We do not pin an exact byte count (that would tie the test to a
-- particular fixture / optimization level), just that the debug section
-- actually costs disk space.
do
  local sz_no = filesize(EXE_NODBG)
  local sz_dbg = filesize(EXE_DBG)
  ok(sz_no > 0 and sz_dbg >= sz_no,
     "-g build is at least as large as a release build",
     ("no_g=%d, g=%d"):format(sz_no, sz_dbg))
  -- Report the delta so the reviewer sees the concrete cost.
  print(string.format("     (-g adds %d bytes on this fixture: %d -> %d)",
                      sz_dbg - sz_no, sz_no, sz_dbg))
end

os.remove(EXE_NODBG)
os.remove(EXE_DBG)
os.remove(FIXTURE)

if fails > 0 then os.exit(1) end
print("[+] PASS test-debug-lineinfo (all checks)")
os.exit(0)
