-- run-differential.lua -- R2 differential test (JIT vs interpreter oracle).
--
-- Run by luavm.exe. The Makefile passes every tests/differential/*.lua path.
-- For each, this runs it through the JIT (luavm.exe <file>) AND the bytecode
-- interpreter (luavm.exe -i <file>), strips JIT/runtime trace noise, and
-- asserts identical output. A divergence is a JIT miscompilation. Exit 1 on
-- any mismatch.
--
-- This is the safety net that would have caught the tail-call and
-- metamethod-top miscompilations mechanically.

local LUAVM = "build\\bin\\luavm.exe"   -- backslashes: os/io route through cmd

local tests = {}
for i = 1, #(arg or {}) do tests[i] = arg[i] end
if #tests == 0 then
  print("[*] no differential corpus files -- nothing to run")
  os.exit(0)
end

-- Capture a command's combined stdout/stderr, with the JIT/runtime trace
-- lines removed so the two backends are comparable. Outer-quote wrap so
-- cmd /c does not mangle the leading-quoted command.
local function capture(cmd)
  local p = io.popen('"' .. cmd .. '" 2>&1')
  if not p then return nil end
  local out = p:read("*a") or ""
  p:close()
  local kept = {}
  for line in (out .. "\n"):gmatch("(.-)\r?\n") do
    if not line:match("^%[%*%] jit:") and not line:match("^%[%*%] runtime:") then
      kept[#kept + 1] = line
    end
  end
  return table.concat(kept, "\n")
end

local pass, fail = 0, 0
for _, path in ipairs(tests) do
  local name = path:match("([^/\\]+)%.lua$") or path
  local jit    = capture(LUAVM .. ' "' .. path .. '"')
  local interp = capture(LUAVM .. ' -i "' .. path .. '"')
  if jit == interp then
    pass = pass + 1
    print(string.format("[+] PASS %-16s (JIT == interpreter)", name))
  else
    fail = fail + 1
    print(string.format("[-] FAIL %-16s (JIT != interpreter)", name))
    -- show first differing line for diagnosis
    local jl, il = {}, {}
    for l in (jit .. "\n"):gmatch("(.-)\n") do jl[#jl + 1] = l end
    for l in (interp .. "\n"):gmatch("(.-)\n") do il[#il + 1] = l end
    for i = 1, math.max(#jl, #il) do
      if jl[i] ~= il[i] then
        print(string.format("    line %d:\n      JIT:    %s\n      interp: %s",
                            i, tostring(jl[i]), tostring(il[i])))
        break
      end
    end
  end
end

print("")
print(string.format("[*] differential: %d pass / %d fail", pass, fail))
os.exit(fail > 0 and 1 or 0)
