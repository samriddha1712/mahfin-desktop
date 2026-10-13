import AppKit

/*
 * What every native page shares: the API, image addresses, the household's
 * request statuses and My List (so a card's buttons agree in every row), and
 * the way out to the web router.
 */
@MainActor
final class NativeContext {
    let api: MahfinAPI
    let art: Artwork
    /// Asks the web router to go to `path` (native pages included).
    let open: (String) -> Void
    /// Opens one of the web app's own dialogs over this page ("recommend:<id>",
    /// "download:<id>", "collection:<id>"): the same dialog, the same UI.
    var openDialog: ((String) -> Void)?
    /// Whether this build has a download route (the web's `downloadsConfigured`).
    var downloadsConfigured = false
    /// Whether this person is a Jellyfin administrator (Editor's pick).
    var isAdmin = false
    /// What friends said of each title ("movie:<tmdb>"), newest first, for
    /// the badge on a card (the web's FriendsOnCard). One request per page.
    var friendVerdicts: [String: [FriendOnCard]] = [:]
    var statuses: [String: Int] = [:]
    var saved: Set<String> = []          // "movie:123" keys on My List (watchlist)
    private var listeners: [() -> Void] = []

    init(session: NativeSession, open: @escaping (String) -> Void) {
        api = MahfinAPI(session: session)
        art = Artwork(server: session.server)
        self.open = open
    }

    func onChange(_ f: @escaping () -> Void) { listeners.append(f) }
    private func changed() { listeners.forEach { $0() } }

    /// The request statuses and the watchlist, as the web's buttons read them.
    func refreshShared() {
        let api = self.api
        Task { [weak self] in
            await api.load(StatusMap.self, .mahfin, "/api/discover/status") { m in
                self?.statuses = m.statuses
                self?.changed()
            }
            struct Watch: Codable { struct E: Codable { var tmdbId: Int; var mediaType: String }; var items: [E] }
            await api.load(Watch.self, .mahfin, "/api/watchlist") { w in
                self?.saved = Set(w.items.map { "\($0.mediaType):\($0.tmdbId)" })
                self?.changed()
            }
            struct Friends: Codable { var byKey: [String: [FriendOnCard]] }
            await api.load(Friends.self, .mahfin, "/api/verdicts/friends") { f in
                self?.friendVerdicts = f.byKey
                self?.changed()
            }
            struct Me: Codable { struct P: Codable { var IsAdministrator: Bool? }; var Policy: P? }
            if let me = try? await api.fetch(Me.self, .jellyfin, "Users/Me") {
                self?.isAdmin = me.Policy?.IsAdministrator == true
                self?.changed()
            }
        }
    }

    func status(_ item: DiscoverItem) -> Int? { statuses[item.key] ?? item.status }

    /// My List for a title not in the library: optimistic, then the server's answer.
    func toggleSaved(_ item: DiscoverItem) {
        let on = !saved.contains(item.key)
        if on { saved.insert(item.key) } else { saved.remove(item.key) }
        changed()
        Task {
            do {
                if on {
                    try await api.send(.mahfin, "POST", "/api/watchlist", json: [
                        "tmdbId": item.tmdbId, "mediaType": item.mediaType, "title": item.title ?? "",
                        "posterUrl": item.posterUrl ?? "", "year": item.year ?? "",
                    ])
                } else {
                    try await api.send(.mahfin, "DELETE", "/api/watchlist", ["type": item.mediaType, "id": String(item.tmdbId)])
                }
            } catch {
                if on { saved.remove(item.key) } else { saved.insert(item.key) }
                changed()
            }
        }
    }

    func openItem(_ item: JFItem) {
        open(item.isPerson ? "/person/\(item.Id)" : "/item/\(item.Id)")
    }

    func openDiscover(_ item: DiscoverItem) {
        open("/discover/\(item.mediaType)/\(item.tmdbId)")
    }

    func play(_ id: String) { open("/play/\(id)") }
}

/// One entry of a mixed row: a library title or a requestable one.
enum CardEntry {
    case library(JFItem)
    case discover(DiscoverItem)
}

/// Hosts a poster or a discover card, whichever the entry is.
final class EntryCell: FlippedView {
    private var poster: PosterCell?
    private var discover: DiscoverCell?

