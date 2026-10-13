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
/// caption under it. Subclasses fill them.
class CardCell: FlippedView {
    let tile = CALayer()
    let placeholder = CAGradientLayer()
    let picture = RemoteImage()
    let veil = ShadeLayer()
    let playBadge = CAShapeLayer()
    let title = makeLabel(font: Theme.text(13, .medium), color: Theme.palette.ink.withAlphaComponent(0.9))
    let meta = makeLabel(font: Theme.text(11.5), color: Theme.palette.muted)
    var onOpen: (() -> Void)?
    /// Where a click on the picture goes, if not `onOpen` (the wide card plays).
    var onPicture: (() -> Void)?
    private var tracking: NSTrackingArea?
    private(set) var hovering = false
    var tileHeight: CGFloat = 0
    var showsVeil = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = false
        tile.cornerRadius = 12
        tile.cornerCurve = .continuous
        tile.masksToBounds = false
        tile.shadowColor = NSColor.black.cgColor
        tile.shadowOpacity = 0
        tile.shadowRadius = 21
        tile.shadowOffset = CGSize(width: 0, height: -20)
        tile.borderColor = Theme.palette.accent.withAlphaComponent(0.42).cgColor
        tile.borderWidth = 0
        placeholder.colors = [Theme.palette.placeholderFrom.cgColor, Theme.palette.placeholderTo.cgColor]
        placeholder.startPoint = CGPoint(x: 0, y: 0)
        placeholder.endPoint = CGPoint(x: 1, y: 1)
        placeholder.cornerRadius = 12
        placeholder.cornerCurve = .continuous
        placeholder.masksToBounds = true
        picture.layer.cornerRadius = 12
        picture.layer.cornerCurve = .continuous
        // The inset ring every card carries (white/10).
        picture.layer.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        picture.layer.borderWidth = 1
        veil.set([.clear, NSColor.black.withAlphaComponent(0.25), NSColor.black.withAlphaComponent(0.85)])
        veil.cornerRadius = 12
        veil.masksToBounds = true
        veil.opacity = 0
        playBadge.fillColor = NSColor.white.withAlphaComponent(0.15).cgColor
        playBadge.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        playBadge.lineWidth = 1
        playBadge.opacity = 0
        tile.addSublayer(placeholder)
        tile.addSublayer(picture.layer)
        tile.addSublayer(veil)
        tile.addSublayer(playBadge)
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
        tile.bounds = CGRect(origin: .zero, size: r.size)
        tile.position = CGPoint(x: r.midX, y: r.midY)
        tile.shadowPath = CGPath(roundedRect: tile.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        placeholder.frame = tile.bounds
        picture.layer.frame = tile.bounds
        veil.frame = tile.bounds
        let d: CGFloat = 44
        playBadge.frame = CGRect(x: (r.width - d) / 2, y: (r.height - d) / 2, width: d, height: d)
        let circle = CGMutablePath()
        circle.addEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        let tri = PillButton.path(.play, 18)
        circle.addPath(tri, transform: CGAffineTransform(translationX: (d - 18) / 2 + 1, y: (d - 18) / 2))
        playBadge.path = circle
        CATransaction.commit()
        title.frame = NSRect(x: 0, y: tileHeight + 8, width: bounds.width, height: 17)
        meta.frame = NSRect(x: 0, y: tileHeight + 26, width: bounds.width, height: 15)
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

    func setHover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.42 : 0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1))
        // Up 7 pt (the layer tree is flipped with its view) and 3.5% larger.
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, 0, on ? -7 : 0, 0)
        t = CATransform3DScale(t, on ? 1.035 : 1, on ? 1.035 : 1, 1)
        tile.transform = t
        tile.shadowOpacity = on ? 0.72 : 0
        tile.borderWidth = on ? 1 : 0
        if showsVeil {
            veil.opacity = on ? 1 : 0
            playBadge.opacity = on ? 1 : 0
        }
        CATransaction.commit()
    }

    /// A reused cell must not keep the last card's hover.
    func resetForReuse() {
        hovering = true
        setHover(false)
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
        badgeBG.cornerRadius = 10
        badge.fontSize = 11
        badge.font = Theme.text(11, .bold)
        badge.foregroundColor = Theme.palette.accentInk.cgColor
        badge.alignmentMode = .center
        badge.contentsScale = 2
        badgeBG.addSublayer(badge)
        tile.addSublayer(badgeBG)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: JFItem, art: Artwork) {
        resetForReuse()
        tileHeight = bounds.width * 1.5
        picture.load(art.poster(item, width: Int(bounds.width * 2)), points: bounds.width * 1.5, scale: backingScale)
        title.stringValue = item.Name ?? ""
        meta.stringValue = CardText.meta(item)
        // A ✓ when watched, or the count of unwatched episodes.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if item.UserData?.Played == true {
            badge.string = "✓"
            badgeBG.isHidden = false
            badgeBG.frame = CGRect(x: bounds.width - 30, y: 8, width: 22, height: 22)
            badgeBG.cornerRadius = 11
        } else if let n = item.UserData?.UnplayedItemCount, n > 0, item.isSeries {
            badge.string = "\(n)"
            badgeBG.isHidden = false
            let w = max(22, CGFloat("\(n)".count) * 7 + 12)
            badgeBG.frame = CGRect(x: bounds.width - w - 8, y: 8, width: w, height: 20)
            badgeBG.cornerRadius = 10
        } else {
            badgeBG.isHidden = true
        }
        badge.frame = CGRect(x: 0, y: 3, width: badgeBG.bounds.width, height: 16)
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
        track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.backgroundColor = Theme.palette.accent.cgColor
        tile.addSublayer(track)
        track.addSublayer(fill)
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
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let p = item.progress {
            track.isHidden = false
            track.frame = CGRect(x: 0, y: tileHeight - 3, width: bounds.width, height: 3)
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * p, height: 3)
        } else {
            track.isHidden = true
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The bar sits inside the picture's rounded clip.
        tile.masksToBounds = false
    }
}

