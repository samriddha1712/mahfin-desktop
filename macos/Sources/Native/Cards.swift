import AppKit
import QuartzCore

/*
 * The cards, matching Mahfin's Cards.tsx / DiscoverCard.tsx at the desktop
 * breakpoint: posters 184 wide (2:3), wide cards 292 (16:9), a 13 px title and
 * an 11.5 px meta line under each.
 *
 * The picture and everything drawn on it live in one Core Animation tree
 * (`tile`), centred on its own anchor, so the hover lift — up 7 pt, 3.5%
 * larger, a shadow and an accent ring, the same as the web — is a GPU
 * transform and nothing is redrawn while it runs.
 */

/// Puts a remote image into a layer, decoded to size off the main thread.
final class RemoteImage {
    let layer = CALayer()
    private var task: Task<Void, Never>?
    private(set) var url: URL?
    /// Called once the picture is in, for layouts that size to it.
    var onLoad: (() -> Void)?

    init() {
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
    }

    func load(_ url: URL?, points: CGFloat, scale: CGFloat) {
        guard url != self.url else { return }
        self.url = url
        task?.cancel()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = nil
        layer.opacity = 0
        CATransaction.commit()
        guard let url else { return }
        let pixels = Int((points * min(2, scale)).rounded(.up))
        if let hit = ImagePipeline.shared.cached(url, pixels: pixels) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.contents = hit
            layer.opacity = 1
            CATransaction.commit()
            onLoad?()
            return
        }
        task = Task { @MainActor [weak self] in
            let image = await ImagePipeline.shared.image(url, pixels: pixels)
            guard !Task.isCancelled, let image, let self, self.url == url else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            self.layer.contents = image
            self.layer.opacity = 1
            CATransaction.commit()
            self.onLoad?()
        }
    }
}

