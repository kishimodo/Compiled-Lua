-- tests/packages/test_secret.lua : constant-time compare, wipe, redact, buffers.
-- Fully deterministic: no addresses printed; redaction outputs are hand-verified.
local ok_req, secret = pcall(require, "secret")
if not ok_req then print("[~] SKIP test_secret (" .. tostring(secret) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_secret: " .. tostring(m)) end end
local function xfail(cond, desc, bug)
  if cond then print(("[!] XPASS test_secret: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
  else        print(("[x] XFAIL test_secret: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== constant-time equals / memcmp =====
ok(secret.equals("hunter2", "hunter2") == true, "equals: identical strings")
ok(secret.equals("hunter2", "hunter3") == false, "equals: same length differ")
ok(secret.equals("abc", "abcd") == false, "equals: different lengths")
ok(secret.equals("", "") == true, "equals: two empty strings")
ok(secret.equals("a", "") == false, "equals: one empty one not")
ok(secret.memcmp("token", "token") == true, "memcmp alias matches equals")
-- non-string args error.
ok(pcall(secret.equals, "x", 5) == false, "equals errors on non-string arg")
ok(pcall(secret.equals, nil, "x") == false, "equals errors on nil arg")

-- ===== buffers =====
local buf, n = secret.bytes_to_buffer("ABCD")
ok(n == 4, "bytes_to_buffer reports length")
ok(buf[0] == 65 and buf[1] == 66 and buf[2] == 67 and buf[3] == 68, "bytes_to_buffer copies bytes")
ok(pcall(secret.bytes_to_buffer, 123) == false, "bytes_to_buffer errors on non-string")

local nb = secret.new_buffer(8)
-- ffi.sizeof() now reports the allocated length of a variable-length-array
-- cdata (it reads the instance's element count, not the type's zero size).
nb[0] = 1; nb[7] = 9
ok(nb[0] == 1 and nb[7] == 9, "new_buffer is writable across requested length")
ok(ffi.sizeof(nb) == 8, "ffi.sizeof reports the VLA buffer length")
ok(pcall(secret.new_buffer, 0) == false, "new_buffer rejects size 0")
ok(pcall(secret.new_buffer, -3) == false, "new_buffer rejects negative size")

-- ===== wipe =====
local wb = secret.bytes_to_buffer("SECRET")
secret.wipe(wb, 6)
local all_zero = true
for i = 0, 5 do if wb[i] ~= 0 then all_zero = false end end
ok(all_zero == true, "wipe zeroes the whole buffer")
-- wipe defaults n to ffi.sizeof(buf) when omitted. ffi.sizeof now reports the
-- real length of a variable-length buffer (new_buffer / bytes_to_buffer), so
-- the documented default works (SECRET-WIPE-DEFAULTLEN-001 fixed).
local wb2 = secret.new_buffer(4)
wb2[0] = 9; wb2[1] = 9; wb2[2] = 9; wb2[3] = 9
secret.wipe(wb2)
ok(wb2[0] == 0 and wb2[3] == 0,
   "wipe(buf) with no explicit length zeroes the buffer (sizeof default)")
-- explicit length always works:
local wb3 = secret.new_buffer(4)
wb3[0] = 9; wb3[1] = 9; wb3[2] = 9; wb3[3] = 9
secret.wipe(wb3, 4)
ok(wb3[0] == 0 and wb3[3] == 0, "wipe with explicit n zeroes the buffer")
-- wiping a Lua string is an explicit error (strings are immutable).
ok(pcall(secret.wipe, "cannot wipe me") == false, "wipe errors on a Lua string")
-- wipe(nil) is a no-op (no error).
ok(pcall(secret.wipe, nil) == true, "wipe(nil) is a safe no-op")

-- ===== redact: string masking form (keep_first / keep_last numbers) =====
ok(secret.redact("abcdef", 1, 1) == "a****f", "redact keep 1/1 masks middle")
ok(secret.redact("abcd", 0, 0) == "****", "redact 0/0 masks all")
ok(secret.redact("", 1, 1) == "", "redact of empty string is empty")
-- keep_first + keep_last >= len => fully starred.
ok(secret.redact("ab", 2, 2) == "**", "redact masks all when keeps exceed length")
-- long middle is capped: "ab" + 8 stars + "(+N)" + "yz" where middle=30-4=26.
local long = "ab" .. string.rep("X", 26) .. "yz"  -- len 30
ok(secret.redact(long, 2, 2) == "ab********(+18)yz", "redact caps long middle and reports remainder")

-- ===== redact: wrapper form =====
local r = secret.redact("topsecret")
ok(tostring(r) == "<redacted>", "wrapper tostring hides the value")
ok(("leak=" .. r) == "leak=<redacted>", "wrapper __concat hides on the right")
ok((r .. "!") == "<redacted>!", "wrapper __concat hides on the left")
ok(r:reveal() == "topsecret", "reveal() returns the original value")
-- custom label.
local rl = secret.redact("pw", "***hidden***")
ok(tostring(rl) == "***hidden***", "wrapper accepts a custom label")
ok(rl:reveal() == "pw", "custom-label wrapper still reveals value")
-- wraps non-string values too.
local rn = secret.redact(42)
ok(tostring(rn) == "<redacted>" and rn:reveal() == 42, "wrapper can hold a number")
-- masked() convenience renders partial reveal of the wrapped string.
local rm = secret.redact("abcdef")
ok(rm:masked(1, 1) == "a****f", "wrapper :masked produces partial reveal")

if fails == 0 then print("[+] PASS test_secret") os.exit(0) else os.exit(1) end
