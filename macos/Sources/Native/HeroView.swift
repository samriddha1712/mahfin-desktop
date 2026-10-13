import AppKit
import QuartzCore

/*
 * The home page's hero, as Mahfin's Hero.tsx draws it under the top bar: a
 * full-bleed backdrop with a slow zoom, the two scrims, "Featured tonight",
 * the logo (or the title), the rating ticket and meta line, three lines of
 * overview, Play and More info, and a pager whose active dot is the
 * countdown. Seven titles, nine seconds each.
 */
final class HeroView: FlippedView {
    static let rotateSeconds: TimeInterval = 9

    private let ctx: NativeContext
    private let backdrops = [RemoteImage(), RemoteImage()]
    private var front = 0
    private let scrimBottom = ShadeLayer()
    private let scrimLeft = CAGradientLayer()
    private let eyebrow = makeLabel("FEATURED TONIGHT", font: Theme.text(12.5, .semibold), color: Theme.palette.accent)
    private let logo = RemoteImage()
    private let titleLabel = makeLabel(font: Theme.display(60, .heavy), color: Theme.palette.ink, lines: 2)
    private let ticket = makeLabel(font: Theme.text(13, .semibold), color: Theme.palette.accent)
    private let ticketBox = CAShapeLayer()
    private let metaLabel = makeLabel(font: Theme.text(14), color: Theme.palette.muted)
    private let overview = makeLabel(font: Theme.text(15), color: Theme.palette.ink.withAlphaComponent(0.75), lines: 3)
    private let play = PillButton("Play", style: .accent, height: 48, fontSize: 16)
    private let info = PillButton("More info", style: .glass, height: 48, fontSize: 16)
    private var dots: [CALayer] = []
    private let dotFill = CALayer()
    private var timer: Timer?
    private var logoSize = CGSize.zero
    private(set) var items: [JFItem] = []
    private var index = 0