    func configure(_ entry: CardEntry, rank: Int?, tricolour: Bool = false, ctx: NativeContext) {
        switch entry {
        case .library(let item):
            discover?.isHidden = true
            let c = poster ?? { let c = PosterCell(frame: bounds); addSubview(c); poster = c; return c }()
            c.isHidden = false
            c.frame = bounds
            c.configure(item, art: ctx.art)
            c.friends.set(MeterView.key(for: item).flatMap { ctx.friendVerdicts[$0] }, server: ctx.api.session.server,
                          origin: CGPoint(x: 8, y: 8), fromRight: false)
            c.onOpen = { ctx.openItem(item) }
            c.onPicture = nil
        case .discover(let item):
            poster?.isHidden = true
            let c = discover ?? { let c = DiscoverCell(frame: bounds); addSubview(c); discover = c; return c }()
            c.isHidden = false
            c.frame = bounds
            c.configure(item, rank: rank, status: ctx.status(item), saved: ctx.saved.contains(item.key), tricolour: tricolour)
            // Top left is free unless the row is ranked; then the numeral owns
            // it, and the badge drops under the Movie/Show chip on the right.
            c.friends.set(ctx.friendVerdicts[item.key], server: ctx.api.session.server,
                          origin: rank != nil ? CGPoint(x: bounds.width - 6, y: 28) : CGPoint(x: 6, y: 6), fromRight: rank != nil)
            c.onOpen = { ctx.openDiscover(item) }
            c.onSave = { ctx.toggleSaved(item) }
            c.onRequest = { ctx.openDiscover(item) }
        }
    }

    override func layout() {
        super.layout()
        poster?.frame = bounds
        discover?.frame = bounds
    }
}

/// A row on a page, as Mahfin's Row.tsx: heading (accent pill, title, "See
/// all"), the strip, and arrows on the strip's edges while the row is hovered.
/// The first time it comes into view it rises and fades in, and deals its
/// first eight cards in after it.
final class RowView: FlippedView {
    enum Kind { case posters, wide, entries(ranked: Bool), cast, otts }

    let kind: Kind
    private let heading = makeLabel(font: Theme.display(25.6, .bold), color: Theme.palette.ink)
    private let pill = CALayer()
    private var seeAll: SeeAllButton?
    private let prev = NudgeButton(direction: -1)
    private let next = NudgeButton(direction: 1)
    private let ctx: NativeContext
    private var strip: NSView & RowStrip
    private var tracking: NSTrackingArea?
    private var hovered = false
    private(set) var revealed = false
    static let headerHeight: CGFloat = 44
    static let inset: CGFloat = 40
    private static let padTop: CGFloat = 16, padBottom: CGFloat = 28
    /// Rank numerals in the Indian OTTs row are the tricolour ones.
    var tricolour = false

    func setTitle(_ t: String) {
        guard heading.stringValue != t else { return }
        heading.attributedStringValue = RowView.title(t)
        needsLayout = true
    }

    private static func title(_ t: String) -> NSAttributedString {
        // `tracking-tight`: -0.025em.
        NSAttributedString(string: t, attributes: [
            .font: Theme.display(25.6, .bold), .foregroundColor: Theme.palette.ink, .kern: -0.64,
        ])
    }

    var items: [JFItem] = [] { didSet { reload(items.count) } }
    var entries: [CardEntry] = [] { didSet { reload(entries.count) } }
    var people: [JFPerson] = [] { didSet { reload(people.count) } }
    var otts: [Ott] = [] { didSet { reload(otts.count) } }

