import Foundation

public actor HTTPClient {
    private let config: Configuration
    private let session: URLSession
    public let sessionManager: SessionManager
    private let workspaceContext: WorkspaceContext
    private let logger: SMLogger

    private var rateLimitedUntil: Date = .distantPast

    private static let sdkVersion = "0.0.1"

    public init(
        config: Configuration,
        sessionManager: SessionManager,
        workspaceContext: WorkspaceContext
    ) {
        self.config = config
        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = config.timeoutInterval
        self.session = URLSession(configuration: urlConfig)
        self.sessionManager = sessionManager
        self.workspaceContext = workspaceContext
        self.logger = SMLogger(category: "HTTPClient", debug: config.debug)
    }

    /// For testing: inject a custom URLSession.
    public init(
        config: Configuration,
        sessionManager: SessionManager,
        workspaceContext: WorkspaceContext,
        urlSession: URLSession
    ) {
        self.config = config
        self.session = urlSession
        self.sessionManager = sessionManager
        self.workspaceContext = workspaceContext
        self.logger = SMLogger(category: "HTTPClient", debug: config.debug)
    }

    // MARK: - Public API

    public func request<T: Decodable & Sendable>(
        _ options: RequestOptions,
        as type: T.Type = T.self
    ) async -> ApiResponse<T> {
        await executeWithRetry(options, as: type)
    }

    public func requestVoid(_ options: RequestOptions) async -> ApiResponse<EmptyResponse> {
        await executeWithRetry(options, as: EmptyResponse.self)
    }

    // MARK: - Request Execution

    private func executeWithRetry<T: Decodable & Sendable>(
        _ options: RequestOptions,
        as type: T.Type
    ) async -> ApiResponse<T> {
        var lastError: ApiError?
        var idempotencyKey: String?

        for attempt in 0...config.maxRetries {
            // Rate limit check
            if Date() < rateLimitedUntil {
                let waitTime = rateLimitedUntil.timeIntervalSinceNow
                if waitTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                }
            }

            // Build request
            let urlRequest: URLRequest
            do {
                if attempt > 0 && options.method == .post {
                    if idempotencyKey == nil {
                        idempotencyKey = UUID().uuidString
                    }
                }
                urlRequest = try await buildRequest(options, idempotencyKey: idempotencyKey)
            } catch {
                return .failure(ApiError(code: .internalError, message: "Failed to build request: \(error.localizedDescription)"))
            }

            logger.debug("\(options.method.rawValue) \(options.path) (attempt \(attempt + 1))")

            // Execute
            let data: Data
            let httpResponse: HTTPURLResponse
            do {
                let (responseData, response) = try await session.data(for: urlRequest)
                guard let resp = response as? HTTPURLResponse else {
                    return .failure(ApiError.network("Invalid response"))
                }
                data = responseData
                httpResponse = resp
            } catch let urlError as URLError {
                if urlError.code == .timedOut {
                    lastError = .timeout()
                } else {
                    lastError = .network(urlError.localizedDescription)
                }
                if attempt < config.maxRetries {
                    await backoff(attempt: attempt)
                    continue
                }
                return .failure(lastError!)
            } catch {
                return .failure(.network(error.localizedDescription))
            }

            let statusCode = httpResponse.statusCode

            // 202 Accepted — MFA challenge (check before general 2xx)
            if statusCode == 202 {
                if let challenge = try? Self.decoder.decode(MFAChallenge.self, from: data) {
                    return .failure(ApiError(
                        code: .mfaRequired,
                        message: "MFA verification required",
                        statusCode: 202,
                        details: [
                            "pending_token": AnyCodable(challenge.pendingToken),
                            "mfa_method": AnyCodable(challenge.mfaMethod),
                            "expires_in": AnyCodable(challenge.expiresIn),
                            "allowed_methods": AnyCodable(challenge.allowedMethods),
                        ]
                    ))
                }
            }

            // 2xx success
            if (200..<300).contains(statusCode) {
                // 204 No Content
                if statusCode == 204 || data.isEmpty {
                    if type == EmptyResponse.self {
                        return .success(EmptyResponse() as! T)
                    }
                    // Try to decode empty JSON object
                    let emptyData = "{}".data(using: .utf8)!
                    do {
                        let decoded = try Self.decoder.decode(T.self, from: emptyData)
                        return .success(decoded)
                    } catch {
                        return .failure(ApiError(code: .internalError, message: "Unexpected empty response"))
                    }
                }

                do {
                    let decoded = try Self.decoder.decode(T.self, from: data)
                    return .success(decoded)
                } catch {
                    logger.error("Decode error: \(error)")
                    return .failure(ApiError(code: .internalError, message: "Failed to decode response: \(error.localizedDescription)"))
                }
            }

            // 401 Unauthorized — attempt token refresh if possible
            if statusCode == 401 && attempt == 0 {
                let refreshed = await attemptTokenRefresh(options: options)
                if refreshed {
                    continue
                }
                // Session is dead — clear and return error
                await sessionManager.clear()
                return .failure(parseError(data: data, statusCode: statusCode))
            }

            // 403 MFA_SETUP_REQUIRED
            if statusCode == 403 {
                if let setup = try? Self.decoder.decode(MFASetupRequiredResponse.self, from: data),
                   setup.code == "MFA_SETUP_REQUIRED" {
                    return .failure(ApiError(
                        code: .mfaSetupRequired,
                        message: setup.message,
                        statusCode: 403,
                        details: [
                            "requirement_source": AnyCodable(setup.requirementSource ?? "unknown"),
                        ]
                    ))
                }
            }

            // 429 Rate Limited
            if statusCode == 429 {
                if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Double(retryAfter) {
                    rateLimitedUntil = Date().addingTimeInterval(seconds)
                }
                lastError = ApiError(code: .rateLimited, message: "Rate limited", statusCode: 429)
                if attempt < config.maxRetries {
                    await backoff(attempt: attempt)
                    continue
                }
                return .failure(lastError!)
            }

            // Retryable server errors
            if [408, 500, 502, 503, 504].contains(statusCode) {
                lastError = parseError(data: data, statusCode: statusCode)
                if attempt < config.maxRetries {
                    await backoff(attempt: attempt)
                    continue
                }
                return .failure(lastError!)
            }

            // Non-retryable 4xx
            return .failure(parseError(data: data, statusCode: statusCode))
        }

        return .failure(lastError ?? ApiError(code: .internalError, message: "Request failed"))
    }

    // MARK: - Token Refresh

    private func attemptTokenRefresh(options: RequestOptions) async -> Bool {
        // Only attempt refresh for accessToken-credentialed requests in refreshToken mode
        guard options.credential == .accessToken else { return false }

        let mode = await sessionManager.authMode
        guard mode == .refreshToken else { return false }

        guard let refreshToken = await sessionManager.refreshToken else { return false }

        let refreshOptions = RequestOptions(
            method: .post,
            path: "/v1/auth/token/refresh",
            body: ["refresh_token": refreshToken],
            credential: .none
        )

        let urlRequest: URLRequest
        do {
            urlRequest = try await buildRequest(refreshOptions, idempotencyKey: nil)
        } catch {
            return false
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            let result = try Self.decoder.decode(RefreshAccessTokenResponse.self, from: data)
            let expiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn))
            try await sessionManager.updateAccessToken(result.accessToken, expiresAt: expiresAt)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Request Building

    private func buildRequest(_ options: RequestOptions, idempotencyKey: String?) async throws -> URLRequest {
        var components = URLComponents(url: config.baseURL.appendingPathComponent(options.path), resolvingAgainstBaseURL: true)!

        if let query = options.query {
            components.queryItems = QueryString.build(query)
        }

        guard let url = components.url else {
            throw ApiError(code: .internalError, message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = options.method.rawValue
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("ScaleMule-SDK-Swift/\(Self.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Workspace header
        if let workspaceId = await workspaceContext.workspaceId {
            request.setValue(workspaceId, forHTTPHeaderField: "x-sm-workspace-id")
        }

        // Idempotency key
        if let key = idempotencyKey {
            request.setValue(key, forHTTPHeaderField: "x-idempotency-key")
        }

        // Credential strategy
        switch options.credential {
        case .accessToken:
            let accessTok = await sessionManager.accessToken
            let sessionTok = await sessionManager.sessionToken
            if let token = accessTok ?? sessionTok {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .sessionToken:
            if let token = await sessionManager.sessionToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .sessionBody:
            if let token = await sessionManager.sessionToken {
                var body = options.body ?? [:]
                body["session_token"] = token
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                return request
            }
        case .none:
            break
        }

        // Body
        if let body = options.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return request
    }

    // MARK: - Error Parsing

    private func parseError(data: Data, statusCode: Int) -> ApiError {
        if let errResponse = try? Self.decoder.decode(ErrorResponse.self, from: data) {
            let code = errResponse.code.flatMap { ErrorCode(rawValue: $0) } ?? errorCodeFromStatus(statusCode)
            let message = errResponse.message ?? errResponse.error ?? "Request failed"
            return ApiError(code: code, message: message, statusCode: statusCode, details: errResponse.details)
        }
        return ApiError(code: errorCodeFromStatus(statusCode), message: "Request failed with status \(statusCode)", statusCode: statusCode)
    }

    private func errorCodeFromStatus(_ statusCode: Int) -> ErrorCode {
        switch statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 422: return .validationError
        case 429: return .rateLimited
        default: return .internalError
        }
    }

    // MARK: - Backoff

    private func backoff(attempt: Int) async {
        let baseMs: Double = 300
        let maxMs: Double = 30_000
        let delay = min(baseMs * pow(2, Double(attempt)), maxMs)
        let jitter = delay * Double.random(in: 0.7...1.3)
        try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000))
    }

    // MARK: - Decoder

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}

public struct EmptyResponse: Decodable, Sendable {}

private struct RefreshAccessTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
}

private struct MFASetupRequiredResponse: Decodable {
    let code: String?
    let message: String
    let requirementSource: String?
}
