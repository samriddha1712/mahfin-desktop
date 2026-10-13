import Foundation

/*
 * The answers the native pages read — the subset of Jellyfin's BaseItemDto
 * and of Mahfin's /api shapes that the web pages use (src/lib/queries.ts,
 * src/app/api/discover). Everything optional: a missing field draws less, it
 * never fails a page.
 */

struct JFUserData: Codable, Hashable {
    var PlaybackPositionTicks: Int64?
    var Played: Bool?
    var IsFavorite: Bool?
    var UnplayedItemCount: Int?
    var PlayedPercentage: Double?
}

struct JFPerson: Codable, Hashable {
    var Id: String?
    var Name: String?
    var Role: String?
    var `Type`: String?
    var PrimaryImageTag: String?
}

struct JFNamed: Codable, Hashable {
    var Name: String?
    var Id: String?
}

struct JFItem: Codable, Hashable, Identifiable {
    var Id: String
    var Name: String?
    var `Type`: String?
    var Overview: String?
    var ProductionYear: Int?
    var PremiereDate: String?
    var DateCreated: String?
    var CommunityRating: Double?
    var OfficialRating: String?
    var RunTimeTicks: Int64?
    var Genres: [String]?
    var Studios: [JFNamed]?
    var People: [JFPerson]?
    var ChildCount: Int?
    var IndexNumber: Int?
    var ParentIndexNumber: Int?
    var SeriesId: String?
    var SeriesName: String?
    var SeasonId: String?
    var SeriesPrimaryImageTag: String?
    var ImageTags: [String: String]?
    var BackdropImageTags: [String]?
    var ParentBackdropItemId: String?
    var ParentBackdropImageTags: [String]?
    var ParentLogoItemId: String?
    var ParentLogoImageTag: String?
    var ParentThumbItemId: String?
    var ParentThumbImageTag: String?
    var AlbumId: String?
    var AlbumPrimaryImageTag: String?
    var ProviderIds: [String: String]?
    var UserData: JFUserData?
    var CollectionType: String?
    var ImageBlurHashes: [String: [String: String]]?

    var id: String { Id }
    var isEpisode: Bool { Type == "Episode" }
    var isSeries: Bool { Type == "Series" }
    var isPerson: Bool { Type == "Person" }

    var tmdbId: Int? {
        (ProviderIds?["Tmdb"] ?? ProviderIds?["tmdb"]).flatMap(Int.init)
    }

    /// "1h 52m", "45m"; nil without a runtime.
    var runtimeText: String? {
        guard let t = RunTimeTicks, t > 0 else { return nil }
        let minutes = Int(t / 600_000_000)
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Fraction watched, 0…1, or nil when not started.
    var progress: Double? {
        guard let pos = UserData?.PlaybackPositionTicks, pos > 0, let total = RunTimeTicks, total > 0 else { return nil }
        return min(1, Double(pos) / Double(total))
    }
}

struct JFItems: Codable {
    var Items: [JFItem]
    var TotalRecordCount: Int?
}

/// A title from Seerr/TMDB as Mahfin's /api/discover returns it.
struct DiscoverItem: Codable, Hashable {
    var tmdbId: Int
    var mediaType: String          // "movie" | "tv"
    var title: String?
    var posterUrl: String?
    var genre: String?
    var status: Int?
    var voteAverage: Double?
    var year: String?
    var releaseDate: String?

    var key: String { "\(mediaType):\(tmdbId)" }
}

struct DiscoverPage: Codable {
    var items: [DiscoverItem]
    var page: Int?
    var totalPages: Int?
    var totalResults: Int?
}

struct CuratedView: Codable {
    var heading: String?
    var picks: [DiscoverItem]?
    var talk: [DiscoverItem]?
}

struct BecauseItem: Codable {
    var tmdbId: Int
    var mediaType: String
    var title: String?
    var posterUrl: String?
    var genre: String?
    var status: Int?
    var voteAverage: Double?
    var year: String?
    var library: JFItem?

    var discover: DiscoverItem {
        DiscoverItem(tmdbId: tmdbId, mediaType: mediaType, title: title, posterUrl: posterUrl, genre: genre,
                     status: status, voteAverage: voteAverage, year: year, releaseDate: nil)
    }
}

struct BecauseRows: Codable {
    struct Row: Codable {
        struct Seed: Codable { var name: String? }
        var seed: Seed
        var items: [BecauseItem]
    }
    var rows: [Row]
    var fallback: Bool?
}

struct LeavingEntry: Codable {
    var id: String?
    var itemId: String
    var kind: String
    var name: String?
    var seriesId: String?
    var seriesName: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var deleteAt: Double

    /// The item whose poster the card shows: the series for a season or episode.
    var cardItemId: String { (kind == "season" || kind == "episode") ? (seriesId ?? itemId) : itemId }
}

struct LeavingList: Codable { var items: [LeavingEntry] }

struct StatusMap: Codable {
    var statuses: [String: Int]
}

/// Seerr media status, as the web's request buttons read it.
enum SeerrStatus {
    static func label(_ s: Int?) -> String {
        switch s ?? 1 {
        case 4, 5: return "In library"
        case 2, 3: return "Requested"
        default: return "Request"
        }
    }
    static func inLibrary(_ s: Int?) -> Bool { s == 4 || s == 5 }
    static func requested(_ s: Int?) -> Bool { s == 2 || s == 3 }
}
