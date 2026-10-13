import AppKit

// Dev-only stand-ins for the mpv player and its video layer, so the app can be
// built and its pages tested on a Mac without libmpv. Playback does nothing.
final class MpvPlayer {
    init() { DispatchQueue.main.async { MainActor.assumeIsolated { DevAutomation.start() } } }
    var onSignal: ((String, [Any]) -> Void)?
    var onVideoActive: ((Bool) -> Void)?
    func load(url: String, options: [String: Any], audio: Any, subtitle: Any) { NSLog("[dev] load %@", url) }
    func seekTo(ms: Double) {}
    func play() {}
    func pause() {}
    func stop() {}
    func setVolume(_ v: Double) {}
    func setMuted(_ m: Bool) {}
    func setPlaybackRate(_ r: Double) {}
    func setAudioStream(_ s: Any) {}
    func setSubtitleStream(_ s: Any) {}
    func userCommand(_ c: String) {}
    func shutdown() {}
}

final class VideoLayer: CALayer {
    func showFrames() {}
    func blankUntilNextFrame() {}
    func shutdown() {}
}

final class VideoView: NSView {
    let videoLayer = VideoLayer()
    init(player: MpvPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        videoLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}
