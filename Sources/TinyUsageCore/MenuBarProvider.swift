import Foundation

enum MenuBarProvider: String, CaseIterable {
    case claude, codex, antigravity
    case openCodeGo = "opencode"

    private static let defaultsKey = "tinyusage.menuBarProviders"
    static let all = Set(allCases)

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: AntigravityConfiguration.name
        case .openCodeGo: OpenCodeGoConfiguration.name
        }
    }

    static func selection(in defaults: UserDefaults = .standard) -> Set<Self> {
        guard let saved = defaults.stringArray(forKey: defaultsKey) else { return all }
        return Set(saved.compactMap(Self.init(rawValue:)))
    }

    static func save(_ selection: Set<Self>, in defaults: UserDefaults = .standard) {
        defaults.set(allCases.filter(selection.contains).map(\.rawValue), forKey: defaultsKey)
    }

    static func selectedServices(from services: [ServiceStatus], selection: Set<Self>) -> [ServiceStatus] {
        // Each account of a provider uses the same icon, including Claude Desktop.
        services.filter { service in
            Self(rawValue: service.iconName).map(selection.contains) ?? false
        }
    }
}
