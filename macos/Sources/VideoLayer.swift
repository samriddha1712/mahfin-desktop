import AppKit
import OpenGL.GL3
import QuartzCore

/*
 * Where mpv draws.
 *
 * libmpv can no longer embed itself in another app's window on macOS, so it
 * draws through its render API into an OpenGL layer the app owns. The layer
 * sits under the web view, and the web page is transparent wherever video
 * should show — the same arrangement the Qt shell had with its QML video item.
 *
 * Frames are pulled, not pushed: mpv calls `onUpdate` when it has a new frame,
 * and the layer asks to be redrawn; `draw` then renders into whatever
 * framebuffer CoreAnimation hands it. VideoToolbox frames reach OpenGL through
 * IOSurface without a copy, so hardware decoding stays hardware all the way.
 */
final class VideoLayer: CAOpenGLLayer {
    private weak var player: MpvPlayer?
    private var renderContext: OpaquePointer?
    private var cglContext: CGLContextObj?
    private let renderLock = NSLock()
    /*
     * Frames are drawn here, off the main thread. Drawing on the main thread
     * made the web page fight the video for it: scrolling the episode list and
     * dragging the subtitle-size slider over a playing film were choppy, because
     * every frame of video was rendered between their events. (IINA does the
     * same: a dedicated queue that calls display().)
     */
    private let renderQueue = DispatchQueue(label: "online.mahfin.render", qos: .userInteractive)
    /// Black instead of mpv's last frame: nothing is playing, or the next file
    /// has not produced its first frame. Touched only under `renderLock`.
    private var blank = true

    init(player: MpvPlayer) {
        self.player = player
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        let other = layer as? VideoLayer
        player = other?.player
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: OpenGL setup

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize, CGLPixelFormatAttribute(24),
            kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            kCGLPFADisplayMask, CGLPixelFormatAttribute(mask),
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attrs, &format, &count)
        return format!
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx = super.copyCGLContext(forPixelFormat: pf)
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLSetCurrentContext(ctx)
        cglContext = ctx
        createRenderContext()
        return ctx
    }

    private func createRenderContext() {
        guard renderContext == nil, let mpv = player?.handle else { return }
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let symbol = String(cString: name)
                let lib = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
                return dlsym(lib, symbol)
            },
            get_proc_address_ctx: nil)
        // Kept alive until mpv has read it.
        let apiType = strdup("opengl")
        defer { free(apiType) }
        var advanced: Int32 = 1
        withUnsafeMutablePointer(to: &initParams) { initPtr in
            withUnsafeMutablePointer(to: &advanced) { advPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                var ctx: OpaquePointer?
                if mpv_render_context_create(&ctx, mpv, &params) < 0 {
                    NSLog("mpv: could not create the OpenGL render context")
                    return
                }
                renderContext = ctx
            }
        }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            guard let ctx else { return }
            let layer = Unmanaged<VideoLayer>.fromOpaque(ctx).takeUnretainedValue()
            layer.renderQueue.async { layer.frameReady() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Drawing

    /// On `renderQueue`: mpv has something new.
    private func frameReady() {
        guard let renderContext else { return }
        let flags = mpv_render_context_update(renderContext)
        if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
            displayNow()
        }
    }

    private func displayNow() {
        CATransaction.begin()
        display()
        CATransaction.commit()
    }

    /*
     * Back to black. Without this the layer kept the last frame of whatever
     * played before — it showed behind the next film's intro animation, and
     * through the page during the slide between pages, which read as a flicker.
     * Called on stop and whenever a new file starts; the first frame of the
     * new one clears it again.
     */
    func blankUntilNextFrame() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderLock.lock()
            self.blank = true
            self.renderLock.unlock()
            self.displayNow()
        }
    }

    func showFrames() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderLock.lock()
            self.blank = false
            self.renderLock.unlock()
            self.displayNow()
        }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        renderLock.lock()
        defer { renderLock.unlock() }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        let width = viewport[2], height = viewport[3]

        guard let renderContext, width > 0, height > 0, !blank else {
            glClearColor(8.0 / 255, 8.0 / 255, 10.0 / 255, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }
        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(width), h: Int32(height), internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &target) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        glFlush()
    }

    override func display() {
        super.display()
        CATransaction.flush()
        if let renderContext { mpv_render_context_report_swap(renderContext) }
    }

    /// Called once, before the player handle goes away.
    func shutdown() {
        renderLock.lock()
        defer { renderLock.unlock() }
        if let renderContext {
            if let cglContext { CGLSetCurrentContext(cglContext) }
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
    }
}

/// The view that hosts the layer, under the web view.
final class VideoView: NSView {
    let videoLayer: VideoLayer

    init(player: MpvPlayer) {
        videoLayer = VideoLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        videoLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override var isOpaque: Bool { true }
}
