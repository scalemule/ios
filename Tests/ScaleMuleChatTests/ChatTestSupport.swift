import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleRealtime
@testable import ScaleMuleChat

/// A socket the test drives: `push` is what the server sends.
final class FakeSocket: RealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sentFrames: [String] = []
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false

    struct Closed: Error {}

    var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func send(_ text: String) async throws {
        try record(text)
    }

    private func record(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        if closed { throw Closed() }
        sentFrames.append(text)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !incoming.isEmpty {
                let next = incoming.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: Closed())
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func push(_ text: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            incoming.append(text)
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(throwing: Closed())
    }

    /// The JSON frames sent, as dictionaries ("ping" is left out).
    var frames: [[String: String]] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String] }
    }
}

/// Hands out a new `FakeSocket` for every connection.
final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeSocket] = []
    private var urlsSeen: [URL] = []

    var sockets: [FakeSocket] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urlsSeen
    }

    /// What the server says first on a connection it accepts.
    var greets = true

    func make(_ url: URL) -> RealtimeSocket {
        let socket = FakeSocket()
        if greets { socket.push("{\"type\": \"auth_success\"}") }
        lock.lock()
        made.append(socket)
        urlsSeen.append(url)
        lock.unlock()
        return socket
    }
}

extension XCTestCase {
    /// Wait (up to two seconds) for something that happens on another task.
    @MainActor
    func eventually(_ what: String = "condition", file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    func liveEvent(channel: String, name: String, _ data: [String: Any]) -> RealtimeEvent {
        RealtimeEvent(channel: channel, name: name, payload: try! JSONSerialization.data(withJSONObject: data))
    }

    func messageJSON(id: String, from sender: String, _ text: String, at time: String = "2026-11-24T10:00:00Z") -> String {
        """
        {"id": "\(id)", "content": "\(text)", "content_format": "plain", "message_type": "text", "sender_id": "\(sender)",
         "is_deleted": false, "is_edited": false, "created_at": "\(time)", "is_pinned": false}
        """
    }
}
