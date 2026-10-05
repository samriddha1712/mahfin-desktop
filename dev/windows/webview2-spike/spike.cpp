// Throwaway: mpv (d3d11, wid) in a child window, transparent WebView2 above it.
// Proves the composition the Windows shell will rely on. Not part of the build.
#include <windows.h>
#include <wrl.h>
#include <WebView2.h>
#include <mpv/client.h>
#include <string>
#include <cstdio>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

static HWND g_main, g_video;
static mpv_handle* g_mpv;
static bool g_parentMode;
static ComPtr<ICoreWebView2Controller> g_ctrl;
static ComPtr<ICoreWebView2> g_web;

static const wchar_t* kHtml = LR"HTML(<!doctype html><html><body style="margin:0;background:transparent;font:24px sans-serif;color:#fff">
<div style="position:fixed;left:40px;top:40px;padding:20px;border-radius:16px;background:rgba(20,20,40,.55);backdrop-filter:blur(12px)">
WebView2 overlay over mpv <span id=t></span></div>
<div style="position:fixed;bottom:0;left:0;right:0;height:90px;background:linear-gradient(transparent,rgba(0,0,0,.8))"></div>
<script>let n=0;setInterval(()=>{t.textContent=++n;chrome.webview.postMessage('tick '+n)},500)</script></body></html>)HTML";

static void layout()
{
  RECT rc; GetClientRect(g_main, &rc);
  if (g_video) MoveWindow(g_video, 0, 0, rc.right, rc.bottom, TRUE);
  if (g_ctrl) g_ctrl->put_Bounds(rc);
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  switch (m) {
  case WM_SIZE: layout(); return 0;
  case WM_TIMER: {
    // Report and fix the sibling z-order: who is on top, mpv's window or WebView2's?
    KillTimer(h, 1);
    for (HWND c = GetWindow(h, GW_CHILD); c; c = GetWindow(c, GW_HWNDNEXT)) {
      wchar_t cls[128]; GetClassNameW(c, cls, 128); fwprintf(stderr, L"child (top first): %p %s\n", c, cls);
    }
    if (wcsstr(GetCommandLineW(), L"--raise"))
      for (HWND c = GetWindow(h, GW_CHILD); c; c = GetWindow(c, GW_HWNDNEXT)) {
        wchar_t cls[128]; GetClassNameW(c, cls, 128);
        if (wcsncmp(cls, L"Chrome_WidgetWin", 16) == 0) { SetWindowPos(c, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE); fwprintf(stderr, L"raised %p\n", c); }
      }
    return 0; }
  case WM_DESTROY: PostQuitMessage(0); return 0;
  }
  return DefWindowProcW(h, m, w, l);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int)
{
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  WNDCLASSW wc{}; wc.lpfnWndProc = WndProc; wc.hInstance = inst; wc.lpszClassName = L"spike";
  wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH); wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);
  WNDCLASSW vc = wc; vc.lpfnWndProc = DefWindowProcW; vc.lpszClassName = L"spikevideo";
  RegisterClassW(&vc);
  g_main = CreateWindowExW(0, L"spike", L"WebView2 + mpv spike", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
                           100, 100, 1280, 720, nullptr, nullptr, inst, nullptr);
  g_parentMode = wcsstr(GetCommandLineW(), L"--parent") != nullptr;
  if (!g_parentMode) g_video = CreateWindowExW(0, L"spikevideo", L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, 1, 1,
                            g_main, nullptr, inst, nullptr);
  ShowWindow(g_main, SW_SHOW);
  layout();

  g_mpv = mpv_create();
  int64_t wid = (int64_t)(intptr_t)(g_parentMode ? g_main : g_video);
  mpv_set_option(g_mpv, "wid", MPV_FORMAT_INT64, &wid);
  mpv_set_option_string(g_mpv, "vo", "gpu-next");
  mpv_set_option_string(g_mpv, "gpu-api", "d3d11");
  mpv_set_option_string(g_mpv, "hwdec", "auto");
  mpv_set_option_string(g_mpv, "force-window", "yes");
  mpv_set_option_string(g_mpv, "input-default-bindings", "no");
  mpv_set_option_string(g_mpv, "input-vo-keyboard", "no");
  mpv_set_option_string(g_mpv, "loop-file", "inf");
  mpv_set_option_string(g_mpv, "terminal", "no");
  mpv_set_option_string(g_mpv, "log-file", "spike-mpv.log");
  mpv_set_option_string(g_mpv, "msg-level", "all=v");
  if (mpv_initialize(g_mpv) < 0) { MessageBoxW(nullptr, L"mpv_initialize failed", L"spike", 0); return 1; }
  const char* cmd[] = {"loadfile", "av://lavfi:testsrc2=size=1920x1080:rate=24", nullptr};
  mpv_command(g_mpv, cmd);

  CreateCoreWebView2EnvironmentWithOptions(nullptr, L"spike-userdata", nullptr,
    Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
      [](HRESULT hr, ICoreWebView2Environment* env) -> HRESULT {
        if (FAILED(hr)) { fprintf(stderr, "env failed %08lx\n", hr); return hr; }
        return env->CreateCoreWebView2Controller(g_main,
          Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [](HRESULT hr, ICoreWebView2Controller* c) -> HRESULT {
              if (FAILED(hr)) { fprintf(stderr, "controller failed %08lx\n", hr); return hr; }
              g_ctrl = c;
              ComPtr<ICoreWebView2Controller2> c2;
              if (SUCCEEDED(g_ctrl.As(&c2))) c2->put_DefaultBackgroundColor({0, 0, 0, 0});
              g_ctrl->get_CoreWebView2(&g_web);
              EventRegistrationToken tok;
              g_web->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                [](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* a) -> HRESULT {
                  LPWSTR s; a->TryGetWebMessageAsString(&s); fwprintf(stderr, L"js: %s\n", s); CoTaskMemFree(s); return S_OK;
                }).Get(), &tok);
              layout();
              g_web->NavigateToString(kHtml);
              SetTimer(g_main, 1, 2000, nullptr);
              return S_OK;
            }).Get());
      }).Get());

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
  g_ctrl.Reset(); g_web.Reset();
  mpv_terminate_destroy(g_mpv);
  return 0;
}
