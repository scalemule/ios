import Foundation

public struct Configuration: Sendable {
    public let apiKey: String
    public let environment: GatewayEnvironment
    public let baseURL: URL
    public let maxRetries: Int
    public let timeoutInterval: TimeInterval
    public let debug: Bool

    public init(
        apiKey: String,
        environment: GatewayEnvironment = .production,
        customBaseURL: URL? = nil,
        maxRetries: Int = 2,
        timeoutInterval: TimeInterval = 30,
        debug: Bool = false
    ) {
        self.apiKey = apiKey
        self.environment = customBaseURL != nil ? .custom : environment
        self.baseURL = customBaseURL ?? environment.baseURL
        self.maxRetries = maxRetries
        self.timeoutInterval = timeoutInterval
        self.debug = debug
    }
}
