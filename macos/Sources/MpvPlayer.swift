import Foundation

/*
 * libmpv, driven the way Mahfin's web player drives the shell's `api.player`.
 *
 * The contract is the Qt shell's PlayerComponent, method for method and signal
 * for signal, because the web side (src/lib/mpvPlayer.ts in the Mahfin repo)
 * was written against it and is unchanged:
 *
 *   load(url, {startMilliseconds, autoplay}, metadata, audio, subtitle)
 *   seekTo(ms) play() pause() stop() setVolume(0-100) setMuted(bool)
 *   setPlaybackRate(thousandths) setAudioStream(n) setSubtitleStream(n | "#,url")
 *   setVideoRectangle(...) (always 0,0,0,0: the whole window) userCommand(cmd)
 *
 *   signals: playing paused buffering(percent) updateDuration(ms)
 *            positionUpdate(ms) finished error(message)
 *            bufferedRangesUpdated([{start,end}] in 100 ns ticks)
 *            playbackRateChanged(rate) stopped
 *
 * Track ids are mpv's: 1-based within their own type, -1 for off, and an
 * external subtitle arrives as "#,<url>". They are applied in the
 * `on_preloaded` hook, once mpv knows the file's tracks — the same moment the
 * Qt shell chose them.
 */
final class MpvPlayer {
    private(set) var handle: OpaquePointer?

    /// (signal name, arguments) for the page.
    var onSignal: ((String, [Any]) -> Void)?

    private enum State { case idle, buffering, playing, paused }
    private var state: State = .idle
    private var started = false        // first frame shown for the current file
    private var paused = false
    private var pausedForCache = false
    private var lastPositionMs: Double = -1
    private var positionSeconds: Double = 0

    private var pendingAudio: Any = 1
    private var pendingSubtitle: Any = -1

    init() {
        guard let mpv = mpv_create() else { fatalError("libmpv could not be created") }
        handle = mpv

        // The Qt shell's settings (PlayerComponent.cpp), less what only made
        // sense for its own window.
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("msg-level", "all=warn"),
            ("demuxer-mkv-probe-start-time", "no"),
            ("demuxer-lavf-probe-info", "yes"),
            ("audio-fallback-to-null", "yes"),
            ("ad-lavc-downmix", "no"),
            ("audio-client-name", "Mahfin"),
            ("title", "Mahfin"),
            ("cache-seek-min", "5000"),
            ("ytdl", "no"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("hwdec", "auto"),
            ("hwdec-codecs", "all"),
            ("hr-seek", "no"),
            ("keep-open", "no"),
            ("audio-swresample-o", "surround_mix_level=1"),
            ("deband", "yes"),
            // Compiled GPU shaders are kept between launches. The Qt build never
            // set this, so the first video of every session stuttered while
            // they were compiled again.
            ("gpu-shader-cache-dir", MpvPlayer.cacheDir("shaders")),
            ("icc-cache-dir", MpvPlayer.cacheDir("icc")),
        ]
        for (k, v) in options { mpv_set_option_string(mpv, k, v) }

        // The bundled CA list: a copied-in libmpv cannot see the system keychain,
        // and https (the edge, and lan.mahfin.online at home) must be verified.
        if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            mpv_set_option_string(mpv, "tls-ca-file", ca)
            mpv_set_option_string(mpv, "tls-verify", "yes")
        }

        if mpv_initialize(mpv) < 0 { fatalError("libmpv could not be initialised") }

