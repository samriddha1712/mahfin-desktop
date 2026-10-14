import AppKit
import WebKit
import QuartzCore

// Dev builds only: runs MAHFIN_DEV_STEPS, e.g.
//   "wait:10;shot:/tmp/a.png;flick:2;bench;open:/item/x;wait:4;shot:/tmp/b.png;quit"
@MainActor
enum DevAutomation {
    static func start() {
        guard let script = ProcessInfo.processInfo.environment["MAHFIN_DEV_STEPS"] else { return }
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor in
            for step in steps {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 1) * 1e9))
                case "shot": shot(arg)
                case "shot2": shotAppKit(arg)
                case "winshot":
                    // The window as the screen composites it — the only capture
                    // that includes video layers.
                    if let w = window {
                        let t = Process()
                        t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        t.arguments = ["-x", "-o", "-l", String(w.windowNumber), arg]
                        try? t.run(); t.waitUntilExit()
                    }
                case "open": NativeHost.shared?.open(arg)
                case "nav": NativeHost.shared?.callNav?(arg, nil)
                case "js":
                    if let web = window?.contentView?.subviews.first(where: { $0 is WKWebView }) as? WKWebView {
                        _ = try? await web.evaluateJavaScript(arg)
                    }
                case "jsprint":
                    if let web = window?.contentView?.subviews.first(where: { $0 is WKWebView }) as? WKWebView {
                        let r = try? await web.evaluateJavaScript(arg)
                        print("[dev] js ->", r.map { "\($0)" } ?? "nil"); fflush(stdout)
                    }
                case "buttons":
                    var out: [String] = []
                    func walk(_ v: NSView) {
                        if let b = v as? PillButton, !b.isHidden, b.window != nil { out.append(b.title) }
                        v.subviews.forEach(walk)
                    }
                    if let c = window?.contentView { walk(c) }
                    print("[dev] buttons:", out.joined(separator: " | ")); fflush(stdout)
                case "route":
                    print("[dev] route", NativeHost.shared?.debugRoute ?? "-"); fflush(stdout)
                case "badges":
                    var n = 0
                    func walk(_ v: NSView) {
                        if let c = v as? CardCell, !c.friends.isHidden, !c.isHidden { n += 1 }
                        v.subviews.forEach(walk)
                    }
                    if let c = window?.contentView { walk(c) }
                    print("[dev] friend badges on cards:", n); fflush(stdout)
                case "scrollto":
                    if let root = window?.contentView?.subviews.first(where: { $0 is NativeRootView }),
                       let screen = root.subviews.first(where: { $0 is ScreenView }) as? ScreenView {
                        screen.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: CGFloat(Double(arg) ?? 0)))
                        screen.scroll.reflectScrolledClipView(screen.scroll.contentView)
                    }
                case "flick": for _ in 0..<(Int(arg) ?? 1) { await flick(1) }
                case "up": for _ in 0..<(Int(arg) ?? 1) { await flick(-1) }
                case "bench": await bench()
                case "scrollbench": await scrollBench()
                case "log": print("[dev]", arg); fflush(stdout)
                case "frames": frames()
                case "rows":
                    var out: [String] = []
                    func walk(_ v: NSView) {
                        if let r = v as? RowView { out.append("\(r.revealed ? "R" : "-")@\(Int(r.frame.minY))\(r.isHidden ? "h" : "")") }
                        v.subviews.forEach(walk)
                    }
                    if let c = window?.contentView { walk(c) }
                    print("[dev] rows", out.joined(separator: " ")); fflush(stdout)
                case "hovered":
                    var n = 0
                    func walk(_ v: NSView) { if let c = v as? CardCell, c.hovering { n += 1 }; v.subviews.forEach(walk) }
                    if let c = window?.contentView { walk(c) }
                    print("[dev] hovered cards:", n); fflush(stdout)
                case "hover":
                    // Hover the Nth card (by index across the page) that is on screen.
                    var cards: [CardCell] = []
                    func collect(_ v: NSView) {
                        if let c = v as? CardCell, !c.isHidden, !c.visibleRect.isEmpty { cards.append(c) }
                        v.subviews.forEach(collect)
                    }
                    if let c = window?.contentView { collect(c) }
                    let n = Int(arg) ?? 0
                    if n < cards.count, let e = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                                         windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                        cards[n].mouseEntered(with: e)
                        print("[dev] hovering", type(of: cards[n]), cards[n].title.stringValue)
                    }
                case "hero":
                    func find(_ v: NSView) -> HeroView? {
                        if let h = v as? HeroView { return h }
                        for s in v.subviews { if let h = find(s) { return h } }
                        return nil
                    }
                    if let c = window?.contentView, let h = find(c) { print("[dev] hero", h.debugState); fflush(stdout) }
                case "meterfake":
                    func findMeter(_ v: NSView) -> MeterView? {
                        if let m = v as? MeterView { return m }
                        for s in v.subviews { if let m = findMeter(s) { return m } }
                        return nil
                    }
                    let now = Date().timeIntervalSince1970 * 1000
                    let json = """
                    {"key":"movie:1","total":7,"counts":{"perfection":3,"go_for_it":2,"timepass":1,"skip":1},"mine":"go_for_it",
                     "friends":[{"person":{"id":"a","alias":"Quiet Comet","name":"partha_23","avatarOf":null},"verdict":"perfection","at":\(now - 7200000),"vibes":["mind_bending","edge"],
                                 "review":{"text":"The last forty minutes rewrite everything before them. Watch it without reading anything.","at":\(now - 7200000),"likes":2,"liked":true}},
                                {"person":{"id":"b","alias":"Amber Fox","name":"strucker30","avatarOf":null},"verdict":"timepass","at":\(now - 90000000),"vibes":["slow_burn"],"review":null}],
                     "vibes":[{"vibe":"mind_bending","count":4},{"vibe":"edge","count":3},{"vibe":"dark","count":1}],
                     "myVibes":["edge"],"myReview":{"text":"Better than the second one.","at":\(now - 300000),"likes":1,"liked":false},"otherReviews":2}
                    """
                    if let c = window?.contentView, let m = findMeter(c) { m.debugShow(json) } else { print("[dev] no meter") }
                case "meteroff":
                    if let c = window?.contentView {
                        func y(_ v: NSView) -> CGFloat? {
                            if let m = v as? MeterView { return m.frame.minY }
                            for s in v.subviews { if let r = y(s) { return r } }
                            return nil
                        }
                        print("[dev] meter at", y(c) as Any); fflush(stdout)
                    }
                case "layers": layers()
                case "quit": NSApp.terminate(nil)
                default: print("[dev] unknown step", step)
                }
            }
        }
    }

    static func frames() {
        guard let w = window, let c = w.contentView else { return }
        print("[dev] window", w.frame, "content", c.bounds)
        for v in c.subviews { print("[dev]   ", type(of: v), v.frame, "hidden", v.isHidden) }
        if let root = c.subviews.first(where: { $0 is NativeRootView }) {
            for s in root.subviews { print("[dev]     ", type(of: s), s.frame) }
            if let screen = root.subviews.first(where: { $0 is ScreenView }) as? ScreenView {
                print("[dev]     scroll y", screen.scroll.contentView.bounds.origin.y, "doc", screen.document.frame.size)
            }
        }
        let p = w.mouseLocationOutsideOfEventStream
        print("[dev]   hit at centre", type(of: c.hitTest(NSPoint(x: c.bounds.midX, y: c.bounds.midY)) as Any), "mouse", p)
        fflush(stdout)
    }

    static func layers() {
        func find(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)) == "BackdropHeader" { return v }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let c = window?.contentView, let h = find(c) else { print("[dev] no header"); return }
        print("[dev] header frame", h.frame, "bounds", h.bounds, "flipped", h.layer?.isGeometryFlipped ?? false)
        for l in h.layer?.sublayers ?? [] {
            print("[dev]   ", type(of: l), l.frame, "hidden", l.isHidden, "opacity", l.opacity, (l as? CAGradientLayer).map { "start \($0.startPoint) end \($0.endPoint) n=\($0.colors?.count ?? 0)" } ?? "")
        }
        fflush(stdout)
    }

    static var window: NSWindow? { NSApp.windows.first { $0.isVisible } }

    /// The window's layer tree rendered to a PNG (native layers; the web view's
    /// content is drawn out of process and does not appear).
    static func shot(_ path: String) {
        guard let w = window, let view = w.contentView, let layer = view.layer else { return }
        let scale = w.backingScaleFactor
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("[dev] shot", path); fflush(stdout)
    }

    /// AppKit's own drawing of the window (text exactly as on screen).
    static func shotAppKit(_ path: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("[dev] shot2", path); fflush(stdout)
    }

    static func post(_ dy: Int32, _ phase: Int64, _ mom: Int64) {
        guard let w = window else { return }
        let c = CGPoint(x: w.frame.midX, y: NSScreen.screens[0].frame.height - w.frame.midY)
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
        e.location = c
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: mom)
        // Into this process's own event stream, as a real trackpad's events
        // arrive: AppKit's scroll view tracks a gesture by pulling its later
        // events from the queue, so handing them to a view directly does nothing.
        e.postToPid(getpid())
    }

    /// One two-finger flick with momentum, as the trackpad reports it (120 Hz).
    static func flick(_ dir: Int32) async {
        let tick: UInt64 = 8_333_333
        post(0, 1, 0)
        for _ in 0..<20 { post(-28 * dir, 2, 0); try? await Task.sleep(nanoseconds: tick) }
        post(0, 4, 0)
        var v = 28.0
        post(-Int32(v) * dir, 0, 1)
        while v > 1 { v *= 0.965; post(-Int32(v) * dir, 0, 2); try? await Task.sleep(nanoseconds: tick) }
        post(0, 0, 3)
    }

    static func scrollBench() async {
        guard let root = window?.contentView?.subviews.first(where: { $0 is NativeRootView }),
              let screen = root.subviews.first(where: { $0 is ScreenView }) as? ScreenView else { return }
        let clip = screen.scroll.contentView
        let driver = ScrollDriver(clip: clip, maxY: screen.document.frame.height - clip.bounds.height)
        let link = root.displayLink(target: driver, selector: #selector(ScrollDriver.tick(_:)))
        let start = CACurrentMediaTime()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            driver.done = { c.resume() }
            link.add(to: .main, forMode: .common)
        }
        let gaps = driver.gaps.sorted()
        let n = gaps.count, secs = CACurrentMediaTime() - start
        let q = { (p: Double) in n > 0 ? gaps[min(n - 1, Int(Double(n) * p))] * 1000 : 0 }
        print(String(format: "[dev] scrollbench %.1fs frames=%d fps=%.1f p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms over20ms=%d over34ms=%d reached=%.0f",
                     secs, n, Double(n) / secs, q(0.5), q(0.95), q(0.99), (gaps.last ?? 0) * 1000,
                     gaps.filter { $0 > 0.020 }.count, gaps.filter { $0 > 0.034 }.count, clip.bounds.minY))
        fflush(stdout)
    }

    /// Frame pacing on the main thread while four flicks scroll the page.
    static func bench() async {
        guard let view = window?.contentView else { return }
        let probe = FrameProbe()
        let link = view.displayLink(target: probe, selector: #selector(FrameProbe.tick(_:)))
        link.add(to: .main, forMode: .common)
        let start = CACurrentMediaTime()
        await flick(1); await flick(1); await flick(-1); await flick(-1)
        link.invalidate()
        let gaps = probe.gaps.sorted()
        let n = gaps.count
        let secs = CACurrentMediaTime() - start
        let q = { (p: Double) in n > 0 ? gaps[min(n - 1, Int(Double(n) * p))] * 1000 : 0 }
        print(String(format: "[dev] bench %.1fs frames=%d fps=%.1f p50=%.1fms p95=%.1fms max=%.1fms over25ms=%d",
                     secs, n, Double(n) / secs, q(0.5), q(0.95), (gaps.last ?? 0) * 1000, gaps.filter { $0 > 0.025 }.count))
        fflush(stdout)
    }
}

