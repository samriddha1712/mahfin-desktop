#include "NativeMainWindow.h"
#include "WebViewHost.h"
#include "settings/SettingsComponent.h"
#include "ui/WindowManager.h"

#include <QAction>
#include <QCoreApplication>
#include <QIcon>
#include <QMenu>
#include <QResizeEvent>
#include <QSystemTrayIcon>

///////////////////////////////////////////////////////////////////////////////////////////////////
NativeMainWindow::NativeMainWindow(QWindow* parent) : QWindow(parent)
{
  setObjectName("mainWindow");
  setTitle("Mahfin");
  setMinimumSize(QSize(213, 120));
  resize(1280, 720);
  setFlags(flags() | Qt::WindowFullscreenButtonHint);

  connect(this, &QWindow::visibilityChanged, this, &NativeMainWindow::updateWebViewVisibility);
  connect(this, &QWindow::windowStateChanged, this, &NativeMainWindow::updateWebViewVisibility);
  connect(&SettingsComponent::Get(), &SettingsComponent::windowsTrayIconChanged, this, &NativeMainWindow::updateTrayIcon);
  updateTrayIcon();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
NativeMainWindow::~NativeMainWindow()
{
  delete m_tray;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::setWebViewHost(WebViewHost* host)
{
  m_host = host;
  updateWebViewBounds();
  updateWebViewVisibility();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::updateWebViewBounds()
{
  if (!m_host)
    return;
  // WebView2 bounds are physical pixels; Qt's sizes are device-independent.
  const qreal dpr = devicePixelRatio();
  m_host->setBounds(QRect(0, 0, qRound(width() * dpr), qRound(height() * dpr)));
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::updateWebViewVisibility()
{
  if (m_host)
    m_host->setVisible(isVisible() && !(windowState() & Qt::WindowMinimized));
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::resizeEvent(QResizeEvent* event)
{
  QWindow::resizeEvent(event);
  updateWebViewBounds();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::moveEvent(QMoveEvent* event)
{
  QWindow::moveEvent(event);
  // Popups the page opens (a <select>, a date picker) are positioned from this.
  if (m_host)
    m_host->notifyWindowMoved();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::exposeEvent(QExposeEvent* event)
{
  QWindow::exposeEvent(event);
  // A DPI change resizes in device pixels without changing the logical size.
  updateWebViewBounds();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::focusInEvent(QFocusEvent* event)
{
  QWindow::focusInEvent(event);
  // Keyboard input belongs to the page. Whenever Windows hands focus to this
  // window -- activation, Alt+Tab, a click on the frame -- pass it on.
  if (m_host)
    m_host->focus();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
bool NativeMainWindow::event(QEvent* event)
{
  if (event->type() == QEvent::Close && m_tray && m_tray->isVisible())
  {
    // Close to the tray rather than quit, when the tray icon is on.
    event->ignore();
    hide();
    return true;
  }
  return QWindow::event(event);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::restoreFromTray()
{
  WindowManager::Get().raiseWindow();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NativeMainWindow::updateTrayIcon()
{
  const bool wanted = SettingsComponent::Get().enableWindowsTrayIcon();
  if (!wanted)
  {
    if (m_tray)
      m_tray->hide();
    return;
  }

  if (!m_tray)
  {
    m_tray = new QSystemTrayIcon(QIcon(":/images/icon.png"));
    m_tray->setToolTip("Mahfin");
    auto* menu = new QMenu();
    QAction* restore = menu->addAction(QCoreApplication::translate("NativeMainWindow", "Restore"));
    menu->addSeparator();
    QAction* quit = menu->addAction(QCoreApplication::translate("NativeMainWindow", "Quit"));
    connect(restore, &QAction::triggered, this, &NativeMainWindow::restoreFromTray);
    connect(quit, &QAction::triggered, qApp, &QCoreApplication::quit);
    m_tray->setContextMenu(menu);
    connect(m_tray, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
      if (reason == QSystemTrayIcon::Context)
        WindowManager::Get().setCursorVisibility(true);
      else
        restoreFromTray();
    });
  }
  m_tray->show();
}
