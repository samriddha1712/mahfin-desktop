import AppKit
import QuartzCore

/*
 * The IOS theme's home page top (Mahfin's BoardHome.tsx + HeroDeck.tsx),
 * natively: the featured titles as a deck of cards with the trailer on the one
 * in front, "Now watching" on a glass panel beside it, and the genre chips
 * under both. Below this the page is the same native rows as Golden Hour.
 *
 * Drawn here rather than left to the web view because WebKit on the owner's
 * Mac cannot scroll a page like this smoothly, whatever the page does (see
 * mahfin-webkit-performance); the native pages scroll at the display's rate.
 */

/// The part of the home page above the rows: Golden Hour's hero, or this.
@MainActor
protocol HomeTop: NSView {
    var items: [JFItem] { get }
    var onTint: ((NSColor) -> Void)? { get set }
    func set(_ items: [JFItem])
    func setActive(_ on: Bool)
    func setScrollProgress(_ p: CGFloat)
    /// Lays itself out for `width` and returns its height.
    func height(for width: CGFloat, viewport: CGFloat) -> CGFloat
    /// How far the first row rides up over its foot (negative: a gap).
    var overlap: CGFloat { get }
}

extension HeroView: HomeTop {
    func height(for width: CGFloat, viewport: CGFloat) -> CGFloat { max(480, (viewport * 0.78).rounded()) }
    var overlap: CGFloat { 24 }
}

// MARK: - The board top

@MainActor
final class BoardTop: FlippedView, HomeTop {
    static let barHeight: CGFloat = 72
    let deck: DeckView
    private let watching: NowWatchingView
    private let genres: GenreChipsView
    var onHeight: (() -> Void)?

    var onTint: ((NSColor) -> Void)? {
        get { deck.onTint }
        set { deck.onTint = newValue }
    }
    var items: [JFItem] { deck.items }
    var overlap: CGFloat { -40 }   // the rows' `mt-10`

    init(ctx: NativeContext) {
        deck = DeckView(ctx: ctx)
        watching = NowWatchingView(ctx: ctx)
        genres = GenreChipsView(ctx: ctx)
        super.init(frame: .zero)
        layer?.masksToBounds = false
        for v in [deck, watching, genres] as [NSView] { addSubview(v) }
        watching.onHeight = { [weak self] in self?.needsLayout = true; self?.onHeight?() }
        genres.onHeight = { [weak self] in self?.needsLayout = true; self?.onHeight?() }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ items: [JFItem]) { deck.set(items) }

    func setActive(_ on: Bool) {
        deck.setActive(on)
        if on { watching.reload() }
    }

    func setScrollProgress(_ p: CGFloat) { deck.setOffscreen(p > 0.75) }

    private var lastViewport: CGFloat = 800

    func height(for width: CGFloat, viewport: CGFloat) -> CGFloat {
        lastViewport = viewport
        return layoutContent(width: width, viewport: viewport)
    }

    @discardableResult
    private func layoutContent(width: CGFloat, viewport: CGFloat) -> CGFloat {
        let x = RowView.inset
        let top = BoardTop.barHeight + 24
        let inner = width - x * 2
        // `lg:grid-cols-[minmax(0,1fr)_340px] 2xl:…_400px`, gap 24.
        let wide = width >= 1024
        let sideW: CGFloat = width >= 1536 ? 400 : 340
        let deckW = wide ? inner - sideW - 24 : inner
        // The deck: full width of its column at 2.25:1, never taller than what
        // leaves the first row of posters on screen (the web's clamp).
        let deckH = min(deckW / 2.25, min(560, max(280, viewport - 500)))
        deck.frame = NSRect(x: x, y: top, width: deckW, height: deckH)
        // Beside the deck the panel is the deck's height, and holds as many
        // titles as fit (owner's ask, 2026-10-16); under it, three.
        watching.fixedHeight = wide ? deckH : nil
        let wh = watching.height(for: wide ? sideW : inner)
        if wide {
            watching.frame = NSRect(x: x + deckW + 24, y: top, width: sideW, height: wh)
        } else {
            watching.frame = NSRect(x: x, y: deck.frame.maxY + 24, width: inner, height: wh)
        }
        let below = max(deck.frame.maxY, wh > 0 ? watching.frame.maxY : 0)
        genres.frame = NSRect(x: x, y: below + 36, width: inner, height: genres.isHidden ? 0 : 46)
        return genres.isHidden ? below : genres.frame.maxY
    }

    override func layout() {
        super.layout()
        layoutContent(width: bounds.width, viewport: lastViewport)
    }
}

// MARK: - The deck

@MainActor
final class DeckView: FlippedView {
    static let holdSeconds: TimeInterval = 9
    static let previewSeconds: TimeInterval = 15

    private let ctx: NativeContext
    private(set) var items: [JFItem] = []
    private var cards: [String: DeckCard] = [:]
    private var index = 0
    private let trailer: HeroTrailer
    private let pager = FlippedView()
    private var dots: [CALayer] = []
    private let dotFill = CALayer()
    var onTint: ((NSColor) -> Void)?

