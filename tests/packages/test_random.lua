local random = require "random"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_random: " .. tostring(m)) end end

-- Regression for the unbiased_range modulo-bias bug: with the broken signed
-- limit/comparison, range(1,N) rejected nearly everything and never produced a
-- full, in-range, uniform spread. Assert the invariants for both the seeded
-- (xoshiro256**) convenience path and the default CSPRNG path.

-- Helper: draw many range(1,N) values; assert each is an integer in [1,N] and
-- that the whole set [1,N] is covered over enough draws.
local function check_range(N, draws)
  local seen = {}
  for _ = 1, draws do
    local v = random.int(1, N)
    ok(math.type(v) == "integer", "int(1," .. N .. ") returned non-integer " .. tostring(v))
    ok(v >= 1 and v <= N, "int(1," .. N .. ") out of range: " .. tostring(v))
    seen[v] = true
  end
  local covered = 0
  for k = 1, N do if seen[k] then covered = covered + 1 end end
  ok(covered == N, "int(1," .. N .. ") did not cover [1," .. N .. "]: covered " .. covered)
end

-- Seeded deterministic path (random.seed switches helpers onto xoshiro256**).
random.seed(0xC0FFEE)
check_range(1, 100)
check_range(3, 30000)
check_range(6, 30000)

-- A non-power-of-two span (5) exercises the rejection threshold most.
check_range(5, 30000)

-- choice stays in range over many draws.
do
  local t = { "a", "b", "c", "d", "e" }
  local lookup = {}
  for _, x in ipairs(t) do lookup[x] = true end
  for _ = 1, 2000 do
    ok(lookup[random.choice(t)] == true, "choice returned a non-member")
  end
end

-- shuffle yields a permutation of the input (in place) every time.
do
  for _ = 1, 200 do
    local arr = {}
    for i = 1, 12 do arr[i] = i end
    local ret = random.shuffle(arr)
    ok(ret == arr, "shuffle did not return the same table")
    ok(#arr == 12, "shuffle changed length")
    local mark = {}
    for _, v in ipairs(arr) do mark[v] = (mark[v] or 0) + 1 end
    local perm = true
    for i = 1, 12 do if mark[i] ~= 1 then perm = false end end
    ok(perm, "shuffle is not a permutation")
  end
end

-- Object-level :range from an explicit PRNG instance honours the same bound.
do
  local rng = random.prng("splitmix64", 42)
  for _ = 1, 5000 do
    local v = rng:range(1, 6)
    ok(v >= 1 and v <= 6, "prng:range(1,6) out of range: " .. tostring(v))
  end
end

-- Default CSPRNG path (no seed): same in-range + coverage invariants.
random.seed(nil)
check_range(6, 30000)

if fails == 0 then print("[+] PASS test_random") os.exit(0) else os.exit(1) end
