import Foundation
import Combine
import ScaleMuleCore

/// Something ScaleMule Realtime sent on a channel: the event's name
/// ("new_message") and its JSON payload.
public struct RealtimeEvent: Sendable {
    public let channel: String
    public let name: String
    /// The payload as JSON (an object). Decode it with `decode`.
    public let payload: Data

    public init(channel: String, name: String, payload: Data) {
        self.channel = channel
        self.name = name
        self.payload = payload
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }

    /// One text field of the payload.
    public func string(_ key: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?[key] as? String
    }
}

/// One open socket. The SDK's is a URLSession WebSocket; tests supply their own.
public protocol RealtimeSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame; throws when the socket closes.
    func receive() async throws -> String
    func close()
}

/// Keeps a subscription alive; `cancel()` (or letting it go) ends it.
public final class RealtimeSubscription: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { onCancel() }
    }

    deinit { cancel() }
}

/// A live connection to ScaleMule Realtime for the signed-in person:
/// subscribe to channels and receive their events as they happen. It asks
/// for a one-use ticket with the person's session, keeps the socket alive,
/// reconnects with a growing pause when the network drops and subscribes
/// again by itself. The person's own private channel is subscribed by the
/// server (events arrive on a channel that starts with "private:"). The
/// connection counts as open once the server has answered the ticket.
///
/// Call `connect()` when the app comes to the front and `disconnect()` when
/// it leaves; subscriptions are remembered across both.
@MainActor
public final class RealtimeClient: ObservableObject {
    public enum Status: Sendable, Equatable { case disconnected, connecting, connected }

    @Published public private(set) var status: Status = .disconnected
    /// Counts connections made: a change after the first means events may
    /// have been missed while offline, so catch up from the server.
    @Published public private(set) var connectionCount = 0

    public typealias SocketFactory = @Sendable (URL) -> RealtimeSocket

    private let client: HTTPClient
    private let makeSocket: SocketFactory
    private let heartbeat: TimeInterval
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let pause: @Sendable (TimeInterval) async -> Void

    private var wanted = false
    private var generation = 0
    private var lastHeard = Date()
    private var socket: RealtimeSocket?
    private var runTask: Task<Void, Never>?
    private var channels: [String: Int] = [:]
    private var handlers: [UUID: (RealtimeEvent) -> Void] = [:]

    public init(
        client: HTTPClient,
        heartbeat: TimeInterval = 30,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 30,
        socketFactory: SocketFactory? = nil,
        pause: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.client = client
        self.heartbeat = heartbeat
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.makeSocket = socketFactory ?? { URLSessionRealtimeSocket(url: $0) }
        self.pause = pause ?? { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    // MARK: - Connection

    /// Open the connection and keep it open. Safe to call again.
    public func connect() {
        wanted = true
        guard runTask == nil else { return }
        generation += 1
        let mine = generation
        runTask = Task { [weak self] in await self?.run(mine) }
    }

    /// Close the connection. Subscriptions are kept for the next `connect()`.
    public func disconnect() {
        wanted = false
        generation += 1
        runTask?.cancel()
        runTask = nil
        socket?.close()
        socket = nil
        status = .disconnected
    }

    // MARK: - Channels and events

    /// Receive a channel's events until the subscription is cancelled.
    /// Several subscriptions to one channel share it.
    public func subscribe(_ channel: String) -> RealtimeSubscription {
        channels[channel, default: 0] += 1
        if channels[channel] == 1 { sendFrame(["type": "subscribe", "channel": channel]) }
        return RealtimeSubscription { [weak self] in
            Task { @MainActor in self?.release(channel) }
        }
    }

    private func release(_ channel: String) {
        guard let count = channels[channel] else { return }
        if count <= 1 {
            channels[channel] = nil
            sendFrame(["type": "unsubscribe", "channel": channel])
        } else {
            channels[channel] = count - 1
        }
    }

    /// Hear every event on every subscribed channel (and the person's
    /// private channel) until the returned subscription is cancelled.
    public func onEvent(_ handler: @escaping (RealtimeEvent) -> Void) -> RealtimeSubscription {
        let id = UUID()
        handlers[id] = handler
        return RealtimeSubscription { [weak self] in
            Task { @MainActor in self?.handlers[id] = nil }
        }
    }

    // MARK: - The connection loop

    private func run(_ mine: Int) async {
        var attempt = 0
        while wanted, generation == mine, !Task.isCancelled {
            status = .connecting
            if let opened = await open() {
                guard generation == mine else {
                    opened.close()
                    return
                }
                socket = opened
                lastHeard = Date()
                if await listen(on: opened, mine) { attempt = 0 }
                opened.close()
                guard generation == mine else { return }
                socket = nil
            }
            guard wanted, generation == mine, !Task.isCancelled else { return }
            status = .connecting
            attempt += 1
            await pause(Self.delay(attempt: attempt, base: baseDelay, max: maxDelay))
        }
    }

    /// 1 s, 2 s, 4 s … up to `max`, with up to a quarter taken off so many
    /// phones do not all come back in the same instant.
    nonisolated static func delay(attempt: Int, base: TimeInterval, max: TimeInterval, jitter: Double = Double.random(in: 0...0.25)) -> TimeInterval {
        let grown = base * pow(2, Double(Swift.max(0, attempt - 1)))
        return Swift.min(max, grown) * (1 - Swift.min(0.25, Swift.max(0, jitter)))
    }

    private struct Ticket: Decodable { let ticket: String }

    private func open() async -> RealtimeSocket? {
        let result: ApiResponse<Ticket> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/realtime/ws/ticket",
            credential: .accessToken
        ))
        guard case .success(let ticket) = result, let url = Self.socketURL(base: client.configuration.baseURL, ticket: ticket.ticket) else { return nil }
        return makeSocket(url)
    }

