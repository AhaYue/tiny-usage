import CryptoKit
import Foundation
import Security

enum OpenCodeGoConfiguration {
    enum Mode: String {
        case disabled
        case reuse
        case personalKey
    }

    enum ConfigurationError: LocalizedError {
        case missingKey, saveFailed, removeFailed

        var errorDescription: String? {
            switch self {
            case .missingKey: L("Enter an OpenCode Go key")
            case .saveFailed: L("Couldn't save the OpenCode Go key")
            case .removeFailed: L("Couldn't remove the OpenCode Go key")
            }
        }
    }

    static let name = "OpenCode Go"
    static let iconName = "opencode"
    private static let modeKey = "tinyusage.openCodeGo.credentialMode"
    private static let keychainService = "TinyUsage-opencode-go"
    private static let lock = NSLock()
    // Read and updated only while holding lock. A request that spans a disconnect/reconnect
    // must be discarded even if the user reconnects with the same key.
    nonisolated(unsafe) private static var revision = 0

    fileprivate struct Credential {
        let key: String?
        let sourceID: String
        let revision: Int
    }

    static var mode: Mode { lock.withLock { configuredMode } }

    static func setMode(_ mode: Mode, personalKey: String? = nil) throws {
        try lock.withLock {
            guard credentialsAllowed else { throw ConfigurationError.saveFailed }
            if mode == .personalKey {
                guard let key = validKey(personalKey) else { throw ConfigurationError.missingKey }
                let data = Data(key.utf8)
                let query = keychainQuery
                let status = KeychainAccess.perform(interactive: true) {
                    let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                    guard updated == errSecItemNotFound else { return updated }
                    var item = query
                    item[kSecValueData as String] = data
                    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    return SecItemAdd(item as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw ConfigurationError.saveFailed }
            } else if configuredMode == .personalKey {
                let removed = KeychainAccess.perform(interactive: true) {
                    SecItemDelete(keychainQuery as CFDictionary)
                }
                guard removed == errSecSuccess || removed == errSecItemNotFound else {
                    throw ConfigurationError.removeFailed
                }
            }

            try? FileManager.default.removeItem(at: LiveUsageDataSource().snapshotURL(for: name))
            UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
            revision += 1
        }
    }

    static func currentSourceID() -> String? {
        withCredential { $0?.sourceID }
    }

    fileprivate static func withCredential<T>(_ body: (Credential?) -> T) -> T {
        lock.withLock {
            let mode = configuredMode
            let key: String?
            switch mode {
            case .disabled: return body(nil)
            case .reuse: key = try? reusableKey(at: authFile)
            case .personalKey: key = readPersonalKey()
            }
            return body(Credential(key: key, sourceID: sourceID(mode: mode, key: key), revision: revision))
        }
    }

    // Re-read the selected entry on refresh to follow key rotation in OpenCode.
    static func reusableKey(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let credentials = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let entry = credentials?["opencode-go"] as? [String: Any], entry["type"] as? String == "api" else {
            return nil
        }
        return validKey(entry["key"] as? String)
    }

    static func sourceID(mode: Mode, key: String?) -> String {
        let digest = key.map { key in
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? "missing"
        return "opencode-go:\(mode.rawValue):\(digest)"
    }

    private static var authFile: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("opencode/auth.json")
        }
        return LiveUsageDataSource.userHome.appendingPathComponent(".local/share/opencode/auth.json")
    }

    private static func validKey(_ value: String?) -> String? {
        guard let key = value?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return key
    }

    private static var configuredMode: Mode {
        guard credentialsAllowed else { return .disabled }
        return UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .disabled
    }

    private static var credentialsAllowed: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TINY_USAGE_TEST_HOME"] == nil && KeychainAccess.newUserSessionID == nil
            && env["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
            && !CommandLine.arguments.contains(where: ["--demo", "--render-preview", "--smoke-test"].contains)
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: NSUserName()]
    }

    private static func readPersonalKey() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = KeychainAccess.perform { SecItemCopyMatching(query as CFDictionary, &item) }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return validKey(String(data: data, encoding: .utf8))
    }
}

enum OpenCodeGoUsage {
    struct Reading: Equatable {
        struct Window: Equatable {
            let remaining: Int
            let resetAt: Date?
        }

        let rolling: Window?
        let weekly: Window?
        let monthly: Window?
    }

