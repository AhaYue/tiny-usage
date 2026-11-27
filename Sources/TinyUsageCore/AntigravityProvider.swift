import Darwin
import Foundation

enum AntigravityConfiguration {
    static let name = "Antigravity"
    static let iconName = "antigravity"
    static let extraLimitGroup = "antigravity.additional-limit"
    static let enabledDefaultsKey = "tinyusage.antigravity.enabled"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var revision = 0

    static var currentRevision: Int { lock.withLock { revision } }

    static var isEnabled: Bool {
        lock.withLock {
            guard probesAllowed else { return false }
            return resolveEnabled(defaults: .standard, detectInstalled: isInstalled)
        }
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        lock.withLock {
            defaults.set(enabled, forKey: enabledDefaultsKey)
            if !enabled {
                try? FileManager.default.removeItem(at: LiveUsageDataSource().snapshotURL(for: name))
            }
            revision += 1
        }
    }

    /// First launch detects whether Antigravity.app or `agy` is installed and persists the choice.
    /// Once persisted, manual changes in Settings always win.
    static func resolveEnabled(defaults: UserDefaults, detectInstalled: () -> Bool) -> Bool {
        if defaults.object(forKey: enabledDefaultsKey) != nil {
            return defaults.bool(forKey: enabledDefaultsKey)
        }
        let detected = detectInstalled()
        defaults.set(detected, forKey: enabledDefaultsKey)
        return detected
    }

    static var appPaths: [String] {
        [
            "/Applications/Antigravity.app",
            LiveUsageDataSource.userHome.appendingPathComponent("Applications/Antigravity.app").path,
        ]
    }

    static var isAppInstalled: Bool {
        appPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func isInstalled() -> Bool {
        isAppInstalled || AntigravityCLIUsage.locateExecutable() != nil
    }

    static var probesAllowed: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TINY_USAGE_TEST_HOME"] == nil && KeychainAccess.newUserSessionID == nil
            && env["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
            && !CommandLine.arguments.contains(where: ["--demo", "--render-preview", "--smoke-test"].contains)
    }
}

enum AntigravityUsage {
    struct Window: Equatable, Sendable {
        let remaining: Int
        let resetAt: Date?
    }

    struct Group: Equatable, Sendable {
        let name: String
        let session: Window?
        let weekly: Window?

        var isEmpty: Bool { session == nil && weekly == nil }
    }

    struct Reading: Equatable, Sendable {
        let primary: Group
        let extras: [Group]
        let account: AccountInfo?
        let sourceNote: String
        let observedAt: Date

        var allResetDates: [Date] {
            ([primary] + extras).flatMap { [$0.session?.resetAt, $0.weekly?.resetAt].compactMap { $0 } }
        }

        func isFresh(at date: Date, maxAge: TimeInterval = 300) -> Bool {
            let age = date.timeIntervalSince(observedAt)
            return (0 ..< maxAge).contains(age) && allResetDates.allSatisfy { date < $0 }
        }

        func withAccount(_ account: AccountInfo?) -> Reading {
            guard let account else { return self }
            return Reading(primary: primary, extras: extras, account: account, sourceNote: sourceNote, observedAt: observedAt)
        }
    }

    static let localSourceNote = "Antigravity app"
    static let cliSourceNote = "Antigravity CLI"
    static let notInstalledNote = "Install Antigravity or agy CLI to read quota."
    static let signInHintNote = "Open Antigravity or sign in with agy in Terminal."

    // MARK: - Shared group & bucket normalization

    fileprivate struct RawBucket {
        let id: String?
        let window: String?
        let remainingFraction: Double?
        let resetTime: String?
        let disabled: Bool
    }

    fileprivate struct RawGroup {
        let name: String?
        let buckets: [RawBucket]
    }

