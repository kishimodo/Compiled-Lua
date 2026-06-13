// CLua ImGui host shim. Bridges the async event loop to Dear ImGui's
// Win32 + DX11 backends. Window + device + frame lifecycle lives here;
// every widget call goes straight to cimgui from Lua via FFI.
//
// Exported C ABI (dllexport so ffi.C lookups via GetProcAddress on the
// main module handle succeed):
//
//   CLua_ImGuiHost_Init(title_utf8, w, h) -> 0 ok, nonzero err code
//   CLua_ImGuiHost_PumpEvents()           -> 1 if close requested, 0 ok
//   CLua_ImGuiHost_NewFrame()             -> backend NewFrame + ImGui::NewFrame
//   CLua_ImGuiHost_Render(r,g,b,a)        -> Render + clear + Present
//   CLua_ImGuiHost_Shutdown()             -> tear down ImGui + D3D11 + window
//   CLua_ImGuiHost_Version()              -> IMGUI_VERSION_NUM (sanity probe)
//   CLua_ImGuiHost_GetD3DDevice()         -> ID3D11Device*  (cdata, advanced use)
//   CLua_ImGuiHost_GetD3DContext()        -> ID3D11DeviceContext*
//   CLua_ImGuiHost_RebuildFontAtlas()     -> drop+rebuild backend font texture
//                                            after Lua loaded new fonts
//
// Widget calls (igButton, igSliderFloat, igGetIO, igPushStyleColor, ...)
// land directly in the exe's PE export table via cimgui's dllexport.

#include "imgui.h"
#include "backends/imgui_impl_win32.h"
#include "backends/imgui_impl_dx11.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(
    HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

namespace {

struct HostState {
    HINSTANCE                hInstance     = nullptr;
    HWND                     hWnd          = nullptr;
    WNDCLASSEXW              wc            = {};
    ID3D11Device            *device        = nullptr;
    ID3D11DeviceContext     *context       = nullptr;
    IDXGISwapChain          *swapchain     = nullptr;
    ID3D11RenderTargetView  *rtv           = nullptr;
    bool                     want_close    = false;
};

HostState g_state;

void ReleaseBackBufferRTV() {
    if (g_state.rtv) { g_state.rtv->Release(); g_state.rtv = nullptr; }
}

void CreateBackBufferRTV() {
    ID3D11Texture2D *back = nullptr;
    if (FAILED(g_state.swapchain->GetBuffer(0, IID_PPV_ARGS(&back))) || !back) return;
    g_state.device->CreateRenderTargetView(back, nullptr, &g_state.rtv);
    back->Release();
}

LRESULT WINAPI HostWndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam)) return true;
    switch (msg) {
    case WM_SIZE:
        if (g_state.device && wParam != SIZE_MINIMIZED) {
            ReleaseBackBufferRTV();
            g_state.swapchain->ResizeBuffers(0, (UINT)LOWORD(lParam),
                                             (UINT)HIWORD(lParam),
                                             DXGI_FORMAT_UNKNOWN, 0);
            CreateBackBufferRTV();
        }
        return 0;
    case WM_SYSCOMMAND:
        /* swallow Alt menu (otherwise game-like apps eat the Alt key) */
        if ((wParam & 0xfff0) == SC_KEYMENU) return 0;
        break;
    case WM_DESTROY:
        g_state.want_close = true;
        PostQuitMessage(0);
        return 0;
    case WM_CLOSE:
        g_state.want_close = true;
        return 0;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

bool CreateDeviceD3D() {
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount                        = 2;
    sd.BufferDesc.Format                  = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator   = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage                        = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow                       = g_state.hWnd;
    sd.SampleDesc.Count                   = 1;
    sd.Windowed                           = TRUE;
    sd.SwapEffect                         = DXGI_SWAP_EFFECT_DISCARD;

    const D3D_FEATURE_LEVEL fl_array[] = {
        D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0
    };
    D3D_FEATURE_LEVEL fl;

    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        fl_array, (UINT)(sizeof(fl_array) / sizeof(fl_array[0])),
        D3D11_SDK_VERSION, &sd, &g_state.swapchain,
        &g_state.device, &fl, &g_state.context);
    if (hr == DXGI_ERROR_UNSUPPORTED) {
        /* no usable GPU -- fall back to WARP software rasteriser */
        hr = D3D11CreateDeviceAndSwapChain(
            nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0,
            fl_array, (UINT)(sizeof(fl_array) / sizeof(fl_array[0])),
            D3D11_SDK_VERSION, &sd, &g_state.swapchain,
            &g_state.device, &fl, &g_state.context);
    }
    if (FAILED(hr)) return false;

    CreateBackBufferRTV();
    return g_state.rtv != nullptr;
}

