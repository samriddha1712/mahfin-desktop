import AppKit
import WebKit

/*
 * Puts native pages and the web app in one window.
 *
 * Layers, bottom to top: the video (mpv), the native pages, the web view. On a
 * native route the web view is cut down to the top bar — transparent, so the
 * page's artwork runs under the bar as it does on the web — and the native page
 * fills the window. A dialog from the bar, or any web page, gets the web view
 * the whole window back.
 *
 * The web app owns navigation (see NativeRoute). A click on a native card shows
 * its page at once and asks the router to follow; a route report from before
 * the click is ignored, so the page never flickers back.
 *
 * The session is kept in the Keychain, so a cold launch can draw the home page
 * from its kept data straight away instead of waiting for the web app to boot.
 */
@MainActor
final class NativeHost {
    let root = NativeRootView()
    private weak var webView: WKWebView?
    private weak var container: NSView?
    private var ctx: NativeContext?
    private var session: NativeSession?
    private var current: ScreenView?
    private var cache: [NativeRoute: ScreenView] = [:]
    private var recent: [NativeRoute] = []
    private var barHeight: CGFloat = 64
    private var webMode = WebMode.full
    private var overlay = false
    private var pending: (path: String, at: Date)?
    private let support = PillButton("Support", style: .glass, height: 44, fontSize: 14)
    /// The bar's glass. The web bar's own backdrop blur cannot reach the native
    /// page under it, so once the page scrolls the app blurs that strip itself.
    private let barBlur = NSVisualEffectView()
    /// Calls `window.__mahfinNav[method](arg)` in the page.
    var callNav: ((String, String?) -> Void)?
    /// The one host, for dev builds' scripted checks.
    static weak var shared: NativeHost?

    enum WebMode { case full, bar }

    init(container: NSView, webView: WKWebView) {
        self.container = container
        self.webView = webView
        root.isHidden = true
        root.frame = container.bounds
        root.autoresizingMask = [.width, .height]
        support.action = { [weak self] in self?.callNav?("openSupport", nil) }
        barBlur.material = .headerView
        barBlur.blendingMode = .withinWindow
        barBlur.state = .active
        barBlur.appearance = NSAppearance(named: .darkAqua)
        barBlur.alphaValue = 0
        root.addSubview(barBlur)
        root.addSubview(support)
        root.onLayout = { [weak self] in self?.layoutSupport() }
        root.onBack = { [weak self] in self?.callNav?("back", nil) }
        root.onForward = { [weak self] in self?.webView?.goForward() }
        Theme.registerFonts()
        NativeHost.shared = self
        // A kept session draws the home page before the web app has booted.
        if let kept = Keychain.loadSession() {
            adopt(kept)
            show(.home, animated: false)
        }
    }

    // MARK: From the web app

    func route(_ state: WebRouteState) {
        Theme.use(state.theme)
        barHeight = CGFloat(state.barHeight)
        if let s = state.session {
            if s != session { adopt(s) }
            Keychain.saveSession(state.rawSession)
        } else if state.path.hasPrefix("/login") {
            // Signed out: forget everything, show the web sign-in.
            Keychain.clearSession()
            session = nil
            ctx = nil
            cache.values.forEach { $0.removeFromSuperview() }
            cache.removeAll()
            current = nil
        }
        if let p = pending {
            if state.path == p.path || Date().timeIntervalSince(p.at) > 3 {
                pending = nil
            } else {
                return   // a report from before the click that started `pending`
            }
        }
        if let r = state.nativeRoute {
            show(r, animated: true)
        } else {
            hideNative()
        }
    }

    func overlayChanged(_ open: Bool) {
        overlay = open
        applyWebFrame()
    }

    // MARK: Navigation from native pages

    /// Goes to `path`: a native page at once, anything else when the web loads it.
    func open(_ path: String) {
        // The player takes the whole window at once: it is drawn by mpv under a
        // transparent web page, and nothing native may sit in between.
        if path.hasPrefix("/play/") {
            pending = (path, Date())
            hideNative()
        }
        if NativeRoute(path: path) != nil, session != nil {
            pending = (path, Date())
            if let r = NativeRoute(path: path) { show(r, animated: true) }
        }
        callNav?("push", path)
    }

    // MARK: Screens

