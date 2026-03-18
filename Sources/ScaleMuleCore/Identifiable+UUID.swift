import Foundation

public enum UUIDHelpers {
    public static func isValid(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }
}