    init(title: String, kind: Kind, seeAll: String? = nil, ctx: NativeContext) {
        self.kind = kind
        self.ctx = ctx
        switch kind {
        case .posters:
            let s = CardStrip<PosterCell>(make: { PosterCell(frame: NSRect(origin: .zero, size: PosterCell.size)) }, configure: { _, _ in })
            s.cellSize = PosterCell.size
            strip = s
        case .wide:
            let s = CardStrip<WideCell>(make: { WideCell(frame: NSRect(origin: .zero, size: WideCell.size)) }, configure: { _, _ in })
            s.cellSize = WideCell.size
            strip = s
        case .entries:
            let s = CardStrip<EntryCell>(make: { EntryCell(frame: NSRect(origin: .zero, size: PosterCell.size)) }, configure: { _, _ in })
            s.cellSize = PosterCell.size
            strip = s
        case .cast:
            let s = CardStrip<CastCell>(make: { CastCell(frame: NSRect(origin: .zero, size: CastCell.size)) }, configure: { _, _ in })
            s.cellSize = CastCell.size
            s.spacing = 18
            strip = s
        case .otts:
            let s = CardStrip<OttCell>(make: { OttCell(frame: NSRect(origin: .zero, size: OttCell.size)) }, configure: { _, _ in })
            s.cellSize = OttCell.size
            strip = s
        }
        super.init(frame: .zero)
        layer?.masksToBounds = false
        heading.attributedStringValue = RowView.title(title)
        pill.backgroundColor = Theme.palette.accent.cgColor
        pill.cornerRadius = 2.5
        // `box-shadow: 0 0 14px` of the accent at 55%.
        pill.shadowColor = Theme.palette.accent.cgColor
        pill.shadowOpacity = 0.55
        pill.shadowRadius = 7
        pill.shadowOffset = .zero
        layer?.addSublayer(pill)
        addSubview(heading)
        addSubview(strip)
        if let seeAll {
            let b = SeeAllButton()
            b.action = { ctx.open(seeAll) }
            addSubview(b)
            self.seeAll = b
        }
        prev.action = { [weak self] in self?.strip.page(-1) }
        next.action = { [weak self] in self?.strip.page(1) }
        prev.alphaValue = 0
        next.alphaValue = 0
        addSubview(prev)
        addSubview(next)
        strip.onScroll = { [weak self] in self?.updateArrows(animated: true) }
        wire()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Connects the strip's cells to this row's data.
    private func wire() {
        let ctx = self.ctx
        switch kind {
        case .posters:
            (strip as! CardStrip<PosterCell>).setConfigure { [weak self] c, i in
                guard let self, i < self.items.count else { return }
                let item = self.items[i]
                c.configure(item, art: ctx.art)
                c.friends.set(MeterView.key(for: item).flatMap { ctx.friendVerdicts[$0] }, server: ctx.api.session.server,
                              origin: CGPoint(x: 8, y: 8), fromRight: false)
                c.onOpen = { ctx.openItem(item) }
            }
        case .wide:
            (strip as! CardStrip<WideCell>).setConfigure { [weak self] c, i in
                guard let self, i < self.items.count else { return }
                let item = self.items[i]
                c.configure(item, art: ctx.art)
                c.onPicture = { ctx.play(item.Id) }
                c.onOpen = { ctx.openItem(item) }
            }
        case .entries(let ranked):
            (strip as! CardStrip<EntryCell>).setConfigure { [weak self] c, i in
                guard let self, i < self.entries.count else { return }
                c.configure(self.entries[i], rank: ranked && i < 10 ? i + 1 : nil, tricolour: self.tricolour, ctx: ctx)
            }
        case .otts:
            (strip as! CardStrip<OttCell>).setConfigure { [weak self] c, i in
                guard let self, i < self.otts.count else { return }
                let o = self.otts[i]
                c.configure(o, site: ctx.api.session.site)
                c.onOpen = { ctx.open("/ott/\(o.id)") }
            }
        case .cast:
            (strip as! CardStrip<CastCell>).setConfigure { [weak self] c, i in
                guard let self, i < self.people.count else { return }
                let p = self.people[i]
                c.configure(p, art: ctx.art)
                c.onOpen = { if let id = p.Id { ctx.open("/person/\(id)") } }
            }
        }
        if case .posters = kind {
            (strip as! CardStrip<PosterCell>).prefetch = { [weak self] r in
                guard let self else { return }
                let urls = r.compactMap { $0 < self.items.count ? ctx.art.poster(self.items[$0], width: 368) : nil }
                ImagePipeline.shared.prefetch(urls, pixels: Int(PosterCell.width * 1.5 * 2))
            }
        }
    }

    private func reload(_ count: Int) {
        strip.setCount(count)
        isHidden = count == 0
        updateArrows(animated: false)
    }

    /// Re-applies shared state (statuses, My List) to the cards on screen.
    func refreshCards() { strip.reloadVisible() }

    /// Asks the strip to create or recycle cells for what is now on screen.
    func refreshVisibility() { strip.refresh() }

    var height: CGFloat { RowView.headerHeight + strip.cellHeight + 8 }

    override func layout() {
        super.layout()
        let inset = RowView.inset
        let size = heading.fitSize
        // The pill is 0.95em tall beside the 25.6 pt title, 10 pt before it.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pill.bounds = CGRect(x: 0, y: 0, width: 5, height: 24)
        pill.position = CGPoint(x: inset + 2.5, y: 20)
        pill.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        CATransaction.commit()
        var right = bounds.width - inset
        if let seeAll {
            let s = seeAll.fitSize
            seeAll.frame = NSRect(x: right - s.width, y: 20 - s.height / 2, width: s.width, height: s.height)
            right = seeAll.frame.minX - 12
        }
        heading.frame = NSRect(x: inset + 15, y: 20 - size.height / 2, width: min(size.width, right - inset - 15), height: size.height)
        // The strip reaches above and below its cards (see CardStrip.padTop),
        // so a hovered card and its shadow are never clipped. The cards stay put.
        strip.frame = NSRect(x: 0, y: RowView.headerHeight - Self.padTop, width: bounds.width,
                             height: strip.cellHeight + Self.padTop + Self.padBottom)
        // Arrows: 40 pt, 8 pt in from the edges, centred on the cards.
        let mid = RowView.headerHeight + strip.cellHeight / 2 - 20
        prev.frame = NSRect(x: 8, y: mid, width: 40, height: 40)
        next.frame = NSRect(x: bounds.width - 48, y: mid, width: 40, height: 40)
        updateArrows(animated: false)
    }

    // MARK: Hover and arrows

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        Hover.enter(self, area: { [unowned self] in self.bounds },
                    begin: { [weak self] in self?.hovered = true; self?.updateArrows(animated: true) },
                    end: { [weak self] in self?.hovered = false; self?.updateArrows(animated: true) })
    }
    override func mouseExited(with event: NSEvent) { Hover.exit(self) }

