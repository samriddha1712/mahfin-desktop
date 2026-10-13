import Foundation
import CryptoKit

/*
 * Requests for the native pages: Jellyfin's API and Mahfin's own /api routes,
 * with the credentials the web app reported (NativeSession).
 *
 * Every answer is also kept, per person, in memory and on disk, and `load`
 * hands back the kept copy first and the network's answer after it. So a page
 * opens on what it showed last time — instantly, even on a cold launch — and
 * then quietly brings itself up to date. That is the single biggest part of
 * "opens instantly": nothing on the home page waits for the network before
 * it can be drawn.
 */
final class MahfinAPI {
    let session: NativeSession
    private let net: URLSession
    private let diskDir: URL

    private static var memory: [String: Data] = [:]
    private static let memoryLock = NSLock()

    init(session: NativeSession) {
        self.session = session
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25
        config.httpMaximumConnectionsPerHost = 6
        net = URLSession(configuration: config)
        diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("online.mahfin.mac/JSON/\(session.userId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    enum Host { case jellyfin, mahfin }

    struct Failure: Error { let status: Int }

    func url(_ host: Host, _ path: String, _ query: [String: String] = [:]) -> URL {
        let base = host == .jellyfin ? session.server : session.site
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return c.url!
    }

    private func request(_ host: Host, _ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        for (k, v) in host == .jellyfin ? session.jellyfinHeaders : session.mahfinHeaders { r.setValue(v, forHTTPHeaderField: k) }
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// One network fetch, no cache.
    func fetch<T: Decodable>(_ type: T.Type, _ host: Host, _ path: String, _ query: [String: String] = [:]) async throws -> T {
        let u = url(host, path, query)
        let data = try await raw(host, u)
        remember(u, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The kept copy first (if any), then the network's — `deliver` runs on
    /// the main actor once or twice. Returns when the network answer is in.
    func load<T: Decodable>(_ type: T.Type, _ host: Host, _ path: String, _ query: [String: String] = [:],
                            deliver: @escaping @MainActor (T) -> Void) async {
        let u = url(host, path, query)
        var shown: Data?
        if let kept = recall(u), let value = try? JSONDecoder().decode(T.self, from: kept) {
            shown = kept
            await deliver(value)
        }
        guard let data = try? await raw(host, u) else { return }
        remember(u, data)
        if data != shown, let value = try? JSONDecoder().decode(T.self, from: data) {
            await deliver(value)
        }
    }

    /// A write (favourite, request): no caching, and the status code matters.
    @discardableResult
    func send(_ host: Host, _ method: String, _ path: String, _ query: [String: String] = [:], json: Any? = nil) async throws -> Data {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, response) = try await net.data(for: request(host, url(host, path, query), method: method, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(status: status) }
        return data
    }

    private func raw(_ host: Host, _ u: URL) async throws -> Data {
        let (data, response) = try await net.data(for: request(host, u))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(status: status) }
        return data
    }

    // MARK: Kept answers

    /// Keeps a value this page computed from several requests (the hero's
    /// picks), so it can be drawn at once next time like any single answer.
    func keep<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        remember(url(.mahfin, "/__kept/\(name)"), data)
    }

    func kept<T: Decodable>(_ type: T.Type, as name: String) -> T? {
        recall(url(.mahfin, "/__kept/\(name)")).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func key(_ u: URL) -> String {
        // Hashed so a URL never becomes a path, and keyed per person because
        // the same URL answers differently for each of them.
        SHA256.hash(data: Data((session.userId + u.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func remember(_ u: URL, _ data: Data) {
        let k = key(u)
        MahfinAPI.memoryLock.lock()
        MahfinAPI.memory[k] = data
        MahfinAPI.memoryLock.unlock()
        let file = diskDir.appendingPathComponent(k)
        DispatchQueue.global(qos: .utility).async { try? data.write(to: file, options: .atomic) }
    }

    private func recall(_ u: URL) -> Data? {
        let k = key(u)
        MahfinAPI.memoryLock.lock()
        let hit = MahfinAPI.memory[k]
        MahfinAPI.memoryLock.unlock()
        if let hit { return hit }
        return try? Data(contentsOf: diskDir.appendingPathComponent(k))
    }
}
