#ifndef WEBVIEWHOST_H
#define WEBVIEWHOST_H

#include <QObject>
#include <QRect>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QWebChannelAbstractTransport>
#include <functional>

#include <windows.h>
#include <wrl/client.h>
#include <WebView2.h>

class QWebChannel;
class QWindow;

/*
 * The QWebChannel transport over WebView2's message port.
 *
 * QtWebEngine provided `window.qt.webChannelTransport` itself. Here the page
 * gets a shim with the same shape (see the injected script in WebViewHost.cpp),
 * so qwebchannel.js and nativeshell.js run unchanged and the C++ components are
 * published exactly as before.
 */
class WebViewTransport : public QWebChannelAbstractTransport
{
  Q_OBJECT
public:
  explicit WebViewTransport(QObject* parent = nullptr) : QWebChannelAbstractTransport(parent) {}
  void setWebView(ICoreWebView2* webView) { m_webView = webView; }
  void sendMessage(const QJsonObject& message) override;
  void receive(const QString& json);

private:
  Microsoft::WRL::ComPtr<ICoreWebView2> m_webView;
};

/*
 * Hosts the web client in WebView2, above mpv, for the Windows shell.
 *
 * This replaces webview.qml's WebEngineView. Each feature that file provided
 * has its equivalent here, and the page cannot tell the difference: the same
 * script is injected before any page script runs, the same objects are on the
 * channel, and the page background is transparent so mpv shows through it.
 *
 * WebView2 is created asynchronously; ready() fires once the page can be
 * navigated. Everything that depends on the rest of the application -- what to
 * do when the page asks for fullscreen, what to log -- is a callback, so this
 * class knows nothing about the components.
 */
class WebViewHost : public QObject
{
  Q_OBJECT
public:
  struct Options
  {
    QString userDataFolder;
    QStringList browserArguments;
    QString userAgent;
    QString injectedScript;      // getNativeShellScript(): jmpInfo + qwebchannel.js + native/*.js
    bool allowZoom = false;
    bool ignoreCertificateErrors = false;
    bool devTools = false;
    QString browserExecutableFolder;  // a fixed-version runtime shipped with the app, if any
  };

  // Called with a page-initiated fullscreen change, a log line, a shortcut.
  std::function<void(bool)> onFullscreenRequested;
  std::function<void()> onNavigationStarting;
  std::function<void(bool ok)> onNavigationCompleted;
  std::function<void(int level, const QString& message)> onConsoleMessage;
  // Return true if the key was handled and must not reach the page.
  std::function<bool(UINT key, bool ctrl, bool shift, bool alt)> onAcceleratorKey;

  explicit WebViewHost(QWindow* window, QObject* parent = nullptr);
  ~WebViewHost() override;

  // The runtime's version, or an empty string if no WebView2 runtime is installed.
  static QString runtimeVersion(const QString& browserExecutableFolder = QString());

  void create(const Options& options);
  void attachChannel(QWebChannel* channel);
  bool isReady() const { return m_controller != nullptr; }

  void navigate(const QUrl& url);
  void reload();
  void goBack();
  void goForward();
  void setVisible(bool visible);
  void setBounds(const QRect& physicalRect);
  void notifyWindowMoved();
  void focus();
  void setCursorHidden(bool hidden);
  void setZoomFactor(double factor);
  // Leaves DOM fullscreen when the window has left fullscreen some other way
  // (F11, the window manager), so the page does not think it is still in it.
  void exitDocumentFullscreen();
  // mpv's window is a sibling under WebView2's. Puts the page back on top if
  // mpv ever recreates its window above it.
  void raiseAboveVideo();

  // The URL a navigation in progress is heading to, or the current one.
  QString currentUrl() const { return m_currentUrl; }
  bool isLoading() const { return m_loading; }

  // Maps a qrc: URL onto the virtual host the bundled pages are served from.
  static QUrl mapToVirtualHost(const QUrl& url);

Q_SIGNALS:
  void ready();
  void failed(const QString& reason);

private:
  void onControllerCreated(ICoreWebView2Controller* controller);
  void installHandlers();
  void serveResource(ICoreWebView2WebResourceRequestedEventArgs* args);
  void showErrorPage(const QString& url, int status);

  QWindow* m_window;
  HWND m_hwnd;
  Options m_options;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> m_environment;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> m_controller;
  Microsoft::WRL::ComPtr<ICoreWebView2> m_webView;
  WebViewTransport* m_transport;
  QWebChannel* m_channel = nullptr;
  QRect m_bounds;
  bool m_visible = true;
  bool m_cursorHidden = false;
  bool m_loading = false;
  QString m_currentUrl;
  QUrl m_pendingNavigation;
};

#endif // WEBVIEWHOST_H
