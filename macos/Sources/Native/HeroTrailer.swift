import AppKit
import AVFoundation
import VideoToolbox

/*
 * A title's local trailer over the hero artwork, as Mahfin's HeroTrailer.tsx
 * plays it: the backdrop holds alone for 1.2 s, then the trailer fades in over
 * 0.9 s, muted, at 1.06 so the letterboxing baked into scope trailers is
 * cropped away; it fades out over 0.6 s ahead of the slide changing. Mute and
 * pause sit at the hero's bottom right once something is playing.
 *
 * Nothing at all happens for a title without a trailer (most of the library),
 * for one this Mac cannot decode (AV1 needs an M3 or later), or when the
 * system asks for reduced motion.
 */
@MainActor
final class HeroTrailer {
    static let holdSeconds: TimeInterval = 1.2
    static let fadeInSeconds: TimeInterval = 0.9
    static let fadeOutSeconds: TimeInterval = 0.6

    struct Clip { let id: String; let url: URL; let seconds: Double }

    /// Holds the player layer; the hero moves it with the backdrop's parallax.
    let host = CALayer()
    private var video = HeroTrailer.makeLayer()
    private var frame = CGRect.zero
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private let api: MahfinAPI
    /// What each title's trailer turned out to be, nil for none (asked once).
    private var clips: [String: Clip?] = [:]
    private var token = 0
    private(set) var visible = false
    private(set) var muted = true
    private(set) var paused = false
    /// Paused by the viewer, so scrolling back must not resume it. Per clip.
    private var userPaused = false
    /// Sound is a setting, kept from one trailer to the next.
    private var soundOn = false
    private var offscreen = false
    private var occluded = false
    private var inactive = false
    private var held: Bool { inactive || offscreen || occluded }

    /// The trailer's length, once known — the hero's countdown follows it.
    var onDuration: ((Double) -> Void)?
    /// Raised by the controls: sound on or a deliberate pause holds the slide.
    var onEngaged: ((Bool) -> Void)?
    /// Show or hide the controls, and what they should say.
    var onControls: (() -> Void)?

    init(api: MahfinAPI) {
        self.api = api
        host.masksToBounds = false
        host.addSublayer(video)
    }

    private static func makeLayer() -> AVPlayerLayer {
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspectFill
        l.opacity = 0
        l.backgroundColor = NSColor.clear.cgColor
        return l
    }

    func layout(_ frame: CGRect) {
        self.frame = frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.frame = frame
        place(video)
        CATransaction.commit()
    }

    /// Slightly beyond cover: these are scope films inside a taller frame
    /// (1920x1012 for a 1920x804 picture), and 6% overscan eats the bars.
    private func place(_ l: AVPlayerLayer) {
        l.bounds = CGRect(origin: .zero, size: frame.size)
        l.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        l.setAffineTransform(CGAffineTransform(scaleX: 1.06, y: 1.06))
    }

