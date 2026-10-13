import AppKit

/*
 * "See all" (Mahfin's /discover/browse/[feed]): a grid of discover cards, a
 * page of the feed at a time. The web page asks for "Load more"; here the next
 * page simply arrives as the grid nears its end. Only the cards on screen
 * exist, recycled as the grid scrolls.
 */
@MainActor
final class BrowseScreen: ScreenView {
    static let feeds: [String: (type: String, title: String)] = [
        "popular-movies": ("movies", "Popular Movies"),
        "popular-shows": ("tv", "Popular Shows"),
        "trending": ("trending", "Trending Movies and Shows"),
        "in-cinemas-soon": ("upcoming", "In cinemas soon"),
        "on-streaming-soon": ("upcoming-tv", "In OTTs soon"),
        "top-rated-films": ("top-rated", "Highest rated films"),
        "top-rated-shows": ("top-rated-tv", "Highest rated shows"),
        "on-the-way": ("coming-soon", "Soon on Mahfin"),
        "my-requests": ("arrived", "Request Landed"),
        "indian-otts": ("indian-ott", "Indian OTTs"),
    ]

    private let feed: String
    private let heading = makeLabel(font: Theme.display(36, .heavy), color: Theme.palette.ink)
    private let empty = makeLabel(font: Theme.text(15), color: Theme.palette.muted)
    private var items: [DiscoverItem] = []
    private var page = 0
    private var totalPages = 1
    private var loading = false
    private var live: [Int: DiscoverCell] = [:]
    private var pool: [DiscoverCell] = []
    private var columns = 6
    private var cell = DiscoverCell.size
    private let gapX: CGFloat = 16, gapY: CGFloat = 28
    private let top: CGFloat = 64 + 40 + 56

    init(feed: String, ctx: NativeContext) {
        self.feed = feed
        super.init(route: .browse(feed: feed), ctx: ctx)
        heading.stringValue = BrowseScreen.feeds[feed]?.title ?? "There is no such section."
        document.addSubview(heading)
        empty.stringValue = "Nothing to show — Seerr may be unreachable."
        empty.isHidden = true
        document.addSubview(empty)
        NotificationCenter.default.addObserver(self, selector: #selector(gridScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        ctx.onChange { [weak self] in self?.reconfigureVisible() }
        loadMore()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func loadMore() {
        guard !loading, page < min(totalPages, 500), let type = BrowseScreen.feeds[feed]?.type else { return }
        loading = true
        let next = page + 1
        let api = ctx.api
        Task { [weak self] in
            await api.load(DiscoverPage.self, .mahfin, "/api/discover", ["type": type, "page": String(next)]) { p in
                guard let self else { return }
                // The first page may be delivered twice (kept, then fresh).
                if next == 1 { self.items = p.items } else if self.page < next { self.items += p.items }
                self.page = max(self.page, next)
                self.totalPages = p.totalPages ?? 1
                self.empty.isHidden = !self.items.isEmpty
                self.needsLayout = true
                self.layoutCells()
            }
            self?.loading = false
        }
    }

    override func layoutDocument(width: CGFloat) {
        let inset = RowView.inset
        heading.frame = NSRect(x: inset, y: 64 + 32, width: width - inset * 2, height: 44)
        empty.frame = NSRect(x: inset, y: top, width: width - inset * 2, height: 20)
        // As many columns of roughly the row card's width as fit, 2 to 7.
        columns = max(2, min(7, Int((width - inset * 2 + gapX) / (PosterCell.width + gapX))))
        let w = floor((width - inset * 2 - gapX * CGFloat(columns - 1)) / CGFloat(columns))
        cell = NSSize(width: w, height: w * 1.5 + 46)
        let rowsCount = Int(ceil(Double(items.count) / Double(columns)))
        let h = top + CGFloat(rowsCount) * (cell.height + gapY) + 80
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(h, scroll.contentView.bounds.height))
        for (_, c) in live { c.removeFromSuperview(); pool.append(c) }
        live.removeAll()
        layoutCells()
    }

    private func frame(for i: Int) -> NSRect {
        let r = i / columns, c = i % columns
        return NSRect(x: RowView.inset + CGFloat(c) * (cell.width + gapX), y: top + CGFloat(r) * (cell.height + gapY),
                      width: cell.width, height: cell.height)
    }

    @objc private func gridScrolled() { layoutCells() }

    /// Creates the cells on screen (and a row either side), recycles the rest,
    /// and asks for the next page when the end comes into view.
    private func layoutCells() {
        guard !items.isEmpty, columns > 0 else { return }
        let vis = scroll.contentView.bounds
        let rowH = cell.height + gapY
        let firstRow = max(0, Int((vis.minY - top) / rowH) - 1)
        let lastRow = Int((vis.maxY - top) / rowH) + 1
        let first = firstRow * columns
        let last = min(items.count - 1, (lastRow + 1) * columns - 1)
        for (i, c) in live where i < first || i > last {
            c.removeFromSuperview(); pool.append(c); live[i] = nil
        }
        if first <= last {
            for i in first...last where live[i] == nil {
                let c = pool.popLast() ?? DiscoverCell(frame: .zero)
                c.frame = frame(for: i)
                configure(c, i)
                document.addSubview(c)
                live[i] = c
            }
        }
        if last >= items.count - columns * 2 { loadMore() }
    }

    private func configure(_ c: DiscoverCell, _ i: Int) {
        let item = items[i]
        c.configure(item, rank: nil, status: ctx.status(item), saved: ctx.saved.contains(item.key))
        c.onOpen = { [weak self] in self?.ctx.openDiscover(item) }
        c.onSave = { [weak self] in self?.ctx.toggleSaved(item) }
        c.onRequest = { [weak self] in self?.ctx.openDiscover(item) }
    }

    private func reconfigureVisible() {
        for (i, c) in live where i < items.count { configure(c, i) }
    }
}
