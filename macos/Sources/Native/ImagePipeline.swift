import AppKit
import ImageIO

/*
 * Artwork for the native screens.
 *
 * The whole reason these screens are native is that they scroll at the
 * display's own rate, and the thing that breaks that in an image grid is
 * decoding on the main thread. So every image here is decoded off it, by
 * ImageIO, at exactly the pixel size it will be drawn — a 342-wide TMDB poster
 * shown 170 points wide on a retina screen is decoded to 340 pixels, not to its
 * full size and scaled by the compositor each frame — and handed back as a
 * CGImage that can go straight into a layer's `contents`.
 *
 * Memory: a bounded NSCache of decoded images (the visible screen and a little
 * either side; the rest is evicted), in front of a disk URLCache of the
 * compressed bytes, so going back to a row costs a decode and not a download.
 */
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let session: URLSession
    private let memory = NSCache<NSString, CGImage>()
    private let decodeQueue = DispatchQueue(label: "online.mahfin.decode", qos: .userInitiated, attributes: .concurrent)
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        let config = URLSessionConfiguration.default
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("online.mahfin.mac/Images", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 400 << 20, directory: caches)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        // Cost is bytes of decoded pixels; about two screens of posters.
        memory.totalCostLimit = 160 << 20
    }

    /// The image at `url`, decoded to fit `pixels` on its longer side.
    /// Returns at once from memory when it can; otherwise loads and decodes off
    /// the main thread. Concurrent requests for the same image share one load.
    func image(_ url: URL, pixels: Int) async -> CGImage? {
        let key = "\(url.absoluteString)#\(pixels)" as NSString
        if let hit = memory.object(forKey: key) { return hit }

        let image = await loader(for: key as String, url: url, pixels: pixels).value
        lock.withLock { inFlight[key as String] = nil }
        if let image {
            memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// The load already running for `key`, or a new one: one network fetch
    /// and one decode however many cells ask at once.
    private func loader(for key: String, url: URL, pixels: Int) -> Task<CGImage?, Never> {
        lock.withLock {
            if let running = inFlight[key] { return running }
            let task = Task<CGImage?, Never>.detached(priority: .userInitiated) { [session] in
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
                return ImagePipeline.decode(data, pixels: pixels)
            }
            inFlight[key] = task
            return task
        }
    }

    /// Synchronous memory lookup, for a cell being reused while scrolling: if
    /// the image is already decoded it is shown in the same frame.
    func cached(_ url: URL, pixels: Int) -> CGImage? {
        memory.object(forKey: "\(url.absoluteString)#\(pixels)" as NSString)
    }

    /// Starts loading images expected on screen shortly, at low priority.
    func prefetch(_ urls: [URL], pixels: Int) {
        for url in urls where cached(url, pixels: pixels) == nil {
            Task.detached(priority: .utility) { _ = await self.image(url, pixels: pixels) }
        }
    }

    private static func decode(_ data: Data, pixels: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            return rasterize(data, pixels: pixels)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,   // decode now, not on first draw
            kCGImageSourceThumbnailMaxPixelSize: max(1, pixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// SVG (some of Mahfin's own logos): ImageIO does not read it, NSImage does.
    private static func rasterize(_ data: Data, pixels: Int) -> CGImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(image.size.width, image.size.height)
        var rect = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
