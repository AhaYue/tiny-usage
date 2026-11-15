import XCTest
@testable import TinyUsageCore

/// English and Simplified Chinese must stay in step: a key missing from one table shows the raw
/// key (or the other language) to that table's users.
final class LocalizationTests: XCTestCase {
    private func table(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.tinyUsage.url(forResource: "Localizable", withExtension: "strings",
                                                 subdirectory: nil, localization: language))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testEnglishAndChineseHaveTheSameKeys() throws {
        let english = try table("en"), chinese = try table("zh-Hans")
        XCTAssertEqual(Set(english.keys).symmetricDifference(chinese.keys), [])
    }

    func testTranslationsKeepTheirPlaceholders() throws {
        let english = try table("en"), chinese = try table("zh-Hans")
        func placeholders(_ text: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|lld)")
            return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range(at: 2), in: text)!]) }.sorted()
        }
        for (key, value) in english {
            XCTAssertEqual(placeholders(value), placeholders(key), key)
            XCTAssertEqual(placeholders(chinese[key] ?? ""), placeholders(key), key)
        }
    }

    func testOnlyEnglishAndChineseShip() {
        XCTAssertEqual(Set(Bundle.tinyUsage.localizations).subtracting(["Base"]), ["en", "zh-Hans"])
    }
}
