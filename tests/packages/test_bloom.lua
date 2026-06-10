-- tests/packages/test_bloom.lua : Bloom / counting-Bloom / cuckoo filter behavior.
-- Pure-Lua package, so we assert structural guarantees against known-correct
-- reference values rather than the code's own output:
--   * no false negatives (every inserted key tests present),
--   * plausible (low) false-positive rate on absent keys,
--   * to_string/from_string round-trips preserve membership,
--   * counting filter add/remove/count semantics,
--   * cuckoo add/contains/remove semantics.
local ok_req, bloom = pcall(require, "bloom")
if not ok_req then print("[~] SKIP test_bloom") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_bloom: " .. tostring(m)) end end

-- ===== Classic Bloom filter =====
do
  local bf = bloom.bloom({ expected_items = 1000, false_positive_rate = 0.01 })

  -- Insert a known set of keys.
  local inserted = {}
  for i = 1, 500 do inserted[i] = "key-" .. i end
  for _, k in ipairs(inserted) do bf:add(k) end

  -- No false negatives: every inserted key MUST test present.
  local all_present = true
  for _, k in ipairs(inserted) do
    if not bf:contains(k) then all_present = false break end
  end
  ok(all_present, "bloom: no false negatives on 500 inserted keys")

  -- size() counts distinct inserts (we inserted 500 distinct keys).
  ok(bf:size() == 500, "bloom: size() == 500 after 500 distinct adds")

  -- Plausible false-positive rate: probe 5000 keys never inserted.
  -- A correctly-sized 1% filter at half load should be well under 5% here.
  local fp = 0
  for i = 1, 5000 do
    if bf:contains("absent-" .. i) then fp = fp + 1 end
  end
  ok(fp / 5000 < 0.05, "bloom: false-positive rate plausibly low (" .. fp .. "/5000)")

  -- A key clearly not in a tiny test set should usually be absent: assert at
  -- least one absent key is reported absent (the filter is not all-ones).
  ok(bf:bit_count() < bf._m, "bloom: not all bits set (filter not saturated)")

  -- to_string / from_string round-trip preserves membership exactly.
  local blob = bf:to_string()
  ok(type(blob) == "string" and #blob > 0, "bloom: to_string returns non-empty string")
  local bf2 = bloom.bloom_from_string(blob)
  ok(bf2 ~= nil, "bloom: bloom_from_string decodes blob")
  if bf2 then
    ok(bf2:size() == bf:size(), "bloom: round-trip preserves size()")
    local rt_ok = true
    for _, k in ipairs(inserted) do
      if not bf2:contains(k) then rt_ok = false break end
    end
    ok(rt_ok, "bloom: round-trip preserves membership (no false negatives)")
    -- And preserves the exact bit set, so absent keys answer identically.
    local same = true
    for i = 1, 2000 do
      local key = "probe-" .. i
      if bf:contains(key) ~= bf2:contains(key) then same = false break end
    end
    ok(same, "bloom: round-trip answers identically for probe keys")
  end

  -- Instance :from_string mutates self to match a blob.
  local bf3 = bloom.bloom({ expected_items = 1000, false_positive_rate = 0.01 })
  local r = bf3:from_string(blob)
  ok(r == bf3, "bloom: :from_string returns self")
  ok(bf3:contains(inserted[1]) and bf3:contains(inserted[250]),
     "bloom: :from_string restores membership")
end

-- ===== Counting Bloom filter =====
do
  local cb = bloom.counting_bloom({ expected_items = 1000, false_positive_rate = 0.01 })
  for i = 1, 200 do cb:add("c-" .. i) end

  -- No false negatives.
  local all_present = true
  for i = 1, 200 do
    if not cb:contains("c-" .. i) then all_present = false break end
  end
  ok(all_present, "counting: no false negatives")

  ok(cb:size() == 200, "counting: size() == 200")

  -- count() is a lower-bound estimate; for a single-added key it should be >= 1.
  ok(cb:count("c-1") >= 1, "counting: count of present key >= 1")

  -- Remove a key: contains should reflect removal of its counters. With low
  -- load and k>1 the removed key is very likely fully absent afterwards.
  local removed = cb:remove("c-1")
  ok(removed == true, "counting: remove of present key returns true")
  ok(cb:size() == 199, "counting: size() decremented after remove")
  -- Removing an absent key returns false and does not change size.
  ok(cb:remove("never-added-xyz") == false, "counting: remove of absent key returns false")
  ok(cb:size() == 199, "counting: size() unchanged after no-op remove")

  -- The other 199 keys must still be present after one removal.
  local rest_ok = true
  for i = 2, 200 do
    if not cb:contains("c-" .. i) then rest_ok = false break end
  end
  ok(rest_ok, "counting: remaining keys still present after one remove")
end

-- ===== Cuckoo filter =====
do
  local ck = bloom.cuckoo({ capacity = 1024, bucket_size = 4 })
  ok(ck:capacity() == 1024 * 4, "cuckoo: capacity() == cap*bucket_size")

  -- Insert a moderate set (well under capacity).
  local added = {}
  local n_added = 0
  for i = 1, 500 do
    if ck:add("x-" .. i) then added[#added + 1] = "x-" .. i; n_added = n_added + 1 end
  end
  ok(n_added == 500, "cuckoo: all 500 inserts under capacity succeed")
  ok(ck:size() == 500, "cuckoo: size() == 500 after inserts")

  -- No false negatives for the keys that were actually added.
  local all_present = true
  for _, k in ipairs(added) do
    if not ck:contains(k) then all_present = false break end
  end
  ok(all_present, "cuckoo: no false negatives on inserted keys")

  -- Remove a present key, then it should be removable exactly once.
  ok(ck:remove("x-1") == true, "cuckoo: remove of present key returns true")
  ok(ck:size() == 499, "cuckoo: size() decremented after remove")
  ok(ck:remove("definitely-absent-key-9999") == false,
     "cuckoo: remove of absent key returns false")
end

if fails == 0 then print("[+] PASS test_bloom") os.exit(0) else os.exit(1) end
