import XCTest
@testable import ScaleMuleAuth

final class PhoneCountryTests: XCTestCase {
    func testTheListStartsWithTheUnitedStatesAndHasNoRepeats() {
        XCTAssertEqual(PhoneCountry.all.count, 51, "the same list as PHONE_COUNTRIES in @scalemule/ui")
        XCTAssertEqual(PhoneCountry.all.first, .unitedStates)
        XCTAssertEqual(Set(PhoneCountry.all.map(\.code)).count, PhoneCountry.all.count)
        for country in PhoneCountry.all {
            XCTAssertEqual(country.code.count, 2, country.name)
            XCTAssertTrue(country.dialCode.hasPrefix("+") && country.dialCode.dropFirst().allSatisfy(\.isNumber), country.name)
            XCTAssertEqual(country.flag.unicodeScalars.count, 2, country.name)
            XCTAssertFalse(country.name.isEmpty)
        }
        XCTAssertEqual(PhoneCountry.unitedStates.flag, "🇺🇸")
        XCTAssertEqual(PhoneCountry.find(code: "gb")?.dialCode, "+44")
        XCTAssertEqual(PhoneCountry.find(code: "GB")?.flag, "🇬🇧")
        XCTAssertNil(PhoneCountry.find(code: "ZZ"))
        XCTAssertEqual(PhoneCountry(code: "1", name: "x", dialCode: "+1").flag, "")
        XCTAssertEqual(PhoneCountry(code: "Пл", name: "x", dialCode: "+1").flag, "")
    }

    func testSearchFindsByNameCountryCodeAndCallingCode() {
        XCTAssertEqual(PhoneCountry.matching("").count, 51)
        XCTAssertEqual(PhoneCountry.matching("   ").count, 51)
        XCTAssertEqual(PhoneCountry.matching("united").map(\.code), ["US", "GB"])
        XCTAssertEqual(PhoneCountry.matching(" KINGDOM ").map(\.code), ["GB"])
        XCTAssertEqual(PhoneCountry.matching("gb").map(\.code), ["GB"])
        XCTAssertEqual(PhoneCountry.matching("+44").map(\.code), ["GB"])
        XCTAssertEqual(PhoneCountry.matching("44").map(\.code), ["GB"])
        XCTAssertEqual(PhoneCountry.matching("1").map(\.code), ["US", "CA"])
        XCTAssertEqual(PhoneCountry.matching("35").map(\.code), ["FI", "IE", "PT"])
        // Nothing to find is an empty list, in any script.
        for query in ["Пламен", "山田", "😀", "٤٤", "+", "zzz"] {
            XCTAssertEqual(PhoneCountry.matching(query), [], query)
        }
        let few = [PhoneCountry.unitedStates, PhoneCountry.find(code: "CA")!]
        XCTAssertEqual(PhoneCountry.matching("a", in: few).map(\.code), ["US", "CA"])
        XCTAssertEqual(PhoneCountry.matching("44", in: few), [])
    }

    func testAStoredNumberGivesItsCountryAndTheRest() {
        XCTAssertEqual(PhoneCountry.detect(e164: "+14155550134")?.country.code, "US")
        XCTAssertEqual(PhoneCountry.detect(e164: "+14155550134")?.local, "4155550134")
        XCTAssertEqual(PhoneCountry.detect(e164: "+447911123456")?.country.code, "GB")
        XCTAssertEqual(PhoneCountry.detect(e164: "+447911123456")?.local, "7911123456")
        // The longest calling code wins.
        XCTAssertEqual(PhoneCountry.detect(e164: "+85251234567")?.country.code, "HK")
        XCTAssertEqual(PhoneCountry.detect(e164: "+8613812345678")?.country.code, "CN")
        XCTAssertEqual(PhoneCountry.detect(e164: "+358401234567")?.country.code, "FI")
        // A country that is not in the list, and what is not a number.
        XCTAssertNil(PhoneCountry.detect(e164: "+359881234567"))
        for stored in ["", "4155550134", "reader@example.com", "Пламен", "+1", "📞"] {
            XCTAssertNil(PhoneCountry.detect(e164: stored), stored)
        }
        XCTAssertEqual(PhoneNumber(typed: "+14155550134")?.country, .unitedStates)
        XCTAssertEqual(PhoneNumber(typed: "+14155550134")?.localDisplay, "(415) 555-0134")
        XCTAssertEqual(PhoneNumber(typed: "+447911123456")?.localDisplay, "7911123456")
        XCTAssertEqual(PhoneNumber(typed: "+359881234567")?.localDisplay, "+359881234567")
    }

    func testANumberTypedNextToAPickerGetsItsCallingCode() {
        let us = PhoneCountry.unitedStates
        let country: (String) -> PhoneCountry = { PhoneCountry.find(code: $0)! }
        XCTAssertEqual(PhoneNumber(local: "(415) 555-0134", country: us)?.e164, "+14155550134")
        XCTAssertEqual(PhoneNumber(local: " 415.555.0134 ", country: us)?.e164, "+14155550134")
        XCTAssertEqual(PhoneNumber(local: "1 415 555 0134", country: us)?.e164, "+14155550134")
        XCTAssertEqual(PhoneNumber(local: "604 555 0134", country: country("CA"))?.e164, "+16045550134")
        // The 0 people write at home is not part of the international number.
        XCTAssertEqual(PhoneNumber(local: "07911 123456", country: country("GB"))?.e164, "+447911123456")
        XCTAssertEqual(PhoneNumber(local: "7911 123456", country: country("GB"))?.e164, "+447911123456")
        XCTAssertEqual(PhoneNumber(local: "0151 23456789", country: country("DE"))?.e164, "+4915123456789")
        // In Italy it is.
        XCTAssertEqual(PhoneNumber(local: "06 1234 5678", country: country("IT"))?.e164, "+390612345678")
        XCTAssertEqual(PhoneNumber(local: "333 123 4567", country: country("IT"))?.e164, "+393331234567")
        // Digits from another keyboard.
        XCTAssertEqual(PhoneNumber(local: "٧٩١١١٢٣٤٥٦", country: country("GB"))?.e164, "+447911123456")
        // A whole international number wins over the picker.
        XCTAssertEqual(PhoneNumber(local: "+44 7911 123456", country: us)?.e164, "+447911123456")
    }

    func testWhatCannotBeANumberNextToAPickerIsRefused() {
        let us = PhoneCountry.unitedStates
        let gb = PhoneCountry.find(code: "GB")!
        for typed in ["", "   ", "555", "555-0134", "415 555 01345", "115 555 0134", "415 155 0134", "0", "000",
                      "call me 4155550134", "reader@example.com", "Пламен", "山田4155550134", "📞4155550134",
                      "415+5550134", "½4155550134"] {
            XCTAssertNil(PhoneNumber(local: typed, country: us), typed)
        }
        for typed in ["", "0", "12", "079", "07911 123456 7890 1234", "seven nine", "Пламен 07911", "😀"] {
            XCTAssertNil(PhoneNumber(local: typed, country: gb), typed)
        }
    }
}
