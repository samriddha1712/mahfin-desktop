#include <QtGlobal>
#include <QColorSpace>
#include <QSurfaceFormat>
#include <QCoreApplication>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QOffscreenSurface>
#include <QDebug>

#include <mpv/client.h>


#include "QtHelper.h"
#include "OpenGLDetect.h"

#if defined(Q_OS_MAC)

///////////////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLEarly()
{
  // Request OpenGL 4.1 if possible on OSX, otherwise it defaults to 2.0
  // This needs to be done before we create the QGuiApplication
  //
  QSurfaceFormat format = QSurfaceFormat::defaultFormat();
  format.setMajorVersion(3);
  format.setMinorVersion(2);
  format.setProfile(QSurfaceFormat::CoreProfile);
  // Fix oversaturated colors on HDR displays
  format.setColorSpace(QColorSpace::SRgb);
  QSurfaceFormat::setDefaultFormat(format);
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLLate()
{
}

#elif defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)

///////////////////////////////////////////////////////////////////////////////////////////////////
// Attempt to reuse mpv's code for detecting whether we want GLX or EGL (which
// is tricky to do because of hardware decoding concerns). This is not pretty,
// but quite effective and without having to duplicate too much GLX/EGL code.
static QString probeHwdecInterop()
{
  auto mpv = mpv::qt::Handle::FromRawHandle(mpv_create());
  if (!mpv)
    return "";
  mpv::qt::set_property(mpv, "gpu-hwdec-interop", "auto");
  // Actually creating a window is required. There is currently no way to keep
  // this window hidden or invisible.
  mpv::qt::set_property(mpv, "force-window", true);
  // As a mitigation, put the window in the top/right corner, and make it as
  // small as possible by forcing 1x1 size and removing window borders.
  mpv::qt::set_property(mpv, "geometry", "1x1+0+0");
  mpv::qt::set_property(mpv, "border", false);
  if (mpv_initialize(mpv) < 0)
    return "";
  return mpv::qt::get_property(mpv, "hwdec-interop").toString();
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLEarly()
{
  // The putenv call must happen before Qt initializes its platform stuff.
  if (probeHwdecInterop() == "vaapi-egl")
    qputenv("QT_XCB_GL_INTEGRATION", "xcb_egl");
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLLate()
{
}

#elif defined(Q_OS_WIN)


///////////////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLEarly()
{
}

/////////////////////////////////////////////////////////////////////////////////////////
// Say which OpenGL implementation this machine actually handed us.
//
// The scene graph is pinned to OpenGL because mpvqt draws through a
// QQuickFramebufferObject, so on Windows everything on screen — the video, the
// page composited over it, the window itself — goes through whatever
// opengl32.dll resolves to. Usually that is the graphics driver. It is not
// always: with no vendor ICD registered Windows answers with its own software
// implementation, and Qt has a Mesa build it falls back to as well. Either way
// the application starts, renders correctly, and is unusably slow, with nothing
// anywhere saying why.
//
// One line in the log settles it. "Intel", "NVIDIA", "AMD", "Apple" — hardware.
// "GDI Generic", "llvmpipe", "Microsoft Basic Render Driver", "Software
// Rasterizer" — a CPU is drawing every pixel, and no amount of tuning in this
// application will fix that; the graphics driver is what needs installing.
//
// Its own context rather than the window's: this runs before any QQuickWindow
// exists, and a throwaway offscreen context reports the same strings the real
// one will get.
static void logOpenGLImplementation()
{
  QOpenGLContext ctx;
  if (!ctx.create())
  {
    qWarning() << "Could not create an OpenGL context to identify the driver";
    return;
  }

  QOffscreenSurface surface;
  surface.setFormat(ctx.format());
  surface.create();
  if (!surface.isValid() || !ctx.makeCurrent(&surface))
  {
    qWarning() << "Could not make an OpenGL context current to identify the driver";
    return;
  }

  QOpenGLFunctions* gl = ctx.functions();
  const auto str = [gl](GLenum name) {
    const GLubyte* value = gl->glGetString(name);
    return value ? QString::fromLatin1(reinterpret_cast<const char*>(value)) : QStringLiteral("(unknown)");
  };

  qInfo() << "OpenGL vendor:" << str(GL_VENDOR);
  qInfo() << "OpenGL renderer:" << str(GL_RENDERER);
  qInfo() << "OpenGL version:" << str(GL_VERSION);

  ctx.doneCurrent();
}

/////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLLate()
{
  // Qt 6 does not support AA_UseOpenGLES - it uses desktop OpenGL by default
  // No need to force GLES version, let Qt use the native OpenGL
  qInfo() << "Using native desktop OpenGL (Qt 6)";
  logOpenGLImplementation();
}

#else

///////////////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLEarly()
{
}

///////////////////////////////////////////////////////////////////////////////////////////////////
void detectOpenGLLate()
{
}

#endif
