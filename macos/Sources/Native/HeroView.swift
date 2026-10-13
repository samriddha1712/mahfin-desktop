import AppKit
import QuartzCore

/*
 * The home page's hero, as Mahfin's Hero.tsx draws it under the top bar: a
 * full-bleed backdrop with a slow zoom, the two scrims, "Featured tonight",
 * the logo (or the title), the rating ticket and meta line, three lines of
 * overview, Play and More info, and a pager whose active dot is the
 * countdown. Seven titles, nine seconds each.
 *
 * Motion, from globals.css: the copy rises in once (`.hero-enter`, 60 ms then
 * every 70 ms, 620 ms expo-out); as the page scrolls the backdrop drifts down
 * (`.hero-parallax`, 9% of its own height) and the copy rises and fades
 * (`.hero-copy`: −34 pt, gone by 69%); the backdrop zooms to 1.07 over 12 s.
 */
final class HeroView: FlippedView {
    static let rotateSeconds: TimeInterval = 9

    private let ctx: NativeContext
    private let backdrops = [RemoteImage(), RemoteImage()]
    /// The two backdrops' own layer, taller than the hero by 8% at each end so
    /// the parallax drift never shows its edge. The incoming backdrop is put on
    /// top by order inside it, never by zPosition (beta 1 lifted the picture
    /// over the hero's own words that way).
    private let backdropHost = CALayer()
    private var front = 0
    private let scrimBottom = ShadeLayer()
    private let scrimLeft = CAGradientLayer()
    /// The copy block, moved and faded as one by the scroll.
    private let copy = FlippedView()
    private let eyebrow = makeLabel("FEATURED TONIGHT", font: Theme.text(12.5, .semibold), color: Theme.palette.accent)
    private let logo = RemoteImage()
    private let logoView = FlippedView()
    private let titleLabel = makeLabel(font: Theme.display(60, .heavy), color: Theme.palette.ink, lines: 2)
    private let metaRow = FlippedView()
    private let ticket = makeLabel(font: Theme.text(13, .semibold), color: Theme.palette.accent)
    private let ticketBox = CAShapeLayer()
    private let metaLabel = makeLabel(font: Theme.text(14), color: Theme.palette.muted)
    private let overview = makeLabel(font: Theme.text(15), color: Theme.palette.ink.withAlphaComponent(0.75), lines: 3)
    private let buttons = FlippedView()
    private let play = PillButton("Play", style: .accent, height: 46, fontSize: 15)
    private let info = PillButton("More info", style: .glass, height: 46, fontSize: 15)
    private let pager = FlippedView()
    private let prevSlide = NudgeButton(direction: -1, diameter: 24, icon: 13)
    private let nextSlide = NudgeButton(direction: 1, diameter: 24, icon: 13)
    private var dots: [CALayer] = []
    private let dotFill = CALayer()
    private var timer: Timer?
    private(set) var items: [JFItem] = []
    private var index = 0
    private var entered = false
    private var scrollP: CGFloat = 0
    /// The current slide's colour, for the page's ambient glow.
    var onTint: ((NSColor) -> Void)?