    private func adopt(_ s: NativeSession) {
        session = s
        let ctx = NativeContext(session: s) { [weak self] path in self?.open(path) }
        self.ctx = ctx
        cache.values.forEach { $0.removeFromSuperview() }
        cache.removeAll()
        current = nil
        ctx.refreshShared()
    }

    private func screen(for r: NativeRoute) -> ScreenView? {
        if let s = cache[r] { return s }
        guard let ctx else { return nil }
        let s: ScreenView
        switch r {
        case .home: s = HomeScreen(ctx: ctx)
        case .item(let id): s = ItemScreen(id: id, ctx: ctx)
        case .browse(let feed): s = BrowseScreen(feed: feed, ctx: ctx)
        }
        s.onScrolled = { [weak self] scrolled in
            self?.callNav?("setScrolled", scrolled ? "true" : "false")
            self?.setBarGlass(scrolled)
        }
        cache[r] = s
        return s
    }

    private func show(_ r: NativeRoute, animated: Bool) {
        guard let next = screen(for: r) else { return }
        let wasHidden = root.isHidden
        root.isHidden = false
        webMode = .bar
        applyWebFrame()
        defer { remember(r) }
        if next === current { return }
        // Back to a page still kept: it slides in from the left, like the web.
        let back = recent.contains(r)
        let previous = current
        previous?.deactivate()
        current = next
        next.frame = root.bounds
        next.autoresizingMask = [.width, .height]
        root.addSubview(next, positioned: .below, relativeTo: barBlur)
        next.activate()
        if animated && !wasHidden {
            slideIn(next, from: back ? -44 : 44)
        }
        if let previous {
            previous.removeFromSuperview()
        }
        root.window?.makeFirstResponder(next.scroll)
    }

    private func slideIn(_ v: NSView, from dx: CGFloat) {
        guard let layer = v.layer else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = dx
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.34
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        layer.add(group, forKey: "slide")
    }

    /// Keeps the home page and the last few pages; drops the rest.
    private func remember(_ r: NativeRoute) {
        recent.removeAll { $0 == r }
        recent.append(r)
        while recent.count > 6 {
            let old = recent.removeFirst()
            if old != .home, cache[old] !== current { cache[old] = nil }
        }
        for key in cache.keys where key != .home && !recent.contains(key) { cache[key] = nil }
    }

    private func hideNative() {
        current?.deactivate()
        root.isHidden = true
        webMode = .full
        applyWebFrame()
    }

    // MARK: Web view frame

    private func applyWebFrame() {
        guard let webView, let container else { return }
        let full = webMode == .full || overlay
        if full {
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
        } else {
            // The bar strip at the top of a non-flipped container.
            webView.frame = NSRect(x: 0, y: container.bounds.height - barHeight, width: container.bounds.width, height: barHeight)
            webView.autoresizingMask = [.width, .minYMargin]
        }
    }

    private func setBarGlass(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            barBlur.animator().alphaValue = on ? 1 : 0
        }
    }

    private func layoutSupport() {
        barBlur.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: barHeight)
        support.sizeToFit()
        support.frame = NSRect(x: root.bounds.width - support.frame.width - 24, y: root.bounds.height - 44 - 24,
                               width: support.frame.width, height: 44)
    }
}

/// The native layer; also catches back/forward from the keyboard and mouse.
final class NativeRootView: FlippedView {
    var onLayout: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.backgroundColor = Theme.palette.void.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func otherMouseUp(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: onBack?()
        case 4: onForward?()
        default: super.otherMouseUp(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "[": onBack?(); return true
        case "]": onForward?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// The signed-in session, kept for the next cold launch.
///
/// A file readable by this user only, not the Keychain. The builds are
/// ad-hoc signed (there is no paid developer identity), so the Keychain cannot
/// recognise a later launch or a new build as the same app and asked for access
/// on every start. The token is already on disk in WebKit's own storage for the
/// site, unencrypted, so a 0600 file beside it costs nothing in safety.
enum Keychain {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("online.mahfin.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("session.json")
    }

    static func saveSession(_ dict: [String: Any]?) {
        guard let dict, let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let url = file
        if let old = try? Data(contentsOf: url), old == data { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    static func loadSession() -> NativeSession? {
        guard let data = try? Data(contentsOf: file),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return NativeSession(dict)
    }

    static func clearSession() {
        try? FileManager.default.removeItem(at: file)
    }
}
