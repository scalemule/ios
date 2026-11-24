#if canImport(UIKit)
import AVFoundation
import Foundation
import ScaleMuleCore

/// One quality of a ScaleMule Video as an ordinary MP4 on the phone, to
/// share or save. ScaleMule Video keeps each quality as one MP4 file behind
/// its HLS playlist; this picks the best quality up to `maxShortSide`,
/// downloads it and rewrites it as a plain MP4 with no metadata at all (no
/// place, no device). Use `MediaExport.watermarkedVideo` to add an app's logo.
public enum VideoShareFile {
    public enum ShareError: LocalizedError, Sendable {
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            }
        }
    }

    /// The file (kept for an hour, so sharing twice is instant).
    @MainActor
    public static func file(
        for videoId: String,
        videos: VideosService,
        maxShortSide: Int = 1080,
        session: URLSession = .shared
    ) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scalemule-share", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let output = folder.appendingPathComponent("\(safe)-\(maxShortSide).mp4")
        if let made = (try? output.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(made) < 3600 {
            return output
        }
        guard case .success(let master) = await videos.playbackURL(id: videoId, validFor: 600) else {
            throw ShareError.unavailable("This video isn't ready to share yet. Try again in a moment.")
        }
        let masterText = try await text(master, session: session)
        guard let variant = HLSPlaylist.bestVariant(in: masterText, base: master, maxShortSide: maxShortSide) else {
            throw ShareError.unavailable("This video isn't ready to share yet.")
        }
        let mediaText = try await text(variant, session: session)
        let parts = HLSPlaylist.files(in: mediaText, base: variant)
        guard !parts.isEmpty else { throw ShareError.unavailable("This video can't be shared.") }

        let raw = folder.appendingPathComponent("\(safe)-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: raw) }
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let handle = try FileHandle(forWritingTo: raw)
        do {
            for part in parts {
                let (downloaded, response) = try await session.download(from: part)
                defer { try? FileManager.default.removeItem(at: downloaded) }
                guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                    throw ShareError.unavailable("The video didn't download. Try again.")
                }
                try handle.write(contentsOf: try Data(contentsOf: downloaded))
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try? FileManager.default.removeItem(at: output)
        try await MediaFileExport.plainMP4(from: raw, to: output)
        return output
    }

    private static func text(_ url: URL, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw ShareError.unavailable("This video isn't available right now.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reading the playlists ScaleMule Video serves.
enum HLSPlaylist {
    /// The variant with the largest short side up to `maxShortSide` (else the
    /// smallest). With `preferHEVC`, an HEVC variant of that size wins over
    /// H.264 (about half the bytes); without, H.264 is taken when there is one
    /// (files shared to other apps and phones).
    static func bestVariant(in master: String, base: URL, maxShortSide: Int, preferHEVC: Bool = false) -> URL? {
        var variants: [(shortSide: Int, hevc: Bool, url: URL)] = []
        var pending: (side: Int, hevc: Bool)?
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let codecs = (attribute("CODECS", in: line) ?? "").lowercased()
                pending = (resolutionShortSide(line) ?? 0, codecs.contains("hvc1") || codecs.contains("hev1"))
            } else if let variant = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL { variants.append((variant.side, variant.hevc, url)) }
                pending = nil
            }
        }
        let fitting = variants.filter { $0.shortSide <= maxShortSide }
        let pool = fitting.isEmpty ? variants.filter { $0.shortSide == variants.map(\.shortSide).min() } : fitting
        guard let side = (fitting.isEmpty ? pool.map(\.shortSide).min() : pool.map(\.shortSide).max()) else { return nil }
        let sized = pool.filter { $0.shortSide == side }
        let wanted = sized.first { $0.hevc == preferHEVC }
        return (wanted ?? sized.first)?.url
    }

    /// The files that make up a media playlist, in order, each once (the
    /// init section first; byte-range segments of one file give one file).
    static func files(in media: String, base: URL) -> [URL] {
        var urls: [URL] = []
        func add(_ value: String) {
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL, !urls.contains(url) else { return }
            urls.append(url)
        }
        for raw in media.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"), let uri = attribute("URI", in: line) {
                add(uri)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                add(line)
            }
        }
        return urls
    }

    private static func resolutionShortSide(_ line: String) -> Int? {
        guard let value = attribute("RESOLUTION", in: line) else { return nil }
        let sides = value.lowercased().split(separator: "x").compactMap { Int($0) }
        return sides.count == 2 ? min(sides[0], sides[1]) : nil
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            return body.firstIndex(of: "\"").map { String(body[..<$0]) }
        }
        return String(rest.prefix { $0 != "," })
    }
}

/// Writing video files that leave the phone.
public enum MediaFileExport {
    /// The same video and sound as a plain MP4, with every metadata item
    /// (location, device, dates) removed.
    public static func plainMP4(from source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoShareFile.ShareError.unavailable("This video can't be prepared on this iPhone.")
        }
        try await run(session, to: output)
    }

    /// Run an export to `output` as MP4 without metadata.
    public static func run(_ session: AVAssetExportSession, to output: URL) async throws {
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        let box = ExportBox(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        guard box.session.status == .completed else {
            throw VideoShareFile.ShareError.unavailable(box.session.error?.localizedDescription ?? "The video couldn't be prepared.")
        }
    }
}

private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
#endif
