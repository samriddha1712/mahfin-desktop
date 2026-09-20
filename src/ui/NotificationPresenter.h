#ifndef MAHFIN_NOTIFICATIONPRESENTER_H
#define MAHFIN_NOTIFICATIONPRESENTER_H

#include <QObject>
#include <QSystemTrayIcon>
#include <QtWebEngineCore/QWebEngineNotification>

#include <memory>

/*
 * Draws the notifications the page asks for.
 *
 * QtWebEngine does not show one by itself. A page calling `new Notification()`
 * hands it to whatever `QWebEngineProfile::setNotificationPresenter` installed,
 * and installs nothing by default -- so until this existed, every notification
 * the web client raised was constructed, accepted, and silently dropped. The
 * desktop app could not show one at all, with the window open or shut.
 *
 * ## Why a tray icon
 *
 * Qt has no cross-platform "post a toast" call; `QSystemTrayIcon::showMessage`
 * is the nearest thing there is, and it lands in the right place on each
 * platform -- an Action Center toast on Windows, a notification on macOS,
 * whatever the desktop's daemon draws on Linux.
 *
 * Its cost is a tray presence, so the icon is created on the *first*
 * notification rather than at start-up. Somebody who never turns notifications
 * on never gets one, and by the time it appears they have explicitly asked for
 * notifications in Mahfin's own settings and been granted the permission.
 *
 * ## The page is told what happened
 *
 * A QWebEngineNotification is a live object, not a message: the page is waiting
 * to hear whether it was shown, clicked or closed, and its `onclick` -- which
 * is what navigates to the friend request or the film -- only fires if click()
 * is called. So the most recent one is kept, because QSystemTrayIcon's
 * `messageClicked` does not say which message was clicked and there is only
 * ever one on screen to mean.
 */
class NotificationPresenter : public QObject
{
  Q_OBJECT

public:
  explicit NotificationPresenter(QObject* parent = nullptr);
  ~NotificationPresenter() override;

  /** Installs itself on the default profile. Safe to call once, early. */
  static void install();

  void present(std::unique_ptr<QWebEngineNotification> notification);

private:
  void ensureTray();
  void onMessageClicked();

  QSystemTrayIcon* m_tray = nullptr;
  /** The one currently on screen, so a click can be handed back to the page. */
  std::unique_ptr<QWebEngineNotification> m_current;
};

#endif // MAHFIN_NOTIFICATIONPRESENTER_H
