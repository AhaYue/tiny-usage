import Foundation

/// Independent cooldowns for supplementary endpoints, including Desktop and extra logins.
/// Values are dates only; credentials are never persisted here.
actor EndpointBackoff {
    static let shared = EndpointBackoff()
    private let defaults: UserDefaults
    private let storageKey = "tinyusage.endpointBackoff.v1"
    private var until: [String: Date]

    init(suiteName: String? = nil) {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        until = (defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
    }
    func remaining(_ key: String, now: Date = Date()) -> TimeInterval {
        max(0, until[key]?.timeIntervalSince(now) ?? 0)
    }
    func record(_ response: URLResponse, key: String, now: Date = Date()) {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 429: until[key] = now.addingTimeInterval(AdaptiveUsageSchedule.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now) ?? 900)
        case 401, 403: until[key] = now.addingTimeInterval(1800)
        case 200..<300: until[key] = nil
        default: until[key] = now.addingTimeInterval(120)
        }
        until = until.filter { $0.value > now }
        defaults.set(until.mapValues(\.timeIntervalSince1970), forKey: storageKey)
    }
}
