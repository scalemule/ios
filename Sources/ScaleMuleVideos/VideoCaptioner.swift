#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// Turns the speech in a video into captions on the phone (Apple's speech
/// recognition, on the device only: the audio never leaves the phone).
/// `MediaUploadQueue` runs it for every posted video and saves the result
/// with ScaleMule Video.
///
/// The app needs `NSSpeechRecognitionUsageDescription` in its Info.plist;
/// without it nothing is transcribed (asking would crash). People are asked
/// once, the first time they post a video (or call `requestPermission()`
/// earlier, for example on the camera screen).
public enum VideoCaptioner {
    public struct Result: Sendable, Equatable {
        public let language: String
        public let cues: [CaptionCue]
    }

    /// Turn off to post videos without captions.
    nonisolated(unsafe) public static var isEnabled = true

    /// The app can ask for speech recognition (its Info.plist says why).
    public static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    /// Ask now (the system prompt shows once). True when allowed.
    @discardableResult
    public static func requestPermission() async -> Bool {
        guard isEnabled, isConfigured else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// Captions for the speech in `file`, or nil when there is none, it is
    /// not allowed, or this phone cannot recognise the language on device.
    /// Tries the person's languages in order of preference.
    public static func transcribe(_ file: URL, languages: [String] = Locale.preferredLanguages, timeout: TimeInterval = 90) async -> Result? {
        guard isEnabled, await requestPermission(), await hasAudio(file) else { return nil }
        for language in candidateLocales(languages) {
            guard let recognizer = SFSpeechRecognizer(locale: language),
                  recognizer.supportsOnDeviceRecognition else { continue }
            let words = await recognize(file, with: recognizer, timeout: timeout)
            let cues = CaptionBuilder.cues(from: words)
            guard !cues.isEmpty else { return nil }
            return Result(language: language.identifier.replacingOccurrences(of: "_", with: "-"), cues: cues)
        }
        return nil
    }

    static func candidateLocales(_ languages: [String]) -> [Locale] {
        var seen = Set<String>()
        var locales: [Locale] = []
        for language in languages + [Locale.current.identifier, "en-US"] {
            let locale = Locale(identifier: language)
            let key = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if seen.insert(key).inserted { locales.append(locale) }
        }
        return locales
    }

    private static func hasAudio(_ file: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    private static func recognize(_ file: URL, with recognizer: SFSpeechRecognizer, timeout: TimeInterval) async -> [TimedWord] {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let box = RecognitionBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[TimedWord], Never>) in
                box.setContinuation(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let words = result.bestTranscription.segments.map {
                            TimedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                        }
                        box.finish(words)
                    } else if error != nil {
                        // "No speech detected" and every other failure: no captions.
                        box.finish([])
                    }
                }
                box.setTask(task)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    box.cancel()
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Resumes the continuation exactly once (result, error, timeout or cancel).
private final class RecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TimedWord], Never>?
    private var task: SFSpeechRecognitionTask?
    private var done = false

    func setContinuation(_ continuation: CheckedContinuation<[TimedWord], Never>) {
        lock.lock()
        defer { lock.unlock() }
        if done { continuation.resume(returning: []) } else { self.continuation = continuation }
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let finished = done
        if !finished { self.task = task }
        lock.unlock()
        if finished { task.cancel() }
    }

    func finish(_ words: [TimedWord]) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let continuation = continuation
        self.continuation = nil
        task = nil
        lock.unlock()
        continuation?.resume(returning: words)
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
        finish([])
    }
}
#endif