    init(ctx: NativeContext) {
        self.ctx = ctx
        super.init(frame: .zero)
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.palette.void.cgColor
        backdropHost.masksToBounds = false
        layer?.addSublayer(backdropHost)
        for b in backdrops {
            b.layer.contentsGravity = .resizeAspectFill
            b.layer.masksToBounds = true
            backdropHost.addSublayer(b.layer)
        }
        ticket.isHidden = true
        let v = Theme.palette.void
        // Top to foot: lightly dimmed under the bar, solid page colour at the foot.
        scrimBottom.set([v.withAlphaComponent(0.2), v.withAlphaComponent(0.3), v])
        scrimLeft.colors = [v.withAlphaComponent(0.85).cgColor, v.withAlphaComponent(0.25).cgColor, NSColor.clear.cgColor]
        scrimLeft.locations = [0, 0.5, 1]
        scrimLeft.startPoint = CGPoint(x: 0, y: 0.5)
        scrimLeft.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(scrimBottom)
        layer?.addSublayer(scrimLeft)

        addSubview(copy)
        copy.layer?.masksToBounds = false
        eyebrow.attributedStringValue = NSAttributedString(string: "FEATURED TONIGHT", attributes: [
            .kern: 2.0, .font: Theme.text(12.5, .semibold), .foregroundColor: Theme.palette.accent,
        ])
        logo.layer.contentsGravity = .resizeAspect
        logo.layer.masksToBounds = false
        // `drop-shadow(0 4px 24px rgba(0,0,0,0.6))`.
        logo.layer.shadowColor = NSColor.black.cgColor
        logo.layer.shadowOpacity = 0.6
        logo.layer.shadowRadius = 12
        logo.layer.shadowOffset = CGSize(width: 0, height: -4)
        logo.onLoad = { [weak self] in self?.needsLayout = true }
        logoView.layer?.addSublayer(logo.layer)
        logoView.layer?.masksToBounds = false
        titleLabel.attributedStringValue = NSAttributedString(string: "")
        ticketBox.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        ticketBox.strokeColor = Theme.palette.accent.withAlphaComponent(0.5).cgColor
        ticketBox.lineDashPattern = [3, 2]
        ticketBox.lineWidth = 1
        metaRow.layer?.addSublayer(ticketBox)
        metaRow.addSubview(ticket)
        metaRow.addSubview(metaLabel)
        play.icon = .play
        play.radius = 12
        play.cta = true
        info.radius = 12
        buttons.addSubview(play)
        buttons.addSubview(info)
        buttons.layer?.masksToBounds = false
        pager.addSubview(prevSlide)
        pager.addSubview(nextSlide)
        for v in [eyebrow, logoView, titleLabel, metaRow, overview, buttons, pager] as [NSView] { copy.addSubview(v) }
        play.action = { [weak self] in
            guard let self, self.index < self.items.count else { return }
            ctx.play(self.items[self.index].Id)
        }
        info.action = { [weak self] in
            guard let self, self.index < self.items.count else { return }
            ctx.openItem(self.items[self.index])
        }
        prevSlide.action = { [weak self] in guard let self else { return }; self.show(self.index - 1, animated: true) }
        nextSlide.action = { [weak self] in guard let self else { return }; self.show(self.index + 1, animated: true) }
        dotFill.backgroundColor = Theme.palette.accent.cgColor
        dotFill.anchorPoint = CGPoint(x: 0, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ items: [JFItem]) {
        let same = items.map(\.Id) == self.items.map(\.Id)
        self.items = items
        if !same {
            for d in dots { d.removeFromSuperlayer() }
            dots = items.indices.map { _ in
                let d = CALayer()
                d.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
                d.cornerRadius = 3
                d.masksToBounds = true
                pager.layer?.addSublayer(d)
                return d
            }
            prevSlide.isHidden = items.count < 2
            nextSlide.isHidden = items.count < 2
            index = 0
            show(0, animated: false)
        }
    }

    private var showToken = 0

    private func logoPixels() -> Int {
        Int((380 * min(2, window?.backingScaleFactor ?? 2)).rounded(.up))
    }

    private func backdropPixels() -> Int {
        Int((max(bounds.width, 1280) * min(2, window?.backingScaleFactor ?? 2)).rounded(.up))
    }

    /// Moves to slide `i` — once its backdrop is decoded, so the words and the
    /// picture always change together.
    private func show(_ i: Int, animated: Bool) {
        guard !items.isEmpty else { return }
        let target = (i + items.count) % items.count
        showToken += 1
        let token = showToken
        let backdropURL = ctx.art.backdrop(items[target], width: 1920)
        let logoURL = ctx.art.logo(items[target], width: 760)
        let ready = (backdropURL.map { ImagePipeline.shared.cached($0, pixels: backdropPixels()) != nil } ?? true)
            && (logoURL.map { ImagePipeline.shared.cached($0, pixels: logoPixels()) != nil } ?? true)
        if animated && !ready {
            let bpx = backdropPixels(), lpx = logoPixels()
            Task { @MainActor [weak self] in
                // Picture and logo together, so the slide never changes with a
                // gap where its title belongs.
                async let b: CGImage? = backdropURL == nil ? nil : ImagePipeline.shared.image(backdropURL!, pixels: bpx)
                async let l: CGImage? = logoURL == nil ? nil : ImagePipeline.shared.image(logoURL!, pixels: lpx)
                _ = await (b, l)
                guard let self, token == self.showToken else { return }
                self.apply(target, animated: true)
            }
            return
        }
        apply(target, animated: animated)
    }

    private func apply(_ i: Int, animated: Bool) {
        index = i
        let item = items[index]
        let scale = window?.backingScaleFactor ?? 2
        let next = animated ? 1 - front : front
        let incoming = backdrops[next]
        incoming.onLoad = { [weak self, weak incoming] in
            guard let self, let img = incoming?.layer.contents as! CGImage? else { return }
            self.onTint?(ImagePipeline.vivid(ImagePipeline.average(img)))
        }
        incoming.load(ctx.art.backdrop(item, width: 1920), points: max(bounds.width, 1280), scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if backdropHost.sublayers?.last !== incoming.layer {
            incoming.layer.removeFromSuperlayer()
            backdropHost.addSublayer(incoming.layer)
        }
        CATransaction.commit()
        if animated {
            // Already decoded (`show` waits for it): a one-second crossfade.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 1.0
            fade.timingFunction = Theme.easeOut
            incoming.layer.add(fade, forKey: "crossfade")
        }
        front = next
        kenBurns(incoming.layer)

        logo.load(ctx.art.logo(item, width: 760), points: 380, scale: scale)
        let hasLogo = ctx.art.logo(item, width: 760) != nil
        titleLabel.attributedStringValue = NSAttributedString(string: item.Name ?? "", attributes: [
            .font: Theme.display(60, .heavy), .foregroundColor: Theme.palette.ink, .kern: -1.5,
        ])
        titleLabel.isHidden = hasLogo
        logoView.isHidden = !hasLogo
        if let r = item.CommunityRating, r > 0 {
            ticket.stringValue = "★ " + String(format: "%.1f", r)
            ticket.isHidden = false
        } else {
            ticket.isHidden = true
        }
        var meta: [String] = []
        if let y = item.ProductionYear { meta.append(String(y)) }
        meta.append(item.isSeries ? "Series" : (item.runtimeText ?? ""))
        if let g = item.Genres?.prefix(2), !g.isEmpty { meta.append(g.joined(separator: " · ")) }
        metaLabel.stringValue = meta.filter { !$0.isEmpty }.joined(separator: " · ")
        overview.stringValue = item.Overview ?? ""
        overview.isHidden = overview.stringValue.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        enterOnce()
        startCountdown()
        if items.count > 1 {
            let next = items[(index + 1) % items.count]
            if let u = ctx.art.backdrop(next, width: 1920) { ImagePipeline.shared.prefetch([u], pixels: backdropPixels()) }
            if let u = ctx.art.logo(next, width: 760) { ImagePipeline.shared.prefetch([u], pixels: logoPixels()) }
        }
    }

    /// `.hero-enter`: the copy's parts rise 10 pt and fade in, 60 ms then every
    /// 70 ms after, once — later slides change their words in place.
    private func enterOnce() {
        guard !entered else { return }
        entered = true
        let parts: [NSView] = [eyebrow, logoView.isHidden ? titleLabel : logoView, metaRow, overview, buttons, pager].filter { !$0.isHidden }
        for (n, v) in parts.enumerated() {
            guard let l = v.layer else { continue }
            let g = CAAnimationGroup()
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 10
            rise.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            g.animations = [rise, fade]
            g.duration = 0.62
            g.timingFunction = Theme.expoOut
            g.beginTime = CACurrentMediaTime() + 0.06 + 0.07 * Double(n)
            g.fillMode = .backwards
            l.add(g, forKey: "enter")
        }
    }

    /// The zoom to 1.07 over 12 s (`.hero-kenburns`).
    private func kenBurns(_ l: CALayer) {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0
        a.toValue = 1.07
        a.duration = 12
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        l.add(a, forKey: "kenburns")
    }

    private func startCountdown() {
        timer?.invalidate()
        guard items.count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: HeroView.rotateSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.show(self.index + 1, animated: true)
            }
        }
        layoutDots(animated: true)
        dotFill.removeAllAnimations()
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 0
        a.toValue = 1
        a.duration = HeroView.rotateSeconds
        dotFill.add(a, forKey: "countdown")
    }

