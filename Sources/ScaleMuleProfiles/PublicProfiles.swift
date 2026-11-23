import Foundation
import ScaleMuleCore

/// What anyone signed in to the app may see of another person: no email or phone.
public struct PublicProfile: Sendable, Equatable {
    public let id: String
    /// Full name, when the person gave one.
    public let name: String?
    public let username: String?
    /// The profile photo (an unsigned HTTPS link), when there is one.
    public let avatarURL: URL?

    public init(id: String, name: String?, username: String?, avatarURL: URL?) {
        self.id = id
        self.name = name
        self.username = username
        self.avatarURL = avatarURL
    }
}

/// A small cached directory of other people's public profiles
/// (`GET /v1/auth/users/{id}`, which gives a signed-in caller in the same app
/// only the contact-free view of anyone else).
///
/// Lookups are kept in memory for `ttl` (10 minutes by default); a person who
/// could not be found (or a failed lookup) is remembered for `missTTL` (1
/// minute) so a feed does not ask again for every row. Concurrent lookups of
/// the same person share one request. Needs a signed-in session.
public actor PublicProfiles {
    public let client: HTTPClient
    public let ttl: TimeInterval
    public let missTTL: TimeInterval
    /// Most people kept; the oldest entries go first.
    public let capacity: Int
    private let now: @Sendable () -> Date

    private struct Entry {
        let profile: PublicProfile?
        let expires: Date
        let stored: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<PublicProfile?, Never>] = [:]
    private var generation = 0

    public init(
        client: HTTPClient,
        ttl: TimeInterval = 600,
        missTTL: TimeInterval = 60,
        capacity: Int = 500,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.ttl = ttl
        self.missTTL = missTTL
        self.capacity = max(1, capacity)
        self.now = now
    }

    public init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    /// The person's public profile, from the cache while it is fresh. Nil when
    /// the person does not exist in this app or the lookup failed.
    public func profile(_ userId: String) async -> PublicProfile? {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if let entry = entries[id], entry.expires > now() { return entry.profile }
        if let running = inFlight[id] { return await running.value }

        let client = self.client
        let task = Task<PublicProfile?, Never> { await Self.fetch(id, client: client) }
        inFlight[id] = task
        let startedIn = generation
        let profile = await task.value
        inFlight[id] = nil
        // A `removeAll` or `forget` while this was running wins.
        if generation == startedIn { store(id, profile) }
        return profile
    }

    /// The cached profile, without asking the server (nil when not cached or stale).
    public func cached(_ userId: String) -> PublicProfile? {
        guard let entry = entries[userId], entry.expires > now() else { return nil }
        return entry.profile
    }

    /// Put a profile known to be current into the cache (for example your own,
    /// after changing your photo).
    public func remember(_ profile: PublicProfile) {
        generation += 1
        store(profile.id, profile)
    }

    /// Drop one person, so the next lookup asks the server.
    public func forget(_ userId: String) {
        generation += 1
        entries[userId] = nil
    }

    public func removeAll() {
        generation += 1
        entries.removeAll()
    }

    private func store(_ id: String, _ profile: PublicProfile?) {
        let at = now()
        entries[id] = Entry(profile: profile, expires: at.addingTimeInterval(profile == nil ? missTTL : ttl), stored: at)
        if entries.count > capacity {
            let expired = entries.filter { $0.value.expires <= at }.map(\.key)
            for key in expired { entries[key] = nil }
            if entries.count > capacity {
                let oldest = entries.sorted { $0.value.stored < $1.value.stored }.prefix(entries.count - capacity).map(\.key)
                for key in oldest { entries[key] = nil }
            }
        }
    }

    private static func fetch(_ id: String, client: HTTPClient) async -> PublicProfile? {
        let segment = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
        let result: ApiResponse<PublicUserRecord> = await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/users/\(segment)",
            credential: .sessionToken
        ))
        guard case .success(let record) = result else { return nil }
        return record.profile
    }
}

/// The fields of Auth's user record a profile needs (the contact-free view has no more).
struct PublicUserRecord: Decodable, Sendable {
    let id: String
    let fullName: String?
    let username: String?
    let avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case id, username
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
    }

    var profile: PublicProfile {
        let name = fullName.map(ProfileText.unescape)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PublicProfile(
            id: id,
            name: (name?.isEmpty ?? true) ? nil : name,
            username: username.map(ProfileText.unescape),
            avatarURL: ProfileURL.avatar(avatarUrl.map(ProfileText.unescape))
        )
    }
}

/// Auth stores profile text HTML-escaped (`O&#x27;Brien`); people see the text.
enum ProfileText {
    static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
