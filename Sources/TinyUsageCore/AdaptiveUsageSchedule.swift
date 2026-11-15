import Foundation

struct AdaptiveUsageSchedule {
    private struct Entry: Codable {
        var next: Date
        var cooldown: Date?
        var interval: TimeInterval
        var fingerprint: String?
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults
    private let key = "tinyusage.usageSchedule.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func skipped(now: Date, manual: Bool) -> Set<String> {
        Set(entries.compactMap { name, entry in
            if let cooldown = entry.cooldown, cooldown > now { return name }
            return !manual && entry.next > now ? name : nil
        })
    }

    mutating func record(_ status: ServiceStatus, now: Date, mode: RefreshMode = .auto) {
        let previous = entries[status.name]
        let fingerprint = [String(describing: status.sessionRemainingPercent), String(describing: status.weeklyRemainingPercent),
                           String(describing: status.sessionResetAt), String(describing: status.weeklyResetAt)]
            .joined(separator: "|") + status.models.map { "\($0.name):\($0.remainingPercent):\($0.valueText ?? ""):\($0.resetAt?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
        let changed = previous?.fingerprint != fingerprint
        // Changed data snaps back to the floor; steady data doubles towards the ceiling. The floor
        // is the user's refresh setting, so a slow mode is never undercut by "data just changed".
        let floor = mode.networkFloor
        let interval = status.isAvailable && !status.isStale && changed ? floor
            : min(max(1800, floor), max(floor, (previous?.interval ?? floor) * 2))
        var cooldown = previous?.cooldown.flatMap { $0 > now ? $0 : nil }
        if let hint = status.cooldownHint { cooldown = hint > 0 ? now.addingTimeInterval(hint) : nil }
        var next = now.addingTimeInterval(interval)
        for reset in [status.sessionResetAt, status.weeklyResetAt].compactMap({ $0 }) where mode.refreshesAtReset && reset > now {
            next = min(next, reset.addingTimeInterval(2))
        }
        entries[status.name] = Entry(next: next, cooldown: cooldown, interval: interval, fingerprint: fingerprint)
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
