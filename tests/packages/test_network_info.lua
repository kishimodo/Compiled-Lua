-- tests/packages/test_network_info.lua : adapter / routing / ARP enumeration.
-- Determinism: MACs, IPs, gateways and table sizes vary per host, so we assert
-- structural invariants and enum membership rather than fixed values.
--
-- NET-FFINEW-001 (ffi.new array-with-initializer rejected) is FIXED as of
-- 2026-06-09: hostname/domain_name/adapters/dns_servers/default_gateway are
-- asserted unconditionally below.
--
-- NET-ROUTE-002 is FIXED: the MIB_IPFORWARD_ROW2 / SOCKADDR_INET cdefs are now
-- byte-exact with the platform ABI (SOCKADDR_INET forced to size 28 / align 4,
-- and the four route booleans are 1-byte BOOLEAN, not 4-byte BOOL). The row
-- stride matches, so every Table[i] decodes correctly and prefix_length is in
-- range; the value-correctness probe is asserted unconditionally below.
local ok_req, ni = pcall(require, "network_info")
if not ok_req then
    print("[~] SKIP test_network_info (" .. tostring(ni) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_network_info: " .. tostring(m)) end end
local function xfail(cond, desc, bug)
    if cond then print(("[!] XPASS test_network_info: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
    else        print(("[x] XFAIL test_network_info: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== API surface =========================================================
ok(type(ni.adapters) == "function",         "adapters is a function")
ok(type(ni.interfaces) == "function",       "interfaces is a function")
ok(ni.interfaces == ni.adapters,            "interfaces aliases adapters")
ok(type(ni.default_gateway) == "function",  "default_gateway is a function")
ok(type(ni.dns_servers) == "function",      "dns_servers is a function")
ok(type(ni.routing_table) == "function",    "routing_table is a function")
ok(type(ni.arp_table) == "function",        "arp_table is a function")
ok(type(ni.hostname) == "function",         "hostname is a function")
ok(type(ni.domain_name) == "function",      "domain_name is a function")

-- ===== routing_table: runs (no array-init ffi.new), shape is correct =======
local rt = ni.routing_table()
ok(type(rt) == "table",                     "routing_table() returns a table")
ok(#rt >= 1,                                "routing table has at least one entry")
-- TYPE-level shape holds even though values are garbage (NET-ROUTE-002).
local rt_shape_ok = true
local prefix_in_range = true
for _, r in ipairs(rt) do
    if r.family ~= "ipv4" and r.family ~= "ipv6" then rt_shape_ok = false end
    if type(r.metric) ~= "number" then rt_shape_ok = false end
    if type(r.interface) ~= "number" then rt_shape_ok = false end
    if type(r.prefix_length) ~= "number" then rt_shape_ok = false end
    if r.mask ~= nil and r.mask:match("^%d+%.%d+%.%d+%.%d+$") == nil then rt_shape_ok = false end
    -- value-correctness probe for the XFAIL below:
    local lim = (r.family == "ipv4") and 32 or 128
    if r.prefix_length < 0 or r.prefix_length > lim then prefix_in_range = false end
end
ok(rt_shape_ok,                             "routing rows have correct field TYPES")
-- The pure dotted-quad mask conversion: where a /N produced a mask, it must be
-- the canonical mask. (This holds regardless of whether prefix decode is sane.)
local mask_conv_ok = true
local MASKS = { [0]="0.0.0.0", [8]="255.0.0.0", [16]="255.255.0.0",
                [24]="255.255.255.0", [32]="255.255.255.255" }
for _, r in ipairs(rt) do
    if r.family == "ipv4" and r.mask and MASKS[r.prefix_length] then
        if r.mask ~= MASKS[r.prefix_length] then mask_conv_ok = false end
    end
end
ok(mask_conv_ok,                            "ipv4 prefix->mask conversion is canonical")
ok(prefix_in_range, "every route prefix_length is in valid range (struct decode, NET-ROUTE-002)")

-- ===== arp_table: runs, shape correct ======================================
local arp = ni.arp_table()
ok(type(arp) == "table",                    "arp_table() returns a table")
local arp_states = { unreachable=true, incomplete=true, probe=true, delay=true,
                     stale=true, reachable=true, permanent=true, unknown=true }
local arp_shape_ok = true
for _, e in ipairs(arp) do
    if e.family ~= "ipv4" and e.family ~= "ipv6" then arp_shape_ok = false end
    if not arp_states[e.state] then arp_shape_ok = false end
    if type(e.interface) ~= "number" then arp_shape_ok = false end
    if e.mac ~= nil and e.mac:match("^%x%x") == nil then arp_shape_ok = false end
end
ok(arp_shape_ok,                            "arp rows have valid family/state/interface/mac TYPES")

-- ===== hostname / adapters (NET-FFINEW-001 fixed 2026-06-09) ===============
local hn_ok, hn = pcall(ni.hostname)
ok(hn_ok and type(hn) == "string" and #hn >= 1,
   "hostname() returns non-empty string (regression NET-FFINEW-001)")

local dn_ok = pcall(ni.domain_name)
ok(dn_ok, "domain_name() does not throw (regression NET-FFINEW-001)")

local ad_ok, adapters = pcall(ni.adapters)
ok(ad_ok and type(adapters) == "table" and #adapters >= 1,
   "adapters() returns a non-empty table (regression NET-FFINEW-001)")

local dns_ok = pcall(ni.dns_servers)
ok(dns_ok, "dns_servers() does not throw (regression NET-FFINEW-001)")

local gw_ok = pcall(ni.default_gateway)
ok(gw_ok, "default_gateway() does not throw (regression NET-FFINEW-001)")

if fails == 0 then print("[+] PASS test_network_info") os.exit(0) else os.exit(1) end
