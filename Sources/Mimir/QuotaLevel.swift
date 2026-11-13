import AppKit

/// How much of a window is left, read like a phone battery: green while there's plenty, amber once
/// it's worth watching, red when it's nearly gone. One set of bands for the menu bar and the panel,
/// and it depends on the remaining percentage only — never on pace — so the same number is always
/// the same colour.
enum QuotaLevel: Equatable {
    case plenty, low, critical

    init(remaining percent: Int) {
        switch max(0, min(100, percent)) {
        case 50...100: self = .plenty
        case 20..<50: self = .low
        default: self = .critical
        }
    }

    /// Dynamic colour, darker in light mode so it stays legible on a light menu bar or panel.
    var color: NSColor {
        let (dark, light): (UInt32, UInt32) = switch self {
        case .plenty: (0x3FB984, 0x1FA45E)
        case .low: (0xE0A93C, 0xB07D0A)
        case .critical: (0xE5564E, 0xC9403A)
        }
        return NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
}
