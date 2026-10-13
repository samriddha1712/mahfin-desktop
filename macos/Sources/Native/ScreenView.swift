import AppKit

/*
 * A native page: a vertical scroll view over a flipped document. Reports to
 * the host when it has scrolled far enough for the web bar to go solid (the
 * bar's own rule, 24 pt), and tells its rows when they come on screen so only
 * those hold cards.
 */
@MainActor
class ScreenView: FlippedView {
    let route: NativeRoute
    let ctx: NativeContext
    let scroll = PageScrollView()
    let document = FlippedView()
    var onScrolled: ((Bool) -> Void)?
    private var scrolled = false
    /// Rows to keep in step with the viewport.
    var rows: [RowView] = []

    init(route: NativeRoute, ctx: NativeContext) {
        self.route = route
        self.ctx = ctx
        super.init(frame: .zero)
        layer?.backgroundColor = Theme.palette.void.cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        ctx.onChange { [weak self] in self?.rows.forEach { $0.refreshCards() } }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutDocument(width: bounds.width)
        refreshRows()
    }

    /// Subclasses lay their content out in `document` and set its height.
    func layoutDocument(width: CGFloat) {}

    /// For pages with scroll-driven motion (the home page's hero).
    func scrolled(to y: CGFloat) {}

    @objc private func didScroll() {
        let y = scroll.contentView.bounds.minY
        scrolled(to: y)
        Hover.scrolled()
        let now = y > 24
        if now != scrolled {
            scrolled = now
            onScrolled?(now)
        }
        refreshRows()
    }

    var isScrolled: Bool { scrolled }

    func refreshRows() {
        let clip = scroll.contentView.bounds
        // The web's observer: `rootMargin: 0 0 -6% 0`, so a row reveals once its
        // top is 6% above the bottom of the window.
        let line = clip.maxY - clip.height * 0.06
        for r in rows {
            r.refreshVisibility()
            r.revealIfNeeded(viewportBottom: line, in: document)
        }
    }

    private var shownOnce = false

    /// The page's own entrance (`.fade-in`: 0.35 s), the first time it appears
    /// without a slide (a cold launch); the host's slide covers the rest.
    func fadeInIfFirst() {
        guard !shownOnce, let layer else { shownOnce = true; return }
        shownOnce = true
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.35
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "fade-in")
    }

    func markShown() { shownOnce = true }

    /// Shown again (back to this page): resume anything that runs on its own.
    func activate() { onScrolled?(scrolled) }
    func deactivate() {}

    /// Stacks views top to bottom with a gap, skipping hidden ones; returns the bottom.
    @discardableResult
    func stack(_ views: [NSView], from top: CGFloat, width: CGFloat, gap: CGFloat, height: (NSView) -> CGFloat) -> CGFloat {
        var y = top
        for v in views where !v.isHidden {
            let h = height(v)
            v.frame = NSRect(x: 0, y: y, width: width, height: h)
            y += h + gap
        }
        return y
    }
}

/// The page scroll view; keeps keyboard scrolling (space, arrows, page keys).
final class PageScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let clip = contentView
        let page = clip.bounds.height * 0.9
        var y = clip.bounds.minY
        switch event.keyCode {
        case 49: y += event.modifierFlags.contains(.shift) ? -page : page   // space
        case 121: y += page                                                  // page down
        case 116: y -= page                                                  // page up
        case 125: y += 60                                                    // down
        case 126: y -= 60                                                    // up
        case 115: y = 0                                                      // home
        case 119: y = (documentView?.frame.height ?? 0) - clip.bounds.height // end
        default: super.keyDown(with: event); return
        }
        y = max(0, min(y, (documentView?.frame.height ?? 0) - clip.bounds.height))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        reflectScrolledClipView(clip)
    }
}
