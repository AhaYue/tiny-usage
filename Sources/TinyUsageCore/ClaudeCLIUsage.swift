import Darwin
import Foundation

actor ClaudeCLIUsage {
    struct Window: Equatable, Sendable {
        let used: Double
        let resetAt: Date?
    }

    struct Reading: Equatable, Sendable {
        let session: Window?
        let weekly: Window?
        let observedAt: Date

        func isFresh(at date: Date) -> Bool {
            let age = date.timeIntervalSince(observedAt)
            return (0 ..< 300).contains(age)
                && [session?.resetAt, weekly?.resetAt].compactMap { $0 }.allSatisfy { date < $0 }
        }
    }

    private struct Entry {
        let attemptedAt: Date
        var reading: Reading?
    }

    static let shared = ClaudeCLIUsage()
    private var entries: [String: Entry] = [:]
    private let runCommand: @Sendable (String, URL) async -> Data?

    init(runCommand: @escaping @Sendable (String, URL) async -> Data? = ClaudeCLIUsage.readCurrent) {
        self.runCommand = runCommand
    }

    func read(accountID: String, configDirectory: String, home: URL, now: Date = Date(),
              currentAccountID: @Sendable () -> String?) async -> Reading? {
        guard !Task.isCancelled, currentAccountID() == accountID else { return nil }
        if let entry = entries[accountID] {
            if let reading = entry.reading, reading.isFresh(at: now) { return reading }
            if now.timeIntervalSince(entry.attemptedAt) < 30 { return nil }
        }
        entries[accountID] = Entry(attemptedAt: now)
        guard let bytes = await runCommand(configDirectory, home), !Task.isCancelled, currentAccountID() == accountID,
              let reading = Self.parse(bytes, now: Date()) else { return nil }
        entries[accountID]?.reading = reading
        return reading
    }

    private static let quotaLine = try! NSRegularExpression(
        pattern: #"^Current (session|week(?: \(all models\))?):\s*([0-9]+(?:\.[0-9]+)?)% used(?:\s*·\s*resets\s+(.+))?$"#,
        options: .caseInsensitive)

    static func parse(_ bytes: Data, now: Date) -> Reading? {
        let json = try? JSONSerialization.jsonObject(with: bytes)
        let result = (json as? [[String: Any]])?.last { $0["type"] as? String == "result" }
            ?? (json as? [String: Any])
        guard let result, result["type"] as? String == "result", result["is_error"] as? Bool != true,
              let output = result["result"] as? String else { return nil }

        let text = output.replacingOccurrences(of: "\u{1B}" + #"\[[0-?]*[ -/]*[@-~]"#,
                                               with: "", options: .regularExpression)
        var session: Window?
        var weekly: Window?
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces) as NSString
            guard let match = quotaLine.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
                  let used = Double(line.substring(with: match.range(at: 2))), (0 ... 100).contains(used) else { continue }
            let isSession = line.substring(with: match.range(at: 1)).lowercased() == "session"
            let resetRange = match.range(at: 3)
            let span: TimeInterval = isSession ? 5 * 3600 : 7 * 86_400
            let reset = resetRange.location == NSNotFound ? nil
                : resetTime(line.substring(with: resetRange), now: now, span: span)
            guard reset.map({ now < $0 }) != false else { continue }
            let window = Window(used: used, resetAt: reset)
            if isSession { session = session ?? window } else { weekly = weekly ?? window }
        }
        guard session != nil || weekly != nil else { return nil }
        return Reading(session: session, weekly: weekly, observedAt: now)
    }

    private static func resetTime(_ value: String, now: Date, span: TimeInterval) -> Date? {
        var text = value.trimmingCharacters(in: .whitespaces).lowercased()
        var zone = TimeZone.current
        if let open = value.lastIndex(of: "("), value.hasSuffix(")") {
            guard let namedZone = TimeZone(identifier: String(value[value.index(after: open)..<value.index(before: value.endIndex)])) else { return nil }
            zone = namedZone
            text = value[..<open].trimmingCharacters(in: .whitespaces).lowercased()
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.isLenient = false

        for date in ["MMM d, yyyy 'at'", "MMM d, yyyy,", "MMM d 'at'", "MMM d,"] {
            for clock in ["h:mma", "ha", "h:mm a", "h a"] {
                formatter.dateFormat = "\(date) \(clock)"
                if date.contains("yyyy"), let parsed = formatter.date(from: text) { return parsed }
                if date.contains("yyyy") { continue }
                let year = calendar.component(.year, from: now)
                let candidates = ((year - 1) ... (year + 1)).compactMap { candidate -> Date? in
                    formatter.defaultDate = calendar.date(from: DateComponents(year: candidate, month: 1, day: 1))
                    return formatter.date(from: text)
                }
                if let nearest = candidates.min(by: { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }) {
                    return nearest
                }
            }
        }
        for clock in ["h:mma", "ha", "h:mm a", "h a"] {
            formatter.dateFormat = clock
            formatter.defaultDate = calendar.startOfDay(for: now)
            guard let today = formatter.date(from: text) else { continue }
            let next = today >= now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
            if next.timeIntervalSince(now) <= span + 3600 { return next }
            return today < now ? today : calendar.date(byAdding: .day, value: -1, to: today)
        }
        return nil
    }

    private static let arguments = ["-p", "/usage", "--output-format", "json", "--verbose", "--tools", "",
                                    "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
                                    "--settings", #"{"disableDeepLinkRegistration":"disable"}"#]

    static func readCurrent(configDirectory: String, home: URL) async -> Data? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TINY_USAGE_TEST_HOME"] == nil,
              !CommandLine.arguments.contains(where: ["--demo", "--render-preview", "--smoke-test"].contains) else { return nil }

        let standardPaths = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        let searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + standardPaths
        let manager = FileManager.default
        guard let cli = searchPaths.lazy.filter({ $0.hasPrefix("/") }).map({ $0 + "/claude" })
            .first(where: { manager.isExecutableFile(atPath: $0) }) else { return nil }

        let conflicting = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_OAUTH_TOKEN",
                           "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                           "CLAUDE_CODE_USE_MANAGED_SETTINGS", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                           "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"]
        var childEnvironment = environment.filter { !conflicting.contains($0.key) }
        childEnvironment["HOME"] = home.path
        childEnvironment["PATH"] = searchPaths.joined(separator: ":")
        childEnvironment["CLAUDE_CONFIG_DIR"] = configDirectory == home.appendingPathComponent(".claude").path
            ? nil : configDirectory
        childEnvironment["DISABLE_TELEMETRY"] = "1"
        childEnvironment["DISABLE_ERROR_REPORTING"] = "1"
        childEnvironment["DISABLE_AUTOUPDATER"] = "1"

        return await run(executable: cli, arguments: arguments, environment: childEnvironment)
    }

    static func run(executable: String, arguments: [String], environment: [String: String],
                    timeout: Duration = .seconds(5)) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("tiny-usage-claude-\(UUID().uuidString)")
        guard (try? manager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? manager.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("stdout")
        guard let pid = spawn(executable: executable, arguments: arguments, environment: environment,
                              directory: temporary, output: output) else { return nil }

        // A dedicated process group also covers wrapper scripts. Polling waitpid keeps cancellation
        // responsive without a blocked Pipe reader or a blocking wait on a cooperative executor.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var status: Int32 = 0
        while true {
            let waited = Darwin.waitpid(pid, &status, WNOHANG)
            if waited == pid {
                guard status == 0, !Task.isCancelled, let file = try? FileHandle(forReadingFrom: output) else { return nil }
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

    private static func spawn(executable: String, arguments: [String], environment: [String: String],
                              directory: URL, output: URL) -> pid_t? {
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
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_CREAT | O_WRONLY | O_EXCL, 0o600) == 0 else { return nil }

        let argv = ([executable] + arguments).map { strdup($0) }
        let env = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + env).forEach { free($0) } }
        guard (argv + env).allSatisfy({ $0 != nil }) else { return nil }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], env + [nil])
        return result == 0 ? pid : nil
    }
}
