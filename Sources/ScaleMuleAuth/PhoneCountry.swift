import Foundation

/// A country in a phone number's country picker: its name, its flag and the
/// calling code that goes in front of the number.
///
/// The list and its order are the same as `PHONE_COUNTRIES` in the web SDK
/// (`@scalemule/ui`), so a picker looks the same on every platform. United
/// States comes first and is what a picker starts on.
///
///     @State var country = PhoneCountry.unitedStates
///     PhoneNumber(local: "(415) 555-0134", country: country)?.e164  // "+14155550134"
///     PhoneNumber(local: "07911 123456", country: .find(code: "GB")!)?.e164 // "+447911123456"
public struct PhoneCountry: Sendable, Hashable, Identifiable {
    /// ISO 3166-1 alpha-2, capitals: "US".
    public let code: String
    public let name: String
    /// "+1"
    public let dialCode: String

    public var id: String { code }

    public init(code: String, name: String, dialCode: String) {
        self.code = code
        self.name = name
        self.dialCode = dialCode
    }

    /// The flag emoji for the country code.
    public var flag: String {
        let scalars = code.uppercased().unicodeScalars.compactMap { letter -> Unicode.Scalar? in
            guard ("A"..."Z").contains(Character(letter)) else { return nil }
            return Unicode.Scalar(0x1F1E6 + letter.value - 65)
        }
        guard scalars.count == 2 else { return "" }
        return String(String.UnicodeScalarView(scalars))
    }

    /// What a picker starts on.
    public static let unitedStates = PhoneCountry(code: "US", name: "United States", dialCode: "+1")

    public static let all: [PhoneCountry] = [
        PhoneCountry(code: "US", name: "United States", dialCode: "+1"),
        PhoneCountry(code: "CA", name: "Canada", dialCode: "+1"),
        PhoneCountry(code: "GB", name: "United Kingdom", dialCode: "+44"),
        PhoneCountry(code: "AU", name: "Australia", dialCode: "+61"),
        PhoneCountry(code: "DE", name: "Germany", dialCode: "+49"),
        PhoneCountry(code: "FR", name: "France", dialCode: "+33"),
        PhoneCountry(code: "IT", name: "Italy", dialCode: "+39"),
        PhoneCountry(code: "ES", name: "Spain", dialCode: "+34"),
        PhoneCountry(code: "NL", name: "Netherlands", dialCode: "+31"),
        PhoneCountry(code: "BE", name: "Belgium", dialCode: "+32"),
        PhoneCountry(code: "CH", name: "Switzerland", dialCode: "+41"),
        PhoneCountry(code: "AT", name: "Austria", dialCode: "+43"),
        PhoneCountry(code: "SE", name: "Sweden", dialCode: "+46"),
        PhoneCountry(code: "NO", name: "Norway", dialCode: "+47"),
        PhoneCountry(code: "DK", name: "Denmark", dialCode: "+45"),
        PhoneCountry(code: "FI", name: "Finland", dialCode: "+358"),
        PhoneCountry(code: "IE", name: "Ireland", dialCode: "+353"),
        PhoneCountry(code: "PT", name: "Portugal", dialCode: "+351"),
        PhoneCountry(code: "PL", name: "Poland", dialCode: "+48"),
        PhoneCountry(code: "CZ", name: "Czech Republic", dialCode: "+420"),
        PhoneCountry(code: "GR", name: "Greece", dialCode: "+30"),
        PhoneCountry(code: "RU", name: "Russia", dialCode: "+7"),
        PhoneCountry(code: "JP", name: "Japan", dialCode: "+81"),
        PhoneCountry(code: "KR", name: "South Korea", dialCode: "+82"),
        PhoneCountry(code: "CN", name: "China", dialCode: "+86"),
        PhoneCountry(code: "HK", name: "Hong Kong", dialCode: "+852"),
        PhoneCountry(code: "TW", name: "Taiwan", dialCode: "+886"),
        PhoneCountry(code: "SG", name: "Singapore", dialCode: "+65"),
        PhoneCountry(code: "MY", name: "Malaysia", dialCode: "+60"),
        PhoneCountry(code: "TH", name: "Thailand", dialCode: "+66"),
        PhoneCountry(code: "VN", name: "Vietnam", dialCode: "+84"),
        PhoneCountry(code: "PH", name: "Philippines", dialCode: "+63"),
        PhoneCountry(code: "ID", name: "Indonesia", dialCode: "+62"),
        PhoneCountry(code: "IN", name: "India", dialCode: "+91"),
        PhoneCountry(code: "PK", name: "Pakistan", dialCode: "+92"),
        PhoneCountry(code: "BD", name: "Bangladesh", dialCode: "+880"),
        PhoneCountry(code: "AE", name: "UAE", dialCode: "+971"),
        PhoneCountry(code: "SA", name: "Saudi Arabia", dialCode: "+966"),
        PhoneCountry(code: "IL", name: "Israel", dialCode: "+972"),
        PhoneCountry(code: "TR", name: "Turkey", dialCode: "+90"),
        PhoneCountry(code: "EG", name: "Egypt", dialCode: "+20"),
        PhoneCountry(code: "ZA", name: "South Africa", dialCode: "+27"),
        PhoneCountry(code: "NG", name: "Nigeria", dialCode: "+234"),
        PhoneCountry(code: "KE", name: "Kenya", dialCode: "+254"),
        PhoneCountry(code: "BR", name: "Brazil", dialCode: "+55"),
        PhoneCountry(code: "MX", name: "Mexico", dialCode: "+52"),
        PhoneCountry(code: "AR", name: "Argentina", dialCode: "+54"),
        PhoneCountry(code: "CL", name: "Chile", dialCode: "+56"),
        PhoneCountry(code: "CO", name: "Colombia", dialCode: "+57"),
        PhoneCountry(code: "PE", name: "Peru", dialCode: "+51"),
        PhoneCountry(code: "NZ", name: "New Zealand", dialCode: "+64"),
    ]

