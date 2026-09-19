#ifndef MAHFIN_GRAPHICSCAPABILITY_H
#define MAHFIN_GRAPHICSCAPABILITY_H

#include <QJsonObject>
#include <QString>
#include <QStringList>

/*
 * What this machine can afford to draw, decided before Qt is started.
 *
 * Everything on screen in this application goes through one OpenGL context:
 * mpvqt draws video through a QQuickFramebufferObject, the scene graph is
 * pinned to desktop OpenGL because of it, and the web page is composited on
 * top. When opengl32.dll resolves to a real driver that is one GPU doing three
 * cheap things. When it does not — no vendor driver installed, a driver Qt
 * blacklists, a virtual machine — Qt falls back to the llvmpipe build it ships
 * as `opengl32sw.dll`, and the same three things are done by the CPU, every
 * frame, at window resolution. The application starts, renders correctly, and
 * saturates every core: what the person in front of it sees is their whole
 * machine seizing up, and what they report is "it crashes and freezes
 * everything".
 *
 * Qt makes that fallback silently and there is no supported hook in front of
 * it, so this asks what it can first, with the Win32 API and no Qt at all, and
 * the answer decides how much work the rest of the process asks for: which
 * Chromium switches are set, whether QML animates, and what the web client is
 * told about the machine it has landed on.
 *
 * It is deliberately a cheap, conservative check rather than a definitive one
 * — see the note on probeWindowsAdapter for what it can and cannot see, and
 * why. The start-up lock in main() is the backstop for everything it misses,
 * and the `graphicsMode` setting is the manual override for both.
 *
 * Safe to call before QCoreApplication exists. That is the point of it: the
 * Chromium flags have to be in the environment before
 * QtWebEngineQuick::initialize(), which is long before any Qt GL code runs.
 */
namespace GraphicsCapability
{
  enum class Tier
  {
    /** Not probed, or the probe could not answer. Treated as Normal. */
    Unknown,
    /** Nothing says otherwise. Everything on. */
    Normal,
    /** A CPU is drawing, or there is not enough machine. */
    Low,
  };

  struct Info
  {
    /** The probe ran and found something to report. */
    bool probed = false;
    /** Nothing is accelerating the drawing. */
    bool softwareRenderer = false;
    /** The display adapters Windows reports, comma separated. Empty elsewhere. */
    QString adapter;
    quint64 memoryMB = 0;
    int cores = 0;
    Tier tier = Tier::Unknown;
    /** Why it was put in the tier it is in, in words fit for showing someone. */
    QStringList reasons;

    bool isLow() const { return tier == Tier::Low; }
  };

  /** Probes once and caches. Subsequent calls are free. */
  const Info& probe();

  /*
   * Overrides, applied whether or not probe() has already run.
   *
   * These exist so that the verdict is decided in exactly one place. main()
   * has three things to weigh — the start-up guard, the `graphicsMode`
   * setting, and the probe — and if it folded them into a local `bool` then
   * SystemComponent, which hands the answer to QML and to the web client,
   * would be re-deriving it from the probe alone and quietly disagreeing with
   * the flags the process was actually started with. Pushing the overrides in
   * here means everything downstream reads one answer.
   *
   * Low wins over normal, structurally rather than by call order: the only
   * caller of forceLow that is not a preference is the crash guard, and
   * evidence that the last run died must not be overridden by a setting.
   */
  void forceLow(const QString& reason);
  void forceNormal(const QString& reason);

  /** For the log, and for the nativeshell payload the web client reads. */
  QJsonObject toJson();
  QString describe();
}

#endif // MAHFIN_GRAPHICSCAPABILITY_H
