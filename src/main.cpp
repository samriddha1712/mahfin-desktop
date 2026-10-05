#include <QGuiApplication>
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIcon>
#include <optional>
#include <Qt>
#ifndef MAHFIN_NATIVE_SHELL
#include <QtQml>
#include <QtWebEngineQuick>
#include <qtwebenginecoreglobal.h>
#include <QtWebEngineCore/QWebEngineProfile>
#include <QtWebEngineCore/QWebEngineScript>
#endif
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QDebug>
#include <QSettings>
#include <QDateTime>
#include <QTimer>

#include "shared/Names.h"
#include "system/SystemComponent.h"
#include "Paths.h"
#include "core/ProfileManager.h"
#include "player/PlayerComponent.h"
#ifndef MAHFIN_NATIVE_SHELL
#include "player/OpenGLDetect.h"
#endif
#include "display/DisplayComponent.h"
#include "Version.h"
#include "settings/SettingsComponent.h"
#include "settings/SettingsSection.h"
#include "ui/WindowManager.h"
#include "ui/ErrorMessage.h"
#ifdef MAHFIN_NATIVE_SHELL
#include "ui/win/NativeShell.h"
#else
#include "ui/EventFilter.h"
#include "Globals.h"
#include "ui/NotificationPresenter.h"
#endif
#include "UniqueApplication.h"
#include "utils/GraphicsCapability.h"
#include "utils/Log.h"

#ifdef Q_OS_MAC
#include "PFMoveApplication.h"
#endif

#if defined(Q_OS_MAC) || defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)
#include "SignalManager.h"
#endif

#if defined(Q_OS_WIN) && defined(_M_X64)
#include <windows.h>
#include <cstdio>

/////////////////////////////////////////////////////////////////////////////////////////
// Check AVX2 support and swap libmpv DLL if needed (before delay-load triggers)
// Only relevant for x64 - ARM64 doesn't have AVX2
static void setupMpvFallback()
{
  // Check if AVX2 is available (PF_AVX2_INSTRUCTIONS_AVAILABLE = 40)
  if (IsProcessorFeaturePresent(40))
  {
    fprintf(stderr, "AVX2 supported, using primary libmpv\n");
    return;
  }

  fprintf(stderr, "AVX2 not supported, checking for fallback libmpv\n");

  // Get application directory
  wchar_t exePath[MAX_PATH];
  GetModuleFileNameW(nullptr, exePath, MAX_PATH);
  std::wstring appDir(exePath);
  size_t lastSlash = appDir.find_last_of(L"\\/");
  if (lastSlash != std::wstring::npos)
    appDir = appDir.substr(0, lastSlash + 1);

  std::wstring fallbackPath = appDir + L"libmpv-fallback.dll";
  std::wstring primaryPath = appDir + L"libmpv-2.dll";

  // Check if fallback exists
  if (GetFileAttributesW(fallbackPath.c_str()) == INVALID_FILE_ATTRIBUTES)
  {
    fprintf(stderr, "No fallback libmpv available\n");
    return;
  }

  // Delete primary and rename fallback
  DeleteFileW(primaryPath.c_str());
  if (MoveFileW(fallbackPath.c_str(), primaryPath.c_str()))
    fprintf(stderr, "Switched to fallback libmpv (non-AVX2)\n");
  else
    fprintf(stderr, "Failed to switch to fallback libmpv\n");
}
#endif

/////////////////////////////////////////////////////////////////////////////////////////
static void preinitQt()
{
  QCoreApplication::setApplicationName(Names::DataName());
  QCoreApplication::setApplicationVersion(Version::GetVersionString());
  QCoreApplication::setOrganizationDomain("mahfin.online");

#ifdef Q_OS_WIN32
  // Qt 6 uses desktop OpenGL by default on Windows
  // AA_UseOpenGLES and AA_UseDesktopOpenGL are deprecated and ignored
  // No need to set any attributes
#endif
}

/////////////////////////////////////////////////////////////////////////////////////////
char** appendCommandLineArguments(int argc, char **argv, const QStringList& args)
{
  size_t newSize = static_cast<size_t>(argc + args.length() + 1) * sizeof(char*);
  char** newArgv = static_cast<char**>(calloc(1, newSize));
  memcpy(newArgv, argv, static_cast<size_t>(argc) * sizeof(char*));

  int pos = argc;
  for(const QString& str : args)
    newArgv[pos++] = qstrdup(str.toUtf8().data());

  return newArgv;
}

/////////////////////////////////////////////////////////////////////////////////////////
void ShowLicenseInfo()
{
  QFile licenses(":/misc/licenses.txt");
  if (!licenses.open(QIODevice::ReadOnly | QIODevice::Text))
  {
    fprintf(stderr, "Error: Could not open license file\n");
    return;
  }
  QByteArray contents = licenses.readAll();
  printf("%.*s\n", static_cast<int>(contents.size()), contents.data());
}

