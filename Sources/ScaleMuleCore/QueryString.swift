import Foundation

public enum QueryString {
    public static func build(_ params: [String: String?]) -> [URLQueryItem] {
        params.compactMap { key, value in
            guard let value else { return nil }
            return URLQueryItem(name: key, value: value)
        }
    }
}