        mpv_observe_property(mpv, 0, "playback-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "cache-buffering-state", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_hook_add(mpv, 0, "on_preloaded", 50)

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let me = Unmanaged<MpvPlayer>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private static func cacheDir(_ name: String) -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("online.mahfin.mac/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    func shutdown() {
        guard let mpv = handle else { return }
        mpv_set_wakeup_callback(mpv, nil, nil)
        handle = nil
        mpv_terminate_destroy(mpv)
    }

    // MARK: Commands

    private func command(_ args: [String]) {
        guard let mpv = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p)) } }
        cargs.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command(mpv, buf.baseAddress)
        }
    }

    private func set(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, name, value)
    }

    // MARK: api.player

    func load(url: String, options: [String: Any], audio: Any, subtitle: Any) {
        stop()
        started = false
        lastPositionMs = -1
        pendingAudio = audio
        pendingSubtitle = subtitle
        let startMs = (options["startMilliseconds"] as? NSNumber)?.doubleValue ?? 0
        let autoplay = (options["autoplay"] as? NSNumber)?.boolValue ?? true
        var per = [String]()
        if startMs > 0 { per.append("start=+\(startMs / 1000.0)") }
        // Tracks are chosen in the on_preloaded hook, once the file's own are known.
        per.append("aid=no")
        per.append("sid=no")
        per.append("pause=\(autoplay ? "no" : "yes")")
        command(["loadfile", url, "replace", "-1", per.joined(separator: ",")])
    }

    func seekTo(ms: Double) {
        command(["seek", String(ms / 1000.0), "absolute+exact"])
    }

    func play() { set("pause", "no") }
    func pause() { set("pause", "yes") }

    func stop() {
        command(["stop"])
    }

    func setVolume(_ v: Double) { set("volume", String(max(0, min(100, v)))) }
    func setMuted(_ m: Bool) { set("mute", m ? "yes" : "no") }

    func setPlaybackRate(_ thousandths: Double) {
        let speed = thousandths / 1000.0
        set("speed", String(speed))
        emit("playbackRateChanged", [speed])
    }

    func setAudioStream(_ id: Any) { applyAudio(id) }
    func setSubtitleStream(_ id: Any) { applySubtitle(id) }

    /// The page may only restyle subtitles; mpv's command language can run
    /// programs, so nothing else passes (see shared/TrustedOrigins.h in the Qt shell).
    func userCommand(_ cmd: String) {
        let allowed = ##"^set (sub-scale|sub-pos|sub-back-color|sub-color|sub-border-color|sub-font-size|sub-ass-override) ("#[0-9A-Fa-f]{6,8}"|-?[0-9]{1,4}(\.[0-9]{1,4})?|scale|yes|no|force|strip)$"##
        guard cmd.range(of: allowed, options: .regularExpression) != nil else {
            NSLog("userCommand: refused %@", String(cmd.prefix(80)))
            return
        }
        guard let mpv = handle else { return }
        mpv_command_string(mpv, cmd)
    }

    private func applyAudio(_ id: Any) {
        if let n = (id as? NSNumber)?.intValue, n >= 0 { set("aid", String(n)) } else { set("aid", "no") }
    }

    private func applySubtitle(_ id: Any) {
        if let s = id as? String, s.hasPrefix("#,") {
            let url = String(s.dropFirst(2))
            if !url.isEmpty { command(["sub-add", url, "select"]) }
            return
        }
        if let n = (id as? NSNumber)?.intValue, n >= 0 { set("sid", String(n)) } else { set("sid", "no") }
    }

    // MARK: Events

    private func emit(_ name: String, _ args: [Any] = []) {
        onSignal?(name, args)
    }

    private func drainEvents() {
        guard let mpv = handle else { return }
        while true {
            guard let ev = mpv_wait_event(mpv, 0) else { return }
            let e = ev.pointee
            if e.event_id == MPV_EVENT_NONE { return }
            process(event: e)
        }
    }

    private func process(event e: mpv_event) {
        switch e.event_id {
        case MPV_EVENT_HOOK:
            if let data = e.data?.assumingMemoryBound(to: mpv_event_hook.self).pointee {
                applyAudio(pendingAudio)
                applySubtitle(pendingSubtitle)
                if let mpv = handle { mpv_hook_continue(mpv, data.id) }
            }
        case MPV_EVENT_START_FILE:
            started = false
            updateState()
        case MPV_EVENT_PLAYBACK_RESTART:
            started = true
            updateState()
        case MPV_EVENT_END_FILE:
            let reason = e.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            started = false
            state = .idle
            switch reason?.reason {
            case MPV_END_FILE_REASON_EOF:
                emit("finished")
                emit("stopped")
            case MPV_END_FILE_REASON_ERROR:
                let message = reason.map { String(cString: mpv_error_string($0.error)) } ?? "playback error"
                emit("error", [message])
            default:
                emit("stopped")
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let p = e.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                  let name = p.name.map({ String(cString: $0) }) else { return }
            propertyChanged(name, p)
        default:
            break
        }
    }

    private func propertyChanged(_ name: String, _ p: mpv_event_property) {
        func double() -> Double? {
            guard p.format == MPV_FORMAT_DOUBLE, let d = p.data else { return nil }
            return d.assumingMemoryBound(to: Double.self).pointee
        }
        func flag() -> Bool? {
            guard p.format == MPV_FORMAT_FLAG, let d = p.data else { return nil }
            return d.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        switch name {
        case "playback-time":
            guard let t = double() else { return }
            positionSeconds = t
            let ms = (t * 1000).rounded()
            if lastPositionMs < 0 || abs(ms - lastPositionMs) > 15 {
                lastPositionMs = ms
                emit("positionUpdate", [ms])
            }
        case "duration":
            if let d = double(), d > 0 { emit("updateDuration", [(d * 1000).rounded()]) }
        case "pause":
            if let f = flag() { paused = f; updateState() }
        case "paused-for-cache":
            if let f = flag() { pausedForCache = f; updateState() }
        case "cache-buffering-state":
            if state == .buffering, p.format == MPV_FORMAT_INT64, let d = p.data {
                emit("buffering", [Double(d.assumingMemoryBound(to: Int64.self).pointee)])
            }
        case "demuxer-cache-time":
            // The read-ahead, as the one range the page shows: from where
            // playback is to how far the cache reaches. In 100 ns ticks.
            if let ahead = double() {
                let start = max(0, positionSeconds) * 1e7
                emit("bufferedRangesUpdated", [[["start": start, "end": max(start, ahead * 1e7)]]])
            }
        default:
            break
        }
    }

    private func updateState() {
        let next: State
        if !started { next = pausedForCache ? .buffering : .idle }
        else if pausedForCache { next = .buffering }
        else if paused { next = .paused }
        else { next = .playing }
        guard next != state else { return }
        state = next
        switch next {
        case .playing: emit("playing")
        case .paused: emit("paused")
        case .buffering: emit("buffering", [0.0])
        case .idle: break
        }
    }
}
