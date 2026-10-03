#include "GraphicsCapability.h"

#include <QJsonArray>
#include <QThread>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace
{
  GraphicsCapability::Info g_info;
  bool g_probed = false;
  bool g_forcedLow = false;
  bool g_forcedNormal = false;
  QStringList g_forcedReasons;

  /** Applies the overrides, in the order that makes low win. */
  void applyOverrides(GraphicsCapability::Info& info)
  {
    if (g_forcedNormal)
      info.tier = GraphicsCapability::Tier::Normal;
    if (g_forcedLow)
      info.tier = GraphicsCapability::Tier::Low;
  }

  /**
   * Below this, QtWebEngine and mpv and the scene graph do not fit at once.
   *
   * Chromium reserves a few hundred MB per process and this runs three of
   * them; mpv's demuxer cache defaults to 75MB; the scene graph holds a
   * window-sized texture per layer. On 4GB the machine is already swapping
   * before the library has loaded, and swapping is indistinguishable from a
   * freeze.
   */
  constexpr quint64 kLowMemoryMB = 4096;

  /** Two cores have to run Chromium's renderer, its IO thread and the UI. */
  constexpr int kLowCoreCount = 2;

#ifdef Q_OS_WIN

  /**
   * Adapter names that mean there is no graphics driver worth the name.
   *
   * Matched case-insensitively against what the display device list reports.
   * These are the drivers Windows falls back to when no vendor one has been
   * installed, plus the remote-desktop ones, which have the same consequence:
   * no OpenGL ICD, so opengl32.dll resolves to the GDI software
   * implementation, so Qt loads llvmpipe.
   */
  const char* const kBasicAdapters[] = {
    "microsoft basic display",
    "microsoft basic render",
    "microsoft remote display",
    "standard vga",
    "rdpdd",
    "rdpudd",
  };

  /** Whether an adapter name is one of the no-driver fallbacks above. */
  bool isBasicAdapter(const QString& name)
  {
    const QString lowered = name.toLower();
    for (const char* marker : kBasicAdapters)
    {
      if (lowered.contains(QLatin1String(marker)))
        return true;
    }
    return false;
  }

  /**
   * Which display adapter Windows is using, without touching OpenGL.
   *
   * ## Why not simply create a context and read GL_RENDERER
   *
   * That is the direct question, and it cannot be asked from here. Reading the
   * renderer string needs a current context; a context needs a pixel format;
   * a pixel format needs a window — and creating a window settles the
   * process's DPI awareness at whatever the default is. This executable ships
   * no manifest, so that default is "unaware", and Qt sets per-monitor
   * awareness itself during QGuiApplication construction, which happens after
   * this runs. SetProcessDpiAwarenessContext fails once the mode is settled,
   * so probing that way would leave every high-DPI display rendering a
   * scaled-up blur. A diagnosis is not worth a regression, and a soft window
   * on every 4K laptop is a far more visible fault than the one being
   * diagnosed.
   *
   * ## What this asks instead
   *
   * The adapter's own name. It does not say which OpenGL implementation will
   * be loaded, but it answers the case that accounts for most of these
   * reports: a machine running on Microsoft's built-in display driver because
   * no vendor driver was ever installed.
   *
   * The cases it cannot see — a vendor driver that is present but too old, or
   * one Qt blacklists — are caught by the start-up lock in main(), at the cost
   * of one bad launch, and by the `graphicsMode` setting for anyone who would
   * rather not have that launch at all.
   */
  void probeWindowsAdapter(GraphicsCapability::Info& info)
  {
    /*
     * Every attached adapter, not just the first. A laptop with switchable
     * graphics enumerates both, and a machine is only in trouble when there is
     * nothing but a basic adapter on the list.
     */
    bool sawAny = false;
    bool sawReal = false;
    QStringList names;

    DISPLAY_DEVICEW device = {};
    for (DWORD i = 0; ; ++i)
    {
      // Reset before every call: EnumDisplayDevices writes the whole struct,
      // and it reads `cb` to decide how much of it it may write.
      device = DISPLAY_DEVICEW{};
      device.cb = sizeof(device);
      if (!EnumDisplayDevicesW(nullptr, i, &device, 0))
        break;

      // Mirroring drivers are screen-capture hooks, not something anything
      // draws through, and counting one as a real adapter would mask a machine
      // that has only a basic one.
      if (device.StateFlags & DISPLAY_DEVICE_MIRRORING_DRIVER)
        continue;

      const QString name = QString::fromWCharArray(device.DeviceString).trimmed();
      if (name.isEmpty())
        continue;

      sawAny = true;
      if (!names.contains(name))
        names << name;

      if (!isBasicAdapter(name))
        sawReal = true;
    }

    info.adapter = names.join(", ");
    info.probed = sawAny;

    if (sawAny && !sawReal)
    {
      info.softwareRenderer = true;
      info.reasons << QStringLiteral(
                        "the only display adapter is a basic Windows one (%1), so there is no "
                        "graphics driver and every pixel is drawn by the processor")
                        .arg(info.adapter);
    }
  }

  void probeWindowsMachine(GraphicsCapability::Info& info)
  {
    MEMORYSTATUSEX mem = {};
    mem.dwLength = sizeof(mem);
    if (GlobalMemoryStatusEx(&mem))
      info.memoryMB = mem.ullTotalPhys / (1024ull * 1024ull);

    SYSTEM_INFO sys = {};
    GetNativeSystemInfo(&sys);
    info.cores = static_cast<int>(sys.dwNumberOfProcessors);
  }

#endif // Q_OS_WIN

  /**
   * Pretend to be a smaller machine, for reproducing a report on a big one.
   *
   * The machines this file exists for are the ones nobody developing it owns,
   * and the probe reads the real hardware, so a CPU-limited job object or a
   * VM with the host's RAM still classifies as a workstation. This replaces
   * what the probe *found* — before classify() runs, so every downstream
   * decision follows exactly as it would on the real thing:
   *
   *   MAHFIN_SIMULATE_MACHINE="ram=4096;cores=2;adapter=Microsoft Basic Display Adapter"
   *
   * Any key may be left out. It says so in the log on every launch, because a
   * forgotten environment variable quietly flattening the interface is the
   * kind of bug that takes a day to find.
   */
  void applySimulation(GraphicsCapability::Info& info)
  {
    const QString spec = qEnvironmentVariable("MAHFIN_SIMULATE_MACHINE");
    if (spec.isEmpty())
      return;

    for (const QString& part : spec.split(';', Qt::SkipEmptyParts))
    {
      const QString key = part.section('=', 0, 0).trimmed();
      const QString value = part.section('=', 1).trimmed();
      if (key == QLatin1String("ram"))
        info.memoryMB = value.toULongLong();
      else if (key == QLatin1String("cores"))
        info.cores = value.toInt();
      else if (key == QLatin1String("adapter"))
      {
        info.adapter = value;
        info.probed = true;
#ifdef Q_OS_WIN
        info.softwareRenderer = isBasicAdapter(value);
#endif
        info.reasons.clear();
        if (info.softwareRenderer)
          info.reasons << QStringLiteral("the only display adapter is a basic Windows one (%1), so "
                                         "there is no graphics driver and every pixel is drawn by "
                                         "the processor").arg(value);
      }
    }
    qWarning() << "MAHFIN_SIMULATE_MACHINE is set, probing a pretend machine:" << spec;
  }

  void classify(GraphicsCapability::Info& info)
  {
    if (info.softwareRenderer)
      info.tier = GraphicsCapability::Tier::Low;

    if (info.memoryMB > 0 && info.memoryMB < kLowMemoryMB)
    {
      info.tier = GraphicsCapability::Tier::Low;
      info.reasons << QStringLiteral(
                        "%1 MB of RAM is below the %2 MB three Chromium processes and mpv need")
                        .arg(info.memoryMB).arg(kLowMemoryMB);
    }

    if (info.cores > 0 && info.cores <= kLowCoreCount)
    {
      info.tier = GraphicsCapability::Tier::Low;
      info.reasons << QStringLiteral(
                        "%1 logical cores is not enough to composite and decode at once")
                        .arg(info.cores);
    }

    if (info.tier == GraphicsCapability::Tier::Unknown)
      info.tier = GraphicsCapability::Tier::Normal;
  }
}

