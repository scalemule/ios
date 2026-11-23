import Foundation
import ScaleMuleCore

/// One caption on screen: its text from `start` to `end` (seconds into the video).
public struct CaptionCue: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A video's captions in one language, as ScaleMule Video keeps them.
public struct CaptionTrack: Codable, Equatable, Sendable {
    /// BCP 47, for example "en-US".
    public let language: String
    /// `device` (transcribed on the poster's phone), `server` or `manual`.
    public let source: String?
    /// Sorted by start.
    public let cues: [CaptionCue]
    /// The same captions as WebVTT, for web players (`<track>`).
    public let vtt: String?

    public init(language: String, source: String? = "device", cues: [CaptionCue], vtt: String? = nil) {
        self.language = language
        self.source = source
        self.cues = cues.sorted { $0.start < $1.start }
        self.vtt = vtt
    }

    /// The caption on screen at `time` (seconds), if any.
    public func cue(at time: Double) -> CaptionCue? {
        guard time.isFinite else { return nil }
        // Last cue starting at or before `time`.
        var low = 0, high = cues.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0, time < cues[found].end else { return nil }
        return cues[found]
    }
}

/// `GET /v1/videos/{id}/captions`.
public struct CaptionTracks: Codable, Sendable {
    public let tracks: [CaptionTrack]

    /// The track for the person's language, else the first one.
    public func preferred(languages: [String] = Locale.preferredLanguages) -> CaptionTrack? {
        for wanted in languages {
            let base = wanted.split(separator: "-").first.map(String.init)?.lowercased()
            if let exact = tracks.first(where: { $0.language.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }
            if let base, let same = tracks.first(where: { $0.language.split(separator: "-").first.map(String.init)?.lowercased() == base }) {
                return same
            }
        }
        return tracks.first
    }
}

/// `PUT /v1/videos/{id}/captions`.
public struct CaptionUploadResult: Codable, Sendable {
    public let language: String
    public let cueCount: Int?

    private enum CodingKeys: String, CodingKey {
        case language
        case cueCount = "cue_count"
    }
}

/// Words with their times, as speech recognition gives them.
public struct TimedWord: Equatable, Sendable {
    public let text: String
    public let start: Double
    public let duration: Double

    public init(text: String, start: Double, duration: Double) {
        self.text = text
        self.start = start
        self.duration = duration
    }

    var end: Double { start + duration }
}

public enum CaptionBuilder {
    /// Characters a caption holds: two short lines on a phone held upright.
    public static let maxCharacters = 64
    /// The longest a caption stays up.
    public static let maxSeconds = 4.0
    /// A pause this long starts a new caption.
    public static let pauseSeconds = 0.7
    /// A caption stays at least this long (when the next allows), so it can be read.
    public static let minSeconds = 1.0
    /// How long the last words stay after they are spoken.
    public static let lingerSeconds = 0.6

    /// Group recognised words into captions the way TV and TikTok do: a new
    /// caption at a pause, at the end of a sentence once there is enough
    /// text, or when it would get too long to read.
    public static func cues(from words: [TimedWord]) -> [CaptionCue] {
        let spoken = words
            .map { TimedWord(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, duration: max(0, $0.duration)) }
            .filter { !$0.text.isEmpty && $0.start.isFinite && $0.duration.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
        var groups: [[TimedWord]] = []
        var current: [TimedWord] = []
        func length(_ words: [TimedWord]) -> Int { words.reduce(0) { $0 + $1.text.count } + max(0, words.count - 1) }
        for word in spoken {
            if let last = current.last, let first = current.first {
                let pause = word.start - last.end
                let tooLong = length(current) + 1 + word.text.count > maxCharacters
                let tooSlow = word.end - first.start > maxSeconds
                let sentenceEnded = [".", "?", "!", "…", "。", "？", "！"].contains { last.text.hasSuffix($0) } && length(current) >= 20
                if pause >= pauseSeconds || tooLong || tooSlow || sentenceEnded {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        var cues: [CaptionCue] = []
        for (index, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let next = index + 1 < groups.count ? groups[index + 1].first?.start : nil
            var end = max(last.end + lingerSeconds, first.start + minSeconds)
            if let next { end = min(end, next) }
            end = max(end, last.end)
            guard end > first.start else { continue }
            let text = group.map(\.text).joined(separator: " ")
            cues.append(CaptionCue(start: rounded(first.start), end: rounded(end), text: text))
        }
        return cues
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

extension VideosService {
    /// The video's captions (`tracks` is empty when it has none). Anyone who
    /// may watch the video may read them.
    public func captions(id: String) async -> ApiResponse<CaptionTracks> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/videos/\(Self.segment(id))/captions",
            credential: .accessToken
        ))
    }

    /// Save captions for your video (replaces that language's captions).
    /// `MediaUploadQueue` does this by itself after transcribing a posted video.
    public func uploadCaptions(id: String, language: String, cues: [CaptionCue], source: String = "device") async -> ApiResponse<CaptionUploadResult> {
        await client.request(RequestOptions(
            method: .put,
            path: "/v1/videos/\(Self.segment(id))/captions",
            body: [
                "language": language,
                "source": source,
                "cues": cues.map { ["start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] },
            ],
            credential: .accessToken
        ))
    }

    /// Remove one language's captions from your video.
    public func deleteCaptions(id: String, language: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/videos/\(Self.segment(id))/captions/\(Self.segment(language))",
            credential: .accessToken
        ))
    }
}