    init(ctx: NativeContext) {
        self.ctx = ctx
        super.init(frame: .zero)
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.palette.void.cgColor
        for b in backdrops {
            b.layer.contentsGravity = .resizeAspectFill
            b.layer.masksToBounds = true
            layer?.addSublayer(b.layer)
        }
        let v = Theme.palette.void
        // Top to foot: lightly dimmed under the bar, solid page colour at the foot.
        scrimBottom.set([v.withAlphaComponent(0.2), v.withAlphaComponent(0.3), v])
        scrimLeft.colors = [v.withAlphaComponent(0.85).cgColor, v.withAlphaComponent(0.25).cgColor, NSColor.clear.cgColor]
        scrimLeft.locations = [0, 0.5, 1]
        scrimLeft.startPoint = CGPoint(x: 0, y: 0.5)
        scrimLeft.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(scrimBottom)
        layer?.addSublayer(scrimLeft)
        logo.layer.contentsGravity = .resizeAspect
        logo.layer.masksToBounds = false
        logo.onLoad = { [weak self] in self?.needsLayout = true }
        layer?.addSublayer(logo.layer)
        ticketBox.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        ticketBox.strokeColor = Theme.palette.accent.withAlphaComponent(0.5).cgColor
        ticketBox.lineDashPattern = [3, 2]
        ticketBox.lineWidth = 1
        layer?.addSublayer(ticketBox)
        for v in [eyebrow, titleLabel, ticket, metaLabel, overview] { addSubview(v) }
        eyebrow.attributedStringValue = NSAttributedString(string: "FEATURED TONIGHT", attributes: [
            .kern: 2.0, .font: Theme.text(12.5, .semibold), .foregroundColor: Theme.palette.accent,
        ])
        play.icon = .play
        info.icon = nil
        addSubview(play)
        addSubview(info)
        play.action = { [weak self] in
            guard let self, self.index < self.items.count else { return }
            ctx.play(self.items[self.index].Id)
        }
        info.action = { [weak self] in
            guard let self, self.index < self.items.count else { return }
            ctx.openItem(self.items[self.index])
        }
        dotFill.backgroundColor = Theme.palette.accent.cgColor
        dotFill.cornerRadius = 2
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
                d.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
                d.cornerRadius = 2
                d.masksToBounds = true
                layer?.addSublayer(d)
                return d
            }
            index = 0
            show(0, animated: false)
        }
    }

    private var showToken = 0

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
        if animated, let url = ctx.art.backdrop(items[target], width: 1920),
           ImagePipeline.shared.cached(url, pixels: backdropPixels()) == nil {
            let px = backdropPixels()
            Task { @MainActor [weak self] in
                _ = await ImagePipeline.shared.image(url, pixels: px)
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
        // Crossfade: the back layer takes the new picture and fades in over 1 s.
        let next = animated ? 1 - front : front
        let incoming = backdrops[next]
        incoming.load(ctx.art.backdrop(item, width: 1920), points: max(bounds.width, 1280), scale: scale)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 1.0 : 0)
        backdrops[next].layer.zPosition = 1
        backdrops[1 - next].layer.zPosition = 0
        backdrops[next].layer.opacity = 1
        CATransaction.commit()
        front = next
        kenBurns(incoming.layer)

        logo.load(ctx.art.logo(item, width: 760), points: 380, scale: scale)
        titleLabel.stringValue = item.Name ?? ""
        let hasLogo = ctx.art.logo(item, width: 760) != nil
        titleLabel.isHidden = hasLogo
        logo.layer.isHidden = !hasLogo
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
        needsLayout = true
        startCountdown()
        // The next slide's picture, ahead of time.
        if items.count > 1, let u = ctx.art.backdrop(items[(index + 1) % items.count], width: 1920) {
            ImagePipeline.shared.prefetch([u], pixels: backdropPixels())
        }
    }

    private func kenBurns(_ l: CALayer) {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0
        a.toValue = 1.07
        a.duration = HeroView.rotateSeconds + 1
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        a.timingFunction = CAMediaTimingFunction(name: .linear)
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
        layoutDots()
        dotFill.removeAllAnimations()
        let a = CABasicAnimation(keyPath: "bounds.size.width")
        a.fromValue = 0
        a.toValue = 40
        a.duration = HeroView.rotateSeconds
        dotFill.add(a, forKey: "countdown")
    }

    /// Stops rotating while the page is not on screen.
    func setActive(_ on: Bool) {
        if on { startCountdown() } else { timer?.invalidate(); timer = nil }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for b in backdrops {
            b.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            b.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // Framed toward the top, as `background-position: center 20%`.
            b.layer.contentsGravity = .resizeAspectFill
        }
        scrimBottom.frame = bounds
        scrimLeft.frame = bounds
        CATransaction.commit()

        let x = RowView.inset
        let width = min(672, bounds.width - x * 2)
        // The copy sits over the lower part, clear of the rows that overlap
        // the hero's last 24 points.
        var y = bounds.height - 96
        play.sizeToFit(); info.sizeToFit()
        y -= 48
        play.frame = NSRect(x: x, y: y, width: play.frame.width + 8, height: 48)
        info.frame = NSRect(x: play.frame.maxX + 12, y: y, width: info.frame.width, height: 48)
        y -= 22
        let ov = overview.sizeThatFits(NSSize(width: width, height: 200))
        let ovh = min(ov.height, 66)
        y -= ovh
        overview.frame = NSRect(x: x, y: y, width: width, height: ovh)
        y -= 14 + 26
        let tw = ticket.isHidden ? 0 : ticket.fitSize.width + 24
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ticketBox.isHidden = ticket.isHidden
        ticketBox.path = CGPath(roundedRect: CGRect(x: x, y: y, width: tw, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil)
        CATransaction.commit()
        ticket.frame = NSRect(x: x + 12, y: y + 4, width: tw, height: 18)
        metaLabel.frame = NSRect(x: x + tw + (tw > 0 ? 12 : 0), y: y + 4, width: width, height: 18)
        y -= 18
        if !logo.layer.isHidden {
            let maxW: CGFloat = 380, maxH: CGFloat = 96
            var size = CGSize(width: maxW, height: maxH)
            if let img = logo.layer.contents as! CGImage?, img.width > 0 {
                let r = CGFloat(img.width) / CGFloat(img.height)
                size = r > maxW / maxH ? CGSize(width: maxW, height: maxW / r) : CGSize(width: maxH * r, height: maxH)
            }
            y -= size.height
            CATransaction.begin(); CATransaction.setDisableActions(true)
            logo.layer.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            CATransaction.commit()
        } else {
            let t = titleLabel.sizeThatFits(NSSize(width: width, height: 200))
            y -= t.height
            titleLabel.frame = NSRect(x: x, y: y, width: width, height: t.height)
        }
        y -= 12 + 16
        eyebrow.frame = NSRect(x: x, y: y, width: width, height: 16)
        layoutDots()
    }

    private func layoutDots() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var x = bounds.width - RowView.inset
        let y = bounds.height - 96 - 24
        for (i, d) in dots.enumerated().reversed() {
            let w: CGFloat = i == index ? 40 : 8
            x -= w
            d.frame = CGRect(x: x, y: y, width: w, height: 4)
            x -= 6
        }
        if index < dots.count {
            dotFill.removeFromSuperlayer()
            dots[index].addSublayer(dotFill)
            dotFill.frame = CGRect(x: 0, y: 0, width: 40, height: 4)
            dotFill.position = CGPoint(x: 0, y: 2)
        }
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        // A click on the pager moves to that slide.
        let p = convert(event.locationInWindow, from: nil)
        for (i, d) in dots.enumerated() where d.frame.insetBy(dx: -4, dy: -10).contains(p) {
            show(i, animated: true)
            return
        }
    }
}