/// Shared shape of every card: a tile (the picture and its overlays) and a
/// caption under it, as Cards.tsx's `.tile`.
///
/// Hover (globals.css): the tile rises 7 pt and grows 3.5% on expo-out over
/// 420 ms, with a dark shadow (0 20 42 −14 at 0.72), a 1 pt accent ring (0.42)
/// and an accent glow under it (0 14 40 −16 at 0.5); a sheen of light crosses
/// it once (820 ms); the veil fades in (240 ms) and the play mark springs from
/// 82% (320 ms). Press: up 2 pt at 97.5%, 110 ms.
class CardCell: FlippedView {
    let tile = CALayer()
    private let glow = CALayer()
    let placeholder = CAGradientLayer()
    let picture = RemoteImage()
    let veil = ShadeLayer()
    let playMark = CAShapeLayer()
    private let sheenClip = CALayer()
    private let sheen = CAGradientLayer()
    /// The inset hairline every card carries (`ring-1 ring-inset ring-white/10`).
    private let ring = CALayer()
    let title = makeLabel(font: Theme.text(13, .medium), color: Theme.palette.ink.withAlphaComponent(0.9))
    let meta = makeLabel(font: Theme.text(11.5), color: Theme.palette.muted)
    var onOpen: (() -> Void)?
    /// Where a click on the picture goes, if not `onOpen` (the wide card plays).
    var onPicture: (() -> Void)?
    private var tracking: NSTrackingArea?
    private(set) var hovering = false
    var tileHeight: CGFloat = 0
    /// Library cards carry the veil and play mark; discover cards do not.
    var showsVeil = true
    /// The veil's play glyph size (17 on posters, 18 on wide cards).
    var playGlyph: CGFloat = 17
    var cornerRadius: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = false
        let p = Theme.palette
        tile.masksToBounds = false
        tile.shadowColor = NSColor.black.cgColor
        tile.shadowOpacity = 0
        tile.shadowRadius = 21
        tile.shadowOffset = CGSize(width: 0, height: -20)
        tile.borderColor = p.accent.withAlphaComponent(0.42).cgColor
        tile.borderWidth = 0
        glow.shadowColor = p.accent.cgColor
        glow.shadowOpacity = 0
        glow.shadowRadius = 20
        glow.shadowOffset = CGSize(width: 0, height: -14)
        placeholder.colors = [p.placeholderFrom.cgColor, p.placeholderTo.cgColor]
        placeholder.startPoint = CGPoint(x: 0, y: 0)
        placeholder.endPoint = CGPoint(x: 1, y: 1)
        placeholder.masksToBounds = true
        veil.set([.clear, p.void.withAlphaComponent(0.25), p.void.withAlphaComponent(0.85)])
        veil.opacity = 0
        veil.masksToBounds = true
        playMark.fillColor = NSColor.white.withAlphaComponent(0.15).cgColor
        playMark.strokeColor = p.glassBorder.cgColor
        playMark.lineWidth = 1
        playMark.opacity = 0
        sheenClip.masksToBounds = true
        sheen.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.24).cgColor, NSColor.clear.cgColor]
        sheen.locations = [0.4, 0.5, 0.6]
        // 104deg: left to right, tipped a little.
        sheen.startPoint = CGPoint(x: 0, y: 0.38)
        sheen.endPoint = CGPoint(x: 1, y: 0.62)
        sheen.opacity = 0
        sheenClip.addSublayer(sheen)
        ring.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        ring.borderWidth = 1
        for l in [glow, placeholder, picture.layer, veil, playMark, sheenClip, ring] { tile.addSublayer(l) }
        layer?.addSublayer(tile)
        addSubview(title)
        addSubview(meta)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lays the tile out at `tileHeight` and the caption under it.
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r = CGRect(x: 0, y: 0, width: bounds.width, height: tileHeight)
        let b = CGRect(origin: .zero, size: r.size)
        tile.bounds = b
        tile.position = CGPoint(x: r.midX, y: r.midY)
        tile.cornerRadius = cornerRadius
        // The dark shadow's −14 spread, as a smaller shape.
        tile.shadowPath = CGPath(roundedRect: b.insetBy(dx: 14, dy: 14), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        glow.frame = b
        glow.shadowPath = CGPath(roundedRect: b.insetBy(dx: 16, dy: 16), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        for l in [placeholder, picture.layer, veil, sheenClip, ring] as [CALayer] {
            l.frame = b
            l.cornerRadius = cornerRadius
            l.cornerCurve = .continuous
        }
        sheen.frame = b
        let d: CGFloat = 44
        playMark.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        playMark.position = CGPoint(x: r.midX, y: r.midY)
        let circle = CGMutablePath()
        circle.addEllipse(in: CGRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1))
        let g = playGlyph
        circle.addPath(PillButton.path(.play, g), transform: CGAffineTransform(translationX: (d - g) / 2 + 1, y: (d - g) / 2))
        playMark.path = circle
        CATransaction.commit()
        title.frame = NSRect(x: 0, y: tileHeight + 8, width: bounds.width, height: 18)
        meta.frame = NSRect(x: 0, y: tileHeight + 27, width: bounds.width, height: 16)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: bounds.width, height: tileHeight),
                               options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func lifted(_ on: Bool) -> CATransform3D {
        var t = CATransform3DMakeTranslation(0, on ? -7 : 0, 0)
        t = CATransform3DScale(t, on ? 1.035 : 1, on ? 1.035 : 1, 1)
        return t
    }

    func setHover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.42)
        CATransaction.setAnimationTimingFunction(Theme.expoOut)
        tile.transform = lifted(on)
        tile.shadowOpacity = on ? 0.72 : 0
        glow.shadowOpacity = on ? 0.5 : 0
        tile.borderWidth = on ? 1 : 0
        CATransaction.commit()
        if showsVeil {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.24)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            veil.opacity = on ? 1 : 0
            playMark.opacity = on ? 1 : 0
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.32)
            CATransaction.setAnimationTimingFunction(Theme.spring)
            playMark.transform = on ? CATransform3DIdentity : CATransform3DMakeScale(0.82, 0.82, 1)
            CATransaction.commit()
        }
        if on { runSheen() }
    }

    /// One pass of light across the picture, on approach (`tile-sheen`).
    private func runSheen() {
        let w = tile.bounds.width
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = -1.15 * w
        move.toValue = 1.15 * w
        move.timingFunction = Theme.expoOut
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.38, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.82
        sheen.add(group, forKey: "sheen")
    }

    /// A reused cell must not keep the last card's hover.
    func resetForReuse() {
        hovering = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        setHover(false)
        playMark.transform = CATransform3DMakeScale(0.82, 0.82, 1)
        sheen.removeAllAnimations()
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: tileHeight + 44), cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.11)
        tile.transform = CATransform3DScale(CATransform3DMakeTranslation(0, -2, 0), 0.975, 0.975, 1)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovering = !hovering
        setHover(bounds.contains(p))
        guard bounds.contains(p) else { return }
        if p.y <= tileHeight, let onPicture { onPicture() } else { onOpen?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
}

