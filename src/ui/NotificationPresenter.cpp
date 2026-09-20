#include "NotificationPresenter.h"

#include <QApplication>
#include <QIcon>
#include <QPixmap>
#include <QtWebEngineCore/QWebEngineProfile>

#include "WindowManager.h"
#include "utils/Log.h"

///////////////////////////////////////////////////////////////////////////////////////////////////
NotificationPresenter::NotificationPresenter(QObject* parent) : QObject(parent)
{
}

///////////////////////////////////////////////////////////////////////////////////////////////////
NotificationPresenter::~NotificationPresenter()
{
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NotificationPresenter::install()
{
  /*
   * Parented to the application so it outlives every window. A presenter owned
   * by a window would be destroyed on the way out while the profile still held
   * the lambda that captures it, and the profile is destroyed after the
   * windows are.
   */
  auto* presenter = new NotificationPresenter(qApp);

  QWebEngineProfile::defaultProfile()->setNotificationPresenter(
    [presenter](std::unique_ptr<QWebEngineNotification> notification)
    {
      presenter->present(std::move(notification));
    });
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NotificationPresenter::ensureTray()
{
  if (m_tray)
    return;

  if (!QSystemTrayIcon::isSystemTrayAvailable())
  {
    qWarning() << "No system tray on this desktop; notifications cannot be shown";
    return;
  }

  m_tray = new QSystemTrayIcon(this);
  m_tray->setIcon(QIcon(":/images/icon.png"));
  m_tray->setToolTip("Mahfin");
  connect(m_tray, &QSystemTrayIcon::messageClicked, this, &NotificationPresenter::onMessageClicked);
  m_tray->show();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NotificationPresenter::onMessageClicked()
{
  // Bring the app forward first: the page is about to route somewhere, and
  // routing behind another window is the same as doing nothing.
  WindowManager::Get().raiseWindow();

  if (m_current)
    m_current->click();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void NotificationPresenter::present(std::unique_ptr<QWebEngineNotification> notification)
{
  if (!notification)
    return;

  ensureTray();
  if (!m_tray)
  {
    /*
     * Still tell the page it was closed rather than leaving it waiting.
     *
     * A Notification whose lifecycle events never arrive is one the page
     * believes is still on screen; the web client tags its notifications so a
     * second of the same kind replaces the first, and a phantom that never
     * closes would suppress the replacement for as long as the app runs.
     */
    notification->close();
    return;
  }

  /*
   * Replacing the previous one closes it, in that order.
   *
   * The page is entitled to hear `close` for the notification it can no longer
   * see, and it has to hear it *before* the new one is presented: the web
   * client reuses one tag per kind, so a close that arrived afterwards would
   * be read as closing the notification that had just replaced it.
   */
  if (m_current)
    m_current->close();
  m_current = std::move(notification);

  const QImage icon = m_current->icon();
  if (!icon.isNull())
    m_tray->showMessage(m_current->title(), m_current->message(), QIcon(QPixmap::fromImage(icon)));
  else
    m_tray->showMessage(m_current->title(), m_current->message(), QSystemTrayIcon::Information);

  // Says "it is on screen", which is what releases the page's own promise.
  m_current->show();
}
