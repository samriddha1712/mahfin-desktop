import AppKit
import QuartzCore

/*
 * Building blocks for the native pages. All layer-backed and flipped (y grows
 * downward, like the web), and built so that scrolling never asks the CPU to
 * draw: artwork is a layer's `contents`, hover motion is a transform on the
 * GPU, and shadows carry an explicit `shadowPath` so they are never computed
 * from pixels.
 */

class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A vertical shade, top to foot, that is the right way up wherever it sits.
///
/// CAGradientLayer reads its start and end points in a space that AppKit flips
/// for some layers and not others (it depends on how many ancestors are
/// flipped), and every attempt to predict it put a hard edge under one
/// backdrop or another. Pictures, on the other hand, are drawn upright
/// everywhere here — so the shade is a small picture: drawn top to foot once,
/// stretched to fit.
final class ShadeLayer: CALayer {
    override init() {
        super.init()
        contentsGravity = .resize
        needsDisplayOnBoundsChange = false
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `colors` from the top to the foot, at `locations` (0…1, top to foot).
    func set(_ colors: [NSColor], at locations: [CGFloat]? = nil) {
        let h = 256
        guard let ctx = CGContext(data: nil, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors.map(\.cgColor) as CFArray,
                                 locations: locations ?? (0..<colors.count).map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) })
        else { return }
        // Bitmap y runs up; the image's first row is its top. Top colour at y = h.
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        contents = ctx.makeImage()
    }
}

extension NSTextField {
    /// The size a label needs to draw without truncating. `intrinsicContentSize`
    /// leaves out the 2 pt the cell pads each side with, so a label framed to
    /// it truncates its own text ("Play" became "P…").
    var fitSize: NSSize {
        guard let cell else { return intrinsicContentSize }
        let s = cell.cellSize
        return NSSize(width: ceil(s.width), height: ceil(s.height))
    }
}

/// A single-line or clamped label.
func makeLabel(_ text: String = "", font: NSFont, color: NSColor, lines: Int = 1) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.maximumNumberOfLines = lines
    l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    l.cell?.truncatesLastVisibleLine = true
    l.isSelectable = false
    l.drawsBackground = false
    l.wantsLayer = true
    return l
}

// MARK: - Image

/// Shows a remote image, decoded to its own pixel size off the main thread.
/// Placeholder: the theme's gradient, as the web cards use.
final class ArtworkView: FlippedView {
    private let gradient = CAGradientLayer()
    private let imageLayer = CALayer()
    private var task: Task<Void, Never>?
    private(set) var url: URL?
    var contentsGravity: CALayerContentsGravity = .resizeAspectFill {
        didSet { imageLayer.contentsGravity = contentsGravity }
    }
    var placeholder = true {
        didSet { gradient.isHidden = !placeholder }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        gradient.colors = [Theme.palette.placeholderFrom.cgColor, Theme.palette.placeholderTo.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(gradient)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.opacity = 0
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue; layer?.cornerCurve = .continuous }
    }

    /// Loads `url`. `points` is the drawn size of the longer side in points.
    func load(_ url: URL?, points: CGFloat) {
        guard url != self.url else { return }
        self.url = url
        task?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        imageLayer.opacity = 0
        CATransaction.commit()
        guard let url else { return }
        let scale = min(2, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let pixels = Int((points * scale).rounded(.up))
        if let hit = ImagePipeline.shared.cached(url, pixels: pixels) {
            show(hit, animated: false)
            return
        }
        task = Task { @MainActor [weak self] in
            let image = await ImagePipeline.shared.image(url, pixels: pixels)
            guard !Task.isCancelled, let self, self.url == url, let image else { return }
            self.show(image, animated: true)
        }
    }

    private func show(_ image: CGImage, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        imageLayer.contents = image
        imageLayer.opacity = 1
        CATransaction.commit()
    }

    func clear() {
        task?.cancel()
        url = nil
        imageLayer.contents = nil
        imageLayer.opacity = 0
    }
}

// MARK: - Buttons

/// A rounded button: filled (the accent), glass, or plain text. Hover and
/// press respond at once, on the GPU.
final class PillButton: FlippedView {
    enum Style { case accent, glass, outline, text }
    private let label: NSTextField
    private let iconLayer = CAShapeLayer()
    var style: Style { didSet { restyle() } }
    var action: (() -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    private var hovering = false
    private var tracking: NSTrackingArea?
    private let height: CGFloat
    var icon: Icon? { didSet { restyle(); needsLayout = true } }

    enum Icon { case play, plus, check, chevronRight, chevronLeft, bookmark, bookmarkFilled }

    init(_ title: String, style: Style, height: CGFloat = 44, fontSize: CGFloat = 15) {
        self.style = style
        self.height = height
        label = makeLabel(title, font: Theme.text(fontSize, .semibold), color: Theme.palette.ink)
        super.init(frame: .zero)
        addSubview(label)
        layer?.addSublayer(iconLayer)
        layer?.cornerCurve = .continuous
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize(); needsLayout = true }
    }