/////////////////////////////////////////////////////////////////////////////////////////
void GraphicsCapability::forceLow(const QString& reason)
{
  g_forcedLow = true;
  g_forcedReasons << reason;

  // Already probed: fold the decision into the answer everybody else holds.
  if (g_probed)
  {
    g_info.reasons << reason;
    applyOverrides(g_info);
  }
}

/////////////////////////////////////////////////////////////////////////////////////////
void GraphicsCapability::forceNormal(const QString& reason)
{
  g_forcedNormal = true;
  g_forcedReasons << reason;

  if (g_probed)
  {
    g_info.reasons << reason;
    applyOverrides(g_info);
  }
}

/////////////////////////////////////////////////////////////////////////////////////////
const GraphicsCapability::Info& GraphicsCapability::probe()
{
  if (g_probed)
    return g_info;
  g_probed = true;

#ifdef Q_OS_WIN
  probeWindowsMachine(g_info);
  probeWindowsAdapter(g_info);
#else
  /*
   * Elsewhere this is a machine-size check and nothing more.
   *
   * macOS has one OpenGL implementation and it is always the GPU's. Linux can
   * land on llvmpipe, but detectOpenGLEarly() there already creates an mpv
   * handle to work out the hwdec interop, and adding a second graphics probe
   * in front of it buys a guess at the cost of another thing to go wrong on
   * the platform that has the most graphics stacks to go wrong.
   */
  g_info.cores = QThread::idealThreadCount();
#endif

  applySimulation(g_info);
  g_info.reasons << g_forcedReasons;

  // classify() first, so the reasons it finds are recorded even when an
  // override then decides the tier — the log should say what the machine looks
  // like as well as what it was told to do.
  classify(g_info);
  applyOverrides(g_info);
  return g_info;
}

/////////////////////////////////////////////////////////////////////////////////////////
QJsonObject GraphicsCapability::toJson()
{
  const Info& info = probe();
  QJsonObject json;
  json.insert("tier", info.isLow() ? "low" : "normal");
  json.insert("softwareRenderer", info.softwareRenderer);
  json.insert("adapter", info.adapter);
  json.insert("memoryMB", static_cast<double>(info.memoryMB));
  json.insert("cores", info.cores);

  QJsonArray reasons;
  for (const QString& reason : info.reasons)
    reasons.append(reason);
  json.insert("reasons", reasons);
  return json;
}

/////////////////////////////////////////////////////////////////////////////////////////
QString GraphicsCapability::describe()
{
  const Info& info = probe();
  QString out = QStringLiteral("graphics tier=%1").arg(info.isLow() ? "low" : "normal");
  if (!info.adapter.isEmpty())
    out += QStringLiteral(" adapter=\"%1\"").arg(info.adapter);
  if (info.memoryMB)
    out += QStringLiteral(" ram=%1MB").arg(info.memoryMB);
  if (info.cores)
    out += QStringLiteral(" cores=%1").arg(info.cores);
  return out;
}
