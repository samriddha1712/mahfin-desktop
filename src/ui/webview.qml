import QtQuick
import Konvergo 1.0
import QtWebEngine
import QtWebChannel
import QtQuick.Window
import QtQuick.Controls
import Qt.labs.platform as Labs

Window
{
  id: mainWindow
  title: "Mahfin Desktop"
  objectName: "mainWindow"
  width: 1280
  height: 720
  minimumWidth: 213
  minimumHeight: 120
  visible: true
  color: "#000000"

  // Properties previously from KonvergoWindow
  property bool webDesktopMode: true
  property bool showDebugLayer: false
  property string debugInfo: ""
  property string videoInfo: ""
  property string webUrl: ""

  /*
   * The window is not empty while the library is on its way.
   *
   * `webUrl` is a remote address, and the WebEngineView renders nothing at all
   * until the document it points at has come back, parsed and painted a first
   * frame. Until then this window is its own background colour and nothing
   * else — on a cold start, over a slow connection, or on a machine drawing
   * without a GPU, that is several seconds of a black rectangle with the title
   * bar of an application that looks like it has hung. It was the first thing
   * anyone saw of Mahfin, and what it said was "this is broken".
   *
   * So the splash is drawn *here*, in QML, by the scene graph that is already
   * running before the web engine has been asked for anything. It is up in the
   * first frame the window ever draws, it says what is happening, and it hands
   * over to the page underneath once that page has something to show.
   *
   * Deliberately not an HTML splash: an HTML one cannot appear until the very
   * document whose arrival it exists to cover has already arrived.
   */
  property bool splashVisible: true
  property string splashStatus: qsTr("Starting Mahfin")

  property bool showSystemTrayIcon: webDesktopMode && components.system.isWindows &&
                                    components.settings.windowsTrayIcon

  signal reloadWebClient()

  Component.onCompleted: {
    if (components && components.settings) {
      webUrl = components.settings.getWebClientUrl(webDesktopMode)
    }
  }

  onClosing: function(close) {
    if (showSystemTrayIcon) {
      // Minimize to tray on close.
      close.accepted = false
      mainWindow.hide()
    }
  }

  function toggleFullscreen() {
    setFullScreen(visibility !== Window.FullScreen)
  }

  function toggleDebug() {
    showDebugLayer = !showDebugLayer
  }

  // Through WindowManager, which remembers whether the window was maximized
  // before and puts it back that way. Setting `visibility` here always came back
  // as a normal window, so a maximized one shrank every time fullscreen ended.
  function setFullScreen(enable) {
    components.window.setFullScreen(enable)
  }

  function minimizeWindow() {
    if (visibility !== Window.FullScreen)
      visibility = Window.Minimized
  }

  function restoreWindow() {
    mainWindow.show()
    mainWindow.raise()
    mainWindow.requestActivate()
  }

  function runWebAction(action)
  {
    if (mainWindow.webDesktopMode)
      web.triggerWebAction(action)
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut:
    {
      if (components.system.isMacos) return "Ctrl+Meta+F"
      return "F11"
    }
    onTriggered: mainWindow.toggleFullscreen()
  }

  Action
  {
    shortcut: "Alt+Return"
    enabled:
    {
      if (mainWindow.webDesktopMode && components.system.isWindows)
        return true;
      return false;
    }
    onTriggered: mainWindow.toggleFullscreen()
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: StandardKey.Close
    onTriggered: mainWindow.close()
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: {
      if (components.system.isMacos) return "Ctrl+M";
      return "Meta+Down";
    }
    onTriggered: mainWindow.minimizeWindow()
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: components.system.isWindows ? "Ctrl+Q" : StandardKey.Quit
    onTriggered: Qt.quit()
  }

  Action
  {
    shortcut: "Ctrl+Shift+D"
    enabled: mainWindow.webDesktopMode
    onTriggered: mainWindow.toggleDebug()
  }

  Action
  {
    shortcut: StandardKey.Copy
    onTriggered: runWebAction(WebEngineView.Copy)
    id: action_copy
  }

  Action
  {
    shortcut: StandardKey.Cut
    onTriggered: runWebAction(WebEngineView.Cut)
    id: action_cut
  }

  Action
  {
    shortcut: StandardKey.Paste
    onTriggered: runWebAction(WebEngineView.Paste)
    id: action_paste
  }

  Action
  {
    shortcut: StandardKey.SelectAll
    onTriggered: runWebAction(WebEngineView.SelectAll)
    id: action_selectall
  }

  Action
  {
    shortcut: StandardKey.Undo
    onTriggered: runWebAction(WebEngineView.Undo)
    id: action_undo
  }

  Action
  {
    shortcut: StandardKey.Redo
    onTriggered: runWebAction(WebEngineView.Redo)
    id: action_redo
  }

  Action
  {
    shortcut: StandardKey.Back
    onTriggered: runWebAction(WebEngineView.Back)
    id: action_back
  }

  Action
  {
    shortcut: StandardKey.Forward
    onTriggered: runWebAction(WebEngineView.Forward)
    id: action_forward
  }

  Action
  {
    enabled: mainWindow.webDesktopMode
    shortcut: "Ctrl+0"
    onTriggered: web.zoomFactor = 1.0
  }

  WebChannel
  {
    id: webChannelObject
  }

  Binding
  {
    target: web
    property: "zoomFactor"
    value: 1.0
    when: !components.settings.allowBrowserZoom()
  }

  MpvVideoItem
  {
    id: video
    objectName: "video"
    enabled: true

    width: mainWindow.contentItem.width
    height: mainWindow.contentItem.height
    anchors.left: mainWindow.contentItem.left
    anchors.right: mainWindow.contentItem.right
    anchors.top: mainWindow.contentItem.top

    Component.onCompleted: {
      console.log("MpvVideoItem size:", width, "x", height, "visible:", visible)
    }
    onWidthChanged: console.log("MpvVideoItem width changed:", width)
    onHeightChanged: console.log("MpvVideoItem height changed:", height)
  }

  WebEngineView
  {
    id: web
    objectName: "web"
    width: mainWindow.width
    height: mainWindow.height
    z: 100
    backgroundColor: "transparent"

    /*
     * Notifications, and nothing else.
     *
     * A permission nobody answers is denied, so without this
     * `Notification.requestPermission()` never resolved to "granted" and the
     * switch in Mahfin's own settings could not be turned on. Granting here is
     * not granting blindly: this app opens exactly one site, the request can
     * only have come from a button somebody pressed in that site's settings,
     * and there is no address bar to arrive anywhere else from.
     *
     * Every other permission type is deliberately left alone rather than
     * denied, so this cannot quietly change what a future one does -- an
     * unhandled request is refused by Qt, which is the behaviour that was here
     * before and the safe default for a camera or a microphone.
     */
    onPermissionRequested: function(permission)
    {
      /*
       * The scoped form. QWebEnginePermission::PermissionType is declared with
       * enforcesScopedEnums, so `WebEnginePermission.Notifications` is plain
       * `undefined` in QML -- the comparison silently never matched, the
       * permission was never granted, and the switch in the web app's alerts
       * screen did nothing at all when pressed. QML gives no warning for
       * reading an undefined enum, which is why it survived a clean build.
       */
      if (permission.permissionType === WebEnginePermission.PermissionType.Notifications)
      {
        console.log("Granting notification permission to", permission.origin)
        permission.grant()
      }
    }

    /*
     * Render into an offscreen layer, on the platform that needs it and no
     * other.
     *
     * Upstream added this to stop intermittent black windows on un-minimise
     * and resume from suspend, which is an X11/Wayland compositor problem, and
     * applied it everywhere. It is not free: a layer makes Qt Quick draw this
     * item into a full-window texture and then draw that texture, so every
     * frame of an ordinary, still page costs an extra screen-sized render pass
     * and the memory to hold it — on top of the mpv item underneath and the
     * final composite. On a machine with a capable GPU that is invisible. On
     * the integrated graphics most Windows laptops have, at the window sizes
     * people actually use, it is the difference between the interface feeling
     * immediate and feeling like treacle.
     *
     * So it stays on Linux, where it fixes something, and comes off Windows
     * and macOS, where it only costs. If the black window ever appears there,
     * this is the first line to put back.
     */
    layer.enabled: components.system.isLinux || components.system.isFreeBSD

    /*
     * Tell the page when nobody can see it.
     *
     * Minimising the window, or closing it to the tray, leaves Chromium
     * believing it is on screen: `document.visibilityState` stays "visible",
     * so requestAnimationFrame keeps firing, timers run at full rate, and the
     * home page's carousel goes on counting down and changing slides for an
     * audience of nobody. The page already does the right thing when it is
     * told — browsers stop drawing a hidden tab, throttle its timers, and the
     * web client refreshes itself on the way back — it simply never was.
     *
     * Playback is not affected: mpv lives out here, not in the page, and the
     * page only hears from it through web channel events, which a hidden page
     * still receives.
     */
    visible: mainWindow.visible && mainWindow.visibility !== Window.Minimized
    onVisibleChanged: if (visible) forceActiveFocus()

    webChannel: webChannelObject
    settings.errorPageEnabled: false
    settings.localContentCanAccessRemoteUrls: true
    settings.localContentCanAccessFileUrls: true
    settings.allowRunningInsecureContent: true
    settings.playbackRequiresUserGesture: false
    profile.httpUserAgent: components.system.getUserAgent()
    profile.httpCacheType: WebEngineProfile.DiskHttpCache
    url: mainWindow.webUrl
    focus: true
    property string currentHoveredUrl: ""
    // Where the page is going while it loads. Set on LoadStartedStatus, which
    // arrives before the outgoing page gives up its fullscreen.
    property string loadingUrl: ""
    onLinkHovered: function(hoveredUrl)
    {
      web.currentHoveredUrl = hoveredUrl;
    }
    profile.persistentCookiesPolicy: WebEngineProfile.AllowPersistentCookies
    profile.offTheRecord: false
    profile.storageName: "MahfinDesktopStorage"

    Component.onCompleted:
    {
      console.log("WebEngineView size:", width, "x", height, "backgroundColor:", backgroundColor)
      forceActiveFocus()
      mainWindow.reloadWebClient.connect(reload)

      // Handle CSP workaround from C++
      components.system.pageContentReady.connect(function(html, finalUrl, hadCSP) {
        if (hadCSP) {
          console.log("CSP workaround: navigating to", finalUrl);
          web.url = finalUrl;
        }
      })

      var nativeshell =
      {
        sourceCode: components.system.getNativeShellScript(),
        injectionPoint: WebEngineScript.DocumentCreation,
        worldId: WebEngineScript.MainWorld
      }

      web.profile.userScripts.collection = [ nativeshell ];
    }

    onLoadingChanged: function(loadingInfo)
    {
      // we use a timer here to switch to the webview since
      // it take a few moments for the webview to render
      // after it has loaded.
      //
      if (loadingInfo.status == WebEngineView.LoadStartedStatus)
      {
        console.log("WebEngineLoadRequest starting: " + loadingInfo.url);
        web.loadingUrl = loadingInfo.url;

        // Only for the very first document. Every later navigation happens
        // inside a library the viewer is already looking at, and throwing a
        // full-window cover over that would be a regression, not a splash.
        if (mainWindow.splashVisible)
          mainWindow.splashStatus = qsTr("Connecting to your library")

        // Stop playback whenever the document is replaced.
        //
        // mpv lives out here, not in the page, so it does not go away with it.
        // A reload, a hard navigation or the window closing tears down the JS
        // context without running any of the web client's cleanup — and the
        // film keeps playing, audible, with nothing on screen that belongs to
        // it. The web client does stop the player on its own route changes,
        // but it cannot cover this case: a stop posted from `pagehide` is
        // still queued on the web channel when the page is dismantled, so it
        // never arrives. Measured, not assumed.
        //
        // Harmless when nothing is playing, which includes the first load.
        components.player.stop();
      }
      else if (loadingInfo.status == WebEngineView.LoadSucceededStatus)
      {
        console.log("WebEngineLoadRequest success: " + loadingInfo.url);

        // Loaded is not the same as painted: the document has arrived and the
        // first frame of it has not necessarily been composited yet. Lifting
        // the cover on this signal alone shows a flash of the web view's own
        // background between the two. One short beat is enough, and it is the
        // same reasoning the original comment above records.
        if (mainWindow.splashVisible)
          splashHandoff.start()
      }
      else if (loadingInfo.status == WebEngineView.LoadFailedStatus)
      {
        console.log("WebEngineLoadRequest failure: " + loadingInfo.url + " error code: " + loadingInfo.errorCode);

        // Out of the way, or the cover hides the only explanation there is.
        splashHandoff.stop()
        mainWindow.splashVisible = false
        errorLabel.visible = true
        errorLabel.text = "Error loading client, this is bad and should not happen<br>" +
                          "You can try to <a href='reload'>reload</a> or head to our <a href='http://mahfin.online'>support page</a><br><br>Actual Error: <pre>" +
                          loadingInfo.errorString + " [" + loadingInfo.errorCode + "]</pre><br><br>" +
                          "Provide the <a target='_blank' href='file://"+ components.system.logFilePath + "'>logfile</a> as well."
      }
    }

    onNewWindowRequested:
    {
      if (request.userInitiated)
      {
        console.log("Opening external URL: " + web.currentHoveredUrl)
        components.system.openExternalUrl(web.currentHoveredUrl)
      }
    }

    onFullScreenRequested:
    {
      console.log("Request fullscreen: " + request.toggleOn + " loading: " + loading +
                  " to: " + web.loadingUrl)
      request.accept()
      /*
       * A page that is being replaced gives up its fullscreen on the way out,
       * and that is not the viewer asking to leave. Mahfin reloads into the
       * next episode (see playNavigation.ts in the web app), so following it
       * dropped the window out of fullscreen at every episode change. The new
       * page reads the window's state and draws its button to match, and Esc
       * or the button still take the window out.
       *
       * Only when the page being loaded is another player, though. Back from
       * the player is a page load too — the player is always opened as one —
       * and holding fullscreen for that left the library filling the screen
       * with no title bar, no close button and nothing on the page to undo it.
       */
      if (!request.toggleOn && loading && /\/play\//.test(web.loadingUrl))
        return
      mainWindow.setFullScreen(request.toggleOn)
    }

    onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID)
    {
      components.system.jsLog(level, sourceID + ":" + lineNumber + " " + message);
    }

    onCertificateError: function(error)
    {
      console.log(error.url + " :" + error.description + error.error)
      if (components.settings.ignoreSSLErrors()) {
        error.acceptCertificate()
      }
    }
  }

  /*
   * The start-up cover.
   *
   * Above the web view rather than below it, because the web view is opaque
   * from the moment it exists and "underneath" would mean invisible. It fades
   * out instead of disappearing, which is the difference between the page
   * arriving and the page being snapped into place.
   *
   * Everything here is cheap on purpose: solid fills, one image, no blur, no
   * drop shadow, and on a machine with no GPU not even the pulse — this is the
   * cover for a slow machine, and a cover that is itself expensive to draw is
   * a cover that makes the thing it is covering slower.
   */
  Rectangle
  {
    id: splash
    objectName: "splash"
    z: 200
    anchors.fill: parent
    color: "#07070b"
    visible: opacity > 0
    opacity: mainWindow.splashVisible ? 1 : 0

    Behavior on opacity
    {
      NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
    }

    // Swallow clicks so nothing reaches the page while it is still loading.
    MouseArea { anchors.fill: parent }

    Column
    {
      anchors.centerIn: parent
      spacing: 28

      Image
      {
        id: splashMark
        source: "qrc:/images/icon.png"
        // Bounded rather than proportional: a mark that grows with the window
        // is a mark that is enormous on a television.
        width: Math.max(96, Math.min(160, mainWindow.width * 0.12))
        height: width
        anchors.horizontalCenter: parent.horizontalCenter
        smooth: true
        mipmap: true
        // Decoded at the size it is drawn at, so a 236KB source does not
        // become a full-resolution texture on a machine short of memory.
        sourceSize.width: 160
        sourceSize.height: 160

        // A slow breath, so the window is visibly alive rather than frozen —
        // which is the exact thing being disproved here. Off entirely when a
        // CPU is doing the drawing: it would be a permanent full-window
        // repaint on the machine that can least afford one.
        SequentialAnimation on opacity
        {
          running: mainWindow.splashVisible && !components.system.lowGraphics
          loops: Animation.Infinite
          NumberAnimation { to: 0.55; duration: 1100; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1.0;  duration: 1100; easing.type: Easing.InOutSine }
        }
      }

      Text
      {
        anchors.horizontalCenter: parent.horizontalCenter
        text: mainWindow.splashStatus
        color: "#8b8b9a"
        font.pixelSize: 15
        horizontalAlignment: Text.AlignHCenter
      }
    }

    /*
     * A door out, for the case this cover is wrong.
     *
     * If the page never loads and never reports a failure — a server that
     * accepts the connection and then says nothing is the usual way — the
     * fade-out below is never reached and this would sit on screen forever,
     * hiding an error nobody can now see. After fifteen seconds it says so and
     * offers the one thing that helps.
     */
    Text
    {
      id: splashStuck
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.verticalCenter
      anchors.topMargin: 140
      visible: false
      color: "#6f6f7d"
      linkColor: "#a85dc3"
      font.pixelSize: 13
      textFormat: Text.StyledText
      horizontalAlignment: Text.AlignHCenter
      text: qsTr("This is taking longer than it should. <a href='reload'>Try again</a>")
      onLinkActivated: function(link)
      {
        splashStuck.visible = false
        mainWindow.splashStatus = qsTr("Reconnecting")
        web.reload()
      }
    }

    Timer
    {
      id: splashStuckTimer
      interval: 15000
      running: mainWindow.splashVisible
      onTriggered: splashStuck.visible = true
    }
  }

  Timer
  {
    id: splashHandoff
    interval: 350
    onTriggered: mainWindow.splashVisible = false
  }

  Text
  {
    id: errorLabel
    z: 5
    anchors.centerIn: parent
    color: "#999999"
    linkColor: "#a85dc3"
    text: "Generic error"
    font.pixelSize: 32
    font.bold: true
    visible: false
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.StyledText
    onLinkActivated:
    {
      if (url == "reload")
      {
        errorLabel.visible = false
        web.reload()
      }
      else
      {
        Qt.openUrlExternally(url)
      }
    }
  }


  Rectangle
  {
    id: debug
    color: "black"
    z: 10
    anchors.centerIn: parent
    width: parent.width
    height: parent.height
    opacity: 0.7
    visible: mainWindow.showDebugLayer

    Text
    {
      id: debugLabel
      width: (parent.width - 50) / 2
      height: parent.height - 25
      anchors.left: parent.left
      anchors.leftMargin: 64
      anchors.top: parent.top
      anchors.topMargin: 54
      anchors.bottomMargin: 54
      color: "white"
      font.pixelSize: Math.round(height / 65)
      wrapMode: Text.WrapAnywhere

      function windowDebug()
      {
        var dbg = mainWindow.debugInfo + "Window and web\n";
        dbg += "  Window size: " + parent.width + "x" + parent.height + " - " + web.width + "x" + web.height + "\n";
        dbg += "  DevicePixel ratio: " + Screen.devicePixelRatio + "\n";

        return dbg;
      }

      text: windowDebug()
    }

    Text
    {
      id: videoLabel
      width: (parent.width - 50) / 2
      height: parent.height - 25
      anchors.right: parent.right
      anchors.left: debugLabel.right
      anchors.rightMargin: 64
      anchors.top: parent.top
      anchors.topMargin: 54
      anchors.bottomMargin: 54
      color: "white"
      font.pixelSize: Math.round(height / 65)
      wrapMode: Text.WrapAnywhere

      text: mainWindow.videoInfo
    }
  }

  property QtObject webChannel: web.webChannel

  Labs.SystemTrayIcon {
    visible: showSystemTrayIcon
    icon.source: "qrc:/images/icon.png"
    tooltip: "Mahfin Desktop"

    onActivated: function(reason) {
      if (reason === Labs.SystemTrayIcon.Context) {
        // Right click: open context menu
        contextMenu.open()
        components.window.setCursorVisibility(true)
      } else {
        // All other clicks: restore window
        restoreWindow()
      }
    }

    menu: Labs.Menu {
      id: contextMenu
      Labs.MenuItem {
        text: qsTr("Restore")
        onTriggered: restoreWindow()
      }
      Labs.MenuSeparator {}
      Labs.MenuItem {
        text: qsTr("Quit")
        onTriggered: Qt.quit()
      }
    }
  }
}
