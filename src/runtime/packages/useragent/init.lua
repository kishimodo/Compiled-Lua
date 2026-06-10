-- useragent -- User-Agent string parser.
--
-- Public surface:
--   useragent.parse(ua)   -> {
--       browser = { name, version },
--       engine  = { name, version },
--       os      = { name, version },
--       device  = { type, vendor, model },
--       is_bot, is_mobile, raw,
--   }
--   useragent.is_bot(ua)     -> bool
--   useragent.is_mobile(ua)  -> bool
--
-- Rule order matters: more specific patterns must come first (e.g. Edge
-- before Chrome, because Edge UAs contain the substring "Chrome/").

local M = {}

-- ===== Bot patterns =====================================================

local BOT_PATTERNS = {
    "[Gg]ooglebot", "[Bb]ingbot", "[Yy]andexbot", "[Bb]aiduspider",
    "[Dd]uckduckbot", "[Ss]ogou", "[Ee]xabot", "[Ff]acebot",
    "ia_archiver", "[Mm]j12bot", "[Aa]hrefsbot", "[Ss]emrushbot",
    "[Dd]otbot", "[Bb]ytespider", "[Aa]pplebot", "[Ll]inkedinbot",
    "[Tt]elegrambot", "[Ww]hatsapp", "[Ss]lackbot", "[Dd]iscordbot",
    "[Tt]witterbot", "[Rr]edditbot", "[Pp]interestbot", "[Pp]etalbot",
    "[Ss]eznambot", "[Cc]url/", "[Ww]get/", "[Pp]ython%-requests",
    "[Pp]ython%-urllib", "[Gg]o%-http%-client", "[Jj]ava/",
    "[Pp]ostmanruntime", "[Aa]xios/", "[Oo]kHttp", "[Hh]eadlesschrome",
    "[Pp]hantomjs", "[Cc]rawler", "[Ss]pider", "[Bb]ot/", "[Bb]ot;",
    "[Bb]ot$", "[Mm]onitor", "[Vv]alidator", "[Ff]etcher",
}

local BOT_NAMES = {
    { "[Gg]ooglebot/?([%d%.]*)",       "Googlebot" },
    { "[Bb]ingbot/?([%d%.]*)",         "bingbot" },
    { "[Yy]andexbot/?([%d%.]*)",       "YandexBot" },
    { "[Bb]aiduspider/?([%d%.]*)",     "Baiduspider" },
    { "[Dd]uckduckbot[/-]?([%d%.]*)",  "DuckDuckBot" },
    { "[Aa]hrefsbot/?([%d%.]*)",       "AhrefsBot" },
    { "[Ss]emrushbot/?([%d%.]*)",      "SemrushBot" },
    { "[Mm]j12bot/?v?([%d%.]*)",       "MJ12bot" },
    { "[Dd]otbot/?([%d%.]*)",          "DotBot" },
    { "[Ss]ogou web spider/?([%d%.]*)","Sogou web spider" },
    { "[Ff]acebot/?([%d%.]*)",         "facebot" },
    { "[Bb]ytespider/?([%d%.]*)",      "Bytespider" },
    { "[Aa]pplebot/?([%d%.]*)",        "Applebot" },
    { "[Ll]inkedinbot/?([%d%.]*)",     "LinkedInBot" },
    { "[Tt]elegrambot %(like ([%w%.]+)%)","TelegramBot" },
    { "[Ss]lackbot/?([%d%.]*)",        "Slackbot" },
    { "[Dd]iscordbot/?([%d%.]*)",      "Discordbot" },
    { "[Tt]witterbot/?([%d%.]*)",      "Twitterbot" },
    { "[Pp]interestbot/?([%d%.]*)",    "Pinterestbot" },
    { "[Pp]etalbot/?([%d%.]*)",        "PetalBot" },
    { "[Cc]url/([%d%.]+)",             "curl" },
    { "[Ww]get/([%d%.]+)",             "wget" },
    { "[Pp]ython%-requests/([%d%.]+)", "python-requests" },
    { "[Pp]ython%-urllib/([%d%.]+)",   "python-urllib" },
    { "[Gg]o%-http%-client/([%d%.]+)", "Go-http-client" },
    { "[Jj]ava/([%d%._]+)",            "Java" },
    { "[Pp]ostmanruntime/([%d%.]+)",   "PostmanRuntime" },
    { "[Aa]xios/([%d%.]+)",            "axios" },
    { "[Oo]kHttp/([%d%.]+)",           "OkHttp" },
    { "[Hh]eadlesschrome/([%d%.]+)",   "HeadlessChrome" },
}

function M.is_bot(ua)
    if type(ua) ~= "string" then return false end
    for _, p in ipairs(BOT_PATTERNS) do
        if ua:find(p) then return true end
    end
    return false
end

local function detect_bot(ua)
    for _, rule in ipairs(BOT_NAMES) do
        local v = ua:match(rule[1])
        if v then return rule[2], v ~= "" and v or nil end
    end
    if M.is_bot(ua) then return "Other", nil end
    return nil, nil