/////////////////////////////////////////////////////////////////////////////////////////
/*
 * Nothing here any more, and the list stays for the mechanism.
 *
 * This used to carry `--enable-gpu-rasterization` and a `--disable-features`
 * switch, appended to argv before anything had been read. Both were wrong in
 * the same way: argv is built before the profile is resolved, so the flags
 * were fixed before there was any way to know what machine they were being
 * fixed on — and asking Chromium to raster on the GPU is actively harmful when
 * the "GPU" is llvmpipe answering from the CPU.
 *
 * They now go through QTWEBENGINE_CHROMIUM_FLAGS further down, which is set
 * after the graphics probe and before QtWebEngineQuick::initialize(), so the
 * switches can differ per machine. Appending to argv still has to happen, and
 * an empty list is the honest way to say there is nothing left to append.
 */
QStringList g_qtFlags = {};

/////////////////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
#if defined(Q_OS_WIN) && defined(_M_X64)
  // Must run before any mpv code triggers delay-load
  setupMpvFallback();
#endif

  try
  {
    QCommandLineParser parser;
    parser.setApplicationDescription("Mahfin");
    parser.addVersionOption();
    parser.addOptions({{{"h", "help"},              "Show this help"},
                       {{"l", "licenses"},          "Show license information"},
                       {"desktop",                  "Start in desktop mode"},
                       {"tv",                       "Start in TV mode"},
                       {"windowed",                 "Start in windowed mode"},
                       {"fullscreen",               "Start in fullscreen"},
                       {"disable-gpu",              "Disable QtWebEngine gpu accel"},
                       {"ignore-certificate-errors", "Ignore certificate errors"}});

    auto scaleOption = QCommandLineOption("scale-factor", "Set to a integer or default auto which controls" \
                                                          "the scale (DPI) of the desktop interface.");
    scaleOption.setValueName("scale");
    scaleOption.setDefaultValue("auto");

    auto platformOption = QCommandLineOption("platform", "Equivalent to QT_QPA_PLATFORM.");
    platformOption.setValueName("platform");
    platformOption.setDefaultValue("default");

    auto devOption = QCommandLineOption("remote-debugging-port", "Port number for devtools.");
    devOption.setValueName("port");

    auto configDirOption = QCommandLineOption("config-dir", "Override config directory path.");
    configDirOption.setValueName("path");

    auto logLevelOption = QCommandLineOption("log-level", "Log level: debug, info, warn, error, fatal (default: error)");
    logLevelOption.setValueName("level");

    auto gpuBackendOption = QCommandLineOption("gpu-backend",
      "How QtWebEngine reaches the GPU: default, gl, d3d11, software.");
    gpuBackendOption.setValueName("backend");
    gpuBackendOption.setDefaultValue("default");

    auto resetGraphicsOption = QCommandLineOption("reset-graphics",
      "Forget a previous failed start and probe the graphics driver again.");

    auto profileOption = QCommandLineOption("profile", "Use specific profile for this session.");
    profileOption.setValueName("name");

    auto setDefaultProfileOption = QCommandLineOption("set-default-profile", "Set the default profile and exit.");
    setDefaultProfileOption.setValueName("name");

    auto listProfilesOption = QCommandLineOption("list-profiles", "List all profiles and exit.");

    auto deleteProfileOption = QCommandLineOption("delete-profile", "Delete a profile and exit.");
    deleteProfileOption.setValueName("name");

    auto createProfileOption = QCommandLineOption("create-profile", "Create a new profile and exit.");
    createProfileOption.setValueName("name");

    parser.addOption(scaleOption);
    parser.addOption(devOption);
    parser.addOption(platformOption);
    parser.addOption(configDirOption);
    parser.addOption(logLevelOption);
    parser.addOption(gpuBackendOption);
    parser.addOption(resetGraphicsOption);
    parser.addOption(profileOption);
    parser.addOption(setDefaultProfileOption);
    parser.addOption(listProfilesOption);
    parser.addOption(deleteProfileOption);
    parser.addOption(createProfileOption);

    char **newArgv = appendCommandLineArguments(argc, argv, g_qtFlags);
    int newArgc = argc + static_cast<int>(g_qtFlags.size());

    preinitQt();

    QStringList arguments;
    for (int i = 0; i < argc; i++)
      arguments << QString::fromLatin1(argv[i]);

    {
      // This is kinda dumb. But in order for the QCommandLineParser
      // to work properly we need to init if before we call process
      // but we don't want to do that for the main application since
      // we need to set the scale factor before we do that. So it becomes
      // a small chicken-or-egg problem, which we "solve" by making
      // this temporary console app.
      //
      QCoreApplication core(newArgc, newArgv);

      // Now parse the command line.
      parser.process(arguments);

      // Detect portable mode while QCoreApplication exists (needed for applicationDirPath)
      Paths::detectAndEnablePortableMode();

#if defined(Q_OS_WIN) && !defined(MAHFIN_NATIVE_SHELL)
      // Disable pipeline cache in portable mode to avoid writing to user's AppData
      if (Paths::isPortableMode())
        qputenv("QSG_RHI_DISABLE_DISK_CACHE", "1");
#endif
    }

#ifndef MAHFIN_NATIVE_SHELL
    detectOpenGLEarly();
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
#endif

    if (parser.isSet("help"))
    {
      // Get Qt's generated help, insert section header before profile options
      QString help = parser.helpText();
      help.replace("  --profile", "\nProfile Options:\n  --profile");
      printf("%s", qPrintable(help));
      return EXIT_SUCCESS;
    }

    if (parser.isSet("licenses"))
    {
      ShowLicenseInfo();
      return EXIT_SUCCESS;
    }

    // Set QSettings path for portable mode
    if (Paths::isPortableMode())
    {
      QSettings::setPath(QSettings::NativeFormat, QSettings::UserScope,
                         Paths::globalDataDir());
    }

    // Handle config-dir (overrides portable mode if explicitly set)
    auto configDir = parser.value("config-dir");
    if (!configDir.isEmpty())
    {
      QFileInfo fi(configDir);
      QString absPath = fi.absoluteFilePath();
      QDir parentDir = fi.dir();

      if (!parentDir.exists())
      {
        fprintf(stderr, "Config directory parent does not exist: %s\n", qPrintable(parentDir.absolutePath()));
        return EXIT_FAILURE;
      }

      Paths::setConfigDir(absPath);
      QSettings::setPath(QSettings::NativeFormat, QSettings::UserScope, absPath);
    }

    // Handle --list-profiles
    if (parser.isSet("list-profiles"))
    {
      auto allProfiles = ProfileManager::profiles();
      auto defaultProf = ProfileManager::defaultProfile();
      if (allProfiles.isEmpty())
      {
        printf("No profiles found.\n");
      }
      else
      {
        for (const Profile& p : allProfiles)
        {
          QString marker = (defaultProf && p.name() == defaultProf->name()) ? " *" : "";
          printf("%s%s\n", qPrintable(p.name()), qPrintable(marker));
        }
      }
      return EXIT_SUCCESS;
    }

    // Handle --create-profile
    if (parser.isSet("create-profile"))
    {
      QString name = parser.value("create-profile");
      if (name.isEmpty())
      {
        fprintf(stderr, "Profile name is required\n");
        return EXIT_FAILURE;
      }
      if (ProfileManager::profileByName(name))
      {
        fprintf(stderr, "Profile already exists: %s\n", qPrintable(name));
        return EXIT_FAILURE;
      }
      ProfileManager::createProfile(name);
      printf("Created profile: %s\n", qPrintable(name));
      return EXIT_SUCCESS;
    }

    // Handle --delete-profile
    if (parser.isSet("delete-profile"))
    {
      QString name = parser.value("delete-profile");
      auto profile = ProfileManager::profileByName(name);
      if (!profile)
      {
        fprintf(stderr, "Profile not found: %s\n", qPrintable(name));
        return EXIT_FAILURE;
      }
      if (!ProfileManager::deleteProfile(*profile))
      {
        fprintf(stderr, "Failed to delete profile: %s\n", qPrintable(name));
        return EXIT_FAILURE;
      }
      printf("Deleted profile: %s\n", qPrintable(name));
      return EXIT_SUCCESS;
    }

    // Handle --set-default-profile
    if (parser.isSet("set-default-profile"))
    {
      QString name = parser.value("set-default-profile");
      auto profile = ProfileManager::profileByName(name);
      if (!profile)
      {
        fprintf(stderr, "Profile not found: %s\n", qPrintable(name));
        return EXIT_FAILURE;
      }
      ProfileManager::setDefaultProfile(*profile);
      printf("Default profile set to: %s\n", qPrintable(name));
      return EXIT_SUCCESS;
    }

    // Determine which profile to use for this session
    std::optional<Profile> activeProfile;

    // --profile overrides everything
    if (parser.isSet("profile"))
    {
      QString name = parser.value("profile");
      activeProfile = ProfileManager::profileByName(name);
      if (!activeProfile)
      {
        fprintf(stderr, "Profile not found: %s\n", qPrintable(name));
        return EXIT_FAILURE;
      }
    }
    else
    {
      // Try default profile
      activeProfile = ProfileManager::defaultProfile();

      // Try first available profile
      if (!activeProfile)
      {
        auto allProfiles = ProfileManager::profiles();
        if (!allProfiles.isEmpty())
          activeProfile = allProfiles.first();
      }

      // Create new profile if none exist
      if (!activeProfile)
        activeProfile = ProfileManager::createProfile("Default");

      // Update default
      ProfileManager::setDefaultProfile(*activeProfile);
    }

    ProfileManager::Get().setActiveProfile(*activeProfile);

    // Now everything else - all paths are profile-specific from here on
    QString logLevel = parser.value("log-level");
    if (parser.isSet("log-level") && (logLevel.isEmpty() || Log::ParseLogLevel(logLevel) == -1))
    {
      fprintf(stderr, "Error: invalid log level '%s'. Valid levels: debug, info, warn, error, fatal\n", qPrintable(logLevel));
      return EXIT_FAILURE;
    }

    if (parser.isSet("log-level"))
      Log::SetLogLevel(logLevel);

    Log::Init();

    auto scale = parser.value("scale-factor");
    if (scale.isEmpty() || scale == "auto")
    {
#if QT_VERSION < QT_VERSION_CHECK(5, 14, 0)
      QCoreApplication::setAttribute(Qt::AA_EnableHighDpiScaling);
#endif
    }
    else if (scale != "none")
    {
      qputenv("QT_SCALE_FACTOR", scale.toUtf8());
    }

    auto platform = parser.value("platform");
    if (!(platform.isEmpty() || platform == "default"))
    {
      qputenv("QT_QPA_PLATFORM", platform.toUtf8());
    }
#if defined(Q_OS_UNIX) && !defined(Q_OS_DARWIN) && !defined(Q_OS_ANDROID) && QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    // Force xcb on Qt < 6.5 due to mpvqt wayland requiring >=6.5
    else if (platform.isEmpty() || platform == "default")
    {
      qputenv("QT_QPA_PLATFORM", "xcb");
    }
#endif

    /*
     * Find out what this machine can draw with, and remember if asking killed
     * us.
     *
     * The failure this guards against does not report itself. On a machine
     * with no usable OpenGL driver the application starts, draws the right
     * pixels, and does it entirely on the CPU — three Chromium processes, an
     * mpv render context and a window-sized composite, all on cores that are
     * also running the rest of the person's computer. From the outside it is
     * not a graphics problem at all: the machine stops responding, and the
     * only thing anyone can report is "it crashes and freezes everything".
     *
     * Two mechanisms, because either alone has a hole in it.
     *
     * GraphicsCapability looks at the display adapter and the size of the
     * machine. That catches the common case — a PC running on Microsoft's
     * basic display driver because no vendor one was ever installed — and it
     * is cheap and free of side effects. What it cannot see is a driver that
     * is present but too old or too broken for Qt to use, because seeing that
     * needs a GL context, and a GL context cannot be created here without
     * settling the process's DPI awareness behind Qt's back.
     *
     * So the lock file catches the rest, empirically. It is written now and
     * removed either twenty seconds into a run that is still answering, or on
     * a clean exit. Finding it here means the previous launch did neither — it
     * died, or it hung hard enough that its own event loop never ran again.
     * That is precisely the reported symptom, and the response is to not go
     * down the same path twice. `--reset-graphics` is the way back out once a
     * driver has been installed.
     */
    const QString graphicsGuardPath =
      ProfileManager::activeProfile().dataDir("graphics-startup.lock");

    if (parser.isSet("reset-graphics") && QFile::exists(graphicsGuardPath))
    {
      QFile::remove(graphicsGuardPath);
      qInfo() << "Forgetting the previous failed start, as asked";
    }

    /*
     * Evidence, not a guess, so nothing overrides it.
     *
     * Kept apart from the setting below for one reason: a machine that has
     * already failed to start must not be sent down the same path again
     * because somebody once chose "Hardware" in the settings. That is a loop
     * with no way out of it from inside an application whose whole problem is
     * that it will not open. `--reset-graphics` is the way back, and it is
     * deliberately something you have to mean.
     */
    const bool previousStartFailed = QFile::exists(graphicsGuardPath);
    if (previousStartFailed)
    {
      GraphicsCapability::forceSoftware(
        QObject::tr("the previous start did not get as far as drawing a window"));
      qWarning() << "The last run never finished starting up. Using the safest graphics "
                    "settings. Run with --reset-graphics once the display driver is "
                    "sorted out.";
    }

    /*
     * Chosen by hand, and it outranks the probe in both directions: somebody on
     * a machine this misreads can pin it, and somebody who wants the effects
     * back on a machine it reads correctly can have them.
     */
    const QString graphicsMode =
      SettingsComponent::readPreinitValue(SETTINGS_SECTION_MAIN, "graphicsMode").toString();
    if (graphicsMode == "software")
      GraphicsCapability::forceSoftware(QObject::tr("the graphics mode setting is set to software"));
    else if (graphicsMode == "hardware" && !previousStartFailed)
      GraphicsCapability::forceNormal(QObject::tr("the graphics mode setting is set to hardware"));

    {
      // mkpath rather than trusting the profile to have been laid out already.
      // A guard that silently fails to be written is a guard that silently is
      // not there, and this is the one thing here with no other way of finding
      // out that it is broken.
      QDir().mkpath(QFileInfo(graphicsGuardPath).absolutePath());
      QFile guard(graphicsGuardPath);
      if (guard.open(QIODevice::WriteOnly | QIODevice::Truncate))
      {
        guard.write(QDateTime::currentDateTimeUtc().toString(Qt::ISODate).toUtf8());
        guard.close();
      }
      else
      {
        qWarning() << "Could not write the start-up guard at" << graphicsGuardPath
                   << "- a failed start will not be noticed next time";
      }
    }

    /*
     * One answer, read from one place. The guard and the setting were pushed
     * into GraphicsCapability above rather than combined into a local, so that
     * SystemComponent — which hands this same verdict to QML and to the web
     * client — cannot come to a different conclusion than the flags this
     * process was actually started with.
     */
    const bool lowGraphics = GraphicsCapability::probe().isLow();
    const bool softwareGraphics = GraphicsCapability::probe().drawsInSoftware();

    qInfo() << qPrintable(GraphicsCapability::describe());
    for (const QString& reason : GraphicsCapability::probe().reasons)
      qInfo() << "  reduced settings because" << qPrintable(reason);

    QStringList chromiumFlags;

    /*
     * One switch, because Chromium keeps only the last occurrence of a repeated
     * one. Two separate `--disable-features` lines meant the second silently
     * threw the first away, which is the kind of bug that shows up as a feature
     * quietly coming back on a platform nobody is testing.
     */
    QStringList disabledFeatures{"MediaSessionService"};
#ifdef Q_OS_LINUX
    // We register MPRIS ourselves, and handle the media keys ourselves.
    disabledFeatures << "HardwareMediaKeyHandling";
#endif
    if (lowGraphics)
    {
      /*
       * Occlusion tracking walks the window tree on every window change to
       * work out whether Chromium may stop drawing. On a machine already short
       * of CPU it costs more than the drawing it saves, and it is a long-
       * standing source of windows that come back blank.
       */
      disabledFeatures << "CalculateNativeWinOcclusion";
    }
    chromiumFlags << "--disable-features=" + disabledFeatures.join(",");

    /*
     * Raster on the GPU, but only where there is one.
     *
     * This was unconditional. On a machine whose OpenGL is llvmpipe it asks the
     * CPU to do the rasterising *through* a software GL implementation, which
     * is strictly more work than asking it to rasterise directly — the one
     * configuration where the flag makes things worse rather than better.
     */
    const QString gpuBackend = parser.value("gpu-backend");
    const bool cpuDraws =
        softwareGraphics || parser.isSet("disable-gpu") || gpuBackend == "software";
    if (!cpuDraws)
      chromiumFlags << "--enable-gpu-rasterization";

    // Tell Blink there is a mouse, because inside a QQuickWebEngineView it does
    // not work that out for itself.
    //
    // Chromium reports `(pointer: fine)` and `(pointer: coarse)` as *both*
    // false here — with no input device associated with the view it answers
    // "no pointer at all". `(hover: hover)` is true, so the mismatch is easy to
    // miss, and `matchMedia` is the only place it shows.
    //
    // It is not cosmetic. `@media (hover: hover) and (pointer: fine)` is the
    // standard guard for hover styling — a touch browser matching `hover` alone
    // would latch the hovered state on tap and never release it — and the web
    // client puts every hover effect it has behind exactly that query. Without
    // this the whole lot is silently dead in the window: cards do not lift,
    // rows do not respond, and nothing anywhere reports an error.
    //
    // The numbers are Blink's own bitmasks from pointer_properties.h: pointer
    // fine = 1<<2, hover = 1<<1.
#ifndef MAHFIN_NATIVE_SHELL
    // (WebView2 is a real top-level Chromium view and works this out itself,
    // including on touchscreens, where forcing "fine" would be wrong.)
    chromiumFlags << "--blink-settings=availablePointerTypes=4,primaryPointerType=4,"
                     "availableHoverTypes=2,primaryHoverType=2";
#endif

    /*
     * Which way Chromium reaches the GPU, and what to do when the default way
     * is slow.
     *
     * The scene graph is pinned to desktop OpenGL and cannot move: mpvqt draws
     * through a QQuickFramebufferObject, which has no other backend. Chromium
     * reaches the GPU through ANGLE, which on Windows means Direct3D 11 by
     * default. Two different GL implementations in one process cannot hand
     * each other a texture, and when the sharing fails the page is read back
     * to the CPU and uploaded again once per frame. That does not look like a
     * graphics fault from the inside — it looks like the whole application
     * being slow, at every window size, whatever is on screen.
     *
     * `--gpu-backend=gl` puts ANGLE on the same desktop OpenGL driver the
     * scene graph already uses, so there is nothing to copy. It is not the
     * default because it then rests on that driver being correct, and D3D11 is
     * the path Chromium actually tests. It is here so that "is this what is
     * slow?" costs one launch to answer instead of a rebuild, and so the
     * answer can be reported from a machine nobody developing this owns.
     *
     * `--disable-gpu` was declared for years and never read; it means the same
     * thing as `--gpu-backend=software` and is kept because it is the spelling
     * Chromium itself uses.
     */
    if (cpuDraws)
    {
      /*
       * No GPU process at all, and no pretend one either.
       *
       * `--disable-gpu` on its own leaves Chromium free to start SwiftShader,
       * its own software GL, for anything that asks for a 3D context — so a
       * machine with no GPU ends up running *two* software rasterisers, one
       * inside the other. Nothing in this interface needs WebGL, so the
       * fallback is turned off with it and the renderer rasterises to plain
       * memory, which Qt uploads once per frame.
       */
      chromiumFlags << "--disable-gpu" << "--disable-software-rasterizer"
                    << "--disable-accelerated-2d-canvas";
    }
    else if (gpuBackend == "gl" || gpuBackend == "d3d11")
    {
#ifdef MAHFIN_NATIVE_SHELL
      // WebView2 composites on its own, with Direct3D 11; there is no OpenGL
      // scene graph left to share a context with. Accepted so old shortcuts
      // with the switch on them still start.
      qInfo() << "--gpu-backend" << gpuBackend << "has no effect in the WebView2 shell";
#else
      chromiumFlags << "--use-angle=" + gpuBackend;
#endif
    }
    else if (gpuBackend != "default")
    {
      fprintf(stderr, "Error: unknown --gpu-backend '%s'. Use default, gl, d3d11 or software.\n",
              qPrintable(gpuBackend));
      return EXIT_FAILURE;
    }

    if (lowGraphics)
    {
      /*
       * Leave the machine something to run itself with.
       *
       * Raster threads default to one per core, and with no GPU to raster on
       * they are the busiest threads in the process. Letting them take every
       * core is what turns "the app is slow" into "the computer has stopped"
       * — the complaint that started all of this. Two is enough to keep
       * scrolling smooth and leaves the rest of the machine usable.
       *
       * Deliberately not tied to the CPU doing the drawing. A two-core or
       * 4GB machine keeps its GPU (see drawsInSoftware) and still needs every
       * saving here; the two questions were one answer until it turned out
       * that sent working integrated graphics down the software path.
       *
       * One renderer process, likewise: this is a single-origin application
       * that never opens a second site, so the isolation Chromium would buy
       * with a second process is isolation from nothing, paid for in a few
       * hundred MB on a machine that does not have them spare.
       */
      chromiumFlags << "--num-raster-threads=2"
                    << "--renderer-process-limit=1"
                    << "--disable-smooth-scrolling";


      /*
       * Not `--force-prefers-reduced-motion`, although it was tried here and
       * measured well: with no GPU, an infinite animation anywhere in the page
       * keeps the whole window redrawing, and forcing reduced motion stopped
       * every one of them at once.
       *
       * It broke playback. Qt WebEngine composites the page over mpv, and where
       * the page has once painted opaque pixels it keeps them after the element
       * is gone (see the long note in the web client's globals.css). The player
       * relies on its opening card and the outgoing page *animating* to
       * transparent before they leave; with motion forced off they leave at
       * full opacity, and their last frame stays on screen over the film — the
       * mark and the home page ghosted over a video nobody could see, sound
       * playing underneath. The offending animations are fixed in the web
       * client instead, where each one can be judged on its own.
       */
    }

    // Disable pinch-to-zoom if browser zoom is not allowed
    QVariant allowZoom = SettingsComponent::readPreinitValue(SETTINGS_SECTION_MAIN, "allowBrowserZoom");
    if (allowZoom.isValid() && !allowZoom.toBool())
      chromiumFlags << "--disable-pinch";

    if (parser.isSet("ignore-certificate-errors"))
      chromiumFlags << "--ignore-certificate-errors";

#ifdef MAHFIN_NATIVE_SHELL
    NativeShell::Options nativeShellOptions;
    // QtWebEngine took these from the environment; WebView2 takes them as the
    // browser's arguments. The same list, worked out from the same probe.
    chromiumFlags << "--autoplay-policy=no-user-gesture-required";
    if (parser.isSet("remote-debugging-port"))
    {
      chromiumFlags << "--remote-debugging-port=" + parser.value("remote-debugging-port");
      nativeShellOptions.devTools = true;
    }
#ifndef NDEBUG
    nativeShellOptions.devTools = true;
#endif
    nativeShellOptions.ignoreCertificateErrors = parser.isSet("ignore-certificate-errors");
    nativeShellOptions.browserArguments = chromiumFlags;
#else
    if (!chromiumFlags.isEmpty())
    {
      // Whatever the user already put in the environment wins. Chromium takes
      // the last occurrence of a repeated switch, so theirs goes on the end.
      //
      // This used to be a plain overwrite, which was harmless only while the
      // list could be empty — it no longer can be, and silently discarding a
      // GPU workaround somebody set by hand is a bad way to find that out.
      QByteArray flags = chromiumFlags.join(" ").toUtf8();
      const QByteArray existing = qgetenv("QTWEBENGINE_CHROMIUM_FLAGS");
      if (!existing.isEmpty())
        flags = flags + " " + existing;
      qputenv("QTWEBENGINE_CHROMIUM_FLAGS", flags);
    }

    if (parser.isSet("remote-debugging-port"))
      qputenv("QTWEBENGINE_REMOTE_DEBUGGING", parser.value("remote-debugging-port").toUtf8());

    QtWebEngineQuick::initialize();
#endif
    QApplication app(newArgc, newArgv);

#if defined(Q_OS_WIN) 
    // Setting window icon on OSX will break user ability to change it
    app.setWindowIcon(QIcon(":/images/icon.png"));
#endif

#if defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)
  	// Set window icon on Linux using system icon theme
  	app.setWindowIcon(QIcon::fromTheme("online.mahfin.Mahfin", QIcon(":/images/icon.png")));
    // Set app id for Wayland compositor window icon
    app.setDesktopFileName("online.mahfin.Mahfin");
#endif

#ifndef MAHFIN_NATIVE_SHELL
    // Configure default WebEngineProfile paths early (profile is already set)
    {
      QWebEngineProfile* defaultProfile = QWebEngineProfile::defaultProfile();
      defaultProfile->setCachePath(ProfileManager::activeProfile().cacheDir("QtWebEngine"));
      defaultProfile->setPersistentStoragePath(ProfileManager::activeProfile().dataDir("QtWebEngine"));

      /*
       * Without this, a notification the page raises is constructed, accepted
       * and silently dropped: QtWebEngine has no presenter of its own, so the
       * desktop app could not show one at all. See NotificationPresenter.
       */
      NotificationPresenter::install();
    }
#endif

#if defined(Q_OS_MAC) && defined(NDEBUG)
    PFMoveToApplicationsFolderIfNecessary();
#endif

    UniqueApplication* uniqueApp = new UniqueApplication(&app);
    if (!uniqueApp->ensureUnique())
    {
      /*
       * This process raised the window of the copy that was already running
       * and is now leaving, so take the start-up guard back off.
       *
       * It was written further up, before there was any way to know this was a
       * second instance — and nothing else would ever remove it, because the
       * two things that do are twenty seconds of *this* event loop and *this*
       * process exiting through app.exec(), neither of which happens here.
       * Without this, double-clicking the icon while Mahfin is already open
       * would leave a guard behind and send the next genuine launch into safe
       * mode for no reason at all.
       *
       * The instance that is actually running looks after its own.
       */
      if (QFile::exists(graphicsGuardPath))
        QFile::remove(graphicsGuardPath);

      Log::Cleanup();
      return EXIT_SUCCESS;
    }

#ifdef Q_OS_UNIX
    // install signals handlers for proper app closing.
    SignalManager signalManager(&app);
    Q_UNUSED(signalManager);
#endif

#ifndef MAHFIN_NATIVE_SHELL
    detectOpenGLLate();
#endif

    // Initialize all the components. This needs to be done
    // early since most everything else relies on it
    //
    ComponentManager::Get().initialize();

    // Rotate temp log to main log file and rotate old logs
    Log::RotateLog();

    qInfo() << "Config directory:" << qPrintable(ProfileManager::activeProfile().dataDir());

    Log::ApplyConfigLogLevel();

    SettingsComponent::Get().setCommandLineValues(parser.optionNames());

#ifdef MAHFIN_NATIVE_SHELL
    if (!NativeShell::start(uniqueApp, nativeShellOptions))
    {
      // Nothing was drawn and nothing went wrong with the graphics: the guard
      // must not send the next launch into safe mode.
      if (QFile::exists(graphicsGuardPath))
        QFile::remove(graphicsGuardPath);
      delete uniqueApp;
      return EXIT_FAILURE;
    }
#else
    // Set user agent now that SystemComponent is available
    QWebEngineProfile::defaultProfile()->setHttpUserAgent(SystemComponent::Get().getUserAgent());

    // load QtWebChannel so that we can register our components with it.
    QQmlApplicationEngine *engine = Globals::Engine();

    Globals::SetContextProperty("components", &ComponentManager::Get().getQmlPropertyMap());

    // the only way to detect if QML parsing fails is to hook to this signal and then see
    // if we get a valid object passed to it. Any error messages will be reported on stderr
    // but since no normal user should ever see this it should be fine
    //
    QObject::connect(engine, &QQmlApplicationEngine::objectCreated, [&](QObject* object, const QUrl& url)
    {
      Q_UNUSED(url);

      if (object == nullptr)
        throw FatalException(QObject::tr("Failed to parse application engine script."));

      QQuickWindow* window = Globals::MainWindow();

      // Set window flags for proper popup handling (e.g., WebEngineView dropdowns)
      window->setFlags(window->flags() | Qt::WindowFullscreenButtonHint);

      // Install event filter for proper event handling
      window->installEventFilter(new EventFilter(window));

      // Install application event filter to catch popup window creation early
      class PopupFixer : public QObject {
        QQuickWindow* m_mainWindow;
      public:
        PopupFixer(QQuickWindow* mainWin) : m_mainWindow(mainWin) {}
        bool eventFilter(QObject* obj, QEvent* event) override {
          auto* win = qobject_cast<QWindow*>(obj);
          if (!win || win == m_mainWindow) {
            return QObject::eventFilter(obj, event);
          }

          // Fix WebEngineView popup flags to accept focus
          if (event->type() == QEvent::Show) {
            Qt::WindowFlags flags = win->flags();

            // Only fix WebEngineView dropdowns (Tool + FramelessWindowHint + WindowStaysOnTopHint)
            // Don't touch other windows (e.g., MPV-related)
            bool isWebEnginePopup = (flags & Qt::Tool) &&
                                     (flags & Qt::FramelessWindowHint) &&
                                     (flags & Qt::WindowStaysOnTopHint);

            if (!isWebEnginePopup) {
              return QObject::eventFilter(obj, event);
            }

            if (win->transientParent() == nullptr) {
              win->setTransientParent(m_mainWindow);
            }

            if (win->modality() != Qt::NonModal) {
              win->setModality(Qt::NonModal);
            }

            // WebEngineView creates popups with Qt::Tool | WindowDoesNotAcceptFocus
            // which prevents interaction. Change to Qt::Popup to accept focus.
            flags &= ~Qt::Tool;
            flags |= Qt::Popup;
            flags &= ~Qt::WindowDoesNotAcceptFocus;
            win->setFlags(flags);
          }

          return QObject::eventFilter(obj, event);
        }
      };
      app.installEventFilter(new PopupFixer(window));

      QObject* webChannel = qvariant_cast<QObject*>(window->property("webChannel"));
      Q_ASSERT(webChannel);
      ComponentManager::Get().setWebChannel(qobject_cast<QWebChannel*>(webChannel));

      // Initialize WindowManager with window reference
      WindowManager::Get().initializeWindow(window);

      // Handle other app focus by raising window
      QObject::connect(uniqueApp, &UniqueApplication::otherApplicationStarted, []() {
        WindowManager::Get().raiseWindow();
      });
    });
    engine->load(QUrl(QStringLiteral("qrc:/webview.qml")));
#endif

    /*
     * Twenty seconds of a responsive event loop is the all-clear.
     *
     * Deliberately not the window's first frame: on the machines this is for,
     * one frame is exactly what a software rasteriser *can* manage before the
     * process wedges, so clearing the lock there would clear it on every run
     * that then froze. What has to be proved is that the loop is still turning
     * some time after everything is up — and if it is not, this timer never
     * fires, the lock survives, and the next launch starts safe.
     */
    QTimer::singleShot(20000, qApp, [graphicsGuardPath]() {
      if (QFile::exists(graphicsGuardPath))
        QFile::remove(graphicsGuardPath);
    });

    // run our application
    int ret = app.exec();

    /*
     * A clean exit is the other all-clear, and it is the one that matters for
     * anybody who opens the app, plays something and closes it inside the
     * twenty seconds above — without this they would be sent into safe mode
     * for having been quick.
     */
    if (QFile::exists(graphicsGuardPath))
      QFile::remove(graphicsGuardPath);

    delete uniqueApp;
#ifndef MAHFIN_NATIVE_SHELL
    Globals::EngineDestroy();
#endif

    return ret;
  }
  catch (FatalException& e)
  {
    qFatal("Unhandled FatalException: %s", qPrintable(e.message()));
    QApplication errApp(argc, argv);

    auto  msg = new ErrorMessage(e.message(), true);
    msg->show();

    errApp.exec();

    return 1;
  }
}
