#ifndef NATIVEMAINWINDOW_H
#define NATIVEMAINWINDOW_H

#include <QWindow>
#include <QPointer>

class QSystemTrayIcon;
class WebViewHost;

/*
 * The application window of the Windows shell.
 *
 * A plain QWindow: Qt draws nothing into it. mpv presents the video into it
 * directly and WebView2 is its child, above the video. What is left for this
 * class is keeping WebView2 the size of the window, hiding the page while the
 * window is minimised, and what webview.qml's Window used to do -- the minimum
 * size, closing to the tray, the tray icon itself.
 *
 * WindowManager drives it exactly as it drove the QQuickWindow: it only ever
 * used the QWindow half of that.
 */
class NativeMainWindow : public QWindow
{
  Q_OBJECT
public:
  explicit NativeMainWindow(QWindow* parent = nullptr);
  ~NativeMainWindow() override;

  void setWebViewHost(WebViewHost* host);
  void updateTrayIcon();

protected:
  bool event(QEvent* event) override;
  void resizeEvent(QResizeEvent* event) override;
  void moveEvent(QMoveEvent* event) override;
  void exposeEvent(QExposeEvent* event) override;
  void focusInEvent(QFocusEvent* event) override;

private:
  void updateWebViewBounds();
  void updateWebViewVisibility();
  void restoreFromTray();

  QPointer<WebViewHost> m_host;
  QSystemTrayIcon* m_tray = nullptr;
};

#endif // NATIVEMAINWINDOW_H
