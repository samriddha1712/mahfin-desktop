import AppKit

/*
 * The Mahfin Meter on a title page, as Mahfin's Verdict.tsx draws it: the
 * household's split as a half-circle gauge and four bars (or, below three
 * verdicts, how many more are needed), the vibe line, your own verdict as four
 * buttons, then — once you have one — your vibes and a few words, your friends'
 * verdicts, and the reviews friends wrote.
 *
 * Everything goes through Mahfin's own /api/verdicts, keyed by TMDB id
 * (`movie:<id>` / `tv:<id>`), so a verdict given here is the one the web, the
 * phone and the "coming soon" page show. Who is named to whom is decided on
 * the server; this only draws what it is sent.
 */

// MARK: - Model

enum Verdict: String, Codable, CaseIterable {
    case perfection, go_for_it, timepass, skip

    var label: String {
        switch self {
        case .perfection: return "Perfection"
        case .go_for_it: return "Go for it"
        case .timepass: return "Timepass"
        case .skip: return "Skip it"
        }
    }

    var hint: String {
        switch self {
        case .perfection: return "Loved it. Watch it."
        case .go_for_it: return "Really good. Worth your time."
        case .timepass: return "Fine if nothing else is on."
        case .skip: return "Not worth it."
        }
    }

    /// `--t-verdict-*`: fixed across themes.
    var hex: String {
        switch self {
        case .perfection: return "#b07cff"
        case .go_for_it: return "#3fcf8e"
        case .timepass: return "#f2c14e"
        case .skip: return "#ef6b73"
        }
    }

    var color: NSColor { Glyphs.color(hex) }
}

enum Vibe: String, CaseIterable {
    case mind_bending, edge, feel_good, tearjerker, funny, slow_burn, thoughtful, comfort, dark, horror, epic

    var label: String {
        switch self {
        case .mind_bending: return "Twisty"
        case .edge: return "Thrilling"
        case .feel_good: return "Happy"
        case .tearjerker: return "Emotional"
        case .funny: return "Funny"
        case .slow_burn: return "Slow-paced"
        case .thoughtful: return "Thoughtful"
        case .comfort: return "Relaxing"
        case .dark: return "Dark"
        case .horror: return "Horror"
        case .epic: return "Epic"
        }
    }

    /// `/mood/<slug>`, the web's vibeHref.
    var href: String { "/mood/" + rawValue.replacingOccurrences(of: "_", with: "-") }

    /// VibeIcon.tsx's paths: 24 units, a 1.9 stroke.
    var paths: String {
        switch self {
        case .mind_bending: return #"<path d="M12 12a1 1 0 0 1 1 1 2 2 0 0 1-2 2 3 3 0 0 1-3-3 4 4 0 0 1 4-4 5 5 0 0 1 5 5 6 6 0 0 1-6 6"/>"#
        case .edge: return #"<path d="M2.5 12h4l2-5.5 3.5 11 2.5-7.5 1.5 2h5.5"/>"#
        case .feel_good: return #"<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>"#
        case .tearjerker: return #"<path d="M12 3.5c3 3.9 6 7.2 6 10.6a6 6 0 0 1-12 0c0-3.4 3-6.7 6-10.6z"/>"#
        case .funny: return #"<circle cx="12" cy="12" r="9"/><path d="M8 10c.5-.8 1.5-.8 2 0M14 10c.5-.8 1.5-.8 2 0"/><path d="M7.8 13.5h8.4a4.2 4.2 0 0 1-8.4 0z"/>"#
        case .slow_burn: return #"<path d="M12 2.8c.6 2.6 3.6 3.9 3.6 7.2a3.6 3.6 0 0 1-7.2 0c0-1.6.8-2.6 1.7-3.4 0 1.6.8 2.4 1.7 2.4 0-1.9-.7-3.6.2-6.2z"/><path d="M9.5 16.5h5v4.7h-5z"/>"#
        case .thoughtful: return #"<path d="M9.2 17.5h5.6M10.2 20.8h3.6"/><path d="M12 3a6 6 0 0 0-3.6 10.8c.6.5 1 1.2 1 2v.7h5.2v-.7c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/>"#
        case .comfort: return #"<path d="M4.5 9h11v5.5a4.5 4.5 0 0 1-4.5 4.5H9a4.5 4.5 0 0 1-4.5-4.5z"/><path d="M15.5 10.5h1.3a2.6 2.6 0 0 1 0 5.2h-1.6M8 3.5c-.6.8.6 1.6 0 2.5M11.5 3.5c-.6.8.6 1.6 0 2.5"/>"#
        case .dark: return #"<path d="M20 14.6A8.2 8.2 0 1 1 9.4 4a6.6 6.6 0 0 0 10.6 10.6z"/>"#
        case .horror: return #"<path d="M5.5 20.5V10.5a6.5 6.5 0 0 1 13 0v10l-2.2-1.6-2.1 1.6-2.2-1.6-2.1 1.6-2.2-1.6z"/><path d="M9.6 10.6h.01M14.4 10.6h.01" stroke-width="2.6"/>"#
        case .epic: return #"<path d="M2.5 20l6.5-11 4 6.2 2.3-3.4L21.5 20z"/><path d="M9 9V3.5l3.2 1.3L9 6.1"/>"#
        }
    }
}

struct MeterPerson: Codable {
    var id: String
    var alias: String
    var name: String?
    var avatarOf: String?
    var shown: String { name ?? alias }
}

struct MeterReview: Codable {
    var text: String
    var at: Double
    var likes: Int
    var liked: Bool
}

struct MeterFriend: Codable {
    var person: MeterPerson
    var verdict: Verdict
    var at: Double
    var vibes: [String]?
    var review: MeterReview?
}

struct MeterVibeCount: Codable {
    var vibe: String
    var count: Int
}

struct MeterData: Codable {
    var key: String
    var total: Int
    var counts: [String: Int]?
    var mine: Verdict?
    var friends: [MeterFriend]
    var vibes: [MeterVibeCount]?
    var myVibes: [String]?
    var myReview: MeterReview?
    var otherReviews: Int?

    func count(_ v: Verdict) -> Int { counts?[v.rawValue] ?? 0 }
}

private struct MetersResponse: Codable { var meters: [String: MeterData] }
private struct SeedResponse: Codable { var seed: [String] }

/// "3 days ago", as lib/ago.ts.
func agoText(_ ms: Double) -> String {
    let mins = Int(((Date().timeIntervalSince1970 * 1000 - ms) / 60_000).rounded())
    if mins < 1 { return "just now" }
    if mins < 60 { return "\(mins)m ago" }
    let hours = Int((Double(mins) / 60).rounded())
    if hours < 24 { return "\(hours)h ago" }
    let days = Int((Double(hours) / 24).rounded())
    return days == 1 ? "yesterday" : "\(days) days ago"
}

// MARK: - Drawn marks

/// The web's SVG marks, drawn by AppKit's own SVG reader at the size shown.
enum Glyphs {
    private static var cache: [String: CGImage] = [:]

