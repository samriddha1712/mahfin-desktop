import AppKit

/*
 * A title's page (Mahfin's src/app/(app)/item/[id]/page.tsx), natively: the
 * backdrop header, poster, logo or title, the ticket and meta lines, progress,
 * Play / Resume, WatchList and Mark watched, the overview, seasons and episodes,
 * the Mahfin Meter, cast, and "More like this". Play goes to the web player, as every Play does.
 */
@MainActor
final class ItemScreen: ScreenView {
    private let id: String
    private var item: JFItem?
    private let header = BackdropHeader()
    /// Hosts the drawn parts (poster, logo, ticket, progress) above the
    /// header: AppKit keeps subviews over loose layers, so these get a view.
    private let art = FlippedView()
    private let poster = RemoteImage()
    private let posterShadow = CALayer()
    private let logo = RemoteImage()
    private let titleLabel = makeLabel(font: Theme.display(48, .heavy), color: Theme.palette.ink, lines: 2)
    private let ticket = makeLabel(font: Theme.text(13, .semibold), color: Theme.palette.accent)
    private let ticketBox = CAShapeLayer()
    private let metaLabel = makeLabel(font: Theme.text(14), color: Theme.palette.muted)
    private let genresLabel = makeLabel(font: Theme.text(14), color: Theme.palette.muted)
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let progressLabel = makeLabel(font: Theme.text(12.5), color: Theme.palette.muted)
    private let play = PillButton("Play", style: .accent, height: 46, fontSize: 15)
    private let favorite = PillButton("WatchList", style: .glass, height: 46, fontSize: 15)
    private let watched = PillButton("Mark watched", style: .glass, height: 46, fontSize: 15)
    // The rest of the web page's row: each opens the web's own dialog over
    // this page (Collection, Download, Recommend) or flips a pick in place.
    private let collection = PillButton("Collection", style: .glass, height: 46, fontSize: 15)
    private let pick = PillButton("Pick", style: .glass, height: 46, fontSize: 15)
    private let download = PillButton("Download", style: .glass, height: 46, fontSize: 15)
    private let recommend = PillButton("Recommend", style: .glass, height: 46, fontSize: 15)
    /// A show partly here: the way to ask for the seasons that are not.
    private let requestSeasons = PillButton("Request seasons", style: .glass, height: 46, fontSize: 15)
    private var moreSeasons = false
    private var picked = false
    private var pickBusy = false
    private var pickFull = false
    /// The poster's colour at 16%, laid over WatchList's glass (the web tints it
    /// from the poster's blurhash).
    private var tint: NSColor?
    private let overview = makeLabel(font: Theme.text(15), color: Theme.palette.ink.withAlphaComponent(0.8), lines: 0)
    private let studios = makeLabel(font: Theme.text(13), color: Theme.palette.muted)
    private let episodes: EpisodesView
    private let meter: MeterView
    private lazy var cast = RowView(title: "Cast & crew", kind: .cast, ctx: ctx)
    private lazy var similar = RowView(title: "More like this", kind: .posters, ctx: ctx)
    private var ready = true

