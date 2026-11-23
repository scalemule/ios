import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleVideos

final class VideoCaptionsTests: XCTestCase {
    private func words(_ spec: [(String, Double, Double)]) -> [TimedWord] {
        spec.map { TimedWord(text: $0.0, start: $0.1, duration: $0.2) }
    }

    func testAPauseStartsANewCaptionAndCaptionsNeverOverlap() {
        let cues = CaptionBuilder.cues(from: words([
            ("Three,", 0.0, 0.4), ("one,", 0.5, 0.3), ("two,", 0.9, 0.3),
            ("three,", 2.4, 0.3), ("four,", 2.8, 0.3), ("five,", 3.2, 0.3), ("six.", 3.6, 0.3),
        ]))
        XCTAssertEqual(cues.map(\.text), ["Three, one, two,", "three, four, five, six."])
        XCTAssertEqual(cues[0].start, 0.0)
        XCTAssertLessThanOrEqual(cues[0].end, cues[1].start)
        XCTAssertEqual(cues[1].end, 4.5, accuracy: 0.001, "last words linger")
    }

    func testLongSpeechIsSplitIntoReadableCaptions() {
        let sentence = (0..<40).map { ("word\($0)", Double($0) * 0.3, 0.25) }
        let cues = CaptionBuilder.cues(from: words(sentence))
        XCTAssertGreaterThan(cues.count, 3)
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.text.count, CaptionBuilder.maxCharacters)
            XCTAssertLessThanOrEqual(cue.end - cue.start, CaptionBuilder.maxSeconds + CaptionBuilder.lingerSeconds + 0.3)
        }
        XCTAssertEqual(cues.map(\.text).joined(separator: " "), sentence.map(\.0).joined(separator: " "), "no word lost")
    }

    func testASentenceEndStartsANewCaptionOnceThereIsEnoughText() {
        let cues = CaptionBuilder.cues(from: words([
            ("Hello", 0, 0.3), ("everyone", 0.35, 0.4), ("here.", 0.8, 0.3), ("Welcome", 1.15, 0.4), ("back.", 1.6, 0.3),
        ]))
        XCTAssertEqual(cues.map(\.text), ["Hello everyone here.", "Welcome back."])
    }

    func testCharactersNotBytesAcrossScripts() {
        // 30 Cyrillic letters + emoji fit (characters), though over 64 bytes.
        let cues = CaptionBuilder.cues(from: words([
            ("Привет,", 0, 0.4), ("как", 0.45, 0.2), ("дела?", 0.7, 0.3), ("🎬🎉", 1.0, 0.2), ("東京へ", 1.25, 0.3),
        ]))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Привет, как дела? 🎬🎉 東京へ")
        XCTAssertGreaterThan(cues[0].text.utf8.count, cues[0].text.count)
    }

    func testEmptyAndBrokenWordsAreDropped() {
        XCTAssertEqual(CaptionBuilder.cues(from: []), [])
        let cues = CaptionBuilder.cues(from: words([(" ", 0, 0.2), ("ok", .nan, 0.2), ("yes", 1, 0.2)]))
        XCTAssertEqual(cues.map(\.text), ["yes"])
    }

    func testCueAtTime() {
        let track = CaptionTrack(language: "en-US", cues: [
            CaptionCue(start: 2, end: 3, text: "b"), CaptionCue(start: 0, end: 1, text: "a"),
        ])
        XCTAssertEqual(track.cue(at: 0)?.text, "a")
        XCTAssertEqual(track.cue(at: 0.99)?.text, "a")
        XCTAssertNil(track.cue(at: 1.5), "gap")
        XCTAssertEqual(track.cue(at: 2.5)?.text, "b")
        XCTAssertNil(track.cue(at: 3))
        XCTAssertNil(track.cue(at: -1))
        XCTAssertNil(track.cue(at: .nan))
    }

    func testPreferredTrackFollowsThePersonsLanguages() {
        let tracks = CaptionTracks(tracks: [
            CaptionTrack(language: "en-US", cues: []), CaptionTrack(language: "bg-BG", cues: []),
        ])
        XCTAssertEqual(tracks.preferred(languages: ["bg"])?.language, "bg-BG")
        XCTAssertEqual(tracks.preferred(languages: ["en-GB"])?.language, "en-US")
        XCTAssertEqual(tracks.preferred(languages: ["ja-JP"])?.language, "en-US", "else the first")
    }

    func testUploadAndReadCaptions() async {
        let (app, _) = createTestClient()
        try? await app.sessionManager.setCredentials(CredentialSet(sessionToken: "sess", sessionExpiresAt: Date().addingTimeInterval(3600)))
        let videos = VideosService(app: app)
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.url?.path, "/v1/videos/v1/captions")
                body = self.bodyJSON(request)
                return TestFixtures.envelopedResponse(json: #"{"language":"en-US","source":"device","cue_count":1,"updated_at":"2026-11-23T20:00:00Z"}"#)
            }
            XCTAssertEqual(request.url?.path, "/v1/videos/v1/captions")
            return TestFixtures.envelopedResponse(json: #"{"tracks":[{"language":"en-US","source":"device","cues":[{"start":0.0,"end":1.8,"text":"Three, one, two"}],"vtt":"WEBVTT","updated_at":"2026-11-23T20:00:00Z"}]}"#)
        }
        let saved = await videos.uploadCaptions(id: "v1", language: "en-US", cues: [CaptionCue(start: 0, end: 1.8, text: "Three, one, two")])
        XCTAssertEqual(saved.data?.cueCount, 1)
        XCTAssertEqual(body?["language"] as? String, "en-US")
        XCTAssertEqual(body?["source"] as? String, "device")
        let cue = (body?["cues"] as? [[String: Any]])?.first
        XCTAssertEqual(cue?["text"] as? String, "Three, one, two")
        XCTAssertEqual(cue?["end"] as? Double, 1.8)
        let read = await videos.captions(id: "v1")
        XCTAssertEqual(read.data?.tracks.first?.cues, [CaptionCue(start: 0, end: 1.8, text: "Three, one, two")])
    }
}