    /// Shown only while the row is hovered, and only toward where there is more.
    private func updateArrows(animated: Bool) {
        let (canLeft, canRight) = strip.scrollable
        let l: CGFloat = hovered && canLeft ? 1 : 0, r: CGFloat = hovered && canRight ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.2
                prev.animator().alphaValue = l
                next.animator().alphaValue = r
            }
        } else {
            prev.alphaValue = l
            next.alphaValue = r
        }
    }

    // MARK: Reveal

    /// The first time the row is in view (and has something in it): it rises
    /// 24 pt and fades in, the pill springs up, and the first eight cards are
    /// dealt in after it (globals.css `.reveal`, `.row-pill`, `card-deal`).
    func revealIfNeeded(viewportBottom: CGFloat, viewportTop: CGFloat, in document: NSView) {
        // Laid out, and actually overlapping the window.
        guard !revealed, !isHidden, frame.height > 0,
              frame.minY < viewportBottom, frame.maxY > viewportTop else { return }
        revealed = true
        guard let layer else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 24
        rise.toValue = 0
        rise.duration = 0.62
        rise.timingFunction = Theme.expoOut
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.52
        fade.timingFunction = Theme.expoOut
        layer.add(rise, forKey: "reveal-rise")
        layer.add(fade, forKey: "reveal-fade")

        let grow = CABasicAnimation(keyPath: "transform.scale.y")
        grow.fromValue = 0
        grow.toValue = 1
        grow.duration = 0.6
        grow.beginTime = CACurrentMediaTime() + 0.08
        grow.fillMode = .backwards
        grow.timingFunction = Theme.spring
        pill.add(grow, forKey: "pill")

        for (n, cell) in strip.visibleCells.prefix(8).enumerated() {
            guard let l = cell.layer else { continue }
            let b = cell.bounds
            let deal = CAAnimationGroup()
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = PillButton.lift(b, dy: 18, scale: 0.96)
            move.toValue = CATransform3DIdentity
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0
            show.toValue = 1
            deal.animations = [move, show]
            deal.duration = 0.52
            deal.timingFunction = Theme.expoOut
            deal.beginTime = CACurrentMediaTime() + 0.03 + 0.045 * Double(n)
            deal.fillMode = .backwards
            l.add(deal, forKey: "deal")
        }
    }
}

