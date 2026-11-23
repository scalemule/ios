import Foundation

// Port of the web SDK's upload-to-s3.ts: presigned PUTs straight to S3 with
// retry, stall detection and structured failure codes.

/// Why a PUT to S3 failed (same codes as the web SDK).
public enum S3UploadErrorCode: String, Sendable {
    /// 403: the presigned link expired or does not match. Refresh it.
    case signatureError = "s3_signature_error"
    /// Other 4xx (400/404/411/412/413/415): S3 refused the request itself.
    case clientError = "s3_client_error"
    case serverError = "s3_server_error"
    /// 408/429 and other retryable statuses.
    case transientError = "s3_transient_error"
    /// 2xx without an ETag on a part.
    case missingETag = "s3_missing_etag"
    case networkError = "network_error"
    /// No bytes moved for the stall timeout.
    case stalled
    case cancelled = "aborted"
    /// The server no longer has the multipart session.
    case sessionExpired = "upload_session_expired"
}

struct S3Failure: Error, Sendable {
    let code: S3UploadErrorCode
    let status: Int?
    let body: String?
    let attempts: Int

    var refreshable: Bool { code == .signatureError }
    var message: String {
        let detail = status.map { " (HTTP \($0))" } ?? ""
        return "\(code.rawValue)\(detail)"
    }
}

/// Moves bytes to presigned S3 URLs. Sends no ScaleMule credentials.
final class S3Transfer: Sendable {
    /// Delay before each attempt: now, 1 s, 3 s.
    static let retryDelays: [TimeInterval] = [0, 1, 3]
    static let fatalStatuses: Set<Int> = [400, 403, 404, 411, 412, 413, 415]
    static let maxErrorBody = 1024

    private let session: URLSession
    private let conditions: NetworkConditions
    private let retryDelays: [TimeInterval]

    init(session: URLSession? = nil, conditions: NetworkConditions = .shared, retryDelays: [TimeInterval] = S3Transfer.retryDelays) {
        self.retryDelays = retryDelays
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.timeoutIntervalForResource = 6 * 60 * 60
            self.session = URLSession(configuration: configuration)
        }
        self.conditions = conditions
    }

    /// One PUT for a small file. The URL is signed with the Content-Type,
    /// so it must be sent exactly.
    func putSingle(
        url: URL,
        data: Data,
        contentType: String,
        stallTimeout: TimeInterval,
        onAttempt: @Sendable (Int) -> Void = { _ in },
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Result<Void, S3Failure> {
        var last = S3Failure(code: .networkError, status: nil, body: nil, attempts: 0)
        for (attempt, delay) in retryDelays.enumerated() {
            if attempt > 0 {
                onAttempt(attempt + 1)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if Task.isCancelled { return .failure(S3Failure(code: .cancelled, status: nil, body: nil, attempts: attempt + 1)) }
            var request = URLRequest(url: url, timeoutInterval: stallTimeout)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            switch await put(request, data: data, measureSpeed: true, onProgress: onProgress) {
            case .success:
                return .success(())
            case .failure(let failure):
                last = S3Failure(code: failure.code, status: failure.status, body: failure.body, attempts: attempt + 1)
                if failure.code == .cancelled || Self.isFatal(failure) { return .failure(last) }
                onProgress(0)
            }
        }
        return .failure(last)
    }

    /// One multipart part. Part URLs are signed without a Content-Type, so
    /// none is sent. A 403 comes back at once so the caller can refresh the link.
    func putPart(
        url: URL,
        data: Data,
        stallTimeout: TimeInterval,
        onAttempt: @Sendable (Int) -> Void = { _ in },
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Result<String, S3Failure> {
        var last = S3Failure(code: .networkError, status: nil, body: nil, attempts: 0)
        for (attempt, delay) in retryDelays.enumerated() {
            if attempt > 0 {
                onAttempt(attempt + 1)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if Task.isCancelled { return .failure(S3Failure(code: .cancelled, status: nil, body: nil, attempts: attempt + 1)) }
            var request = URLRequest(url: url, timeoutInterval: stallTimeout)
            request.httpMethod = "PUT"
            switch await put(request, data: data, measureSpeed: false, onProgress: onProgress) {
            case .success(let etag):
                if let etag, !etag.isEmpty { return .success(etag) }
                last = S3Failure(code: .missingETag, status: 200, body: nil, attempts: attempt + 1)
            case .failure(let failure):
                last = S3Failure(code: failure.code, status: failure.status, body: failure.body, attempts: attempt + 1)
                if failure.code == .cancelled || failure.refreshable || Self.isFatal(failure) { return .failure(last) }
            }
            onProgress(0)
        }
        return .failure(last)
    }

    static func isFatal(_ failure: S3Failure) -> Bool {
        guard let status = failure.status else { return false }
        return fatalStatuses.contains(status)
    }

    static func classify(status: Int) -> S3UploadErrorCode {
        if status == 403 { return .signatureError }
        if fatalStatuses.contains(status) { return .clientError }
        if status >= 500 { return .serverError }
        return .transientError
    }

    /// The request's timeout is the idle timeout: it fires when no bytes
    /// move for that long, which is exactly a stall.
    /// Parts share the link with each other, so a part's own speed is a
    /// fraction of the connection's: multipart uploads measure as a whole.
    private func put(_ request: URLRequest, data: Data, measureSpeed: Bool, onProgress: @escaping @Sendable (Int64) -> Void) async -> Result<String?, S3Failure> {
        let started = Date()
        let delegate = ProgressDelegate(onProgress: onProgress)
        do {
            let (body, response) = try await session.upload(for: request, from: data, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                return .failure(S3Failure(code: .networkError, status: nil, body: nil, attempts: 1))
            }
            if (200..<300).contains(http.statusCode) {
                if measureSpeed { conditions.recordUpload(bytes: data.count, seconds: Date().timeIntervalSince(started)) }
                return .success(http.value(forHTTPHeaderField: "ETag"))
            }
            let text = String(decoding: body.prefix(Self.maxErrorBody), as: UTF8.self)
            return .failure(S3Failure(code: Self.classify(status: http.statusCode), status: http.statusCode, body: text, attempts: 1))
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                return .failure(S3Failure(code: Task.isCancelled ? .cancelled : .networkError, status: nil, body: nil, attempts: 1))
            case .timedOut:
                return .failure(S3Failure(code: .stalled, status: nil, body: nil, attempts: 1))
            default:
                return .failure(S3Failure(code: .networkError, status: nil, body: error.localizedDescription, attempts: 1))
            }
        } catch is CancellationError {
            return .failure(S3Failure(code: .cancelled, status: nil, body: nil, attempts: 1))
        } catch {
            return .failure(S3Failure(code: .networkError, status: nil, body: error.localizedDescription, attempts: 1))
        }
    }
}

/// Reports bytes sent for one request.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }
}