    public static func find(code: String) -> PhoneCountry? {
        let wanted = code.uppercased()
        return all.first { $0.code == wanted }
    }

    /// The countries a search box shows for `query`: by name, by country code
    /// ("gb") or by calling code ("44", "+44"). An empty query gives them all.
    public static func matching(_ query: String, in countries: [PhoneCountry] = all) -> [PhoneCountry] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return countries }
        let digits = wanted.hasPrefix("+") ? String(wanted.dropFirst()) : wanted
        return countries.filter { country in
            country.name.lowercased().contains(wanted)
                || country.code.lowercased() == wanted
                || (!digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
                    && country.dialCode.dropFirst().hasPrefix(digits))
        }
    }

    /// The country of a stored number and the part after its calling code.
    /// The longest calling code wins ("+852" before "+86"); a "+1" number is
    /// read as United States.
    public static func detect(e164: String) -> (country: PhoneCountry, local: String)? {
        guard let number = PhoneNumber(typed: e164), e164.trimmingCharacters(in: .whitespaces).hasPrefix("+") else {
            return nil
        }
        var best: PhoneCountry?
        for country in all where number.e164.hasPrefix(country.dialCode) {
            if best == nil || country.dialCode.count > (best?.dialCode.count ?? 0) { best = country }
        }
        guard let country = best else { return nil }
        let local = String(number.e164.dropFirst(country.dialCode.count))
        return local.isEmpty ? nil : (country, local)
    }
}

extension PhoneNumber {
    /// The number typed next to a country picker.
    ///
    /// The calling code of `country` goes in front of what was typed. A
    /// leading 0 that people write inside their own country ("07911 123456")
    /// is dropped, except in Italy, where it is part of the number. A United
    /// States or Canada number may be typed with its leading 1. Someone who
    /// types a whole international number ("+44 …") gets that number,
    /// whatever the picker shows. `nil` for what cannot be a phone number.
    public init?(local: String, country: PhoneCountry) {
        let trimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+") {
            self.init(typed: trimmed)
            return
        }
        let punctuation: Set<Character> = ["-", "(", ")", ".", " ", "\u{00A0}"]
        let isDigit: (Character) -> Bool = { $0.wholeNumberValue.map { (0...9).contains($0) } == true }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ isDigit($0) || punctuation.contains($0) }) else { return nil }
        var digits = trimmed.compactMap(\.wholeNumberValue).map(String.init).joined()
        if country.dialCode == "+1" {
            if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
        } else if digits.hasPrefix("0"), country.code != "IT" {
            digits.removeFirst()
        }
        guard !digits.isEmpty else { return nil }
        self.init(typed: country.dialCode + digits)
    }

    /// The number's country, for a picker (see `PhoneCountry.detect`).
    public var country: PhoneCountry? {
        PhoneCountry.detect(e164: e164)?.country
    }

    /// The part after the calling code, the way it sits in the field next to
    /// a country picker: "(415) 555-0134" for a United States or Canada
    /// number, the digits for any other.
    public var localDisplay: String {
        guard let local = PhoneCountry.detect(e164: e164)?.local else { return e164 }
        guard e164.hasPrefix("+1"), local.count == 10 else { return local }
        let digits = Array(local)
        return "(\(String(digits[0..<3]))) \(String(digits[3..<6]))-\(String(digits[6..<10]))"
    }
}