    enum Result: Equatable {
        case reading(Reading)
        case failed(note: String, cooldown: TimeInterval? = nil)
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let liveNote = "OpenCode Go usage"
    static let missingKeyNote = "Couldn't find an OpenCode Go key"
    static let rejectedKeyNote = "OpenCode Go rejected the key"
    static let permissionNote = "This key cannot read OpenCode Go usage"
    static let unavailableNote = "OpenCode Go usage is temporarily unavailable"

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static func fetch(key: String, transport: Transport = { request in
        try await URLSession.shared.data(for: request, delegate: NoRedirect())
    }) async -> Result {
        var request = URLRequest(url: URL(string: "https://opencode.ai/inference/go/v1/usage")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = sessionID()
        request.setValue(session, forHTTPHeaderField: "x-opencode-session")
        request.setValue(session, forHTTPHeaderField: "x-opencode-session-id")

        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { return .failed(note: unavailableNote) }
            switch http.statusCode {
            case 200...299:
                guard let reading = parse(data) else { return .failed(note: unavailableNote) }
                return .reading(reading)
            case 401: return .failed(note: rejectedKeyNote)
            case 403: return .failed(note: permissionNote)
            case 429:
                let retry = AdaptiveUsageSchedule.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                return .failed(note: unavailableNote, cooldown: retry ?? 15 * 60)
            default: return .failed(note: unavailableNote)
            }
        } catch {
            return .failed(note: unavailableNote)
        }
    }

    static func parse(_ data: Data) -> Reading? {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let usage = root?["usage"] as? [String: Any] else { return nil }
        let windows = Reading(rolling: window(usage["rolling"]), weekly: window(usage["weekly"]),
                              monthly: window(usage["monthly"]))
        return windows.rolling == nil && windows.weekly == nil && windows.monthly == nil ? nil : windows
    }

    private static func window(_ value: Any?) -> Reading.Window? {
        guard let window = value as? [String: Any], let percent = window["percent"] as? NSNumber,
              CFGetTypeID(percent) != CFBooleanGetTypeID() else { return nil }
        let used = percent.doubleValue
        guard used.isFinite, (0...100).contains(used) else { return nil }
        let remaining = used == 100 ? 0 : max(1, Int((100 - used).rounded()))
        // An unused window's reset is a placeholder. A countdown begins with the first use.
        let reset = used > 0 ? (window["resetsAt"] as? String).flatMap(LiveUsageDataSource().parseISO8601) : nil
        return Reading.Window(remaining: remaining, resetAt: reset)
    }

    private static func sessionID() -> String {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)
        let ascending = (timestamp << 12) | 1
        let descending = String(format: "%012llx", ~ascending & 0xffffffffffff)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let suffix = String((0..<14).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        return "ses_\(descending)\(suffix)"
    }
}

extension LiveUsageDataSource {
    func openCodeGoCachedStatus() -> ServiceStatus? {
        OpenCodeGoConfiguration.withCredential { credential in
            guard let credential else { return nil }
            return openCodeGoFallback(credential)
        }
    }

    func fetchOpenCodeGo() async -> ServiceStatus? {
        guard let credential = OpenCodeGoConfiguration.withCredential({ $0 }) else { return nil }
        guard let key = credential.key else { return openCodeGoCachedStatus() }
        let result = await OpenCodeGoUsage.fetch(key: key)
        return OpenCodeGoConfiguration.withCredential { current in
            guard !Task.isCancelled, let current, current.revision == credential.revision,
                  current.sourceID == credential.sourceID else { return nil }
            switch result {
            case let .reading(reading):
                let status = ServiceStatus(
                    name: OpenCodeGoConfiguration.name, iconName: OpenCodeGoConfiguration.iconName,
                    sessionResetAt: reading.rolling?.resetAt, weeklyResetAt: reading.weekly?.resetAt,
                    sessionRemainingPercent: reading.rolling?.remaining, weeklyRemainingPercent: reading.weekly?.remaining,
                    weeklyWindowSeconds: 7 * 86_400,
                    monthlyResetAt: reading.monthly?.resetAt, monthlyRemainingPercent: reading.monthly?.remaining,
                    models: [], isAvailable: true, statusNote: OpenCodeGoUsage.liveNote, cooldownHint: 0, observedAt: Date()
                ).withSourceID(credential.sourceID)
                saveSnapshot(status)
                return status
            case let .failed(note, cooldown):
                return openCodeGoFallback(credential, note: note).withCooldownHint(cooldown)
            }
        }
    }

    private func openCodeGoFallback(_ credential: OpenCodeGoConfiguration.Credential,
                                    note: String = OpenCodeGoUsage.unavailableNote) -> ServiceStatus {
        let name = OpenCodeGoConfiguration.name
        let icon = OpenCodeGoConfiguration.iconName
        let note = credential.key == nil ? OpenCodeGoUsage.missingKeyNote : note
        if credential.key != nil, let cached = loadOpenCodeGoSnapshot(sourceID: credential.sourceID, note: note) {
            return cached
        }
        return unavailableService(name: name, iconName: icon, models: [], note: note)
            .withSourceID(credential.sourceID)
    }

    func loadOpenCodeGoSnapshot(sourceID: String, note: String) -> ServiceStatus? {
        let cached = loadSnapshot(for: OpenCodeGoConfiguration.name, iconName: OpenCodeGoConfiguration.iconName,
                                  freshNote: note, staleNote: note)
        return cached?.sourceID == sourceID ? cached : nil
    }
}
