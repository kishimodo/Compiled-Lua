-- rover -- the CLua package manager (local-first, R6 + v1.x).
--
-- Run by clua-interp.exe:  clua-interp.exe -i rover/src/rover.lua <cmd> ...
--
-- Model: a single GLOBAL content store -- install once, `require` from any
-- project. The store is %CLUA_HOME%\packages, or %LOCALAPPDATA%\clua\packages.
-- compiler.exe resolves `require "<name>"` against this store at compile time
-- (so it bundles the package into the standalone exe), and clua-interp.exe -i adds
-- it to package.path so the interpreter can require it at runtime. Installing
-- the same package again is idempotent (it overwrites the same store path), so
-- a forgotten reinstall cannot corrupt state.
--
-- v1.x adds, all SERVER-FREE (no remote registry, no network):
--   * SHA-256 content integrity: each install records the package's hash.
--   * Manifests: name + version + description + hash, stored under <store>\.meta.
--   * verify <name>  -- re-hash the installed package, compare to its manifest.
--   * info   <name>  -- print the installed manifest.
--   * search <q>     -- list registry packages whose name/desc match <q>.
--   * init           -- scaffold a rover.toml dependency manifest in the cwd.
-- (A versioned store layout + per-project lockfile need the C-side resolver to
--  learn the version dimension; that is the documented next step. The layout
--  here stays <store>\<name>\init.lua so compiler/interpreter resolution is
--  unchanged.)

----------------------------------------------------------------------
-- Pure-Lua SHA-256 (the interpreter host can't `require "hash"`, so the
-- package manager is self-contained). Verified against the standard vectors
-- sha256("")  = e3b0c442...  and  sha256("abc") = ba7816bf...
----------------------------------------------------------------------
local MASK = 0xFFFFFFFF
local SHA_K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}
local function rrot(x, n) return ((x >> n) | (x << (32 - n))) & MASK end