// MARK: - Poster (library title)

final class PosterCell: CardCell {
    static let width: CGFloat = 184
    static var size: NSSize { NSSize(width: width, height: width * 1.5 + 46) }
    private let badge = CATextLayer()
    private let badgeBG = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        tileHeight = PosterCell.width * 1.5
        badgeBG.backgroundColor = Theme.palette.accent.cgColor
        badge.font = Theme.text(11, .bold)
        badge.fontSize = 11
        badge.foregroundColor = Theme.palette.accentInk.cgColor
        badge.alignmentMode = .center
        badge.contentsScale = 2
        badgeBG.addSublayer(badge)
        tile.insertSublayer(badgeBG, below: tile.sublayers?.last(where: { $0.masksToBounds && $0.sublayers?.count == 1 }))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: JFItem, art: Artwork) {
        resetForReuse()
        tileHeight = bounds.width * 1.5
        picture.load(art.poster(item, width: Int(bounds.width * 2)), points: bounds.width * 1.5, scale: backingScale)
        title.stringValue = item.Name ?? ""
        meta.stringValue = CardText.meta(item)
        // A ✓ in a 20 pt accent circle when watched; the unwatched count as a pill.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if item.UserData?.Played == true {
            badge.string = "✓"
            badgeBG.isHidden = false
            badgeBG.frame = CGRect(x: bounds.width - 28, y: 8, width: 20, height: 20)
            badgeBG.cornerRadius = 10
        } else if let n = item.UserData?.UnplayedItemCount, n > 0, item.isSeries {
            badge.string = "\(n)"
            badgeBG.isHidden = false
            let w = CGFloat("\(n)".count) * 7 + 12
            badgeBG.frame = CGRect(x: bounds.width - w - 8, y: 8, width: w, height: 19)
            badgeBG.cornerRadius = 9.5
        } else {
            badgeBG.isHidden = true
        }
        badge.frame = CGRect(x: 0, y: (badgeBG.bounds.height - 14) / 2, width: badgeBG.bounds.width, height: 14)
        CATransaction.commit()
        needsLayout = true
    }
}

// MARK: - Wide (continue watching, next up)

final class WideCell: CardCell {
    static let width: CGFloat = 292
    static var size: NSSize { NSSize(width: width, height: width * 9 / 16 + 46) }
    private let track = CALayer()
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        tileHeight = WideCell.width * 9 / 16
        playGlyph = 18
        // The wide card's veil is an even 40% of the page colour.
        veil.set([Theme.palette.void.withAlphaComponent(0.4), Theme.palette.void.withAlphaComponent(0.4)])
        track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.backgroundColor = Theme.palette.accent.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        // Above the sheen (z-index 4 on the web), inside the rounded clip.
        tile.addSublayer(track)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: JFItem, art: Artwork) {
        resetForReuse()
        tileHeight = bounds.width * 9 / 16
        picture.load(art.wide(item, width: Int(bounds.width * 2)), points: bounds.width, scale: backingScale)
        if item.isEpisode {
            title.stringValue = item.SeriesName ?? item.Name ?? ""
            meta.stringValue = "S\(item.ParentIndexNumber ?? 0):E\(item.IndexNumber ?? 0) · \(item.Name ?? "")"
        } else {
            title.stringValue = item.Name ?? ""
            meta.stringValue = CardText.timeLeft(item) ?? item.runtimeText ?? ""
        }
        meta.font = Theme.text(12)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let p = item.progress {
            track.isHidden = false
            track.frame = CGRect(x: 0, y: tileHeight - 3, width: bounds.width, height: 3)
            track.cornerRadius = 0
            track.masksToBounds = false
            fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * p, height: 3)
            fill.position = CGPoint(x: 0, y: 1.5)
        } else {
            track.isHidden = true
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The bar runs along the picture's foot inside its rounded corners.
        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: CGRect(x: 0, y: -(tileHeight - 3), width: bounds.width, height: tileHeight),
                           cornerWidth: 12, cornerHeight: 12, transform: nil)
        track.mask = mask
    }
}

// MARK: - Discover (a title from TMDB, maybe not in the library)

