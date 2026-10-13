import AppKit

/*
 * The "OTTs" row: the streaming platforms this library carries titles from,
 * generated from Mahfin's src/lib/otts.ts (same ids, names and logos). A
 * platform shows only when the library has something from it.
 */
struct Ott {
    let id: String
    let name: String
    let short: String?
    let aliases: [String]
    let logo: String

    static let all: [Ott] = [
        Ott(id: "netflix", name: "Netflix", short: nil, aliases: ["Netflix"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/wwemzKWzjKYJFfCeiB57q3r4Bcm.png"),
        Ott(id: "prime-video", name: "Prime Video", short: nil, aliases: ["Prime Video", "Prime Video India", "Amazon Prime Video"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/ifhbNuuVnlwYy5oXA5VIb2YR8AZ.png"),
        Ott(id: "disney-plus", name: "Disney+", short: nil, aliases: ["Disney+", "Disney Plus"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/gJ8VX6JSu3ciXHuC2dDGAo2lvwM.png"),
        Ott(id: "jiohotstar", name: "JioHotstar", short: nil, aliases: ["JioHotstar", "Hotstar", "Disney+ Hotstar", "JioCinema"], logo: "/logos/jiohotstar.svg"),
        Ott(id: "sonyliv", name: "SonyLIV", short: nil, aliases: ["SonyLIV", "Sony LIV", "Sony Liv"], logo: "/logos/sonyliv.png"),
        Ott(id: "zee5", name: "ZEE5", short: nil, aliases: ["Zee5", "ZEE5"], logo: "/logos/zee5.svg"),
        Ott(id: "max", name: "Max", short: nil, aliases: ["Max", "HBO Max", "HBO"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/tuomPhY2UtuPTqqFnKMVHvSb724.png"),
        Ott(id: "apple-tv", name: "Apple TV+", short: nil, aliases: ["Apple TV", "Apple TV+", "Apple Studios"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/4KAy34EHvRM25Ih8wb82AuGU7zJ.png"),
        Ott(id: "hulu", name: "Hulu", short: nil, aliases: ["Hulu"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/pqUTCleNUiTLAVlelGxUgWn1ELh.png"),
        Ott(id: "paramount-plus", name: "Paramount+", short: nil, aliases: ["Paramount+", "Paramount Plus"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/fi83B1oztoS47xxcemFdPMhIzK.png"),
        Ott(id: "peacock", name: "Peacock", short: nil, aliases: ["Peacock"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/gIAcGTjKKr0KOHL5s4O36roJ8p7.png"),
        Ott(id: "mx-player", name: "MX Player", short: "MX", aliases: ["MX Player", "Amazon MX Player"], logo: "/logos/mx-player.svg"),
        Ott(id: "altbalaji", name: "ALTBalaji", short: "ALT", aliases: ["ALTBalaji", "ALT Balaji"], logo: "/logos/altbalaji.svg"),
        Ott(id: "voot", name: "VOOT", short: nil, aliases: ["VOOT", "Voot"], logo: "/logos/voot.png"),
        Ott(id: "aha", name: "aha", short: nil, aliases: ["aha", "Aha"], logo: "/logos/aha.svg"),
        Ott(id: "sunnxt", name: "Sun NXT", short: nil, aliases: ["Sun NXT", "SunNXT"], logo: "/logos/sunnxt.png"),
        Ott(id: "crunchyroll", name: "Crunchyroll", short: nil, aliases: ["Crunchyroll"], logo: "/logos/crunchyroll.svg"),
        Ott(id: "bbc", name: "BBC", short: nil, aliases: ["BBC", "BBC One", "BBC Two", "BBC Three", "BBC iPlayer"], logo: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/mVn7xESaTNmjBUyUtGNvDQd3CT1.png"),
    ]

    /// TMDB logos are absolute; Mahfin's own (`/logos/...`) are on the site.
    func logoURL(site: URL) -> URL? {
        logo.hasPrefix("/") ? URL(string: logo, relativeTo: site)?.absoluteURL : URL(string: logo)
    }
}

/// A platform tile (OttCard.tsx): its logo on a gray-800 plate with a
/// gray-700 ring; hovered, it grows 5% to a gray-700 plate and gray-500 ring
/// over 300 ms. 288 × 144, as on the web at desktop width.
@MainActor
final class OttCell: FlippedView {
    static let size = NSSize(width: 288, height: 144)
    private static let gray800 = Theme.rgb(0x1e2939), gray700 = Theme.rgb(0x364153)
    private static let gray500 = Theme.rgb(0x6a7282), gray900 = Theme.rgb(0x101828)
    private let plate = CALayer()
    private let foot = ShadeLayer()
    private let logo = RemoteImage()
    private let fallback = makeLabel(font: Theme.display(17, .bold), color: .white)
    var onOpen: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = false
        plate.backgroundColor = OttCell.gray800.cgColor
        plate.cornerRadius = 12
        plate.cornerCurve = .continuous
        plate.borderWidth = 1
        plate.borderColor = OttCell.gray700.cgColor
        plate.masksToBounds = true
        plate.shadowOpacity = 0
        foot.set([.clear, OttCell.gray900])
        plate.addSublayer(foot)
        logo.layer.contentsGravity = .resizeAspect
        logo.layer.masksToBounds = false
        plate.addSublayer(logo.layer)
        layer?.addSublayer(plate)
        fallback.alignment = .center
        addSubview(fallback)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ o: Ott, site: URL) {
        fallback.stringValue = o.short ?? o.name
        logo.onLoad = { [weak self] in self?.fallback.isHidden = true }
        logo.load(o.logoURL(site: site), points: 240, scale: window?.backingScaleFactor ?? 2)
        fallback.isHidden = logo.layer.contents != nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plate.bounds = CGRect(origin: .zero, size: bounds.size)
        plate.position = CGPoint(x: bounds.midX, y: bounds.midY)
        foot.frame = CGRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 40)
        // `p-6`: the logo fits inside 24 pt of padding.
        logo.layer.frame = plate.bounds.insetBy(dx: 24, dy: 24)
        CATransaction.commit()
        let s = fallback.fitSize
        fallback.frame = NSRect(x: 0, y: (bounds.height - s.height) / 2, width: bounds.width, height: s.height)
    }

    private func setHover(_ on: Bool) {
        hovering = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(Theme.standard)
        plate.transform = on ? CATransform3DMakeScale(1.05, 1.05, 1) : CATransform3DIdentity
        plate.backgroundColor = (on ? OttCell.gray700 : OttCell.gray800).cgColor
        plate.borderColor = (on ? OttCell.gray500 : OttCell.gray700).cgColor
        CATransaction.commit()
        foot.set([.clear, on ? OttCell.gray800 : OttCell.gray900])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
}
