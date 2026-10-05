#include "NativeShell.h"
#include "NativeMainWindow.h"
#include "WebViewHost.h"

#include "core/ComponentManager.h"
#include "core/ProfileManager.h"
#include "player/PlayerComponent.h"
#include "settings/SettingsComponent.h"
#include "system/SystemComponent.h"
#include "ui/WindowManager.h"
#include "UniqueApplication.h"

#include <QApplication>
#include <QDebug>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QMessageBox>
#include <QUrl>
#include <QWebChannel>

namespace
{
  /*
   * Carries the page's saved state across from QtWebEngine, once.
   *
   * The web client keeps the signed-in session and its device id in
   * localStorage. A new browser profile would sign everybody out on the update
   * and make Jellyfin see a new device. Both engines are Chromium and store
   * localStorage in the same LevelDB format, so the directory is copied into
   * the place WebView2 looks for it -- before WebView2 first starts, and only if
   * it has never started here.
   */
  void migrateLocalStorage(const QString& userDataFolder)
  {
    const QString target = userDataFolder + "/EBWebView/Default/Local Storage/leveldb";
    if (QDir(userDataFolder + "/EBWebView").exists())
      return;

    const QString source = ProfileManager::activeProfile().dataDir("QtWebEngine") + "/Local Storage/leveldb";
    if (!QDir(source).exists())
      return;

    QDir().mkpath(target);
    int copied = 0;
    QDirIterator it(source, QDir::Files);
    while (it.hasNext())
    {
      const QString file = it.next();
      const QString name = QFileInfo(file).fileName();
      if (name == "LOCK")
        continue;
      if (QFile::copy(file, target + "/" + name))
        copied++;
    }
    qInfo() << "Carried" << copied << "localStorage files over from QtWebEngine";
  }

  /*
   * A WebView2 runtime that ships next to the executable wins over the
   * system's. The portable build can carry one, for machines where the
   * Evergreen runtime is missing and cannot be installed.
   */
  QString bundledRuntimeFolder()
  {
    const QString folder = QCoreApplication::applicationDirPath() + "/webview2";
    return QFileInfo::exists(folder + "/msedgewebview2.exe") ? folder : QString();
  }

  bool isPlayUrl(const QString& url)
  {
    return QUrl(url).path().contains("/play/");
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
bool NativeShell::start(UniqueApplication* uniqueApp, const Options& options)
{
  const QString runtimeFolder = bundledRuntimeFolder();
  const QString runtime = WebViewHost::runtimeVersion(runtimeFolder);
  if (runtime.isEmpty())
  {
    qCritical() << "No WebView2 runtime found";
    QMessageBox box(QMessageBox::Critical, QObject::tr("Mahfin"),
                    QObject::tr("Mahfin needs the Microsoft Edge WebView2 Runtime, which is not installed "
                                "on this computer.\n\nIt is free and takes a minute to install. Open the "
                                "download page now?"),
                    QMessageBox::Yes | QMessageBox::No);
    if (box.exec() == QMessageBox::Yes)
      QDesktopServices::openUrl(QUrl("https://go.microsoft.com/fwlink/p/?LinkId=2124703"));
    return false;
  }
  qInfo() << "WebView2 runtime" << runtime << (runtimeFolder.isEmpty() ? "(system)" : "(bundled)");
  SystemComponent::Get().setBrowserEngineVersion(runtime);

  auto* window = new NativeMainWindow();
  // The window handle has to exist before mpv is given it, and mpv's own
  // window has to exist before WebView2's, so that the page is the one on top.
  window->create();
  PlayerComponent::Get().initializeNativeMpv(window);

  WindowManager::Get().initializeWindow(window);
  window->show();

  auto* host = new WebViewHost(window, window);
  auto* channel = new QWebChannel(host);
  ComponentManager::Get().setWebChannel(channel);
  host->attachChannel(channel);

  window->setWebViewHost(host);
  WindowManager::Get().setWebViewHost(host);
  PlayerComponent::Get().setWebViewVisibilityHandler([host](bool visible) { host->setVisible(visible); });

  // A new document is a new page: whatever the old one was playing stops, as
  // webview.qml did on every load start.
  host->onNavigationStarting = []() { PlayerComponent::Get().stop(); };

  host->onFullscreenRequested = [host](bool enable) {
    /*
     * Moving to the next episode is a full page load into another /play/ URL.
     * The outgoing document leaving fullscreen as it is torn down is not the
     * person asking to leave, so the window stays where it is.
     */
    if (!enable && host->isLoading() && isPlayUrl(host->currentUrl()))
      return;
    WindowManager::Get().setFullScreen(enable);
  };
  QObject::connect(window, &QWindow::visibilityChanged, host, [host](QWindow::Visibility visibility) {
    if (visibility != QWindow::FullScreen)
      host->exitDocumentFullscreen();
  });

  host->onConsoleMessage = [](int level, const QString& message) {
    SystemComponent::Get().jsLog(level, message);
  };

  host->onAcceleratorKey = [window, host](UINT key, bool ctrl, bool shift, bool alt) -> bool {
    Q_UNUSED(shift);
    if (key == VK_F11 || (alt && key == VK_RETURN))
    {
      WindowManager::Get().toggleFullscreen();
      return true;
    }
    if (ctrl && key == 'Q')
    {
      qApp->quit();
      return true;
    }
    if (ctrl && (key == 'W' || key == VK_F4))
    {
      window->close();
      return true;
    }
    if (ctrl && key == '0')
    {
      host->setZoomFactor(1.0);
      return true;
    }
    return false;
  };

  // mpv recreates its window if its video output restarts; keep the page above it.
  QObject::connect(&PlayerComponent::Get(), &PlayerComponent::windowVisible, host, [host]() { host->raiseAboveVideo(); });

  QObject::connect(host, &WebViewHost::ready, host, [host]() {
    host->raiseAboveVideo();
    const bool desktopMode = SettingsComponent::Get().value(SETTINGS_SECTION_MAIN, "webMode").toString() != "tv";
    QString startUrl = SettingsComponent::Get().getWebClientUrl(desktopMode);
    const QString override = SettingsComponent::Get().value(SETTINGS_SECTION_MAIN, "startupurl").toString();
    if (!override.isEmpty())
      startUrl = override;
    host->navigate(QUrl(startUrl));
  });

  QObject::connect(host, &WebViewHost::failed, host, [](const QString& reason) {
    qCritical() << "WebView2 failed:" << reason;
    QMessageBox::critical(nullptr, QObject::tr("Mahfin"),
                          QObject::tr("Mahfin could not start its web view.\n\n%1").arg(reason));
    qApp->quit();
  });

  QObject::connect(uniqueApp, &UniqueApplication::otherApplicationStarted, []() {
    WindowManager::Get().raiseWindow();
  });

  WebViewHost::Options webOptions;
  webOptions.userDataFolder = ProfileManager::activeProfile().dataDir("WebView2");
  webOptions.browserArguments = options.browserArguments;
  webOptions.userAgent = SystemComponent::Get().getUserAgent();
  webOptions.injectedScript = SystemComponent::Get().getNativeShellScript();
  webOptions.allowZoom = SettingsComponent::Get().allowBrowserZoom();
  webOptions.ignoreCertificateErrors = options.ignoreCertificateErrors || SettingsComponent::Get().ignoreSSLErrors();
  webOptions.devTools = options.devTools;
  webOptions.browserExecutableFolder = runtimeFolder;

  QDir().mkpath(webOptions.userDataFolder);
  migrateLocalStorage(webOptions.userDataFolder);

  host->create(webOptions);
  return true;
}
