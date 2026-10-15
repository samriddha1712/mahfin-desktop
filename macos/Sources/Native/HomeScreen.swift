import AppKit

/*
 * Mahfin's home page (src/app/(app)/page.tsx, the top-bar shell), natively.
 * Same rows, same order, same requests; each row loads on its own, from its
 * kept copy first, and a row with nothing in it takes no space.
 */
@MainActor
final class HomeScreen: ScreenView {
    private let hero: HeroView
    private let mood: MoodStrip
    private let glow = AmbientGlow()
    private var order: [NSView] = []
    private var loaded = false

    private static let cardFields = "PrimaryImageAspectRatio,MediaSourceCount,ProviderIds"
    private static let heroFields = "Overview,Genres,PrimaryImageAspectRatio,MediaSourceCount,ProviderIds"

    // The rows, in the web page's order.
    private lazy var resume = RowView(title: "Continue watching", kind: .wide, ctx: ctx)
    private lazy var nextUp = RowView(title: "Next up", kind: .wide, ctx: ctx)
    private lazy var editors = RowView(title: "Editor's pick", kind: .entries(ranked: false), ctx: ctx)
    private lazy var talk = RowView(title: "Talk of the town", kind: .entries(ranked: false), ctx: ctx)
    private lazy var landed = RowView(title: "Request Landed", kind: .entries(ranked: false), seeAll: "/discover/browse/my-requests", ctx: ctx)
    private lazy var soon = RowView(title: "Soon on Mahfin", kind: .entries(ranked: false), seeAll: "/discover/browse/on-the-way", ctx: ctx)
    private lazy var leaving = RowView(title: "Leaving Mahfin", kind: .posters, ctx: ctx)
    private lazy var trending = RowView(title: "Trending Movies and Shows", kind: .entries(ranked: true), seeAll: "/discover/browse/trending", ctx: ctx)
    private lazy var indian = RowView(title: "Indian OTTs", kind: .entries(ranked: true), seeAll: "/discover/browse/indian-otts", ctx: ctx)
    private lazy var popularMovies = RowView(title: "Popular Movies", kind: .entries(ranked: false), seeAll: "/discover/browse/popular-movies", ctx: ctx)
    private lazy var popularShows = RowView(title: "Popular Shows", kind: .entries(ranked: false), seeAll: "/discover/browse/popular-shows", ctx: ctx)
    private var latest: [RowView] = []
    private lazy var because0 = RowView(title: "Because you watched", kind: .entries(ranked: false), ctx: ctx)
    private lazy var cinemas = RowView(title: "In cinemas soon", kind: .entries(ranked: false), seeAll: "/discover/browse/in-cinemas-soon", ctx: ctx)
    private lazy var otts = RowView(title: "In OTTs soon", kind: .entries(ranked: false), seeAll: "/discover/browse/on-streaming-soon", ctx: ctx)
    private lazy var because1 = RowView(title: "Because you watched", kind: .entries(ranked: false), ctx: ctx)
    private lazy var topRated = RowView(title: "Highest rated films", kind: .entries(ranked: false), seeAll: "/discover/browse/top-rated-films", ctx: ctx)
    private lazy var myList = RowView(title: "WatchList", kind: .posters, seeAll: "/watchlist", ctx: ctx)
    private lazy var ottRow = RowView(title: "OTTs", kind: .otts, ctx: ctx)