    override var intrinsicContentSize: NSSize {
        let text = label.fitSize.width
        let pad: CGFloat = style == .text ? 0 : (height > 36 ? 22 : 14)
        let iconW: CGFloat = icon == nil ? 0 : (title.isEmpty ? height * 0.42 : height * 0.36 + 8)
        let w = title.isEmpty ? height : text + pad * 2 + iconW
        return NSSize(width: ceil(w), height: height)
    }

    func sizeToFit() { setFrameSize(intrinsicContentSize) }

    private func restyle() {
        let p = Theme.palette
        layer?.cornerRadius = height / 2
        layer?.borderWidth = 0
        switch style {
        case .accent:
            layer?.backgroundColor = p.accent.cgColor
            label.textColor = p.accentInk
        case .glass:
            layer?.backgroundColor = (hovering ? p.glassStrong : p.panel).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = p.glassBorder.cgColor
            label.textColor = p.ink
        case .outline:
            layer?.backgroundColor = (hovering ? p.glassStrong : p.glass).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = p.glassBorder.cgColor
            label.textColor = p.ink
        case .text:
            layer?.backgroundColor = nil
            label.textColor = hovering ? p.ink : p.muted
        }
        iconLayer.fillColor = label.textColor?.cgColor
        iconLayer.strokeColor = label.textColor?.cgColor
        if style == .accent { layer?.opacity = hovering ? 0.92 : 1 }
    }