    /// The slide changed to `itemId`: stop whatever was playing and line up its trailer.
    func load(_ itemId: String) {
        token += 1
        let t = token
        tearDown(fade: true)
        userPaused = false
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let shownAt = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            guard let self, let clip = await self.clip(for: itemId), t == self.token else { return }
            self.onDuration?(clip.seconds)
            let item = AVPlayerItem(url: clip.url)
            item.preferredForwardBufferDuration = 6
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.preventsDisplaySleepDuringVideoPlayback = false
            p.allowsExternalPlayback = false
            self.player = p
            self.video.player = p
            self.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fade(in: false, seconds: HeroTrailer.fadeInSeconds) }
            }
            // The artwork's beat on its own, which is also cover for the first bytes.
            let wait = HeroTrailer.holdSeconds - (CACurrentMediaTime() - shownAt)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            guard t == self.token else { return }
            // Waits for a frame, so the fade begins on picture and not on black.
            while !(item.status == .readyToPlay && (self.video.isReadyForDisplay || self.held)) {
                if item.status == .failed { return }
                if item.status == .readyToPlay && p.rate == 0 && !self.held { p.play() }
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard t == self.token else { return }
                if CACurrentMediaTime() - shownAt > 12 { return }
            }
            p.isMuted = !self.soundOn
            self.muted = p.isMuted
            self.paused = false
            if self.held { p.pause() } else { p.play() }
            self.visible = true
            self.lastStart = CACurrentMediaTime() - shownAt
            self.fade(in: true, seconds: HeroTrailer.fadeInSeconds)
            self.onControls?()
        }
    }

    /// Looks the next slide's trailer up (and checks this Mac can draw it)
    /// while the current one plays, so its own slide only waits for video.
    func prefetch(_ itemId: String) {
        guard clips[itemId] == nil else { return }
        Task { @MainActor [weak self] in _ = await self?.clip(for: itemId) }
    }

    /// Seconds from the slide appearing to its trailer fading in, last time.
    private(set) var lastStart: Double = 0

    /// Fades out ahead of the slide changing.
    func leave() {
        guard visible else { return }
        fade(in: false, seconds: HeroTrailer.fadeOutSeconds)
    }

    /// The page went away (or came back).
    func setActive(_ on: Bool) {
        inactive = !on
        resumeOrPause()
    }

    /// The hero scrolled off: less than a quarter of it showing is not worth decoding.
    func setOffscreen(_ off: Bool) {
        guard off != offscreen else { return }
        offscreen = off
        resumeOrPause()
    }

    /// The window is covered or minimised.
    func setOccluded(_ hidden: Bool) {
        guard hidden != occluded else { return }
        occluded = hidden
        resumeOrPause()
    }

    private func resumeOrPause() {
        guard let p = player, visible else { return }
        if held { p.pause() } else if !userPaused { p.play() }
    }

    var debugState: String {
        "trailer[visible=\(visible) rate=\(player?.rate ?? -1) muted=\(muted) inactive=\(inactive) offscreen=\(offscreen) occluded=\(occluded) ready=\(video.isReadyForDisplay) start=\(String(format: "%.2f", lastStart))s]"
    }

    func toggleMute() {
        guard let p = player else { return }
        let wantSound = p.isMuted
        p.isMuted = !wantSound
        soundOn = wantSound
        muted = p.isMuted
        onEngaged?(wantSound)
        onControls?()
    }

    func togglePause() {
        guard let p = player else { return }
        if p.rate == 0 {
            userPaused = false
            paused = false
            p.play()
            onEngaged?(soundOn)
        } else {
            userPaused = true
            paused = true
            p.pause()
            onEngaged?(true)
        }
        onControls?()
    }

    private func fade(in show: Bool, seconds: TimeInterval) {
        if !show { visible = false; onControls?() }
        let from = video.presentation()?.opacity ?? video.opacity
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = show ? 1 : 0
        a.duration = seconds
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.opacity = show ? 1 : 0
        CATransaction.commit()
        video.add(a, forKey: "fade")
        if !show {
            let p = player
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                // Still the same clip and still hidden: stop it decoding.
                guard let self, self.player === p, !self.visible else { return }
                p?.pause()
            }
        }
    }

    private func tearDown(fade: Bool) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        let old = player
        player = nil
        if visible && fade {
            // A slide changed by hand: the old clip fades out over the
            // backdrop's crossfade, in its own layer, and the next one gets a
            // fresh layer underneath.
            let outgoing = video
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = outgoing.presentation()?.opacity ?? 1
            a.toValue = 0
            a.duration = HeroTrailer.fadeOutSeconds
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            outgoing.opacity = 0
            CATransaction.commit()
            outgoing.add(a, forKey: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + HeroTrailer.fadeOutSeconds + 0.05) {
                old?.pause()
                outgoing.player = nil
                outgoing.removeFromSuperlayer()
            }
            let fresh = HeroTrailer.makeLayer()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            place(fresh)
            host.insertSublayer(fresh, at: 0)
            CATransaction.commit()
            video = fresh
        } else {
            old?.pause()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            video.removeAllAnimations()
            video.opacity = 0
            video.player = nil
            CATransaction.commit()
        }
        visible = false
        onControls?()
    }

    // MARK: Finding the trailer

    private func clip(for itemId: String) async -> Clip? {
        if let known = clips[itemId] { return known }
        let found = await lookUp(itemId)
        clips[itemId] = .some(found)
        return found
    }

    private func lookUp(_ itemId: String) async -> Clip? {
        let s = api.session
        guard let list = try? await api.fetch([JFItem].self, .jellyfin, "/Items/\(itemId)/LocalTrailers", ["userId": s.userId]),
              let first = list.first else { return nil }
        // The web's address: the file as it is, with the key in the query
        // because AVPlayer gives no supported way to add a header.
        var c = URLComponents(url: s.server.appendingPathComponent("/Videos/\(first.Id)/stream.mp4"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "ApiKey", value: s.token)]
        guard let url = c.url, await HeroTrailer.decodable(url) else { return nil }
        let seconds = Double(first.RunTimeTicks ?? 0) / 10_000_000
        return Clip(id: first.Id, url: url, seconds: seconds)
    }

    /// Whether this Mac can draw the trailer's picture. AVFoundation answers
    /// "playable" for an AV1 file on an M1/M2 and then plays only its sound.
    private static func decodable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
              (try? await track.load(.isDecodable)) == true,
              let formats = try? await track.load(.formatDescriptions) else { return false }
        for f in formats where CMFormatDescriptionGetMediaSubType(f) == kCMVideoCodecType_AV1 {
            if !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { return false }
        }
        return true
    }
}

/// Mute or pause: 32 pt, a fine white ring on dark glass, 70% until reached for.
final class TrailerButton: FlippedView {
    private let glyph = CAShapeLayer()
    var action: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        layer?.backgroundColor = Theme.palette.void.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.cornerRadius = 16
        layer?.opacity = 0.7
        glyph.frame = CGRect(x: 8.5, y: 8.5, width: 15, height: 15)
        glyph.strokeColor = Theme.palette.ink.cgColor
        glyph.lineCap = .round
        glyph.lineJoin = .round
        layer?.addSublayer(glyph)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ icon: PillButton.Icon) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.path = PillButton.path(icon, 15)
        let solid = icon == .play || icon == .pause
        glyph.fillColor = solid ? Theme.palette.ink.cgColor : nil
        glyph.lineWidth = solid ? 0 : 1.6
        CATransaction.commit()
    }

    private func look(scale: CGFloat, opacity: Float, duration: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer?.transform = PillButton.lift(bounds, dy: 0, scale: scale)
        layer?.opacity = opacity
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; look(scale: 1.05, opacity: 1, duration: 0.15) }
    override func mouseExited(with event: NSEvent) { hovering = false; look(scale: 1, opacity: 0.7, duration: 0.15) }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) { look(scale: 0.95, opacity: 1, duration: 0.08) }
    override func mouseUp(with event: NSEvent) {
        look(scale: hovering ? 1.05 : 1, opacity: hovering ? 1 : 0.7, duration: 0.15)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
