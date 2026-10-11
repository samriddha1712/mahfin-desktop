#ifndef TRUSTEDORIGINS_H
#define TRUSTEDORIGINS_H

#include <QRegularExpression>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariant>

/*
 * Where the shell's page is allowed to be.
 *
 * Every page the window shows gets the native bridge — the player, the system
 * object, the settings — and those can start programs (mpv's own commands),
 * open any URL with the operating system, fetch local files and rewrite the
 * startup address. Upstream jellyfin-desktop let the window go anywhere, so a
 * link, a redirect or a single injected script could take the user's machine.
 * The window now stays on Mahfin; anything else opens in the system browser,
 * and the bridge refuses the dangerous calls even from Mahfin's own pages.
 * (Found in the 2026-10-12 security review.)
 *
 * Trusted: the bundled pages (qrc: on Qt, the WebView2 virtual host on
 * Windows), Mahfin's public addresses over https, and the two home-network
 * addresses the household uses at home.
 */
namespace TrustedOrigins
{
  inline bool isTrusted(const QUrl& url)
  {
    const QString scheme = url.scheme().toLower();
    const QString host = url.host().toLower();
    if (scheme == "qrc")
      return true;
    static const QStringList hosts = {
      "mahfin.online", "www.mahfin.online", "jf.mahfin.online", "app.mahfin.invalid"};
    if (scheme == "https")
      return hosts.contains(host) && url.port(443) == 443;
    // Plain http only as the way in: the connect screen prefixes "http://"
    // to an address typed without a scheme, and the edge answers that with a
    // redirect to https. (HSTS keeps it there afterwards.)
    if (scheme == "http" && hosts.contains(host))
      return url.port(80) == 80;
    if (scheme == "http" && host == "192.168.29.96")
      return url.port() == 8096 || url.port() == 8098;
    return false;
  }

  inline bool isTrusted(const QString& url) { return isTrusted(QUrl(url)); }

  // What may be handed to the operating system to open: web pages only, never
  // file:, custom schemes or anything that launches a program.
  inline bool isSafeExternal(const QUrl& url)
  {
    const QString scheme = url.scheme().toLower();
    return (scheme == "https" || scheme == "http") && !url.host().isEmpty();
  }

  /*
   * Settings the page must not be able to point somewhere else. The startup
   * address and the saved server decide what the window loads — with the
   * whole bridge — on every launch from then on, and ignoreSSLErrors would
   * let a network attacker stand in for Mahfin. Checked on every write,
   * including loading the file, so a value planted earlier does not survive.
   */
  inline bool isAllowedSetting(const QString& section, const QString& key, const QVariant& value)
  {
    const QString v = value.toString().trimmed();
    auto addressOk = [&]() {
      if (v.isEmpty() || v == "bundled")
        return true;
      return isTrusted(QUrl(v.startsWith("http") || v.startsWith("qrc") ? v : "http://" + v));
    };
    if (section == "main" && (key == "userWebClient" || key == "startupurl"))
      return addressOk();
    if (section == "main" && key == "ignoreSSLErrors")
      return !value.toBool();
    if (section == "path")
      return addressOk();
    return true;
  }

  /*
   * The only mpv commands the page needs: the subtitle styling the web app
   * sets (sub-scale, sub-pos, sub-back-color). mpv's command language can
   * also `run` programs, load scripts and write files, so nothing else passes.
   */
  inline bool isAllowedMpvCommand(const QString& command)
  {
    static const QRegularExpression allowed(
      QStringLiteral(R"(^set (sub-scale|sub-pos|sub-back-color|sub-color|sub-border-color|sub-font-size) ("#[0-9A-Fa-f]{6,8}"|-?[0-9]{1,4}(\.[0-9]{1,4})?)$)"));
    return allowed.match(command).hasMatch();
  }
}

#endif // TRUSTEDORIGINS_H