end

-- ===== Browser patterns =================================================
-- Order matters. More-specific brands first.

local BROWSER_RULES = {
    { "Edg[ieA]?/([%d%.]+)",                "Edge" },
    { "Edge/([%d%.]+)",                     "Edge" },
    { "EdgiOS/([%d%.]+)",                   "Edge" },
    { "OPR/([%d%.]+)",                      "Opera" },
    { "Opera Mini/([%d%.]+)",               "Opera Mini" },
    { "Opera Mobi.-Version/([%d%.]+)",      "Opera Mobile" },
    { "Opera/([%d%.]+)",                    "Opera" },
    { "Vivaldi/([%d%.]+)",                  "Vivaldi" },
    { "Brave/([%d%.]+)",                    "Brave" },
    { "YaBrowser/([%d%.]+)",                "Yandex Browser" },
    { "UCBrowser/([%d%.]+)",                "UC Browser" },
    { "SamsungBrowser/([%d%.]+)",           "Samsung Browser" },
    { "MiuiBrowser/([%d%.]+)",              "MIUI Browser" },
    { "HuaweiBrowser/([%d%.]+)",            "Huawei Browser" },
    { "DuckDuckGo/([%d%.]+)",               "DuckDuckGo" },
    { "Firefox/([%d%.]+)",                  "Firefox" },
    { "FxiOS/([%d%.]+)",                    "Firefox iOS" },
    { "SeaMonkey/([%d%.]+)",                "SeaMonkey" },
    { "PaleMoon/([%d%.]+)",                 "Pale Moon" },
    { "Waterfox/([%d%.]+)",                 "Waterfox" },
    { "Chromium/([%d%.]+)",                 "Chromium" },
    { "CriOS/([%d%.]+)",                    "Chrome iOS" },
    { "Chrome/([%d%.]+)",                   "Chrome" },
    { "Version/([%d%.]+).*Mobile.*Safari",  "Mobile Safari" },
    { "Version/([%d%.]+).*Safari",          "Safari" },
    { "Safari/([%d%.]+)",                   "Safari" },
    { "MSIE ([%d%.]+)",                     "IE" },
    { "Trident/.-rv:([%d%.]+)",             "IE" },
    { "Konqueror/([%d%.]+)",                "Konqueror" },
    { "Lynx/([%d%.]+)",                     "Lynx" },
    { "Links %(([%d%.]+)",                  "Links" },
    { "w3m/([%d%.]+)",                      "w3m" },
}

local function detect_browser(ua)
    for _, rule in ipairs(BROWSER_RULES) do
        local v = ua:match(rule[1])
        if v then return rule[2], v end
    end
    return nil, nil
end

-- ===== Engine patterns ==================================================

local ENGINE_RULES = {
    { "Blink/([%d%.]+)",                "Blink" },
    { "EdgeHTML/([%d%.]+)",             "EdgeHTML" },
    { "Trident/([%d%.]+)",              "Trident" },
    { "Gecko/(%d+)",                    "Gecko" },
    { "AppleWebKit/([%d%.]+)",          "WebKit" },
    { "KHTML/([%d%.]+)",                "KHTML" },
    { "Presto/([%d%.]+)",               "Presto" },
}

local function detect_engine(ua, browser_name)
    -- Chrome >= 28 uses Blink even though UA only says AppleWebKit.
    if browser_name == "Chrome" or browser_name == "Chromium"
       or browser_name == "Edge" or browser_name == "Opera"
       or browser_name == "Vivaldi" or browser_name == "Brave"
       or browser_name == "Yandex Browser" or browser_name == "Samsung Browser" then
        local v = ua:match("AppleWebKit/([%d%.]+)")
        return "Blink", v
    end
    for _, rule in ipairs(ENGINE_RULES) do
        local v = ua:match(rule[1])
        if v then return rule[2], v end
    end
    return nil, nil
end

-- ===== OS patterns ======================================================

local function win_nt_to_name(v)
    local t = {
        ["10.0"] = "10", ["6.3"] = "8.1", ["6.2"] = "8",
        ["6.1"]  = "7",  ["6.0"] = "Vista", ["5.2"] = "XP x64",
        ["5.1"]  = "XP", ["5.0"] = "2000",
    }
    return t[v] or v
end

