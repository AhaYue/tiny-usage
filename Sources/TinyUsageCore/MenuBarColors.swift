import AppKit

struct MenuBarColors: Codable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case standard, subtle, custom

        var label: String {
            switch self {
            case .standard: L("Default colors")
            case .subtle: L("Subtle")
            case .custom: L("Custom colors")
            }
        }
    }

    private static let defaultsKey = "tinyusage.menuBarColors"

    var mode: Mode = .standard
    private var plenty = QuotaLevel.plenty.rgb
    private var low = QuotaLevel.low.rgb
    private var critical = QuotaLevel.critical.rgb

    subscript(_ level: QuotaLevel) -> UInt32 {
        get {
            switch level {
            case .plenty: plenty
            case .low: low
            case .critical: critical
            }
        }
        set {
            switch level {
            case .plenty: plenty = newValue
            case .low: low = newValue
            case .critical: critical = newValue
            }
        }
    }

    func color(for level: QuotaLevel) -> NSColor {
        switch mode {
        case .standard: level.color
        case .subtle: level == .plenty ? .labelColor : level.color
        case .custom: NSColor(hex: self[level])
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let colors = try? PropertyListDecoder().decode(Self.self, from: data) else { return Self() }
        return colors
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? PropertyListEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
