local ok_req, useragent = pcall(require, "useragent")
if not ok_req then print("[~] SKIP test_useragent") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_useragent: " .. tostring(m)) end end

-- Known-correct reference UA strings parsed against expected fields.

-- ---- Chrome on Windows 10 (desktop) ------------------------------------
local chrome = useragent.parse(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ..
  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
ok(chrome.browser.name == "Chrome", "chrome browser.name=" .. tostring(chrome.browser.name))
ok(chrome.browser.version == "120.0.0.0", "chrome browser.version=" .. tostring(chrome.browser.version))
ok(chrome.engine.name == "Blink", "chrome engine.name=" .. tostring(chrome.engine.name))
ok(chrome.engine.version == "537.36", "chrome engine.version=" .. tostring(chrome.engine.version))
ok(chrome.os.name == "Windows", "chrome os.name=" .. tostring(chrome.os.name))
ok(chrome.os.version == "10", "chrome os.version=" .. tostring(chrome.os.version))
ok(chrome.device.type == "desktop", "chrome device.type=" .. tostring(chrome.device.type))
ok(chrome.is_bot == false, "chrome is_bot=" .. tostring(chrome.is_bot))
ok(chrome.is_mobile == false, "chrome is_mobile=" .. tostring(chrome.is_mobile))

-- ---- Firefox on Windows 10 (desktop) -----------------------------------
local ff = useragent.parse(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0")
ok(ff.browser.name == "Firefox", "firefox browser.name=" .. tostring(ff.browser.name))
ok(ff.browser.version == "121.0", "firefox browser.version=" .. tostring(ff.browser.version))
ok(ff.engine.name == "Gecko", "firefox engine.name=" .. tostring(ff.engine.name))
ok(ff.engine.version == "20100101", "firefox engine.version=" .. tostring(ff.engine.version))
ok(ff.os.name == "Windows", "firefox os.name=" .. tostring(ff.os.name))
ok(ff.os.version == "10", "firefox os.version=" .. tostring(ff.os.version))
ok(ff.is_bot == false, "firefox is_bot=" .. tostring(ff.is_bot))

-- ---- Safari on macOS (desktop) -----------------------------------------
local saf = useragent.parse(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " ..
  "(KHTML, like Gecko) Version/17.1 Safari/605.1.15")
ok(saf.browser.name == "Safari", "safari browser.name=" .. tostring(saf.browser.name))
ok(saf.browser.version == "17.1", "safari browser.version=" .. tostring(saf.browser.version))
ok(saf.engine.name == "WebKit", "safari engine.name=" .. tostring(saf.engine.name))
ok(saf.engine.version == "605.1.15", "safari engine.version=" .. tostring(saf.engine.version))
ok(saf.os.name == "macOS", "safari os.name=" .. tostring(saf.os.name))
ok(saf.os.version == "10.15.7", "safari os.version=" .. tostring(saf.os.version))
ok(saf.is_bot == false, "safari is_bot=" .. tostring(saf.is_bot))

-- ---- Edge must win over Chrome substring (rule order) -------------------
local edge = useragent.parse(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ..
  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.2210.91")
ok(edge.browser.name == "Edge", "edge browser.name=" .. tostring(edge.browser.name))
ok(edge.browser.version == "120.0.2210.91", "edge browser.version=" .. tostring(edge.browser.version))
ok(edge.engine.name == "Blink", "edge engine.name=" .. tostring(edge.engine.name))

-- ---- Chrome on Android phone (mobile) ----------------------------------
local andr = useragent.parse(
  "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " ..
  "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
ok(andr.browser.name == "Chrome", "android browser.name=" .. tostring(andr.browser.name))
ok(andr.os.name == "Android", "android os.name=" .. tostring(andr.os.name))
ok(andr.os.version == "13", "android os.version=" .. tostring(andr.os.version))
ok(andr.device.type == "mobile", "android device.type=" .. tostring(andr.device.type))
ok(andr.device.vendor == "Google", "android device.vendor=" .. tostring(andr.device.vendor))
ok(andr.is_mobile == true, "android is_mobile=" .. tostring(andr.is_mobile))
ok(useragent.is_mobile(
  "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " ..
  "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36") == true, "is_mobile(android)")

-- ---- Safari on iPhone (mobile) -----------------------------------------
local iph = useragent.parse(
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 " ..
  "(KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1")
ok(iph.browser.name == "Mobile Safari", "iphone browser.name=" .. tostring(iph.browser.name))
ok(iph.os.name == "iOS", "iphone os.name=" .. tostring(iph.os.name))
ok(iph.os.version == "17.1", "iphone os.version=" .. tostring(iph.os.version))
ok(iph.device.vendor == "Apple", "iphone device.vendor=" .. tostring(iph.device.vendor))
ok(iph.device.model == "iPhone", "iphone device.model=" .. tostring(iph.device.model))
ok(iph.is_mobile == true, "iphone is_mobile=" .. tostring(iph.is_mobile))

-- ---- iPad is a tablet ---------------------------------------------------
local ipad = useragent.parse(
  "Mozilla/5.0 (iPad; CPU OS 17_1 like Mac OS X) AppleWebKit/605.1.15 " ..
  "(KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1")
ok(ipad.os.name == "iOS", "ipad os.name=" .. tostring(ipad.os.name))
ok(ipad.device.type == "tablet", "ipad device.type=" .. tostring(ipad.device.type))
ok(ipad.is_mobile == true, "ipad is_mobile (tablet counts)=" .. tostring(ipad.is_mobile))

-- ---- Googlebot (bot) ----------------------------------------------------
local gbot = useragent.parse(
  "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)")
ok(gbot.is_bot == true, "googlebot is_bot=" .. tostring(gbot.is_bot))
ok(gbot.browser.name == "Googlebot", "googlebot browser.name=" .. tostring(gbot.browser.name))
ok(gbot.browser.version == "2.1", "googlebot browser.version=" .. tostring(gbot.browser.version))
ok(gbot.device.type == "bot", "googlebot device.type=" .. tostring(gbot.device.type))
ok(gbot.os.name == nil, "googlebot os.name should be nil, got " .. tostring(gbot.os.name))
ok(gbot.is_mobile == false, "googlebot is_mobile=" .. tostring(gbot.is_mobile))
ok(useragent.is_bot(
  "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)") == true,
  "is_bot(googlebot)")

-- ---- curl is detected as a bot/client ----------------------------------
local curl = useragent.parse("curl/8.4.0")
ok(curl.is_bot == true, "curl is_bot=" .. tostring(curl.is_bot))
ok(curl.browser.name == "curl", "curl browser.name=" .. tostring(curl.browser.name))
ok(curl.browser.version == "8.4.0", "curl browser.version=" .. tostring(curl.browser.version))

-- ---- A normal Chrome UA is NOT a bot, NOT mobile -----------------------
ok(useragent.is_bot(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ..
  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36") == false, "is_bot(desktop chrome)")
ok(useragent.is_mobile(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ..
  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36") == false, "is_mobile(desktop chrome)")

-- ---- raw is preserved; non-string input is tolerated -------------------
ok(curl.raw == "curl/8.4.0", "raw preserved")
local empty = useragent.parse(nil)
ok(empty.raw == "", "nil input -> raw empty string")
ok(empty.is_bot == false, "nil input not bot")
ok(useragent.is_bot(nil) == false, "is_bot(nil)")
ok(useragent.is_mobile(123) == false, "is_mobile(number)")

if fails == 0 then print("[+] PASS test_useragent") os.exit(0) else os.exit(1) end
