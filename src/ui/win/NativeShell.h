#ifndef NATIVESHELL_H
#define NATIVESHELL_H

#include <QStringList>

class UniqueApplication;

/*
 * Starts the Windows shell: the window, mpv drawing into it, and the web
 * client in WebView2 above it, wired to the same components and channel the
 * QML shell used. main() calls this where it used to load webview.qml.
 *
 * Returns false if the shell cannot run on this machine (no WebView2 runtime),
 * after telling the person why.
 */
namespace NativeShell
{
  struct Options
  {
    // Chromium switches worked out in main() from the graphics probe.
    QStringList browserArguments;
    bool devTools = false;
    bool ignoreCertificateErrors = false;
  };

  bool start(UniqueApplication* uniqueApp, const Options& options);
}

#endif // NATIVESHELL_H