    init(ctx: NativeContext) {
        hero = HeroView(ctx: ctx)
        mood = MoodStrip(ctx: ctx)
        super.init(route: .home, ctx: ctx)
        indian.tricolour = true
        // Under the scroll view, fixed to the window, as the web's fixed layer.
        layer?.insertSublayer(glow, at: 0)
        hero.onTint = { [weak self] c in self?.glow.tint(c) }
        document.addSubview(hero)
        rebuildOrder()
        load()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func rebuildOrder() {
        let before: [NSView] = [resume, nextUp, editors, talk, landed, soon, leaving, mood, trending, indian, popularMovies, popularShows]
        let after: [NSView] = [because0, cinemas, otts, because1, topRated, myList, ottRow]
        order = before + latest + after
        for v in order where v.superview == nil {
            v.isHidden = true
            document.addSubview(v)
        }
        rows = order.compactMap { $0 as? RowView }
        mood.isHidden = false
        needsLayout = true
    }

    override func scrolled(to y: CGFloat) {
        hero.setScrollProgress(y / max(1, hero.frame.height))
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }

    override func layoutDocument(width: CGFloat) {
        let viewport = scroll.contentView.bounds.height
        let heroHeight = max(480, (viewport * 0.78).rounded())
        hero.frame = NSRect(x: 0, y: 0, width: width, height: heroHeight)
        // The rows ride up over the hero's last 24 points, as on the web.
        let bottom = stack(order, from: heroHeight - 24, width: width, gap: 40) { v in
            (v as? RowView)?.height ?? (v as? MoodStrip)?.height(for: width) ?? 0
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(bottom + 120, viewport))
    }

    override func activate() {
        super.activate()
        hero.setActive(true)
        if loaded { load() }   // back on the page: bring it up to date quietly
    }

    override func deactivate() { hero.setActive(false) }

    // MARK: Loading

    /// New data: lay the page out again. The rows' reveals are checked in
    /// that layout, against their real positions — checking here, before it,
    /// saw every newly filled row at y = 0 and revealed all twenty at launch,
    /// off-screen, so none ever rose into view.
    private func rowsChanged() {
        needsLayout = true
    }

    private func load() {
        loaded = true
        let api = ctx.api
        let uid = api.session.userId
        let fields = HomeScreen.cardFields

        // The last picks at once, then fresh ones (retried: a hero left empty
        // by one failed request at launch stayed empty for the visit).
        if hero.items.isEmpty, let kept = ctx.api.kept([JFItem].self, as: "hero") { hero.set(kept) }
        Task { [weak self] in
            for attempt in 0..<3 {
                guard let self else { return }
                if await self.loadHero() { return }
                try? await Task.sleep(nanoseconds: UInt64(3 + attempt * 5) * 1_000_000_000)
            }
        }

        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "UserItems/Resume", [
                "userId": uid, "limit": "32", "fields": fields, "mediaTypes": "Video",
                "enableImageTypes": "Primary,Backdrop,Thumb",
            ]) { r in
                var seen = Set<String>()
                let items = r.Items.filter { seen.insert(($0.isEpisode ? $0.SeriesId : $0.Id) ?? $0.Id).inserted }
                self?.resume.items = Array(items.prefix(16))
                self?.rowsChanged()
            }
        }
        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "Shows/NextUp", [
                "userId": uid, "limit": "16", "fields": fields, "enableImageTypes": "Primary,Backdrop,Thumb",
            ]) { r in
                self?.nextUp.items = r.Items
                self?.rowsChanged()
            }
        }
        Task { [weak self] in
            await api.load(CuratedView.self, .mahfin, "/api/curated") { c in
                guard let self else { return }
                self.editors.setTitle(c.heading ?? "Editor's pick")
                self.editors.entries = (c.picks ?? []).map(CardEntry.discover)
                self.talk.entries = (c.talk ?? []).prefix(12).map(CardEntry.discover)
                self.rowsChanged()
            }
        }
        feed("arrived", into: landed)
        feed("coming-soon", into: soon)
        feed("trending", into: trending)
        feed("indian-ott", into: indian)
        feed("movies", into: popularMovies)
        feed("tv", into: popularShows)
        feed("upcoming", into: cinemas)
        feed("upcoming-tv", into: otts)
        feed("top-rated", into: topRated)

        Task { [weak self] in
            await api.load(LeavingList.self, .mahfin, "/api/leaving") { list in
                guard let self else { return }
                let ids = Array(Set(list.items.map(\.cardItemId)))
                guard !ids.isEmpty else { self.leaving.items = []; self.rowsChanged(); return }
                Task { [weak self] in
                    await api.load(JFItems.self, .jellyfin, "Items", [
                        "userId": uid, "ids": ids.joined(separator: ","), "fields": fields, "enableImageTypes": "Primary",
                    ]) { r in
                        let byId = Dictionary(r.Items.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
                        var seen = Set<String>()
                        self?.leaving.items = list.items.compactMap { e in
                            seen.insert(e.cardItemId).inserted ? byId[e.cardItemId] : nil
                        }
                        self?.rowsChanged()
                    }
                }
            }
        }
        Task { [weak self] in
            await api.load(BecauseRows.self, .mahfin, "/api/discover/because") { b in
                guard let self else { return }
                for (row, i) in [(self.because0, 0), (self.because1, 1)] {
                    guard i < b.rows.count else { row.entries = []; continue }
                    row.setTitle("Because you watched \(b.rows[i].seed.name ?? "")")
                    row.entries = b.rows[i].items.map { $0.library.map(CardEntry.library) ?? .discover($0.discover) }
                }
                self.rowsChanged()
            }
        }
        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "Items", [
                "userId": uid, "recursive": "true", "filters": "IsFavorite", "includeItemTypes": "Movie,Series,Episode",
                "sortBy": "DateCreated", "sortOrder": "Descending", "limit": "16", "fields": fields,
            ]) { r in
                self?.myList.items = r.Items
                self?.rowsChanged()
            }
        }
        Task { await loadLatest() }
        Task { [weak self] in await self?.loadOtts() }
    }

    /// Platforms this library carries anything from (`useOttCounts`), in order.
    private func loadOtts() async {
        let api = ctx.api
        let uid = api.session.userId
        let counts = await withTaskGroup(of: (String, Int).self) { group in
            for o in Ott.all {
                group.addTask {
                    let r = try? await api.fetch(JFItems.self, .jellyfin, "Items", [
                        "userId": uid, "recursive": "true", "studios": o.aliases.joined(separator: "|"),
                        "includeItemTypes": "Movie,Series", "limit": "0",
                    ])
                    return (o.id, r?.TotalRecordCount ?? 0)
                }
            }
            var out: [String: Int] = [:]
            for await (id, n) in group { out[id] = n }
            return out
        }
        ottRow.otts = Ott.all.filter { (counts[$0.id] ?? 0) > 0 }
        rowsChanged()
    }

    private func feed(_ type: String, into row: RowView) {
        let api = ctx.api
        Task { [weak self] in
            await api.load(DiscoverPage.self, .mahfin, "/api/discover", ["type": type]) { p in
                row.entries = p.items.map(CardEntry.discover)
                self?.rowsChanged()
            }
        }
    }

    /// "New in …", one row per film/show library, episodes shown as their show.
    private func loadLatest() async {
        let api = ctx.api
        let uid = api.session.userId
        guard let views = try? await api.fetch(JFItems.self, .jellyfin, "UserViews", ["userId": uid]) else { return }
        let kept = views.Items.filter { ["movies", "tvshows", "homevideos", "music", "musicvideos"].contains($0.CollectionType ?? "") }
        if latest.count != kept.count {
            latest.forEach { $0.removeFromSuperview() }
            latest = kept.map { v in
                RowView(title: "New in \(v.Name ?? "")", kind: .posters, seeAll: "/library/\(v.Id)", ctx: ctx)
            }
            rebuildOrder()
        }
        for (view, row) in zip(kept, latest) {
            await api.load([JFItem].self, .jellyfin, "Items/Latest", [
                "userId": uid, "parentId": view.Id, "limit": "32", "groupItems": "true",
                "fields": HomeScreen.cardFields, "enableImageTypes": "Primary,Backdrop,Thumb",
            ]) { [weak self] items in
                Task { await self?.resolveSeries(items, into: row) }
            }
        }
    }

    /// Swaps episodes and seasons for their show, as the web's `useLatest` does.
    private func resolveSeries(_ items: [JFItem], into row: RowView) async {
        let needs = Array(Set(items.filter { $0.isEpisode || $0.Type == "Season" }.compactMap(\.SeriesId)))
        var shows: [String: JFItem] = [:]
        if !needs.isEmpty, let r = try? await ctx.api.fetch(JFItems.self, .jellyfin, "Items", [
            "userId": ctx.api.session.userId, "ids": needs.joined(separator: ","), "fields": HomeScreen.cardFields,
            "enableImageTypes": "Primary,Backdrop,Thumb",
        ]) {
            shows = Dictionary(r.Items.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        var seen = Set<String>()
        row.items = items.compactMap { i -> JFItem? in
            let resolved = (i.isEpisode || i.Type == "Season") ? i.SeriesId.flatMap { shows[$0] } : i
            guard let r = resolved, seen.insert(r.Id).inserted else { return nil }
            return r
        }
        rowsChanged()
    }

    /// Seven titles, newest first, alternating films and shows (`heroQuery`).
    @discardableResult
    private func loadHero() async -> Bool {
        let api = ctx.api
        let uid = api.session.userId
        let now = ISO8601DateFormatter().string(from: Date())
        async let films = try? api.fetch(JFItems.self, .jellyfin, "Items", [
            "userId": uid, "recursive": "true", "includeItemTypes": "Movie", "sortBy": "PremiereDate",
            "sortOrder": "Descending", "maxPremiereDate": now, "limit": "24", "fields": HomeScreen.heroFields,
            "imageTypes": "Backdrop", "enableImageTypes": "Primary,Backdrop,Logo",
        ])
        async let episodes = try? api.fetch(JFItems.self, .jellyfin, "Items", [
            "userId": uid, "recursive": "true", "includeItemTypes": "Episode", "isMissing": "false",
            "sortBy": "PremiereDate", "sortOrder": "Descending", "maxPremiereDate": now, "limit": "150",
            "enableImages": "false", "enableUserData": "false",
        ])
        let (f, e) = await (films, episodes)
        var newest: [String: String] = [:]
        var seriesOrder: [String] = []
        for ep in e?.Items ?? [] {
            guard let sid = ep.SeriesId, newest[sid] == nil else { continue }
            newest[sid] = ep.PremiereDate ?? ""
            seriesOrder.append(sid)
        }
        var shows: [JFItem] = []
        if !seriesOrder.isEmpty, let s = try? await api.fetch(JFItems.self, .jellyfin, "Items", [
            "userId": uid, "ids": seriesOrder.prefix(16).joined(separator: ","), "fields": HomeScreen.heroFields,
            "enableImageTypes": "Primary,Backdrop,Logo",
        ]) {
            shows = s.Items.filter { !($0.BackdropImageTags ?? []).isEmpty }
                .sorted { (newest[$0.Id] ?? "") > (newest[$1.Id] ?? "") }
        }
        let movies = (f?.Items ?? []).filter { !($0.BackdropImageTags ?? []).isEmpty }
            .sorted { ($0.PremiereDate ?? "") > ($1.PremiereDate ?? "") }
        var picks: [JFItem] = []
        var a = movies[...], b = shows[...]
        // Start with whichever is newer, then alternate.
        var takeFilm = (movies.first?.PremiereDate ?? "") >= (shows.first.flatMap { newest[$0.Id] } ?? "")
        while picks.count < 7, !(a.isEmpty && b.isEmpty) {
            if takeFilm, let m = a.popFirst() { picks.append(m) } else if let s = b.popFirst() { picks.append(s) } else if let m = a.popFirst() { picks.append(m) }
            takeFilm.toggle()
        }
        guard !picks.isEmpty else { return false }
        ctx.api.keep(picks, as: "hero")
        hero.set(picks)
        return true
    }
}

/// "Browse by mood": the vibes as chips that wrap (lib/vibes.ts).
final class MoodStrip: FlippedView {
    private static let vibes: [(String, String)] = [
        ("mind_bending", "Twisty"), ("edge", "Thrilling"), ("feel_good", "Happy"), ("tearjerker", "Emotional"),
        ("funny", "Funny"), ("slow_burn", "Slow-paced"), ("thoughtful", "Thoughtful"), ("comfort", "Relaxing"),
        ("dark", "Dark"), ("horror", "Horror"), ("epic", "Epic"),
    ]
    private let heading = makeLabel("Browse by mood", font: Theme.display(25.6, .bold), color: Theme.palette.ink)
    private let pill = CALayer()
    private var chips: [PillButton] = []

    init(ctx: NativeContext) {
        super.init(frame: .zero)
        pill.backgroundColor = Theme.palette.accent.cgColor
        pill.cornerRadius = 2.5
        layer?.addSublayer(pill)
        addSubview(heading)
        chips = MoodStrip.vibes.map { id, label in
            let b = PillButton(label, style: .tinted(NSColor.white.withAlphaComponent(0.03), NSColor.white.withAlphaComponent(0.1),
                                                     Theme.palette.ink.withAlphaComponent(0.8)), height: 37, fontSize: 13.5)
            b.border = Theme.palette.glassBorder
            b.action = { ctx.open("/mood/\(id.replacingOccurrences(of: "_", with: "-"))") }
            addSubview(b)
            return b
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func height(for width: CGFloat) -> CGFloat {
        RowView.headerHeight + flow(width: width, apply: false) + 4
    }

    @discardableResult
    private func flow(width: CGFloat, apply: Bool) -> CGFloat {
        var x = RowView.inset, y: CGFloat = 0
        for c in chips {
            let w = c.intrinsicContentSize.width
            if x + w > width - RowView.inset { x = RowView.inset; y += 38 + 10 }
            if apply { c.frame = NSRect(x: x, y: RowView.headerHeight + y, width: w, height: 38) }
            x += w + 10
        }
        return y + 38
    }

    override func layout() {
        super.layout()
        pill.frame = CGRect(x: RowView.inset, y: 9, width: 5, height: 22)
        let s = heading.fitSize
        heading.frame = NSRect(x: RowView.inset + 14, y: 20 - s.height / 2, width: s.width, height: s.height)
        flow(width: bounds.width, apply: true)
    }
}

/// The page's ambient light (AmbientGlow.tsx): two soft ellipses of the hero's
/// colour near the top of the window, breathing over 14 s. Drawn into an image
/// once per colour — upright wherever it sits, unlike a gradient layer.
final class AmbientGlow: CALayer {
    private var last: NSColor?

    override init() {
        super.init()
        contentsGravity = .resize
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1
        breathe.toValue = 1.09
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 1
        let g = CAAnimationGroup()
        g.animations = [breathe, fade]
        g.duration = 14
        g.autoreverses = true
        g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(g, forKey: "breathe")
        tint(Theme.rgb(0x503c8c))   // --t-ambient-rgb until a picture says otherwise
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func tint(_ c: NSColor) {
        guard c != last, let rgb = c.usingColorSpace(.sRGB) else { return }
        last = c
        let w = 320, h = 200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, alpha: CGFloat, stop: CGFloat) {
            let colors = [rgb.withAlphaComponent(alpha).cgColor, rgb.withAlphaComponent(0).cgColor] as CFArray
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, stop]) else { return }
            ctx.saveGState()
            // Bitmap y runs up: a point `cy` from the top is at h − cy.
            ctx.translateBy(x: cx, y: CGFloat(h) - cy)
            ctx.scaleBy(x: rx, y: ry)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
        }
        // ellipse 58% 34% at 50% 24% (0.34 → clear by 72%), and
        // ellipse 95% 26% at 50% 2% (0.16 → clear by 78%).
        ellipse(cx: CGFloat(w) * 0.5, cy: CGFloat(h) * 0.24, rx: CGFloat(w) * 0.58, ry: CGFloat(h) * 0.34, alpha: 0.34, stop: 0.72)
        ellipse(cx: CGFloat(w) * 0.5, cy: CGFloat(h) * 0.02, rx: CGFloat(w) * 0.95, ry: CGFloat(h) * 0.26, alpha: 0.16, stop: 0.78)
        contents = ctx.makeImage()
    }
}
