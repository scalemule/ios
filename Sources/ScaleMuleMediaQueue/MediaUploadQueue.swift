#if canImport(UIKit)
import Combine
import Foundation
import Network
import UIKit
import ScaleMuleCore
import ScaleMuleStorage
import ScaleMulePhotos
import ScaleMuleVideos
import ScaleMuleMediaEditing

/// What a finished upload hands to the app's publish step.
public struct MediaUpload: Sendable {
    public enum Kind: String, Codable, Sendable { case photo, video }

    public let id: UUID
    public let kind: Kind
    /// The ScaleMule Photos or Video id.
    public let mediaId: String
    public let width: Int
    public let height: Int
    /// Seconds, for videos.
    public let duration: Double?
    /// What the app stored with the post (caption, place, ...).
    public let attributes: [String: String]
}

/// Posting in the background, the way Instagram does it: the person goes
/// back to the feed at once and a strip shows the upload. A post is kept on
/// the phone until published, so a dropped connection or a closed app loses
/// nothing (the next launch carries on); uploads go through the ScaleMule
/// resumable pipeline; upload and publish are separate steps, so a failed
/// publish reuses the media already uploaded.
///
/// Photos: on Wi-Fi the full original goes up at once; on mobile data a copy
/// sized for the connection, and the original follows on Wi-Fi
/// (`PhotosService.attachOriginal`). Videos: the take's clips are joined and
/// edited (`VideoComposer`) once, then uploaded to ScaleMule Video. Their
/// speech is turned into captions on the phone while they upload
/// (`VideoCaptioner`) and saved with the video before the post is published.
///
/// The app supplies `publish` (for example a Social post) and observes `jobs`.
///
/// `publish` runs at least once per post: after a crash between publishing
/// and cleaning up, or a publish that succeeded but timed out, it can run
/// again for the same `MediaUpload.id`; make it idempotent on that id.
@MainActor
public final class MediaUploadQueue: ObservableObject {
    public struct Job: Identifiable {
        public enum State: Equatable, Sendable {
            case posting
            case failed(String)
        }

        public let id: UUID
        public let kind: MediaUpload.Kind
        public internal(set) var thumbnail: UIImage
        public internal(set) var state: State = .posting
        /// 0...1 of the bytes sent.
        public internal(set) var progress: Double = 0
        public let attributes: [String: String]
        var record: Record
    }

    /// Saved on the phone until published.
    struct Record: Codable, Sendable {
        let id: UUID
        let kind: MediaUpload.Kind
        let attributes: [String: String]
        let createdAt: Date
        var filename: String
        /// Videos: clip file names in the queue folder, and the edit.
        var clipNames: [String]?
        var edit: VideoEdit?
        var prepared: Bool?
        var width: Int?
        var height: Int?
        var duration: Double?
        /// Set once uploaded.
        var mediaId: String?
        var needsOriginal: Bool?
        var published: Bool?
        /// Where and when it was taken: written into the uploaded file only,
        /// for the platform to keep privately.
        var capture: CaptureLocation?
        /// Videos: speech recognition ran (captions below when it heard any).
        var transcribed: Bool?
        var captionLanguage: String?
        var captionCues: [CaptionCue]?
        var captionsSent: Bool?
    }

    public typealias Publish = @MainActor (MediaUpload) async -> Result<Void, PublishError>

    public struct PublishError: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    @Published public private(set) var jobs: [Job] = []
    /// Caption posted videos from their speech (needs the app's
    /// `NSSpeechRecognitionUsageDescription`; see `VideoCaptioner`).
    public var transcribesSpeech = true
    /// The phone's copy of each finished upload (by media id), to show it at once.
    public private(set) var previews: [String: UIImage] = [:]

    private let photos: PhotosService
    private let videos: VideosService
    private let publish: Publish
    private let folder: URL
    private let imageCache: PhotoImageCache
    private let originalQuality: CGFloat
    private let previewMaxSide: CGFloat
    private let maxVideoSeconds: Double
    private var running: Set<UUID> = []
    private var restored = false
    private var localPreviews: [UUID: UIImage] = [:]
    private var sendingOriginals = false
    /// Given up on: running steps stop at their next check and leave nothing behind.
    private var discarded: Set<UUID> = []
    private let monitor = NWPathMonitor()
    private var activeObserver: NSObjectProtocol?

