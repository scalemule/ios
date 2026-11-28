import Foundation

/// A phone number as a person types it, turned into the one form the server
/// takes (E.164: "+", then country code and number, digits only).
///
/// A number typed without a country code is read as a United States or Canada
/// number. Anything that cannot be a phone number gives `nil`, so a screen can
/// ask again before a text is sent.
///
///     PhoneNumber(typed: "(415) 555-0134")?.e164   // "+14155550134"
///     PhoneNumber(typed: "+44 20 7946 0958")?.e164 // "+442079460958"
public struct PhoneNumber: Sendable, Equatable {
    /// "+14155550134"
    public let e164: String

    public init?(typed: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only digits and the usual punctuation; letters or emoji are not a number.
        let punctuation: Set<Character> = ["+", "-", "(", ")", ".", " ", "\u{00A0}"]
        let isDigit: (Character) -> Bool = { $0.wholeNumberValue.map { (0...9).contains($0) } == true }
        guard trimmed.allSatisfy({ isDigit($0) || punctuation.contains($0) }),
              !trimmed.dropFirst().contains("+") else { return nil }
        // Digits from any keyboard (Arabic-Indic, for one) are folded to 0-9.
        let number = trimmed.compactMap(\.wholeNumberValue).map(String.init).joined()

        let digits: String
        if trimmed.hasPrefix("+") {
            digits = number
        } else if number.count == 10 {
            digits = "1" + number
        } else if number.count == 11, number.first == "1" {
            digits = number
        } else {
            return nil
        }
        // International form: 10 to 15 digits, never starting with 0. A
        // United States or Canada number is 1, then ten digits whose area
        // code and exchange each start with 2 to 9.
        guard (10...15).contains(digits.count), digits.first != "0" else { return nil }
        if digits.first == "1" {
            let all = Array(digits)
            guard all.count == 11, ("2"..."9").contains(all[1]), ("2"..."9").contains(all[4]) else { return nil }
        }
        e164 = "+" + digits
    }

    /// "+1 (415) 555-0134" for a United States or Canada number; otherwise
    /// the number as stored.
    public var display: String {
        guard e164.hasPrefix("+1"), e164.count == 12 else { return e164 }
        let digits = Array(e164.dropFirst(2))
        return "+1 (\(String(digits[0..<3]))) \(String(digits[3..<6]))-\(String(digits[6..<10]))"
    }

    /// Display form of a stored number, or the text itself if it is not one.
    public static func display(_ stored: String) -> String {
        PhoneNumber(typed: stored)?.display ?? stored
    }
}
