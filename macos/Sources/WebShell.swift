import AppKit
import WebKit

/*
 * Mahfin in the system's own WebKit, with the bridge to the player.
 *
 * Security, carried over from the Qt shell's 1.1.1 lock-down (and stricter):
 *  - The window stays on Mahfin's addresses. Anything else a link or redirect
 *    tries to load is refused; a link the person clicked opens in their
 *    browser (http/https only).
 *  - The bridge script is injected into the main frame only, and a message is
 *    answered only when it comes from the main frame on a trusted origin — so
 *    a frame, or a page the window was somehow pushed to, gets nothing.
 *  - mpv commands from the page are allowlisted (MpvPlayer.userCommand).
 */
final class WebShell: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private let player: MpvPlayer
    private weak var window: NSWindow?
    private var cursorHidden = false
    /// Native pages (Sources/Native): what the page reports, and its answers.
    var onNativeRoute: (([String: Any]) -> Void)?
    var onNativeOverlay: ((Bool) -> Void)?

    static let startURL = URL(string: "https://mahfin.online/")!

    init(player: MpvPlayer, window: NSWindow) {
        self.player = player
        self.window = window

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        // The update prompt picks the download from this: "Darwin" says Mac,
        // and x86_64 says Intel (anything else is Apple silicon). Set on the
        // configuration, which WebKit copies when the view is created.
        #if arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "arm64"
        #endif
        config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15 MahfinDesktop/\(version) (Darwin; \(arch))"

        let content = WKUserContentController()
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        let info: [String: Any] = [
            "version": version,
            "deviceName": Host.current().localizedName ?? "Mac",
            "fullscreen": window.styleMask.contains(.fullScreen),
        ]
        let infoJSON = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let bridgeURL = Bundle.main.url(forResource: "Bridge", withExtension: "js")
        let bridge = bridgeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        content.addUserScript(WKUserScript(
            source: "window.__mahfinInfo = \(infoJSON);\n\(bridge)",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        content.add(WeakHandler(self), name: "mahfin")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Transparent, so the video drawn underneath shows through the player page.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.allowsBackForwardNavigationGestures = false

        player.onSignal = { [weak self] name, args in self?.emit("player", name, args) }
    }

    func start() {
        webView.load(URLRequest(url: WebShell.startURL))
    }

    // MARK: Trust

    static func isTrusted(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        let hosts: Set<String> = ["mahfin.online", "www.mahfin.online", "jf.mahfin.online"]
        switch scheme {
        case "https": return hosts.contains(host) && (url.port ?? 443) == 443
        // Plain http only as the way in; the edge redirects it to https.
        case "http":
            if hosts.contains(host) { return (url.port ?? 80) == 80 }
            return host == "192.168.29.96" && (url.port == 8096 || url.port == 8098)
        case "about": return url.absoluteString == "about:blank"
        default: return false
        }
    }

    private static func openExternally(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if WebShell.isTrusted(url) || action.targetFrame?.isMainFrame == false && url?.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        NSLog("Blocked navigation to %@", url?.host ?? "?")
        if action.navigationType == .linkActivated && action.targetFrame?.isMainFrame != false {
            WebShell.openExternally(url)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Every page load stops playback: the player page's own `pagehide` stop
        // can be lost with the document (the Qt shell did the same).
        player.stop()
        setCursorVisible(true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOffline(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    /// target=_blank and window.open: the browser, never a second window here.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        WebShell.openExternally(action.request.url)
        return nil
    }

    private func showOffline(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:#08080a;color:#e8e8ef;font:15px/1.5 -apple-system,sans-serif}
        main{display:grid;place-items:center;height:100%;text-align:center}
        button{margin-top:16px;padding:10px 18px;border-radius:10px;border:0;background:#e8b54a;color:#2a1e08;font-weight:600}
        </style></head><body><main><div><h2>Mahfin isn't answering</h2>
        <p>Check the internet connection and try again.</p>
        <button onclick="location.href='\(WebShell.startURL.absoluteString)'">Try again</button></div></main></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        let originURL = URL(string: "\(origin.protocol)://\(origin.host)\(origin.port > 0 ? ":\(origin.port)" : "")")
        guard frame.isMainFrame, WebShell.isTrusted(originURL) else {
            NSLog("Ignored a bridge message from %@", origin.host)
            return
        }
        guard let body = message.body as? [String: Any],
              let object = body["object"] as? String,
              let method = body["method"] as? String else { return }
        let args = body["args"] as? [Any] ?? []
        dispatch(object, method, args)
    }

    private func dispatch(_ object: String, _ method: String, _ a: [Any]) {
        func num(_ i: Int) -> Double { (a.count > i ? a[i] as? NSNumber : nil)?.doubleValue ?? 0 }
        func bool(_ i: Int) -> Bool { (a.count > i ? a[i] as? NSNumber : nil)?.boolValue ?? false }
        func str(_ i: Int) -> String { a.count > i ? (a[i] as? String ?? "") : "" }
        func any(_ i: Int) -> Any { a.count > i ? a[i] : NSNull() }

        switch (object, method) {
        case ("player", "load"):
            player.load(url: str(0),
                        options: (a.count > 1 ? a[1] as? [String: Any] : nil) ?? [:],
                        audio: any(3), subtitle: any(4))
        case ("player", "seekTo"): player.seekTo(ms: num(0))
        case ("player", "play"): player.play()
        case ("player", "pause"): player.pause()
        case ("player", "stop"): player.stop()
        case ("player", "setVolume"): player.setVolume(num(0))
        case ("player", "setMuted"): player.setMuted(bool(0))
        case ("player", "setPlaybackRate"): player.setPlaybackRate(num(0))
        case ("player", "setAudioStream"): player.setAudioStream(any(0))
        case ("player", "setSubtitleStream"): player.setSubtitleStream(any(0))
        case ("player", "userCommand"): player.userCommand(str(0))
        case ("player", "setVideoRectangle"): break   // always the whole window
        case ("system", "openExternalUrl"): WebShell.openExternally(URL(string: str(0)))
        case ("window", "setCursorVisibility"): setCursorVisible(bool(0))
        case ("window", "setFullscreen"): setFullscreen(bool(0))
        case ("native", "route"): if let d = a.first as? [String: Any] { onNativeRoute?(d) }
        case ("native", "overlay"): onNativeOverlay?(bool(0))
        default:
            NSLog("bridge: no %@.%@", object, method)
        }
    }

    private func emit(_ object: String, _ name: String, _ args: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__mahfinEmit && window.__mahfinEmit('\(object)','\(name)',\(json))")
    }

    /// `window.__mahfinNav[method](arg)` in the page; the argument is passed as
    /// JSON so no value can break out of the call.
    func callNav(_ method: String, _ arg: String?) {
        guard method.allSatisfy({ $0.isLetter }) else { return }
        var argJSON = ""
        if let arg {
            if arg == "true" || arg == "false" {
                argJSON = arg
            } else if let data = try? JSONSerialization.data(withJSONObject: [arg]),
                      let json = String(data: data, encoding: .utf8) {
                argJSON = String(json.dropFirst().dropLast())
            }
        }
        webView.evaluateJavaScript("window.__mahfinNav && window.__mahfinNav.\(method)(\(argJSON))")
    }

    // MARK: Window

    func fullscreenChanged(_ on: Bool) {
        webView.evaluateJavaScript("window.__mahfinFullscreen && window.__mahfinFullscreen(\(on))")
    }

    private func setFullscreen(_ on: Bool) {
        guard let window, window.styleMask.contains(.fullScreen) != on else { return }
        window.toggleFullScreen(nil)
    }

    /// Hidden only while this window is in front; a hide never outlives the page.
    func setCursorVisible(_ visible: Bool) {
        if visible {
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        } else if !cursorHidden, window?.isKeyWindow == true {
            NSCursor.hide()
            cursorHidden = true
        }
    }
}

/// WKUserContentController keeps its handler alive; this keeps the shell from leaking.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