    static func color(_ hex: String) -> NSColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Theme.rgb(v)
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }

    static func image(_ body: String, size: CGFloat, scale: CGFloat = 2) -> CGImage? {
        let px = Int((size * scale).rounded(.up))
        let key = "\(px)|\(body)"
        if let hit = cache[key] { return hit }
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(px)" height="\#(px)" viewBox="0 0 24 24">\#(body)</svg>"#
        guard let img = NSImage(data: Data(svg.utf8)) else { return nil }
        var r = CGRect(x: 0, y: 0, width: px, height: px)
        let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        cache[key] = cg
        return cg
    }

    /// VerdictGlyph: a heart for Perfection, then three faces, grin to frown,
    /// filled in the verdict's colour with the features cut in the page's ink.
    static func verdict(_ v: Verdict, size: CGFloat) -> CGImage? {
        let c = v.hex, ink = hex(Theme.palette.void)
        let face = { (mouth: String) in
            #"<circle cx="12" cy="12" r="10" fill="\#(c)"/><circle cx="8.6" cy="10" r="1.35" fill="\#(ink)"/><circle cx="15.4" cy="10" r="1.35" fill="\#(ink)"/>"# + mouth
        }
        let body: String
        switch v {
        case .perfection:
            body = #"<path d="M12 21s-8-4.9-9.9-9.6C.8 8.2 2.6 4.6 6 4.1c2-.3 4 .6 6 2.7 2-2.1 4-3 6-2.7 3.4.5 5.2 4.1 3.9 7.3C20 16.1 12 21 12 21z" fill="\#(c)"/><path d="M18.6 1.4l.65 1.5 1.5.65-1.5.65-.65 1.5-.65-1.5-1.5-.65 1.5-.65z" fill="\#(c)"/><path d="M7.4 8.2c.6-.9 1.6-1.4 2.6-1.2" stroke="\#(ink)" stroke-opacity="0.35" stroke-width="1.4" stroke-linecap="round" fill="none"/>"#
        case .go_for_it:
            body = face(#"<path d="M7.6 13.6c1 2.4 2.6 3.5 4.4 3.5s3.4-1.1 4.4-3.5" stroke="\#(ink)" stroke-width="1.8" stroke-linecap="round" fill="none"/>"#)
        case .timepass:
            body = face(#"<path d="M8.4 15.3h7.2" stroke="\#(ink)" stroke-width="1.8" stroke-linecap="round"/>"#)
        case .skip:
            body = face(#"<path d="M8 17c1-1.9 2.4-2.8 4-2.8s3 .9 4 2.8" stroke="\#(ink)" stroke-width="1.8" stroke-linecap="round" fill="none"/>"#)
        }
        return image(body, size: size)
    }

    static func vibe(_ v: Vibe, size: CGFloat, color: NSColor) -> CGImage? {
        image(#"<g fill="none" stroke="\#(hex(color))" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">\#(v.paths)</g>"#, size: size)
    }

    static func heart(size: CGFloat, color: NSColor, filled: Bool) -> CGImage? {
        let c = hex(color)
        return image(#"<path d="M12 20.5s-7.5-4.7-9.5-9C1.2 8.6 2.6 5.5 5.6 4.8c1.9-.4 3.9.4 5 2 .3.4.4.6 1.4.6s1.1-.2 1.4-.6c1.1-1.6 3.1-2.4 5-2 3 .7 4.4 3.8 3.1 6.7-2 4.3-9.5 9-9.5 9z" fill="\#(filled ? c : "none")" stroke="\#(c)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>"#, size: size)
    }
}

/// A drawn mark at a fixed size.
final class GlyphView: FlippedView {
    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func set(_ image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

/// A friend's picture, or — for anyone without one — the generated mark the
/// web gives strangers: two hues a third of the wheel apart, and initials.
final class AvatarView: FlippedView {
    private let gradient = CAGradientLayer()
    private let initials: NSTextField
    private let photo = RemoteImage()

    init(person: MeterPerson, size: CGFloat, server: URL) {
        initials = makeLabel(font: Theme.text((size * 0.36).rounded(), .bold), color: NSColor.white.withAlphaComponent(0.92))
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        var h = 0
        for u in person.alias.unicodeScalars { h = (h * 31 + Int(u.value)) % 360 }
        gradient.colors = [NSColor(hue: CGFloat(h) / 360, saturation: 0.58, brightness: 0.66, alpha: 1).cgColor,
                           NSColor(hue: CGFloat((h + 42) % 360) / 360, saturation: 0.54, brightness: 0.4, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = bounds
        layer?.addSublayer(gradient)
        let parts = person.alias.split(separator: " ")
        initials.stringValue = String(parts.first?.first ?? "?") + (parts.count > 1 ? String(parts[1].first!) : "")
        initials.alignment = .center
        addSubview(initials)
        let s = initials.fitSize
        initials.frame = NSRect(x: 0, y: (size - s.height) / 2, width: size, height: s.height)
        photo.layer.frame = bounds
        layer?.addSublayer(photo.layer)
        // AppKit draws subviews over loose layers, so the initials go once a
        // photo is in rather than relying on the photo to cover them.
        photo.onLoad = { [weak self] in self?.initials.isHidden = true }
        if let id = person.avatarOf {
            var c = URLComponents(url: server.appendingPathComponent("Users/\(id)/Images/Primary"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "maxWidth", value: String(Int(size * 2))), URLQueryItem(name: "quality", value: "90")]
            photo.load(c.url, points: size, scale: 2)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Motion helpers

private enum Motion {
    /// `.stagger-in`/`.rise-in`: up from 10 pt and in from nothing.
    static func riseIn(_ v: NSView, index: Int = 0, step: Double = 0.035, duration: Double = 0.42) {
        guard let l = v.layer else { return }
        let g = CAAnimationGroup()
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 10
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        g.animations = [rise, fade]
        g.duration = duration
        g.timingFunction = Theme.expoOut
        g.beginTime = CACurrentMediaTime() + step * Double(index)
        g.fillMode = .backwards
        l.add(g, forKey: "rise-in")
    }

    /// A transform about the view's centre (a layer-backed view's anchor is its corner).
    static func pulse(_ v: NSView, values: [CGFloat], times: [NSNumber], duration: Double, rotations: [CGFloat]? = nil) {
        guard let l = v.layer else { return }
        let b = v.bounds
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = values.enumerated().map { i, s in
            var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            t = CATransform3DScale(t, s, s, 1)
            if let r = rotations?[i] { t = CATransform3DRotate(t, r * .pi / 180, 0, 0, 1) }
            return NSValue(caTransform3D: CATransform3DTranslate(t, -b.midX, -b.midY, 0))
        }
        a.keyTimes = times
        a.duration = duration
        a.timingFunction = Theme.spring
        l.add(a, forKey: "pulse")
    }
}

// MARK: - Small controls

/// A view that is a button: hover and press, by the same tracker the cards use.
class Pressable: FlippedView {
    var action: (() -> Void)?
    var enabled = true
    private(set) var hovering = false
    private var tracking: NSTrackingArea?
    /// How far hover lifts it (`hover:-translate-y-0.5` is 2 pt).
    var hoverLift: CGFloat = 2
    var pressScale: CGFloat = 0.95

    func hoverChanged() {}

    private func place(dy: CGFloat, scale: CGFloat, duration: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Theme.standard)
        layer?.transform = PillButton.lift(bounds, dy: dy, scale: scale)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        Hover.enter(self, area: { [unowned self] in self.bounds },
                    begin: { [weak self] in
                        guard let self else { return }
                        self.hovering = true
                        self.place(dy: -self.hoverLift, scale: 1, duration: 0.15)
                        self.hoverChanged()
                    },
                    end: { [weak self] in
                        guard let self else { return }
                        self.hovering = false
                        self.place(dy: 0, scale: 1, duration: 0.15)
                        self.hoverChanged()
                    })
    }
    override func mouseExited(with event: NSEvent) { Hover.exit(self) }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        place(dy: 0, scale: pressScale, duration: 0.08)
    }
    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        place(dy: hovering ? -hoverLift : 0, scale: 1, duration: 0.15)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One of the four verdict buttons.
final class VerdictButton: Pressable {
    let verdict: Verdict
    private let glyph: GlyphView
    private let label: NSTextField
    private let ring = CALayer()
    var on = false { didSet { restyle() } }

    init(_ v: Verdict) {
        verdict = v
        glyph = GlyphView(size: 19)
        label = makeLabel(v.label, font: Theme.text(14, .semibold), color: Theme.palette.ink)
        super.init(frame: .zero)
        toolTip = v.hint
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        glyph.set(Glyphs.verdict(v, size: 19))
        addSubview(glyph)
        addSubview(label)
        ring.cornerRadius = 12
        ring.borderColor = v.color.cgColor
        ring.borderWidth = 0
        layer?.addSublayer(ring)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hoverChanged() { restyle() }

    private func restyle() {
        let p = Theme.palette
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        if on {
            layer?.backgroundColor = verdict.color.withAlphaComponent(hovering ? 0.24 : 0.18).cgColor
            layer?.borderColor = verdict.color.cgColor
            layer?.borderWidth = 1.5
            label.textColor = verdict.color
            glyph.layer?.opacity = 1
        } else {
            layer?.backgroundColor = (hovering ? NSColor.white.withAlphaComponent(0.1) : p.panel).cgColor
            layer?.borderColor = p.glassBorder.cgColor
            layer?.borderWidth = 1
            label.textColor = hovering ? p.ink : p.ink.withAlphaComponent(0.85)
            glyph.layer?.opacity = hovering ? 1 : 0.7
        }
        CATransaction.commit()
    }

    /// `.verdict-pick`: a springy beat, the mark spinning in, and a ring of
    /// the verdict's colour leaving the button.
    func celebrate() {
        Motion.pulse(self, values: [1, 1.07, 0.98, 1], times: [0, 0.35, 0.65, 1], duration: 0.42)
        Motion.pulse(glyph, values: [0.6, 1.4, 1], times: [0, 0.5, 1], duration: 0.52, rotations: [-12, 8, 0])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.borderWidth = 2
        ring.opacity = 0
        CATransaction.commit()
        let spread = CABasicAnimation(keyPath: "bounds")
        spread.fromValue = NSValue(rect: bounds)
        spread.toValue = NSValue(rect: bounds.insetBy(dx: -10, dy: -10))
        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = 12
        corner.toValue = 22
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [spread, corner, fade]
        g.duration = 0.62
        g.timingFunction = Theme.expoOut
        ring.add(g, forKey: "ring")
    }

    override func layout() {
        super.layout()
        let s = label.fitSize
        let w = 19 + 8 + s.width
        let x = max(8, (bounds.width - w) / 2)
        glyph.frame = NSRect(x: x, y: (bounds.height - 19) / 2, width: 19, height: 19)
        label.frame = NSRect(x: x + 27, y: (bounds.height - s.height) / 2, width: min(s.width, bounds.width - x - 27 - 6), height: s.height)
    }
}

/// A pill with a vibe's mark: a choice in the picker, or a link on the meter.
final class VibeChip: Pressable {
    let vibe: Vibe
    private let glyph: GlyphView
    private let label: NSTextField
    private let countLabel: NSTextField
    private let isLink: Bool
    private let height: CGFloat
    var on = false { didSet { restyle() } }

    init(_ v: Vibe, count: Int? = nil, link: Bool) {
        vibe = v
        isLink = link
        height = link ? 28 : 36
        let fontSize: CGFloat = link ? 12.5 : 13
        glyph = GlyphView(size: link ? 14 : 15)
        label = makeLabel(v.label, font: Theme.text(fontSize, .semibold), color: Theme.palette.ink)
        countLabel = makeLabel(count.map(String.init) ?? "", font: Theme.text(fontSize, .regular), color: Theme.palette.muted)
        super.init(frame: .zero)
        layer?.cornerRadius = height / 2
        layer?.borderWidth = 1
        addSubview(glyph)
        addSubview(label)
        addSubview(countLabel)
        countLabel.isHidden = count == nil
        if link { hoverLift = 0 }
        restyle()
        sizeToFit()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hoverChanged() { restyle() }

    private func restyle() {
        let p = Theme.palette
        let text: NSColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        if on {
            layer?.borderColor = p.accent.withAlphaComponent(0.6).cgColor
            layer?.backgroundColor = p.accent.withAlphaComponent(0.15).cgColor
            text = p.accent
        } else {
            layer?.borderColor = p.glassBorder.cgColor
            layer?.backgroundColor = (hovering ? NSColor.white.withAlphaComponent(0.05) : .clear).cgColor
            text = hovering ? p.ink : p.ink.withAlphaComponent(isLink ? 0.85 : 0.7)
        }
        CATransaction.commit()
        label.textColor = text
        glyph.set(Glyphs.vibe(vibe, size: isLink ? 14 : 15, color: text))
    }

    func pop() { Motion.pulse(glyph, values: [0.6, 1.4, 1], times: [0, 0.5, 1], duration: 0.52, rotations: [-12, 8, 0]) }

    func sizeToFit() {
        let g: CGFloat = isLink ? 14 : 15
        let pad: CGFloat = isLink ? 10 : 12
        let c = countLabel.isHidden ? 0 : countLabel.fitSize.width + 6
        setFrameSize(NSSize(width: ceil(pad * 2 + g + 6 + label.fitSize.width + c), height: height))
    }

    override func layout() {
        super.layout()
        let g: CGFloat = isLink ? 14 : 15
        let pad: CGFloat = isLink ? 10 : 12
        glyph.frame = NSRect(x: pad, y: (bounds.height - g) / 2, width: g, height: g)
        let s = label.fitSize
        label.frame = NSRect(x: pad + g + 6, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        let cs = countLabel.fitSize
        countLabel.frame = NSRect(x: label.frame.maxX + 6, y: (bounds.height - cs.height) / 2, width: cs.width, height: cs.height)
    }
}

/// One verdict, small: a tinted pill with the mark and the word.
final class VerdictBadge: FlippedView {
    private let glyph = GlyphView(size: 14)
    private let label: NSTextField

    init(_ v: Verdict) {
        label = makeLabel(v.label, font: Theme.text(12, .semibold), color: v.color)
        super.init(frame: .zero)
        toolTip = v.hint
        layer?.backgroundColor = v.color.withAlphaComponent(0.16).cgColor
        glyph.set(Glyphs.verdict(v, size: 14))
        addSubview(glyph)
        addSubview(label)
        let s = label.fitSize
        setFrameSize(NSSize(width: ceil(10 + 14 + 6 + s.width + 10), height: 22))
        layer?.cornerRadius = 11
        glyph.frame = NSRect(x: 10, y: 4, width: 14, height: 14)
        label.frame = NSRect(x: 30, y: (22 - s.height) / 2, width: s.width, height: s.height)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The half-circle split into the four verdicts, the leader's share counting
/// up in its middle.
final class GaugeView: FlippedView {
    private let track = CAShapeLayer()
    private var arcs: [CAShapeLayer] = []
    private let pct = makeLabel(font: Theme.display(24, .heavy), color: Theme.palette.ink)
    private let caption = makeLabel(font: Theme.text(12, .semibold), color: Theme.palette.muted)
    private var shown = 0
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        track.lineCap = .butt
        layer?.addSublayer(track)
        pct.alignment = .center
        caption.alignment = .center
        addSubview(pct)
        addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The arc in the view's own coordinates: the web's viewBox 0 0 120 66,
    /// `M 10 60 A 50 50 0 0 1 110 60`, over the top.
    private func arcPath() -> CGPath {
        let k = bounds.width / 120
        let p = CGMutablePath()
        // Flipped coordinates: y grows downward, so "over the top" is the
        // half from 180° to 360° measured clockwise on screen.
        p.addArc(center: CGPoint(x: 60 * k, y: 60 * k), radius: 50 * k, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        return p
    }

    func set(_ m: MeterData, animate: Bool) {
        arcs.forEach { $0.removeFromSuperlayer() }
        arcs = []
        let total = max(1, m.total)
        let shares = Verdict.allCases.map { Double(m.count($0)) / Double(total) * 100 }
        let drawn = Verdict.allCases.indices.filter { shares[$0] > 0 }
        let gap = drawn.count > 1 ? 1.2 : 0
        var start = 0.0
        var n = 0
        for (i, v) in Verdict.allCases.enumerated() {
            defer { start += shares[i] }
            guard shares[i] > 0 else { continue }
            let a = CAShapeLayer()
            a.fillColor = nil
            a.strokeColor = v.color.cgColor
            a.lineCap = .butt
            a.strokeStart = start / 100
            a.strokeEnd = max(start, start + shares[i] - gap) / 100
            layer?.addSublayer(a)
            arcs.append(a)
            if animate {
                let d = CABasicAnimation(keyPath: "strokeEnd")
                d.fromValue = a.strokeStart
                d.toValue = a.strokeEnd
                d.duration = 0.9
                d.timingFunction = Theme.expoOut
                d.beginTime = CACurrentMediaTime() + 0.12 * Double(n)
                d.fillMode = .backwards
                a.add(d, forKey: "draw")
            }
            n += 1
        }
        let top = Verdict.allCases.max { m.count($0) < m.count($1) } ?? .perfection
        let target = Int((Double(m.count(top)) / Double(total) * 100).rounded())
        pct.textColor = top.color
        caption.stringValue = top.label
        countUp(to: target, animate: animate)
        needsLayout = true
    }

    /// useCountUp: eased out over 0.8 s, from wherever it was.
    private func countUp(to target: Int, animate: Bool) {
        timer?.invalidate()
        let from = shown
        guard animate, from != target else { shown = target; pct.stringValue = "\(target)%"; return }
        let start = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let p = min(1, (CACurrentMediaTime() - start) / 0.8)
                self.shown = Int((Double(from) + Double(target - from) * (1 - pow(1 - p, 3))).rounded())
                self.pct.stringValue = "\(self.shown)%"
                if p >= 1 { t.invalidate() }
            }
        }
    }

    override func layout() {
        super.layout()
        let k = bounds.width / 120
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let path = arcPath()
        for l in [track] + arcs {
            l.frame = bounds
            l.path = path
            l.lineWidth = 9 * k
        }
        CATransaction.commit()
        let cs = caption.fitSize, ps = pct.fitSize
        caption.frame = NSRect(x: 0, y: bounds.height - cs.height, width: bounds.width, height: cs.height)
        pct.frame = NSRect(x: 0, y: caption.frame.minY - ps.height + 2, width: bounds.width, height: ps.height)
    }
}

// MARK: - The meter

@MainActor
final class MeterView: FlippedView, NSTextViewDelegate {
    static let minVotes = 3
    static let maxVibes = 2
    static let maxReview = 280

    private let ctx: NativeContext
    private(set) var key: String?
    private var title: String = ""
    private var year: Int?
    private var meter: MeterData?
    private var seed: [Vibe] = []
    private var loaded = false
    private var drawnOnce = false

    private let heading = makeLabel("Mahfin Meter", font: Theme.display(20, .semibold), color: Theme.palette.ink)
    private let people = makeLabel(font: Theme.text(14), color: Theme.palette.muted)
    private let card = FlippedView()
    private let left = FlippedView()
    private let right = FlippedView()
    private let gauge = GaugeView()
    private var bars: [FlippedView] = []
    private let waiting = FlippedView()
    private let waitingText = makeLabel(font: Theme.text(15), color: Theme.palette.muted, lines: 0)
    private var waitingBars: [CALayer] = []
    private let vibesHeading = makeLabel(font: Theme.text(14, .semibold), color: Theme.palette.muted)
    private var vibeLinks: [VibeChip] = []
    private let pickHeading = makeLabel(font: Theme.text(14, .semibold), color: Theme.palette.muted)
    private let buttons = Verdict.allCases.map { VerdictButton($0) }
    private let chooseHeading = makeLabel(font: Theme.text(14, .semibold), color: Theme.palette.muted)
    private let chips = Vibe.allCases.map { VibeChip($0, link: false) }
    private let reviewHeading = makeLabel(font: Theme.text(14, .semibold), color: Theme.palette.muted)
    private let reviewBox = FlippedView()
    private let reviewScroll = NSScrollView()
    private let reviewText = NSTextView()
    private let reviewPlaceholder = makeLabel("What made it work — or not?", font: Theme.text(14), color: Theme.palette.muted.withAlphaComponent(0.6))
    private let reviewCount = makeLabel(font: Theme.text(12), color: Theme.palette.muted)
    private let reviewRemove = PillButton("Remove", style: .text, height: 30, fontSize: 13)
    private let reviewPost = PillButton("Post", style: .accent, height: 30, fontSize: 13)
    private let reviewError = makeLabel(font: Theme.text(13), color: Theme.palette.alert, lines: 2)
    private var reviewDraft: String?
    private let friendsHeading = makeLabel("Your friends", font: Theme.text(14, .semibold), color: Theme.palette.muted)
    private var friendRows: [FlippedView] = []
    private let reviewsSection = FlippedView()
    private let reviewsHeading = makeLabel("Reviews", font: Theme.display(18, .semibold), color: Theme.palette.ink)
    private var reviewCards: [FlippedView] = []
    private let othersNote = makeLabel(font: Theme.text(13), color: Theme.palette.muted, lines: 0)
    /// Writes go one after another, so a vibe sent the instant a first verdict
    /// is tapped never reaches the server before the verdict it rides on.
    private var queue: Task<Void, Never>?
    private var busy = false
    var onHeight: (() -> Void)?

    init(ctx: NativeContext) {
        self.ctx = ctx
        super.init(frame: .zero)
        layer?.masksToBounds = false
        addSubview(heading)
        addSubview(people)
        people.alignment = .right
        // `.glass-dark`: the panel fill, a hairline, a soft drop.
        card.layer?.backgroundColor = Theme.palette.panel.cgColor
        card.layer?.borderColor = Theme.palette.glassBorder.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 17
        card.layer?.shadowOffset = CGSize(width: 0, height: -10)
        card.layer?.masksToBounds = false
        addSubview(card)
        card.addSubview(left)
        card.addSubview(right)
        left.addSubview(gauge)
        left.addSubview(waiting)
        waiting.addSubview(waitingText)
        for i in 0..<MeterView.minVotes {
            let b = CALayer()
            b.cornerRadius = 4
            waiting.layer?.addSublayer(b)
            waitingBars.append(b)
            _ = i
        }
        left.addSubview(vibesHeading)
        right.addSubview(pickHeading)
        for b in buttons {
            right.addSubview(b)
            b.action = { [weak self, weak b] in
                guard let self, let b else { return }
                self.tapped(b.verdict)
            }
        }
        right.addSubview(chooseHeading)
        for c in chips {
            right.addSubview(c)
            c.action = { [weak self, weak c] in
                guard let self, let c else { return }
                self.toggleVibe(c.vibe)
            }
        }
        chooseHeading.attributedStringValue = Self.twoTone("The vibe", " · up to \(MeterView.maxVibes)")
        reviewHeading.attributedStringValue = Self.twoTone("In a few words", " · friends can read it")
        right.addSubview(reviewHeading)
        reviewBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        reviewBox.layer?.borderColor = Theme.palette.glassBorder.cgColor
        reviewBox.layer?.borderWidth = 1
        reviewBox.layer?.cornerRadius = 12
        right.addSubview(reviewBox)
        reviewScroll.drawsBackground = false
        reviewScroll.hasVerticalScroller = false
        reviewScroll.borderType = .noBorder
        reviewText.drawsBackground = false
        reviewText.isRichText = false
        reviewText.font = Theme.text(14)
        reviewText.textColor = Theme.palette.ink
        reviewText.insertionPointColor = Theme.palette.accent
        reviewText.textContainerInset = NSSize(width: 10, height: 10)
        reviewText.isAutomaticQuoteSubstitutionEnabled = false
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.25
        reviewText.defaultParagraphStyle = para
        reviewText.typingAttributes = [.font: Theme.text(14), .foregroundColor: Theme.palette.ink, .paragraphStyle: para]
        reviewText.delegate = self
        reviewText.isVerticallyResizable = true
        reviewText.textContainer?.widthTracksTextView = true
        reviewScroll.documentView = reviewText
        reviewBox.addSubview(reviewScroll)
        reviewBox.addSubview(reviewPlaceholder)
        right.addSubview(reviewCount)
        right.addSubview(reviewRemove)
        right.addSubview(reviewPost)
        right.addSubview(reviewError)
        reviewPost.radius = 8
        reviewRemove.action = { [weak self] in self?.saveReview("") }
        reviewPost.action = { [weak self] in
            guard let self else { return }
            self.saveReview(self.reviewText.string)
        }
        right.addSubview(friendsHeading)
        addSubview(reviewsSection)
        reviewsSection.addSubview(reviewsHeading)
        reviewsSection.addSubview(othersNote)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func twoTone(_ a: String, _ b: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: a, attributes: [.font: Theme.text(14, .semibold), .foregroundColor: Theme.palette.muted])
        s.append(NSAttributedString(string: b, attributes: [.font: Theme.text(14), .foregroundColor: Theme.palette.muted]))
        return s
    }

    // MARK: Data

    /// keyForItem: a film or a show by its TMDB id; an episode has none of its own.
    static func key(for item: JFItem) -> String? {
        let tmdb = item.ProviderIds?["Tmdb"] ?? item.ProviderIds?["tmdb"]
        if item.Type == "Movie" { return tmdb.map { "movie:\($0)" } ?? "jf:\(item.Id)" }
        if item.isSeries { return tmdb.map { "tv:\($0)" } ?? "jf:\(item.Id)" }
        return nil
    }

    func show(for item: JFItem) {
        let k = MeterView.key(for: item)
        title = item.Name ?? ""
        year = item.ProductionYear
        if k != key {
            key = k
            meter = nil
            seed = []
            loaded = false
            drawnOnce = false
            reviewDraft = nil
        }
        isHidden = k == nil
        reload()
    }

    func reload() {
        guard let key else { return }
        let api = ctx.api
        Task { [weak self] in
            await api.load(MetersResponse.self, .mahfin, "/api/verdicts", ["keys": key]) { r in
                guard let self, self.key == key, !self.busy else { return }
                self.apply(r.meters[key])
            }
        }
    }

    private func apply(_ m: MeterData?) {
        let wasLoaded = loaded
        meter = m
        loaded = true
        if (m?.vibes ?? []).isEmpty, seed.isEmpty, let key, !key.hasPrefix("jf:") { loadSeed(key) }
        render(animate: !wasLoaded || !drawnOnce)
    }

    /// For dev builds' checks: draws `json` (a MeterView answer) as if the
    /// server had sent it. Nothing is written anywhere.
    func debugShow(_ json: String) {
        guard let m = try? JSONDecoder().decode(MeterData.self, from: Data(json.utf8)) else { print("[dev] meter json did not decode"); return }
        loaded = false
        drawnOnce = false
        apply(m)
    }

    private func loadSeed(_ key: String) {
        let api = ctx.api
        Task { [weak self] in
            guard let r = try? await api.fetch(SeedResponse.self, .mahfin, "/api/vibes/seed", ["key": key]) else { return }
            guard let self, self.key == key else { return }
            self.seed = r.seed.compactMap(Vibe.init(rawValue:))
            self.render(animate: false)
        }
    }

    /// One write, then the server's answer as the new state.
    private func post(_ body: [String: Any], route: String = "/api/verdicts", revert: MeterData?, then: ((Bool) -> Void)? = nil) {
        guard let key else { return }
        let previous = queue
        let api = ctx.api
        busy = true
        queue = Task { [weak self] in
            await previous?.value
            var json = body
            json["key"] = key
            do {
                let data = try await api.send(.mahfin, "POST", route, json: json)
                let r = try JSONDecoder().decode(MetersResponse.self, from: data)
                guard let self, self.key == key else { return }
                self.busy = false
                self.meter = r.meters[key] ?? self.meter
                self.render(animate: false)
                then?(true)
            } catch {
                guard let self, self.key == key else { return }
                self.busy = false
                if let revert { self.meter = revert }
                self.render(animate: false)
                then?(false)
            }
        }
    }

    private func tapped(_ v: Verdict) {
        guard let m = meter ?? emptyMeter() else { return }
        let next: Verdict? = m.mine == v ? nil : v
        // Withdrawing a verdict takes its review and vibes with it, for good.
        if next == nil, m.myReview != nil || !(m.myVibes ?? []).isEmpty {
            let a = NSAlert()
            a.messageText = "Clear your verdict?"
            a.informativeText = "Clearing your verdict also deletes your review and vibes."
            a.addButton(withTitle: "Clear it")
            a.addButton(withTitle: "Cancel")
            guard let window else { return }
            a.beginSheetModal(for: window) { [weak self] r in
                MainActor.assumeIsolated {
                    if r == .alertFirstButtonReturn { self?.setVerdict(nil, from: m) }
                }
            }
            return
        }
        setVerdict(next, from: m)
        if let next { buttons.first { $0.verdict == next }?.celebrate() }
    }

    private func setVerdict(_ v: Verdict?, from m: MeterData) {
        var guess = m
        guess.mine = v
        if v == nil { guess.myVibes = []; guess.myReview = nil }
        meter = guess
        render(animate: false)
        post(["verdict": v.map { $0.rawValue } ?? NSNull(), "title": title, "year": year.map { String($0) } ?? NSNull()], revert: m)
    }

    private func toggleVibe(_ v: Vibe) {
        guard let m = meter, m.mine != nil else { return }
        var list = (m.myVibes ?? []).compactMap(Vibe.init(rawValue:))
        if let i = list.firstIndex(of: v) { list.remove(at: i) } else {
            list.append(v)
            list = Array(list.suffix(MeterView.maxVibes))
            chips.first { $0.vibe == v }?.pop()
        }
        var guess = m
        guess.myVibes = list.map(\.rawValue)
        meter = guess
        render(animate: false)
        post(["vibes": list.map(\.rawValue)], revert: m)
    }

    private func saveReview(_ text: String) {
        guard meter?.mine != nil else { return }
        reviewPost.isEnabled = false
        reviewError.isHidden = true
        post(["review": String(text.prefix(MeterView.maxReview))], revert: nil) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.reviewDraft = nil
                self.window?.makeFirstResponder(nil)
            } else {
                self.reviewError.stringValue = "That didn't save. Try again in a moment."
                self.reviewError.isHidden = false
            }
            self.render(animate: false)
        }
    }

    private func like(_ author: String, on: Bool) {
        post(["author": author, "on": on], route: "/api/verdicts/like", revert: nil)
    }

    private func emptyMeter() -> MeterData? {
        guard let key else { return nil }
        return MeterData(key: key, total: 0, counts: nil, mine: nil, friends: [], vibes: nil, myVibes: [], myReview: nil, otherReviews: 0)
    }

    // MARK: Review editing

    func textDidChange(_ notification: Notification) {
        if reviewText.string.count > MeterView.maxReview {
            reviewText.string = String(reviewText.string.prefix(MeterView.maxReview))
        }
        reviewDraft = reviewText.string
        refreshReviewControls()
    }

    private func refreshReviewControls() {
        let saved = meter?.myReview?.text ?? ""
        let text = reviewDraft ?? saved
        let dirty = reviewDraft != nil && text.trimmingCharacters(in: .whitespacesAndNewlines) != saved
        reviewPlaceholder.isHidden = !text.isEmpty
        reviewCount.stringValue = "\(text.count)/\(MeterView.maxReview)"
        reviewPost.title = saved.isEmpty ? "Post" : "Update"
        reviewPost.isEnabled = dirty && !busy
        reviewRemove.isHidden = saved.isEmpty || dirty
        needsLayout = true
    }

    // MARK: Drawing

    private func render(animate: Bool) {
        guard key != nil else { return }
        let m = meter
        let total = m?.total ?? 0
        people.stringValue = total > 0 ? "\(total) \(total == 1 ? "person" : "people") here" : ""
        people.isHidden = total == 0

        // Left: the split, or what it is waiting for.
        let hasSplit = m?.counts != nil && total > 0
        gauge.isHidden = !hasSplit
        bars.forEach { $0.removeFromSuperview() }
        bars = []
        if let m, hasSplit {
            gauge.set(m, animate: animate)
            for (i, v) in Verdict.allCases.enumerated() {
                let row = barRow(v, count: m.count(v), total: total, index: i, animate: animate)
                left.addSubview(row)
                bars.append(row)
            }
        }
        waiting.isHidden = hasSplit || !loaded
        if !hasSplit {
            let short = max(0, MeterView.minVotes - total)
            waitingText.stringValue = total == 0
                ? "Nobody here has rated this yet. Be the first."
                : short > 0
                    ? "\(total) \(total == 1 ? "person has" : "people have") rated this. \(short) more and the split shows."
                    : "\(total) people have rated this. The split stays hidden until a few more do, so nobody's vote can be worked out."
            for (i, b) in waitingBars.enumerated() {
                b.backgroundColor = (i < min(total, MeterView.minVotes) ? Theme.palette.accent : NSColor.white.withAlphaComponent(0.1)).cgColor
            }
            if animate && loaded { Motion.riseIn(waiting, duration: 0.45) }
        }

        // The vibe line: the household's, or TMDB's until there is one.
        vibeLinks.forEach { $0.removeFromSuperview() }
        vibeLinks = []
        let household = (m?.vibes ?? []).compactMap { c in Vibe(rawValue: c.vibe).map { ($0, Optional(c.count)) } }
        let line: [(Vibe, Int?)] = household.isEmpty ? seed.map { ($0, nil) } : household
        vibesHeading.stringValue = household.isEmpty ? "TMDB calls it" : "The vibe here"
        vibesHeading.isHidden = line.isEmpty || !loaded
        for (i, (v, n)) in line.enumerated() where loaded {
            let chip = VibeChip(v, count: n, link: true)
            chip.action = { [weak self] in self?.ctx.open(v.href) }
            left.addSubview(chip)
            vibeLinks.append(chip)
            if animate { Motion.riseIn(chip, index: i) }
        }

        // Right: your verdict.
        let mine = m?.mine
        pickHeading.stringValue = mine == nil ? "What did you think?" : "Your verdict"
        for b in buttons {
            b.on = b.verdict == mine
            b.enabled = true
        }
        if animate && !drawnOnce { for (i, b) in buttons.enumerated() { Motion.riseIn(b, index: i) } }
        let hasMine = mine != nil
        let myVibes = Set((m?.myVibes ?? []).compactMap(Vibe.init(rawValue:)))
        for v in [chooseHeading, reviewHeading, reviewBox, reviewCount, reviewPost] as [NSView] { v.isHidden = !hasMine }
        for c in chips {
            c.isHidden = !hasMine
            c.on = myVibes.contains(c.vibe)
        }
        if hasMine, reviewDraft == nil {
            let saved = m?.myReview?.text ?? ""
            if reviewText.string != saved { reviewText.string = saved }
        }
        if !hasMine { reviewRemove.isHidden = true; reviewError.isHidden = true } else { refreshReviewControls() }
        if reviewError.stringValue.isEmpty { reviewError.isHidden = true }

        // Your friends.
        friendRows.forEach { $0.removeFromSuperview() }
        friendRows = []
        friendsHeading.isHidden = (m?.friends ?? []).isEmpty
        for f in m?.friends ?? [] {
            let row = friendRow(f)
            right.addSubview(row)
            friendRows.append(row)
        }

        // Reviews, under the card.
        reviewCards.forEach { $0.removeFromSuperview() }
        reviewCards = []
        if let m {
            var n = 0
            if let r = m.myReview, let v = m.mine {
                let c = reviewCard(name: "You", person: nil, verdict: v, review: r, mine: true)
                reviewsSection.addSubview(c)
                reviewCards.append(c)
                if animate { Motion.riseIn(c, index: n) }
                n += 1
            }
            for f in m.friends.filter({ $0.review != nil }).sorted(by: { $0.review!.at > $1.review!.at }) {
                let c = reviewCard(name: f.person.shown, person: f.person, verdict: f.verdict, review: f.review!, mine: false)
                reviewsSection.addSubview(c)
                reviewCards.append(c)
                if animate { Motion.riseIn(c, index: n) }
                n += 1
            }
            let others = m.otherReviews ?? 0
            othersNote.isHidden = others == 0
            othersNote.stringValue = "\(others) more \(others == 1 ? "review" : "reviews") from people here you're not friends with. Reviews are shared between friends only."
        }
        reviewsSection.isHidden = reviewCards.isEmpty && (m?.otherReviews ?? 0) == 0
        if loaded { drawnOnce = true }
        needsLayout = true
        onHeight?()
    }

    private func barRow(_ v: Verdict, count: Int, total: Int, index: Int, animate: Bool) -> FlippedView {
        let row = FlippedView()
        let g = GlyphView(size: 16)
        g.set(Glyphs.verdict(v, size: 16))
        let name = makeLabel(v.label, font: Theme.text(14), color: Theme.palette.ink.withAlphaComponent(0.85))
        let n = makeLabel(String(count), font: Theme.text(14), color: Theme.palette.muted)
        let pct = Int((Double(count) / Double(max(1, total)) * 100).rounded())
        let p = makeLabel("\(pct)%", font: Theme.text(14, .semibold), color: Theme.palette.ink)
        p.alignment = .right
        let track = CALayer()
        track.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        track.cornerRadius = 3
        track.masksToBounds = true
        let fill = CALayer()
        fill.backgroundColor = v.color.cgColor
        fill.cornerRadius = 3
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        for s in [g, name, n, p] as [NSView] { row.addSubview(s) }
        row.layer?.addSublayer(track)
        row.identifier = NSUserInterfaceItemIdentifier("bar:\(pct)")
        // Laid out by `layoutBar` once the row has a width.
        row.layer?.setValue(track, forKey: "track")
        row.layer?.setValue(fill, forKey: "fill")
        if animate {
            let a = CABasicAnimation(keyPath: "transform.scale.x")
            a.fromValue = 0
            a.toValue = 1
            a.duration = 0.7
            a.timingFunction = Theme.expoOut
            a.beginTime = CACurrentMediaTime() + 0.07 * Double(index)
            a.fillMode = .backwards
            fill.add(a, forKey: "grow")
        }
        return row
    }

    private func layoutBar(_ row: FlippedView, width: CGFloat) {
        let subs = row.subviews
        guard subs.count == 4, let g = subs[0] as? GlyphView, let name = subs[1] as? NSTextField,
              let n = subs[2] as? NSTextField, let p = subs[3] as? NSTextField,
              let track = row.layer?.value(forKey: "track") as? CALayer,
              let fill = row.layer?.value(forKey: "fill") as? CALayer else { return }
        let pct = CGFloat(Int(row.identifier?.rawValue.dropFirst(4) ?? "0") ?? 0)
        g.frame = NSRect(x: 0, y: 2, width: 16, height: 16)
        let ps = p.fitSize, ns = n.fitSize
        p.frame = NSRect(x: width - 40, y: 0, width: 40, height: ps.height)
        n.frame = NSRect(x: width - 40 - 10 - ns.width, y: 0, width: ns.width, height: ns.height)
        name.frame = NSRect(x: 26, y: 0, width: max(0, n.frame.minX - 36), height: name.fitSize.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: 24, width: width, height: 6)
        fill.bounds = CGRect(x: 0, y: 0, width: width * pct / 100, height: 6)
        fill.position = CGPoint(x: 0, y: 3)
        CATransaction.commit()
    }

    private func friendRow(_ f: MeterFriend) -> FlippedView {
        let row = FlippedView()
        let avatar = AvatarView(person: f.person, size: 28, server: ctx.api.session.server)
        let name = makeLabel(f.person.shown, font: Theme.text(14, .semibold), color: Theme.palette.ink)
        row.addSubview(avatar)
        row.addSubview(name)
        let vibes = (f.vibes ?? []).compactMap(Vibe.init(rawValue:))
        for v in vibes {
            let g = GlyphView(size: 14)
            g.set(Glyphs.vibe(v, size: 14, color: Theme.palette.muted))
            g.toolTip = vibes.map(\.label).joined(separator: ", ")
            row.addSubview(g)
        }
        row.addSubview(VerdictBadge(f.verdict))
        return row
    }

    private func layoutFriendRow(_ row: FlippedView, width: CGFloat) {
        guard let avatar = row.subviews.first as? AvatarView, let name = row.subviews.dropFirst().first as? NSTextField,
              let badge = row.subviews.last as? VerdictBadge else { return }
        avatar.frame.origin = .zero
        badge.frame.origin = NSPoint(x: width - badge.frame.width, y: 3)
        let ns = name.fitSize
        let icons = row.subviews.compactMap { $0 as? GlyphView }
        let room = badge.frame.minX - 40 - CGFloat(icons.count) * 18 - 8
        name.frame = NSRect(x: 40, y: (28 - ns.height) / 2, width: min(ns.width, max(0, room)), height: ns.height)
        var x = name.frame.maxX + 8
        for g in icons {
            g.frame = NSRect(x: x, y: 7, width: 14, height: 14)
            x += 18
        }
    }

    private func reviewCard(name: String, person: MeterPerson?, verdict: Verdict, review: MeterReview, mine: Bool) -> FlippedView {
        let c = FlippedView()
        c.layer?.backgroundColor = Theme.palette.panel.cgColor
        c.layer?.borderColor = Theme.palette.glassBorder.cgColor
        c.layer?.borderWidth = 1
        c.layer?.cornerRadius = 16
        c.layer?.cornerCurve = .continuous
        if let person { c.addSubview(AvatarView(person: person, size: 26, server: ctx.api.session.server)) }
        let who = makeLabel(name, font: Theme.text(14, .semibold), color: Theme.palette.ink)
        who.identifier = NSUserInterfaceItemIdentifier("who")
        c.addSubview(who)
        c.addSubview(VerdictBadge(verdict))
        let when = makeLabel(agoText(review.at), font: Theme.text(12), color: Theme.palette.muted)
        when.identifier = NSUserInterfaceItemIdentifier("when")
        c.addSubview(when)
        let body = makeLabel(review.text, font: Theme.text(14.5), color: Theme.palette.ink.withAlphaComponent(0.9), lines: 0)
        body.identifier = NSUserInterfaceItemIdentifier("body")
        c.addSubview(body)
        if mine {
            if review.likes > 0 {
                let likes = LikeButton(likes: review.likes, liked: true, passive: true)
                c.addSubview(likes)
            }
        } else if let person {
            let likes = LikeButton(likes: review.likes, liked: review.liked, passive: false)
            likes.action = { [weak self, weak likes] in
                guard let self, let likes else { return }
                likes.toggle()
                self.like(person.id, on: likes.liked)
            }
            c.addSubview(likes)
        }
        return c
    }

    private func layoutReviewCard(_ c: FlippedView, width: CGFloat) -> CGFloat {
        var x: CGFloat = 16
        if let a = c.subviews.first as? AvatarView {
            a.frame.origin = NSPoint(x: 16, y: 16)
            x = 16 + 26 + 10
        }
        guard let who = c.subviews.first(where: { $0.identifier?.rawValue == "who" }) as? NSTextField,
              let badge = c.subviews.first(where: { $0 is VerdictBadge }),
              let when = c.subviews.first(where: { $0.identifier?.rawValue == "when" }) as? NSTextField,
              let body = c.subviews.first(where: { $0.identifier?.rawValue == "body" }) as? NSTextField else { return 0 }
        let ws = when.fitSize
        when.frame = NSRect(x: width - 16 - ws.width, y: 16 + (26 - ws.height) / 2, width: ws.width, height: ws.height)
        let hs = who.fitSize
        let room = when.frame.minX - 10 - badge.frame.width - 10 - x
        who.frame = NSRect(x: x, y: 16 + (26 - hs.height) / 2, width: min(hs.width, max(0, room)), height: hs.height)
        badge.frame.origin = NSPoint(x: who.frame.maxX + 10, y: 16 + 2)
        let bs = body.sizeThatFits(NSSize(width: width - 32, height: 2000))
        body.frame = NSRect(x: 16, y: 16 + 26 + 8, width: width - 32, height: bs.height)
        var y = body.frame.maxY + 16
        if let likes = c.subviews.first(where: { $0 is LikeButton }) as? LikeButton {
            likes.sizeToFit()
            likes.frame.origin = NSPoint(x: 10, y: body.frame.maxY + 6)
            y = likes.frame.maxY + 10
        }
        return y
    }

    // MARK: Layout

    /// Lays everything out for `width` and returns the height it needs.
    @discardableResult
    func layoutContent(width: CGFloat) -> CGFloat {
        guard key != nil else { return 0 }
        let inset = RowView.inset
        let w = width - inset * 2
        let hs = heading.fitSize
        heading.frame = NSRect(x: inset, y: 0, width: hs.width, height: hs.height)
        let ps = people.fitSize
        people.frame = NSRect(x: width - inset - ps.width, y: hs.height - ps.height - 2, width: ps.width, height: ps.height)
        let cardTop = hs.height + 16
        let pad: CGFloat = 24
        let inner = w - pad * 2
        let twoColumns = inner >= 560
        let leftW = twoColumns ? ((inner - 24) / 2.2).rounded() : inner
        let rightW = twoColumns ? inner - 24 - leftW : inner

        let leftH = layoutLeft(width: leftW)
        let rightH = layoutRight(width: rightW)
        let rowH: CGFloat
        if twoColumns {
            rowH = max(leftH, rightH)
            left.frame = NSRect(x: pad, y: pad + (rowH - leftH) / 2, width: leftW, height: leftH)
            right.frame = NSRect(x: pad + leftW + 24, y: pad, width: rightW, height: rightH)
        } else {
            rowH = leftH + 24 + rightH
            left.frame = NSRect(x: pad, y: pad, width: leftW, height: leftH)
            right.frame = NSRect(x: pad, y: pad + leftH + 24, width: rightW, height: rightH)
        }
        card.frame = NSRect(x: inset, y: cardTop, width: w, height: rowH + pad * 2)
        card.layer?.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        var bottom = card.frame.maxY
        if !reviewsSection.isHidden {
            let rh = layoutReviews(width: w)
            reviewsSection.frame = NSRect(x: inset, y: bottom + 32, width: w, height: rh)
            bottom = reviewsSection.frame.maxY
        }
        return bottom
    }

    private func layoutLeft(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        if !gauge.isHidden {
            let gw = min(260, width)
            gauge.frame = NSRect(x: (width - gw) / 2, y: 0, width: gw, height: (gw * 66 / 120).rounded())
            y = gauge.frame.maxY + 16
            for row in bars {
                row.frame = NSRect(x: 0, y: y, width: width, height: 30)
                layoutBar(row, width: width)
                y += 30 + 8
            }
            y -= 8
        }
        if !waiting.isHidden {
            let ts = waitingText.sizeThatFits(NSSize(width: width, height: 400))
            let gap: CGFloat = 6
            let bw = (width - gap * CGFloat(MeterView.minVotes - 1)) / CGFloat(MeterView.minVotes)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (i, b) in waitingBars.enumerated() { b.frame = CGRect(x: CGFloat(i) * (bw + gap), y: 0, width: bw, height: 8) }
            CATransaction.commit()
            waitingText.frame = NSRect(x: 0, y: 8 + 12, width: width, height: ts.height)
            waiting.frame = NSRect(x: 0, y: y, width: width, height: waitingText.frame.maxY)
            y = waiting.frame.maxY
        } else if gauge.isHidden && !loaded {
            y = 96   // the skeleton's height while the first answer is out
        }
        if !vibesHeading.isHidden {
            y += 20
            let s = vibesHeading.fitSize
            vibesHeading.frame = NSRect(x: 0, y: y, width: width, height: s.height)
            y += s.height + 8
            y = flow(vibeLinks, from: y, width: width, gap: 6)
        }
        return y
    }

    private func layoutRight(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let ph = pickHeading.fitSize
        pickHeading.frame = NSRect(x: 0, y: 0, width: width, height: ph.height)
        y = ph.height + 8
        // Four across once the picker is 34rem (544 pt) wide, else two by two.
        let across = width >= 544 ? 4 : 2
        let bw = (width - CGFloat(across - 1) * 8) / CGFloat(across)
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: CGFloat(i % across) * (bw + 8), y: y + CGFloat(i / across) * 52, width: bw, height: 44)
        }
        y += CGFloat((buttons.count + across - 1) / across) * 52 - 8
        if !chooseHeading.isHidden {
            y += 16
            let s = chooseHeading.fitSize
            chooseHeading.frame = NSRect(x: 0, y: y, width: width, height: s.height)
            y += s.height + 8
            y = flow(chips, from: y, width: width, gap: 6)
            y += 16
            let rs = reviewHeading.fitSize
            reviewHeading.frame = NSRect(x: 0, y: y, width: width, height: rs.height)
            y += rs.height + 8
            reviewBox.frame = NSRect(x: 0, y: y, width: width, height: 88)
            reviewScroll.frame = reviewBox.bounds.insetBy(dx: 1, dy: 1)
            reviewText.frame.size.width = reviewScroll.contentSize.width
            let pls = reviewPlaceholder.fitSize
            reviewPlaceholder.frame = NSRect(x: 16, y: 11, width: width - 32, height: pls.height)
            y = reviewBox.frame.maxY + 8
            reviewPost.sizeToFit()
            reviewPost.frame.origin = NSPoint(x: width - reviewPost.frame.width, y: y)
            reviewRemove.sizeToFit()
            reviewRemove.frame.origin = NSPoint(x: reviewPost.frame.minX - 12 - reviewRemove.frame.width, y: y)
            let cs = reviewCount.fitSize
            reviewCount.frame = NSRect(x: 0, y: y + (30 - cs.height) / 2, width: cs.width, height: cs.height)
            y += 30
            if !reviewError.isHidden {
                let es = reviewError.sizeThatFits(NSSize(width: width, height: 100))
                reviewError.frame = NSRect(x: 0, y: y + 8, width: width, height: es.height)
                y = reviewError.frame.maxY
            }
        }
        if !friendsHeading.isHidden {
            y += 20
            let s = friendsHeading.fitSize
            friendsHeading.frame = NSRect(x: 0, y: y, width: width, height: s.height)
            y += s.height + 8
            for row in friendRows {
                row.frame = NSRect(x: 0, y: y, width: width, height: 28)
                layoutFriendRow(row, width: width)
                y += 28 + 8
            }
            y -= 8
        }
        return y
    }

    private func layoutReviews(width: CGFloat) -> CGFloat {
        let hs = reviewsHeading.fitSize
        reviewsHeading.frame = NSRect(x: 0, y: 0, width: width, height: hs.height)
        var y = hs.height + 12
        for c in reviewCards {
            let h = layoutReviewCard(c, width: width)
            c.frame = NSRect(x: 0, y: y, width: width, height: h)
            y += h + 12
        }
        if !othersNote.isHidden {
            let s = othersNote.sizeThatFits(NSSize(width: width, height: 200))
            othersNote.frame = NSRect(x: 0, y: y, width: width, height: s.height)
            y += s.height
        } else {
            y -= 12
        }
        return y
    }

    /// Wraps pills left to right.
    private func flow(_ views: [NSView], from top: CGFloat, width: CGFloat, gap: CGFloat) -> CGFloat {
        var x: CGFloat = 0, y = top, rowH: CGFloat = 0
        for v in views where !v.isHidden {
            let s = v.frame.size
            if x > 0 && x + s.width > width { x = 0; y += rowH + gap; rowH = 0 }
            v.frame.origin = NSPoint(x: x, y: y)
            x += s.width + gap
            rowH = max(rowH, s.height)
        }
        return y + rowH
    }

    func height(for width: CGFloat) -> CGFloat { isHidden ? 0 : layoutContent(width: width) }

    override func layout() {
        super.layout()
        layoutContent(width: bounds.width)
    }
}

/// A heart and a count: liking a friend's review (or, on your own, how many did).
final class LikeButton: Pressable {
    private let heart = GlyphView(size: 13)
    private let label = makeLabel(font: Theme.text(12.5, .semibold), color: Theme.palette.muted)
    private(set) var liked: Bool
    private var likes: Int
    private let passive: Bool

    init(likes: Int, liked: Bool, passive: Bool) {
        self.likes = likes
        self.liked = liked
        self.passive = passive
        super.init(frame: .zero)
        hoverLift = 0
        layer?.cornerRadius = 13
        enabled = !passive
        addSubview(heart)
        addSubview(label)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func toggle() {
        liked.toggle()
        likes = max(0, likes + (liked ? 1 : -1))
        restyle()
        if liked { Motion.pulse(heart, values: [1, 1.45, 0.9, 1], times: [0, 0.3, 0.6, 1], duration: 0.48) }
    }

    override func hoverChanged() { restyle() }

    private func restyle() {
        let p = Theme.palette
        let color: NSColor = passive ? p.muted : (liked ? p.alert : (hovering ? p.ink : p.muted))
        heart.set(Glyphs.heart(size: 13, color: passive ? p.alert : color, filled: liked || passive))
        label.textColor = color
        label.stringValue = passive
            ? "\(likes) \(likes == 1 ? "friend likes" : "friends like") this"
            : (likes > 0 ? "\(likes)" : "Like")
        layer?.backgroundColor = (hovering && !passive ? NSColor.white.withAlphaComponent(0.05) : .clear).cgColor
        sizeToFit()
        needsLayout = true
    }

    func sizeToFit() {
        setFrameSize(NSSize(width: ceil(10 + 13 + 6 + label.fitSize.width + 10), height: 26))
    }

    override func layout() {
        super.layout()
        heart.frame = NSRect(x: 10, y: 6.5, width: 13, height: 13)
        let s = label.fitSize
        label.frame = NSRect(x: 29, y: (26 - s.height) / 2, width: s.width, height: s.height)
    }
}

/// One friend's verdict on a card's title.
struct FriendOnCard: Codable {
    var person: MeterPerson
    var verdict: Verdict
    var at: Double
}

/// FriendsOnCard: up to two friends' faces and the newest one's verdict, on a
/// solid backing over a card's poster (a blur per card would be a compositor
/// layer per card while the row scrolls).
final class FriendsBadgeLayer: CALayer {
    private var faces: [CALayer] = []
    private var photos: [RemoteImage] = []
    private let more = CATextLayer()
    private let mark = CALayer()
    private var shownKey = ""

    override init() {
        super.init()
        backgroundColor = Theme.palette.void.withAlphaComponent(0.8).cgColor
        masksToBounds = false
        more.fontSize = 10
        more.font = Theme.text(10, .semibold)
        more.foregroundColor = Theme.palette.ink.withAlphaComponent(0.8).cgColor
        more.contentsScale = 2
        more.alignmentMode = .center
        mark.contentsGravity = .resizeAspect
        addSublayer(more)
        addSublayer(mark)
        isHidden = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `friends` (newest first) with its corner at `origin`, or its
    /// right edge at `origin.x` when `fromRight`.
    func set(_ friends: [FriendOnCard]?, server: URL, origin: CGPoint, fromRight: Bool) {
        guard let friends, !friends.isEmpty else { isHidden = true; shownKey = ""; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let shown = Array(friends.prefix(2))
        let key = shown.map(\.person.id).joined() + friends[0].verdict.rawValue + "\(friends.count)"
        if key != shownKey {
            faces.forEach { $0.removeFromSuperlayer() }
            faces = []
            photos = []
            for (i, f) in shown.enumerated() {
                let face = CALayer()
                face.frame = CGRect(x: 2 + CGFloat(i) * 12, y: 2, width: 18, height: 18)
                face.cornerRadius = 9
                face.masksToBounds = true
                face.borderColor = Theme.palette.void.cgColor
                face.borderWidth = 1
                var h = 0
                for u in f.person.alias.unicodeScalars { h = (h * 31 + Int(u.value)) % 360 }
                let g = CAGradientLayer()
                g.colors = [NSColor(hue: CGFloat(h) / 360, saturation: 0.58, brightness: 0.66, alpha: 1).cgColor,
                            NSColor(hue: CGFloat((h + 42) % 360) / 360, saturation: 0.54, brightness: 0.4, alpha: 1).cgColor]
                g.startPoint = .zero
                g.endPoint = CGPoint(x: 1, y: 1)
                g.frame = face.bounds
                face.addSublayer(g)
                let parts = f.person.alias.split(separator: " ")
                let t = CATextLayer()
                t.string = String(parts.first?.first ?? "?") + (parts.count > 1 ? String(parts[1].first!) : "")
                t.fontSize = 7
                t.font = Theme.text(7, .bold)
                t.alignmentMode = .center
                t.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
                t.contentsScale = 2
                t.frame = CGRect(x: 0, y: 4.5, width: 18, height: 10)
                face.addSublayer(t)
                if let id = f.person.avatarOf {
                    let photo = RemoteImage()
                    photo.layer.frame = face.bounds
                    face.addSublayer(photo.layer)
                    var c = URLComponents(url: server.appendingPathComponent("Users/\(id)/Images/Primary"), resolvingAgainstBaseURL: false)!
                    c.queryItems = [URLQueryItem(name: "maxWidth", value: "36"), URLQueryItem(name: "quality", value: "90")]
                    photo.load(c.url, points: 18, scale: 2)
                    photos.append(photo)
                }
                // Later faces tuck under the first, as `-ml-1.5` does.
                insertSublayer(face, at: 0)
                faces.append(face)
            }
            mark.contents = Glyphs.verdict(friends[0].verdict, size: 14)
            let extra = friends.count - shown.count
            more.string = extra > 0 ? "+\(extra)" : ""
            more.isHidden = extra <= 0
            if isHidden || shownKey.isEmpty {
                // `.pop-in`.
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0
                a.toValue = 1
                a.duration = 0.2
                add(a, forKey: "pop-in")
            }
            shownKey = key
        }
        var x = 2 + 18 + CGFloat(shown.count - 1) * 12 + 4
        if !more.isHidden {
            more.frame = CGRect(x: x, y: 5.5, width: 16, height: 12)
            x += 16 + 2
        }
        mark.frame = CGRect(x: x, y: 4, width: 14, height: 14)
        let w = x + 14 + 6
        frame = CGRect(x: fromRight ? origin.x - w : origin.x, y: origin.y, width: w, height: 22)
        cornerRadius = 11
        isHidden = false
        CATransaction.commit()
    }
}