/// "See all ›" (Row.tsx): a bordered pill; on hover the border and text take
/// the accent and the chevron steps 2 pt right.
final class SeeAllButton: FlippedView {
    private let label = makeLabel("See all", font: Theme.text(12.5, .semibold), color: Theme.palette.ink.withAlphaComponent(0.75))
    private let chevron = CAShapeLayer()
    var action: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.borderWidth = 1
        layer?.borderColor = Theme.palette.glassBorder.cgColor
        addSubview(label)
        chevron.path = PillButton.path(.chevronRight, 13)
        chevron.fillColor = nil
        chevron.lineWidth = 1.7
        chevron.lineCap = .round
        chevron.lineJoin = .round
        layer?.addSublayer(chevron)
        restyle(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var fitSize: NSSize {
        let t = label.fitSize
        return NSSize(width: 12 + t.width + 4 + 13 + 12, height: max(26, t.height + 8))
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let t = label.fitSize
        label.frame = NSRect(x: 12, y: (bounds.height - t.height) / 2, width: t.width, height: t.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        chevron.frame = CGRect(x: 12 + t.width + 4, y: (bounds.height - 13) / 2, width: 13, height: 13)
        CATransaction.commit()
    }

    private func restyle(animated: Bool) {
        let p = Theme.palette
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.15 : 0)
        CATransaction.setAnimationTimingFunction(Theme.standard)
        layer?.borderColor = (hovering ? p.accent.withAlphaComponent(0.5) : p.glassBorder).cgColor
        chevron.strokeColor = (hovering ? p.accent : p.ink.withAlphaComponent(0.75)).cgColor
        chevron.setAffineTransform(hovering ? CGAffineTransform(translationX: 2, y: 0) : .identity)
        CATransaction.commit()
        label.textColor = hovering ? p.accent : p.ink.withAlphaComponent(0.75)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        Hover.enter(self, area: { [unowned self] in self.bounds },
                    begin: { [weak self] in self?.hovering = true; self?.restyle(animated: true) },
                    end: { [weak self] in self?.hovering = false; self?.restyle(animated: true) })
    }
    override func mouseExited(with event: NSEvent) { Hover.exit(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { layer?.transform = PillButton.lift(bounds, dy: 0, scale: 0.97) }
    override func mouseUp(with event: NSEvent) {
        layer?.transform = CATransform3DIdentity
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// The round glass arrow on a row's edge (`.nudge-btn .glass-dark`, 40 pt):
/// grows to 1.12 on hover on a spring, presses to 0.9.
final class NudgeButton: FlippedView {
    private let chevron = CAShapeLayer()
    var action: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false

    init(direction: Int, diameter: CGFloat = 40, icon: CGFloat = 18) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        let p = Theme.palette
        layer?.backgroundColor = p.panel.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.glassBorder.cgColor
        layer?.cornerRadius = diameter / 2
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 17
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        chevron.path = PillButton.path(direction < 0 ? .chevronLeft : .chevronRight, icon)
        chevron.strokeColor = p.ink.cgColor
        chevron.fillColor = nil
        chevron.lineWidth = 2
        chevron.lineCap = .round
        chevron.lineJoin = .round
        chevron.frame = CGRect(x: (diameter - icon) / 2, y: (diameter - icon) / 2, width: icon, height: icon)
        layer?.addSublayer(chevron)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func scale(_ s: CGFloat, duration: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Theme.spring)
        layer?.transform = PillButton.lift(bounds, dy: 0, scale: s)
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
        Hover.enter(self, area: { [unowned self] in self.bounds },
                    begin: { [weak self] in self?.hovering = true; self?.scale(1.12, duration: 0.22) },
                    end: { [weak self] in self?.hovering = false; self?.scale(1, duration: 0.22) })
    }
    override func mouseExited(with event: NSEvent) { Hover.exit(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.05 ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) { scale(0.9, duration: 0.12) }
    override func mouseUp(with event: NSEvent) {
        scale(hovering ? 1.12 : 1, duration: 0.22)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The parts of CardStrip a RowView drives, whatever its cell type.
protocol RowStrip: AnyObject {
    func setCount(_ n: Int)
    func refresh()
    func reloadVisible()
    func page(_ direction: Int)
    var cellHeight: CGFloat { get }
    /// Whether there is more to the left and to the right (8 pt of slack).
    var scrollable: (Bool, Bool) { get }
    var visibleCells: [NSView] { get }
    var onScroll: (() -> Void)? { get set }
}

extension CardStrip: RowStrip {
    func setCount(_ n: Int) { count = n }
    func page(_ direction: Int) { scrollBy(pages: direction) }
    var cellHeight: CGFloat { cellSize.height }
}
