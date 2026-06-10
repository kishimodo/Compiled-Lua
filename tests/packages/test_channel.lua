-- tests/packages/test_channel.lua : in-process channel send/receive + the
-- value serializer that powers cross-thread transport.
-- All tests are single-threaded (no real cross-thread hand-off needed):
-- a bounded channel with spare capacity accepts a send and a subsequent
-- receive returns it. Deterministic: no time/random, values fixed.
local ok_req, channel = pcall(require, "channel")
if not ok_req then
    print("[~] SKIP test_channel (" .. tostring(channel) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m)
    if not c then fails = fails + 1; print("[-] FAIL test_channel: " .. tostring(m)) end
end

-- ===== serialize / deserialize round trips =====
local function roundtrip(v) return channel.deserialize(channel.serialize(v)) end
ok(roundtrip(nil) == nil, "serialize nil")
ok(roundtrip(true) == true, "serialize true")
ok(roundtrip(false) == false, "serialize false")
ok(roundtrip(0) == 0, "serialize 0")
ok(roundtrip(-12345) == -12345, "serialize negative int")
ok(roundtrip(2147483648) == 2147483648, "serialize > int32")
ok(roundtrip(3.5) == 3.5, "serialize float")
ok(roundtrip("") == "", "serialize empty string")
ok(roundtrip("hello world") == "hello world", "serialize string")
ok(roundtrip("a\0b") == "a\0b", "serialize string with NUL")

-- integer vs float type preserved
local ri = roundtrip(7)
ok(math.type(ri) == "integer", "integer stays integer")
local rf = roundtrip(7.0)
ok(math.type(rf) == "float", "float stays float")

-- table round trip (array + hash)
local t = roundtrip({ 1, 2, 3, name = "x", nested = { 9 } })
ok(t[1] == 1 and t[2] == 2 and t[3] == 3, "table array part")
ok(t.name == "x", "table hash string field")
ok(t.nested[1] == 9, "table nested array")

-- cycle is preserved via back-ref
local cyc = { v = 5 }
cyc.me = cyc
local rc = roundtrip(cyc)
ok(rc.v == 5, "cyclic table value")
ok(rc.me == rc, "cyclic back-ref resolves to same table")

-- unsupported types raise on serialize
ok(not pcall(channel.serialize, print), "serialize function raises")
ok(not pcall(channel.serialize, coroutine.create(function() end)), "serialize coroutine raises")

-- ===== channel object basics =====
local ch = channel.make(4)
ok(ch:capacity() == 4, "bounded capacity 4")
ok(ch:len() == 0, "empty len 0")
ok(ch:is_closed() == false, "not closed initially")

ok(ch:try_send(10) == true, "try_send accepted")
ok(ch:try_send(20) == true, "try_send second")
ok(ch:len() == 2, "len 2 after two sends")

local v1, ok1 = ch:try_receive()
ok(ok1 == true and v1 == 10, "FIFO receive first value")
local v2, ok2 = ch:try_receive()
ok(ok2 == true and v2 == 20, "FIFO receive second value")
ok(ch:len() == 0, "len 0 after draining")

-- try_receive on empty returns nil,false
local ve, oke = ch:try_receive()
ok(ve == nil and oke == false, "try_receive empty -> nil,false")

-- bounded full rejects try_send
local small = channel.make(2)
ok(small:try_send("a") == true, "fill 1")
ok(small:try_send("b") == true, "fill 2")
ok(small:try_send("c") == false, "try_send rejected when full")
ok(small:len() == 2, "len capped at capacity")

-- send/receive blocking variants succeed when room/data available
local sb = channel.make(2)
ok(sb:send("p") == true, "send returns true with room")
local rv, rok = sb:receive(1000)
ok(rok == true and rv == "p", "receive returns sent value")

-- receive timeout when empty: returns nil,false,"timeout"
local empty = channel.make(1)
local tv, tok, terr = empty:receive(0)
ok(tv == nil and tok == false, "receive timeout nil,false")
ok(terr == "timeout", "receive timeout reports 'timeout'")

-- unbounded channel: capacity is math.huge, accepts many
local ub = channel.make()
ok(ub:capacity() == math.huge, "unbounded capacity huge")
for i = 1, 50 do ub:send(i) end
ok(ub:len() == 50, "unbounded accepts 50")
local sum = 0
for i = 1, 50 do
    local v = ub:receive()
    sum = sum + v
end
ok(sum == 1275, "unbounded FIFO drain sum 1..50")

-- close: subsequent send fails, receive on empty closed -> nil,false
local cc = channel.make(2)
cc:send("x")
cc:close()
ok(cc:is_closed() == true, "closed flag set")
local cs_ok = cc:send("y")
ok(cs_ok == false, "send on closed returns false")
-- remaining buffered item still drains
local lv, lok = cc:receive()
ok(lok == true and lv == "x", "buffered value drains after close")
local nv, nok = cc:receive()
ok(nv == nil and nok == false, "receive on drained+closed -> nil,false")

-- iter() drains until closed
local it = channel.make(8)
it:send(1); it:send(2); it:send(3)
it:close()
local itsum, itn = 0, 0
for v in it:iter() do itsum = itsum + v; itn = itn + 1 end
ok(itn == 3 and itsum == 6, "iter drains all values")

-- channel.select with default fires default when nothing ready
local sel_ch = channel.make(1)
local idx, val = channel.select({
    { sel_ch, "receive" },
    default = function() return "def" end,
})
ok(idx == 0 and val == "def", "select default fires when not ready")

-- channel.select picks a ready receive branch
local rdy = channel.make(1)
rdy:send(99)
local sidx, sval = channel.select({
    { rdy, "receive" },
    default = function() return "no" end,
})
ok(sidx == 1 and sval == 99, "select receives ready value")

if fails == 0 then print("[+] PASS test_channel") os.exit(0) else os.exit(1) end
