import Foundation
import CryptoKit

// Port of the web SDK's upload-resume.ts (IndexedDB there, files here).
// A multipart upload records its session and every finished part, so the
// same bytes uploaded again continue where they stopped: after a dropped
// connection, a crash, or the app being closed.

struct ResumeSession: Codable, Sendable, Equatable {
    var uploadSessionId: String
    var fileId: String
    var completionToken: String
    var totalParts: Int
    var partSizeBytes: Int
    /// Part number -> ETag.
    var completedParts: [Int: String]
    var createdAt: Date
}

actor UploadResumeStore {
    /// Server sessions last 24 hours.
    static let maxAge: TimeInterval = 24 * 60 * 60

    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("ScaleMule/uploads", isDirectory: true)
        }
    }

    /// Same app, same owner, same name and the same bytes.
    static func key(apiKey: String, owner: String, filename: String, data: Data) -> String {
        let content = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let raw = "\(apiKey):\(owner):\(filename):\(data.count):\(content)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func get(_ key: String) -> ResumeSession? {
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(ResumeSession.self, from: data) else { return nil }
        if Date().timeIntervalSince(session.createdAt) > Self.maxAge {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return session
    }

    func save(_ key: String, _ session: ResumeSession) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = fileURL(key)
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
        // Upload bookkeeping, not user data.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func recordPart(_ key: String, partNumber: Int, etag: String) throws {
        guard var session = get(key) else { return }
        session.completedParts[partNumber] = etag
        try save(key, session)
    }

    func remove(_ key: String) {
        try? fileManager.removeItem(at: fileURL(key))
    }

    /// Delete records older than a server session can live.
    func removeExpired() {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            _ = get(key)
        }
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }
}
