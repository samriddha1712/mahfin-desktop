import AppKit

/*
 * A title's page (Mahfin's src/app/(app)/item/[id]/page.tsx), natively: the
 * backdrop header, poster, logo or title, the ticket and meta lines, progress,
 * Play / Resume, My List and Mark watched, the overview, seasons and episodes,
 * cast, and "More like this". Play goes to the web player, as every Play does.
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
    private let play = PillButton("Play", style: .accent, height: 48, fontSize: 16)
    private let favorite = PillButton("My List", style: .glass, height: 48, fontSize: 15)
    private let watched = PillButton("Mark watched", style: .glass, height: 48, fontSize: 15)
    private let overview = makeLabel(font: Theme.text(15), color: Theme.palette.ink.withAlphaComponent(0.8), lines: 0)
    private let studios = makeLabel(font: Theme.text(13), color: Theme.palette.muted)
    private let episodes: EpisodesView
    private lazy var cast = RowView(title: "Cast & crew", kind: .cast, ctx: ctx)
    private lazy var similar = RowView(title: "More like this", kind: .posters, ctx: ctx)
    private var ready = true

    init(id: String, ctx: NativeContext) {
        self.id = id
        episodes = EpisodesView(ctx: ctx)
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
        favorite.icon = .plus
        watched.icon = .check
        for b in [play, favorite, watched] { document.addSubview(b) }
        document.addSubview(episodes)
        document.addSubview(cast)
        document.addSubview(similar)
        rows = [cast, similar]
        play.action = { [weak self] in
            guard let self, self.ready else { return }
            ctx.play(self.id)
        }
        favorite.action = { [weak self] in self?.toggleFavorite() }
        watched.action = { [weak self] in self?.toggleWatched() }
        load()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

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
        favorite.title = fav ? "In My List" : "My List"
        favorite.icon = fav ? .check : .plus
        let seen = item.UserData?.Played == true
        watched.isHidden = !(item.Type == "Movie" || item.isSeries)
        watched.title = seen ? "Watched" : (item.isSeries ? "Mark all watched" : "Mark watched")
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
        var bx = x
        for b in [play, favorite, watched] where !b.isHidden {
            b.sizeToFit()
            b.frame = NSRect(x: bx, y: y, width: b.frame.width + (b === play ? 10 : 0), height: 48)
            bx = b.frame.maxX + 12
        }
        y += 48 + 26
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
        heading.stringValue = current != nil ? "All episodes of \(seriesName ?? "")" : "Episodes"
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
            let b = PillButton(s.Name ?? "Season", style: s.Id == selected ? .accent : .outline, height: 36, fontSize: 13.5)
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

    func height(for width: CGFloat) -> CGFloat {
        RowView.headerHeight + 36 + 20 + CGFloat(rows.count) * (EpisodeRow.height + 12)
    }

    override func layout() {
        super.layout()
        let inset = RowView.inset
        heading.frame = NSRect(x: inset, y: 6, width: bounds.width - inset * 2, height: 32)
        var x = inset
        for b in seasonButtons {
            b.sizeToFit()
            b.frame = NSRect(x: x, y: RowView.headerHeight, width: b.frame.width, height: 36)
            x = b.frame.maxX + 8
        }
        var y = RowView.headerHeight + 36 + 20
        for r in rows {
            r.frame = NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: EpisodeRow.height)
            y += EpisodeRow.height + 12
        }
    }
}

/// One episode: thumbnail with progress, "N. Name", runtime and overview. Plays it.
@MainActor
final class EpisodeRow: FlippedView {
    static let height: CGFloat = 108
    private let thumb = RemoteImage()
    private let track = CALayer()
    private let fill = CALayer()
    private let name = makeLabel(font: Theme.text(15, .semibold), color: Theme.palette.ink)
    private let detail = makeLabel(font: Theme.text(12.5), color: Theme.palette.muted)
    private let overview = makeLabel(font: Theme.text(13), color: Theme.palette.ink.withAlphaComponent(0.7), lines: 2)
    private let ep: JFItem
    private let ctx: NativeContext
    private var tracking: NSTrackingArea?

    init(_ ep: JFItem, ctx: NativeContext, isCurrent: Bool) {
        self.ep = ep
        self.ctx = ctx
        super.init(frame: .zero)
        layer?.cornerRadius = 12
        thumb.layer.cornerRadius = 10
        thumb.layer.backgroundColor = Theme.palette.void2.cgColor
        layer?.addSublayer(thumb.layer)
        track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.backgroundColor = Theme.palette.accent.cgColor
        track.addSublayer(fill)
        layer?.addSublayer(track)
        for v in [name, detail, overview] { addSubview(v) }
        name.stringValue = "\(ep.IndexNumber.map { "\($0). " } ?? "")\(ep.Name ?? "")" + (ep.UserData?.Played == true ? "  ✓" : "")
        var d: [String] = []
        if isCurrent { d.append("This episode") }
        if let r = ep.runtimeText { d.append(r) }
        if let left = CardText.timeLeft(ep) { d.append(left) }
        detail.stringValue = d.joined(separator: " · ")
        overview.stringValue = ep.Overview ?? ""
        if isCurrent { layer?.backgroundColor = Theme.palette.glass.cgColor }
        thumb.load(ctx.art.wide(ep, width: 400), points: 192, scale: 2)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.layer.frame = CGRect(x: 0, y: 0, width: 192, height: 108)
        if let p = ep.progress {
            track.isHidden = false
            track.frame = CGRect(x: 0, y: 105, width: 192, height: 3)
            fill.frame = CGRect(x: 0, y: 0, width: 192 * p, height: 3)
        } else { track.isHidden = true }
        CATransaction.commit()
        let x: CGFloat = 192 + 18
        name.frame = NSRect(x: x, y: 10, width: bounds.width - x - 12, height: 20)
        detail.frame = NSRect(x: x, y: 32, width: bounds.width - x - 12, height: 16)
        overview.frame = NSRect(x: x, y: 54, width: min(760, bounds.width - x - 12), height: 36)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Theme.palette.glassStrong.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
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