    override func layout() {
        super.layout()
        let size = label.fitSize
        let iconSize = title.isEmpty ? height * 0.42 : height * 0.36
        var x = (bounds.width - (size.width + (icon == nil || title.isEmpty ? 0 : iconSize + 8))) / 2
        if let icon {
            let ix = title.isEmpty ? (bounds.width - iconSize) / 2 : x
            CATransaction.begin(); CATransaction.setDisableActions(true)
            iconLayer.frame = CGRect(x: ix, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            iconLayer.path = Self.path(icon, iconSize)
            iconLayer.lineWidth = icon == .play ? 0 : max(1.6, iconSize / 9)
            iconLayer.fillColor = (icon == .play || icon == .bookmarkFilled) ? label.textColor?.cgColor : nil
            iconLayer.lineCap = .round
            iconLayer.lineJoin = .round
            CATransaction.commit()
            x = ix + iconSize + 8
        }
        label.isHidden = title.isEmpty
        label.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    static func path(_ icon: Icon, _ s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        switch icon {
        case .play:
            p.move(to: CGPoint(x: s * 0.22, y: s * 0.12))
            p.addLine(to: CGPoint(x: s * 0.88, y: s * 0.5))
            p.addLine(to: CGPoint(x: s * 0.22, y: s * 0.88))
            p.closeSubpath()
        case .plus:
            p.move(to: CGPoint(x: s * 0.5, y: s * 0.15)); p.addLine(to: CGPoint(x: s * 0.5, y: s * 0.85))
            p.move(to: CGPoint(x: s * 0.15, y: s * 0.5)); p.addLine(to: CGPoint(x: s * 0.85, y: s * 0.5))
        case .check:
            p.move(to: CGPoint(x: s * 0.16, y: s * 0.52))
            p.addLine(to: CGPoint(x: s * 0.42, y: s * 0.76))
            p.addLine(to: CGPoint(x: s * 0.86, y: s * 0.26))
        case .chevronRight:
            p.move(to: CGPoint(x: s * 0.36, y: s * 0.18)); p.addLine(to: CGPoint(x: s * 0.68, y: s * 0.5))
            p.addLine(to: CGPoint(x: s * 0.36, y: s * 0.82))
        case .chevronLeft:
            p.move(to: CGPoint(x: s * 0.64, y: s * 0.18)); p.addLine(to: CGPoint(x: s * 0.32, y: s * 0.5))
            p.addLine(to: CGPoint(x: s * 0.64, y: s * 0.82))
        case .bookmark, .bookmarkFilled:
            p.move(to: CGPoint(x: s * 0.26, y: s * 0.12))
            p.addLine(to: CGPoint(x: s * 0.74, y: s * 0.12))
            p.addLine(to: CGPoint(x: s * 0.74, y: s * 0.88))
            p.addLine(to: CGPoint(x: s * 0.5, y: s * 0.68))
            p.addLine(to: CGPoint(x: s * 0.26, y: s * 0.88))
            p.closeSubpath()
        }
        return p
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.setAffineTransform(CGAffineTransform(scaleX: 0.96, y: 0.96))
    }
    override func mouseUp(with event: NSEvent) {
        layer?.setAffineTransform(.identity)
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Horizontal strip

/// A horizontally scrolling scroll view that hands vertical gestures to the
/// page, decided once at the start of each gesture.
final class StripScrollView: NSScrollView {
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided

    override func scrollWheel(with event: NSEvent) {
        // A new trackpad gesture, or a mouse-wheel notch (which has no phases):
        // decide again. Momentum events keep the axis of their gesture.
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            axis = .undecided
        }
        if axis == .undecided {
            let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
            if dx == 0 && dy == 0 {
                // The opening event of a gesture often has no movement yet:
                // both may need it to begin tracking.
                nextResponder?.scrollWheel(with: event)
                super.scrollWheel(with: event)
                return
            }
            axis = dx > dy ? .horizontal : .vertical
        }
        if axis == .vertical {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Cells laid out in a row, only the visible ones alive, the rest recycled.
/// `make` builds a cell; `configure` fills one for an index.
final class CardStrip<Cell: NSView>: FlippedView {
    let scroll = StripScrollView()
    private let document = FlippedView()
    var count = 0 { didSet { relayout(); refresh() } }
    var cellSize = NSSize(width: 166, height: 300)
    var spacing: CGFloat = 14
    var inset: CGFloat = 40
    private var live: [Int: Cell] = [:]
    private var pool: [Cell] = []
    let make: () -> Cell
    private(set) var configure: (Cell, Int) -> Void

    func setConfigure(_ f: @escaping (Cell, Int) -> Void) {
        configure = f
        reloadVisible()
    }
    /// Indices about to come on screen, for prefetching their images.
    var prefetch: ((Range<Int>) -> Void)?

    init(make: @escaping () -> Cell, configure: @escaping (Cell, Int) -> Void) {
        self.make = make
        self.configure = configure
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.usesPredominantAxisScrolling = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        relayout()
        refresh()
    }

    private func relayout() {
        let width = inset * 2 + CGFloat(count) * cellSize.width + CGFloat(max(0, count - 1)) * spacing
        document.frame = NSRect(x: 0, y: 0, width: max(width, bounds.width), height: bounds.height)
    }

    @objc private func scrolled() { refresh() }

    func frame(for index: Int) -> NSRect {
        NSRect(x: inset + CGFloat(index) * (cellSize.width + spacing), y: 0, width: cellSize.width, height: cellSize.height)
    }

    /// Creates the cells in view (and a cell either side), recycles the rest.
    /// Rows scrolled off the page vertically keep no cells at all.
    func refresh() {
        let visible = visibleRect
        guard count > 0, !visible.isEmpty, window != nil else {
            for (_, c) in live { c.removeFromSuperview(); pool.append(c) }
            live.removeAll()
            return
        }
        let x0 = scroll.contentView.bounds.minX
        let x1 = x0 + scroll.bounds.width
        let step = cellSize.width + spacing
        let first = max(0, Int(floor((x0 - inset) / step)) - 1)
        let last = min(count - 1, Int(ceil((x1 - inset) / step)) + 1)
        guard first <= last else { return }
        for (i, c) in live where i < first || i > last {
            c.removeFromSuperview()
            pool.append(c)
            live[i] = nil
        }
        for i in first...last where live[i] == nil {
            let c = pool.popLast() ?? make()
            c.frame = frame(for: i)
            configure(c, i)
            document.addSubview(c)
            live[i] = c
        }
        prefetch?((last + 1)..<min(count, last + 6))
    }

    func reloadVisible() {
        for (i, c) in live { configure(c, i) }
    }

    func scrollBy(pages: Int) {
        let target = max(0, min(document.frame.width - scroll.bounds.width,
                                scroll.contentView.bounds.minX + CGFloat(pages) * scroll.bounds.width * 0.85))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: target, y: 0))
        }
    }
}