local function sha256(message)
  local bitlen = #message * 8
  local padded = message .. "\128"
  while (#padded % 64) ~= 56 do padded = padded .. "\0" end
  local hi, lo = (bitlen >> 32) & MASK, bitlen & MASK
  padded = padded .. string.char(
    (hi >> 24) & 0xFF, (hi >> 16) & 0xFF, (hi >> 8) & 0xFF, hi & 0xFF,
    (lo >> 24) & 0xFF, (lo >> 16) & 0xFF, (lo >> 8) & 0xFF, lo & 0xFF)
  local h = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
  for chunk = 1, #padded, 64 do
    local w = {}
    for i = 0, 15 do
      local p = chunk + i * 4
      w[i] = ((padded:byte(p) << 24) | (padded:byte(p + 1) << 16) |
              (padded:byte(p + 2) << 8) | padded:byte(p + 3)) & MASK
    end
    for i = 16, 63 do
      local s0 = rrot(w[i-15], 7) ~ rrot(w[i-15], 18) ~ (w[i-15] >> 3)
      local s1 = rrot(w[i-2], 17) ~ rrot(w[i-2], 19) ~ (w[i-2] >> 10)
      w[i] = (w[i-16] + s0 + w[i-7] + s1) & MASK
    end
    local a,b,c,d,e,f,g,hh = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
    for i = 0, 63 do
      local S1  = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
      local ch  = (e & f) ~ ((~e & MASK) & g)
      local t1  = (hh + S1 + ch + SHA_K[i + 1] + w[i]) & MASK
      local S0  = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local t2  = (S0 + maj) & MASK
      hh = g; g = f; f = e; e = (d + t1) & MASK
      d = c; c = b; b = a; a = (t1 + t2) & MASK
    end
    h[1]=(h[1]+a)&MASK; h[2]=(h[2]+b)&MASK; h[3]=(h[3]+c)&MASK; h[4]=(h[4]+d)&MASK
    h[5]=(h[5]+e)&MASK; h[6]=(h[6]+f)&MASK; h[7]=(h[7]+g)&MASK; h[8]=(h[8]+hh)&MASK
  end
  local out = {}
  for i = 1, 8 do out[i] = string.format("%08x", h[i]) end
  return table.concat(out)
end

----------------------------------------------------------------------
-- Paths + shell helpers
----------------------------------------------------------------------
local function store_base()
  local home = os.getenv("CLUA_HOME")
  if not home or home == "" then
    home = (os.getenv("LOCALAPPDATA") or ".") .. "\\clua"
  end
  return home .. "\\packages"
end

-- os.execute routes through cmd.exe; wrap in an outer quote pair so a
-- leading-quoted command is not mangled.
local function sh(cmd)
  local ok, _, code = os.execute('"' .. cmd .. '"')
  return (ok == true) or (ok == 0) or (code == 0)
end
local function bs(p) return (p:gsub("/", "\\")) end   -- cmd wants backslashes
local function read_file(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local c = f:read("*a"); f:close(); return c
end
local function write_file(p, content)
  local f = io.open(p, "wb"); if not f then return false end
  f:write(content); f:close(); return true
end
local function exists(p)
  if read_file(p) then return true end
  return sh('if exist "' .. p .. '" (exit 0) else (exit 1) >nul 2>&1')
end

-- SECURITY: every path this program touches is eventually interpolated into a
-- cmd.exe command line (mkdir/move/xcopy/del/curl). A value carrying a quote,
-- `&`, `|`, `<`, `>`, `^`, `%` or a control character escapes the quoting and
-- runs arbitrary commands, so the ROOTS we build staging/lock paths from
-- ($TEMP, $CLUA_HOME/$LOCALAPPDATA) get the same allowlist treatment the
-- registry value already had. `registry_ok` below is this same predicate.
local function shell_safe_path(p)
  if type(p) ~= "string" or p == "" then return false end
  return not p:find('[%c"&|<>%^%%`]')
end

----------------------------------------------------------------------
-- SECURITY: package-name allowlist.
--
-- Every package name eventually becomes part of a shell command string passed
-- to io.popen/os.execute (e.g. `dir /b /ad "<store>\<name>"`). A name is
-- attacker-controlled: it comes from the CLI, from rover.toml/rover.lock, and
-- -- critically -- from a remote registry's index.json. A name containing a
-- quote/`&`/`|`/etc. breaks out of the quoting and runs arbitrary commands, so
-- a single compromised registry would mean local code execution.
--
-- Defence: a strict allowlist applied at the entry of EVERY command and again
-- at every internal boundary that consumes a name from data (the remote index,
-- the lock, the store listing). Allowed: ASCII letters/digits and `. _ -`.
-- Rejected: anything else, in particular path separators, `..`, quotes, spaces,
-- NUL, and shell metacharacters. A name must be 1..128 chars and may not start
-- with `.` or `-` (no `..`, no dotfiles, no option-injection). This is the only
-- gate -- there is no escaping/quoting fallback, because correct cross-shell
-- quoting on cmd.exe is not reliably achievable.
----------------------------------------------------------------------
local NAME_PATTERN = "^[%w_%.%-]+$"
local function name_ok(name)
  if type(name) ~= "string" then return false end
  if #name == 0 or #name > 128 then return false end
  if not name:match(NAME_PATTERN) then return false end
  if name:sub(1, 1) == "." or name:sub(1, 1) == "-" then return false end
  if name:find("%.%.") then return false end          -- no ".." traversal
  return true
end

-- Validate a name or abort the whole program with a clear, uniform error. Used
-- at command entry: the user gets one message and NO shell command runs.
local function require_valid_name(name, where)
  if name_ok(name) then return name end
  io.stderr:write(string.format(
    "[-] invalid package name %s%s: names must match %s "
    .. "(letters, digits, '.', '_', '-'; no path separators, '..', quotes, "
    .. "spaces or shell metacharacters)\n",
    (name == nil and "(nil)" or string.format("%q", tostring(name))),
    where and (" in " .. where) or "", NAME_PATTERN))
  os.exit(2)
end

-- Filter a name sourced from data (remote index, store listing, lock). Returns
-- the name if safe, else nil -- the caller skips it rather than aborting, so one
-- poisoned registry entry can't take down a whole `search`/`list`.
local function safe_name(name)
  return name_ok(name) and name or nil
end

-- A version string also becomes a path/URL segment (<store>\<name>\<version>,
-- <url>/<name>/<version>/init.lua) sourced from a remote index, so it gets the
-- same allowlist treatment: digits, dots, and the prerelease/build chars
-- `- + _`. No separators, no `..`, no shell metacharacters.
local function version_ok(v)
  if type(v) ~= "string" then return false end
  if #v == 0 or #v > 64 then return false end
  if not v:match("^[%w_%.%+%-]+$") then return false end
  if v:sub(1, 1) == "." or v:sub(1, 1) == "-" then return false end
  if v:find("%.%.") then return false end
  return true
end

local STORE = store_base()
local META  = STORE .. "\\.meta"   -- manifests live here, OUTSIDE package dirs

----------------------------------------------------------------------
-- Closed-world literal-table parser (no load()).
--
-- aotc.exe compiles this program closed-world: the global `load` is a compile
-- error. Every file this program previously load()ed -- package.lua manifests,
-- .meta/<name>.lua manifests, rover.lock -- is a machine-written (or
-- registry-provided) LITERAL `return { ... }` table serialized with
-- string.format("%q"), so a tiny recursive-descent parser covers them exactly:
--   return { [ ["key"] | ident = ] "str" | 'str' | number | true | false
--             | { ...nested... } , ... }
-- with Lua line comments (`--` to end of line), arbitrary whitespace, and
-- trailing commas tolerated. %q escape forms are decoded: \" \' \\ \n \r \t
-- \<literal newline> and decimal \ddd. Anything else (computed expressions,
-- function calls, identifiers as values, unbalanced braces, trailing garbage)
-- returns nil -- it never raises -- so each caller keeps its existing
-- corrupt/fallback semantics.
----------------------------------------------------------------------
local function parse_return_table(text)
  if type(text) ~= "string" then return nil end
  local pos, n = 1, #text
  local function skip_ws()                          -- whitespace + line comments
    while pos <= n do
      local c = text:sub(pos, pos)
      if c == " " or c == "\t" or c == "\r" or c == "\n" then pos = pos + 1
      elseif c == "-" and text:sub(pos + 1, pos + 1) == "-" then
        local nl = text:find("\n", pos + 2, true)
        pos = nl and (nl + 1) or (n + 1)
      else return end
    end
  end
  local ESC = { n = "\n", r = "\r", t = "\t", a = "\a", b = "\b", f = "\f",
                v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }
  local function parse_string()                     -- cursor on the open quote
    local q = text:sub(pos, pos)
    pos = pos + 1
    local out = {}
    while pos <= n do
      local c = text:sub(pos, pos)
      if c == q then pos = pos + 1; return table.concat(out) end
      if c == "\n" then return nil end              -- unescaped newline
      if c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        local digits = text:match("^%d%d?%d?", pos + 1)
        if ESC[e] then out[#out + 1] = ESC[e]; pos = pos + 2
        elseif digits then                          -- decimal \ddd (%q output)
          local byte = tonumber(digits)
          if byte > 255 then return nil end
          out[#out + 1] = string.char(byte); pos = pos + 1 + #digits
        else return nil end                         -- unknown escape
      else out[#out + 1] = c; pos = pos + 1 end
    end
    return nil                                      -- unterminated string
  end
  local parse_table                                 -- forward (tables nest)
  local function parse_value(depth)                 -- -> ok, value
    skip_ws()
    local c = text:sub(pos, pos)
    if c == '"' or c == "'" then
      local s = parse_string()
      if s == nil then return false end
      return true, s
    end
    if c == "{" then
      local t = parse_table(depth + 1)
      if t == nil then return false end
      return true, t
    end
    local word = text:match("^[%a_][%w_]*", pos)
    if word == "true"  then pos = pos + 4; return true, true  end
    if word == "false" then pos = pos + 5; return true, false end
    if word then return false end                   -- identifier = not a literal
    local num = text:match("^%-?%d+%.?%d*", pos)
    if num then
      local exp = text:match("^[eE][%+%-]?%d+", pos + #num) or ""
      local v = tonumber(num .. exp)
      if v == nil then return false end
      pos = pos + #num + #exp
      return true, v
    end
    return false
  end
  parse_table = function(depth)                     -- cursor on '{'
    if depth > 16 then return nil end               -- runaway nesting
    pos = pos + 1
    local t, arr = {}, 0
    while true do
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "" then return nil end                -- EOF inside a table
      if c == "}" then pos = pos + 1; return t end
      local key
      if c == "[" then                              -- ["string"] = value
        pos = pos + 1; skip_ws()
        local qc = text:sub(pos, pos)
        if qc ~= '"' and qc ~= "'" then return nil end
        key = parse_string()
        if key == nil then return nil end
        skip_ws(); if text:sub(pos, pos) ~= "]" then return nil end
        pos = pos + 1
        skip_ws(); if text:sub(pos, pos) ~= "=" then return nil end
        pos = pos + 1
      else
        local ident = text:match("^[%a_][%w_]*", pos)
        if ident and ident ~= "true" and ident ~= "false" and ident ~= "nil" then
          local save = pos
          pos = pos + #ident; skip_ws()
          if text:sub(pos, pos) == "=" and text:sub(pos + 1, pos + 1) ~= "=" then
            key = ident; pos = pos + 1               -- ident = value
          else
            pos = save        -- bare identifier value -> parse_value rejects it
          end
        end
      end
      local ok, v = parse_value(depth)
      if not ok then return nil end
      if key ~= nil then t[key] = v else arr = arr + 1; t[arr] = v end
      skip_ws()
      local sep = text:sub(pos, pos)
      if sep == "," or sep == ";" then pos = pos + 1
      elseif sep ~= "}" then return nil end
    end
  end
  skip_ws()
  if not (text:match("^return[^%w_]", pos) or text:match("^return$", pos)) then return nil end
  pos = pos + 6
  skip_ws()
  if text:sub(pos, pos) ~= "{" then return nil end
  local t = parse_table(1)
  if t == nil then return nil end
  skip_ws()
  if pos <= n then return nil end                   -- trailing garbage
  return t
end

----------------------------------------------------------------------
-- TRANSACTIONS: private staging, atomic publication, cross-process locks.
--
-- Rover is a MULTI-PROCESS program: several `rover install` runs (a CI matrix,
-- a watch loop, two shells) can hit one global store simultaneously. The rules
-- enforced from here on:
--
--   * every operation stages its work in a PRIVATE, uniquely named directory --
--     never a predictable %TEMP%\rover-fetch\<name>\<version> that two
--     processes delete out from under each other;
--   * a FILE is published by writing a unique sibling temp file, flushing and
--     closing it, reading the bytes back, and then replacing the destination
--     with one `move /Y`. If any step fails the destination keeps its OLD
--     contents and the temp is removed;
--   * a DIRECTORY is published by renaming a fully staged tree into place, so a
--     reader never walks a half-copied package;
--   * mutations of one package's store entry (its version dirs, the flat
--     compatibility view, and its .meta manifest) happen under a cross-process
--     lock with a BOUNDED wait and owner diagnostics.
--
-- Primitive notes -- rover must also run under the reference interpreter, so
-- there is no FFI here and everything is built from cmd.exe:
--   * `mkdir` is the atomic test-and-set (errorlevel 1 when the directory
--     already exists), which is what makes the lock a real mutual exclusion;
--   * `move /Y` is MoveFileEx with MOVEFILE_REPLACE_EXISTING -- an atomic
--     rename WITHIN one volume, which is why publish staging lives under the
--     store (%TEMP% is frequently a different volume, where a move degrades
--     into a non-atomic copy).
-- LIMIT: Lua's io can flush to the OS but cannot force the disk cache, so
-- publication is atomic and correctly ordered but not power-loss durable;
-- that needs a FlushFileBuffers primitive the host does not expose.
----------------------------------------------------------------------
local STAGE_TEMP  = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\rover-staging"
local STAGE_STORE = STORE .. "\\.staging"   -- publish scratch, on the store volume
local LOCK_ROOT   = STORE .. "\\.locks"
local STAGE_MAX_AGE = 24 * 3600             -- abandoned staging is swept after a day
-- Bounded waits. A wait NEVER becomes infinite: after ROVER_LOCK_TIMEOUT the
-- acquire fails with the owner's identity. ROVER_LOCK_STALE is how old an owner
-- record may get before the lock is treated as abandoned (a crashed rover).
local LOCK_WAIT_S  = tonumber(os.getenv("ROVER_LOCK_TIMEOUT") or "") or 60
local LOCK_STALE_S = tonumber(os.getenv("ROVER_LOCK_STALE") or "") or 600

local rand_seeded = false
local function token(n)
  if not rand_seeded then math.randomseed(); rand_seeded = true end
  local A, out = "0123456789abcdefghijklmnopqrstuvwxyz", {}
  for i = 1, (n or 12) do local k = math.random(1, #A); out[i] = A:sub(k, k) end
  return table.concat(out)
end
local PROC_ID = token(16)                   -- this process's identity in lock records

local function ensure_dir(d)
  if not shell_safe_path(d) then return false end
  if exists(d) then return true end
  sh('mkdir "' .. d .. '" >nul 2>&1')
  return exists(d)
end

local function rm_rf(p)
  if not shell_safe_path(p) then return false end
  sh('if exist "' .. p .. '" rmdir /S /Q "' .. p .. '" >nul 2>&1')
  sh('if exist "' .. p .. '" del /F /Q "' .. p .. '" >nul 2>&1')
  return not exists(p)
end

-- Create a directory nobody else can be using. `mkdir` fails when the name is
-- taken, so the winner of a name collision is decided by the filesystem.
local function unique_dir(parent, prefix)
  if not ensure_dir(parent) then return nil, "cannot create directory " .. tostring(parent) end
  for _ = 1, 64 do
    local d = parent .. "\\" .. prefix .. "-" .. token(12)
    if sh('mkdir "' .. d .. '" >nul 2>&1') then return d end
  end
  return nil, "could not create a unique staging directory under " .. parent
end

-- Best-effort recovery of staging abandoned by a crashed rover. A directory is
-- only removed when it carries a `stamp` older than a day: a brand-new staging
-- dir has no stamp yet (it is written immediately after the mkdir), so this can
-- never delete another process's LIVE work.
local function sweep_staging(root)
  if not exists(root) then return end
  local p = io.popen('dir /b /ad "' .. root .. '" 2>nul')
  if not p then return end
  local seen = {}
  for line in p:lines() do
    if line ~= "" and line:match("^[%w_%.%-]+$") then seen[#seen + 1] = line end
  end
  p:close()
  local now = os.time()
  for _, d in ipairs(seen) do
    local full = root .. "\\" .. d
    local stamp = tonumber(((read_file(full .. "\\stamp") or ""):match("%d+")) or "")
    if stamp and (now - stamp) > STAGE_MAX_AGE then rm_rf(full) end
  end
end

local function open_staging(root, prefix)
  sweep_staging(root)
  local d, err = unique_dir(root, prefix)
  if not d then return nil, err end
  write_file(d .. "\\stamp", tostring(os.time()) .. "\n")
  return d
end
local function close_staging(d) if d then rm_rf(d) end end

-- Publish `content` at `path`: unique sibling temp -> write -> flush -> close ->
-- read back -> ONE atomic replace. On any failure the destination is left
-- exactly as it was and the temp is removed. `tmpdir` overrides where the temp
-- lives (it MUST be on the destination's volume, or `move` becomes a copy);
-- pass it when a temp file must not be momentarily visible inside a directory
-- that other commands hash or enumerate.
local function write_atomic(path, content, tmpdir)
  if not shell_safe_path(path) then
    return false, "refusing to write a path with shell metacharacters: " .. tostring(path)
  end
  local dir  = path:match("^(.*)\\[^\\]+$")
  local base = path:match("([^\\]+)$") or "rover.out"
  if dir and not ensure_dir(dir) then return false, "cannot create directory " .. dir end
  local stage = tmpdir or dir or "."
  if not ensure_dir(stage) then return false, "cannot create directory " .. stage end
  local tmp
  for _ = 1, 32 do
    local cand = stage .. "\\.rover-tmp-" .. token(12) .. "-" .. base
    if not exists(cand) then tmp = cand; break end
  end
  if not tmp then return false, "could not name a temporary file for " .. path end
  local f = io.open(tmp, "wb")
  if not f then return false, "cannot create the temporary file " .. tmp end
  local ok = f:write(content)
  if ok then ok = f:flush() end
  f:close()
  -- Read back BEFORE replacing: a short write (disk full, quota) must not be
  -- allowed to destroy a good destination file.
  if not ok or read_file(tmp) ~= content then
    os.remove(tmp)
    return false, "failed to write a complete temporary file for " .. path ..
                  " (the previous file is intact)"
  end
  if not sh('move /Y "' .. tmp .. '" "' .. path .. '" >nul 2>&1') then
    os.remove(tmp)
    return false, "atomic replace of " .. path .. " failed (the previous file is intact)"
  end
  return true
end

-- Sleep roughly a second. cmd has no sleep; a loopback `ping` is the portable
-- stand-in. Falls back to a coarse os.time() spin so a bounded wait can never
-- turn into an unbounded busy loop against a missing ping.exe.
local function nap()
  if sh('ping -n 2 127.0.0.1 >nul 2>&1') then return end
  local t0 = os.time()
  repeat until os.time() > t0
end

local function lock_path(name) return LOCK_ROOT .. "\\" .. name .. ".lock" end

local function lock_owner(dir)
  local t = parse_return_table(read_file(dir .. "\\owner.lua") or "")
  return (type(t) == "table") and t or nil
end

local function describe_owner(dir, o)
  if not o then return "lock " .. dir .. " has no readable owner record" end
  return string.format("lock %s is held by process %s on %s since epoch %s, doing: %s",
    dir, tostring(o.proc), tostring(o.host), tostring(o.at), tostring(o.op))
end

-- Acquire the cross-process lock guarding <store>\<name>: its version dirs, its
-- flat compatibility view, and .meta\<name>.lua. Waits at most LOCK_WAIT_S and
-- then FAILS with the owner's identity -- it never waits forever. A lock whose
-- owner record is older than LOCK_STALE_S, or that stays ownerless for 5s (the
-- holder died between the mkdir and the owner write), is broken by RENAMING it
-- aside -- an atomic claim exactly one waiter can win, so two waiters cannot
-- both decide they broke it.
local function acquire_pkg_lock(name, op)
  if not name_ok(name) then return nil, "invalid package name" end
  if not shell_safe_path(STORE) then
    return nil, "package store path contains shell metacharacters: " .. STORE
  end
  if not ensure_dir(LOCK_ROOT) then
    return nil, "cannot create the lock directory " .. LOCK_ROOT
  end
  local dir = lock_path(name)
  local deadline, breaks, unknown_since = os.time() + LOCK_WAIT_S, 0, nil
  while true do
    if sh('mkdir "' .. dir .. '" >nul 2>&1') then
      local owner_ok, owner_err = write_atomic(dir .. "\\owner.lua", string.format(
        "return { proc = %q, host = %q, at = %d, op = %q }\n",
        PROC_ID, os.getenv("COMPUTERNAME") or "?", os.time(), op or "?"))
      if not owner_ok then
        rm_rf(dir)
        return nil, "claimed package lock but could not publish its owner: " ..
                    tostring(owner_err)
      end
      return { dir = dir, name = name }
    end
    local o, now = lock_owner(dir), os.time()
    local stale
    if o and type(o.at) == "number" then
      unknown_since = nil
      stale = (now - o.at) > LOCK_STALE_S
    else
      unknown_since = unknown_since or now
      stale = (now - unknown_since) >= 5
    end
    if stale and breaks < 3 then
      breaks, unknown_since = breaks + 1, nil
      local aside = STAGE_STORE .. "\\stale-" .. token(12)
      if ensure_dir(STAGE_STORE) and sh('move /Y "' .. dir .. '" "' .. aside .. '" >nul 2>&1') then
        rm_rf(aside)
      end
    elseif now >= deadline then
      return nil, string.format(
        "timed out after %ds waiting for the '%s' package lock -- %s",
        LOCK_WAIT_S, name, describe_owner(dir, o))
    else
      nap()
    end
  end
end

local function release_pkg_lock(lk)
  if not lk then return end
  local o = lock_owner(lk.dir)
  -- Only drop a lock whose readable record still names us. If ours was broken
  -- as stale and re-taken, there is a short mkdir->owner publication window;
  -- treating a missing record as ours would delete the new holder's mutex.
  if o and o.proc == PROC_ID then rm_rf(lk.dir) end
end

----------------------------------------------------------------------
-- FOLLOW-UP (deliberately NOT in this change): the global store is still
-- shared mutable state ACROSS projects. `remove` deletes a package's whole
-- store directory and `gc` only protects the current project's rover.lock, so
-- another project's pinned version can still be dropped. The fix is a durable
-- global lease/reference database (or a content-addressed store plus per-project
-- links), which is a store-layout change and needs its own slice. The locks
-- added here make each individual mutation safe; they do not make deletion
-- reference-counted.
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Metadata: a package's content hash + declared version/description.
----------------------------------------------------------------------
-- Hash the package's entry point (init.lua). Deterministic content integrity.
-- Kept for backward compatibility (legacy manifests stored only this).
local function pkg_hash(dir)
  local init = read_file(dir .. "\\init.lua")
  if not init then return nil end
  return sha256(init)
end

----------------------------------------------------------------------
-- Whole-tree integrity (Merkle-style root). Hashing only init.lua lets a
-- swapped helper.lua in a multi-file package still verify and ship. Instead we
-- hash EVERY file: list relative paths, sort them, and fold
--   sha256( "<relpath>\n" .. sha256(filebytes) .. "\n" )
-- for each into a single root hash. Sorting makes it deterministic regardless of
-- filesystem order; including the path defends against file renames/moves.
----------------------------------------------------------------------
-- List file paths (recursive) under `dir` as store-relative paths using
-- backslashes. Uses `dir /b /s /a-d` (full paths, files only). The version dir
-- contains no metadata files, so everything under it belongs to the package.
local function list_files(dir)
  local files = {}
  -- `dir /s` prints absolute paths even when its input is relative. Canonicalize
  -- the prefix in a child cmd first so the default `rover\registry` and paths
  -- containing `.`/`..` do not silently produce an empty file list.
  local ch = io.popen('cd /d "' .. dir .. '" 2>nul && cd')
  if not ch then return files end
  local canonical = ch:read("*l")
  ch:close()
  if not canonical or canonical == "" then return files end
  local p = io.popen('dir /b /s /a-d "' .. dir .. '" 2>nul')
  if not p then return files end
  local prefix = canonical
  if prefix:sub(-1) ~= "\\" then prefix = prefix .. "\\" end
  local plen = #prefix
  for line in p:lines() do
    if line ~= "" then
      local full = line
      -- normalize: dir prints absolute paths; strip the dir prefix (case-insens).
      if full:sub(1, plen):lower() == prefix:lower() then
        files[#files + 1] = full:sub(plen + 1)
      end
    end
  end
  p:close()
  return files
end

-- Is `seg` -- the FIRST path segment of a path relative to <store>\<name> -- a
-- version directory? The flat compatibility view nests its version dirs
-- (<store>/<name>/<version>/...), so tree_hash and the flat publisher must skip
-- exactly the same set: one predicate, used by both.
local function is_version_segment(seg)
  return seg ~= nil and seg:match("^v?%d+%.%d+") ~= nil
end

-- Merkle-style root hash over all files in `dir`. Returns the hex root, or nil
-- if the dir is empty/unreadable. Relative paths are lowercased ONLY for sorting
-- stability of the manifest order, but hashed as-is (verbatim) so a real rename
-- still changes the root.
local function tree_hash(dir, exclude_version_dirs)
  local files = {}
  for _, rel in ipairs(list_files(dir)) do
    -- A flat store dir (<store>/<name>) NESTS its version dirs
    -- (<store>/<name>/<version>/...). Skip any path whose first segment is a
    -- version, so tree_hash(flat) == tree_hash(versioned) (the same top-level
    -- files) -- the flat install is a copy of the latest version's files.
    -- (parse_semver is defined later; use a self-contained version-segment test)
    if not exclude_version_dirs
       or not is_version_segment(rel:match("^([^\\]+)\\")) then
      files[#files + 1] = rel
    end
  end
  if #files == 0 then return nil end
  table.sort(files, function(a, b) return a:lower() < b:lower() end)
  local acc = {}
  for _, rel in ipairs(files) do
    local bytes = read_file(dir .. "\\" .. rel)
    if not bytes then return nil end
    -- normalize the recorded path separator to '/' so the root is portable.
    local reln = rel:gsub("\\", "/")
    acc[#acc + 1] = sha256(reln .. "\n" .. sha256(bytes) .. "\n")
  end
  return sha256(table.concat(acc, ""))
end

-- Extract version/description without executing the package: prefer a
-- `package.lua` manifest (returns a table), else scrape `M.version = "..."`
-- and a leading `-- ` comment from init.lua.
local function read_meta(dir)
  local meta = { version = "0.0.0", description = "" }
  local pkgmanifest = read_file(dir .. "\\package.lua")
  if pkgmanifest then
    local t = parse_return_table(pkgmanifest)
    if type(t) == "table" then
      if t.version then meta.version = tostring(t.version) end
      if t.description then meta.description = tostring(t.description) end
      return meta
    end
  end
  local init = read_file(dir .. "\\init.lua")
  if init then
    local v = init:match("version%s*=%s*[\"']([^\"']+)[\"']")
    if v then meta.version = v end
    local d = init:match("^%-%-%s*[%w_]+%s*%-%-%s*([^\n]+)")  -- "-- name -- desc"
    if d then meta.description = d:gsub("%s+$", "") end
  end
  return meta
end

-- Parse a package's declared `dependencies` (name -> version range) from its
-- package.lua, WITHOUT executing init.lua. Returns a (possibly empty) table.
-- Only well-formed string keys/values that pass the name allowlist are kept, so
-- a hostile package.lua cannot inject a bad name into later shell commands.
local function read_pkg_deps(dir)
  local out = {}
  local src = read_file(dir .. "\\package.lua")
  if not src then return out end
  local t = parse_return_table(src)
  if not (type(t) == "table" and type(t.dependencies) == "table") then return out end
  for k, v in pairs(t.dependencies) do
    if name_ok(k) and type(v) == "string" then out[k] = v end
  end
  return out
end

local function manifest_path(name) return META .. "\\" .. name .. ".lua" end

-- Publish a manifest atomically: a failed write leaves the PREVIOUS manifest
-- intact rather than truncating it, so a crashed/failed install can never
-- downgrade an installed package to "unknown". Returns ok, err.
local function write_manifest(name, m)
  -- `source` is only present for FOREIGN packages (installed straight from a
  -- GitHub repo, not from a registry); its presence is what marks them.
  local source = (m.source and m.source ~= "")
                 and string.format("  source = %q,\n", m.source) or ""
  return write_atomic(manifest_path(name), string.format(
    "return {\n  name = %q,\n  version = %q,\n  description = %q,\n  hash = %q,\n  tree = %q,\n%s}\n",
    name, m.version, m.description, m.hash, m.tree or "", source))
end

local function read_manifest(name)
  local c = read_file(manifest_path(name))
  if not c then return nil end
  local t = parse_return_table(c)
  if type(t) == "table" then return t end
  return nil
end

----------------------------------------------------------------------
-- Per-project manifest (rover.toml) + lockfile (rover.lock).
-- Minimal, self-contained (no toml package -- the interpreter host can't
-- require it). Only the [dependencies] table is read; values are version
-- constraints (currently informational: the local registry is single-version).
----------------------------------------------------------------------
local TOML = "rover.toml"
local LOCK = "rover.lock"

-- Parse the [dependencies] section of a rover.toml into { name = constraint }.
local function read_toml_deps(path)
  local text = read_file(path)
  if not text then return nil end
  local deps, section = {}, nil
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local s = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" then
      local sec = s:match("^%[(.-)%]$")
      if sec then section = sec
      elseif section == "dependencies" then
        local k, v = s:match('^([%w_%-%.]+)%s*=%s*"?([^"]*)"?$')
        if k then deps[k] = (v == "" and "*" or v) end
      end
    end
  end
  return deps
end

-- Append a dependency to rover.toml's [dependencies] (creating the file/section).
-- Published atomically: a failed rewrite must not leave a truncated manifest
-- behind. Returns ok, err.
local function add_toml_dep(name, constraint)
  local text = read_file(TOML)
  if not text then
    return write_atomic(TOML, table.concat({
      "[project]", 'name = "my-project"', 'version = "0.1.0"', "",
      "[dependencies]", string.format('%s = "%s"', name, constraint), "",
    }, "\n"))
  end
  -- already present? rewrite its line. else append under [dependencies].
  if text:match("\n%s*" .. name:gsub("%-", "%%-") .. "%s*=") then
    text = text:gsub("(\n%s*" .. name:gsub("%-", "%%-") .. "%s*=)[^\n]*",
                     "%1 \"" .. constraint .. "\"")
  elseif text:match("%[dependencies%]") then
    text = text:gsub("(%[dependencies%][^\n]*\n)",
                     "%1" .. string.format('%s = "%s"\n', name, constraint))
  else
    text = text .. "\n[dependencies]\n" .. string.format('%s = "%s"\n', name, constraint)
  end
  return write_atomic(TOML, text)
end

-- Lockfile: resolved name -> { version, hash, tree, deps }. `hash` is the legacy
-- init.lua hash (compat), `tree` is the whole-tree Merkle root (Feature 3), and
-- `deps` is the package's direct dependency graph (Feature 4). Written as a Lua
-- literal return-table; read back with parse_return_table (closed-world: no load()).
-- Published atomically (temp sibling + replace): an interrupted or failed write
-- must leave the PREVIOUS pins in place, never a half-written lock that would
-- read as "corrupt" and block the next install. Returns ok, err.
local function write_lock(locked)
  local lines = { "-- rover.lock -- resolved dependency versions + content hashes.",
                  "-- Generated by rover; do not edit by hand.", "return {" }
  local names = {}
  for n in pairs(locked) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    local e = locked[n]
    local parts = { string.format("version = %q, hash = %q", e.version, e.hash) }
    if e.tree and e.tree ~= "" then parts[#parts + 1] = string.format("tree = %q", e.tree) end
    -- FOREIGN entries record where they came from (github.com/<owner>/<repo>)
    if e.source and e.source ~= "" then parts[#parts + 1] = string.format("source = %q", e.source) end
    -- emit the package's direct deps (sorted) so the graph is recorded + stable
    if type(e.deps) == "table" then
      local dn = {}
      for d in pairs(e.deps) do dn[#dn + 1] = d end
      table.sort(dn)
      if #dn > 0 then
        local ds = {}
        for _, d in ipairs(dn) do ds[#ds + 1] = string.format("[%q] = %q", d, e.deps[d]) end
        parts[#parts + 1] = "deps = { " .. table.concat(ds, ", ") .. " }"
      end
    end
    lines[#lines + 1] = string.format("  [%q] = { %s },", n, table.concat(parts, ", "))
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  return write_atomic(LOCK, table.concat(lines, "\n"))
end

-- Returns (table) when the lock loads, nil when ABSENT, or (nil,"corrupt") when
-- the file exists but does not parse. The caller must distinguish the last case:
-- a corrupt lock that is treated as "absent" silently re-resolves and clobbers
-- the pins, breaking the reproducibility guarantee (and any tamper signal).
local function read_lock()
  local c = read_file(LOCK)
  if not c then return nil end                     -- absent
  local t = parse_return_table(c)
  if type(t) ~= "table" then return nil, "corrupt" end  -- present but unparseable
  for name, entry in pairs(t) do
    if not name_ok(name) or type(entry) ~= "table"
       or not version_ok(entry.version) then
      return nil, "corrupt"
    end
  end
  return t
end

----------------------------------------------------------------------
-- Minimal semver (constraint resolution at install time -- the host can't
-- `require "semver"`). Supports exact, "*"/"", "^" (caret), "~" (tilde),
-- ">=", "<=", ">", "<", and prerelease tags (1.0.0-beta.1).
----------------------------------------------------------------------
-- Returns { major, minor, patch, pre } where `pre` is the prerelease string
-- (e.g. "beta.1") or nil. A build-metadata suffix (+build) is ignored per semver.
-- The returned table also carries `.n` = the count of core components the user
-- actually wrote (1 for "1", 2 for "1.2", 3 for "1.2.3"), which range operators
-- like '~' need to distinguish "~1" (>=1.0.0 <2.0.0) from "~1.0" (>=1.0.0 <1.1.0).
local function parse_semver(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%+.*$", "")                                  -- drop build metadata
  local maj, min, pat, pre = s:match("^v?(%d+)%.(%d+)%.(%d+)%-([%w%.%-]+)$")
  if maj then local t = { tonumber(maj), tonumber(min), tonumber(pat), pre }; t.n = 3; return t end
  maj, min, pat = s:match("^v?(%d+)%.(%d+)%.(%d+)$")
  if maj then local t = { tonumber(maj), tonumber(min), tonumber(pat) }; t.n = 3; return t end
  maj, min = s:match("^v?(%d+)%.(%d+)$")
  if maj then local t = { tonumber(maj), tonumber(min), 0 }; t.n = 2; return t end
  maj = s:match("^v?(%d+)$")
  if maj then local t = { tonumber(maj), 0, 0 }; t.n = 1; return t end
  return nil
end

-- Compare two prerelease strings per semver rules: split on '.', numeric ids
-- compare numerically and rank below alphanumeric ids; a longer list of equal
-- prefix is greater. Returns -1/0/1.
local function pre_cmp(a, b)
  if a == b then return 0 end
  local function split(p) local t = {}; for x in (p .. "."):gmatch("(.-)%.") do t[#t + 1] = x end; return t end
  local ta, tb = split(a), split(b)
  for i = 1, math.max(#ta, #tb) do
    local x, y = ta[i], tb[i]
    if x == nil then return -1 end        -- a is a prefix of b -> a < b
    if y == nil then return 1 end
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
      if nx ~= ny then return nx < ny and -1 or 1 end
    elseif nx and not ny then return -1   -- numeric < alphanumeric
    elseif ny and not nx then return 1
    elseif x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

local function semver_cmp(a, b)
  for i = 1, 3 do if a[i] < b[i] then return -1 elseif a[i] > b[i] then return 1 end end
  -- equal core: a version WITH a prerelease has LOWER precedence than without.
  if a[4] and not b[4] then return -1 end
  if b[4] and not a[4] then return 1 end
  if a[4] and b[4] then return pre_cmp(a[4], b[4]) end
  return 0
end

-- Caret range bound per node-semver: ^MAJOR.MINOR.PATCH allows changes that do
-- not modify the left-most NON-ZERO element. So ^1.2.3 -> <2.0.0, ^0.2.3 ->
-- <0.3.0, ^0.0.3 -> <0.0.4.
local function caret_satisfies(v, c)
  if semver_cmp(v, c) < 0 then return false end
  if c[1] > 0 then return v[1] == c[1]
  elseif c[2] > 0 then return v[1] == 0 and v[2] == c[2]
  else                return v[1] == 0 and v[2] == 0 and v[3] == c[3]
  end
end

-- Tilde range: ~MAJOR (one component written) := >=MAJOR.0.0 <(MAJOR+1).0.0;
-- ~MAJOR.MINOR or ~MAJOR.MINOR.PATCH := >=c <MAJOR.(MINOR+1).0. The old code
-- always required v[2]==c[2], so "~1" (parsed as 1.0.0) wrongly excluded 1.1.0.
local function tilde_satisfies(v, c)
  if semver_cmp(v, c) < 0 then return false end
  if c.n and c.n <= 1 then return v[1] == c[1] end          -- ~1
  return v[1] == c[1] and v[2] == c[2]                       -- ~1.2 / ~1.2.3
end

-- X-range / partial: "1", "1.2", "1.x", "1.2.*", "x". A wildcard or omitted
-- component matches anything at that level. X-ranges never match prereleases.
local function xrange_match(v, rest)
  if v[4] ~= nil then return false end
  local parts = {}
  for p in (rest .. "."):gmatch("(.-)%.") do parts[#parts + 1] = p end
  local function isx(p) return p == nil or p == "" or p == "x" or p == "X" or p == "*" end
  if isx(parts[1]) then return true end
  local maj = tonumber(parts[1]); if not maj then error("rover: bad version constraint '" .. rest .. "'") end
  if v[1] ~= maj then return false end
  if isx(parts[2]) then return true end
  local min = tonumber(parts[2]); if not min then error("rover: bad version constraint '" .. rest .. "'") end
  if v[2] ~= min then return false end
  if isx(parts[3]) then return true end
  local pat = tonumber(parts[3]); if not pat then error("rover: bad version constraint '" .. rest .. "'") end
  return v[3] == pat
end

-- Match a single comparator (no surrounding whitespace) against version table v.
-- Raises on a comparator it cannot parse, so a typo is loud rather than silently
-- unsatisfiable.
local function match_comparator(v, comp)
  if comp == "" or comp == "*" or comp == "x" or comp == "X" or comp == "latest" then
    return v[4] == nil
  end
  local op, rest = comp:match("^([%^~>=<]*)(.+)$")
  rest = rest or comp
  local _, ndots = rest:gsub("%.", "")
  local has_wild = rest:match("[xX%*]") ~= nil
  -- An operator-less partial/wildcard ("1", "1.2", "1.x", "1.2.*") is an x-range.
  if (op == "" or op == "=") and (has_wild or ndots < 2) then
    return xrange_match(v, rest)
  end
  local c = parse_semver(rest)
  if not c then error("rover: unsupported version constraint '" .. comp .. "'") end
  -- Prerelease versions only satisfy a comparator that names a prerelease on the
  -- same major.minor.patch tuple (node-semver semantics).
  if v[4] and not c[4] then
    if not (v[1] == c[1] and v[2] == c[2] and v[3] == c[3]) then return false end
  end
  if op == "^"  then return caret_satisfies(v, c)
  elseif op == "~"  then return tilde_satisfies(v, c)
  elseif op == ">=" then return semver_cmp(v, c) >= 0
  elseif op == "<=" then return semver_cmp(v, c) <= 0
  elseif op == ">"  then return semver_cmp(v, c) >  0
  elseif op == "<"  then return semver_cmp(v, c) <  0
  else                   return semver_cmp(v, c) == 0   -- "" or "="
  end
end

-- Upper bound of a hyphen range "A - B" where B may be partial: full B -> <=B;
-- "B.minor" -> <B.(minor+1).0; "B" -> <(B+1).0.0  (node-semver).
local function hyphen_upper(v, hi)
  local _, ndots = hi:gsub("%.", "")
  local c = parse_semver(hi); if not c then error("rover: bad version constraint '" .. hi .. "'") end
  if ndots >= 2 then return semver_cmp(v, c) <= 0 end
  if ndots == 1 then return semver_cmp(v, { c[1], c[2] + 1, 0 }) < 0 end
  return semver_cmp(v, { c[1] + 1, 0, 0 }) < 0
end

-- A constraint is one of: a wildcard ("*"/""/"latest"); a hyphen range "A - B";
-- or a whitespace-separated AND of comparators (each possibly "op version" with
-- a space after the operator). Raises on an unparseable comparator.
local function semver_satisfies(version, constraint)
  local v = parse_semver(version); if not v then return false end
  local s = (constraint or "*"):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" or s == "*" or s == "latest" or s == "x" or s == "X" then
    return v[4] == nil
  end
  -- Hyphen range "A - B" (spaces around the dash are required, per node-semver).
  local lo, hi = s:match("^(%S+)%s+%-%s+(%S+)$")
  if lo then
    return match_comparator(v, ">=" .. lo) and hyphen_upper(v, hi)
  end
  -- Collapse a space immediately after an operator (">= 1.2.3" -> ">=1.2.3") so
  -- the remaining whitespace splits comparators (AND), then require ALL to hold.
  s = s:gsub("([<>=~^]+)%s+", "%1")
  for comp in s:gmatch("%S+") do
    if not match_comparator(v, comp) then return false end
  end
  return true
end

-- Available versions of <name> in a registry. A versioned registry lays
-- packages out as <reg>/<name>/<version>/init.lua; a flat one as
-- <reg>/<name>/init.lua (single version from its package.lua). Returns the
-- versions sorted DESC (newest first) and whether the registry is versioned.
local function registry_versions(registry, name)
  if not name_ok(name) then return {}, false end   -- never build a shell cmd from a bad name
  local base = registry .. "\\" .. name
  local vers = {}
  local p = io.popen('dir /b /ad "' .. base .. '" 2>nul')
  if p then
    for line in p:lines() do
      if version_ok(line) and parse_semver(line) and exists(base .. "\\" .. line .. "\\init.lua") then
        vers[#vers + 1] = line
      end
    end
    p:close()
  end
  if #vers > 0 then
    table.sort(vers, function(a, b) return semver_cmp(parse_semver(a), parse_semver(b)) > 0 end)
    return vers, true
  end
  return {}, false
end

local function resolve_version(versions, constraint)
  for _, v in ipairs(versions) do                 -- sorted DESC: first match = highest
    if semver_satisfies(v, constraint) then return v end
  end
  return nil
end

----------------------------------------------------------------------
-- Registries: a registry is either a local directory (default) or a URL.
-- Remote registries are static file trees (no server code needed -- a plain
-- file server, GitHub raw, or a file:// path works): <url>/index.json maps
-- name -> [versions]; package files live at <url>/<name>/<version>/init.lua
-- (+ package.lua). Fetched with curl (ships with Windows 10+; supports file://).
----------------------------------------------------------------------
-- Reject a registry URL/path that carries cmd.exe metacharacters before it is
-- interpolated into a shell command (curl/dir). A registry value can come from
-- --registry, the positional slot, or $ROVER_REGISTRY (an untrusted environment
-- in CI / a shipped .env), so without this a crafted value like
--   http://x/" & calc & "
-- would break out of the quotes and run arbitrary commands. Package NAMES were
-- already guarded; the registry was not.
-- control chars, quote, &, |, <, >, ^, %, backtick: none belong in a real
-- registry URL or local path and all are dangerous to cmd.exe. Same predicate
-- as the staging/lock path guard, so there is exactly one rule to audit.
local function registry_ok(reg) return shell_safe_path(reg) end

local function require_safe_registry(reg)
  if not registry_ok(reg) then
    io.stderr:write("[-] refusing registry value with shell metacharacters: " ..
                    tostring(reg) .. "\n")
    os.exit(2)
  end
  return reg
end

local REPO_REGISTRY = "rover\\registry"
-- The OFFICIAL public registry (Go/cargo-style DX): a static file tree served
-- from the CLua-Packages GitHub repository -- index.json + per-package files,
-- exactly the remote-registry shape rover already speaks via curl. To get a
-- package listed here, open a Pull Request at
-- https://github.com/kishimodo/CLua-Packages (reviewed, accepted or denied).
local OFFICIAL_REGISTRY = "https://raw.githubusercontent.com/kishimodo/CLua-Packages/main/packages"
local repo_registry_present = nil          -- lazily probed once per process
-- Precedence: --registry flag (handled by reg_arg) > $ROVER_REGISTRY >
-- rover\registry (a source checkout -- the test suites rely on it) > the
-- OFFICIAL remote registry.
local function default_registry()
  local r = os.getenv("ROVER_REGISTRY")
  if r and r ~= "" then return require_safe_registry(r) end
  if repo_registry_present == nil then
    repo_registry_present = exists(REPO_REGISTRY)
  end
  if repo_registry_present then return REPO_REGISTRY end
  return OFFICIAL_REGISTRY
end

local function is_url(s) return type(s) == "string" and s:match("^%a[%w+.-]*://") ~= nil end

-- curl GET -> body string (nil on failure/empty). -f: fail on HTTP error.
local function http_body(url)
  local p = io.popen('curl -fsSL "' .. url .. '" 2>nul')
  if not p then return nil end
  local b = p:read("*a"); p:close()
  if not b or b == "" then return nil end
  return b
end
-- curl GET -> file (true on success).
local function http_file(url, outfile)
  return sh('curl -fsSL -o "' .. outfile .. '" "' .. url .. '" >nul 2>&1') and exists(outfile)
end

-- Parse `"<name>": ["v1","v2",...]` out of an index.json, sorted DESC. Targeted
-- (the index is machine-written); avoids pulling a full JSON parser into the host.
local function index_versions(text, name)
  if not name_ok(name) then return {} end
  local esc = name:gsub('(%W)', '%%%1')
  local arr = text:match('"' .. esc .. '"%s*:%s*%[(.-)%]')
  if not arr then return {} end
  local vers = {}
  -- versions come from a (possibly hostile) remote index -> allowlist each one.
  for v in arr:gmatch('"([^"]+)"') do if version_ok(v) then vers[#vers + 1] = v end end
  table.sort(vers, function(a, b)
    return semver_cmp(parse_semver(a) or { 0, 0, 0 }, parse_semver(b) or { 0, 0, 0 }) > 0
  end)
  return vers
end

-- Feature 5: remote-registry trust.
--
-- An index.json MAY carry a per-version content hash (ideally the whole-tree
-- Merkle root from Feature 3) so a download can be verified before install:
--
--   { "pkg": ["1.0.0"], "hashes": { "pkg": { "1.0.0": "<treeroot>" } } }
--
-- The simple array form (no "hashes") still works (file:// stays usable). When a
-- hash is present we recompute the tree root of the downloaded files and reject a
-- mismatch. Additionally, a detached signature over the WHOLE index can be
-- required: if $ROVER_REGISTRY_KEY is set, we fetch <url>/index.json.sig and
-- check HMAC-SHA256(index.json, key) == sig (constant-ish compare). HMAC keeps
-- the host pure-Lua (no asymmetric crypto) while still binding the index to a
-- configured secret -- a tampered or unsigned index is rejected.

-- Look up the declared hash for <name>@<version> inside index.json's "hashes".
-- Targeted regex (the index is machine-written), returns nil when absent.
local function index_hash(text, name, version)
  if not (name_ok(name) and version_ok(version)) then return nil end
  local hashes = text:match('"hashes"%s*:%s*(%b{})')
  if not hashes then return nil end
  local en = name:gsub('(%W)', '%%%1')
  local block = hashes:match('"' .. en .. '"%s*:%s*(%b{})')
  if not block then return nil end
  local ev = version:gsub('(%W)', '%%%1')
  return block:match('"' .. ev .. '"%s*:%s*"(%x+)"')
end

-- Extra files an index lists for <name>@<version> beyond init.lua/package.lua,
-- so whole-tree integrity covers multi-file remote packages. Format:
--   "files": { "pkg": { "1.0.0": ["lib/util.lua", "data.lua"] } }
-- Returns a list of safe relative paths (rejects traversal/absolute paths).
local function index_extra_files(text, name, version)
  local out = {}
  if not (name_ok(name) and version_ok(version)) then return out end
  local files = text:match('"files"%s*:%s*(%b{})')
  if not files then return out end
  local en = name:gsub('(%W)', '%%%1')
  local block = files:match('"' .. en .. '"%s*:%s*(%b{})')
  if not block then return out end
  local ev = version:gsub('(%W)', '%%%1')
  local arr = block:match('"' .. ev .. '"%s*:%s*%[(.-)%]')
  if not arr then return out end
  for rel in arr:gmatch('"([^"]+)"') do
    -- only allow forward-slashed relative paths of safe segments
    local ok = true
    if rel == "" or rel:match("^[/\\]") or rel:match(":") or rel:find("%.%.") then ok = false end
    for seg in rel:gmatch("[^/\\]+") do if not seg:match("^[%w_%.%-]+$") then ok = false end end
    if ok then out[#out + 1] = rel end
  end
  return out
end

-- HMAC-SHA256(message, keyhex-or-text). sha256() above operates on byte strings.
local function hmac_sha256(key, message)
  local block = 64
  if #key > block then key = (sha256(key):gsub("(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
  key = key .. string.rep("\0", block - #key)
  local o, i = {}, {}
  for n = 1, block do
    local b = key:byte(n)
    o[n] = string.char(b ~ 0x5c)
    i[n] = string.char(b ~ 0x36)
  end
  local inner = sha256(table.concat(i) .. message)
  local innerbytes = inner:gsub("(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return sha256(table.concat(o) .. innerbytes)
end

-- Verify a detached index signature when a key is configured. Returns true if
-- no key is configured (trust disabled) or the signature matches; false + msg
-- otherwise. `fetch_sig` returns the .sig body (or nil).
local function verify_index_signature(index_text, fetch_sig)
  local key = os.getenv("ROVER_REGISTRY_KEY")
  if not key or key == "" then return true end          -- trust not enabled
  local sig = fetch_sig()
  if not sig then return false, "registry signature required (ROVER_REGISTRY_KEY set) but index.json.sig missing" end
  sig = sig:gsub("%s+", "")
  local want = hmac_sha256(key, index_text)
  sig, want = sig:lower(), want:lower()
  local diff = #sig ~ #want
  local n = math.max(#sig, #want)
  for i = 1, n do diff = diff | ((sig:byte(i) or 0) ~ (want:byte(i) or 0)) end
  if diff == 0 then return true end
  return false, "registry signature mismatch -- index.json failed HMAC verification"
end

-- Fetch one remote index through the SAME signature gate for every consumer.
-- Version selection is security-sensitive too: verifying only the later
-- payload download lets a tampered index steer `update`, `outdated`, conflict
-- reconciliation, and `search` to an attacker-chosen version.
local function verified_remote_index(url)
  url = url:gsub("/+$", "")
  local idx = http_body(url .. "/index.json")
  if not idx then
    if os.getenv("ROVER_REGISTRY_KEY") and os.getenv("ROVER_REGISTRY_KEY") ~= "" then
      return nil, "registry signature required but " .. url .. " has no index.json"
    end
    return nil
  end
  local ok, err = verify_index_signature(idx, function()
    return http_body(url .. "/index.json.sig")
  end)
  if not ok then return nil, err end
  return idx
end

-- Available versions of <name> in a registry (local dir OR URL), sorted DESC.
local function available_versions(name, registry)
  registry = registry or default_registry()
  if is_url(registry) then
    local idx, err = verified_remote_index(registry)
    return idx and index_versions(idx, name) or {}, err
  end
  registry = bs(registry)
  local vers, versioned = registry_versions(registry, name)
  if versioned then return vers end
  local src = registry .. "\\" .. name
  if exists(src .. "\\init.lua") then return { read_meta(src).version } end
  return {}
end

-- Download <name>@version-satisfying-constraint from a URL registry into a
-- PRIVATE per-operation staging directory (never the old predictable
-- %TEMP%\rover-fetch\<name>\<version>, which two concurrent rovers would wipe
-- from under each other). Returns (payload dir, version, staging root) so the
-- caller can release the staging when it is done, or nil + message.
local function fetch_remote(name, constraint, url)
  if not name_ok(name) then return nil, "invalid package name" end
  url = url:gsub("/+$", "")
  local version, declared_hash
  local idx, idxerr = verified_remote_index(url)
  if idxerr then return nil, idxerr end
  if idx then
    local vers = index_versions(idx, name)
    if #vers == 0 then return nil, "package '" .. name .. "' not in remote index " .. url end
    version = resolve_version(vers, constraint)
    if not version then
      return nil, "no remote version of '" .. name .. "' satisfies '" .. constraint ..
                  "' (have: " .. table.concat(vers, ", ") .. ")"
    end
    declared_hash = index_hash(idx, name, version)   -- per-version trusted hash
  elseif parse_semver(constraint) then
    version = constraint                          -- no index: allow an exact version
  else
    return nil, "remote registry " .. url .. " has no index.json; give an exact version"
  end
  if not version_ok(version) then return nil, "invalid version string from remote registry" end
  local work, werr = open_staging(STAGE_TEMP, "fetch")
  if not work then return nil, werr end
  local function bail(msg) close_staging(work); return nil, msg end
  -- The payload lives in a subdirectory so the staging bookkeeping (`stamp`)
  -- can never end up inside the tree whose hash we are about to verify.
  local dl = work .. "\\d"
  if not ensure_dir(dl) then return bail("cannot create the download directory " .. dl) end
  local base = url .. "/" .. name .. "/" .. version
  if not http_file(base .. "/init.lua", dl .. "\\init.lua") then
    return bail("failed to download " .. base .. "/init.lua")
  end
  http_file(base .. "/package.lua", dl .. "\\package.lua")   -- optional metadata
  -- Optionally pull extra files the index lists for this version, so whole-tree
  -- integrity (Feature 3) covers multi-file remote packages too.
  if idx then
    for _, rel in ipairs(index_extra_files(idx, name, version)) do
      local relbs = rel:gsub("/", "\\")
      local outp = dl .. "\\" .. relbs
      local sub = outp:match("^(.*)\\[^\\]+$")
      if sub and not ensure_dir(sub) then return bail("cannot create " .. sub) end
      if not http_file(base .. "/" .. rel, outp) then
        return bail("failed to download listed file " .. base .. "/" .. rel)
      end
    end
  end
  -- Feature 5: verify the downloaded content against the index's trusted hash
  -- BEFORE it is installed. We accept either the whole-tree root (preferred) or
  -- the legacy init.lua hash, so older indexes keep working.
  if declared_hash then
    local got_tree = tree_hash(dl)
    local got_init = pkg_hash(dl)
    if declared_hash ~= got_tree and declared_hash ~= got_init then
      return bail("integrity check failed for '" .. name .. "' v" .. version ..
                  ": downloaded content does not match the hash in index.json")
    end
  end
  return dl, version, work
end

-- Publish `staged` -- a private, COMPLETE copy of one version's tree, sitting on
-- the store's volume -- as the flat compatibility view <store>\<name>.
--
-- The old code ran a NON-recursive `xcopy /Y "<vdir>\*" "<flat>\"` over
-- whatever was already there: nested files were silently omitted, and a file
-- that a newer version had removed stayed behind forever (so the flat view
-- could hash/behave like no released version at all). Instead we diff against
-- the staged tree: delete every flat file the new version does not ship, then
-- MOVE each staged file into place -- a per-file atomic replace, so a reader
-- never sees a half-written file. Version subdirectories are never touched.
-- Consumes `staged`. Returns true, or false + message.
local function publish_flat_view(flat, staged)
  if not (shell_safe_path(flat) and shell_safe_path(staged)) then
    return false, "refusing to publish through a path with shell metacharacters"
  end
  if not ensure_dir(flat) then return false, "cannot create " .. flat end
  local newfiles, want = list_files(staged), {}
  for _, rel in ipairs(newfiles) do want[rel:lower()] = true end
  for _, rel in ipairs(list_files(flat)) do
    if not is_version_segment(rel:match("^([^\\]+)\\")) and not want[rel:lower()] then
      local victim = flat .. "\\" .. rel
      if not shell_safe_path(victim) then
        return false, "refusing to remove a stale path with shell metacharacters: " .. rel
      end
      sh('del /F /Q "' .. victim .. '" >nul 2>&1')
    end
  end
  for _, rel in ipairs(newfiles) do
    local src, dst = staged .. "\\" .. rel, flat .. "\\" .. rel
    if not (shell_safe_path(src) and shell_safe_path(dst)) then
      return false, "refusing to publish a file whose path carries shell metacharacters: " .. rel
    end
    local sub = dst:match("^(.*)\\[^\\]+$")
    if sub and not ensure_dir(sub) then return false, "cannot create " .. sub end
    if not sh('move /Y "' .. src .. '" "' .. dst .. '" >nul 2>&1') then
      return false, "publishing " .. dst .. " failed"
    end
  end
  return true
end

-- Copy a single-version source dir into the store: versioned
-- (<store>/<name>/<version>) for lock-pinned resolution AND flat
-- (<store>/<name>) as the latest. Writes the manifest. Returns m or nil+msg.
--
-- TRANSACTION. The copy AND the integrity hashes happen in a private staging
-- directory on the store's own volume; only then is the package lock taken and
-- the staged tree RENAMED into place. Consequences:
--   * two processes installing the same name@version never see each other's
--     partial trees -- the loser finds an already-published directory whose
--     tree hash equals its own and ADOPTS it instead of republishing;
--   * a version directory is immutable while its content matches. Content that
--     genuinely differs (a tampered store, a re-cut registry version) is
--     swapped in by renaming the old tree aside and the new tree into place,
--     never by emptying and refilling the live directory;
--   * nothing is written into the store before the download/copy has fully
--     succeeded, so a failed install cannot leave a partial package behind.
local function install_from_version_dir(name, version, srcdir)
  if not name_ok(name) then return nil, "invalid package name" end
  if not version_ok(version) then return nil, "invalid version string" end
  if not shell_safe_path(srcdir) then
    return nil, "source path contains shell metacharacters: " .. tostring(srcdir)
  end
  if not shell_safe_path(STORE) then
    return nil, "package store path contains shell metacharacters: " .. STORE
  end
  if not ensure_dir(STORE) then return nil, "cannot create the package store " .. STORE end

  local stage, serr = open_staging(STAGE_STORE, "install")
  if not stage then return nil, serr end
  local payload = stage .. "\\d"
  if not sh('xcopy /E /I /Y /Q "' .. srcdir .. '" "' .. payload .. '" >nul 2>&1')
     or not exists(payload .. "\\init.lua") then
    close_staging(stage)
    return nil, "install of '" .. name .. "' v" .. version ..
                " failed (could not stage " .. srcdir .. ")"
  end
  local staged_tree = tree_hash(payload)
  if not staged_tree then
    close_staging(stage)
    return nil, "install of '" .. name .. "' v" .. version ..
                " failed (staged tree is empty or unreadable)"
  end

  local lk, lerr = acquire_pkg_lock(name, "install " .. name .. "@" .. version)
  if not lk then close_staging(stage); return nil, lerr end

  local flat = STORE .. "\\" .. name
  local vdir = flat .. "\\" .. version
  local ok, err, moved_old, preserve_stage = true, nil, false, false
  if exists(vdir .. "\\init.lua") and staged_tree and tree_hash(vdir) == staged_tree then
    -- Identical bytes are already published: adopt the immutable directory.
  else
    if not ensure_dir(flat) then ok, err = false, "cannot create " .. flat end
    if ok and exists(vdir) then
      if not sh('move /Y "' .. vdir .. '" "' .. stage .. '\\old" >nul 2>&1') then
        ok, err = false, "cannot replace the existing store directory " .. vdir
      else
        moved_old = true
      end
    end
    if ok and not sh('move /Y "' .. payload .. '" "' .. vdir .. '" >nul 2>&1') then
      ok, err = false, "publishing " .. vdir .. " failed"
      if moved_old then
        if sh('move /Y "' .. stage .. '\\old" "' .. vdir .. '" >nul 2>&1') then
          moved_old = false
          err = err .. "; the previous version was restored"
        else
          preserve_stage = true
          err = err .. "; rollback also failed -- recover the previous tree from " ..
                stage .. "\\old"
        end
      end
    end
  end

  if ok then
    local fstage = stage .. "\\flat"
    if not sh('xcopy /E /I /Y /Q "' .. vdir .. '" "' .. fstage .. '" >nul 2>&1') then
      ok, err = false, "cannot stage the flat compatibility view for '" .. name .. "'"
    else
      ok, err = publish_flat_view(flat, fstage)
    end
  end

  local m
  if ok then
    m = read_meta(vdir)
    m.version = version
    m.hash = pkg_hash(vdir) or "?"             -- legacy init.lua hash (compat)
    m.tree = tree_hash(vdir) or m.hash         -- whole-tree Merkle root (integrity)
    ok, err = write_manifest(name, m)
  end

  release_pkg_lock(lk)
  if not preserve_stage then close_staging(stage) end
  if not ok then return nil, err end
  return m
end

----------------------------------------------------------------------
-- FOREIGN packages (Go-style): install straight from a GitHub repository.
--
--   rover install https://github.com/<owner>/<repo>[.git][/]
--   rover install github.com/<owner>/<repo>
--
-- The repo is fetched as a codeload tarball (branch main, falling back to
-- master) with the same external tools rover already uses (curl, plus the
-- tar.exe that ships with Windows 10+), staged under %TEMP%, and installed
-- FLAT into the store (<store>\<name>\...) under the repo name lower-cased.
-- The fetched tree must carry an init.lua at its root (or a package.lua
-- declaring `entry = "<relative file>"`). There is NO trusted index for a
-- foreign install, so there is no registry integrity hash to verify the
-- download against; the manifest records the install-time hashes (so LATER
-- tampering is still caught by `verify`) plus `source = "github.com/<o>/<r>"`,
-- which marks the package FOREIGN -- install/verify/list all warn loudly.
----------------------------------------------------------------------
-- Does `s` even look like a GitHub source? (Used to route install/add; a
-- malformed-but-github-shaped argument then gets a github-specific error
-- instead of the generic invalid-package-name one.)
local function is_github_source(s)
  return type(s) == "string"
         and (s:match("^https?://github%.com/") or s:match("^github%.com/")) ~= nil
end

-- Parse a GitHub source into (owner, repo). Accepts the https URL form with
-- an optional .git suffix and/or trailing slash, and the Go-style shorthand
-- github.com/<owner>/<repo>. Both segments must pass the package-name
-- allowlist (they become shell-command/URL/path segments). Returns
-- owner, repo on success; nil when `s` is not a GitHub source at all; and
-- nil, errmsg when it is github-shaped but malformed.
local function parse_github_source(s)
  if not is_github_source(s) then return nil end
  local rest = s:match("^https?://github%.com/(.*)$") or s:match("^github%.com/(.*)$")
  rest = rest:gsub("/+$", "")
  local owner, repo = rest:match("^([^/]+)/([^/]+)$")
  if not owner then
    return nil, "expected github.com/<owner>/<repo>, got '" .. s .. "'"
  end
  repo = repo:gsub("%.git$", "")
  if not (name_ok(owner) and name_ok(repo)) then
    return nil, "owner/repo in '" .. s ..
                "' contains characters outside the package-name allowlist"
  end
  return owner, repo
end

-- Derive the store name for a GitHub source: the repo name lower-cased,
-- re-checked against the allowlist. Returns name, or nil + message.
local function github_pkg_name(s)
  local owner, repo = parse_github_source(s)
  if not owner then return nil, repo end       -- repo holds the error message
  local name = repo:lower()
  if not name_ok(name) then
    return nil, "derived package name '" .. name .. "' fails the package-name allowlist"
  end
  return name
end

-- The foreign-package warning. MUST print on install and again on
-- `verify`/`list` for any package whose manifest records a `source`.
local function foreign_warning(name, source)
  print(string.format(
    "[!] WARNING: '%s' is a FOREIGN package from %s - it is NOT a verified "
    .. "package from the official CLua-Packages registry (no registry "
    .. "integrity hash). Review its code before trusting it. To get a package "
    .. "verified, open a Pull Request at "
    .. "https://github.com/kishimodo/CLua-Packages - submissions are reviewed "
    .. "and accepted or denied.", name, source))
end

-- Fetch github.com/<owner>/<repo> into a PRIVATE per-operation %TEMP% staging
-- dir (never the old predictable %TEMP%\rover-foreign\<owner>-<repo>, which a
-- second rover would delete mid-extract) and locate the package root (the
-- directory holding init.lua, materializing it from a package.lua `entry` if
-- needed). Test hook: when $ROVER_FOREIGN_TARBALL is set, that local tarball is
-- used instead of curl (the test suite must not hit the network). Returns the
-- staged root dir, nil, and the staging root the caller must release -- or
-- nil + message.
local function fetch_github(owner, repo)
  if not (name_ok(owner) and name_ok(repo)) then
    return nil, "owner/repo fails the package-name allowlist"
  end
  local work, werr = open_staging(STAGE_TEMP, "gh")
  if not work then return nil, werr end
  local function bail(msg) close_staging(work); return nil, msg end
  local tgz = work .. "\\pkg.tgz"
  local hook = os.getenv("ROVER_FOREIGN_TARBALL")
  if hook and hook ~= "" then
    if not registry_ok(hook) then               -- it is interpolated into a shell command
      return bail("ROVER_FOREIGN_TARBALL contains shell metacharacters")
    end
    if not sh('copy /Y "' .. hook .. '" "' .. tgz .. '" >nul 2>&1') or not exists(tgz) then
      return bail("ROVER_FOREIGN_TARBALL is set but unreadable: " .. hook)
    end
  else
    local base = "https://codeload.github.com/" .. owner .. "/" .. repo .. "/tar.gz/refs/heads/"
    if not http_file(base .. "main", tgz) and not http_file(base .. "master", tgz) then
      return bail("failed to download github.com/" .. owner .. "/" .. repo ..
                  " (tried branches main and master via the codeload tarball)")
    end
  end
  local ex = work .. "\\x"
  if not ensure_dir(ex) then return bail("cannot create the extract directory " .. ex) end
  if not sh('tar -xzf "' .. tgz .. '" -C "' .. ex .. '" >nul 2>&1') then
    return bail("failed to extract the tarball (tar.exe, shipped with Windows 10+, is required)")
  end
  -- A codeload tarball wraps everything in <repo>-<branch>/; a hand-built one
  -- may not. Package root = `ex` itself, else the first top-level dir (its
  -- name allowlisted -- it becomes a path segment) holding init/package.lua.
  local root
  if exists(ex .. "\\init.lua") or exists(ex .. "\\package.lua") then
    root = ex
  else
    local p = io.popen('dir /b /ad "' .. ex .. '" 2>nul')
    if p then
      for line in p:lines() do
        if not root and safe_name(line)
           and (exists(ex .. "\\" .. line .. "\\init.lua")
                or exists(ex .. "\\" .. line .. "\\package.lua")) then
          root = ex .. "\\" .. line
        end
      end
      p:close()
    end
  end
  if not root then
    return bail("github.com/" .. owner .. "/" .. repo ..
                " does not look like a CLua package: no init.lua (or package.lua) at the repo root")
  end
  -- Entry point: init.lua at the root, or a package.lua declaring `entry`
  -- (a safe relative path) which we copy to init.lua so the store layout --
  -- and compiler/interpreter resolution -- stays uniform.
  if not exists(root .. "\\init.lua") then
    local t = parse_return_table(read_file(root .. "\\package.lua") or "")
    local entry = (type(t) == "table" and type(t.entry) == "string") and t.entry or nil
    local okrel = entry and entry ~= "" and not entry:match("^[/\\]")
                  and not entry:find(":") and not entry:find("%.%.")
    if okrel then
      for seg in entry:gmatch("[^/\\]+") do
        if not seg:match("^[%w_%.%-]+$") then okrel = false end
      end
    end
    local src = okrel and (root .. "\\" .. entry:gsub("/", "\\")) or nil
    if not (src and exists(src)
            and sh('copy /Y "' .. src .. '" "' .. root .. '\\init.lua" >nul 2>&1')) then
      return bail("github.com/" .. owner .. "/" .. repo ..
                  " does not look like a CLua package: no init.lua at the repo root" ..
                  " (and no package.lua declaring a usable `entry`)")
    end
  end
  return root, nil, work
end

-- Install a foreign GitHub package into the store (FLAT layout -- a foreign
-- install is an unversioned snapshot of a branch head, so it gets no
-- <store>/<name>/<version> dir). Returns manifest, name -- or nil + message.
-- TRANSACTION: same shape as install_from_version_dir -- fetch and stage
-- entirely off to the side, then take the package lock and swap the finished
-- tree in with renames. A foreign snapshot replaces the WHOLE package
-- directory (that has always been its semantics), so the old tree is renamed
-- aside rather than deleted in place.
local function install_foreign(owner, repo)
  local name = repo:lower()
  if not name_ok(name) then
    return nil, "derived package name '" .. name .. "' fails the package-name allowlist"
  end
  if not shell_safe_path(STORE) then
    return nil, "package store path contains shell metacharacters: " .. STORE
  end
  local src, ferr, work = fetch_github(owner, repo)
  if not src then return nil, ferr end
  if not ensure_dir(STORE) then
    close_staging(work); return nil, "cannot create the package store " .. STORE
  end
  local stage, serr = open_staging(STAGE_STORE, "foreign")
  if not stage then close_staging(work); return nil, serr end
  local payload = stage .. "\\d"
  if not sh('xcopy /E /I /Y /Q "' .. src .. '" "' .. payload .. '" >nul 2>&1')
     or not exists(payload .. "\\init.lua") then
    close_staging(stage); close_staging(work)
    return nil, "install of foreign '" .. name .. "' failed (could not stage the fetched tree)"
  end
  close_staging(work)                       -- the download scratch is no longer needed

  local lk, lerr = acquire_pkg_lock(name, "install foreign " .. name)
  if not lk then close_staging(stage); return nil, lerr end
  local flat = STORE .. "\\" .. name
  local ok, err, moved_old, published, preserve_stage = true, nil, false, false, false
  if exists(flat) and not sh('move /Y "' .. flat .. '" "' .. stage .. '\\old" >nul 2>&1') then
    ok, err = false, "cannot replace the existing store directory " .. flat
  elseif exists(stage .. "\\old") then
    moved_old = true
  end
  if ok and not sh('move /Y "' .. payload .. '" "' .. flat .. '" >nul 2>&1') then
    ok, err = false, "install of foreign '" .. name .. "' failed (could not publish into the store)"
  elseif ok then
    published = true
  end
  local m
  if ok then
    m = read_meta(flat)
    m.hash   = pkg_hash(flat) or "?"
    m.tree   = tree_hash(flat) or m.hash
    m.source = "github.com/" .. owner .. "/" .. repo
    ok, err = write_manifest(name, m)
  end
  if not ok and moved_old then
    if published and not sh('move /Y "' .. flat .. '" "' .. stage .. '\\failed" >nul 2>&1') then
      preserve_stage = true
      err = err .. "; rollback could not detach the failed replacement"
    elseif not sh('move /Y "' .. stage .. '\\old" "' .. flat .. '" >nul 2>&1') then
      preserve_stage = true
      err = err .. "; rollback also failed -- recover the previous tree from " ..
            stage .. "\\old"
    else
      err = err .. "; the previous package was restored"
    end
  elseif not ok and published then
    -- There was no prior package. Detach the failed new tree before cleanup so
    -- a failed manifest publication does not leave an untracked install live.
    if not sh('move /Y "' .. flat .. '" "' .. stage .. '\\failed" >nul 2>&1') then
      preserve_stage = true
      err = err .. "; cleanup could not detach the unpublished package at " .. flat
    end
  end
  release_pkg_lock(lk)
  if not preserve_stage then close_staging(stage) end
  if not ok then return nil, err end
  return m, name
end

-- Install <name> at a version satisfying `constraint` (default "*") from a local
-- dir OR a URL registry. Returns its manifest or nil + message.
local function do_install(name, registry, constraint)
  if not name_ok(name) then
    return nil, "invalid package name " .. string.format("%q", tostring(name)) ..
                " (allowed: letters, digits, '.', '_', '-'; no path separators, "
                .. "'..', quotes, spaces or shell metacharacters)"
  end
  registry = registry or default_registry()
  constraint = constraint or "*"
  if is_url(registry) then
    local srcdir, version, work = fetch_remote(name, constraint, registry)
    if not srcdir then return nil, version end       -- version holds the error here
    local m, err = install_from_version_dir(name, version, srcdir)
    close_staging(work)                              -- the download is now published
    return m, err
  end
  registry = bs(registry)
  local versions, versioned = registry_versions(registry, name)
  local srcdir, version
  if versioned then
    version = resolve_version(versions, constraint)
    if not version then
      return nil, "no version of '" .. name .. "' satisfies '" .. constraint ..
                  "' (available: " .. table.concat(versions, ", ") .. ")"
    end
    srcdir = registry .. "\\" .. name .. "\\" .. version
  else
    srcdir = registry .. "\\" .. name
    if not exists(srcdir .. "\\init.lua") and not exists(srcdir .. ".lua") then
      return nil, "package '" .. name .. "' not found in registry '" .. registry .. "'"
    end
    version = read_meta(srcdir).version
    if not semver_satisfies(version, constraint) then
      return nil, "'" .. name .. "' v" .. version .. " does not satisfy '" .. constraint .. "'"
    end
  end
  return install_from_version_dir(name, version, srcdir)
end

-- Read the dependencies of an INSTALLED package (from its store version dir,
-- falling back to the flat dir). Returns name -> range.
local function installed_deps(name, version)
  local vdir = STORE .. "\\" .. name .. "\\" .. version
  if exists(vdir .. "\\package.lua") or exists(vdir .. "\\init.lua") then
    return read_pkg_deps(vdir)
  end
  return read_pkg_deps(STORE .. "\\" .. name)
end

----------------------------------------------------------------------
-- Transitive dependency resolution (Feature 4).
--
-- Starting from a set of root constraints {name -> range}, recursively resolve
-- and install the whole graph: install a package, read its package.lua
-- `dependencies`, resolve+install those, and so on. We detect version conflicts
-- (two requested ranges that no single available version satisfies) and report a
-- clear error rather than silently picking one. The resolved graph (each node's
-- chosen version, hash, tree root, and direct deps) is returned for the lock.
--
-- `graph[name]` = { version, hash, tree, constraints = {..}, deps = {..} }.
----------------------------------------------------------------------
local function resolve_graph(roots, registry)
  registry = registry or default_registry()
  local graph = {}
  local errors = {}

  -- Worklist of { name, constraint, by } requests. `by` is a human label of who
  -- asked (for conflict messages). Process breadth-first.
  local queue = {}
  for name, c in pairs(roots) do queue[#queue + 1] = { name = name, constraint = c or "*", by = "rover.toml" } end

  local head = 1
  while queue[head] do
    local req = queue[head]; head = head + 1
    local name, constraint = req.name, req.constraint
    if not name_ok(name) then
      errors[#errors + 1] = "invalid dependency name from " .. req.by
    else
      local node = graph[name]
      -- record the constraint that brought us here
      local function note() node.constraints[#node.constraints + 1] = { range = constraint, by = req.by } end
      if node then
        -- already chosen: does the existing pick satisfy this new constraint?
        if semver_satisfies(node.version, constraint) then
          note()
        else
          -- try to find a single version satisfying ALL recorded constraints + the new one
          local vers, verr = available_versions(name, registry)
          if verr then
            errors[#errors + 1] = verr
            vers = {}
          end
          local pick
          for _, v in ipairs(vers) do
            local all = semver_satisfies(v, constraint)
            for _, c in ipairs(node.constraints) do all = all and semver_satisfies(v, c.range) end
            if all then pick = v; break end
          end
          if pick and pick ~= node.version then
            -- re-install at the reconciled version
            local m, err = do_install(name, registry, "=" .. pick)
            if not m then errors[#errors + 1] = err
            else
              node.version, node.hash, node.tree = m.version, m.hash, m.tree; note()
              -- The reconciled version may have a DIFFERENT dependency set than
              -- the one first installed. Re-read its deps and enqueue any new
              -- ones (mirroring the first-seen branch) so the resolved closure
              -- stays complete -- otherwise changed transitive deps are silently
              -- never installed or locked.
              node.deps = {}
              local rdeps = installed_deps(name, m.version)
              for dn, dc in pairs(rdeps) do
                node.deps[dn] = dc
                queue[#queue + 1] = { name = dn, constraint = dc, by = name .. "@" .. m.version }
              end
            end
          elseif pick == node.version then
            note()
          else
            local rs = { constraint }
            for _, c in ipairs(node.constraints) do rs[#rs + 1] = c.range .. " (" .. c.by .. ")" end
            errors[#errors + 1] = "dependency conflict for '" .. name ..
              "': no available version satisfies all of { " .. table.concat(rs, ", ") ..
              " }; chose " .. node.version .. " from " .. (node.constraints[1] and node.constraints[1].by or "?")
          end
        end
      else
        -- first time we see this package: resolve + install
        local m, err = do_install(name, registry, constraint)
        if not m then
          errors[#errors + 1] = err
        else
          node = { version = m.version, hash = m.hash, tree = m.tree, constraints = {}, deps = {} }
          graph[name] = node
          note()
          -- enqueue its direct deps
          local deps = installed_deps(name, m.version)
          for dn, dc in pairs(deps) do
            node.deps[dn] = dc
            queue[#queue + 1] = { name = dn, constraint = dc, by = name .. "@" .. m.version }
          end
        end
      end
    end
  end
  if #errors > 0 then return nil, table.concat(errors, "\n[-] ") end
  return graph
end

----------------------------------------------------------------------
-- Argument parsing: pull a `--registry <url>` flag (Feature 6) out of argv
-- BEFORE positional handling, so it works for any command. Returns the cleaned
-- positional argv plus the flag value (nil if absent).
----------------------------------------------------------------------
local function parse_flags(argv)
  local pos, reg, push = {}, nil, nil
  local i = 1
  while argv[i] ~= nil do
    local a = argv[i]
    if a == "--registry" or a == "-r" then
      reg = argv[i + 1]; i = i + 2
    elseif type(a) == "string" and a:match("^%-%-registry=") then
      reg = a:gsub("^%-%-registry=", ""); i = i + 1
    elseif a == "--push" then
      push = argv[i + 1]; i = i + 2
    elseif type(a) == "string" and a:match("^%-%-push=") then
      push = a:gsub("^%-%-push=", ""); i = i + 1
    else
      pos[#pos + 1] = a; i = i + 1
    end
  end
  return pos, reg, push
end

-- `parg` is the flag-stripped positional view: parg[1]=command, parg[2]=name,...
-- mirroring the original `arg[1..]` layout the command handlers expect.
local parg, FLAG_REGISTRY, FLAG_PUSH = parse_flags(arg)
-- A registry given as `--registry <url>` overrides the positional registry slot.
-- Validate whichever value we use against shell-injection before it reaches curl/dir.
local function reg_arg(slot)
  local r = FLAG_REGISTRY or slot
  if r ~= nil then require_safe_registry(r) end
  return r
end

----------------------------------------------------------------------
-- Test hook: when $ROVER_PKG_TEST is set, publish the internal functions on a
-- global so a unit test can `dofile` this program and exercise pure logic
-- (semver, name/version validation, hashing, index parsing) directly, then
-- return WITHOUT running any command. Inert in normal use (the env var is unset).
----------------------------------------------------------------------
if os.getenv("ROVER_PKG_TEST") then
  _G.ROVER_PKG = {
    name_ok = name_ok, version_ok = version_ok,
    parse_semver = parse_semver, semver_cmp = semver_cmp,
    semver_satisfies = semver_satisfies, caret_satisfies = caret_satisfies,
    tilde_satisfies = tilde_satisfies, registry_ok = registry_ok,
    resolve_version = resolve_version,
    -- transaction primitives (staging, atomic publication, package locks)
    shell_safe_path = shell_safe_path, is_version_segment = is_version_segment,
    write_atomic = write_atomic, ensure_dir = ensure_dir, rm_rf = rm_rf,
    open_staging = open_staging, close_staging = close_staging,
    acquire_pkg_lock = acquire_pkg_lock, release_pkg_lock = release_pkg_lock,
    publish_flat_view = publish_flat_view,
    STORE = STORE, STAGE_TEMP = STAGE_TEMP, STAGE_STORE = STAGE_STORE,
    LOCK_ROOT = LOCK_ROOT,
    sha256 = sha256, hmac_sha256 = hmac_sha256,
    tree_hash = tree_hash, pkg_hash = pkg_hash, list_files = list_files,
    index_versions = index_versions, index_hash = index_hash,
    index_extra_files = index_extra_files,
    read_pkg_deps = read_pkg_deps,
    parse_return_table = parse_return_table,
    -- foreign packages + registry defaulting (pure helpers)
    is_github_source = is_github_source,
    parse_github_source = parse_github_source,
    github_pkg_name = github_pkg_name,
    default_registry = default_registry,
    OFFICIAL_REGISTRY = OFFICIAL_REGISTRY, REPO_REGISTRY = REPO_REGISTRY,
  }
  return
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local cmd = parg[1]

if cmd == "where" then
  print(STORE)

elseif cmd == "install" then
  local name = parg[2]
  if name and is_github_source(name) then
    -- FOREIGN install: rover install https://github.com/<o>/<r> | github.com/<o>/<r>
    local owner, repo = parse_github_source(name)
    if not owner then print("[-] " .. repo); os.exit(2) end    -- repo holds the error
    local m, pkgname = install_foreign(owner, repo)
    if not m then print("[-] " .. pkgname); os.exit(1) end     -- pkgname holds the error
    print(string.format("[+] installed FOREIGN '%s' v%s -> %s\\%s", pkgname, m.version, STORE, pkgname))
    print("    sha256(init.lua) = " .. m.hash)
    print("    tree sha256       = " .. (m.tree or m.hash))
    print("    source            = " .. m.source)
    foreign_warning(pkgname, m.source)
    os.exit(0)
  end
  if name then
    require_valid_name(name, "install")
    -- single package: install <name> [registry] (transitive deps included)
    local registry = reg_arg(parg[3])
    local graph, err = resolve_graph({ [name] = "*" }, registry)
    if not graph then print("[-] " .. err); os.exit(1) end
    local root = graph[name]
    print(string.format("[+] installed '%s' v%s -> %s\\%s", name, root.version, STORE, name))
    print("    sha256(init.lua) = " .. root.hash)
    print("    tree sha256       = " .. (root.tree or root.hash))
    local extra = 0
    for n in pairs(graph) do if n ~= name then extra = extra + 1 end end
    if extra > 0 then print(string.format("    + %d transitive dependency(ies)", extra)) end
    os.exit(0)
  end
  -- PROJECT MODE. Two paths, npm-style:
  --   * A rover.lock exists -> CI semantics: install EXACTLY the pinned
  --     versions/hashes, verify content, NO re-resolution (Bug 2). A committed
  --     lock is reproducible: widening the toml constraint must NOT silently
  --     upgrade. Use `update`/`add` to change pins.
  --   * No lock -> resolve the toml constraints (incl. transitive deps), install,
  --     and write a fresh rover.lock.
  local registry = reg_arg(parg[3])
  local lock, lockerr = read_lock()
  if lockerr == "corrupt" then
    print("[-] " .. LOCK .. " exists but is corrupt/unparseable; refusing to " ..
          "silently re-resolve (that would clobber the pinned, reproducible set). " ..
          "Fix or delete it, or run `update` to regenerate it.")
    os.exit(1)
  end
  if lock and next(lock) ~= nil then
    print("[*] rover.lock found -> installing pinned versions (reproducible; no re-resolution)")
    local fail = 0
    local names = {}
    for n in pairs(lock) do names[#names + 1] = n end
    table.sort(names)
    for _, dep in ipairs(names) do
      local e = lock[dep]
      if not name_ok(dep) or not version_ok(e.version) then
        fail = fail + 1; print("[-] invalid lock entry for '" .. tostring(dep) .. "'")
      elseif e.source and e.source ~= "" then
        -- FOREIGN: not in any registry -- verify the installed store content
        -- against the locked hash instead of re-resolving.
        local dir  = STORE .. "\\" .. dep
        local want = (e.tree and e.tree ~= "") and e.tree or e.hash
        local got  = exists(dir .. "\\init.lua")
                     and ((e.tree and e.tree ~= "") and tree_hash(dir) or pkg_hash(dir)) or nil
        if not got then
          fail = fail + 1
          print(string.format("[-] foreign '%s' is not installed; run `rover install %s` to fetch it",
                dep, "https://" .. e.source))
        elseif want and want ~= "" and got ~= want then
          fail = fail + 1
          print(string.format("[-] %s v%s INTEGRITY FAILURE: locked %s, installed %s",
                dep, e.version, want:sub(1, 16), got:sub(1, 16)))
        else
          print(string.format("[+] %s v%s (foreign, locked)", dep, e.version))
          foreign_warning(dep, e.source)
        end
      else
        -- install the EXACT locked version (no constraint widening)
        local m, err = do_install(dep, registry, "=" .. e.version)
        if not m then
          fail = fail + 1; print("[-] " .. err)
        elseif m.version ~= e.version then
          fail = fail + 1
          print(string.format("[-] %s: lock pins %s but registry resolved %s", dep, e.version, m.version))
        else
          -- Verify installed content matches the locked hash, comparing
          -- LIKE-FOR-LIKE: if the lock recorded a Merkle tree root, recompute
          -- the tree (not the single-file hash) and require it. A missing
          -- recomputed hash is a hard FAILURE, never a silent pass (the old
          -- `want and got and want~=got` skipped the check whenever got was nil
          -- and could spuriously fail when the kinds differed).
          local want, got
          if e.tree then want, got = e.tree, m.tree
          else           want, got = e.hash, m.hash end
          if want then
            if not got or got == "" then
              fail = fail + 1
              print(string.format("[-] %s v%s INTEGRITY FAILURE: cannot recompute %s hash to verify",
                    dep, e.version, e.tree and "tree" or "content"))
            elseif want ~= got then
              fail = fail + 1
              print(string.format("[-] %s v%s INTEGRITY FAILURE: locked %s, installed %s",
                    dep, e.version, want:sub(1, 16), got:sub(1, 16)))
            else
              print(string.format("[+] %s v%s (locked, %s)", dep, e.version, want:sub(1, 12)))
            end
          else
            print(string.format("[+] %s v%s (locked, no hash to verify)", dep, e.version))
          end
        end
      end
    end
    os.exit(fail == 0 and 0 or 1)
  end
  -- no lock: resolve from the toml (first install) and write the lock.
  local deps = read_toml_deps(TOML)
  if not deps then
    print("[-] no " .. TOML .. " found (and no <name> given). Run `init` or `add <name>`.")
    os.exit(1)
  end
  local graph, err = resolve_graph(deps, registry)
  if not graph then print("[-] " .. err); os.exit(1) end
  local n = 0
  for dep, node in pairs(graph) do
    n = n + 1
    print(string.format("[+] %s -> v%s (%s)", dep, node.version, (node.tree or node.hash):sub(1, 12)))
  end
  if n > 0 then
    local ok, werr = write_lock(graph)
    if not ok then print("[-] " .. werr); os.exit(1) end
    print(string.format("[+] wrote %s (%d packages)", LOCK, n))
  end
  os.exit(0)

elseif cmd == "add" then
  local name = parg[2]
  if not name then print("usage: add <name|github.com/owner/repo> [registry] [constraint] [--registry url]"); os.exit(2) end
  local existing_lock, existing_lockerr = read_lock()
  if existing_lockerr == "corrupt" then
    print("[-] " .. LOCK .. " exists but is corrupt/unparseable; refusing to add "
          .. "a dependency because that would destroy the existing pins.")
    os.exit(1)
  end
  if is_github_source(name) then
    -- FOREIGN add: install from GitHub + record in rover.toml ("*": foreign
    -- snapshots have no registry versions to range over) + pin in rover.lock
    -- with the install-time hashes and the source.
    local owner, repo = parse_github_source(name)
    if not owner then print("[-] " .. repo); os.exit(2) end    -- repo holds the error
    local m, pkgname = install_foreign(owner, repo)
    if not m then print("[-] " .. pkgname); os.exit(1) end     -- pkgname holds the error
    local tok, terr = add_toml_dep(pkgname, "*")
    if not tok then print("[-] " .. terr); os.exit(1) end
    local lock = existing_lock or {}
    lock[pkgname] = { version = m.version, hash = m.hash, tree = m.tree, source = m.source }
    local lok, lerr2 = write_lock(lock)
    if not lok then print("[-] " .. lerr2); os.exit(1) end
    print(string.format("[+] added FOREIGN '%s' v%s to %s and installed it", pkgname, m.version, TOML))
    foreign_warning(pkgname, m.source)
    os.exit(0)
  end
  require_valid_name(name, "add")
  local registry = reg_arg(parg[3])
  local constraint = parg[4]
  -- resolve+install the package AND its transitive deps under one constraint set
  local roots = read_toml_deps(TOML) or {}
  roots[name] = constraint or "*"
  local graph, err = resolve_graph(roots, registry)
  if not graph then print("[-] " .. err); os.exit(1) end
  local root = graph[name]
  -- record the user's constraint (or a caret on the resolved version) in toml.
  local tok, terr = add_toml_dep(name, constraint or ("^" .. root.version))
  if not tok then print("[-] " .. terr); os.exit(1) end
  local lok, lerr = write_lock(graph)
  if not lok then print("[-] " .. lerr); os.exit(1) end
  print(string.format("[+] added '%s' v%s to %s and installed it", name, root.version, TOML))

elseif cmd == "remove" then
  local name = parg[2]
  if not name then print("usage: remove <name>"); os.exit(2) end
  require_valid_name(name, "remove")
  local lock, lockerr = read_lock()
  if lockerr == "corrupt" then
    print("[-] " .. LOCK .. " exists but is corrupt/unparseable; refusing to "
          .. "remove anything until its pins can be read.")
    os.exit(1)
  end
  -- drop from the store + manifest, under the package lock so a concurrent
  -- install cannot be publishing into the tree we are deleting. The tree is
  -- RENAMED aside first, so a reader never walks a directory being emptied.
  local lk, lerr = acquire_pkg_lock(name, "remove " .. name)
  if not lk then print("[-] " .. lerr); os.exit(1) end
  local dir = STORE .. "\\" .. name
  if exists(dir) then
    local stage, serr = open_staging(STAGE_STORE, "remove")
    if not stage or not sh('move /Y "' .. dir .. '" "' .. stage .. '\\old" >nul 2>&1') then
      close_staging(stage)
      release_pkg_lock(lk)
      print("[-] could not atomically detach " .. dir .. ": " ..
            tostring(serr or "rename failed"))
      os.exit(1)
    end
    close_staging(stage)
  end
  sh('if exist "' .. manifest_path(name) .. '" del /Q "' .. manifest_path(name) .. '" >nul 2>&1')
  release_pkg_lock(lk)
  -- Feature 6: also drop the dependency from rover.toml AND rover.lock.
  local toml = read_file(TOML)
  if toml then
    -- remove the `name = "..."` line from [dependencies]
    local esc = name:gsub("(%W)", "%%%1")
    toml = toml:gsub("\n%s*" .. esc .. "%s*=[^\n]*", "")
    local ok, err = write_atomic(TOML, toml)
    if not ok then print("[-] " .. err); os.exit(1) end
  end
  if lock and lock[name] then
    lock[name] = nil
    local ok, err = write_lock(lock)
    if not ok then print("[-] " .. err); os.exit(1) end
  end
  print("[+] removed '" .. name .. "' (store, manifest, rover.toml, rover.lock)")

elseif cmd == "verify" then
  -- verify one package against its install manifest, or (no arg) every package
  -- pinned in rover.lock against its locked hash. When a version is known, hash
  -- the VERSIONED dir (<store>/<name>/<version>) -- the exact bytes the lock
  -- pins -- falling back to the flat <store>/<name> for un-versioned installs.
  -- Bug 3: prefer the whole-tree Merkle root so a swapped HELPER file (not just
  -- init.lua) is detected; fall back to the legacy init.lua hash for old data.
  local function verify_one(name, version, want_tree, want_init, label)
    if not name_ok(name) then print("[-] invalid package name in lock: " .. tostring(name)); return false end
    local dir = STORE .. "\\" .. name
    local versioned = false
    if version and version_ok(version) and exists(dir .. "\\" .. version .. "\\init.lua") then
      dir = dir .. "\\" .. version
      versioned = true
    end
    if not exists(dir .. "\\init.lua") then
      print("[-] " .. label .. " not installed in the store"); return false
    end
    if want_tree and want_tree ~= "" then
      local actual = tree_hash(dir, not versioned)
      if actual == want_tree then
        print(string.format("[+] %s OK (tree %s)", label, actual)); return true
      end
      print("[-] " .. label .. " INTEGRITY FAILURE -- a file in the package changed")
      print("    expected tree " .. tostring(want_tree) .. "\n    actual   tree " .. tostring(actual))
      return false
    end
    -- legacy / no tree recorded: compare init.lua hash
    local actual = pkg_hash(dir)
    if actual == want_init then
      print(string.format("[+] %s OK (sha256 %s)", label, actual)); return true
    end
    print("[-] " .. label .. " INTEGRITY FAILURE -- content changed")
    print("    expected " .. tostring(want_init) .. "\n    actual   " .. tostring(actual))
    return false
  end
  local name = parg[2]
  if name then
    require_valid_name(name, "verify")
    local m = read_manifest(name)
    if not m then print("[-] '" .. name .. "' is not installed (no manifest)"); os.exit(1) end
    -- FOREIGN packages warn on every verify (the hashes only pin the bytes
    -- installed that day -- there is no registry integrity hash behind them).
    if m.source and m.source ~= "" then foreign_warning(name, m.source) end
    os.exit(verify_one(name, nil, m.tree, m.hash, "'" .. name .. "' v" .. m.version) and 0 or 1)
  end
  -- project mode: verify all of rover.lock
  local lock, lockerr = read_lock()
  if lockerr == "corrupt" then
    print("[-] " .. LOCK .. " exists but is corrupt/unparseable; refusing to "
          .. "report unverifiable pins as absent.")
    os.exit(1)
  end
  if not lock then print("[-] no " .. LOCK .. " (run `install` to generate one)"); os.exit(1) end
  local bad = 0
  for n, e in pairs(lock) do
    if e.source and e.source ~= "" then foreign_warning(n, e.source) end
    if not verify_one(n, e.version, e.tree, e.hash, n .. " v" .. e.version) then bad = bad + 1 end
  end
  if bad == 0 then print("[+] all locked packages verified") end
  os.exit(bad == 0 and 0 or 1)

elseif cmd == "info" then
  local name = parg[2]
  if not name then print("usage: info <name>"); os.exit(2) end
  require_valid_name(name, "info")
  local m = read_manifest(name)
  if not m then print("[-] '" .. name .. "' is not installed"); os.exit(1) end
  print("name:        " .. (m.name or name))
  print("version:     " .. (m.version or "?"))
  print("description: " .. (m.description or ""))
  print("sha256:      " .. (m.hash or "?"))
  if m.tree and m.tree ~= "" then print("tree:        " .. m.tree) end
  if m.source and m.source ~= "" then print("source:      " .. m.source .. "  (FOREIGN)") end
  print("location:    " .. STORE .. "\\" .. name)

elseif cmd == "list" then
  local p = io.popen('dir /b /ad "' .. STORE .. '" 2>nul')
  local any = false
  if p then
    for line in p:lines() do
      if line ~= "" and line ~= ".meta" and safe_name(line) then
        local m = read_manifest(line)
        if m then
          local foreign = (m.source and m.source ~= "") and "  [FOREIGN]" or ""
          print(string.format("  %-20s v%s  %s%s", line, m.version or "?", m.description or "", foreign))
          if foreign ~= "" then foreign_warning(line, m.source) end
        else print("  " .. line) end
        any = true
      end
    end
    p:close()
  end
  if not any then print("  (no packages installed in " .. STORE .. ")") end

elseif cmd == "outdated" then
  -- For each dependency in rover.toml, compare the locked version against the
  -- newest version the registry offers that still satisfies the constraint, and
  -- the newest overall.
  local deps = read_toml_deps(TOML)
  if not deps then print("[-] no " .. TOML .. " (run `init`/`add` first)"); os.exit(1) end
  local registry = reg_arg(parg[2]) or default_registry()
  local lock, lockerr = read_lock()
  if lockerr == "corrupt" then
    print("[-] " .. LOCK .. " exists but is corrupt/unparseable; refusing to "
          .. "compare versions against unknown pins.")
    os.exit(1)
  end
  lock = lock or {}
  local names = {}
  for d in pairs(deps) do names[#names + 1] = d end
  table.sort(names)
  local any = false
  for _, name in ipairs(names) do
    local constraint = deps[name]
    local cur = lock[name] and lock[name].version or nil
    local vers, verr = available_versions(name, registry)
    if verr then print("[-] " .. verr); os.exit(1) end
    local best = resolve_version(vers, constraint)     -- newest satisfying constraint
    local latest = vers[1]                             -- newest overall
    if best and best ~= cur then
      print(string.format("  %-16s %s -> %s   (constraint %s; latest %s)",
            name, cur or "(unlocked)", best, constraint, latest or "?"))
      any = true
    elseif latest and cur and latest ~= cur then
      print(string.format("  %-16s %s   (latest %s held back by constraint %s)",
            name, cur, latest, constraint))
      any = true
    end
  end
  if not any then print("[+] all dependencies are up to date") end

elseif cmd == "update" then
  -- Re-resolve constraints from the registry and install/relock newer versions.
  -- `update` updates every dep; `update <name>` updates one. This is the ONLY
  -- path (besides `add`) allowed to change a lock pin (Bug 2).
  local only = parg[2]
  if only then require_valid_name(only, "update") end
  local registry = reg_arg(parg[3]) or default_registry()
  local deps = read_toml_deps(TOML)
  if not deps then print("[-] no " .. TOML); os.exit(1) end
  local lock, lockerr = read_lock()
  if lockerr == "corrupt" then
    print("[-] " .. LOCK .. " exists but is corrupt/unparseable; refusing to "
          .. "update because that would destroy the existing pins.")
    os.exit(1)
  end
  lock = lock or {}
  -- resolve the full graph fresh from the (possibly widened) constraints
  local graph, err = resolve_graph(deps, registry)
  if not graph then print("[-] " .. err); os.exit(1) end
  local changed = 0
  -- when updating a single dep, keep the other lock entries untouched
  local newlock = {}
  for dep, e in pairs(lock) do newlock[dep] = e end
  for dep, node in pairs(graph) do
    if (not only) or dep == only or not lock[dep] then
      local prev = lock[dep] and lock[dep].version
      newlock[dep] = { version = node.version, hash = node.hash, tree = node.tree, deps = node.deps }
      if prev ~= node.version then
        print(string.format("[+] %s: %s -> %s", dep, prev or "none", node.version))
        changed = changed + 1
      else
        print(string.format("[=] %s already at %s", dep, node.version))
      end
    end
  end
  local lok, lerr = write_lock(newlock)
  if not lok then print("[-] " .. lerr); os.exit(1) end
  if changed == 0 then print("[+] nothing to update") end
  os.exit(0)

elseif cmd == "gc" then
  -- Prune versioned store dirs (<store>/<name>/<version>) that are neither the
  -- newest installed version of their package nor pinned by the current
  -- project's rover.lock. The flat install is always kept.
  local lock, lockerr = read_lock()
  if lockerr == "corrupt" then
    print("[-] " .. LOCK .. " exists but is corrupt/unparseable; refusing to "
          .. "garbage-collect versions whose pins are unknown.")
    os.exit(1)
  end
  lock = lock or {}
  local pkgs, p = {}, io.popen('dir /b /ad "' .. STORE .. '" 2>nul')
  if p then for line in p:lines() do if line ~= "" and line ~= ".meta" and safe_name(line) then pkgs[#pkgs + 1] = line end end p:close() end
  local pruned, kept = 0, 0
  for _, name in ipairs(pkgs) do
    -- Hold the package lock while pruning so a concurrent install cannot be
    -- publishing into a version dir we are deleting. A package that is busy is
    -- skipped, never force-pruned.
    local lk, lerr = acquire_pkg_lock(name, "gc " .. name)
    if not lk then
      print("  [!] skipped " .. name .. ": " .. lerr)
    else
      local vers = registry_versions(STORE, name)   -- versioned subdirs under the store
      local latest = vers[1]
      local pinned = lock[name] and lock[name].version
      for _, v in ipairs(vers) do
        if v ~= latest and v ~= pinned then
          -- rename aside, then delete: a reader never walks a dying tree
          local stage, serr = open_staging(STAGE_STORE, "gc")
          local vdir = STORE .. "\\" .. name .. "\\" .. v
          if stage and sh('move /Y "' .. vdir .. '" "' .. stage .. '\\old" >nul 2>&1') then
            close_staging(stage)
            print(string.format("  pruned %s v%s", name, v))
            pruned = pruned + 1
          else
            close_staging(stage)
            print(string.format("  [!] kept %s v%s: atomic detach failed%s",
                  name, v, serr and (" (" .. serr .. ")") or ""))
            kept = kept + 1
          end
        else
          kept = kept + 1
        end
      end
      release_pkg_lock(lk)
    end
  end
  print(string.format("[+] gc: pruned %d, kept %d versioned dir(s) (latest + lock-pinned)", pruned, kept))

elseif cmd == "publish" then
  -- Feature 6: index.json generation tooling. Scan a registry DIRECTORY and
  -- (re)write its index.json with each package's versions, per-version tree-root
  -- hashes, and (for multi-file packages) the file list -- exactly the trusted
  -- data `fetch_remote`/`do_install` verify against. Usage:
  --   publish [<registry-dir>] [--registry dir]
  local regdir = reg_arg(parg[2]) or default_registry()
  if is_url(regdir) then print("[-] publish needs a local registry directory, not a URL"); os.exit(2) end
  regdir = bs(regdir)
  local names = {}
  do
    local pp = io.popen('dir /b /ad "' .. regdir .. '" 2>nul')
    if pp then for line in pp:lines() do if line ~= "" and safe_name(line) then names[#names + 1] = line end end pp:close() end
  end
  table.sort(names)
  -- collect per-package versions, hashes, and extra files
  local versions_of, hashes_of, files_of = {}, {}, {}
  for _, nm in ipairs(names) do
    local vers = select(1, registry_versions(regdir, nm))
    if #vers == 0 and exists(regdir .. "\\" .. nm .. "\\init.lua") then
      vers = { read_meta(regdir .. "\\" .. nm).version }   -- flat single-version
    end
    if #vers > 0 then
      versions_of[nm] = vers
      hashes_of[nm], files_of[nm] = {}, {}
      for _, v in ipairs(vers) do
        local vdir = regdir .. "\\" .. nm .. "\\" .. v
        if not exists(vdir .. "\\init.lua") then vdir = regdir .. "\\" .. nm end
        hashes_of[nm][v] = tree_hash(vdir) or pkg_hash(vdir) or ""
        local extra = {}
        for _, rel in ipairs(list_files(vdir)) do
          local r = rel:gsub("\\", "/")
          if r ~= "init.lua" and r ~= "package.lua" then extra[#extra + 1] = r end
        end
        table.sort(extra)
        files_of[nm][v] = extra
      end
    end
  end
  -- emit JSON (hand-written; the index is machine-read by index_versions etc.)
  local function jstr(s) return '"' .. tostring(s):gsub('[\\"]', '\\%0') .. '"' end
  local out = { "{" }
  local rows = {}
  for _, nm in ipairs(names) do
    if versions_of[nm] then
      local vs = {}
      for _, v in ipairs(versions_of[nm]) do vs[#vs + 1] = jstr(v) end
      rows[#rows + 1] = "  " .. jstr(nm) .. ": [" .. table.concat(vs, ", ") .. "]"
    end
  end
  out[#out + 1] = table.concat(rows, ",\n") .. ","
  -- hashes block
  local hrows = {}
  for _, nm in ipairs(names) do
    if hashes_of[nm] then
      local hr = {}
      for _, v in ipairs(versions_of[nm]) do hr[#hr + 1] = "      " .. jstr(v) .. ": " .. jstr(hashes_of[nm][v]) end
      hrows[#hrows + 1] = "    " .. jstr(nm) .. ": {\n" .. table.concat(hr, ",\n") .. "\n    }"
    end
  end
  out[#out + 1] = "  \"hashes\": {\n" .. table.concat(hrows, ",\n") .. "\n  },"
  -- files block (only for versions with extra files)
  local frows = {}
  for _, nm in ipairs(names) do
    if files_of[nm] then
      local fr = {}
      for _, v in ipairs(versions_of[nm]) do
        local fl = files_of[nm][v]
        if fl and #fl > 0 then
          local items = {}
          for _, f in ipairs(fl) do items[#items + 1] = jstr(f) end
          fr[#fr + 1] = "      " .. jstr(v) .. ": [" .. table.concat(items, ", ") .. "]"
        end
      end
      if #fr > 0 then frows[#frows + 1] = "    " .. jstr(nm) .. ": {\n" .. table.concat(fr, ",\n") .. "\n    }" end
    end
  end
  out[#out + 1] = "  \"files\": {\n" .. table.concat(frows, ",\n") .. "\n  }"
  out[#out + 1] = "}"
  local idxtext = table.concat(out, "\n") .. "\n"
  local idxpath = regdir .. "\\index.json"
  -- Atomic: a failed regeneration must leave the previous, consistent index in
  -- place -- clients fetching it mid-publish must never read a truncated file.
  local wok, werr = write_atomic(idxpath, idxtext)
  if not wok then print("[-] " .. werr); os.exit(1) end
  print("[+] wrote " .. idxpath .. " (" .. #names .. " package(s))")
  -- optionally emit a detached HMAC signature when a key is configured
  local key = os.getenv("ROVER_REGISTRY_KEY")
  if key and key ~= "" then
    local sok, serr = write_atomic(regdir .. "\\index.json.sig", hmac_sha256(key, idxtext) .. "\n")
    if not sok then print("[-] " .. serr); os.exit(1) end
    print("[+] wrote index.json.sig (HMAC-SHA256, $ROVER_REGISTRY_KEY)")
  end

  -- `--push <dest>`: distribute the just-generated registry to a remote URL
  -- (HTTP PUT per file via curl -- the "dumb HTTP registry" model that any
  -- WebDAV / S3 / static-with-PUT host supports) or copy it into another local
  -- directory. The destination is validated against shell metacharacters first.
  if FLAG_PUSH and FLAG_PUSH ~= "" then
    require_safe_registry(FLAG_PUSH)
    local files = list_files(regdir)   -- relative paths, includes index.json[.sig]
    local n_ok, n_fail = 0, 0
    if is_url(FLAG_PUSH) then
      local base = FLAG_PUSH:gsub("/+$", "")
      for _, rel in ipairs(files) do
        local relfs = rel:gsub("\\", "/")
        if relfs:find("..", 1, true) then
          -- never upload a path with a traversal segment
        elseif sh('curl -fsS -T "' .. regdir .. "\\" .. rel .. '" "' .. base .. "/" .. relfs .. '" >nul 2>&1') then
          n_ok = n_ok + 1
        else
          n_fail = n_fail + 1; print("[-] upload failed: " .. relfs)
        end
      end
      print(string.format("[+] pushed %d file(s) to %s (%d failed)", n_ok, base, n_fail))
    else
      local dest = bs(FLAG_PUSH)
      for _, rel in ipairs(files) do
        local dst    = dest .. "\\" .. rel
        local dstdir = dst:match("^(.+)\\[^\\]+$")
        if dstdir then sh('mkdir "' .. dstdir .. '" 2>nul') end
        if sh('copy /Y "' .. regdir .. "\\" .. rel .. '" "' .. dst .. '" >nul 2>&1') then
          n_ok = n_ok + 1
        else
          n_fail = n_fail + 1; print("[-] copy failed: " .. rel)
        end
      end
      print(string.format("[+] copied %d file(s) to %s (%d failed)", n_ok, dest, n_fail))
    end
    if n_fail > 0 then os.exit(1) end
  end

elseif cmd == "search" then
  local q = (parg[2] or ""):lower()
  local registry = reg_arg(parg[3]) or default_registry()
  local any = false
  if is_url(registry) then
    -- list package names from the remote index.json
    local idx, idxerr = verified_remote_index(registry)
    if idxerr then print("[-] " .. idxerr); os.exit(1) end
    if idx then
      local names = {}
      for nm in idx:gmatch('"([%w_%-%.]+)"%s*:%s*%[') do if safe_name(nm) then names[#names + 1] = nm end end
      table.sort(names)
      for _, nm in ipairs(names) do
        if q == "" or nm:lower():find(q, 1, true) then
          local vs = index_versions(idx, nm)
          print(string.format("  %-20s %s", nm, table.concat(vs, ", ")))
          any = true
        end
      end
    end
  else
    registry = bs(registry)
    local p = io.popen('dir /b /ad "' .. registry .. '" 2>nul')
    if p then
      for line in p:lines() do
        if line ~= "" and safe_name(line) then
          local meta = read_meta(registry .. "\\" .. line)
          local hay = (line .. " " .. (meta.description or "")):lower()
          if q == "" or hay:find(q, 1, true) then
            print(string.format("  %-20s v%s  %s", line, meta.version, meta.description or ""))
            any = true
          end
        end
      end
      p:close()
    end
  end
  if not any then print("  (no matching packages in " .. registry .. ")") end

elseif cmd == "init" then
  local target = "rover.toml"
  if exists(target) then print("[-] " .. target .. " already exists"); os.exit(1) end
  local ok, err = write_atomic(target, table.concat({
    "# rover.toml -- rover (the CLua package manager) project manifest",
    "[project]",
    'name = "my-project"',
    'version = "0.1.0"',
    "",
    "# Declare dependencies here, then `rover install` (no args) installs them",
    "# all and writes rover.lock with resolved versions + sha256 hashes.",
    "# `rover add <name>` installs + records a dependency for you.",
    "[dependencies]",
    "# greet = \"^1.0.0\"",
    "",
  }, "\n"))
  if not ok then print("[-] " .. err); os.exit(1) end
  print("[+] wrote " .. target)

else
  print("rover -- the CLua package manager")
  print("usage:")
  print("  install [<name>] [registry]   install one package + its deps, OR (no name)")
  print("                                install rover.toml deps. With a rover.lock,")
  print("                                installs the EXACT pinned versions (reproducible).")
  print("  install <github-repo>         FOREIGN install: https://github.com/<owner>/<repo>")
  print("                                (.git/trailing-slash ok) or github.com/<owner>/<repo>.")
  print("                                Fetches the repo (branch main, then master) and")
  print("                                installs it under the lower-cased repo name. NOT")
  print("                                from the official registry -- no registry integrity")
  print("                                hash; a loud warning is printed.")
  print("  add     <name> [registry] [constraint]  install + record in rover.toml + lock")
  print("                                (also accepts the github.com forms above)")
  print("  update  [<name>] [registry]   re-resolve constraints + install/relock newer")
  print("  outdated [registry]           show deps with newer versions available")
  print("  remove  <name>                uninstall + drop from manifest, rover.toml, lock")
  print("  gc                            prune old store versions (keep latest + locked)")
  print("  verify  [<name>]              re-hash one package, OR (no name) the whole lock")
  print("  info    <name>                show the installed manifest")
  print("  list                          list installed packages + versions")
  print("  search  <query> [registry]    search the registry (local dir or URL)")
  print("  publish [<registry-dir>]      (re)generate index.json (versions+hashes+files)")
  print("  init                          scaffold a rover.toml in the cwd")
  print("  where                         print the global store path")
  print("")
  print("flags:")
  print("  --registry <url|dir>          set the registry for the command (overrides")
  print("                                the positional registry arg and $ROVER_REGISTRY)")
  print("")
  print("registry: a local directory, or a URL (http(s):// or file://)")
  print("          with <url>/index.json + <url>/<name>/<version>/init.lua.")
  print("          index.json may carry per-version sha256 (\"hashes\") that downloads")
  print("          are verified against, and a detached index.json.sig (HMAC-SHA256")
  print("          over the index, keyed by $ROVER_REGISTRY_KEY) is enforced when set.")
  print("          Default: --registry beats $ROVER_REGISTRY beats rover\\registry (a")
  print("          source checkout) beats the OFFICIAL CLua package registry:")
  print("          " .. OFFICIAL_REGISTRY)
  print("package authors: to get a package verified + listed in the official registry,")
  print("          open a Pull Request at https://github.com/kishimodo/CLua-Packages")
  print("          (submissions are reviewed and accepted or denied).")
  print("store: " .. STORE)
end