local function detect_os(ua)
    -- Mobile / specific OS first.
    local v = ua:match("Android ([%d%._]+)") or ua:match("Android/([%d%._]+)")
    if v then return "Android", v end
    if ua:find("Android") then return "Android", nil end

    v = ua:match("iPhone OS ([%d_]+)") or ua:match("CPU OS ([%d_]+)")
    if v then return "iOS", (v:gsub("_", ".")) end
    if ua:find("iPhone") or ua:find("iPad") or ua:find("iPod") then
        return "iOS", nil
    end

    v = ua:match("Mac OS X ([%d_%.]+)")
    if v then return "macOS", (v:gsub("_", ".")) end
    if ua:find("Macintosh") then return "macOS", nil end

    v = ua:match("Windows NT ([%d%.]+)")
    if v then return "Windows", win_nt_to_name(v) end
    if ua:find("Windows Phone") then return "Windows Phone", ua:match("Windows Phone ([%d%.]+)") end
    if ua:find("Windows") then return "Windows", nil end

    if ua:find("CrOS") then
        return "Chrome OS", ua:match("CrOS %S+ ([%d%.]+)")
    end
    if ua:find("Tizen") then return "Tizen", ua:match("Tizen/?([%d%.]*)") end
    if ua:find("KaiOS")  then return "KaiOS",  ua:match("KaiOS/?([%d%.]*)")  end
    if ua:find("Web0S") or ua:find("webOS") then return "webOS", ua:match("[Ww]ebOS/?([%d%.]*)") end
    if ua:find("FreeBSD")   then return "FreeBSD",   nil end
    if ua:find("OpenBSD")   then return "OpenBSD",   nil end
    if ua:find("NetBSD")    then return "NetBSD",    nil end
    if ua:find("SunOS")     then return "Solaris",   nil end
    if ua:find("Ubuntu")    then return "Ubuntu",    nil end
    if ua:find("Fedora")    then return "Fedora",    nil end
    if ua:find("Debian")    then return "Debian",    nil end
    if ua:find("Linux")     then return "Linux",     nil end

    return nil, nil
end

-- ===== Device patterns =================================================

local TABLET_HINTS = {
    "iPad", "Tablet", "Kindle", "Silk/", "PlayBook", "Nexus 7",
    "Nexus 9", "Nexus 10", "SM%-T", "GT%-P", "Tab[0-9 ]",
}

local MOBILE_HINTS = {
    "Mobile", "iPhone", "iPod", "Android.*Mobile", "BlackBerry",
    "BB10", "IEMobile", "Opera Mini", "Opera Mobi", "webOS",
    "Windows Phone", "KaiOS",
}

function M.is_mobile(ua)
    if type(ua) ~= "string" then return false end
    for _, p in ipairs(MOBILE_HINTS) do
        if ua:find(p) then return true end
    end
    return false
end

local function detect_device_type(ua)
    for _, p in ipairs(TABLET_HINTS) do
        if ua:find(p) then return "tablet" end
    end
    if M.is_mobile(ua) then return "mobile" end
    if ua:find("SmartTV") or ua:find("HbbTV") or ua:find("BRAVIA")
       or ua:find("CrKey") or ua:find("AppleTV") then
        return "tv"
    end
    if ua:find("PlayStation") or ua:find("Xbox") or ua:find("Nintendo") then
        return "console"
    end
    return "desktop"
end

local DEVICE_RULES = {
    { "iPhone",            "Apple",   "iPhone" },
    { "iPad",              "Apple",   "iPad" },
    { "iPod",              "Apple",   "iPod" },
    { "Pixel ?%d+%w*",     "Google",  nil },
    { "Nexus %w+",         "Google",  nil },
    { "SM%-[%w]+",         "Samsung", nil },
    { "GT%-[%w]+",         "Samsung", nil },
    { "Galaxy[%w ]+",      "Samsung", nil },
    { "Mi [%w ]+",         "Xiaomi",  nil },
    { "Redmi [%w ]+",      "Xiaomi",  nil },
    { "HUAWEI[%- ][%w]+",  "Huawei",  nil },
    { "OnePlus[%- ][%w]+", "OnePlus", nil },
    { "Pixel C",           "Google",  "Pixel C" },
    { "Kindle",            "Amazon",  "Kindle" },
    { "BlackBerry",        "BlackBerry", nil },
    { "BB10",              "BlackBerry", nil },
    { "Nokia[%- ]%w+",     "Nokia",   nil },
}

local function detect_device_model(ua)
    for _, rule in ipairs(DEVICE_RULES) do
        local match = ua:match(rule[1])
        if match then
            return rule[2], rule[3] or match
        end
    end
    return nil, nil
end

-- ===== parse() =========================================================

function M.parse(ua)
    if type(ua) ~= "string" then ua = "" end
    local out = { raw = ua }

    local bot_name, bot_ver = detect_bot(ua)
    out.is_bot = bot_name ~= nil

    if out.is_bot then
        out.browser = { name = bot_name, version = bot_ver }
        out.engine  = { name = nil,      version = nil }
        out.os      = { name = nil,      version = nil }
        out.device  = { type = "bot",    vendor = nil, model = nil }
        out.is_mobile = false
        return out
    end

    local br_name, br_ver = detect_browser(ua)
    local en_name, en_ver = detect_engine(ua, br_name)
    local os_name, os_ver = detect_os(ua)
    local dev_type        = detect_device_type(ua)
    local dev_vendor, dev_model = detect_device_model(ua)

    out.browser   = { name = br_name,  version = br_ver }
    out.engine    = { name = en_name,  version = en_ver }
    out.os        = { name = os_name,  version = os_ver }
    out.device    = { type = dev_type, vendor = dev_vendor, model = dev_model }
    out.is_mobile = (dev_type == "mobile" or dev_type == "tablet")
    return out
end

return M
