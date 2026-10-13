import Foundation

/*
 * Which of Mahfin's pages are drawn natively.
 *
 * The web app stays the owner of navigation: its router, its history, its back
 * button and every deep link. On each route change it tells the shell where it
 * is (`native.route`), and for the pages below the shell draws the page itself
 * and the web view shrinks to just its top bar. Everything else — the player,
 * requests, settings, friends — stays the web page it always was.
 *
 * Native screens navigate by asking the web router (`__mahfinNav.push`), so one
 * history covers both kinds of page and Back always means the same thing.
 */
enum NativeRoute: Equatable, Hashable {
    case home
    case item(id: String)
    case browse(feed: String)

    init?(path: String) {
        let clean = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = clean.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch parts.count {
        case 0: self = .home
        case 2 where parts[0] == "item" && !parts[1].isEmpty: self = .item(id: parts[1])
        case 3 where parts[0] == "discover" && parts[1] == "browse": self = .browse(feed: parts[2])
        default: return nil
        }
    }

    var path: String {
        switch self {
        case .home: return "/"
        case .item(let id): return "/item/\(id)"
        case .browse(let feed): return "/discover/browse/\(feed)"
        }
    }
}

/// What the web app reports on every route change.
struct WebRouteState {
    var path: String
    /// "topbar", "board", "studio" or "rail". Native screens are drawn only
    /// under "topbar" for now; the others keep their web pages.
    var shell: String
    var theme: String
    var session: NativeSession?
    /// The session as reported, kept for the next cold launch.
    var rawSession: [String: Any]?
    /// Height of the web app's fixed top bar, in points.
    var barHeight: Double
    /// What this web build offers that the native pages draw buttons for.
    var downloads: Bool

    init?(_ dict: [String: Any]) {
        guard let path = dict["path"] as? String else { return nil }
        self.path = path
        shell = dict["shell"] as? String ?? "topbar"
        theme = dict["theme"] as? String ?? "goldenhour"
        barHeight = (dict["barHeight"] as? NSNumber)?.doubleValue ?? 64
        downloads = ((dict["features"] as? [String: Any])?["downloads"] as? Bool) ?? false
        rawSession = dict["session"] as? [String: Any]
        session = rawSession.flatMap(NativeSession.init)
    }

    var nativeRoute: NativeRoute? {
        guard shell == "topbar", session != nil else { return nil }
        return NativeRoute(path: path)
    }
}