    fileprivate static func buildReading(
        rawGroups: [RawGroup],
        defaultMissingFractionToZero: Bool,
        sourceNote: String,
        account: AccountInfo? = nil,
        now: Date
    ) -> Reading? {
        var parsed: [(rawName: String, group: Group)] = []
        let source = LiveUsageDataSource()

        for raw in rawGroups {
            let rawName = (raw.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var session: Window?
            var weekly: Window?

            for bucket in raw.buckets {
                guard !bucket.disabled else { continue }
                guard let kind = classifyWindow(bucket.window ?? bucket.id) else { continue }
                let resetAt = bucket.resetTime.flatMap(source.parseISO8601)
                let fraction: Double
                if let value = bucket.remainingFraction, value.isFinite {
                    fraction = value
                } else if defaultMissingFractionToZero || resetAt != nil {
                    // Proto3 JSON omits zero-valued numeric fields, so an enabled bucket without
                    // remainingFraction represents 0% remaining (exhausted).
                    fraction = 0
                } else {
                    continue
                }
                let remaining = remainingPercent(fromFraction: fraction)
                let window = Window(remaining: remaining, resetAt: resetAt)
                switch kind {
                case .session:
                    if let current = session {
                        if window.remaining < current.remaining { session = window }
                    } else {
                        session = window
                    }
                case .weekly:
                    if let current = weekly {
                        if window.remaining < current.remaining { weekly = window }
                    } else {
                        weekly = window
                    }
                }
            }

            let group = Group(name: displayGroupName(rawName), session: session, weekly: weekly)
            if !group.isEmpty {
                parsed.append((rawName: rawName, group: group))
            }
        }

        guard !parsed.isEmpty else { return nil }

        // Prefer the main "Gemini Models" / "Gemini" pool as primary (drives the menu bar),
        // falling back to any Gemini group, then the first reported group.
        let primaryIndex = parsed.firstIndex { item in
            let lower = item.rawName.lowercased()
            return lower == "gemini models" || lower == "gemini"
        } ?? parsed.firstIndex { item in
            item.rawName.lowercased().contains("gemini")
        } ?? 0

        let primary = parsed[primaryIndex].group
        let extras = parsed.enumerated().compactMap { index, item in
            index == primaryIndex ? nil : item.group
        }

        return Reading(primary: primary, extras: extras, account: account, sourceNote: sourceNote, observedAt: now)
    }

    static func remainingPercent(fromFraction fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        if fraction <= 0 { return 0 }
        if fraction >= 1 { return 100 }
        return max(1, Int((fraction * 100).rounded()))
    }

    static func displayGroupName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AntigravityConfiguration.name }
        let stripped = trimmed.replacingOccurrences(of: #"\s+models$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let lower = stripped.lowercased()
        if lower == "claude and gpt" || lower == "claude & gpt" || lower == "claude + gpt" {
            return "Claude + GPT"
        }
        return stripped.isEmpty ? AntigravityConfiguration.name : stripped
    }

    private enum WindowKind { case session, weekly }

    private static func classifyWindow(_ raw: String?) -> WindowKind? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return nil
        }
        if value == "weekly" || value.hasSuffix("weekly") || value.hasSuffix("week") || value == "7d" {
            return .weekly
        }
        if value == "5h" || value.hasSuffix("-5h") || value.hasSuffix("_5h") || value == "session" {
            return .session
        }
        return nil
    }
}

// MARK: - Local language_server RPC (Antigravity.app running)

enum AntigravityLocalRPC {
    struct Server: Equatable, Sendable {
        let pid: Int32
        let csrfToken: String
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let servicePath = "exa.language_server_pb.LanguageServerService"
    private static let metadataBody = Data(
        #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8
    )

    /// Loopback-only session: bypasses system proxies and trusts the local language server's
    /// self-signed certificate strictly for 127.0.0.1.
    private final class LoopbackSession: NSObject, URLSessionDelegate, @unchecked Sendable {
        static let shared = LoopbackSession()

        lazy var session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 3
            config.timeoutIntervalForResource = 4
            config.urlCache = nil
            config.httpCookieStorage = nil
            return URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }()

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  space.host == "127.0.0.1",
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    static func fetch(now: Date = Date(), transport: Transport? = nil) async -> AntigravityUsage.Reading? {
        guard !Task.isCancelled else { return nil }
        guard let psData = await AntigravitySubprocess.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            environment: [:],
            timeout: .seconds(3)
        ) else { return nil }

