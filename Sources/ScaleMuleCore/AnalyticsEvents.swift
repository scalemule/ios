import Foundation

/// Product analytics for any ScaleMule app: named events with properties,
/// batched to ScaleMule Analytics (`/v1/analytics/v2/events/batch`), the
/// same place the web SDK and upload telemetry send theirs. Never fails or
/// slows the app: sending happens in the background and errors are dropped.
public actor AnalyticsEvents {
    private struct Pending {
        let name: String
        let properties: [String: AnyCodable]
        let timestamp: String
    }

    private let client: HTTPClient
    private var buffer: [Pending] = []
    private var flushTask: Task<Void, Never>?
    private let maxBuffer: Int
    private let flushDelay: UInt64

    public init(client: HTTPClient, maxBuffer: Int = 25, flushAfterSeconds: Double = 5) {
        self.client = client
        self.maxBuffer = maxBuffer
        self.flushDelay = UInt64(flushAfterSeconds * 1_000_000_000)
    }

    /// Record an event (fire and forget). Values must be strings, numbers or booleans.
    public nonisolated func emit(_ name: String, _ properties: [String: Any?] = [:]) {
        let clean = properties.compactMapValues { $0 }.mapValues(AnyCodable.init)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        Task { await self.record(Pending(name: name, properties: clean, timestamp: timestamp)) }
    }

    /// Send what is waiting now (for example when the app goes to the background).
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        let events: [[String: Any]] = buffer.map { item in
            var properties = item.properties.mapValues(\.value)
            properties["platform"] = "ios"
            return ["event": item.name, "properties": properties, "timestamp": item.timestamp]
        }
        buffer.removeAll()
        let client = client
        Task.detached(priority: .utility) {
            _ = await client.requestVoid(RequestOptions(method: .post, path: "/v1/analytics/v2/events/batch", body: ["events": events], retryable: false))
        }
    }

    /// Events waiting to be sent (for tests).
    public var pendingCount: Int { buffer.count }

    private func record(_ item: Pending) {
        buffer.append(item)
        if buffer.count >= maxBuffer {
            flush()
        } else if flushTask == nil {
            let delay = flushDelay
            flushTask = Task {
                try? await Task.sleep(nanoseconds: delay)
                self.flush()
            }
        }
    }
}
