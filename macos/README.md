# Mahfin for macOS (native)

The Mac app, rebuilt as a native AppKit app: the system's own Safari engine
(WKWebView) shows Mahfin, and libmpv plays the video underneath it. It
replaces the Qt build on macOS only — Windows and Linux keep the Qt/WebView2
shell in `../src`. The Qt Mac app is frozen on the `mac-qt-legacy` branch (and
its v1.1.1 installers) as the fallback.

Why: the Qt build carries its own Chromium (613 MB of the 713 MB app), starts
cold with empty caches, and macOS scans the whole bundle on first launch. This
app is about 60–70 MB, almost all of it libmpv and its codecs.

## Layout
- `Sources/` — Swift. `AppDelegate` (menus, window), `WebShell` (WKWebView,
  navigation lock, the JS bridge), `MpvPlayer` (libmpv + its events),
  `VideoLayer` (libmpv's render API drawing into a CAOpenGLLayer),
  `Bridge.js` (injected at document start: `window.jmpInfo` and `window.api`,
  the same objects the Qt shell exported over QWebChannel).
- `Resources/` — Info.plist template, icon.
- `build.sh` — compiles with swiftc against Homebrew's libmpv, assembles
  `Mahfin.app`, copies libmpv and its dependency closure into
  `Contents/Frameworks` (dylibbundler) and ad-hoc signs it.

Built by `.github/workflows/build-macos-native.yml`; nothing is built locally.
