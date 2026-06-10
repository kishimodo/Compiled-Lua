-- tests/packages/test_tracing.lua : OpenTelemetry-style tracing.
-- Determinism trap: trace/span IDs come from math.random and timestamps from
-- os.time/os.clock -- NEVER assert those values. We assert: deterministic
-- samplers, W3C traceparent propagate/extract using a HAND-BUILT fixed context,
-- span attribute/event/status structure, and exporter selection logic.
local ok_req, tracing = pcall(require, "tracing")
if not ok_req then print("[~] SKIP test_tracing (" .. tostring(tracing) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_tracing: " .. tostring(m)) end end

-- ---- Samplers ----
ok(tracing.sampler.always()() == true,  "sampler.always returns true")
ok(tracing.sampler.never()()  == false, "sampler.never returns false")
-- ratio(1) -> always sampled; ratio(0) -> never sampled (boundary, deterministic).
ok(tracing.sampler.ratio(1)() == true,  "sampler.ratio(1) always samples")
ok(tracing.sampler.ratio(0)() == false, "sampler.ratio(0) never samples")
-- parent_or honors a present parent decision (deterministic).
local po = tracing.sampler.parent_or(0)
ok(po({ parent = { sampled = true } })  == true,  "parent_or honors parent sampled=true")
ok(po({ parent = { sampled = false } }) == false, "parent_or honors parent sampled=false")

-- ---- W3C propagate/extract round-trip with a FIXED context ----
local ctx = {
    trace_id = "0af7651916cd43dd8448eb211c80319c",  -- 32 hex chars
    span_id  = "b7ad6b7169203331",                  -- 16 hex chars
    sampled  = true,
}
local headers = tracing.propagate({}, ctx)
ok(headers.traceparent == "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
   "propagate builds the exact traceparent header")

local back = tracing.extract(headers)
ok(back ~= nil,                                    "extract parses the traceparent")
ok(back.trace_id == ctx.trace_id,                  "extract recovers trace_id")
ok(back.span_id  == ctx.span_id,                   "extract recovers span_id")
ok(back.sampled  == true,                          "extract recovers sampled=true")

-- Unsampled flag round-trips as 00.
local ctx0 = { trace_id = ctx.trace_id, span_id = ctx.span_id, sampled = false }
local h0 = tracing.propagate({}, ctx0)
ok(h0.traceparent:sub(-2) == "00",                 "unsampled flag renders as 00")
ok(tracing.extract(h0).sampled == false,           "extract recovers sampled=false")

-- extract rejects malformed / wrong-length headers.
ok(tracing.extract({}) == nil,                     "extract returns nil with no traceparent")
ok(tracing.extract({ traceparent = "garbage" }) == nil, "extract rejects a non-matching header")
ok(tracing.extract({ traceparent = "00-tooshort-b7ad6b7169203331-01" }) == nil,
   "extract rejects a short trace_id")
-- Case-insensitive header key (Traceparent).
ok(tracing.extract({ Traceparent = headers.traceparent }) ~= nil,
   "extract accepts the capitalized Traceparent header")

-- ---- Span behavior via a provider with a capturing exporter ----
local captured = {}
local exporter = {
    export = function(_self, spans)
        for i = 1, #spans do captured[#captured + 1] = spans[i] end
    end,
    shutdown = function() end,
}
local provider = tracing.provider({ exporter = exporter, sampler = tracing.sampler.always() })
local tracer = tracing.tracer("svc", { provider = provider })

local span = tracer:start("op", { attributes = { initial = "x" } })
ok(#span.trace_id == 32, "generated trace_id is 32 hex chars")
ok(#span.span_id == 16,  "generated span_id is 16 hex chars")
span:set_attribute("http.method", "GET")
ok(span.attributes["http.method"] == "GET", "set_attribute stores the value")
ok(span.attributes.initial == "x",          "initial attributes are preserved")
span:add_event("cache.miss", { key = "k1" })
ok(#span.events == 1 and span.events[1].name == "cache.miss", "add_event appends a named event")
ok(span.events[1].attrs.key == "k1",        "event carries its attrs")
span:set_status("ok")
ok(span.status.code == "ok",                "set_status records the status code")
span:end_()
ok(#captured == 1,                          "ending a sampled span exports it once")
ok(captured[1].name == "op",                "exported span carries its name")
-- Double-end is a no-op (guarded by end_ns).
span:end_()
ok(#captured == 1,                          "double end_ does not re-export")

-- ---- Child span inherits the parent trace_id ----
local parent = tracer:start("parent")
local child = tracer:start("child", { parent = parent })
ok(child.trace_id == parent.trace_id,       "child span inherits the parent trace_id")
ok(child.parent_span_id == parent.span_id,  "child records the parent span_id")
ok(child.span_id ~= parent.span_id,         "child gets a fresh span_id")

-- ---- never() sampler drops spans on end ----
local dropped = {}
local prov2 = tracing.provider({
    exporter = { export = function(_s, sp) for i = 1, #sp do dropped[#dropped + 1] = sp[i] end end,
                 shutdown = function() end },
    sampler  = tracing.sampler.never(),
})
local t2 = tracing.tracer("svc2", { provider = prov2 })
t2:start("unsampled"):end_()
ok(#dropped == 0, "an unsampled span is not exported")

-- ---- with_span: runs fn, ends the span, returns the result ----
local result = tracing.with_span("work", function(sp)
    sp:set_attribute("phase", "compute")
    return 42
end, { tracer = tracer })
ok(result == 42, "with_span returns the body's result")

-- with_span propagates errors after ending the span.
ok(not pcall(function()
    tracing.with_span("boom", function() error("kaboom") end, { tracer = tracer })
end), "with_span re-raises an error from the body")

-- ---- Exporter constructors exist and yield export()able objects ----
ok(type(tracing.exporter.stdout_json().export) == "function", "stdout_json exporter has export()")
ok(type(tracing.exporter.otlp_http("http://localhost/v1/traces").export) == "function",
   "otlp_http exporter has export()")

if fails == 0 then print("[+] PASS test_tracing") os.exit(0) else os.exit(1) end
