import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let defaultsKey = "tinyusage.language"

    static var current: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var label: String {
        switch self {
        case .system: L("Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    private static let bundles: [Self: Bundle] = {
        let resources = Bundle.tinyUsage
        return Dictionary(uniqueKeysWithValues: allCases.filter { $0 != .system }.compactMap { language in
            guard let table = resources.url(forResource: "Localizable", withExtension: "strings",
                                            subdirectory: nil, localization: language.rawValue),
                  let bundle = Bundle(url: table.deletingLastPathComponent()) else { return nil }
            return (language, bundle)
        })
    }()

    private var bundle: Bundle { Self.bundles[self] ?? .tinyUsage }

    func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }

    func text(forKey key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func matches(_ text: String, key: String) -> Bool {
        text == key || english.text(forKey: key) == text || simplifiedChinese.text(forKey: key) == text
    }
}
