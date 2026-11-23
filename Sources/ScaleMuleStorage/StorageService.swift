import Foundation
import ScaleMuleCore

/// ScaleMule Storage uploads (`/v1/storage`): the same pipeline as the web SDK.
///
/// Bytes go straight to S3 through presigned links, never through the API:
///   - small files: one PUT (`/signed-url/upload` → PUT → `/signed-url/complete`),
///   - larger files, or 1 MB and up on a slow connection: S3 multipart
///     (`/signed-url/multipart/start` → parallel part PUTs → `/complete`).
///
/// Images are first made smaller to suit the connection (`.adaptive`). Every
/// PUT is retried (now, 1 s, 3 s), a transfer with no progress for 45 s
/// (90 s on a slow network) counts as stalled and is retried, an expired part
/// link is refreshed, and a multipart upload records its finished parts on
/// the device: uploading the same bytes again continues where it stopped,
/// within the server's 24 hour session. Events go to ScaleMule analytics and
/// logs with the web SDK's names (`upload.*`).
public final class StorageService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient
    private let transfer: S3Transfer
    private let resumeStore: UploadResumeStore
    private let telemetry: UploadTelemetry
    private let conditions: NetworkConditions

    public required convenience init(client: HTTPClient) {
        self.init(client: client, conditions: .shared)
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    init(
        client: HTTPClient,
        conditions: NetworkConditions,
        s3Session: URLSession? = nil,
        resumeDirectory: URL? = nil,
        retryDelays: [TimeInterval] = S3Transfer.retryDelays
    ) {
        self.client = client
        self.conditions = conditions
        self.transfer = S3Transfer(session: s3Session, conditions: conditions, retryDelays: retryDelays)
        self.resumeStore = UploadResumeStore(directory: resumeDirectory)
        self.telemetry = UploadTelemetry(client: client)
        let store = resumeStore
        Task.detached(priority: .background) { await store.removeExpired() }
    }

    /// The connection as the upload planner sees it.
    public func networkSnapshot() -> NetworkSnapshot {
        conditions.snapshot()
    }

    /// Upload bytes with the best strategy for their size and the connection.
    /// Cancel the calling task to stop; a cancelled multipart upload is
    /// aborted on the server.
    public func upload(_ data: Data, options: UploadOptions) async -> ApiResponse<StoredFile> {
        if Task.isCancelled { return .failure(Self.cancelledError) }
        let sessionId = UploadTelemetry.newSessionId()
        let network = conditions.snapshot()
        let started = Date()
        let report = options.telemetry ? telemetry : nil
        report?.emit(sessionId, .started, fields([
            "size_bytes": data.count,
            "content_type": options.contentType,
            "network_type": network.networkClass.rawValue,
            "interface": network.interface.rawValue,
            "measured_uplink_mbps": network.measuredUplinkMbps,
        ]))

        var payload = data
        var contentType = options.contentType
        var filename = options.filename
        if let profile = compressionProfile(options.compression, network: network) {
            report?.emit(sessionId, .compressionStarted, fields([
                "original_size": data.count, "network": network.networkClass.rawValue, "target_quality": profile.quality,
            ]))
            let outcome = await Task.detached(priority: .userInitiated) {
                ImageCompression.compress(data, contentType: options.contentType, filename: options.filename, profile: profile)
            }.value
            switch outcome {
            case .compressed(let result):
                payload = result.data
                contentType = result.contentType
                filename = result.filename
                report?.emit(sessionId, .compressionCompleted, fields([
                    "original_size": data.count, "compressed_size": result.data.count,
                    "ratio": String(format: "%.2f", Double(result.data.count) / Double(max(data.count, 1))),
                ]))
            case .skipped(let reason):
                report?.emit(sessionId, .compressionSkipped, fields(["reason": reason, "type": options.contentType, "size": data.count]))
            }
        }

        let plan = UploadStrategy.plan(
            size: payload.count,
            network: network,
            forceMultipart: options.forceMultipart,
            chunkSize: options.chunkSize,
            concurrency: options.maxConcurrency
        )
        let job = Job(
            sessionId: sessionId,
            data: payload,
            filename: filename,
            contentType: contentType,
            options: options,
            plan: plan,
            network: network,
            telemetry: report,
            started: started
        )
        switch plan.strategy {
        case .direct: return await uploadDirect(job)
        case .multipart: return await uploadMultipart(job)
        }
    }

    /// A private upload of the exact bytes (no compression): originals,
    /// attachments. Same pipeline as `upload`.
    public func uploadPrivate(_ data: Data, options: UploadOptions) async -> ApiResponse<StoredFile> {
        var options = options
        options.visibility = .private
        options.compression = .off
        let result = await upload(data, options: options)
        if case .success(let file) = result, let visibility = file.visibility, visibility != .private {
            return .failure(ApiError(
                code: .internalError,
                message: "Storage returned visibility \(visibility.rawValue) for a private upload.",
                rawCode: "visibility_violation"
            ))
        }
        return result
    }

    // MARK: - Direct (one PUT)

    private func uploadDirect(_ job: Job) async -> ApiResponse<StoredFile> {
        let init_: ApiResponse<PresignedUploadResponse> = await client.request(job.request(
            "/v1/storage/signed-url/upload",
            body: job.baseBody.merging(["size_bytes": job.data.count]) { $1 }
        ))
        guard case .success(let presigned) = init_ else {
            job.telemetry?.emit(job.sessionId, .failed, fields(["step": "presign", "error": init_.error?.message]))
            return .failure(init_.error ?? Self.cancelledError)
        }
        guard let url = URL(string: presigned.uploadUrl) else {
            return .failure(ApiError(code: .internalError, message: "Storage returned an invalid upload link"))
        }

        let progress = job.options.onProgress
        let total = Int64(job.data.count)
        progress?(UploadProgress(bytesSent: 0, totalBytes: total))
        let put = await transfer.putSingle(
            url: url,
            data: job.data,
            contentType: job.contentType,
            stallTimeout: job.plan.stallTimeout,
            onAttempt: { attempt in job.telemetry?.emit(job.sessionId, .retried, fields(["attempt": attempt, "step": "s3_put"])) },
            onProgress: { sent in progress?(UploadProgress(bytesSent: sent, totalBytes: total)) }
        )
        if case .failure(let failure) = put {
            if failure.code == .stalled { job.telemetry?.emit(job.sessionId, .stalled, fields(["step": "s3_put", "file_id": presigned.fileId])) }
            job.telemetry?.emit(job.sessionId, failure.code == .cancelled ? .aborted : .failed, fields([
                "step": "s3_put", "file_id": presigned.fileId, "reason": failure.code.rawValue, "status": failure.status,
            ]))
            await reportFailure(job, fileId: presigned.fileId, token: presigned.completionToken, step: "s3_put", failure: failure)
            return .failure(Self.error(for: failure))
        }

        let complete: ApiResponse<UploadCompleteResponse> = await client.request(job.request(
            "/v1/storage/signed-url/complete",
            body: ["file_id": presigned.fileId, "completion_token": presigned.completionToken, "size_bytes": job.data.count]
        ))
        switch complete {
        case .success(let done):
            job.telemetry?.emit(job.sessionId, .completed, fields([
                "file_id": done.fileId, "size_bytes": job.data.count, "duration_ms": job.elapsedMs, "strategy": "direct",
            ]))
            progress?(UploadProgress(bytesSent: total, totalBytes: total))
            return .success(done.storedFile)
        case .failure(let error):
            job.telemetry?.emit(job.sessionId, .failed, fields(["step": "complete", "error": error.message, "file_id": presigned.fileId]))
            await reportFailure(job, fileId: presigned.fileId, token: presigned.completionToken, step: "complete",
                                code: error.rawCode ?? error.code.rawValue, message: error.message, status: error.statusCode, attempt: nil)
            return .failure(error)
        }
    }

    // MARK: - Multipart

    private func uploadMultipart(_ job: Job, allowResume: Bool = true) async -> ApiResponse<StoredFile> {
        job.telemetry?.emit(job.sessionId, .multipartStarted, fields(["size_bytes": job.data.count]))
        let resumeKey = UploadResumeStore.key(
            apiKey: client.configuration.apiKey,
            owner: "",
            filename: job.filename,
            data: job.data
        )

        // 1. Start, or pick up the session recorded on this device.
        var session: ResumeSession
        var urls: [Int: String] = [:]
        if job.options.resume, allowResume, let saved = await resumeStore.get(resumeKey) {
            session = saved
            job.telemetry?.emit(job.sessionId, .resumed, fields([
                "original_session_id": saved.uploadSessionId,
                "completed_parts": saved.completedParts.count,
                "total_parts": saved.totalParts,
            ]))
            // A session the server no longer knows (expired, finished, other
            // account) cannot continue: start again from the beginning.
            let firstPending = (1...saved.totalParts).filter { saved.completedParts[$0] == nil }.prefix(16)
            if !firstPending.isEmpty {
                switch await fetchPartURLs(job, session: saved, parts: Array(firstPending)) {
                case .success(let fresh):
                    urls = fresh
                case .failure(let error) where (error.statusCode ?? 0) >= 400 && (error.statusCode ?? 0) < 500:
                    await resumeStore.remove(resumeKey)
                    return await uploadMultipart(job, allowResume: false)
                case .failure(let error):
                    return .failure(error)
                }
            }
        } else {
            var body = job.baseBody
            body["size_bytes"] = job.data.count
            body["client_upload_key"] = resumeKey
            if let chunk = job.options.chunkSize { body["chunk_size"] = chunk } else { body["chunk_size"] = job.plan.chunkSize }
            let start: ApiResponse<MultipartStartResponse> = await client.request(job.request("/v1/storage/signed-url/multipart/start", body: body))
            guard case .success(let started) = start else {
                job.telemetry?.emit(job.sessionId, .multipartAborted, fields(["error": start.error?.message, "step": "start"]))
                return .failure(start.error ?? Self.cancelledError)
            }
            session = ResumeSession(
                uploadSessionId: started.uploadSessionId,
                fileId: started.fileId,
                completionToken: started.completionToken,
                totalParts: started.totalParts,
                partSizeBytes: started.partSizeBytes,
                completedParts: [:],
                createdAt: Date()
            )
            for part in started.partUrls { urls[part.partNumber] = part.url }
            if job.options.resume {
                do { try await resumeStore.save(resumeKey, session) } catch {
                    job.telemetry?.emit(job.sessionId, .retried, fields(["step": "resume_save", "error": error.localizedDescription]))
                }
            }
        }

        // 2. Parts, several at a time, in a sliding window.
        let pending = (1...session.totalParts).filter { session.completedParts[$0] == nil }
        let tracker = ProgressTracker(
            total: Int64(job.data.count),
            alreadySent: Int64(session.completedParts.keys.reduce(0) { $0 + partRange($1, session: session, size: job.data.count).count }),
            onProgress: job.options.onProgress
        )
        tracker.report()
        var milestone = 0
        var failure: (part: Int, failure: S3Failure)?
        var next = 0

        await withTaskGroup(of: PartOutcome.self) { group in
            var running = 0
            func refill() async {
                while failure == nil && running < job.plan.concurrency && next < pending.count && !Task.isCancelled {
                    let part = pending[next]
                    if urls[part] == nil {
                        // Ask for the next window of links at once.
                        let wanted = pending[next...].prefix(16).filter { urls[$0] == nil }
                        if case .success(let fresh) = await fetchPartURLs(job, session: session, parts: Array(wanted)) {
                            urls.merge(fresh) { $1 }
                        }
                    }
                    guard let link = urls[part], let url = URL(string: link) else {
                        failure = (part, S3Failure(code: .signatureError, status: nil, body: "No upload link for part", attempts: 0))
                        return
                    }
                    let range = partRange(part, session: session, size: job.data.count)
                    let bytes = job.data.subdata(in: range)
                    let currentSession = session
                    group.addTask {
                        await self.uploadPart(job, session: currentSession, part: part, url: url, bytes: bytes, tracker: tracker)
                    }
                    next += 1
                    running += 1
                }
            }

            await refill()
            while let outcome = await group.next() {
                running -= 1
                switch outcome {
                case .done(let part, let etag):
                    session.completedParts[part] = etag
                    job.telemetry?.emit(job.sessionId, .multipartPartCompleted, fields(["part_number": part]))
                    if job.options.resume {
                        try? await resumeStore.recordPart(resumeKey, partNumber: part, etag: etag)
                    }
                    let percent = session.completedParts.count * 100 / max(session.totalParts, 1)
                    let reached = percent / 25 * 25
                    if reached > milestone && reached < 100 {
                        milestone = reached
                        job.telemetry?.emit(job.sessionId, .progress, fields([
                            "percent": reached, "uploaded_parts": session.completedParts.count, "total_parts": session.totalParts,
                        ]))
                    }
                case .failed(let part, let partFailure):
                    if failure == nil { failure = (part, partFailure) }
                    group.cancelAll()
                }
                await refill()
            }
        }

        if Task.isCancelled || failure?.failure.code == .cancelled {
            await abort(job, session: session)
            await resumeStore.remove(resumeKey)
            job.telemetry?.emit(job.sessionId, .aborted, fields(["file_id": session.fileId]))
            return .failure(Self.cancelledError)
        }
        if let failure {
            job.telemetry?.emit(job.sessionId, .multipartPartFailed, fields([
                "part_number": failure.part, "code": failure.failure.code.rawValue, "status": failure.failure.status,
            ]))
            if failure.failure.code == .stalled {
                job.telemetry?.emit(job.sessionId, .stalled, fields(["step": "multipart_part", "part_number": failure.part]))
            }
            job.telemetry?.emit(job.sessionId, .failed, fields([
                "step": "multipart_part", "file_id": session.fileId, "reason": failure.failure.code.rawValue,
                "completed_parts": session.completedParts.count, "total_parts": session.totalParts,
            ]))
            await reportFailure(job, fileId: session.fileId, token: session.completionToken, step: "multipart_part", failure: failure.failure, part: failure.part)
            // A request S3 refused for good cannot be continued; anything
            // else (lost connection, stall, server error) keeps the session
            // so the next try sends only the missing parts.
            if S3Transfer.isFatal(failure.failure) && !failure.failure.refreshable {
                await abort(job, session: session)
                await resumeStore.remove(resumeKey)
            }
            return .failure(Self.error(for: failure.failure))
        }

        // 3. Complete.
        let parts = session.completedParts.sorted { $0.key < $1.key }.map { ["part_number": $0.key, "etag": $0.value] }
        let complete: ApiResponse<UploadCompleteResponse> = await client.request(job.request(
            "/v1/storage/signed-url/multipart/complete",
            body: [
                "upload_session_id": session.uploadSessionId,
                "file_id": session.fileId,
                "completion_token": session.completionToken,
                "parts": parts,
            ]
        ))
        switch complete {
        case .success(let done):
            await resumeStore.remove(resumeKey)
            job.telemetry?.emit(job.sessionId, .multipartCompleted, fields(["file_id": done.fileId, "size_bytes": job.data.count, "duration_ms": job.elapsedMs]))
            job.telemetry?.emit(job.sessionId, .completed, fields([
                "file_id": done.fileId, "size_bytes": job.data.count, "duration_ms": job.elapsedMs,
                "strategy": "multipart", "parts": session.totalParts,
            ]))
            job.options.onProgress?(UploadProgress(bytesSent: Int64(job.data.count), totalBytes: Int64(job.data.count)))
            return .success(done.storedFile)
        case .failure(let error):
            if let status = error.statusCode, (400..<500).contains(status) { await resumeStore.remove(resumeKey) }
            job.telemetry?.emit(job.sessionId, .multipartAborted, fields(["file_id": session.fileId, "error": error.message, "duration_ms": job.elapsedMs]))
            await reportFailure(job, fileId: session.fileId, token: session.completionToken, step: "multipart_complete",
                                code: error.rawCode ?? error.code.rawValue, message: error.message, status: error.statusCode, attempt: nil)
            return .failure(error)
        }
    }

    private enum PartOutcome: Sendable {
        case done(Int, String)
        case failed(Int, S3Failure)
    }

    private func uploadPart(_ job: Job, session: ResumeSession, part: Int, url: URL, bytes: Data, tracker: ProgressTracker) async -> PartOutcome {
        let onAttempt: @Sendable (Int) -> Void = { attempt in
            job.telemetry?.emit(job.sessionId, .retried, fields(["attempt": attempt, "part_number": part]))
        }
        let onProgress: @Sendable (Int64) -> Void = { sent in tracker.update(part: part, sent: sent) }
        var result = await transfer.putPart(url: url, data: bytes, stallTimeout: job.plan.stallTimeout, onAttempt: onAttempt, onProgress: onProgress)
        // An expired or mismatched link: get a fresh one and try again.
        if case .failure(let failure) = result, failure.refreshable {
            job.telemetry?.emit(job.sessionId, .multipartURLRefreshed, fields(["part_number": part]))
            if case .success(let fresh) = await fetchPartURLs(job, session: session, parts: [part]),
               let link = fresh[part], let freshURL = URL(string: link) {
                result = await transfer.putPart(url: freshURL, data: bytes, stallTimeout: job.plan.stallTimeout, onAttempt: onAttempt, onProgress: onProgress)
            }
        }
        switch result {
        case .success(let etag):
            tracker.finish(part: part, size: Int64(bytes.count))
            return .done(part, etag)
        case .failure(let failure):
            tracker.update(part: part, sent: 0)
            return .failed(part, failure)
        }
    }

    private func fetchPartURLs(_ job: Job, session: ResumeSession, parts: [Int]) async -> ApiResponse<[Int: String]> {
        guard !parts.isEmpty else { return .success([:]) }
        let result: ApiResponse<MultipartPartUrlsResponse> = await client.request(job.request(
            "/v1/storage/signed-url/multipart/part-urls",
            body: [
                "upload_session_id": session.uploadSessionId,
                "part_numbers": parts,
                "completion_token": session.completionToken,
            ]
        ))
        switch result {
        case .success(let response):
            return .success(Dictionary(response.partUrls.map { ($0.partNumber, $0.url) }) { $1 })
        case .failure(let error):
            return .failure(error)
        }
    }

    private func abort(_ job: Job, session: ResumeSession) async {
        _ = await client.requestVoid(job.request(
            "/v1/storage/signed-url/multipart/abort",
            body: ["upload_session_id": session.uploadSessionId, "completion_token": session.completionToken],
            retryable: false
        ))
    }

    private func partRange(_ part: Int, session: ResumeSession, size: Int) -> Range<Int> {
        let start = (part - 1) * session.partSizeBytes
        return start..<min(start + session.partSizeBytes, size)
    }

    // MARK: - Failure reports (Storage keeps them with the file record)

    private func reportFailure(_ job: Job, fileId: String, token: String, step: String, failure: S3Failure, part: Int? = nil) async {
        await reportFailure(job, fileId: fileId, token: token, step: step, code: failure.code.rawValue,
                            message: failure.message, status: failure.status, attempt: failure.attempts, part: part, s3Body: failure.body)
    }

    private func reportFailure(
        _ job: Job, fileId: String, token: String, step: String, code: String, message: String,
        status: Int?, attempt: Int?, part: Int? = nil, s3Body: String? = nil
    ) async {
        var diagnostics: [String: Any] = [
            "platform": "ios",
            "network_type": job.network.networkClass.rawValue,
            "interface": job.network.interface.rawValue,
            "is_expensive": job.network.isExpensive,
            "is_constrained": job.network.isConstrained,
            "duration_ms": job.elapsedMs,
            "strategy": job.plan.strategy.rawValue,
        ]
        if let mbps = job.network.measuredUplinkMbps { diagnostics["measured_uplink_mbps"] = mbps }
        if let part { diagnostics["part_number"] = part }
        if let s3Body { diagnostics["s3_error_body"] = s3Body }
        var body: [String: Any] = [
            "file_id": fileId,
            "completion_token": token,
            "step": step,
            "error_code": code,
            "error_message": message,
            "diagnostics": diagnostics,
        ]
        if let status { body["http_status"] = status }
        if let attempt { body["attempt"] = attempt }
        _ = await client.requestVoid(job.request("/v1/storage/signed-url/report-failure", body: body, retryable: false))
    }

    // MARK: - Helpers

    private func compressionProfile(_ mode: UploadCompression, network: NetworkSnapshot) -> ImageCompressionProfile? {
        switch mode {
        case .off: return nil
        case .custom(let profile): return profile
        case .adaptive: return .forNetwork(network.networkClass)
        }
    }

    static let cancelledError = ApiError(code: .networkError, message: "Upload cancelled", rawCode: "aborted")

    static func error(for failure: S3Failure) -> ApiError {
        switch failure.code {
        case .cancelled:
            return cancelledError
        case .networkError:
            return ApiError(code: .networkError, message: "The connection dropped during the upload", rawCode: failure.code.rawValue)
        case .stalled:
            return ApiError(code: .timeout, message: "The upload stopped moving", rawCode: failure.code.rawValue)
        default:
            // S3 itself refused or failed: a fault on our side, not the person's.
            return ApiError(code: .internalError, message: "Upload failed: \(failure.message)", statusCode: 502, rawCode: failure.code.rawValue)
        }
    }

    /// One upload's settings, shared by its steps.
    struct Job: Sendable {
        let sessionId: String
        let data: Data
        let filename: String
        let contentType: String
        let options: UploadOptions
        let plan: UploadPlan
        let network: NetworkSnapshot
        let telemetry: UploadTelemetry?
        let started: Date

        var elapsedMs: Int { Int(Date().timeIntervalSince(started) * 1000) }

        var baseBody: [String: Any] {
            var body: [String: Any] = [
                "filename": filename,
                "content_type": contentType,
                "visibility": options.visibility.rawValue,
            ]
            if let metadata = options.metadata { body["metadata"] = metadata.mapValues(\.value) }
            return body
        }

        func request(_ path: String, body: [String: Any], retryable: Bool = true) -> RequestOptions {
            RequestOptions(
                method: .post,
                path: path,
                body: body,
                credential: .accessToken,
                retryable: retryable,
                headers: ["X-Upload-Session-Id": sessionId]
            )
        }
    }
}

/// Bytes sent across parts in flight, reported as one number.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private var finished: Int64
    private var inFlight: [Int: Int64] = [:]
    private let onProgress: (@Sendable (UploadProgress) -> Void)?

    init(total: Int64, alreadySent: Int64, onProgress: (@Sendable (UploadProgress) -> Void)?) {
        self.total = total
        self.finished = alreadySent
        self.onProgress = onProgress
    }

    func update(part: Int, sent: Int64) {
        lock.lock()
        inFlight[part] = sent
        let value = finished + inFlight.values.reduce(0, +)
        lock.unlock()
        onProgress?(UploadProgress(bytesSent: min(value, total), totalBytes: total))
    }

    func finish(part: Int, size: Int64) {
        lock.lock()
        inFlight[part] = nil
        finished += size
        let value = finished + inFlight.values.reduce(0, +)
        lock.unlock()
        onProgress?(UploadProgress(bytesSent: min(value, total), totalBytes: total))
    }

    func report() {
        lock.lock()
        let value = finished
        lock.unlock()
        onProgress?(UploadProgress(bytesSent: value, totalBytes: total))
    }
}
