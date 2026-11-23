import Foundation
import ScaleMuleCore

// Port of the web SDK's upload-telemetry.ts. The same event names go to the
// same places, so web and iOS uploads can be compared side by side:
// every event to analytics (/v1/analytics/v2/events/batch, batched),
// warnings and errors also to the logger at once (/v1/logger/logs).
// Telemetry never fails or slows an upload.

public enum UploadTelemetryEvent: String, Sendable, CaseIterable {
    case started = "upload.started"
    case progress = "upload.progress"
    case completed = "upload.completed"
    case failed = "upload.failed"
    case aborted = "upload.aborted"
    case retried = "upload.retried"
    case resumed = "upload.resumed"
    case stalled = "upload.stalled"
    case compressionStarted = "upload.compression.started"
    case compressionCompleted = "upload.compression.completed"
    case compressionSkipped = "upload.compression.skipped"
    case multipartStarted = "upload.multipart.started"
    case multipartPartCompleted = "upload.multipart.part_completed"
    case multipartPartFailed = "upload.multipart.part_failed"
    case multipartURLRefreshed = "upload.multipart.url_refreshed"
    case multipartCompleted = "upload.multipart.completed"
    case multipartAborted = "upload.multipart.aborted"

    /// Same routing as the web SDK.
    var severity: String {
        switch self {
        case .failed, .stalled, .multipartAborted: return "error"
        case .retried, .aborted, .multipartPartFailed, .multipartURLRefreshed, .compressionSkipped: return "warn"
        case .progress, .multipartPartCompleted, .compressionStarted: return "debug"
        default: return "info"
        }
    }
}

/// Telemetry fields (values must be JSON: strings, numbers, booleans).
typealias TelemetryFields = [String: AnyCodable]

func fields(_ values: [String: Any?]) -> TelemetryFields {
    values.compactMapValues { $0 }.mapValues(AnyCodable.init)
}

actor UploadTelemetry {
    private struct Event {
        let sessionId: String
        let event: UploadTelemetryEvent
        let timestamp: String
        let metadata: TelemetryFields
    }

    private let client: HTTPClient
    private var buffer: [Event] = []
    private var flushTask: Task<Void, Never>?
    private let maxBuffer = 50
    private let flushInterval: UInt64 = 2_000_000_000

    init(client: HTTPClient) {
        self.client = client
    }

    static func newSessionId() -> String {
        let time = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "us_\(time)_\(random)"
    }

    /// Fire and forget.
    nonisolated func emit(_ sessionId: String, _ event: UploadTelemetryEvent, _ metadata: TelemetryFields = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        Task { await self.record(Event(sessionId: sessionId, event: event, timestamp: timestamp, metadata: metadata)) }
    }

    private func record(_ item: Event) {
        if item.event.severity != "debug" {
            send(RequestOptions(method: .post, path: "/v1/logger/logs", body: Self.logBody(item), retryable: false))
        }
        buffer.append(item)
        if buffer.count >= maxBuffer {
            flushNow()
        } else if flushTask == nil {
            flushTask = Task { [flushInterval] in
                try? await Task.sleep(nanoseconds: flushInterval)
                self.flushNow()
            }
        }
    }

    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        let events: [[String: Any]] = buffer.map { item in
            var properties = Self.plain(item.metadata)
            properties["upload_session_id"] = item.sessionId
            properties["platform"] = "ios"
            return ["event": item.event.rawValue, "properties": properties, "timestamp": item.timestamp]
        }
        buffer.removeAll()
        send(RequestOptions(method: .post, path: "/v1/analytics/v2/events/batch", body: ["events": events], retryable: false))
    }

    private func send(_ options: RequestOptions) {
        let client = client
        Task.detached(priority: .utility) {
            _ = await client.requestVoid(options)
        }
    }

    private static func plain(_ metadata: TelemetryFields) -> [String: Any] {
        metadata.mapValues(\.value)
    }

    private static func logBody(_ item: Event) -> [String: Any] {
        var metadata = plain(item.metadata)
        metadata["upload_session_id"] = item.sessionId
        metadata["event"] = item.event.rawValue
        metadata["platform"] = "ios"
        return [
            "service": "storage.upload",
            "severity": item.event.severity,
            "message": "Upload \(item.event.rawValue): session=\(item.sessionId)",
            "metadata": metadata,
            "trace_id": item.sessionId,
        ]
    }
}
