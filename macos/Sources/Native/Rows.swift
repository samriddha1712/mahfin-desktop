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

    func configure(_ entry: CardEntry, rank: Int?, ctx: NativeContext) {
        switch entry {
        case .library(let item):
            discover?.isHidden = true
            let c = poster ?? { let c = PosterCell(frame: bounds); addSubview(c); poster = c; return c }()
            c.isHidden = false
            c.frame = bounds
            c.configure(item, art: ctx.art)
            c.onOpen = { ctx.openItem(item) }
            c.onPicture = nil
        case .discover(let item):
            poster?.isHidden = true
            let c = discover ?? { let c = DiscoverCell(frame: bounds); addSubview(c); discover = c; return c }()
            c.isHidden = false
            c.frame = bounds
            c.configure(item, rank: rank, status: ctx.status(item), saved: ctx.saved.contains(item.key))
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

/// A row on a page: heading (accent pill, title, "See all", arrows) over a strip.
final class RowView: FlippedView {
    enum Kind { case posters, wide, entries(ranked: Bool), cast, otts }

    let kind: Kind
    private let heading = makeLabel(font: Theme.display(25.6, .bold), color: Theme.palette.ink)

    func setTitle(_ t: String) {
        guard heading.stringValue != t else { return }
        heading.stringValue = t
        needsLayout = true
    }
    private let pill = CALayer()
    private var seeAll: PillButton?
    private let prev = PillButton("", style: .outline, height: 34)
    private let next = PillButton("", style: .outline, height: 34)
    private let ctx: NativeContext
    private var strip: NSView & RowStrip
    static let headerHeight: CGFloat = 44
    static let inset: CGFloat = 40

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
        heading.stringValue = title
        pill.backgroundColor = Theme.palette.accent.cgColor
        pill.cornerRadius = 2.5
        layer?.addSublayer(pill)
        addSubview(heading)
        addSubview(strip)
        if let seeAll {
            let b = PillButton("See all", style: .outline, height: 30, fontSize: 13)
            b.icon = .chevronRight
            b.action = { ctx.open(seeAll) }
            addSubview(b)
            self.seeAll = b
        }
        prev.icon = .chevronLeft
        next.icon = .chevronRight
        prev.action = { [weak self] in self?.strip.page(-1) }
        next.action = { [weak self] in self?.strip.page(1) }
        addSubview(prev)
        addSubview(next)
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
                c.configure(self.entries[i], rank: ranked && i < 10 ? i + 1 : nil, ctx: ctx)
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
    }

    /// Re-applies shared state (statuses, My List) to the cards on screen.
    func refreshCards() { strip.reloadVisible() }

    /// Asks the strip to create or recycle cells for what is now on screen.
    func refreshVisibility() { strip.refresh() }

    var height: CGFloat { RowView.headerHeight + strip.cellHeight + 8 }
    private static let padTop: CGFloat = 16, padBottom: CGFloat = 28

    override func layout() {
        super.layout()
        let inset = RowView.inset
        pill.frame = CGRect(x: inset, y: 9, width: 5, height: 22)
        let size = heading.fitSize
        heading.frame = NSRect(x: inset + 14, y: 20 - size.height / 2, width: min(size.width, bounds.width - 300), height: size.height)
        var x = bounds.width - inset
        next.frame = NSRect(x: x - 34, y: 3, width: 34, height: 34)
        prev.frame = NSRect(x: x - 34 - 8 - 34, y: 3, width: 34, height: 34)
        x -= 34 + 8 + 34 + 14
        if let seeAll {
            seeAll.sizeToFit()
            seeAll.frame = NSRect(x: x - seeAll.frame.width, y: 5, width: seeAll.frame.width, height: 30)
        }
        // The strip reaches above and below its cards (see CardStrip.padTop),
        // overlapping the heading and the gap to the next row, so a hovered card
        // and its shadow are never clipped. The cards stay where they were.
        strip.frame = NSRect(x: 0, y: RowView.headerHeight - Self.padTop, width: bounds.width,
                             height: strip.cellHeight + Self.padTop + Self.padBottom)
    }
}

/// The parts of CardStrip a RowView drives, whatever its cell type.
protocol RowStrip: AnyObject {
    func setCount(_ n: Int)
    func refresh()
    func reloadVisible()
    func page(_ direction: Int)
    var cellHeight: CGFloat { get }
}

extension CardStrip: RowStrip {
    func setCount(_ n: Int) { count = n }
    func page(_ direction: Int) { scrollBy(pages: direction) }
    var cellHeight: CGFloat { cellSize.height }
}