    init(id: String, ctx: NativeContext) {
        self.id = id
        episodes = EpisodesView(ctx: ctx)
        meter = MeterView(ctx: ctx)
        super.init(route: .item(id: id), ctx: ctx)
        document.addSubview(header)
        document.addSubview(art)
        poster.layer.cornerRadius = 16
        poster.layer.cornerCurve = .continuous
        posterShadow.shadowColor = NSColor.black.cgColor
        posterShadow.shadowOpacity = 0.6
        posterShadow.shadowRadius = 30
        posterShadow.shadowOffset = CGSize(width: 0, height: -20)
        art.layer?.addSublayer(posterShadow)
        art.layer?.addSublayer(poster.layer)
        logo.layer.contentsGravity = .resizeAspect
        logo.onLoad = { [weak self] in self?.needsLayout = true }
        art.layer?.addSublayer(logo.layer)
        ticket.isHidden = true
        ticketBox.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        ticketBox.strokeColor = Theme.palette.accent.withAlphaComponent(0.5).cgColor
        ticketBox.lineDashPattern = [3, 2]
        art.layer?.addSublayer(ticketBox)
        progressTrack.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        progressTrack.cornerRadius = 2
        progressFill.backgroundColor = Theme.palette.accent.cgColor
        progressFill.cornerRadius = 2
        progressTrack.addSublayer(progressFill)
        art.layer?.addSublayer(progressTrack)
        for v in [titleLabel, ticket, metaLabel, genresLabel, progressLabel, overview, studios] as [NSView] { document.addSubview(v) }
        play.icon = .play
        for b in [play, favorite, watched] { b.radius = 12 }
        poster.onLoad = { [weak self] in
            guard let self, let img = self.poster.layer.contents as! CGImage? else { return }
            self.tint = ImagePipeline.average(img)
            self.refreshButtons()
        }
        favorite.icon = .plus
        watched.icon = .check
        collection.svgIcon = WebIcon.addSquare
        pick.svgIcon = WebIcon.sparkle
        download.svgIcon = WebIcon.download
        recommend.svgIcon = WebIcon.star
        requestSeasons.icon = .plus
        for b in [collection, pick, download, recommend, requestSeasons] { b.radius = 12 }
        for b in actionButtons { document.addSubview(b) }
        document.addSubview(episodes)
        document.addSubview(meter)
        meter.onHeight = { [weak self] in self?.needsLayout = true }
        document.addSubview(cast)
        document.addSubview(similar)
        rows = [cast, similar]
        play.action = { [weak self] in
            guard let self, self.ready else { return }
            ctx.play(self.id)
        }
        favorite.action = { [weak self] in self?.toggleFavorite() }
        collection.action = { [weak self] in self?.dialog("collection") }
        download.action = { [weak self] in self?.dialog("download") }
        recommend.action = { [weak self] in self?.dialog("recommend") }
        requestSeasons.action = { [weak self] in self?.dialog("request") }
        pick.action = { [weak self] in self?.togglePick() }
        ctx.onChange { [weak self] in self?.refreshButtons(); self?.loadPick() }
        watched.action = { [weak self] in self?.toggleWatched() }
        load()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Web order: Play, WatchList, Request seasons, Collection, Watched, Pick, Download, Recommend.
    private var actionButtons: [PillButton] { [play, favorite, requestSeasons, collection, watched, pick, download, recommend] }

    /// Whether Seerr has seasons of this show it has neither got nor been
    /// asked for (Mahfin's `hasMoreSeasons`: status 3, 4 and 5 are settled).
    private func loadMoreSeasons() {
        guard let item, item.isSeries, let tmdb = item.tmdbId else { moreSeasons = false; return }
        let api = ctx.api
        Task { [weak self] in
            struct Details: Codable { struct S: Codable { var seasonNumber: Int; var status: Int? }; var seasons: [S]? }
            await api.load(Details.self, .mahfin, "/api/discover/details", ["type": "tv", "id": String(tmdb)]) { d in
                guard let self else { return }
                self.moreSeasons = (d.seasons ?? []).contains { $0.seasonNumber > 0 && ![3, 4, 5].contains($0.status ?? 0) }
                self.refreshButtons()
            }
        }
    }

    private func dialog(_ kind: String) {
        ctx.openDialog?("\(kind):\(id)")
    }

    /// Editor's pick: only for an administrator, only for a title with a TMDB id.
    private func loadPick() {
        guard ctx.isAdmin, let item, let key = MeterView.key(for: item), !key.hasPrefix("jf:") else { return }
        let api = ctx.api
        Task { [weak self] in
            struct Curated: Codable { var pickedKeys: [String] }
            await api.load(Curated.self, .mahfin, "/api/curated") { c in
                guard let self, !self.pickBusy else { return }
                self.picked = c.pickedKeys.contains(key)
                self.refreshButtons()
            }
        }
    }

    private func togglePick() {
        guard let item, let key = MeterView.key(for: item), !pickBusy else { return }
        let on = !picked
        pickBusy = true
        picked = on
        pickFull = false
        refreshButtons()
        let api = ctx.api
        let body: [String: Any] = on
            ? ["action": "add", "key": key, "title": item.Name ?? "", "year": item.ProductionYear.map { String($0) } ?? NSNull()]
            : ["action": "remove", "key": key]
        Task { [weak self] in
            do {
                try await api.send(.mahfin, "POST", "/api/curated", json: body)
                self?.pickBusy = false
            } catch {
                guard let self else { return }
                self.pickBusy = false
                self.picked = !on
                // 409: the list is full (the web's "List full").
                self.pickFull = (error as? MahfinAPI.Failure)?.status == 409
                self.refreshButtons()
            }
        }
    }

    override func activate() {
        super.activate()
        load()   // progress and watched state may have changed in the player
    }

    private func load() {
        let api = ctx.api
        let uid = api.session.userId
        let id = self.id
        Task { [weak self] in
            await api.load(JFItem.self, .jellyfin, "Items/\(id)", ["userId": uid]) { item in
                self?.apply(item)
            }
        }
        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "Items/\(id)/Similar", [
                "userId": uid, "limit": "14", "fields": "PrimaryImageAspectRatio,MediaSourceCount,ProviderIds",
            ]) { r in
                self?.similar.items = r.Items
                self?.needsLayout = true
            }
        }
        Task { [weak self] in
            struct Readiness: Codable { struct R: Codable { var ready: Bool? }; var items: [String: R]? }
            if let r = try? await api.fetch(Readiness.self, .mahfin, "/api/media/readiness", ["ids": id]) {
                self?.setReady(r.items?[id]?.ready ?? true)
            }
        }
    }

    private func setReady(_ ok: Bool) {
        ready = ok
        refreshButtons()
        if !ok {
            // Polled, as the web page does, until the file is complete.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.window != nil else { return }
                self.load()
            }
        }
    }

    private func apply(_ item: JFItem) {
        self.item = item
        let art = ctx.art
        let scale = window?.backingScaleFactor ?? 2
        header.image.load(art.backdrop(item, width: 1920), points: max(bounds.width, 1280), scale: scale)
        poster.load(art.poster(item, width: 480), points: 312, scale: scale)
        let logoURL = art.logo(item, width: 680)
        logo.load(logoURL, points: 340, scale: scale)
        logo.layer.isHidden = logoURL == nil
        titleLabel.isHidden = logoURL != nil
        titleLabel.stringValue = item.Name ?? ""
        if let r = item.CommunityRating, r > 0 {
            ticket.stringValue = "★ " + String(format: "%.1f", r)
            ticket.isHidden = false
        } else { ticket.isHidden = true }
        var meta: [String] = []
        if let y = item.ProductionYear { meta.append(String(y)) }
        if item.isSeries, let c = item.ChildCount { meta.append("\(c) season\(c == 1 ? "" : "s")") }
        else if let r = item.runtimeText { meta.append(r) }
        if let o = item.OfficialRating { meta.append(o) }
        metaLabel.stringValue = meta.joined(separator: " · ")
        genresLabel.stringValue = (item.Genres ?? []).prefix(3).joined(separator: " · ")
        overview.stringValue = item.Overview ?? ""
        studios.stringValue = (item.Studios ?? []).prefix(3).compactMap(\.Name).joined(separator: " · ")
        if let p = item.progress, let left = CardText.timeLeft(item) {
            progressTrack.isHidden = false
            progressLabel.isHidden = false
            progressLabel.stringValue = left
            progressFill.frame = CGRect(x: 0, y: 0, width: 320 * p, height: 4)
        } else {
            progressTrack.isHidden = true
            progressLabel.isHidden = true
        }
        cast.people = Array((item.People ?? []).prefix(20))
        meter.show(for: item)
        loadPick()
        loadMoreSeasons()
        if item.isSeries || item.isEpisode {
            episodes.isHidden = false
            episodes.load(seriesId: item.isSeries ? item.Id : (item.SeriesId ?? item.Id),
                          seriesName: item.SeriesName, current: item.isEpisode ? item : nil)
            episodes.onHeight = { [weak self] in self?.needsLayout = true }
        } else {
            episodes.isHidden = true
        }
        refreshButtons()
        needsLayout = true
    }

    private func refreshButtons() {
        guard let item else { return }
        play.title = !ready ? "Still downloading" : (item.progress != nil ? "Resume" : "Play")
        play.icon = ready ? .play : nil
        play.isEnabled = ready
        let fav = item.UserData?.IsFavorite == true
        favorite.title = fav ? "In WatchList" : "WatchList"
        favorite.icon = fav ? .check : .plus
        let p = Theme.palette
        if fav {
            // In the list: the accent words, no tint, no hover.
            favorite.style = .tinted(p.panel, p.panel, p.accent)
        } else if let tint {
            let rest = p.panel.blended(withFraction: 0.16, of: tint) ?? p.panel
            favorite.style = .tinted(rest, NSColor.white.withAlphaComponent(0.1), p.ink)
            favorite.border = p.glassBorder
        } else {
            favorite.style = .glass
        }
        let seen = item.UserData?.Played == true
        if seen { watched.style = .tinted(p.panel, p.panel, p.accent) } else { watched.style = .glass }
        watched.isHidden = !(item.Type == "Movie" || item.isSeries)
        watched.title = seen ? "Watched" : (item.isSeries ? "Mark all watched" : "Mark watched")
        let titled = item.Type == "Movie" || item.isSeries
        collection.isHidden = !titled || MeterView.key(for: item) == nil
        let key = MeterView.key(for: item)
        pick.isHidden = !(titled && ctx.isAdmin && key != nil && !(key!.hasPrefix("jf:")))
        pick.title = picked ? "Picked" : (pickFull ? "List full" : "Pick")
        pick.toolTip = picked ? "In Editor's pick on the home page — press to take it out" : "Add to Editor's pick on the home page"
        if picked { pick.style = .tinted(p.panel, NSColor.white.withAlphaComponent(0.1), p.accent); pick.border = p.glassBorder } else { pick.style = .glass }
        download.isHidden = item.isPerson || !ctx.downloadsConfigured
        recommend.isHidden = item.isPerson
        requestSeasons.isHidden = !(item.isSeries && moreSeasons)
        // Download and Recommend wear the poster's tint, as WatchList does.
        for b in [download, recommend] {
            if let tint {
                let rest = p.panel.blended(withFraction: 0.16, of: tint) ?? p.panel
                b.style = .tinted(rest, NSColor.white.withAlphaComponent(0.1), p.ink)
                b.border = p.glassBorder
            } else {
                b.style = .glass
            }
        }
        needsLayout = true
    }

    private func toggleFavorite() {
        guard var item else { return }
        let on = !(item.UserData?.IsFavorite ?? false)
        item.UserData = item.UserData ?? JFUserData()
        item.UserData?.IsFavorite = on
        self.item = item
        refreshButtons()
        let api = ctx.api
        Task { [weak self] in
            do {
                try await api.send(.jellyfin, on ? "POST" : "DELETE", "UserFavoriteItems/\(item.Id)", ["userId": api.session.userId])
            } catch {
                self?.item?.UserData?.IsFavorite = !on
                self?.refreshButtons()
            }
        }
    }

    private func toggleWatched() {
        guard var item else { return }
        let on = !(item.UserData?.Played ?? false)
        item.UserData = item.UserData ?? JFUserData()
        item.UserData?.Played = on
        self.item = item
        refreshButtons()
        let api = ctx.api
        Task { [weak self] in
            do {
                try await api.send(.jellyfin, on ? "POST" : "DELETE", "UserPlayedItems/\(item.Id)", ["userId": api.session.userId])
                self?.episodes.reload()
            } catch {
                self?.item?.UserData?.Played = !on
                self?.refreshButtons()
            }
        }
    }

    override func layoutDocument(width: CGFloat) {
        let viewport = scroll.contentView.bounds.height
        let headerH = max(380, (viewport * 0.52).rounded())
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerH)
        art.frame = NSRect(x: 0, y: 0, width: width, height: headerH + 400)

        let inset = RowView.inset
        let top = headerH - 176
        let posterW: CGFloat = 208
        CATransaction.begin(); CATransaction.setDisableActions(true)
        poster.layer.frame = CGRect(x: inset, y: top, width: posterW, height: posterW * 1.5)
        posterShadow.frame = poster.layer.frame
        posterShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: poster.layer.frame.size), cornerWidth: 16, cornerHeight: 16, transform: nil)
        CATransaction.commit()

        let x = inset + posterW + 40
        let colW = min(768, width - x - inset)
        // The column's top is where the title block starts, aligned so the
        // buttons sit level with the foot of the poster on a short title.
        var y = top + 40
        if !logo.layer.isHidden {
            var size = CGSize(width: 340, height: 80)
            if let img = logo.layer.contents as! CGImage?, img.height > 0 {
                let r = CGFloat(img.width) / CGFloat(img.height)
                size = r > 340 / 80 ? CGSize(width: 340, height: 340 / r) : CGSize(width: 80 * r, height: 80)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            logo.layer.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            CATransaction.commit()
            y += size.height + 16
        } else {
            let t = titleLabel.sizeThatFits(NSSize(width: colW, height: 200))
            titleLabel.frame = NSRect(x: x, y: y, width: colW, height: t.height)
            y += t.height + 14
        }
        let tw = ticket.isHidden ? 0 : ticket.fitSize.width + 24
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ticketBox.isHidden = ticket.isHidden
        ticketBox.path = CGPath(roundedRect: CGRect(x: x, y: y, width: tw, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil)
        CATransaction.commit()
        ticket.frame = NSRect(x: x + 12, y: y + 4, width: tw, height: 18)
        metaLabel.frame = NSRect(x: x + tw + (tw > 0 ? 12 : 0), y: y + 4, width: colW, height: 18)
        y += 26 + 8
        genresLabel.frame = NSRect(x: x, y: y, width: colW, height: 18)
        y += 18 + 14
        if !progressTrack.isHidden {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            progressTrack.frame = CGRect(x: x, y: y + 6, width: 320, height: 4)
            CATransaction.commit()
            progressLabel.frame = NSRect(x: x + 332, y: y, width: 200, height: 16)
            y += 26
        }
        // `flex-wrap gap-3`: as many as fit the column, then the next line.
        var bx = x
        for b in actionButtons where !b.isHidden {
            b.sizeToFit()
            let w = b.frame.width + (b === play ? 10 : 0)
            if bx > x && bx + w > x + colW {
                bx = x
                y += 46 + 12
            }
            b.frame = NSRect(x: bx, y: y, width: w, height: 46)
            bx = b.frame.maxX + 12
        }
        y += 46 + 24
        let ov = overview.sizeThatFits(NSSize(width: colW, height: 1000))
        overview.frame = NSRect(x: x, y: y, width: colW, height: ov.height)
        y += ov.height + 10
        studios.isHidden = studios.stringValue.isEmpty
        if !studios.isHidden {
            studios.frame = NSRect(x: x, y: y, width: colW, height: 18)
            y += 18
        }
        y = max(y, top + posterW * 1.5) + 48
        if !episodes.isHidden {
            let h = episodes.height(for: width)
            episodes.frame = NSRect(x: 0, y: y, width: width, height: h)
            y += h + 40
        }
        // The household verdict (`mt-12` on the web), keyed by TMDB id.
        if !meter.isHidden {
            let h = meter.height(for: width)
            meter.frame = NSRect(x: 0, y: y, width: width, height: h)
            y += h + 48
        }
        let bottom = stack([cast, similar], from: y, width: width, gap: 40) { ($0 as! RowView).height }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(bottom + 80, viewport))
    }
}

