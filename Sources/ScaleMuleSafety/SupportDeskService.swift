import Foundation
import ScaleMuleCore

/// One message in a person's conversation with the app's team.
public struct SupportDeskMessage: Sendable, Decodable, Identifiable, Equatable {
    public enum Author: String, Sendable, Decodable {
        case you
        case team
    }

    public let id: String
    public let text: String
    public let from: Author
    public let sentAt: Date?

    public init(id: String, text: String, from: Author, sentAt: Date? = nil) {
        self.id = id
        self.text = text
        self.from = from
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, from
        case sentAt = "sent_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        from = (try? container.decode(Author.self, forKey: .from)) ?? .team
        let raw = try container.decodeIfPresent(String.self, forKey: .sentAt)
        sentAt = raw.flatMap(SupportDeskService.date(from:))
    }
}

/// The app build and device, sent with a message so the team can help.
public struct SupportDeskDevice: Sendable, Equatable {
    public var version: String
    public var build: String
    public var os: String
    public var model: String

    public init(version: String, build: String, os: String, model: String) {
        self.version = version
        self.build = build
        self.os = os
        self.model = model
    }

    /// This app and this device.
    public static var current: SupportDeskDevice {
        let info = Bundle.main.infoDictionary
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SupportDeskDevice(
            version: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            os: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            model: model
        )
    }
}

/// A conversation with the app's team that the team answers in its own
/// support inbox (for example a CoralMeet workspace).
///
/// The app talks to its OWN website, never to the inbox: `endpoint` is a
/// route on that site (`https://example.com/api/support/messages`) which
/// checks the person's ScaleMule session, holds the inbox's credentials on
/// the server and passes messages both ways.
///
/// - `GET endpoint` → `{ "messages": [{ "id", "text", "from": "you"|"team", "sent_at" }] }`, oldest first.
/// - `POST endpoint` with `{ "content", "device" }` → `{ "message": { … } }`.
/// - A refusal is `{ "code", "message" }`; `message` is written for people.
///
/// The site keeps the conversation in HttpOnly cookies, so use a `URLSession`
/// that stores cookies (the default `.shared` does).
public final class SupportDeskService: @unchecked Sendable {
    private let client: HTTPClient
    private let endpoint: URL
    private let urlSession: URLSession

    public init(app: ScaleMuleApp, endpoint: URL, urlSession: URLSession = .shared) {
        self.client = app.client
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    /// The conversation so far, oldest message first. Empty when the person
    /// has not written yet. Reading never starts a conversation.
    public func messages() async -> ApiResponse<[SupportDeskMessage]> {
        switch await call(method: "GET", body: nil) {
        case .success(let reply): return .success(reply.messages ?? [])
        case .failure(let error): return .failure(error)
        }
    }

    /// Send one message. Returns it as the conversation now shows it.
    public func send(_ text: String, device: SupportDeskDevice = .current) async -> ApiResponse<SupportDeskMessage> {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "content": content,
            "device": ["version": device.version, "build": device.build, "os": device.os, "model": device.model],
        ]
        switch await call(method: "POST", body: body) {
        case .success(let reply):
            return .success(reply.message ?? SupportDeskMessage(id: UUID().uuidString, text: content, from: .you, sentAt: Date()))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Forget this device's conversation (signing out, deleting the account).
    public func forgetConversation() {
        guard let storage = urlSession.configuration.httpCookieStorage else { return }
        for cookie in storage.cookies(for: endpoint) ?? [] { storage.deleteCookie(cookie) }
    }

    // MARK: - Internals

    private struct Reply: Decodable, Sendable {
        let messages: [SupportDeskMessage]?
        let message: SupportDeskMessage?
        let code: String?
        let refusal: String?

        private enum CodingKeys: String, CodingKey { case messages, message, code }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            messages = try? container.decodeIfPresent([SupportDeskMessage].self, forKey: .messages)
            code = try? container.decodeIfPresent(String.self, forKey: .code)
            // On success `message` is the sent message; on refusal it is a sentence.
            message = try? container.decodeIfPresent(SupportDeskMessage.self, forKey: .message)
            refusal = try? container.decodeIfPresent(String.self, forKey: .message)
        }
    }

    private func call(method: String, body: [String: Any]?) async -> ApiResponse<Reply> {
        let first = await attempt(method: method, body: body)
        guard case .failure(let error) = first, error.statusCode == 401 else { return first }
        // The short-lived token may have expired: let the SDK renew it, then try once more.
        let renewed = await client.requestData(RequestOptions(method: .get, path: "/v1/auth/me", credential: .accessToken))
        guard case .success = renewed else { return first }
        return await attempt(method: method, body: body)
    }

    private func attempt(method: String, body: [String: Any]?) async -> ApiResponse<Reply> {
        let access = await client.sessionManager.accessToken
        let session = await client.sessionManager.sessionToken
        guard let token = access ?? session else {
            // No status code: there is nothing to renew, so `call` does not retry.
            return .failure(ApiError(code: .unauthorized, message: "Sign in first."))
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let status: Int
        do {
            let (received, response) = try await urlSession.data(for: request)
            data = received
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch let error as URLError where error.code == .timedOut {
            return .failure(ApiError(code: .timeout, message: "Request timed out"))
        } catch {
            return .failure(ApiError(code: .networkError, message: "Network error"))
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if (200..<300).contains(status), let reply { return .success(reply) }
        let code: ErrorCode
        switch status {
        case 401: code = .unauthorized
        case 403: code = .forbidden
        case 422: code = .validationError
        case 429: code = .rateLimited
        default: code = .internalError
        }
        return .failure(ApiError(
            code: code,
            message: reply?.refusal ?? "",
            statusCode: status == 0 ? nil : status,
            rawCode: reply?.code
        ))
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