/// DiscoverCard.tsx: a poster with its MOVIE/SHOW chip, an optional rank
/// numeral over a top scrim, and an always-visible foot bar with the My List
/// bookmark (pop, ring and "Added to My List") and the Request pill.
final class DiscoverCell: CardCell {
    static var size: NSSize { PosterCell.size }
    private let chip = CATextLayer()
    private let chipBG = CALayer()
    private let rankScrim = ShadeLayer()
    private let rank = CATextLayer()
    private let rankTricolour = CAGradientLayer()
    private let rankMask = CATextLayer()
    private let footer = ShadeLayer()
    let save = PillButton("", style: .tinted(Theme.palette.void.withAlphaComponent(0.7), Theme.palette.void.withAlphaComponent(0.9), Theme.palette.ink.withAlphaComponent(0.85)), height: 26)
    let request = PillButton("Request", style: .tinted(NSColor.white.withAlphaComponent(0.25), NSColor.white.withAlphaComponent(0.4), Theme.palette.ink), height: 22, fontSize: 10.5)
    private let flash = FlashPill()
    var onSave: (() -> Void)?
    var onRequest: (() -> Void)?
    private var wasSaved: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        tileHeight = PosterCell.width * 1.5
        showsVeil = false
        let p = Theme.palette
        chipBG.backgroundColor = p.void.withAlphaComponent(0.8).cgColor
        chipBG.cornerRadius = 6
        chip.font = Theme.text(9.5, .semibold)
        chip.fontSize = 9.5
        chip.foregroundColor = p.ink.withAlphaComponent(0.9).cgColor
        chip.alignmentMode = .center
        chip.contentsScale = 2
        chipBG.addSublayer(chip)
        rankScrim.set([p.void.withAlphaComponent(0.7), .clear])
        for l in [rank, rankMask] {
            l.font = Theme.display(72, .heavy)
            l.fontSize = 72
            l.contentsScale = 2
        }
        rank.foregroundColor = p.ink.cgColor
        rank.shadowColor = NSColor.black.cgColor
        rank.shadowOpacity = 0.7
        rank.shadowRadius = 7
        rank.shadowOffset = CGSize(width: 0, height: -2)
        rankMask.foregroundColor = NSColor.black.cgColor
        // The Indian OTTs row's saffron, white and green, top to foot.
        rankTricolour.colors = [Theme.rgb(0xFF9933).cgColor, NSColor.white.cgColor, Theme.rgb(0x21A038).cgColor]
        rankTricolour.mask = rankMask
        rankTricolour.shadowColor = NSColor.black.cgColor
        rankTricolour.shadowOpacity = 0.75
        rankTricolour.shadowRadius = 5
        footer.set([.clear, p.void.withAlphaComponent(0.45), p.void.withAlphaComponent(0.85)])
        // Under the sheen and the ring, over the picture.
        let below = tile.sublayers?.firstIndex(where: { $0 === veil }) ?? 3
        for (i, l) in [footer, rankScrim, chipBG, rank, rankTricolour].enumerated() { tile.insertSublayer(l, at: UInt32(below + 1 + i)) }
        save.icon = .bookmark
        save.action = { [weak self] in self?.pressedSave() }
        request.action = { [weak self] in self?.onRequest?() }
        addSubview(save)
        addSubview(request)
        addSubview(flash)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: DiscoverItem, rank number: Int?, status: Int?, saved: Bool, tricolour: Bool = false) {
        let sameItem = title.stringValue == (item.title ?? "") && wasSaved != nil
        if !sameItem { resetForReuse(); flash.reset() }
        tileHeight = bounds.width * 1.5
        picture.load(Artwork.tmdb(item.posterUrl), points: bounds.width * 1.5, scale: backingScale)
        title.stringValue = item.title ?? ""
        meta.stringValue = CardText.discoverMeta(item)
        let p = Theme.palette
        CATransaction.begin(); CATransaction.setDisableActions(true)
        chip.string = NSAttributedString(string: item.mediaType == "tv" ? "SHOW" : "MOVIE", attributes: [
            .font: Theme.text(9.5, .semibold), .foregroundColor: p.ink.withAlphaComponent(0.9), .kern: 0.47,
        ])
        let cw: CGFloat = item.mediaType == "tv" ? 40 : 45
        chipBG.frame = CGRect(x: bounds.width - cw - 6, y: 6, width: cw, height: 17)
        chip.frame = CGRect(x: 0, y: 2.5, width: cw, height: 13)
        let ranked = number != nil
        rankScrim.isHidden = !ranked
        rankScrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: tileHeight / 3)
        rank.isHidden = !ranked || tricolour
        rankTricolour.isHidden = !ranked || !tricolour
        if let number {
            let text = NSAttributedString(string: "\(number)", attributes: [.font: Theme.display(72, .heavy), .kern: -3.6])
            rank.string = text
            rankMask.string = text
            let f = CGRect(x: 6, y: -6, width: 130, height: 90)
            rank.frame = f
            rankTricolour.frame = f
            rankMask.frame = rankTricolour.bounds
        }
        footer.frame = CGRect(x: 0, y: tileHeight - 56, width: bounds.width, height: 56)
        CATransaction.commit()
        wasSaved = saved
        save.icon = saved ? .bookmarkFilled : .bookmark
        save.style = saved ? .tinted(p.accent, p.accent, p.accentInk) : .tinted(p.void.withAlphaComponent(0.7), p.void.withAlphaComponent(0.9), p.ink.withAlphaComponent(0.85))
        // Request, or what is already true: requested / in the library.
        if SeerrStatus.inLibrary(status) || SeerrStatus.requested(status) {
            request.title = SeerrStatus.label(status)
            request.icon = .check
            request.style = .tinted(p.void.withAlphaComponent(0.75), p.void.withAlphaComponent(0.75), p.accent)
            request.isEnabled = false
        } else {
            request.title = "Request"
            request.icon = .plus
            request.style = .tinted(NSColor.white.withAlphaComponent(0.25), NSColor.white.withAlphaComponent(0.4), p.ink)
            request.isEnabled = true
        }
        needsLayout = true
    }

    private func pressedSave() {
        let adding = !(wasSaved ?? false)
        // The icon pops (1 → 1.45 → 0.9 → 1, 480 ms on a spring); adding also
        // sends a ring out from the button and says so above it.
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.45, 0.9, 1]
        pop.keyTimes = [0, 0.3, 0.6, 1]
        pop.duration = 0.48
        pop.timingFunction = Theme.spring
        save.layer?.sublayers?.first(where: { $0 is CAShapeLayer })?.add(pop, forKey: "pop")
        if adding { save.ring() }
        flash.show(adding ? "Added to My List" : "Removed from My List", check: adding)
        onSave?()
    }

    override func layout() {
        super.layout()
        let y = tileHeight - 26 - 6
        save.frame = NSRect(x: 6, y: y, width: 26, height: 26)
        request.sizeToFit()
        let w = min(request.frame.width, bounds.width - 46)
        request.frame = NSRect(x: bounds.width - w - 6, y: y + 2, width: w, height: 22)
        flash.frame = NSRect(x: 6, y: tileHeight - 40 - 22, width: bounds.width - 12, height: 22)
    }
}