    // The countdown (as HeroView's): re-anchored when its length changes.
    private var timer: Timer?
    private var anchorAt: CFTimeInterval = 0
    private var anchorFrom: Double = 0
    private var anchorRemaining: Double = DeckView.holdSeconds
    private var trailerSeconds: Double?
    private var engaged = false
    private var leaving = false
    private var active = true
    private var tracking: NSTrackingArea?

    init(ctx: NativeContext) {
        self.ctx = ctx
        trailer = HeroTrailer(api: ctx.api)
        super.init(frame: .zero)
        layer?.masksToBounds = false
        addSubview(pager)
        dotFill.backgroundColor = Theme.palette.accent.cgColor
        dotFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        trailer.onDuration = { [weak self] s in
            self?.trailerSeconds = s > 0 ? s : nil
            self?.retarget()
        }
        trailer.onEngaged = { [weak self] e in self?.setEngaged(e) }
        trailer.onControls = { [weak self] in self?.front?.updateTrailerControls(self?.trailer) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var front: DeckCard? { index < items.count ? cards[items[index].Id] : nil }

    func set(_ items: [JFItem]) {
        guard items.map(\.Id) != self.items.map(\.Id) else { return }
        self.items = items
        cards.values.forEach { $0.removeFromSuperview() }
        cards = [:]
        dots.forEach { $0.removeFromSuperlayer() }
        dots = items.map { _ in
            let d = CALayer()
            d.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
            d.cornerRadius = 3
            d.masksToBounds = true
            pager.layer?.addSublayer(d)
            return d
        }
        index = 0
        show(0, animated: false)
    }

    /// Turns the deck to `i`.
    private func show(_ i: Int, animated: Bool) {
        guard !items.isEmpty else { return }
        index = (i + items.count) % items.count
        let n = items.count
        var visible = Set<String>()
        for (k, item) in items.enumerated() {
            let rel = (k - index + n) % n
            let outgoing = rel == n - 1 && n > 2
            guard rel <= 2 || outgoing else { continue }
            visible.insert(item.Id)
            let card = cards[item.Id] ?? {
                let c = DeckCard(item: item, ctx: ctx)
                c.onOpen = { [weak self] in self?.ctx.openItem(item) }
                c.onPlay = { [weak self] in self?.ctx.play(item.Id) }
                addSubview(c, positioned: .below, relativeTo: pager)
                cards[item.Id] = c
                c.frame = cardFrame
                c.setDepth(outgoing ? .out : .back(rel), animated: false)
                return c
            }()
            card.setDepth(outgoing ? .out : (rel == 0 ? .front : .back(rel)), animated: animated)
        }
        // Gone past the deck: let the card finish leaving, then drop it.
        for (id, card) in cards where !visible.contains(id) {
            cards[id] = nil
            card.setDepth(.out, animated: animated)   // a jump of two: off to the left too
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { card.removeFromSuperview() }
        }
        // Front-to-back order for drawing and for clicks.
        let order = items.indices.map { (items[$0], ($0 - index + n) % n) }
            .filter { visible.contains($0.0.Id) }
            .sorted { a, b in
                let ra = a.1 == n - 1 && n > 2 ? -1 : a.1
                let rb = b.1 == n - 1 && n > 2 ? -1 : b.1
                return ra > rb
            }
        for (item, _) in order {
            if let c = cards[item.Id] { addSubview(c, positioned: .below, relativeTo: pager) }
        }
        // The trailer rides the card in front.
        let item = items[index]
        if let f = front {
            f.adoptTrailer(trailer)
            f.onBackdrop = { [weak self] img in self?.onTint?(ImagePipeline.vivid(ImagePipeline.average(img))) }
        }
        leaving = false
        trailerSeconds = nil
        trailer.load(item.Id)
        startCountdown()
        layoutPager(animated: animated)
        if n > 1 {
            let next = items[(index + 1) % n]
            if let u = ctx.art.backdrop(next, width: 1920) { ImagePipeline.shared.prefetch([u], pixels: 2560) }
            trailer.prefetch(next.Id)
        }
    }

    private var cardFrame: NSRect { NSRect(x: 0, y: 0, width: bounds.width * 0.86, height: bounds.height) }

    override func layout() {
        super.layout()
        for c in cards.values { c.frame = cardFrame }
        // Top right, over the stack's own top edge (`right-7 top-3`), where it
        // covers none of the artwork it pages.
        pager.frame = NSRect(x: bounds.width - 28 - pagerWidth, y: 10, width: pagerWidth, height: 10)
        layoutPager(animated: false)
    }

    // MARK: Pager and countdown

    private var pagerWidth: CGFloat { CGFloat(max(0, items.count - 1)) * (6 + 6) + 16 }

    private func layoutPager(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        CATransaction.setDisableActions(!animated)
        var x: CGFloat = 0
        for (i, d) in dots.enumerated() {
            let w: CGFloat = i == index ? 16 : 6
            d.frame = CGRect(x: x, y: 2, width: w, height: 6)
            x += w + 6
        }
        CATransaction.commit()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if index < dots.count {
            dotFill.removeFromSuperlayer()
            dots[index].addSublayer(dotFill)
            dotFill.bounds = CGRect(x: 0, y: 0, width: 16, height: 6)
            dotFill.position = CGPoint(x: 0, y: 3)
        }
        CATransaction.commit()
    }

    private var target: Double {
        guard let t = trailerSeconds else { return DeckView.holdSeconds }
        return engaged ? max(t, 1) : DeckView.previewSeconds
    }

    private var progress: Double {
        min(1, anchorFrom + (1 - anchorFrom) * (CACurrentMediaTime() - anchorAt) / max(0.001, anchorRemaining))
    }

    private func startCountdown() {
        anchorFrom = 0
        anchorAt = CACurrentMediaTime()
        anchorRemaining = target
        runCountdown()
    }

    private func retarget() {
        guard timer?.isValid == true else { return }
        let p = progress
        anchorFrom = p
        anchorAt = CACurrentMediaTime()
        anchorRemaining = max(0.25, target * (1 - p))
        runCountdown()
    }

    private func runCountdown() {
        timer?.invalidate()
        timer = nil
        guard items.count > 1, active else { return }
        timer = Timer.scheduledTimer(withTimeInterval: anchorRemaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        dotFill.removeAllAnimations()
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = anchorFrom
        a.toValue = 1
        a.duration = anchorRemaining
        dotFill.add(a, forKey: "countdown")
    }

    private func finish() {
        guard trailer.visible else { show(index + 1, animated: true); return }
        leaving = true
        trailer.leave()
        let at = index
        DispatchQueue.main.asyncAfter(deadline: .now() + HeroTrailer.fadeOutSeconds) { [weak self] in
            guard let self, self.leaving, self.active, self.index == at else { return }
            self.engaged = false
            self.show(self.index + 1, animated: true)
        }
    }

    func setActive(_ on: Bool) {
        active = on
        trailer.setActive(on)
        if on { startCountdown() } else { timer?.invalidate(); timer = nil; leaving = false; engaged = false }
    }

    func setOffscreen(_ off: Bool) { trailer.setOffscreen(off) }

    private func setEngaged(_ e: Bool) {
        guard e != engaged else { return }
        engaged = e
        retarget()
    }

    // Hovering the deck gives a trailer its whole length (HeroDeck.tsx).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { setEngaged(true) }
    override func mouseExited(with event: NSEvent) {
        setEngaged(false)
        peek(at: nil)
    }
    override func mouseMoved(with event: NSEvent) { peek(at: convert(event.locationInWindow, from: nil)) }

    /// The back card whose peeking edge is under the pointer, leaning out.
    private weak var peeking: DeckCard?

    /// Back cards draw past their own views, right of the face; that strip is
    /// this view's, so it finds the card there itself — the nearer one first.
    private func peekCard(at p: NSPoint?) -> DeckCard? {
        guard let p, p.x > cardFrame.maxX, !pager.frame.insetBy(dx: -4, dy: -8).contains(p) else { return nil }
        let backs = cards.values.compactMap { c -> (Int, DeckCard)? in
            if case .back(let n) = c.depth { return (n, c) }
            return nil
        }
        return backs.sorted { $0.0 < $1.0 }.first { $0.1.drawnFrame.contains(p) }?.1
    }

    private func peek(at p: NSPoint?) {
        let card = peekCard(at: p)
        guard card !== peeking else { return }
        peeking?.setLeaning(false)
        card?.setLeaning(true)
        peeking = card
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let strip = NSRect(x: cardFrame.maxX, y: 0, width: max(0, bounds.width - cardFrame.maxX), height: bounds.height)
        addCursorRect(strip, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}   // so the click's mouseUp comes here

    override func mouseUp(with event: NSEvent) {
        // A dot turns the deck to its card.
        let p = pager.convert(event.locationInWindow, from: nil)
        for (i, d) in dots.enumerated() where d.frame.insetBy(dx: -4, dy: -8).contains(p) {
            show(i, animated: true)
            return
        }
        // A card behind the face comes to the front.
        let q = convert(event.locationInWindow, from: nil)
        if let card = peekCard(at: q), let i = items.firstIndex(where: { cards[$0.Id] === card }) {
            peeking = nil
            show(i, animated: true)
            peek(at: q)   // whatever now peeks under the pointer leans out
        }
    }

    var debugCards: [String] { subviews.compactMap { ($0 as? DeckCard)?.debugState } }

    var debugState: String {
        "index=\(index)/\(items.count) cards=\(cards.count) front=\(front?.title ?? "-") hold=\(String(format: "%.1f", target)) " + trailer.debugState
    }
}

// MARK: - One card

@MainActor
final class DeckCard: FlippedView {
    enum Depth: Equatable { case front, back(Int), out }

    private let item: JFItem
    private let ctx: NativeContext
    /// Carries the deck transform and the shadow; `body` inside it clips.
    private let holder = CALayer()
    private let body = CALayer()
    private let picture = RemoteImage()
    private let trailerSlot = CALayer()
    private let scrim = ShadeLayer()
    private let darken = CALayer()
    private let rim = CALayer()
    private let face = FlippedView()
    private var chips: [NSView] = []
    private let logo = RemoteImage()
    private let logoHost = FlippedView()
    private let bigTitle = makeLabel(font: Theme.display(34, .heavy), color: Theme.palette.ink, lines: 2)
    private let play = PillButton("", style: .accent, height: 44, fontSize: 15)
    private let name = makeLabel(font: Theme.text(15, .semibold), color: Theme.palette.ink)
    private let sub = makeLabel(font: Theme.text(12.5), color: Theme.palette.muted)
    private let heart = PillButton("", style: .tinted(NSColor.black.withAlphaComponent(0.4), NSColor.black.withAlphaComponent(0.55), Theme.palette.ink), height: 40)
    private let muteButton = TrailerButton()
    private let pauseButton = TrailerButton()
    private weak var trailer: HeroTrailer?
    private(set) var depth: Depth = .back(2)
    private var tracking: NSTrackingArea?
    private var hovering = false
    var onOpen: (() -> Void)?
    var onPlay: (() -> Void)?
    var onBackdrop: ((CGImage) -> Void)?
    var title: String { item.Name ?? "" }

    init(item: JFItem, ctx: NativeContext) {
        self.item = item
        self.ctx = ctx
        super.init(frame: .zero)
        layer?.masksToBounds = false
        holder.anchorPoint = CGPoint(x: 1, y: 0.5)
        holder.shadowColor = NSColor.black.cgColor
        holder.shadowOffset = CGSize(width: 0, height: -34)
        holder.shadowRadius = 35
        holder.shadowOpacity = 0
        body.cornerRadius = 16
        body.cornerCurve = .continuous
        body.masksToBounds = true
        body.backgroundColor = Theme.palette.void2.cgColor
        picture.layer.contentsGravity = .resizeAspectFill
        picture.onLoad = { [weak self] in
            guard let self, let img = self.picture.layer.contents as! CGImage? else { return }
            self.onBackdrop?(img)
        }
        // `bg-gradient-to-t from-black via-black/35 to-transparent`.
        scrim.set([.clear, NSColor.black.withAlphaComponent(0.35), .black])
        darken.backgroundColor = NSColor.black.cgColor
        darken.opacity = 0
        rim.cornerRadius = 16
        rim.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        rim.borderWidth = 1
        for l in [picture.layer, trailerSlot, scrim, darken, rim] { body.addSublayer(l) }
        holder.addSublayer(body)
        layer?.addSublayer(holder)

        // The face: pills, logo, play + title, heart. Front card only.
        addSubview(face)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        picture.load(ctx.art.backdrop(item, width: 1920), points: 1280, scale: scale)
        let pills: [String] = [
            item.isSeries ? "Series" : (item.runtimeText ?? ""),
            item.Genres?.first ?? "",
            item.isSeries ? "Show" : "Movie",
            item.ProductionYear.map(String.init) ?? "",
            item.OfficialRating ?? "",
        ].filter { !$0.isEmpty }
        for p in pills { chips.append(chip(p, accent: false)) }
        if let r = item.CommunityRating, r > 0 { chips.append(chip("★ " + String(format: "%.1f", r), accent: true)) }
        chips.forEach { face.addSubview($0) }
        let logoURL = ctx.art.logo(item, width: 720)
        logo.layer.contentsGravity = .resizeAspect
        logo.layer.shadowColor = NSColor.black.cgColor
        logo.layer.shadowOpacity = 0.65
        logo.layer.shadowRadius = 9
        logo.layer.shadowOffset = CGSize(width: 0, height: -4)
        logo.layer.masksToBounds = false
        logo.onLoad = { [weak self] in self?.needsLayout = true }
        logoHost.layer?.masksToBounds = false
        logoHost.layer?.addSublayer(logo.layer)
        face.addSubview(logoHost)
        bigTitle.stringValue = item.Name ?? ""
        bigTitle.isHidden = logoURL != nil
        logoHost.isHidden = logoURL == nil
        logo.load(logoURL, points: 360, scale: scale)
        face.addSubview(bigTitle)
        play.icon = .play
        play.action = { [weak self] in self?.onPlay?() }
        name.stringValue = item.Name ?? ""
        sub.stringValue = item.isSeries ? "Open the series" : "More info"
        heart.svgIcon = WebIcon.heart(filled: item.UserData?.IsFavorite == true)
        heart.border = NSColor.white.withAlphaComponent(0.25)
        heart.action = { [weak self] in self?.toggleFavorite() }
        muteButton.action = { [weak self] in self?.trailer?.toggleMute() }
        pauseButton.action = { [weak self] in self?.trailer?.togglePause() }
        muteButton.isHidden = true
        pauseButton.isHidden = true
        for v in [play, name, sub, heart, muteButton, pauseButton] as [NSView] { face.addSubview(v) }
        face.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func chip(_ text: String, accent: Bool) -> NSView {
        let v = FlippedView()
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        v.layer?.cornerRadius = 12
        let l = makeLabel(text, font: Theme.text(11.5, accent ? .semibold : .medium),
                          color: accent ? Theme.palette.accent : Theme.palette.ink.withAlphaComponent(0.9))
        v.addSubview(l)
        let s = l.fitSize
        v.frame = NSRect(x: 0, y: 0, width: s.width + 24, height: 24)
        l.frame = NSRect(x: 12, y: (24 - s.height) / 2, width: s.width, height: s.height)
        return v
    }

    func adoptTrailer(_ t: HeroTrailer) {
        trailer = t
        t.host.removeFromSuperlayer()
        trailerSlot.addSublayer(t.host)
        t.layout(trailerSlot.bounds)
        updateTrailerControls(t)
    }

    func updateTrailerControls(_ t: HeroTrailer?) {
        guard let t, t === trailer, depth == .front else {
            muteButton.isHidden = true
            pauseButton.isHidden = true
            return
        }
        muteButton.isHidden = !t.visible
        pauseButton.isHidden = !t.visible
        muteButton.set(t.muted ? .speakerMuted : .speaker)
        pauseButton.set(t.paused ? .play : .pause)
    }

    private func toggleFavorite() {
        let on = !(heart.svgIcon == WebIcon.heart(filled: true))
        heart.svgIcon = WebIcon.heart(filled: on)
        let api = ctx.api
        let id = item.Id
        Task {
            try? await api.send(.jellyfin, on ? "POST" : "DELETE", "UserFavoriteItems/\(id)", ["userId": api.session.userId])
        }
    }

    /// The card's place in the deck (globals.css `.studio-hero-card[data-depth]`).
    /// Whether the pointer is on this back card's peeking edge (DeckView).
    private(set) var leaning = false

    /// Leans out a little, straightens, lifts its shade (globals.css
    /// `.studio-hero-card[data-depth="1"]:hover`). Back cards only.
    func setLeaning(_ on: Bool) {
        guard on != leaning, case .back = depth else { return }
        leaning = on
        setDepth(depth, animated: true, duration: 0.45)
    }

    /// The card's drawn extent in its own coordinates (the transform included).
    var drawnFrame: CGRect { holder.frame }

    func setDepth(_ d: Depth, animated: Bool, duration: CFTimeInterval = 0.62) {
        if d != depth { leaning = false }
        depth = d
        let w = bounds.width
        var t = CATransform3DIdentity
        var opacity: Float = 1
        var dark: Float = 0
        switch d {
        case .front:
            break
        case .back(let n):
            t.m34 = -1 / 1400
            let (dx, deg, sy): (CGFloat, CGFloat, CGFloat) = switch (n, leaning) {
            case (1, false): (0.08, -7, 0.9)
            case (1, true): (0.105, -4.5, 0.92)
            case (_, false): (0.152, -11, 0.79)
            case (_, true): (0.18, -8, 0.82)
            }
            t = CATransform3DTranslate(t, dx * w, 0, 0)
            t = CATransform3DRotate(t, deg * .pi / 180, 0, 1, 0)
            t = CATransform3DScale(t, 1, sy, 1)
            dark = n == 1 ? (leaning ? 0.18 : 0.4) : (leaning ? 0.38 : 0.66)
        case .out:
            t = CATransform3DTranslate(t, -1.04 * w, 0, 0)
            t = CATransform3DScale(t, 0.92, 0.92, 1)
            opacity = 0
            dark = 0.5
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? duration : 0)
        CATransaction.setAnimationTimingFunction(Theme.expoOut)
        CATransaction.setDisableActions(!animated)
        holder.transform = t
        holder.opacity = opacity
        holder.shadowOpacity = d == .front ? 0.9 : 0
        darken.opacity = dark
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.36 : 0
            face.animator().alphaValue = d == .front ? 1 : 0
        }
        if d != .front { setHover(false) }
        updateTrailerControls(trailer)
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        holder.bounds = CGRect(origin: .zero, size: b.size)
        holder.position = CGPoint(x: b.width, y: b.midY)
        holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        body.frame = holder.bounds
        for l in [picture.layer, trailerSlot, scrim, darken, rim] { l.frame = body.bounds }
        CATransaction.commit()
        trailer.map { if $0.host.superlayer === trailerSlot { $0.layout(trailerSlot.bounds) } }
        face.frame = b
        // Top left: the facts as chips, clipped rather than wrapped.
        var x: CGFloat = 20
        for c in chips {
            c.isHidden = x + c.frame.width > b.width - 20
            c.frame.origin = NSPoint(x: x, y: 20)
            x += c.frame.width + 6
        }
        // Bottom left: play, then the title and what it opens.
        play.frame = NSRect(x: 20, y: b.height - 20 - 44, width: 44, height: 44)
        play.layer?.cornerRadius = 22
        let ns = name.fitSize, ss = sub.fitSize
        let textW = min(b.width * 0.5, max(ns.width, ss.width))
        name.frame = NSRect(x: 76, y: play.frame.midY - ns.height - 1, width: textW, height: ns.height)
        sub.frame = NSRect(x: 76, y: play.frame.midY + 1, width: textW, height: ss.height)
        // The logo above them, large: up to 46% of the card across.
        let maxW = b.width * 0.46, maxH = min(120, max(48, b.width * 0.09))
        if !logoHost.isHidden {
            var size = CGSize(width: maxW, height: maxH)
            if let img = logo.layer.contents as! CGImage?, img.height > 0 {
                let r = CGFloat(img.width) / CGFloat(img.height)
                size = r > maxW / maxH ? CGSize(width: maxW, height: maxW / r) : CGSize(width: maxH * r, height: maxH)
            }
            logoHost.frame = NSRect(x: 20, y: play.frame.minY - 18 - size.height, width: size.width, height: size.height)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            logo.layer.frame = logoHost.bounds
            CATransaction.commit()
        } else {
            let t = bigTitle.sizeThatFits(NSSize(width: maxW, height: 200))
            bigTitle.frame = NSRect(x: 20, y: play.frame.minY - 18 - t.height, width: maxW, height: t.height)
        }
        heart.frame = NSRect(x: b.width - 20 - 40, y: b.height - 20 - 40, width: 40, height: 40)
        heart.layer?.cornerRadius = 20
        pauseButton.frame = NSRect(x: heart.frame.minX - 8 - 32, y: heart.frame.midY - 16, width: 32, height: 32)
        muteButton.frame = NSRect(x: pauseButton.frame.minX - 8 - 32, y: pauseButton.frame.minY, width: 32, height: 32)
        if case .front = depth {} else { setDepth(depth, animated: false) }
    }

    // MARK: Hover and click (front card only)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { if depth == .front { setHover(true) } }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    /// The picture eases in, the logo lifts, a rim of light comes up.
    private func setHover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.9 : 0.6)
        CATransaction.setAnimationTimingFunction(Theme.expoOut)
        picture.layer.transform = on ? CATransform3DMakeScale(1.045, 1.045, 1) : CATransform3DIdentity
        rim.borderColor = NSColor.white.withAlphaComponent(on ? 0.28 : 0.1).cgColor
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(Theme.expoOut)
        let lift = PillButton.lift(logoHost.bounds, dy: on ? -5 : 0, scale: on ? 1.035 : 1)
        logoHost.layer?.transform = lift
        bigTitle.layer?.transform = PillButton.lift(bigTitle.bounds, dy: on ? -5 : 0, scale: 1)
        CATransaction.commit()
    }

    override func resetCursorRects() { if depth == .front { addCursorRect(bounds, cursor: .pointingHand) } }

    override func mouseUp(with event: NSEvent) {
        // The whole front card opens the title; its buttons handle their own clicks.
        guard depth == .front, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseUp(with: event)
            return
        }
        onOpen?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var debugState: String {
        let f = holder.frame
        return "\(title) \(depth) view=\(Int(frame.minX)),\(Int(frame.width))x\(Int(frame.height)) holder=\(Int(f.minX))..\(Int(f.maxX)) "
            + "opacity=\(holder.opacity) picture=\(picture.layer.contents != nil) clips=\(layer?.masksToBounds ?? false) hidden=\(isHidden)"
    }
}

// MARK: - Now watching

@MainActor
final class NowWatchingView: FlippedView {
    private let ctx: NativeContext
    private let heading = makeLabel("Now watching", font: Theme.display(20, .semibold), color: Theme.palette.ink)
    private let bar = CALayer()
    private let shine = ShadeLayer()
    private var rows: [NowWatchingRow] = []
    var onHeight: (() -> Void)?

    init(ctx: NativeContext) {
        self.ctx = ctx
        super.init(frame: .zero)
        // `.board-glass-panel`: a dark tint, a fine rim, a lit top edge.
        layer?.cornerRadius = 22
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.palette.void.withAlphaComponent(0.5).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.7
        layer?.shadowRadius = 25
        layer?.shadowOffset = CGSize(width: 0, height: -18)
        layer?.masksToBounds = false
        shine.set([NSColor.white.withAlphaComponent(0.085), NSColor.white.withAlphaComponent(0.025), NSColor.white.withAlphaComponent(0.025)], at: [0, 0.55, 1])
        shine.cornerRadius = 22
        shine.masksToBounds = true
        layer?.addSublayer(shine)
        bar.backgroundColor = Theme.palette.accent.cgColor
        bar.cornerRadius = 2.5
        bar.shadowColor = Theme.palette.accent.cgColor
        bar.shadowOpacity = 0.55
        bar.shadowRadius = 7
        bar.shadowOffset = .zero
        layer?.addSublayer(bar)
        addSubview(heading)
        isHidden = true
        reload()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        let api = ctx.api
        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "UserItems/Resume", [
                "userId": api.session.userId, "limit": "12", "mediaTypes": "Video",
                "fields": "PrimaryImageAspectRatio,MediaSourceCount,ProviderIds", "enableImageTypes": "Primary,Backdrop,Thumb",
            ]) { r in
                guard let self else { return }
                var seen = Set<String>()
                let items = r.Items.filter { seen.insert(($0.isEpisode ? $0.SeriesId : $0.Id) ?? $0.Id).inserted }.prefix(12)
                self.rows.forEach { $0.removeFromSuperview() }
                self.rows = items.map { item in
                    let row = NowWatchingRow(item: item, ctx: self.ctx)
                    self.addSubview(row)
                    return row
                }
                self.isHidden = self.rows.isEmpty
                // New rows start at a zero frame: lay them out even when the
                // panel's own size has not changed (1.3.9 stacked them all in
                // its top left corner after the first refresh).
                self.needsLayout = true
                self.onHeight?()
            }
        }
    }