/// Season pills and the selected season's episodes.
@MainActor
final class EpisodesView: FlippedView {
    private let ctx: NativeContext
    private let heading = makeLabel(font: Theme.display(25.6, .bold), color: Theme.palette.ink)
    private var seasonButtons: [PillButton] = []
    private var rows: [EpisodeRow] = []
    private var seasons: [JFItem] = []
    private var selected: String?
    private var seriesId = ""
    private var current: JFItem?
    var onHeight: (() -> Void)?

    init(ctx: NativeContext) {
        self.ctx = ctx
        super.init(frame: .zero)
        addSubview(heading)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func load(seriesId: String, seriesName: String?, current: JFItem?) {
        self.seriesId = seriesId
        self.current = current
        // Only an episode's page names the show above its seasons (the web's).
        heading.attributedStringValue = NSAttributedString(string: "All episodes of \(seriesName ?? "")", attributes: [
            .font: Theme.display(20, .bold), .foregroundColor: Theme.palette.ink, .kern: -0.5,
        ])
        heading.isHidden = current == nil
        let api = ctx.api
        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "Shows/\(seriesId)/Seasons", [
                "userId": api.session.userId, "fields": "PrimaryImageAspectRatio,MediaSourceCount,ProviderIds",
            ]) { r in
                guard let self else { return }
                self.seasons = r.Items
                if self.selected == nil || !r.Items.contains(where: { $0.Id == self.selected }) {
                    self.selected = current?.SeasonId
                        ?? r.Items.first(where: { ($0.IndexNumber ?? 0) > 0 })?.Id
                        ?? r.Items.first?.Id
                }
                self.buildSeasonButtons()
                self.reload()
            }
        }
    }

    func reload() {
        guard let season = selected else { return }
        let api = ctx.api
        let seriesId = self.seriesId
        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "Shows/\(seriesId)/Episodes", [
                "userId": api.session.userId, "seasonId": season,
                "fields": "Overview,DateCreated,PrimaryImageAspectRatio,MediaSourceCount,ProviderIds",
            ]) { r in
                guard let self, self.selected == season else { return }
                self.rows.forEach { $0.removeFromSuperview() }
                self.rows = r.Items.map { ep in
                    let row = EpisodeRow(ep, ctx: self.ctx, isCurrent: ep.Id == self.current?.Id)
                    self.addSubview(row)
                    return row
                }
                self.needsLayout = true
                self.onHeight?()
            }
        }
    }

    private func buildSeasonButtons() {
        seasonButtons.forEach { $0.removeFromSuperview() }
        seasonButtons = seasons.map { s in
            // Selected: the accent. Others: `glass-soft`, words at 80%.
            let b = PillButton(s.Name ?? "Season", style: s.Id == selected ? .accent
                : .tinted(Theme.palette.glass, NSColor.white.withAlphaComponent(0.1), Theme.palette.ink.withAlphaComponent(0.8)),
                height: 36, fontSize: 13.5)
            if s.Id != selected { b.border = Theme.palette.glassBorder }
            b.action = { [weak self] in
                self?.selected = s.Id
                self?.buildSeasonButtons()
                self?.reload()
            }
            addSubview(b)
            return b
        }
        needsLayout = true
    }

    private var top: CGFloat { heading.isHidden ? 0 : 44 }

    func height(for width: CGFloat) -> CGFloat {
        top + 36 + 16 + CGFloat(rows.count) * (EpisodeRow.height + 4)
    }

    override func layout() {
        super.layout()
        let inset = RowView.inset
        heading.frame = NSRect(x: inset, y: 6, width: bounds.width - inset * 2, height: 32)
        var x = inset
        for b in seasonButtons {
            b.sizeToFit()
            b.frame = NSRect(x: x, y: top, width: b.frame.width, height: 36)
            x = b.frame.maxX + 8
        }
        var y = top + 36 + 16
        for r in rows {
            r.frame = NSRect(x: inset - 10, y: y, width: bounds.width - inset * 2 + 20, height: EpisodeRow.height)
            y += EpisodeRow.height + 4
        }
    }
}