/// "Added to My List" / "Removed from My List" over the card's foot
/// (`.list-flash`, 1.4 s: rises in, holds, lifts away).
final class FlashPill: FlippedView {
    private let pill = CALayer()
    private let text = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pill.backgroundColor = Theme.palette.void.withAlphaComponent(0.9).cgColor
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.4
        pill.shadowRadius = 8
        pill.shadowOffset = CGSize(width: 0, height: -8)
        text.contentsScale = 2
        text.alignmentMode = .center
        pill.addSublayer(text)
        layer?.addSublayer(pill)
        pill.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func reset() {
        pill.removeAllAnimations()
        pill.opacity = 0
    }

    func show(_ message: String, check: Bool) {
        let p = Theme.palette
        let s = NSMutableAttributedString()
        if check { s.append(NSAttributedString(string: "✓ ", attributes: [.font: Theme.text(10.5, .bold), .foregroundColor: p.accent])) }
        s.append(NSAttributedString(string: message, attributes: [.font: Theme.text(10.5, .semibold), .foregroundColor: p.ink]))
        let w = ceil(s.size().width) + 20
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: 22)
        pill.cornerRadius = 11
        text.string = s
        text.frame = CGRect(x: 0, y: 4, width: w, height: 16)
        CATransaction.commit()
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.14, 0.78, 1]
        let rise = CAKeyframeAnimation(keyPath: "transform")
        let start = CATransform3DScale(CATransform3DMakeTranslation(0, 6, 0), 0.92, 0.92, 1)
        rise.values = [start, CATransform3DIdentity, CATransform3DIdentity, CATransform3DMakeTranslation(0, -3, 0)]
        rise.keyTimes = [0, 0.14, 0.78, 1]
        let g = CAAnimationGroup()
        g.animations = [fade, rise]
        g.duration = 1.4
        g.timingFunction = Theme.expoOut
        pill.add(g, forKey: "flash")
    }
}