void DestroyDeviceD3D() {
    ReleaseBackBufferRTV();
    if (g_state.swapchain) { g_state.swapchain->Release(); g_state.swapchain = nullptr; }
    if (g_state.context)   { g_state.context->Release();   g_state.context   = nullptr; }
    if (g_state.device)    { g_state.device->Release();    g_state.device    = nullptr; }
}

} // namespace

extern "C" {

__declspec(dllexport) int CLua_ImGuiHost_Init(const char *title_utf8, int width, int height) {
    if (g_state.hWnd) return 1; /* already initialised */

    g_state.hInstance = GetModuleHandleW(nullptr);
    g_state.wc = { sizeof(g_state.wc), CS_CLASSDC, HostWndProc, 0L, 0L,
                   g_state.hInstance, nullptr, nullptr, nullptr, nullptr,
                   L"CLuaImGuiHost", nullptr };
    RegisterClassExW(&g_state.wc);

    WCHAR wtitle[256] = L"CLua ImGui";
    if (title_utf8 && *title_utf8) {
        MultiByteToWideChar(CP_UTF8, 0, title_utf8, -1, wtitle, 255);
    }

    g_state.hWnd = CreateWindowExW(0, g_state.wc.lpszClassName, wtitle,
        WS_OVERLAPPEDWINDOW, 100, 100, width, height,
        nullptr, nullptr, g_state.hInstance, nullptr);
    if (!g_state.hWnd) {
        UnregisterClassW(g_state.wc.lpszClassName, g_state.hInstance);
        return 2;
    }

    if (!CreateDeviceD3D()) {
        DestroyDeviceD3D();
        DestroyWindow(g_state.hWnd);
        g_state.hWnd = nullptr;
        UnregisterClassW(g_state.wc.lpszClassName, g_state.hInstance);
        return 3;
    }

    ShowWindow(g_state.hWnd, SW_SHOWDEFAULT);
    UpdateWindow(g_state.hWnd);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();

    if (!ImGui_ImplWin32_Init(g_state.hWnd)) return 4;
    if (!ImGui_ImplDX11_Init(g_state.device, g_state.context)) return 5;
    return 0;
}

__declspec(dllexport) int CLua_ImGuiHost_PumpEvents(void) {
    MSG msg = {};
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        if (msg.message == WM_QUIT) g_state.want_close = true;
    }
    return g_state.want_close ? 1 : 0;
}

__declspec(dllexport) void CLua_ImGuiHost_NewFrame(void) {
    ImGui_ImplDX11_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
}

__declspec(dllexport) void CLua_ImGuiHost_Render(float r, float g, float b, float a) {
    ImGui::Render();
    if (!g_state.context || !g_state.rtv) return;
    const float clear[4] = { r, g, b, a };
    g_state.context->OMSetRenderTargets(1, &g_state.rtv, nullptr);
    g_state.context->ClearRenderTargetView(g_state.rtv, clear);
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
    g_state.swapchain->Present(1, 0); /* vsync */
}

__declspec(dllexport) void CLua_ImGuiHost_Shutdown(void) {
    if (!g_state.hWnd) return;
    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    DestroyDeviceD3D();
    DestroyWindow(g_state.hWnd);
    UnregisterClassW(g_state.wc.lpszClassName, g_state.hInstance);
    g_state.hWnd       = nullptr;
    g_state.want_close = false;
}

__declspec(dllexport) int CLua_ImGuiHost_Version(void) {
    return IMGUI_VERSION_NUM;
}

__declspec(dllexport) void *CLua_ImGuiHost_GetD3DDevice(void) {
    return (void *)g_state.device;
}

__declspec(dllexport) void *CLua_ImGuiHost_GetD3DContext(void) {
    return (void *)g_state.context;
}

/* Call after the Lua side mutates io.Fonts (AddFontFromFileTTF etc).
   The DX11 backend caches the rasterised atlas as a GPU texture, so we
   drop and rebuild it; ImGuiIO.Fonts itself stays alive. */
__declspec(dllexport) void CLua_ImGuiHost_RebuildFontAtlas(void) {
    ImGui_ImplDX11_InvalidateDeviceObjects();
    ImGui_ImplDX11_CreateDeviceObjects();
}

} // extern "C"
