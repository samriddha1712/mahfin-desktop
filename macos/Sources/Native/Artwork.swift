import Foundation

/*
 * Image addresses, built exactly as Mahfin's src/lib/images.ts builds them, so
 * the native pages hit the same cached files on the server and the edge as the
 * web pages do. `width` is in pixels already (points × backing scale, capped
 * at 2× like the web).
 */
struct Artwork {
    let server: URL

    private func image(_ id: String, _ kind: String, tag: String?, width: Int) -> URL {
        var c = URLComponents(url: server.appendingPathComponent("Items/\(id)/Images/\(kind)"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem]()
        if let tag { q.append(URLQueryItem(name: "tag", value: tag)) }
        q.append(URLQueryItem(name: "maxWidth", value: String(width)))
        q.append(URLQueryItem(name: "quality", value: "85"))
        c.queryItems = q
        return c.url!
    }

    func poster(_ item: JFItem, width: Int) -> URL? {
        if let tag = item.ImageTags?["Primary"] { return image(item.Id, "Primary", tag: tag, width: width) }
        if item.isEpisode, let sid = item.SeriesId, let tag = item.SeriesPrimaryImageTag {
            return image(sid, "Primary", tag: tag, width: width)
        }
        if let aid = item.AlbumId, let tag = item.AlbumPrimaryImageTag { return image(aid, "Primary", tag: tag, width: width) }
        return nil
    }

    func wide(_ item: JFItem, width: Int) -> URL? {
        if item.isEpisode, let tag = item.ImageTags?["Primary"] { return image(item.Id, "Primary", tag: tag, width: width) }
        if let tag = item.ImageTags?["Thumb"] { return image(item.Id, "Thumb", tag: tag, width: width) }
        if let tag = item.BackdropImageTags?.first { return image(item.Id, "Backdrop", tag: tag, width: width) }
        if let pid = item.ParentThumbItemId, let tag = item.ParentThumbImageTag { return image(pid, "Thumb", tag: tag, width: width) }
        if let pid = item.ParentBackdropItemId, let tag = item.ParentBackdropImageTags?.first {
            return image(pid, "Backdrop", tag: tag, width: width)
        }
        return poster(item, width: width)
    }

    func backdrop(_ item: JFItem, width: Int) -> URL? {
        if let tag = item.BackdropImageTags?.first { return image(item.Id, "Backdrop", tag: tag, width: width) }
        if let pid = item.ParentBackdropItemId, let tag = item.ParentBackdropImageTags?.first {
            return image(pid, "Backdrop", tag: tag, width: width)
        }
        return wide(item, width: width)
    }

    func logo(_ item: JFItem, width: Int) -> URL? {
        if let tag = item.ImageTags?["Logo"] { return image(item.Id, "Logo", tag: tag, width: width) }
        if let pid = item.ParentLogoItemId, let tag = item.ParentLogoImageTag { return image(pid, "Logo", tag: tag, width: width) }
        return nil
    }

    func person(_ p: JFPerson, width: Int) -> URL? {
        guard let id = p.Id, let tag = p.PrimaryImageTag else { return nil }
        return image(id, "Primary", tag: tag, width: width)
    }

    /// TMDB posters arrive as full URLs (w342) from Mahfin's API.
    static func tmdb(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.host == "image.tmdb.org" else { return nil }
        return u
    }
}