/// One episode (item/[id] page): a 16 pt-rounded row, white/5 on hover, the
/// current episode ringed in the accent; the thumbnail darkens on hover with an
/// accent play mark. Plays it.
@MainActor
final class EpisodeRow: FlippedView {
    static let height: CGFloat = 108 + 20
    private let thumb = RemoteImage()
    private let thumbClip = CALayer()
    private let shade = CALayer()
    private let playDot = CAShapeLayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let check = CATextLayer()
    private let checkBG = CALayer()
    private let name = makeLabel(font: Theme.text(14.5, .semibold), color: Theme.palette.ink)
    private let detail = makeLabel(font: Theme.text(12), color: Theme.palette.muted)
    private let overview = makeLabel(font: Theme.text(13), color: Theme.palette.muted, lines: 3)
    private let ep: JFItem
    private let ctx: NativeContext
    private let isCurrent: Bool
    private var tracking: NSTrackingArea?

    init(_ ep: JFItem, ctx: NativeContext, isCurrent: Bool) {
        self.ep = ep
        self.ctx = ctx
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        let p = Theme.palette
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        if isCurrent {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = p.accent.withAlphaComponent(0.4).cgColor
        }
        thumbClip.cornerRadius = 12
        thumbClip.cornerCurve = .continuous
        thumbClip.masksToBounds = true
        thumbClip.backgroundColor = p.void2.cgColor
        thumbClip.addSublayer(thumb.layer)
        shade.backgroundColor = p.void.withAlphaComponent(0.4).cgColor
        shade.opacity = 0
        thumbClip.addSublayer(shade)
        playDot.fillColor = p.accent.cgColor
        playDot.opacity = 0
        thumbClip.addSublayer(playDot)
        track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.backgroundColor = p.accent.cgColor
        track.addSublayer(fill)
        thumbClip.addSublayer(track)
        checkBG.backgroundColor = p.accent.cgColor
        checkBG.cornerRadius = 10
        check.string = "✓"
        check.font = Theme.text(11, .bold)
        check.fontSize = 11
        check.foregroundColor = p.accentInk.cgColor
        check.alignmentMode = .center
        check.contentsScale = 2
        checkBG.addSublayer(check)
        checkBG.isHidden = ep.UserData?.Played != true
        thumbClip.addSublayer(checkBG)
        layer?.addSublayer(thumbClip)
        for v in [name, detail, overview] { addSubview(v) }
        let t = NSMutableAttributedString()
        if let n = ep.IndexNumber {
            t.append(NSAttributedString(string: "\(n)  ", attributes: [.font: Theme.text(14.5, .semibold), .foregroundColor: p.muted]))
        }
        t.append(NSAttributedString(string: ep.Name ?? "", attributes: [.font: Theme.text(14.5, .semibold), .foregroundColor: p.ink]))
        if isCurrent {
            t.append(NSAttributedString(string: "   THIS EPISODE", attributes: [.font: Theme.text(11, .semibold), .foregroundColor: p.accent, .kern: 0.3]))
        }
        name.attributedStringValue = t
        var d: [String] = []
        if let r = ep.runtimeText { d.append(r) }
        if let left = CardText.timeLeft(ep) { d.append(left) }
        detail.stringValue = d.joined(separator: " · ")
        overview.attributedStringValue = NSAttributedString(string: ep.Overview ?? "", attributes: [
            .font: Theme.text(13), .foregroundColor: p.muted,
            .paragraphStyle: { let ps = NSMutableParagraphStyle(); ps.lineHeightMultiple = 1.2; return ps }(),
        ])
        thumb.load(ctx.art.wide(ep, width: 400), points: 192, scale: 2)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumbClip.frame = CGRect(x: pad, y: pad, width: 192, height: 108)
        thumb.layer.frame = thumbClip.bounds
        shade.frame = thumbClip.bounds
        let d: CGFloat = 36
        let dot = CGMutablePath()
        dot.addEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        playDot.path = dot
        playDot.frame = CGRect(x: (192 - d) / 2, y: (108 - d) / 2, width: d, height: d)
        if playDot.sublayers == nil {
            let glyph = CAShapeLayer()
            glyph.path = PillButton.path(.play, 14)
            glyph.fillColor = Theme.palette.accentInk.cgColor
            glyph.frame = CGRect(x: (d - 14) / 2 + 1, y: (d - 14) / 2, width: 14, height: 14)
            playDot.addSublayer(glyph)
        }
        if let p = ep.progress {
            track.isHidden = false
            track.frame = CGRect(x: 0, y: 105, width: 192, height: 3)
            fill.frame = CGRect(x: 0, y: 0, width: 192 * p, height: 3)
        } else { track.isHidden = true }
        checkBG.frame = CGRect(x: 192 - 26, y: 6, width: 20, height: 20)
        check.frame = CGRect(x: 0, y: 3, width: 20, height: 14)
        CATransaction.commit()
        let x = pad + 192 + 16
        let w = bounds.width - x - pad
        name.frame = NSRect(x: x, y: pad + 4, width: w, height: 20)
        detail.frame = NSRect(x: x, y: pad + 26, width: w, height: 16)
        overview.frame = NSRect(x: x, y: pad + 48, width: min(760, w), height: 56)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    private func hover(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(Theme.standard)
        if !isCurrent { layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.05).cgColor : nil }
        shade.opacity = on ? 1 : 0
        playDot.opacity = on ? 1 : 0
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) {
        Hover.enter(self, area: { [unowned self] in self.bounds },
                    begin: { [weak self] in self?.hover(true) }, end: { [weak self] in self?.hover(false) })
    }
    override func mouseExited(with event: NSEvent) { Hover.exit(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { layer?.transform = PillButton.lift(bounds, dy: 0, scale: 0.97) }
    override func mouseUp(with event: NSEvent) {
        layer?.transform = CATransform3DIdentity
        if bounds.contains(convert(event.locationInWindow, from: nil)) { ctx.play(ep.Id) }
    }
}

/// A title page's backdrop with its two scrims (the hero's arrangement): the
/// picture fades into the page at its foot and darkens toward the copy.
final class BackdropHeader: FlippedView {
    let image = RemoteImage()
    private let bottom = ShadeLayer()
    private let left = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        let v = Theme.palette.void
        image.layer.contentsGravity = .resizeAspectFill
        // Top to foot: the picture fades into the page at its foot.
        bottom.set([v.withAlphaComponent(0.25), v.withAlphaComponent(0.4), v])
        left.colors = [v.withAlphaComponent(0.7).cgColor, NSColor.clear.cgColor]
        left.startPoint = CGPoint(x: 0, y: 0.5)
        left.endPoint = CGPoint(x: 1, y: 0.5)
        for l in [image.layer, bottom, left] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.layer.frame = bounds
        bottom.frame = bounds
        left.frame = bounds
        CATransaction.commit()
    }
}