    /// For dev builds' checks: which slide, and what each backdrop layer holds.
    var debugState: String {
        let b = backdrops.enumerated().map { i, r in
            "b\(i)[top=\(backdropHost.sublayers?.last === r.layer) op=\(r.layer.opacity) img=\(r.layer.contents != nil) url=\(r.url?.path.split(separator: "/")[1] ?? "-")]"
        }.joined(separator: " ")
        return "index=\(index) item=\(index < items.count ? items[index].Id : "-") front=\(front) " + b
    }

    /// Stops rotating while the page is not on screen.
    func setActive(_ on: Bool) {
        if on { startCountdown() } else { timer?.invalidate(); timer = nil }
    }

    /// How far the hero has scrolled out of view, 0…1 (`--scroll-p`).
    func setScrollProgress(_ p: CGFloat) {
        let p = max(0, min(1, p))
        guard abs(p - scrollP) > 0.0005 else { return }
        scrollP = p
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdropHost.setAffineTransform(CGAffineTransform(translationX: 0, y: p * 0.09 * backdropHost.bounds.height))
        copy.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -34 * p))
        copy.layer?.opacity = Float(max(0, 1 - p * 1.45))
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let extra = bounds.height * 0.08
        backdropHost.frame = bounds.insetBy(dx: 0, dy: -extra)
        for b in backdrops {
            b.layer.bounds = CGRect(origin: .zero, size: backdropHost.bounds.size)
            b.layer.position = CGPoint(x: backdropHost.bounds.midX, y: backdropHost.bounds.midY)
        }
        scrimBottom.frame = bounds
        scrimLeft.frame = bounds
        CATransaction.commit()

        let x = RowView.inset
        let width = min(672 - 40, bounds.width - x * 2)
        copy.frame = bounds
        // From the foot up (`pb-14`, then the pager, buttons, overview, meta,
        // title, eyebrow with the web's margins between them).
        var y = bounds.height - 56
        let hasPager = items.count > 1
        if hasPager {
            y -= 24
            pager.frame = NSRect(x: x, y: y, width: 400, height: 24)
            layoutPager()
            y -= 32
        }
        play.sizeToFit(); info.sizeToFit()
        let pw = play.frame.width + 8, iw = info.frame.width
        y -= 46
        buttons.frame = NSRect(x: x, y: y, width: pw + 12 + iw, height: 46)
        play.frame = NSRect(x: 0, y: 0, width: pw, height: 46)
        info.frame = NSRect(x: pw + 12, y: 0, width: iw, height: 46)
        if !overview.isHidden {
            y -= 24
            let ow = min(576, width)
            let h = min(overview.sizeThatFits(NSSize(width: ow, height: 200)).height, 74)
            y -= h
            overview.frame = NSRect(x: x, y: y, width: ow, height: h)
        }
        y -= 14 + 26
        let tw = ticket.isHidden ? 0 : ticket.fitSize.width + 24
        metaRow.frame = NSRect(x: x, y: y, width: width, height: 26)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ticketBox.isHidden = ticket.isHidden
        ticketBox.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: tw, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil)
        CATransaction.commit()
        ticket.frame = NSRect(x: 12, y: 4, width: tw, height: 18)
        metaLabel.frame = NSRect(x: tw + (tw > 0 ? 12 : 0), y: 4, width: width - tw, height: 18)
        y -= 12
        if !logoView.isHidden {
            let maxW: CGFloat = 380, maxH: CGFloat = 96
            var size = CGSize(width: maxW, height: maxH)
            if let img = logo.layer.contents as! CGImage?, img.width > 0 {
                let r = CGFloat(img.width) / CGFloat(img.height)
                size = r > maxW / maxH ? CGSize(width: maxW, height: maxW / r) : CGSize(width: maxH * r, height: maxH)
            }
            y -= 4 + size.height
            logoView.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            logo.layer.frame = logoView.bounds
            CATransaction.commit()
        } else {
            let t = titleLabel.sizeThatFits(NSSize(width: width, height: 200))
            y -= t.height
            titleLabel.frame = NSRect(x: x, y: y, width: width, height: t.height)
        }
        y -= 12 + 16
        eyebrow.frame = NSRect(x: x, y: y, width: width, height: 16)
    }

    private func layoutPager() {
        prevSlide.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        layoutDots(animated: false)
    }

    /// Dots 6 pt tall, 8 pt apart: the active one 40 wide and filling as the
    /// countdown, the rest 10. Between the two small arrows.
    private func layoutDots(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        CATransaction.setDisableActions(!animated)
        var x: CGFloat = 24 + 8
        for (i, d) in dots.enumerated() {
            let w: CGFloat = i == index ? 40 : 10
            d.frame = CGRect(x: x, y: 9, width: w, height: 6)
            x += w + 8
        }
        CATransaction.commit()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if index < dots.count {
            dotFill.removeFromSuperlayer()
            dots[index].addSublayer(dotFill)
            dotFill.bounds = CGRect(x: 0, y: 0, width: 40, height: 6)
            dotFill.position = CGPoint(x: 0, y: 3)
        }
        CATransaction.commit()
        nextSlide.frame = NSRect(x: x, y: 0, width: 24, height: 24)
    }

    override func mouseUp(with event: NSEvent) {
        // A click on a dot moves to that slide.
        let p = pager.convert(event.locationInWindow, from: nil)
        for (i, d) in dots.enumerated() where d.frame.insetBy(dx: -4, dy: -10).contains(p) {
            show(i, animated: true)
            return
        }
    }
}
