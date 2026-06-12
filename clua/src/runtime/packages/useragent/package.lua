return {
    name        = "useragent",
    version     = "1.0",
    description = "User-Agent string parser. Rule-based prioritized regex matcher that identifies browser (Chrome/Firefox/Safari/Edge/Opera/IE and 20+ others), engine (WebKit/Gecko/Blink/Trident/EdgeHTML), OS (Windows/macOS/Linux/iOS/Android/BSD/...), device type (desktop/mobile/tablet/bot), and crawler bots (Googlebot, bingbot, ahrefs, etc.). Returns a unified shape: {browser, engine, os, device, is_bot, is_mobile, raw}.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["useragent"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
