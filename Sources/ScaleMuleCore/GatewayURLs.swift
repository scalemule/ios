import Foundation

public enum GatewayEnvironment: String, Sendable {
    case production = "https://api.scalemule.com"
    case development = "https://api-dev.scalemule.com"
    case custom

    public var baseURL: URL {
        URL(string: rawValue)!
    }
}