        let servers = parseServers(fromProcessList: String(decoding: psData, as: UTF8.self))
        guard !servers.isEmpty else { return nil }

        let send: Transport = transport ?? { request in
            try await LoopbackSession.shared.session.data(for: request)
        }

        for server in servers {
            guard !Task.isCancelled else { return nil }
            guard let lsofData = await AntigravitySubprocess.run(
                executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(server.pid)],
                environment: [:],
                timeout: .seconds(3)
            ) else { continue }

            let ports = parseLoopbackPorts(fromLsof: String(decoding: lsofData, as: UTF8.self))
            for port in ports {
                for scheme in ["https", "http"] {
                    guard !Task.isCancelled else { return nil }
                    guard let summaryData = await call(
                        method: "RetrieveUserQuotaSummary",
                        scheme: scheme,
                        port: port,
                        csrfToken: server.csrfToken,
                        transport: send
                    ), let reading = parseSummary(summaryData, now: now) else { continue }

                    let account = await call(
                        method: "GetUserStatus",
                        scheme: scheme,
                        port: port,
                        csrfToken: server.csrfToken,
                        transport: send
                    ).flatMap(parseUserStatus)
                    return reading.withAccount(account)
                }
            }
        }
        return nil
    }

    static func call(
        method: String,
        scheme: String,
        port: Int,
        csrfToken: String,
        transport: Transport
    ) async -> Data? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(servicePath)/\(method)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = metadataBody

        guard let (data, response) = try? await transport(request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func parseServers(fromProcessList text: String) -> [Server] {
        let source = LiveUsageDataSource()
        return text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("/Antigravity.app/"), line.contains("/language_server"),
                  let space = line.firstIndex(of: " "),
                  let pid = Int32(line[..<space]),
                  let token = source.extractFlag("--csrf_token", from: line),
                  !token.isEmpty else { return nil }
            return Server(pid: pid, csrfToken: token)
        }
    }

    static func parseLoopbackPorts(fromLsof text: String) -> [Int] {
        var ports: Set<Int> = []
        for line in text.split(separator: "\n") {
            guard line.contains("(LISTEN)"),
                  line.contains("127.0.0.1:") || line.contains("[::1]:") || line.contains("localhost:"),
                  let match = line.range(of: #":(\d+)\s+\(LISTEN\)"#, options: .regularExpression) else { continue }
            let digits = line[match].dropFirst().prefix { $0.isNumber }
            if let port = Int(digits), (1 ... 65_535).contains(port) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    static func parseSummary(_ data: Data, now: Date = Date()) -> AntigravityUsage.Reading? {
        struct Payload: Decodable {
            struct Wrapper: Decodable { let groups: [GroupDTO]? }
            struct GroupDTO: Decodable {
                let displayName: String?
                let name: String?
                let buckets: [BucketDTO]?
            }
            struct BucketDTO: Decodable {
                let bucketId: String?
                let id: String?
                let window: String?
                let remainingFraction: Double?
                let resetTime: String?
                let disabled: Bool?
            }
            let response: Wrapper?
            let groups: [GroupDTO]?
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let groups = payload.response?.groups ?? payload.groups ?? []
        let rawGroups = groups.map { group in
            AntigravityUsage.RawGroup(
                name: group.displayName ?? group.name,
                buckets: (group.buckets ?? []).map { bucket in
                    AntigravityUsage.RawBucket(
                        id: bucket.bucketId ?? bucket.id,
                        window: bucket.window,
                        remainingFraction: bucket.remainingFraction,
                        resetTime: bucket.resetTime,
                        disabled: bucket.disabled == true
                    )
                }
            )
        }
        return AntigravityUsage.buildReading(
            rawGroups: rawGroups,
            defaultMissingFractionToZero: true,
            sourceNote: AntigravityUsage.localSourceNote,
            now: now
        )
    }

    static func parseUserStatus(_ data: Data) -> AccountInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any] else { return nil }
        let rawPlan = ((status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        let rawEmail = status["email"] as? String
        let plan = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPlan = plan?.isEmpty == false ? plan : nil
        let cleanEmail = email?.isEmpty == false ? email : nil
        guard cleanPlan != nil || cleanEmail != nil else { return nil }
        return AccountInfo(plan: cleanPlan, email: cleanEmail, id: cleanEmail)
    }
}

// MARK: - agy CLI (`agy -p /usage --output-format json`)

actor AntigravityCLIUsage {
    struct Version: Comparable, Equatable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    private struct BinaryIdentity: Equatable {
        let path: String
        let size: UInt64
        let modifiedAt: Date?
    }

    static let shared = AntigravityCLIUsage()
    static let minimumPrintUsageVersion = Version(major: 1, minor: 1, patch: 11)

    private var cachedReading: AntigravityUsage.Reading?
    private var lastAttemptedAt: Date?
    private var cachedVersion: (identity: BinaryIdentity, version: Version)?

    private let locateBinary: @Sendable () -> String?
    private let runVersion: @Sendable (String, URL) async -> Data?
    private let runUsage: @Sendable (String, URL) async -> Data?

    init(
        locateBinary: @escaping @Sendable () -> String? = { AntigravityCLIUsage.locateExecutable() },
        runVersion: @escaping @Sendable (String, URL) async -> Data? = AntigravityCLIUsage.readVersion,
        runUsage: @escaping @Sendable (String, URL) async -> Data? = AntigravityCLIUsage.readUsageReport
    ) {
        self.locateBinary = locateBinary
        self.runVersion = runVersion
        self.runUsage = runUsage
    }

    func read(home: URL = LiveUsageDataSource.userHome, now: Date = Date(), force: Bool = false) async -> AntigravityUsage.Reading? {
        guard !Task.isCancelled else { return nil }
        if !force {
            if let cachedReading, cachedReading.isFresh(at: now) { return cachedReading }
            if let lastAttemptedAt, now.timeIntervalSince(lastAttemptedAt) < 30 { return nil }
        }

        lastAttemptedAt = now
        guard let binary = locateBinary() else { return nil }
        guard await supportsPrintUsage(binary: binary, home: home), !Task.isCancelled else { return nil }
        guard let bytes = await runUsage(binary, home), !Task.isCancelled,
              let reading = Self.parseCLIReport(bytes, now: Date()) else { return nil }
        cachedReading = reading
        return reading
    }

    func invalidateCache() {
        cachedReading = nil
        lastAttemptedAt = nil
    }

    private func supportsPrintUsage(binary: String, home: URL) async -> Bool {
        let identity = Self.binaryIdentity(at: binary)
        if let identity, let cachedVersion, cachedVersion.identity == identity {
            return cachedVersion.version >= Self.minimumPrintUsageVersion
        }
        guard let bytes = await runVersion(binary, home),
              let version = Self.parseVersion(String(decoding: bytes, as: UTF8.self)) else { return false }
        if let identity {
            cachedVersion = (identity, version)
        }
        return version >= Self.minimumPrintUsageVersion
    }

    private static func binaryIdentity(at path: String) -> BinaryIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attrs[.modificationDate] as? Date
        return BinaryIdentity(path: path, size: size, modifiedAt: modified)
    }

    static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = LiveUsageDataSource.userHome
    ) -> String? {
        let manager = FileManager.default
        if let override = environment["ANTIGRAVITY_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return manager.isExecutableFile(atPath: override) ? override : nil
        }

        let standardPaths = [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let envPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for dir in (envPaths + standardPaths) where dir.hasPrefix("/") && seen.insert(dir).inserted {
            let candidate = dir + "/agy"
            if manager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func parseVersion(_ output: String) -> Version? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|\D)(\d+)\.(\d+)\.(\d+)(?:\D|$)"#),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let majorRange = Range(match.range(at: 1), in: trimmed),
              let minorRange = Range(match.range(at: 2), in: trimmed),
              let patchRange = Range(match.range(at: 3), in: trimmed),
              let major = Int(trimmed[majorRange]),
              let minor = Int(trimmed[minorRange]),
              let patch = Int(trimmed[patchRange]) else {
            return nil
        }
        return Version(major: major, minor: minor, patch: patch)
    }

    static func parseCLIReport(_ data: Data, now: Date = Date()) -> AntigravityUsage.Reading? {
        struct Report: Decodable {
            struct Command: Decodable {
                struct Payload: Decodable {
                    struct GroupDTO: Decodable {
                        let name: String?
                        let buckets: [BucketDTO]?
                    }
                    struct BucketDTO: Decodable {
                        let id: String?
                        let window: String?
                        let remainingFraction: Double?
                        let resetTime: String?
                        let disabled: Bool?
                    }
                    let groups: [GroupDTO]?
                }
                let name: String?
                let data: Payload?
            }
            let status: String?
            let command: Command?
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let report = try? decoder.decode(Report.self, from: data),
              report.status == "SUCCESS",
              report.command?.name == "usage",
              let groups = report.command?.data?.groups else { return nil }

        let rawGroups = groups.map { group in
            AntigravityUsage.RawGroup(
                name: group.name,
                buckets: (group.buckets ?? []).map { bucket in
                    AntigravityUsage.RawBucket(
                        id: bucket.id,
                        window: bucket.window,
                        remainingFraction: bucket.remainingFraction,
                        resetTime: bucket.resetTime,
                        disabled: bucket.disabled == true
                    )
                }
            )
        }
        return AntigravityUsage.buildReading(
            rawGroups: rawGroups,
            defaultMissingFractionToZero: false,
            sourceNote: AntigravityUsage.cliSourceNote,
            now: now
        )
    }

    static func readVersion(executable: String, home: URL) async -> Data? {
        let env = baseEnvironment(home: home)
        return await AntigravitySubprocess.run(
            executable: executable,
            arguments: ["--version"],
            environment: env,
            timeout: .seconds(3)
        )
    }

    static func readUsageReport(executable: String, home: URL) async -> Data? {
        let env = baseEnvironment(home: home)
        // Run inside an empty private directory with failing `open`/`xdg-open` stubs prepended to
        // PATH and wired to BROWSER so an unauthenticated `agy` cannot pop a browser login window,
        // load workspace MCP configs, or trigger CLI auto-updates.
        return await AntigravitySubprocess.run(
            executable: executable,
            arguments: ["-p", "/usage", "--output-format", "json"],
            environment: env,
            timeout: .seconds(25),
            blockBrowserLaunchers: true
        )
    }

    private static func baseEnvironment(home: URL) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var env = current
        let standardPaths = [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existing = (current["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let mergedPath = (existing + standardPaths).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        env["HOME"] = home.path
        env["PATH"] = mergedPath.joined(separator: ":")
        // Lowercase "true" is required; agy ignores "1".
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        return env
    }
}

// MARK: - Isolated subprocess runner (process-group cleanup + browser launcher guard)

enum AntigravitySubprocess {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        blockBrowserLaunchers: Bool = false
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("tiny-usage-agy-\(UUID().uuidString)")
        guard (try? manager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? manager.removeItem(at: temporary) }

        var childEnvironment = environment
        if blockBrowserLaunchers {
            let stub = Data("#!/bin/sh\nexit 1\n".utf8)
            for command in ["open", "xdg-open"] {
                let stubPath = temporary.appendingPathComponent(command).path
                guard manager.createFile(atPath: stubPath, contents: stub,
                                         attributes: [.posixPermissions: 0o700]) else { return nil }
            }
            let existingPath = childEnvironment["PATH"] ?? "/usr/bin:/bin"
            childEnvironment["PATH"] = temporary.path + ":" + existingPath
            childEnvironment["BROWSER"] = temporary.appendingPathComponent("open").path
        }

        let output = temporary.appendingPathComponent("stdout")
        guard let pid = spawn(executable: executable, arguments: arguments, environment: childEnvironment,
                              directory: temporary, output: output) else { return nil }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var status: Int32 = 0
        while true {
            let waited = Darwin.waitpid(pid, &status, WNOHANG)
            if waited == pid {
                guard status == 0, !Task.isCancelled, let file = try? FileHandle(forReadingFrom: output) else {
                    return nil
                }
                defer { try? file.close() }
                let limit = 1_048_576
                guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
                return bytes
            }
            if waited == -1 && errno != EINTR { return nil }
            if Task.isCancelled || clock.now >= deadline {
                Darwin.kill(-pid, SIGKILL)
                while Darwin.waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                return nil
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        output: URL
    ) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_CREAT | O_WRONLY | O_EXCL, 0o600) == 0
        else { return nil }

        let argv = ([executable] + arguments).map { strdup($0) }
        let env = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + env).forEach { free($0) } }
        guard (argv + env).allSatisfy({ $0 != nil }) else { return nil }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], env + [nil])
        return result == 0 ? pid : nil
    }
}