/// Scrolls the current native page from the display link, flick by flick
/// (fast start, decaying, like trackpad momentum), and records frame gaps.
final class ScrollDriver: NSObject {
    let clip: NSClipView
    let maxY: CGFloat
    var velocity: CGFloat = 0
    var direction: CGFloat = 1
    var flicks = 0
    var last: CFTimeInterval = 0
    var gaps: [CFTimeInterval] = []
    var done: (() -> Void)?
    init(clip: NSClipView, maxY: CGFloat) { self.clip = clip; self.maxY = maxY }
    @objc func tick(_ link: CADisplayLink) {
        let t = link.timestamp
        if last > 0 { gaps.append(t - last) }
        last = t
        if velocity < 2 {
            flicks += 1
            if flicks > 10 { link.invalidate(); done?(); return }
            // Five flicks down the page, five back up.
            direction = flicks <= 5 ? 1 : -1
            velocity = 70
        }
        var y = clip.bounds.minY + velocity * direction
        y = max(0, min(maxY, y))
        clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
        velocity *= 0.965
    }
}

final class FrameProbe: NSObject {
    var last: CFTimeInterval = 0
    var gaps: [CFTimeInterval] = []
    @objc func tick(_ link: CADisplayLink) {
        let t = link.timestamp
        if last > 0 { gaps.append(t - last) }
        last = t
    }
}
