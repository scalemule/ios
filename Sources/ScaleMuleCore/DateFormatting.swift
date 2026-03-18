import Foundation

public enum DateFormatting {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601FormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parseISO8601(_ string: String) -> Date? {
        iso8601Formatter.date(from: string) ?? iso8601FormatterNoFraction.date(from: string)
    }
}
