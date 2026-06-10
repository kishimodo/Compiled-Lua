-- tests/packages/test_archive_traversal.lua : Zip-Slip / path-traversal
-- containment for the archive extractors (tar, zip). A crafted archive whose
-- entry name escapes the destination ("../escape.txt", absolute, drive-letter)
-- must be REFUSED, and no file may be written outside the destination dir.
-- Benign archives must still round-trip.
local tar = require "tar"
local zip = require "zip"

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_archive_traversal: " .. tostring(m)) end end

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end
local function mkdir(p) os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') end
local function rmrf(p) os.execute('rmdir /s /q "' .. p:gsub("/", "\\") .. '" 2>nul') end

local tmp  = os.getenv("TEMP") or os.getenv("TMP") or "."
local base = tmp:gsub("\\", "/") .. "/luavm_slip_" .. tostring(os.time()) .. "_" .. tostring(math.floor(os.clock() * 1e6))
mkdir(base)
local sandbox = base .. "/sandbox"
local escape_marker = base .. "/escape.txt"   -- one level above sandbox

-- ---- tar -----------------------------------------------------------------
do
  local tpath = base .. "/evil.tar"
  local w = tar.writer(tpath)
  w:add_file("good.txt", "ok")
  w:add_file("../escape.txt", "PWNED")   -- traversal entry
  w:close()
  local r = tar.open(tpath)
  local called = pcall(function() return r:extract_all(sandbox) end)
  ok(not called, "tar.extract_all refuses a '..' traversal entry")
  ok(not exists(escape_marker), "tar: no file escaped the destination via '..'")
end

do
  -- absolute / drive-letter entry must also be refused
  local tpath = base .. "/evil_abs.tar"
  local w = tar.writer(tpath)
  w:add_file("C:/luavm_slip_abs.txt", "PWNED")
  w:close()
  local r = tar.open(tpath)
  local called = pcall(function() return r:extract_all(sandbox) end)
  ok(not called, "tar.extract_all refuses an absolute/drive-letter entry")
  ok(not exists("C:/luavm_slip_abs.txt"), "tar: no absolute-path file written")
end

do
  -- benign archive must still extract correctly
  local tpath = base .. "/good.tar"
  local w = tar.writer(tpath)
  w:add_file("a.txt", "alpha")
  w:add_file("sub/b.txt", "beta")
  w:close()
  local dest = base .. "/good_tar_out"
  local r = tar.open(tpath)
  local called, err = pcall(function() return r:extract_all(dest) end)
  ok(called, "tar.extract_all extracts a benign archive (" .. tostring(err) .. ")")
  ok(exists(dest .. "/a.txt"), "tar: benign file a.txt extracted")
  ok(exists(dest .. "/sub/b.txt"), "tar: benign nested file extracted")
end

-- ---- zip -----------------------------------------------------------------
do
  local zpath = base .. "/evil.zip"
  local w = zip.writer(zpath)
  w:add_file("good.txt", "ok")
  w:add_file("../escape.txt", "PWNED")
  w:close()
  local r = zip.open(zpath)
  local called = pcall(function() return r:extract_all(sandbox) end)
  ok(not called, "zip.extract_all refuses a '..' traversal entry")
  ok(not exists(escape_marker), "zip: no file escaped the destination via '..'")
end

do
  local zpath = base .. "/good.zip"
  local w = zip.writer(zpath)
  w:add_file("a.txt", "alpha")
  w:close()
  local dest = base .. "/good_zip_out"
  local r = zip.open(zpath)
  local called, err = pcall(function() return r:extract_all(dest) end)
  ok(called, "zip.extract_all extracts a benign archive (" .. tostring(err) .. ")")
  ok(exists(dest .. "/a.txt"), "zip: benign file a.txt extracted")
end

rmrf(base)

if fails == 0 then print("[+] PASS test_archive_traversal") os.exit(0) else os.exit(1) end
