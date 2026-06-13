-- CLua webview package manifest.
return {
    name        = "webview",
    version     = "0.1",
    description = "Embed the system WebView2 (Edge Chromium) runtime via the WebView2Loader.dll COM SDK. Wraps ICoreWebView2 / ICoreWebView2Controller / ICoreWebView2Environment surfaces: window creation, navigation, HTML loading, JS evaluation, and bidirectional Lua/JS bindings (window.<name>(...) -> Lua). Falls back to embedding the legacy MSHTML / IWebBrowser2 control if WebView2Loader.dll is missing. Owns its WS_OVERLAPPEDWINDOW host window and runs a Win32 message pump.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["webview"] = "init.lua",
    },
    requires        = { "windows", "windows.com", "wndproc" },
    requires_native = {},
}