extension PillButton {
    /// The ring that leaves a button when something is saved (`.save-ring`):
    /// the accent at 75%, spreading 11 pt and fading over 560 ms.
    func ring() {
        guard let host = layer else { return }
        let r = CAShapeLayer()
        let b = bounds
        r.frame = b
        r.path = CGPath(ellipseIn: b, transform: nil)
        r.fillColor = nil
        r.strokeColor = Theme.palette.accent.withAlphaComponent(0.75).cgColor
        r.lineWidth = 2
        host.addSublayer(r)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DIdentity
        grow.toValue = PillButton.lift(b, dy: 0, scale: (b.width + 22) / b.width)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.56
        g.timingFunction = Theme.expoOut
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { r.removeFromSuperlayer() }
        r.add(g, forKey: "ring")
        CATransaction.commit()
        host.masksToBounds = false
    }
}

// MARK: - Cast

final class CastCell: FlippedView {
    static let size = NSSize(width: 104, height: 150)
    private let face = RemoteImage()
    private let ring = CALayer()
    private let name = makeLabel(font: Theme.text(12.5, .medium), color: Theme.palette.ink)
    private let role = makeLabel(font: Theme.text(11.5), color: Theme.palette.muted)
    var onOpen: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.backgroundColor = Theme.palette.void2.cgColor
        ring.cornerRadius = 48
        ring.masksToBounds = true
        face.layer.cornerRadius = 48
        ring.addSublayer(face.layer)
        layer?.addSublayer(ring)
        name.alignment = .center
        role.alignment = .center
        addSubview(name)
        addSubview(role)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ p: JFPerson, art: Artwork) {
        face.load(art.person(p, width: 200), points: 96, scale: window?.backingScaleFactor ?? 2)
        name.stringValue = p.Name ?? ""
        role.stringValue = p.Role?.isEmpty == false ? p.Role! : (p.Type ?? "")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = CGRect(x: (bounds.width - 96) / 2, y: 0, width: 96, height: 96)
        face.layer.frame = ring.bounds
        CATransaction.commit()
        name.frame = NSRect(x: 0, y: 104, width: bounds.width, height: 16)
        role.frame = NSRect(x: 0, y: 121, width: bounds.width, height: 15)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    private func lift(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.42)
        CATransaction.setAnimationTimingFunction(Theme.expoOut)
        var t = CATransform3DMakeTranslation(0, on ? -7 : 0, 0)
        t = CATransform3DScale(t, on ? 1.035 : 1, on ? 1.035 : 1, 1)
        ring.transform = t
        ring.borderWidth = on ? 1 : 0
        ring.borderColor = Theme.palette.accent.withAlphaComponent(0.42).cgColor
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { lift(true) }
    override func mouseExited(with event: NSEvent) { lift(false) }
}

// MARK: - Text

enum CardText {
    static func meta(_ item: JFItem) -> String {
        if item.isEpisode {
            var parts = ["S\(item.ParentIndexNumber ?? 0) · E\(item.IndexNumber ?? 0)"]
            if let r = item.runtimeText { parts.append(r) }
            return parts.joined(separator: "   ")
        }
        var parts: [String] = []
        if let r = item.CommunityRating, r > 0 { parts.append("☆ " + String(format: "%.1f", r)) }
        if let y = item.ProductionYear { parts.append(String(y)) }
        if let r = item.runtimeText { parts.append(r) }
        return parts.joined(separator: "   ")
    }

    static func discoverMeta(_ item: DiscoverItem) -> String {
        var parts: [String] = []
        if let v = item.voteAverage, v > 0 { parts.append("☆ " + String(format: "%.1f", v)) }
        if let y = item.year, !y.isEmpty { parts.append(y) }
        if let g = item.genre, !g.isEmpty { parts.append(g) }
        return parts.joined(separator: "   ")
    }

    /// "1h 5m left", "23 min left".
    static func timeLeft(_ item: JFItem) -> String? {
        guard let pos = item.UserData?.PlaybackPositionTicks, pos > 0, let total = item.RunTimeTicks, total > pos else { return nil }
        let minutes = Int((total - pos) / 600_000_000)
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        return "\(max(1, minutes)) min left"
    }
}
