import Foundation

public final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) public static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override public class func canInit(with request: URLRequest) -> Bool { true }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let handler = Self.requestHandler else {
            let error = NSError(domain: "MockURLProtocol", code: 0, userInfo: [NSLocalizedDescriptionKey: "No request handler set"])
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {}
}