    /// The deck's height, when the panel sits beside it; nil under it.
    var fixedHeight: CGFloat? {
        didSet { if fixedHeight != oldValue { needsLayout = true } }
    }

    private static let head: CGFloat = 20 + 28 + 16
    private static let row: CGFloat = 68
    private static let gap: CGFloat = 16

    /// How many rows the panel shows: what fits beside the deck, else three.
    private var fit: Int {
        guard let h = fixedHeight else { return min(3, rows.count) }
        let room = h - NowWatchingView.head - 20
        return min(rows.count, max(1, Int((room + NowWatchingView.gap) / (NowWatchingView.row + NowWatchingView.gap))))
    }

    func height(for width: CGFloat) -> CGFloat {
        if isHidden { return 0 }
        if let h = fixedHeight { return h }
        let n = CGFloat(fit)
        return NowWatchingView.head + n * NowWatchingView.row + max(0, n - 1) * NowWatchingView.gap + 20
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shine.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 22, cornerHeight: 22, transform: nil)
        let hs = heading.fitSize
        bar.frame = CGRect(x: 20, y: 20 + (28 - 19) / 2, width: 5, height: 19)
        CATransaction.commit()
        heading.frame = NSRect(x: 35, y: 20 + (28 - hs.height) / 2, width: bounds.width - 55, height: hs.height)
        var y = NowWatchingView.head
        let shown = fit
        for (i, r) in rows.enumerated() {
            r.isHidden = i >= shown
            r.frame = NSRect(x: 20, y: y, width: bounds.width - 40, height: NowWatchingView.row)
            y += NowWatchingView.row + NowWatchingView.gap
        }
    }
}

