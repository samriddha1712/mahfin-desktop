#include "WebViewHost.h"
#include "shared/TrustedOrigins.h"

#include <QDebug>
#include <QDesktopServices>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QTimer>
#include <QWebChannel>
#include <QWindow>

#include <shlwapi.h>
#include <wrl.h>
// Qt defines __has_attribute for MSVC, which sends this header down a
// clang-only `__attribute__` branch. It is not Qt's to answer here.
#pragma push_macro("__has_attribute")
#undef __has_attribute
#include <WebView2EnvironmentOptions.h>
#pragma pop_macro("__has_attribute")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

namespace
{
  // The bundled pages (the qrc: start page and its scripts) are served from
  // here. `.invalid` is reserved, so this can never be a real site.
  const QString kVirtualHost = QStringLiteral("app.mahfin.invalid");

  QString fromCoTask(LPWSTR s)
  {
    if (!s)
      return QString();
    QString result = QString::fromWCharArray(s);
    CoTaskMemFree(s);
    return result;
  }

  std::wstring toW(const QString& s) { return s.toStdWString(); }

  /*
   * Runs before every page script, in every document.
   *
   * QtWebEngine injected the native shell script into the main frame only.
   * WebView2 injects into every frame, so child frames (a trailer embed, say)
   * are stopped at the first line: they have no `chrome.webview` and must not
   * get a copy of the shell's API.
   *
   * Then the transport QtWebEngine used to provide: the same object at the
   * same name, `window.qt.webChannelTransport`, so qwebchannel.js connects to
   * the C++ side without knowing what it is running in.
   */
  const char* kPrelude = R"JS(
if (window !== window.top || !window.chrome || !window.chrome.webview) {
  throw new Error('mahfin: the native shell is only for the top frame');
}
window.qt = {
  webChannelTransport: {
    send: function (message) { window.chrome.webview.postMessage(message); },
    onmessage: null
  }
};
window.chrome.webview.addEventListener('message', function (event) {
  var transport = window.qt.webChannelTransport;
  if (transport.onmessage) transport.onmessage({ data: event.data });
});
// The pointer is hidden by the page's own request (api.window.setCursorVisibility).
// Over a WebView2 window that has to be CSS: Qt's override cursor never reaches it.
(function () {
  var css = 'html[data-mahfin-cursor-hidden], html[data-mahfin-cursor-hidden] * { cursor: none !important; }';
  var add = function () {
    var style = document.createElement('style');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  };
  if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
})();
)JS";

  QString contentTypeFor(const QString& path)
  {
    const QString suffix = QFileInfo(path).suffix().toLower();
    if (suffix == "html" || suffix == "htm") return "text/html; charset=utf-8";
    if (suffix == "js") return "text/javascript; charset=utf-8";
    if (suffix == "css") return "text/css; charset=utf-8";
    if (suffix == "json") return "application/json";
    if (suffix == "png") return "image/png";
    if (suffix == "svg") return "image/svg+xml";
    if (suffix == "ico") return "image/x-icon";
    if (suffix == "woff2") return "font/woff2";
    return "application/octet-stream";
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewTransport::sendMessage(const QJsonObject& message)
{
  if (!m_webView)
    return;
  const QByteArray json = QJsonDocument(message).toJson(QJsonDocument::Compact);
  m_webView->PostWebMessageAsString(toW(QString::fromUtf8(json)).c_str());
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewTransport::receive(const QString& json)
{
  QJsonParseError error;
  const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8(), &error);
  if (error.error != QJsonParseError::NoError || !doc.isObject())
  {
    qWarning() << "WebView2: dropped a malformed channel message:" << error.errorString();
    return;
  }
  emit messageReceived(doc.object(), this);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
WebViewHost::WebViewHost(QWindow* window, QObject* parent)
  : QObject(parent), m_window(window), m_hwnd(reinterpret_cast<HWND>(window->winId())),
    m_transport(new WebViewTransport(this))
{
}

///////////////////////////////////////////////////////////////////////////////////////////////////
WebViewHost::~WebViewHost()
{
  if (m_controller)
    m_controller->Close();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
QString WebViewHost::runtimeVersion(const QString& browserExecutableFolder)
{
  LPWSTR version = nullptr;
  std::wstring folder = toW(browserExecutableFolder);
  HRESULT hr = GetAvailableCoreWebView2BrowserVersionString(
      browserExecutableFolder.isEmpty() ? nullptr : folder.c_str(), &version);
  if (FAILED(hr))
    return QString();
  return fromCoTask(version);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
QUrl WebViewHost::mapToVirtualHost(const QUrl& url)
{
  if (url.scheme() != "qrc")
    return url;
  QUrl mapped;
  mapped.setScheme("https");
  mapped.setHost(kVirtualHost);
  mapped.setPath(url.path());
  mapped.setQuery(url.query());
  mapped.setFragment(url.fragment());
  return mapped;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::create(const Options& options)
{
  m_options = options;

  auto envOptions = Make<CoreWebView2EnvironmentOptions>();
  envOptions->put_AdditionalBrowserArguments(toW(options.browserArguments.join(' ')).c_str());

  const std::wstring userData = toW(options.userDataFolder);
  const std::wstring browserFolder = toW(options.browserExecutableFolder);

  QPointer<WebViewHost> self(this);
  HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
      options.browserExecutableFolder.isEmpty() ? nullptr : browserFolder.c_str(),
      userData.c_str(), envOptions.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [self](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
            if (!self)
              return S_OK;
            if (FAILED(result) || !env)
            {
              emit self->failed(QStringLiteral("Could not start WebView2 (0x%1).").arg(quint32(result), 8, 16, QChar('0')));
              return S_OK;
            }
            self->m_environment = env;
            return env->CreateCoreWebView2Controller(self->m_hwnd,
                Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [self](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                      if (!self)
                        return S_OK;
                      if (FAILED(result) || !controller)
                      {
                        emit self->failed(QStringLiteral("Could not create the web view (0x%1).").arg(quint32(result), 8, 16, QChar('0')));
                        return S_OK;
                      }
                      self->onControllerCreated(controller);
                      return S_OK;
                    }).Get());
          }).Get());

  if (FAILED(hr))
    emit failed(QStringLiteral("Could not start WebView2 (0x%1).").arg(quint32(hr), 8, 16, QChar('0')));
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::onControllerCreated(ICoreWebView2Controller* controller)
{
  m_controller = controller;
  m_controller->get_CoreWebView2(&m_webView);
  m_transport->setWebView(m_webView.Get());

  // Transparent, so mpv's window underneath shows through wherever the page
  // has not painted. This is the whole composition: WebView2 draws with
  // DirectComposition, mpv with its own swapchain, and DWM layers them.
  ComPtr<ICoreWebView2Controller2> controller2;
  if (SUCCEEDED(m_controller.As(&controller2)))
    controller2->put_DefaultBackgroundColor({0, 0, 0, 0});

  // A file dropped on the window must not replace the page.
  ComPtr<ICoreWebView2Controller4> controller4;
  if (SUCCEEDED(m_controller.As(&controller4)))
    controller4->put_AllowExternalDrop(FALSE);

  ComPtr<ICoreWebView2Settings> settings;
  m_webView->get_Settings(&settings);
  settings->put_IsStatusBarEnabled(FALSE);
  settings->put_AreDevToolsEnabled(m_options.devTools ? TRUE : FALSE);
  settings->put_IsBuiltInErrorPageEnabled(FALSE);
  settings->put_IsZoomControlEnabled(m_options.allowZoom ? TRUE : FALSE);
  // Browser shortcuts (print, find, reload, ...) were never part of the app.
  ComPtr<ICoreWebView2Settings3> settings3;
  if (SUCCEEDED(settings.As(&settings3)))
    settings3->put_AreBrowserAcceleratorKeysEnabled(FALSE);
  ComPtr<ICoreWebView2Settings2> settings2;
  if (SUCCEEDED(settings.As(&settings2)) && !m_options.userAgent.isEmpty())
    settings2->put_UserAgent(toW(m_options.userAgent).c_str());
  ComPtr<ICoreWebView2Settings4> settings4;
  if (SUCCEEDED(settings.As(&settings4)))
  {
    settings4->put_IsPasswordAutosaveEnabled(FALSE);
    settings4->put_IsGeneralAutofillEnabled(FALSE);
  }
  ComPtr<ICoreWebView2Settings5> settings5;
  if (SUCCEEDED(settings.As(&settings5)))
    settings5->put_IsPinchZoomEnabled(m_options.allowZoom ? TRUE : FALSE);
  ComPtr<ICoreWebView2Settings6> settings6;
  if (SUCCEEDED(settings.As(&settings6)))
    settings6->put_IsSwipeNavigationEnabled(FALSE);

  const QString script = QString::fromUtf8(kPrelude) + m_options.injectedScript;
  m_webView->AddScriptToExecuteOnDocumentCreated(toW(script).c_str(), nullptr);

  m_webView->AddWebResourceRequestedFilter(toW("https://" + kVirtualHost + "/*").c_str(),
                                           COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);

  installHandlers();

  if (m_bounds.isValid())
    m_controller->put_Bounds(RECT{m_bounds.left(), m_bounds.top(), m_bounds.right() + 1, m_bounds.bottom() + 1});
  m_controller->put_IsVisible(m_visible ? TRUE : FALSE);

  if (m_channel)
    attachChannel(m_channel);

  focus();
  emit ready();

  if (m_pendingNavigation.isValid())
  {
    const QUrl url = m_pendingNavigation;
    m_pendingNavigation = QUrl();
    navigate(url);
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::installHandlers()
{
  EventRegistrationToken token;
  QPointer<WebViewHost> self(this);

  m_webView->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
      [self](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
        // The bridge answers only Mahfin's own pages. Navigation is held to
        // them below as well; this is the second lock, should a page ever get
        // past the first (see shared/TrustedOrigins.h).
        LPWSTR source = nullptr;
        args->get_Source(&source);
        const QString from = fromCoTask(source);
        if (!TrustedOrigins::isTrusted(QUrl(from)))
        {
          qWarning() << "WebView2: ignored a bridge message from" << QUrl(from).host();
          return S_OK;
        }
        LPWSTR message = nullptr;
        if (self && SUCCEEDED(args->TryGetWebMessageAsString(&message)))
          self->m_transport->receive(fromCoTask(message));
        return S_OK;
      }).Get(), &token);

  m_webView->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
      [self](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
        if (!self)
          return S_OK;
        LPWSTR uri = nullptr;
        args->get_Uri(&uri);
        const QString target = fromCoTask(uri);
        /*
         * The window stays on Mahfin; every page in it gets the native bridge.
         * A link the person clicked opens in their browser instead (web
         * addresses only), anything else is simply refused.
         */
        // about:/data: is this host's own error page (NavigateToString); the
        // bridge still refuses to answer it, see WebMessageReceived above.
        const QString scheme = QUrl(target).scheme();
        if (!TrustedOrigins::isTrusted(QUrl(target)) && scheme != "about" && scheme != "data")
        {
          args->put_Cancel(TRUE);
          BOOL userInitiated = FALSE;
          args->get_IsUserInitiated(&userInitiated);
          qWarning() << "WebView2: blocked navigation to" << QUrl(target).host();
          if (userInitiated && TrustedOrigins::isSafeExternal(QUrl(target)))
            QDesktopServices::openUrl(QUrl(target));
          return S_OK;
        }
        self->m_currentUrl = target;
        self->m_loading = true;
        /*
         * A new document is a new page on the other end of the channel. Drop
         * the old page's connection so signals it subscribed to stop being
         * sent into a document that no longer exists; the new page's
         * qwebchannel.js says hello again once it has loaded.
         */
        if (self->m_channel)
        {
          self->m_channel->disconnectFrom(self->m_transport);
          self->m_channel->connectTo(self->m_transport);
        }
        if (self->onNavigationStarting)
          self->onNavigationStarting();
        return S_OK;
      }).Get(), &token);

  m_webView->add_NavigationCompleted(Callback<ICoreWebView2NavigationCompletedEventHandler>(
      [self](ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
        if (!self)
          return S_OK;
        self->m_loading = false;
        BOOL success = FALSE;
        args->get_IsSuccess(&success);
        COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
        args->get_WebErrorStatus(&status);
        // Superseded by another navigation: not a failure anyone needs to see.
        if (!success && status == COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED)
          return S_OK;
        LPWSTR source = nullptr;
        sender->get_Source(&source);
        const QString url = fromCoTask(source);
        if (!success)
        {
          qWarning() << "WebView2: navigation to" << self->m_currentUrl << "failed, status" << status;
          self->showErrorPage(self->m_currentUrl, int(status));
        }
        else
        {
          self->m_currentUrl = url;
          // A document replaced by navigation starts with the pointer visible.
          if (self->m_cursorHidden)
            self->setCursorHidden(true);
        }
        if (self->onNavigationCompleted)
          self->onNavigationCompleted(success);
        return S_OK;
      }).Get(), &token);

  m_webView->add_ContainsFullScreenElementChanged(Callback<ICoreWebView2ContainsFullScreenElementChangedEventHandler>(
      [self](ICoreWebView2* sender, IUnknown*) -> HRESULT {
        BOOL fullscreen = FALSE;
        sender->get_ContainsFullScreenElement(&fullscreen);
        if (self && self->onFullscreenRequested)
          self->onFullscreenRequested(fullscreen == TRUE);
        return S_OK;
      }).Get(), &token);

  // Frames are held to the same list; Mahfin embeds none of its own.
  m_webView->add_FrameNavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
      [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
        LPWSTR uri = nullptr;
        args->get_Uri(&uri);
        const QUrl target(fromCoTask(uri));
        if (!TrustedOrigins::isTrusted(target) && target.scheme() != "about")
          args->put_Cancel(TRUE);
        return S_OK;
      }).Get(), &token);

  // window.open and target=_blank go to the system browser, as they did before.
  m_webView->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>(
      [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
        args->put_Handled(TRUE);
        LPWSTR uri = nullptr;
        args->get_Uri(&uri);
        const QUrl url(fromCoTask(uri));
        if (TrustedOrigins::isSafeExternal(url))
          QDesktopServices::openUrl(url);
        return S_OK;
      }).Get(), &token);

  /*
   * Notifications are granted, which is what the page's settings switch
   * expects; the rest of the device permissions were refused under QtWebEngine
   * and still are. Anything else is left to WebView2's own prompt.
   */
  m_webView->add_PermissionRequested(Callback<ICoreWebView2PermissionRequestedEventHandler>(
      [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
        COREWEBVIEW2_PERMISSION_KIND kind = COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
        args->get_PermissionKind(&kind);
        switch (kind)
        {
          case COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS:
            args->put_State(COREWEBVIEW2_PERMISSION_STATE_ALLOW);
            break;
          case COREWEBVIEW2_PERMISSION_KIND_CAMERA:
          case COREWEBVIEW2_PERMISSION_KIND_MICROPHONE:
          case COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION:
            args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            break;
          default:
            break;
        }
        return S_OK;
      }).Get(), &token);

  m_webView->add_WebResourceRequested(Callback<ICoreWebView2WebResourceRequestedEventHandler>(
      [self](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
        if (self)
          self->serveResource(args);
        return S_OK;
      }).Get(), &token);

  // The renderer can die (out of memory on a small machine, a GPU reset) and
  // take the page with it. Reload it; the browser process going is rarer and
  // means starting WebView2 again.
  m_webView->add_ProcessFailed(Callback<ICoreWebView2ProcessFailedEventHandler>(
      [self](ICoreWebView2* sender, ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
        if (!self)
          return S_OK;
        COREWEBVIEW2_PROCESS_FAILED_KIND kind;
        args->get_ProcessFailedKind(&kind);
        qWarning() << "WebView2: process failed, kind" << kind;
        if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED ||
            kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_UNRESPONSIVE)
        {
          sender->Reload();
        }
        else if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED)
        {
          const QUrl last(self->m_currentUrl);
          QTimer::singleShot(0, self, [self, last]() {
            if (!self)
              return;
            self->m_controller.Reset();
            self->m_webView.Reset();
            self->m_transport->setWebView(nullptr);
            self->m_pendingNavigation = last;
            self->create(self->m_options);
          });
        }
        return S_OK;
      }).Get(), &token);

  ComPtr<ICoreWebView2_14> webView14;
  if (m_options.ignoreCertificateErrors && SUCCEEDED(m_webView.As(&webView14)))
  {
    webView14->add_ServerCertificateErrorDetected(Callback<ICoreWebView2ServerCertificateErrorDetectedEventHandler>(
        [](ICoreWebView2*, ICoreWebView2ServerCertificateErrorDetectedEventArgs* args) -> HRESULT {
          args->put_Action(COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW);
          return S_OK;
        }).Get(), &token);
  }

  // Shortcuts the window owns (F11, Alt+Enter, Ctrl+Q, ...). With focus inside
  // WebView2 these never reach Qt, so they are offered here first.
  m_controller->add_AcceleratorKeyPressed(Callback<ICoreWebView2AcceleratorKeyPressedEventHandler>(
      [self](ICoreWebView2Controller*, ICoreWebView2AcceleratorKeyPressedEventArgs* args) -> HRESULT {
        if (!self || !self->onAcceleratorKey)
          return S_OK;
        COREWEBVIEW2_KEY_EVENT_KIND kind;
        args->get_KeyEventKind(&kind);
        if (kind != COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN && kind != COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN)
          return S_OK;
        UINT key = 0;
        args->get_VirtualKey(&key);
        const bool ctrl = GetKeyState(VK_CONTROL) & 0x8000;
        const bool shift = GetKeyState(VK_SHIFT) & 0x8000;
        const bool alt = GetKeyState(VK_MENU) & 0x8000;
        if (self->onAcceleratorKey(key, ctrl, shift, alt))
          args->put_Handled(TRUE);
        return S_OK;
      }).Get(), &token);

  /*
   * The page's console, into the application log. WebView2 has no console
   * event of its own; the DevTools protocol has, and it is available without
   * DevTools being open or enabled.
   */
  auto subscribe = [this, self](const wchar_t* event, auto handler) {
    ComPtr<ICoreWebView2DevToolsProtocolEventReceiver> receiver;
    if (SUCCEEDED(m_webView->GetDevToolsProtocolEventReceiver(event, &receiver)))
    {
      EventRegistrationToken t;
      receiver->add_DevToolsProtocolEventReceived(Callback<ICoreWebView2DevToolsProtocolEventReceivedEventHandler>(
          [self, handler](ICoreWebView2*, ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args) -> HRESULT {
            LPWSTR json = nullptr;
            if (self && self->onConsoleMessage && SUCCEEDED(args->get_ParameterObjectAsJson(&json)))
              handler(QJsonDocument::fromJson(fromCoTask(json).toUtf8()).object());
            return S_OK;
          }).Get(), &t);
    }
  };
  subscribe(L"Runtime.consoleAPICalled", [self](const QJsonObject& params) {
    const QString type = params.value("type").toString();
    QStringList parts;
    for (const QJsonValue& arg : params.value("args").toArray())
    {
      const QJsonObject o = arg.toObject();
      if (o.contains("value"))
        parts << (o.value("value").isString() ? o.value("value").toString()
                                               : QString::fromUtf8(QJsonDocument(QJsonArray{o.value("value")}).toJson(QJsonDocument::Compact)).mid(1).chopped(1));
      else
        parts << o.value("description").toString();
    }
    const QJsonArray frames = params.value("stackTrace").toObject().value("callFrames").toArray();
    QString where;
    if (!frames.isEmpty())
    {
      const QJsonObject f = frames.first().toObject();
      where = QStringLiteral("%1:%2 ").arg(f.value("url").toString()).arg(f.value("lineNumber").toInt() + 1);
    }
    // QtWebEngine's levels, which SystemComponent::jsLog expects: info, warning, error.
    const int level = (type == "error" || type == "assert") ? 2 : (type == "warning") ? 1 : 0;
    self->onConsoleMessage(level, where + parts.join(' '));
  });
  subscribe(L"Runtime.exceptionThrown", [self](const QJsonObject& params) {
    const QJsonObject details = params.value("exceptionDetails").toObject();
    QString text = details.value("exception").toObject().value("description").toString();
    if (text.isEmpty())
      text = details.value("text").toString();
    self->onConsoleMessage(2, QStringLiteral("%1:%2 %3").arg(details.value("url").toString())
                                  .arg(details.value("lineNumber").toInt() + 1).arg(text));
  });
  m_webView->CallDevToolsProtocolMethod(L"Runtime.enable", L"{}", nullptr);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::serveResource(ICoreWebView2WebResourceRequestedEventArgs* args)
{
  ComPtr<ICoreWebView2WebResourceRequest> request;
  args->get_Request(&request);
  LPWSTR uri = nullptr;
  request->get_Uri(&uri);
  const QUrl url(fromCoTask(uri));
  if (url.host() != kVirtualHost)
    return;

  const QString path = ":" + url.path();
  QFile file(path);
  ComPtr<ICoreWebView2WebResourceResponse> response;
  if (!file.open(QIODevice::ReadOnly))
  {
    m_environment->CreateWebResourceResponse(nullptr, 404, L"Not Found", L"", &response);
    args->put_Response(response.Get());
    return;
  }
  const QByteArray data = file.readAll();
  ComPtr<IStream> stream;
  stream.Attach(SHCreateMemStream(reinterpret_cast<const BYTE*>(data.constData()), UINT(data.size())));
  const QString headers = QStringLiteral("Content-Type: %1\r\nCache-Control: no-cache").arg(contentTypeFor(path));
  m_environment->CreateWebResourceResponse(stream.Get(), 200, L"OK", toW(headers).c_str(), &response);
  args->put_Response(response.Get());
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::showErrorPage(const QString& url, int status)
{
  // The page that failed, with a way to try again. QtWebEngine's error page
  // was off too; this is the stand-in for the QML label that replaced it.
  const QString target = url.toHtmlEscaped();
  const QString html = QStringLiteral(R"HTML(<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;height:100%;background:#07070b;color:#e8e8ef;font:15px/1.5 "Segoe UI",sans-serif}
main{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;text-align:center;padding:0 24px}
h1{font-size:20px;font-weight:600;margin:0}p{margin:0;color:#9a9aab;max-width:460px}
button{margin-top:6px;background:#2b6cff;color:#fff;border:0;border-radius:999px;padding:10px 22px;font:inherit;cursor:pointer}</style></head>
<body><main><h1>Mahfin can't reach your library right now</h1>
<p>Check that this computer is online, then try again. (Error %1)</p>
<button data-url="%2" onclick="location.href=this.dataset.url">Try again</button></main></body></html>)HTML")
      .arg(status)
      .arg(target);
  m_webView->NavigateToString(toW(html).c_str());
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::attachChannel(QWebChannel* channel)
{
  m_channel = channel;
  if (m_controller)
    m_channel->connectTo(m_transport);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::navigate(const QUrl& url)
{
  const QUrl target = mapToVirtualHost(url);
  if (!m_webView)
  {
    m_pendingNavigation = target;
    return;
  }
  m_webView->Navigate(toW(target.toString(QUrl::FullyEncoded)).c_str());
}

void WebViewHost::reload() { if (m_webView) m_webView->Reload(); }
void WebViewHost::goBack() { if (m_webView) m_webView->GoBack(); }
void WebViewHost::goForward() { if (m_webView) m_webView->GoForward(); }

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::setVisible(bool visible)
{
  // Hidden is what makes document.visibilityState "hidden" and throttles the
  // page's timers and animation frames while the window is minimised.
  m_visible = visible;
  if (m_controller)
    m_controller->put_IsVisible(visible ? TRUE : FALSE);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::setBounds(const QRect& physicalRect)
{
  m_bounds = physicalRect;
  if (m_controller)
    m_controller->put_Bounds(RECT{physicalRect.left(), physicalRect.top(),
                                  physicalRect.right() + 1, physicalRect.bottom() + 1});
}

void WebViewHost::notifyWindowMoved() { if (m_controller) m_controller->NotifyParentWindowPositionChanged(); }

void WebViewHost::focus() { if (m_controller) m_controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC); }

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::setCursorHidden(bool hidden)
{
  m_cursorHidden = hidden;
  if (!m_webView)
    return;
  const wchar_t* script = hidden
      ? L"document.documentElement && document.documentElement.setAttribute('data-mahfin-cursor-hidden','')"
      : L"document.documentElement && document.documentElement.removeAttribute('data-mahfin-cursor-hidden')";
  m_webView->ExecuteScript(script, nullptr);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::setZoomFactor(double factor)
{
  if (m_controller)
    m_controller->put_ZoomFactor(factor);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::exitDocumentFullscreen()
{
  if (m_webView)
    m_webView->ExecuteScript(L"document.fullscreenElement && document.exitFullscreen().catch(function(){})", nullptr);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void WebViewHost::raiseAboveVideo()
{
  for (HWND child = GetWindow(m_hwnd, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT))
  {
    wchar_t cls[64] = {};
    GetClassNameW(child, cls, 64);
    if (wcsncmp(cls, L"Chrome_WidgetWin", 16) == 0)
      SetWindowPos(child, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    else if (wcscmp(cls, L"mpv") == 0)
      SetWindowPos(child, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}
