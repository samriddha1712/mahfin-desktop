import Foundation

/*
 * The signed-in person, as the web app reports them with every route change
 * (Mahfin's lib/nativeScreens `announceRoute`). The native pages make exactly
 * the requests the web pages would, with the same credentials:
 *
 *  - Jellyfin: `Authorization: MediaBrowser Token="…"`, against `server` —
 *    already the route the page measured fastest (home network or edge).
 *  - Mahfin's own /api routes: `x-mahfin-token` + `x-mahfin-server`, against
 *    `site`, the page's own origin.
 */
struct NativeSession: Equatable {
    let token: String
    let userId: String
    let userName: String
    let deviceId: String
    let server: URL
    let configuredServer: URL
    let site: URL

    init?(_ d: [String: Any]) {
        guard let token = d["token"] as? String, !token.isEmpty,
              let userId = d["userId"] as? String, !userId.isEmpty,
              let server = (d["server"] as? String).flatMap(URL.init(string:)),
              let site = (d["site"] as? String).flatMap(URL.init(string:)),
              NativeSession.allowed(server), NativeSession.allowed(site) else { return nil }
        self.token = token
        self.userId = userId
        userName = d["userName"] as? String ?? ""
        deviceId = d["deviceId"] as? String ?? ""
        self.server = server
        configuredServer = (d["configuredServer"] as? String).flatMap(URL.init(string:)) ?? server
        self.site = site
    }

    /// Credentials go only to Mahfin's own addresses, whatever a page says.
    private static func allowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return host == "mahfin.online" || host.hasSuffix(".mahfin.online") }
        return scheme == "http" && host == "192.168.29.96"
    }

    var jellyfinHeaders: [String: String] {
        ["Authorization": "MediaBrowser Token=\"\(token)\""]
    }

    var mahfinHeaders: [String: String] {
        ["x-mahfin-token": token, "x-mahfin-server": server.absoluteString]
    }
}
