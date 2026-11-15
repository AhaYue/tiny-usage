import Foundation

/// How eagerly Tiny Usage reads local files and asks the network. One setting for both, because
/// "I don't need it fast" means both. Redrawing the menu bar (countdown, time cursor) is not part
/// of it — that's an in-memory draw, no I/O — so it keeps its one-minute tick in every mode.
enum RefreshMode: Int, CaseIterable {
    case auto, every5, every15, every30, manual

    static let defaultsKey = "tinyusage.refreshMode"

    static var current: RefreshMode {
        RefreshMode(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .auto
    }

    var label: String {
        switch self {
        case .auto: L("Auto")
        case .every5: L("Every 5 min")
        case .every15: L("Every 15 min")
        case .every30: L("Every 30 min")
        case .manual: L("Manual only")
        }
    }

    /// The settings row's subtitle: what the chosen mode actually does.
    var detail: String {
        switch self {
        case .auto: L("Adaptive, 2–30 min")
        case .every5, .every15, .every30: L("Local and network alike")
        case .manual: L("Manual refresh only")
        }
    }

    var next: RefreshMode { RefreshMode(rawValue: (rawValue + 1) % Self.allCases.count) ?? .auto }

    /// How often the background tick may read local sources (hook file, Codex logs, snapshots).
    /// `nil` = never on its own; only an explicit refresh reads.
    var localInterval: TimeInterval? {
        switch self {
        case .auto: 60
        case .every5: 300
        case .every15: 900
        case .every30: 1800
        case .manual: nil
        }
    }

    /// The shortest gap between network requests for one service. Auto keeps the adaptive
    /// two-minute floor; the fixed modes never go faster than their interval.
    var networkFloor: TimeInterval { max(120, localInterval ?? 120) }

    /// Auto also asks right after a window resets, so the refill shows at once. The slower modes
    /// skip that extra request — the user asked for fewer.
    var refreshesAtReset: Bool { self == .auto }

    /// Whether a background tick at `now` should read, given when it last did.
    func tickShouldRefresh(lastRefresh: Date?, now: Date) -> Bool {
        guard let interval = localInterval else { return false }
        guard let lastRefresh else { return true }
        // A few seconds of slack so a 60s timer with tolerance doesn't miss its slot by a hair.
        return now.timeIntervalSince(lastRefresh) >= interval - 5
    }
}
