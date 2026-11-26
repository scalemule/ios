import Foundation

/// Shares the existing media budget with one incoming post. The nearest
/// three items of each kind keep priority; no extra player or request pool.
public struct FeedPreloadPlan {
    public let photos: [MediaPost]
    public let videos: [MediaPost]

    public init(upcoming: [MediaPost], incoming: MediaPost?, allowIncoming: Bool) {
        func choose(video: Bool) -> [MediaPost] {
            var seen = Set<String>()
            let next = upcoming.filter { $0.isVideo == video && seen.insert($0.mediaId).inserted }
            guard allowIncoming, let incoming, incoming.isVideo == video,
                  !next.prefix(3).contains(where: { $0.mediaId == incoming.mediaId }) else {
                return Array(next.prefix(4))
            }
            return Array(next.prefix(3)) + [incoming]
        }
        photos = choose(video: false)
        videos = choose(video: true)
    }
}