@MainActor
final class NowWatchingRow: FlippedView {
    private let item: JFItem
    private let ctx: NativeContext
    private let thumb = RemoteImage()
    private let playDot = CAShapeLayer()
    private let dim = CALayer()
    private let title = makeLabel(font: Theme.text(15, .semibold), color: Theme.palette.ink)
    private let meta = makeLabel(font: Theme.text(12), color: Theme.palette.muted)
    private let percent = makeLabel(font: Theme.text(11, .semibold), color: Theme.palette.accent)
    private let track = CALayer()
    private let fill = CALayer()
    /// The thumbnail's rounded clip: picture, shade, play mark and progress.
    private let box = CALayer()
    private var chips: [NSView] = []
    private var tracking: NSTrackingArea?

    init(item: JFItem, ctx: NativeContext) {
        self.item = item
        self.ctx = ctx
        super.init(frame: .zero)
        box.cornerRadius = 12
        box.cornerCurve = .continuous
        box.masksToBounds = true
        box.backgroundColor = Theme.palette.void2.cgColor
        box.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        box.borderWidth = 1
        layer?.addSublayer(box)
        box.addSublayer(thumb.layer)
        // How far in, along the thumbnail's foot (the Surprise theme's resume
        // cards, and every Continue watching card).
        track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.backgroundColor = Theme.palette.accent.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        track.isHidden = item.progress == nil
        percent.stringValue = item.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
        percent.isHidden = item.progress == nil
        addSubview(percent)
        dim.backgroundColor = Theme.palette.void.withAlphaComponent(0.25).cgColor
        box.addSublayer(dim)
        playDot.fillColor = NSColor.white.withAlphaComponent(0.25).cgColor
        playDot.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        playDot.lineWidth = 1
        box.addSublayer(playDot)
        box.addSublayer(track)
        thumb.load(ctx.art.wide(item, width: 320), points: 120, scale: NSScreen.main?.backingScaleFactor ?? 2)
        title.stringValue = item.isEpisode ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? "")
        addSubview(title)
        if item.isEpisode {
            for t in [item.ParentIndexNumber.map { "\($0) season" }, item.IndexNumber.map { "\($0) episode" }].compactMap({ $0 }) {
                let v = FlippedView()
                v.layer?.borderColor = Theme.palette.glassBorder.cgColor
                v.layer?.borderWidth = 1
                v.layer?.cornerRadius = 6
                let l = makeLabel(t, font: Theme.text(10.5), color: Theme.palette.ink.withAlphaComponent(0.75))
                v.addSubview(l)
                let s = l.fitSize
                v.frame = NSRect(x: 0, y: 0, width: s.width + 12, height: s.height + 4)
                l.frame = NSRect(x: 6, y: 2, width: s.width, height: s.height)
                chips.append(v)
                addSubview(v)
            }
        }
        meta.stringValue = item.isEpisode
            ? "S\(item.ParentIndexNumber ?? 0) · E\(item.IndexNumber ?? 0)" + (item.runtimeText.map { " · \($0)" } ?? "")
            : CardText.meta(item)
        addSubview(meta)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        box.frame = CGRect(x: 0, y: 0, width: 120, height: 68)
        thumb.layer.frame = box.bounds
        dim.frame = box.bounds
        let r: CGFloat = 16
        playDot.path = CGPath(ellipseIn: CGRect(x: 60 - r, y: 34 - r, width: r * 2, height: r * 2), transform: nil)
        track.frame = CGRect(x: 0, y: 65, width: 120, height: 3)
        fill.bounds = CGRect(x: 0, y: 0, width: 120 * (item.progress ?? 0), height: 3)
        fill.position = CGPoint(x: 0, y: 1.5)
        CATransaction.commit()
        let x: CGFloat = 134
        let w = bounds.width - x
        let ts = title.fitSize
        var y: CGFloat = chips.isEmpty ? 14 : 2
        title.frame = NSRect(x: x, y: y, width: min(ts.width, w), height: ts.height)
        y = title.frame.maxY + 6
        var cx = x
        for c in chips {
            c.frame.origin = NSPoint(x: cx, y: y)
            cx = c.frame.maxX + 6
        }
        if !chips.isEmpty { y = (chips.first?.frame.maxY ?? y) + 6 }
        let ms = meta.fitSize, ps = percent.fitSize
        let room = w - (percent.isHidden ? 0 : ps.width + 8)
        meta.frame = NSRect(x: x, y: y, width: min(ms.width, room), height: ms.height)
        percent.frame = NSRect(x: meta.frame.maxX + 8, y: y + (ms.height - ps.height) / 2, width: ps.width, height: ps.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        dim.backgroundColor = Theme.palette.void.withAlphaComponent(0.45).cgColor
        title.textColor = Theme.palette.accent
    }
    override func mouseExited(with event: NSEvent) {
        dim.backgroundColor = Theme.palette.void.withAlphaComponent(0.25).cgColor
        title.textColor = Theme.palette.ink
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        // The picture resumes; the words open the title (as the web row).
        if p.x < 124 { ctx.play(item.Id) } else { ctx.openItem(item) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Genre chips

@MainActor
final class GenreChipsView: FlippedView {
    private let ctx: NativeContext
    private let label = makeLabel("Find by genre", font: Theme.display(15, .semibold), color: Theme.palette.ink)
    private let scroll = StripScrollView()
    private let strip = FlippedView()
    private var chips: [PillButton] = []
    var onHeight: (() -> Void)?

    init(ctx: NativeContext) {
        self.ctx = ctx
        super.init(frame: .zero)
        addSubview(label)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        addSubview(scroll)
        isHidden = true
        load()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func load() {
        let api = ctx.api
        Task { [weak self] in
            await api.load(JFItems.self, .jellyfin, "Genres", [
                "userId": api.session.userId, "sortBy": "SortName", "recursive": "true",
                "includeItemTypes": "Movie,Series",
            ]) { r in
                guard let self else { return }
                self.chips.forEach { $0.removeFromSuperview() }
                self.chips = r.Items.prefix(14).compactMap { g in
                    guard let name = g.Name else { return nil }
                    let b = PillButton(name, style: .tinted(Theme.palette.void.withAlphaComponent(0.45),
                                                            NSColor.white.withAlphaComponent(0.06), Theme.palette.ink.withAlphaComponent(0.85)),
                                       height: 42, fontSize: 13.5)
                    b.border = Theme.palette.glassBorder
                    b.action = { [weak self] in
                        self?.ctx.open("/genre/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))
                    }
                    self.strip.addSubview(b)
                    return b
                }
                self.isHidden = self.chips.isEmpty
                self.needsLayout = true
                self.onHeight?()
            }
        }
    }

    override func layout() {
        super.layout()
        // On one line, as the web's (`whitespace-nowrap`), with the strip 16 after it.
        let ls = label.fitSize
        label.frame = NSRect(x: 0, y: (bounds.height - ls.height) / 2, width: ls.width, height: ls.height)
        let sx = ls.width + 16
        scroll.frame = NSRect(x: sx, y: 0, width: max(0, bounds.width - sx), height: bounds.height)
        var x: CGFloat = 0
        for c in chips {
            c.sizeToFit()
            c.frame = NSRect(x: x, y: 2, width: c.frame.width + 8, height: 42)
            x = c.frame.maxX + 12
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(x, scroll.bounds.width), height: bounds.height)
    }
}