    nonisolated static func socketURL(base: URL, ticket: String) -> URL? {
        guard var parts = URLComponents(url: base.appendingPathComponent("v1/realtime/ws"), resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return parts.url
    }

    /// Read frames until the socket ends. True when the server answered at
    /// all (the connection was real, so the next pause starts short again).
    private func listen(on socket: RealtimeSocket, _ mine: Int) async -> Bool {
        let beat = Task { [weak self, heartbeat, pause] in
            while !Task.isCancelled {
                await pause(heartbeat)
                guard !Task.isCancelled, let self else { break }
                // Nothing heard for two beats and more: the line is dead.
                if Date().timeIntervalSince(self.lastHeard) > heartbeat * 2.5 {
                    socket.close()
                    break
                }
                do { try await socket.send("ping") } catch {
                    socket.close()
                    break
                }
            }
        }
        defer { beat.cancel() }
        var answered = false
        while wanted, generation == mine, !Task.isCancelled {
            guard let text = try? await socket.receive() else { return answered }
            guard generation == mine else { return answered }
            lastHeard = Date()
            if !answered {
                // The first frame proves the server took the ticket.
                answered = true
                status = .connected
                connectionCount += 1
                for channel in channels.keys { sendFrame(["type": "subscribe", "channel": channel]) }
            }
            if handle(text) == .reconnect { return answered }
        }
        return answered
    }

    private enum Next { case stay, reconnect }

    private func handle(_ text: String) -> Next {
        guard text != "pong", let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = frame["type"] as? String else { return .stay }
        switch type {
        case "message":
            guard let channel = frame["channel"] as? String, let event = Self.event(channel: channel, data: frame["data"]) else { return .stay }
            for handler in handlers.values { handler(event) }
            return .stay
        case "reconnect", "token_expiring":
            return .reconnect
        default:
            return .stay
        }
    }

    /// Services wrap what they send as `{"event": name, "data": {...}}`.
    nonisolated static func event(channel: String, data: Any?) -> RealtimeEvent? {
        guard let object = data as? [String: Any] else { return nil }
        guard let name = (object["event"] as? String) ?? (object["type"] as? String) else { return nil }
        let inner = (object["data"] as? [String: Any]) ?? object
        guard let payload = try? JSONSerialization.data(withJSONObject: inner) else { return nil }
        return RealtimeEvent(channel: channel, name: name, payload: payload)
    }

    private func sendFrame(_ frame: [String: Any]) {
        guard status == .connected, let socket, let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(text) }
    }
}

/// The SDK's socket: a URLSession WebSocket task.
final class URLSessionRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default: continue
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
