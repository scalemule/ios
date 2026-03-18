import XCTest
import ScaleMuleCore

extension XCTestCase {
    public func createTestClient() -> (ScaleMuleApp, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: config)

        let appConfig = Configuration(
            apiKey: "pk_test_abc123",
            environment: .development,
            maxRetries: 0,
            debug: true
        )

        let app = ScaleMuleApp(config: appConfig, urlSession: urlSession)
        return (app, urlSession)
    }

    public func assertApiSuccess<T>(_ result: ApiResponse<T>, file: StaticString = #filePath, line: UInt = #line) -> T? {
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            XCTFail("Expected success but got error: \(error.message)", file: file, line: line)
            return nil
        }
    }

    public func bodyJSON(_ request: URLRequest) -> [String: Any]? {
        if let data = request.httpBody {
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let data = NSMutableData()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read <= 0 { break }
                data.append(buffer, length: read)
            }
            return try? JSONSerialization.jsonObject(with: data as Data) as? [String: Any]
        }
        return nil
    }

    public func assertApiFailure<T>(_ result: ApiResponse<T>, code: ErrorCode? = nil, file: StaticString = #filePath, line: UInt = #line) -> ApiError? {
        switch result {
        case .success:
            XCTFail("Expected failure but got success", file: file, line: line)
            return nil
        case .failure(let error):
            if let code {
                XCTAssertEqual(error.code, code, file: file, line: line)
            }
            return error
        }
    }
}