    public init(
        photos: PhotosService,
        videos: VideosService,
        imageCache: PhotoImageCache = .shared,
        folderName: String = "ScaleMulePosting",
        originalQuality: CGFloat = 0.92,
        previewMaxSide: CGFloat = 1600,
        maxVideoSeconds: Double = 60,
        publish: @escaping Publish
    ) {
        self.photos = photos
        self.videos = videos
        self.imageCache = imageCache
        self.publish = publish
        self.originalQuality = originalQuality
        self.previewMaxSide = previewMaxSide
        self.maxVideoSeconds = maxVideoSeconds
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.sendWaitingOriginals() }
        }
        monitor.start(queue: DispatchQueue(label: "com.scalemule.media-queue.path"))
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sendWaitingOriginals() }
        }
    }

    deinit {
        monitor.cancel()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    private func isDiscarded(_ id: UUID) -> Bool { discarded.contains(id) }

    // MARK: - Posting

    /// Post a photo (full resolution: the queue decides what to send).
    ///
    /// `capture` is where and when it was taken. It goes into the uploaded
    /// JPEG only; ScaleMule Photos keeps it privately and serves copies
    /// without it. What the post shows is its separate public location.
    public func post(photo image: UIImage, attributes: [String: String] = [:], capture: CaptureLocation? = nil) {
        let id = UUID()
        var record = Record(id: id, kind: .photo, attributes: attributes, createdAt: Date(), filename: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
        record.capture = capture
        jobs.insert(Job(id: id, kind: .photo, thumbnail: Self.resized(image, maxSide: 160), attributes: attributes, record: record), at: 0)
        let folder = folder, quality = originalQuality, side = previewMaxSide
        Task {
            let preview = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard var jpeg = image.jpegData(compressionQuality: quality) else { return nil }
                if let capture { jpeg = CaptureMetadata.jpeg(jpeg, adding: capture) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try jpeg.write(to: folder.appendingPathComponent("\(id.uuidString).jpg"), options: .atomic)
                    try Self.writeRecord(record, in: folder)
                } catch { return nil }
                return Self.resized(image, maxSide: side)
            }.value
            if isDiscarded(id) {
                removeFiles(record)
                return
            }
            guard let preview else {
                setState(.failed("Could not prepare the photo."), for: id)
                return
            }
            localPreviews[id] = preview
            run(id)
        }
    }

    /// Post a video: the take's clips (the queue takes the files over) and the
    /// edit. `capture` is kept privately by ScaleMule Video, as for photos.
    public func post(video edit: VideoEdit, attributes: [String: String] = [:], capture: CaptureLocation? = nil) {
        let id = UUID()
        var record = Record(id: id, kind: .video, attributes: attributes, createdAt: Date(), filename: "video-\(Int(Date().timeIntervalSince1970)).mp4")
        record.capture = capture
        jobs.insert(Job(id: id, kind: .video, thumbnail: Self.placeholder, attributes: attributes, record: record), at: 0)
        var kept = edit
        kept.clips = []
        record.edit = kept
        record.clipNames = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, clip) in edit.clips.enumerated() {
                let name = "\(id.uuidString).clip\(index).\(clip.pathExtension.isEmpty ? "mov" : clip.pathExtension)"
                try FileManager.default.moveItem(at: clip, to: folder.appendingPathComponent(name))
                record.clipNames?.append(name)
            }
            update(record)
        } catch {
            // Whatever was moved stays listed, so Discard removes it.
            update(record)
            setState(.failed("Could not keep the video on this phone."), for: id)
            return
        }
        run(id)
    }

    /// Carry on with posts left from an earlier launch (call once signed in).
    public func restore() {
        guard !restored else { return }
        restored = true
        let records = savedRecords().filter { $0.published != true }
        let folder = folder, side = previewMaxSide
        Task {
            for record in records where !jobs.contains(where: { $0.id == record.id }) {
                let url = folder.appendingPathComponent("\(record.id.uuidString).jpg")
                let images = await Task.detached(priority: .utility) { () -> (UIImage, UIImage)? in
                    guard let image = (try? Data(contentsOf: url)).flatMap(UIImage.init(data:)) else { return nil }
                    return (Self.resized(image, maxSide: 160), Self.resized(image, maxSide: side))
                }.value
                if images == nil && record.kind == .photo { continue }
                jobs.append(Job(id: record.id, kind: record.kind, thumbnail: images?.0 ?? Self.placeholder,
                                attributes: record.attributes, record: record))
                if let images { localPreviews[record.id] = images.1 }
                run(record.id)
            }
            sendWaitingOriginals()
        }
    }

    public func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .posting
        jobs[index].progress = 0
        run(id)
    }

    /// Give up on a post; an uploaded photo nobody will see is deleted.
    public func discard(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        discarded.insert(id)
        jobs.removeAll { $0.id == id }
        localPreviews[id] = nil
        removeFiles(job.record)
        if job.kind == .photo, let mediaId = job.record.mediaId {
            let photos = photos
            Task { _ = await photos.delete(id: mediaId) }
        }
    }

    // MARK: - Running

    private func run(_ id: UUID) {
        guard !running.contains(id), let job = jobs.first(where: { $0.id == id }) else { return }
        running.insert(id)
        let background = BackgroundTime(name: "Posting")
        Task {
            defer {
                running.remove(id)
                background.end()
            }
            var record = job.record
            let uploaded = record.kind == .video ? await uploadVideo(&record) : await uploadPhoto(&record)
            if isDiscarded(id) {
                abandon(record)
                return
            }
            guard uploaded, let mediaId = record.mediaId else { return }
            if record.kind == .video { await sendCaptions(&record) }
            let upload = MediaUpload(
                id: id, kind: record.kind, mediaId: mediaId,
                width: record.width ?? 0, height: record.height ?? 0,
                duration: record.duration, attributes: record.attributes
            )
            switch await publish(upload) {
            case .success where isDiscarded(id):
                // Published as Discard was tapped: the post stands; tidy up.
                removeFiles(record)
            case .success:
                jobs.removeAll { $0.id == id }
                localPreviews[id] = nil
                if record.needsOriginal == true {
                    record.published = true
                    update(record)
                    sendWaitingOriginals()
                } else {
                    removeFiles(record)
                }
            case .failure(let error):
                setState(.failed(error.message), for: id)
            }
        }
    }

    private func uploadPhoto(_ record: inout Record) async -> Bool {
        guard record.mediaId == nil else { return true }
        guard let jpeg = try? Data(contentsOf: jpegURL(record.id)) else {
            setState(.failed("The photo is no longer on this phone."), for: record.id)
            return false
        }
        // On Wi-Fi the original at once; on mobile data a sized copy now.
        let sendOriginal = photos.originalIsCheapToSend()
        let id = record.id
        let result = await photos.upload(jpeg, filename: record.filename, mimeType: "image/jpeg", quality: sendOriginal ? .original : .adaptive) { progress in
            Task { @MainActor [weak self] in self?.setProgress(progress.fraction, for: id) }
        }
        switch result {
        case .success(let info):
            record.mediaId = info.id
            record.width = info.width
            record.height = info.height
            let full = ImageCompression.pixelSize(of: jpeg).map { max($0.width, $0.height) } ?? 0
            record.needsOriginal = !sendOriginal && max(info.width, info.height) < full
            update(record)
            if let preview = localPreviews[record.id] {
                imageCache.store(preview, for: PhotoImageCache.key(for: info.id))
                previews[info.id] = preview
            }
            return true
        case .failure(let error):
            setState(.failed(error.userFacingMessage), for: record.id)
            return false
        }
    }

    private func uploadVideo(_ record: inout Record) async -> Bool {
        if record.prepared != true {
            let clips = (record.clipNames ?? []).map { folder.appendingPathComponent($0) }
            guard !clips.isEmpty, clips.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                setState(.failed("The video is no longer on this phone."), for: record.id)
                return false
            }
            var edit = record.edit ?? VideoEdit(clips: [])
            edit.clips = clips
            do {
                let prepared = try await VideoComposer.export(edit, maxSeconds: maxVideoSeconds, location: record.capture)
                try? FileManager.default.removeItem(at: videoURL(record.id))
                try FileManager.default.moveItem(at: prepared.file, to: videoURL(record.id))
                try prepared.poster.jpegData(compressionQuality: 0.85)?.write(to: jpegURL(record.id), options: .atomic)
                for clip in clips { try? FileManager.default.removeItem(at: clip) }
                record.prepared = true
                record.width = prepared.width
                record.height = prepared.height
                record.duration = prepared.duration
                update(record)
                localPreviews[record.id] = prepared.poster
                if let index = jobs.firstIndex(where: { $0.id == record.id }) {
                    jobs[index].thumbnail = Self.resized(prepared.poster, maxSide: 160)
                }
            } catch {
                setState(.failed(error.localizedDescription), for: record.id)
                return false
            }
        }
        guard record.mediaId == nil else { return true }
        // Captions while it uploads (on the phone; seconds for a short video).
        var transcription: Task<VideoCaptioner.Result?, Never>?
        if transcribesSpeech, record.transcribed != true {
            let source = videoURL(record.id)
            transcription = Task { await VideoCaptioner.transcribe(source) }
        }
        defer { transcription?.cancel() }
        guard let file = try? Data(contentsOf: videoURL(record.id)) else {
            setState(.failed("The video is no longer on this phone."), for: record.id)
            return false
        }
        let id = record.id
        switch await videos.upload(file, filename: record.filename, mimeType: "video/mp4", onProgress: { progress in
            Task { @MainActor [weak self] in self?.setProgress(progress.fraction, for: id) }
        }) {
        case .success(let video):
            record.mediaId = video.videoId
            if let transcription {
                let result = await transcription.value
                record.transcribed = true
                record.captionLanguage = result?.language
                record.captionCues = result?.cues
            }
            update(record)
            VideoFileCache.keep(videoURL(record.id), for: video.videoId)
            if let poster = localPreviews[record.id] {
                imageCache.store(poster, for: PhotoImageCache.key(for: video.videoId))
                previews[video.videoId] = poster
            }
            return true
        case .failure(let error):
            setState(.failed(error.userFacingMessage), for: record.id)
            return false
        }
    }

    /// Save the video's captions with ScaleMule Video (once). The post goes
    /// out whatever happens here: captions are a bonus, never a blocker.
    private func sendCaptions(_ record: inout Record) async {
        guard record.captionsSent != true, let mediaId = record.mediaId,
              let language = record.captionLanguage, let cues = record.captionCues, !cues.isEmpty else { return }
        VideoCaptionStore.shared.store(CaptionTrack(language: language, cues: cues), for: mediaId)
        for attempt in 0..<3 {
            switch await videos.uploadCaptions(id: mediaId, language: language, cues: cues) {
            case .success:
                record.captionsSent = true
                update(record)
                return
            case .failure(let error) where (error.statusCode ?? 0) >= 400 && (error.statusCode ?? 0) < 500:
                return // refused: trying again changes nothing
            case .failure:
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
            }
        }
    }

    // MARK: - Originals on Wi-Fi

    /// Full-resolution originals of photos posted smaller on mobile data.
    public func sendWaitingOriginals() {
        guard restored, !sendingOriginals, photos.originalIsCheapToSend() else { return }
        let waiting = savedRecords().filter { $0.published == true && $0.needsOriginal == true && $0.mediaId != nil }
        guard !waiting.isEmpty else { return }
        sendingOriginals = true
        let background = BackgroundTime(name: "Sending originals")
        Task {
            defer {
                sendingOriginals = false
                background.end()
            }
            for record in waiting {
                guard photos.originalIsCheapToSend(), let mediaId = record.mediaId else { return }
                guard let jpeg = try? Data(contentsOf: jpegURL(record.id)) else {
                    removeFiles(record)
                    continue
                }
                switch await photos.attachOriginal(photoId: mediaId, jpeg, filename: record.filename) {
                case .success:
                    removeFiles(record)
                case .failure(let error):
                    // Refused for good (gone, not the same picture, too large): stop. Connection problems: later.
                    if let status = error.statusCode, [403, 404, 409, 410, 413, 415, 422].contains(status) {
                        removeFiles(record)
                    }
                }
            }
        }
    }

    // MARK: - State and files

    private func setProgress(_ fraction: Double, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .posting else { return }
        let rounded = (fraction * 100).rounded() / 100
        if rounded != jobs[index].progress { jobs[index].progress = rounded }
    }

    private func setState(_ state: Job.State, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    /// Saves a post's progress; a discarded post is never written back.
    private func update(_ record: Record) {
        guard !isDiscarded(record.id) else { return }
        if let index = jobs.firstIndex(where: { $0.id == record.id }) { jobs[index].record = record }
        try? Self.writeRecord(record, in: folder)
    }

    /// Discarded mid-upload: delete what was made, including an uploaded photo.
    private func abandon(_ record: Record) {
        removeFiles(record)
        if record.kind == .photo, let mediaId = record.mediaId {
            let photos = photos
            Task { _ = await photos.delete(id: mediaId) }
        }
    }

    private func savedRecords() -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }
    }

    private func jpegURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).jpg") }
    private func videoURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).mp4") }

    private func removeFiles(_ record: Record) {
        let manager = FileManager.default
        try? manager.removeItem(at: folder.appendingPathComponent("\(record.id.uuidString).json"))
        try? manager.removeItem(at: jpegURL(record.id))
        try? manager.removeItem(at: videoURL(record.id))
        for name in record.clipNames ?? [] { try? manager.removeItem(at: folder.appendingPathComponent(name)) }
    }

    nonisolated private static func writeRecord(_ record: Record, in folder: URL) throws {
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
    }

    nonisolated static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    static let placeholder: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
        UIColor(white: 0.15, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
}

/// Extra time from iOS to finish an upload after the app leaves the screen.
@MainActor
private final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