// MARK: - LiveUsageDataSource integration

extension LiveUsageDataSource {
    func antigravityCachedStatus() -> ServiceStatus? {
        guard AntigravityConfiguration.isEnabled else { return nil }
        return antigravityFallback()
    }

    func fetchAntigravity(force: Bool = false) async -> ServiceStatus? {
        guard AntigravityConfiguration.isEnabled else { return nil }
        let revision = AntigravityConfiguration.currentRevision

        // Prefer the running Antigravity.app local language server (millisecond response, plus
        // plan/email); fall back to `agy -p /usage --output-format json` when the app is closed.
        let reading: AntigravityUsage.Reading?
        if let local = await AntigravityLocalRPC.fetch() {
            reading = local
        } else {
            reading = await AntigravityCLIUsage.shared.read(home: Self.userHome, force: force)
        }

        guard !Task.isCancelled, AntigravityConfiguration.isEnabled,
              AntigravityConfiguration.currentRevision == revision else { return nil }

        if let reading {
            let status = antigravityServiceStatus(from: reading)
            saveSnapshot(status)
            return status
        }
        return antigravityFallback()
    }

    func antigravityServiceStatus(from reading: AntigravityUsage.Reading) -> ServiceStatus {
        let extraModels = reading.extras.flatMap { group -> [ModelStatus] in
            var rows: [ModelStatus] = []
            if let session = group.session {
                rows.append(ModelStatus(name: group.name, remainingPercent: session.remaining,
                                        resetAt: session.resetAt, window: .session,
                                        groupLabel: AntigravityConfiguration.extraLimitGroup))
            }
            if let weekly = group.weekly {
                rows.append(ModelStatus(name: group.name, remainingPercent: weekly.remaining,
                                        resetAt: weekly.resetAt, window: .weekly,
                                        groupLabel: AntigravityConfiguration.extraLimitGroup))
            }
            return rows
        }
        return ServiceStatus(
            name: AntigravityConfiguration.name,
            iconName: AntigravityConfiguration.iconName,
            sessionResetAt: reading.primary.session?.resetAt,
            weeklyResetAt: reading.primary.weekly?.resetAt,
            sessionRemainingPercent: reading.primary.session?.remaining,
            weeklyRemainingPercent: reading.primary.weekly?.remaining,
            weeklyWindowSeconds: 7 * 86_400,
            models: extraModels,
            isAvailable: true,
            statusNote: reading.sourceNote,
            cooldownHint: 0,
            account: reading.account,
            observedAt: reading.observedAt
        )
    }

    private func antigravityFallback() -> ServiceStatus {
        let note = AntigravityConfiguration.isInstalled()
            ? AntigravityUsage.signInHintNote
            : AntigravityUsage.notInstalledNote
        if let cached = loadSnapshot(for: AntigravityConfiguration.name,
                                     iconName: AntigravityConfiguration.iconName,
                                     freshNote: "snapshot", staleNote: "out of date") {
            return cached
        }
        return unavailableService(name: AntigravityConfiguration.name,
                                  iconName: AntigravityConfiguration.iconName,
                                  models: [], note: note)
    }
}