// MARK: - Discover (a title from TMDB, maybe not in the library)

final class DiscoverCell: CardCell {
    static var size: NSSize { PosterCell.size }
    private let chip = CATextLayer()
    private let chipBG = CALayer()
    private let rank = CATextLayer()
    private let footer = ShadeLayer()
    let save = PillButton("", style: .glass, height: 26)
    let request = PillButton("Request", style: .glass, height: 26, fontSize: 12)
    var onSave: (() -> Void)?
    var onRequest: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        tileHeight = PosterCell.width * 1.5
        showsVeil = false
        chipBG.backgroundColor = Theme.palette.void.withAlphaComponent(0.8).cgColor
        chipBG.cornerRadius = 6
        chip.fontSize = 9.5
        chip.font = Theme.text(9.5, .bold)
        chip.foregroundColor = Theme.palette.ink.cgColor
        chip.alignmentMode = .center
        chip.contentsScale = 2
        chipBG.addSublayer(chip)
        rank.font = Theme.display(72, .heavy)
        rank.fontSize = 72
        rank.foregroundColor = Theme.palette.ink.cgColor
        rank.contentsScale = 2
        rank.shadowOpacity = 0.6
        rank.shadowRadius = 6
        rank.shadowOffset = .zero
        footer.set([.clear, NSColor.black.withAlphaComponent(0.75)])
        tile.addSublayer(footer)
        tile.addSublayer(chipBG)
        tile.addSublayer(rank)
        save.icon = .bookmark
        save.action = { [weak self] in self?.onSave?() }
        request.action = { [weak self] in self?.onRequest?() }
        addSubview(save)
        addSubview(request)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: DiscoverItem, rank number: Int?, status: Int?, saved: Bool) {
        resetForReuse()
        tileHeight = bounds.width * 1.5
        picture.load(Artwork.tmdb(item.posterUrl), points: bounds.width * 1.5, scale: backingScale)
        title.stringValue = item.title ?? ""
        meta.stringValue = CardText.discoverMeta(item)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        chip.string = item.mediaType == "tv" ? "SHOW" : "MOVIE"
        let cw: CGFloat = item.mediaType == "tv" ? 40 : 46
        chipBG.frame = CGRect(x: bounds.width - cw - 8, y: 8, width: cw, height: 18)
        chip.frame = CGRect(x: 0, y: 3, width: cw, height: 13)
        if let number {
            rank.isHidden = false
            rank.string = "\(number)"
            rank.frame = CGRect(x: 8, y: -10, width: 120, height: 90)
        } else {
            rank.isHidden = true
        }
        footer.frame = CGRect(x: 0, y: tileHeight - 52, width: bounds.width, height: 52)

        footer.cornerRadius = 12
        footer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        CATransaction.commit()
        save.icon = saved ? .bookmarkFilled : .bookmark
        save.style = saved ? .accent : .glass
        request.title = SeerrStatus.label(status)
        request.icon = SeerrStatus.inLibrary(status) ? .check : (SeerrStatus.requested(status) ? nil : .plus)
        request.style = SeerrStatus.inLibrary(status) ? .glass : .glass
        request.isEnabled = !SeerrStatus.inLibrary(status)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = tileHeight - 26 - 8
        save.frame = NSRect(x: 8, y: y, width: 26, height: 26)
        request.sizeToFit()
        request.frame = NSRect(x: bounds.width - request.frame.width - 8, y: y,
                               width: min(request.frame.width, bounds.width - 50), height: 26)
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
