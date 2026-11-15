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
        // Older SwiftPM lowercases .lproj names in the test bundle ("zh-hans"); the app bundle is
        // copied from the sources as is, so only this comparison needs to ignore case.
        XCTAssertEqual(Set(Bundle.tinyUsage.localizations.map { $0.lowercased() }).subtracting(["base"]), ["en", "zh-hans"])
    }

    func testExplicitLanguageUsesItsOwnTableAndPreservesInterpolation() {
        let count = 7
        XCTAssertEqual(AppLanguage.english.text("Follow System"), "Follow System")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Follow System"), "跟随系统")
        XCTAssertEqual(AppLanguage.english.text("\(count) min ago"), "7 min ago")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("\(count) min ago"), "更新于 7 分钟前")
        XCTAssertEqual(AppLanguage.system.text("Language"), String(localized: "Language", bundle: .tinyUsage))
    }

    func testCachedBillingLabelsFollowTheCurrentLanguage() {
        for language in [AppLanguage.english, .simplifiedChinese] {
            let balance = ModelStatus(name: language.text("Credit balance"), remainingPercent: 0,
                                      resetAt: nil, valueText: String(format: language.text("%@ credits"), "12.5"))
            XCTAssertEqual(balance.displayValueRowName, L("Credit balance"))
            XCTAssertEqual(balance.displayValueRowText, String(format: L("%@ credits"), "12.5"))
        }
    }
}
