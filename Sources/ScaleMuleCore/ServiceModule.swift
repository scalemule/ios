import Foundation

public protocol ServiceModule: Sendable {
    var client: HTTPClient { get }
    init(client: HTTPClient)
}
