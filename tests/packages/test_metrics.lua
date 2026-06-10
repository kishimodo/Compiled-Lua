local ok_req, metrics = pcall(require, "metrics")
if not ok_req then print("[~] SKIP test_metrics") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_metrics: " .. tostring(m)) end end

-- ===== Counter ==========================================================
-- inc()/add() arithmetic and the no-labels series.
local c = metrics.counter("http_requests_total")
ok(c:value() == 0, "fresh counter starts at 0")
c:inc()
ok(c:value() == 1, "bare inc() bumps by 1")
c:inc(4)
ok(c:value() == 5, "inc(4) -> 5")
c:add(2.5)
ok(c:value() == 7.5, "add(2.5) -> 7.5 (add aliases inc)")
-- Counters must never decrease: negative inc is an error.
ok(not pcall(function() c:inc(-1) end), "inc(-1) errors (counters can't go down)")
ok(c:value() == 7.5, "failed inc(-1) left value unchanged")

-- Counter labels: each label set is its own series.
local cl = metrics.counter("by_method", { labels = { "method" } })
cl:labels({ method = "GET" }):inc(3)
cl:labels({ method = "POST" }):inc(1)
ok(cl:value({ method = "GET" }) == 3, "labelled counter GET = 3")
ok(cl:value({ method = "POST" }) == 1, "labelled counter POST = 1")
-- A second :labels() call returns a view over the SAME series.
ok(cl:labels({ method = "GET" }):value() == 3, "re-resolved label view sees prior value")

-- ===== Gauge ============================================================
local g = metrics.gauge("inflight")
g:set(10)
ok(g:value() == 10, "gauge set(10)")
g:inc(5)
ok(g:value() == 15, "gauge inc(5) -> 15")
g:dec(20)
ok(g:value() == -5, "gauge dec(20) -> -5 (gauges may go negative)")
g:dec()
ok(g:value() == -6, "bare gauge dec() -> -6")

-- ===== Histogram ========================================================
-- Use explicit buckets so cumulative counts are fully determined.
local h = metrics.histogram("latency", { buckets = { 1, 2, 5 } })
for _, v in ipairs({ 0.5, 1, 2, 3, 10 }) do h:observe(v) end
-- Reach into the no-labels series to assert exact cumulative bucket counts.
local hs = h._series[""]
ok(hs ~= nil, "histogram no-labels series exists after observe")
ok(hs.count == 5, "histogram total count = 5")
ok(hs.sum == 16.5, "histogram sum = 0.5+1+2+3+10 = 16.5")
-- Cumulative: <=1 -> {0.5,1} = 2 ; <=2 -> +{2} = 3 ; <=5 -> +{3} = 4 ; 10 in none.
ok(hs.counts[1] == 2, "bucket le=1 cumulative count = 2")
ok(hs.counts[2] == 3, "bucket le=2 cumulative count = 3")
ok(hs.counts[3] == 4, "bucket le=5 cumulative count = 4")

-- ===== Summary ==========================================================
-- With a reservoir larger than the sample count, no sampling occurs, so the
-- reservoir holds every value and quantiles are exact (ceil(q*n) index).
local s = metrics.summary("svc_latency", { reservoir = 100 })
for i = 1, 10 do s:observe(i) end  -- values 1..10
ok(s._series[""].count == 10, "summary count = 10")
ok(s._series[""].sum == 55, "summary sum 1..10 = 55")
-- median: ceil(0.5*10)=5 -> sorted[5] = 5
ok(s:quantile(0.5) == 5, "summary q0.5 of 1..10 = 5")
-- p90: ceil(0.9*10)=9 -> sorted[9] = 9
ok(s:quantile(0.9) == 9, "summary q0.9 of 1..10 = 9")
-- p99 clamps to last index: ceil(0.99*10)=10 -> sorted[10] = 10
ok(s:quantile(0.99) == 10, "summary q0.99 of 1..10 = 10")
-- q=1.0 -> max ; q small -> min (clamped to index >= 1)
ok(s:quantile(1.0) == 10, "summary q1.0 = max = 10")
ok(s:quantile(0.0) == 1, "summary q0.0 clamps to min = 1")

-- ===== Registry =========================================================
-- Use an isolated registry so we don't depend on default-registry state.
local reg = metrics.registry()
local rc = metrics.counter("reg_counter")
reg:register(rc)
ok(#reg:gather() == 1, "registry has 1 metric after register")
-- Duplicate names are rejected loudly.
ok(not pcall(function() reg:register(metrics.counter("reg_counter")) end),
   "registering a duplicate name errors")
ok(#reg:gather() == 1, "duplicate register did not add a second entry")
-- unregister removes by name; returns true/false.
ok(reg:register(metrics.gauge("reg_gauge")) ~= nil, "second distinct metric registers")
ok(#reg:gather() == 2, "registry now has 2 metrics")
ok(reg:unregister("reg_counter") == true, "unregister existing returns true")
ok(reg:unregister("nope") == false, "unregister missing returns false")
ok(#reg:gather() == 1, "registry back to 1 after unregister")

-- Default-registry round trip: register -> gather -> reset clears it.
metrics.reset()
ok(#metrics.gather() == 0, "default registry empty after reset")
metrics.register(metrics.counter("default_c"))
ok(#metrics.gather() == 1, "default registry has 1 after register")
metrics.reset()
ok(#metrics.gather() == 0, "reset clears default registry again")

-- ===== Prometheus exposition format =====================================
local preg = metrics.registry()
local pc = metrics.counter("requests")
pc:inc(7)
preg:register(pc)
local text = metrics.prom_format(preg)
ok(text:find("# HELP requests", 1, true) ~= nil, "prom_format emits HELP line")
ok(text:find("# TYPE requests counter", 1, true) ~= nil, "prom_format emits TYPE counter")
ok(text:find("\nrequests 7\n", 1, true) ~= nil, "prom_format emits 'requests 7' sample line")

-- Histogram prom output: _bucket{le=...}, _sum, _count, and +Inf bucket.
local hreg = metrics.registry()
local ph = metrics.histogram("ph", { buckets = { 1, 2 } })
ph:observe(0.5); ph:observe(1.5); ph:observe(3)  -- sum 5, count 3
hreg:register(ph)
local htext = metrics.prom_format(hreg)
ok(htext:find('ph_bucket{le="1"} 1', 1, true) ~= nil, "hist le=1 bucket = 1 (only 0.5)")
ok(htext:find('ph_bucket{le="2"} 2', 1, true) ~= nil, "hist le=2 bucket = 2 (0.5,1.5)")
ok(htext:find('ph_bucket{le="+Inf"} 3', 1, true) ~= nil, "hist +Inf bucket = total count 3")
ok(htext:find('ph_sum 5', 1, true) ~= nil, "hist _sum = 5")
ok(htext:find('ph_count 3', 1, true) ~= nil, "hist _count = 3")

-- ===== StatsD line format ===============================================
local sreg = metrics.registry()
local sc = metrics.counter("hits", { labels = { "host" } })
sc:labels({ host = "a" }):inc(2)
local sg = metrics.gauge("temp")
sg:set(42)
sreg:register(sc)
sreg:register(sg)
local lines = metrics.statsd_lines(sreg)
local joined = table.concat(lines, "\n")
ok(joined:find("hits:2|c|#host:a", 1, true) ~= nil, "statsd counter line w/ tag")
ok(joined:find("temp:42|g", 1, true) ~= nil, "statsd gauge line")

if fails == 0 then print("[+] PASS test_metrics") os.exit(0) else os.exit(1) end
