import Foundation

// Derived from Mimir (MIT). Tiny Usage owns its own files; any existing statusLine (Mimir's included)
// is treated like every other command: wrapped and chained, never read or special-cased.
enum ClaudeStatusLineHook {
    private static var home: String {
        ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] ?? NSHomeDirectory()
    }
    static var claudeDir: String {
        let env = ProcessInfo.processInfo.environment
        if let test = env["TINY_USAGE_TEST_HOME"] { return test + "/.claude" }
        if let configured = env["CLAUDE_CONFIG_DIR"], !configured.isEmpty { return configured }
        return resolvedLaunchDirectory ?? home + "/.claude"
    }
    private static let resolvedLaunchDirectory: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "CLAUDE_CONFIG_DIR"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }()
    static func claudePath(_ component: String) -> String { (claudeDir as NSString).appendingPathComponent(component) }
    static var claudeConfigFile: URL {
        URL(fileURLWithPath: claudeDir == home + "/.claude" ? home + "/.claude.json" : claudePath(".claude.json"))
    }
    static var scriptPath: String { claudePath("tiny-usage-statusline.sh") }
    static var usagePath: String { claudePath("tiny-usage.json") }
    static var settingsPath: String { claudePath("settings.json") }
    static var prevPath: String { claudePath("tiny-usage-statusline-backup.json") }
    static var backupPath: String { claudePath("settings.json.tiny-usage-backup") }
    static var captureURL: URL {
        let base = ProcessInfo.processInfo.environment["TINY_USAGE_HOME"]
            ?? home + "/Library/Application Support/Tiny Usage"
        return URL(fileURLWithPath: base).appendingPathComponent("Helpers/TinyUsageCapture")
    }
    static var hookCommand: String { "sh " + quote(scriptPath) }
    enum Outcome: Equatable {
        case enabled, chained, alreadyOn, disabled, failed(String)
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func isOurCommand(_ command: String?) -> Bool { command?.contains("tiny-usage-statusline.sh") ?? false }
    static func wiredSettings(from current: [String: Any]?) -> (settings: [String: Any], chained: String?) {
        var settings = current ?? [:]
        var status = settings["statusLine"] as? [String: Any] ?? [:]
        let previous = status["command"] as? String
        status["type"] = "command"
        status["command"] = hookCommand
        settings["statusLine"] = status
        return (settings, isOurCommand(previous) ? nil : previous)
    }
    static func unwiredSettings(from current: [String: Any]?, chained: String?) -> [String: Any] {
        var settings = current ?? [:]
        guard isOurCommand((settings["statusLine"] as? [String: Any])?["command"] as? String) else { return settings }
        if let chained, !chained.isEmpty {
            var status = settings["statusLine"] as? [String: Any] ?? [:]
            status["type"] = "command"
            status["command"] = chained
            settings["statusLine"] = status
        } else { settings.removeValue(forKey: "statusLine") }
        return settings
    }
    static func scriptBody(chained: String?, directory: String? = nil) -> String {
        let output = (directory ?? claudeDir) + "/tiny-usage.json"
        let previous = chained.map { " --previous " + quote($0) } ?? ""
        return "#!/bin/sh\n# Tiny Usage — quota-only capture; full stdin stays in memory.\nexec "
            + quote(captureURL.path) + " --output " + quote(output) + previous + "\n"
    }
    static func isWired() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return isOurCommand((settings["statusLine"] as? [String: Any])?["command"] as? String)
    }
    private static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try LiveUsageDataSource.secureAtomicWrite(data: data, to: url, permissions: permissions)
    }
    private static func installCapture(from source: URL?) throws {
        let source = source ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TinyUsageCapture")
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            throw HookError.message(L("Capture helper not found. Enable it from a built Tiny Usage.app."))
        }
        try write(Data(contentsOf: source), to: captureURL, permissions: 0o700)
    }
    private enum HookError: Error {
        case message(String)
        var text: String { switch self { case .message(let message): return message } }
    }
    private static func readSettings(_ url: URL) throws -> (Data?, [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, [:]) }
        let bytes = try Data(contentsOf: url)
        guard let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw HookError.message(L("settings.json is not valid JSON; nothing was changed."))
        }
        return (bytes, root)
    }
    @discardableResult static func enable() -> Outcome { enable(in: URL(fileURLWithPath: claudeDir)) }
    @discardableResult static func enable(in directory: URL, helperSource: URL? = nil) -> Outcome {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let recordURL = directory.appendingPathComponent("tiny-usage-statusline-backup.json")
        let scriptURL = directory.appendingPathComponent("tiny-usage-statusline.sh")
        do {
            let (originalBytes, root) = try readSettings(settingsURL)
            let existing = root["statusLine"] as? [String: Any]
            let command = existing?["command"] as? String
            if isOurCommand(command) { return .alreadyOn }
            if root["statusLine"] != nil && existing == nil { throw HookError.message(L("Couldn't recognise the existing statusLine; nothing was changed.")) }
            if let type = existing?["type"] as? String, type != "command" { throw HookError.message(L("This statusLine type can't be wrapped; nothing was changed.")) }
            try installCapture(from: helperSource)
            var updated = root
            var installed = existing ?? [:]
            installed["type"] = "command"
            installed["command"] = "sh " + quote(scriptURL.path)
            updated["statusLine"] = installed
            let record: [String: Any] = ["original": root["statusLine"] ?? NSNull(), "installed": installed]
            if let bytes = originalBytes {
                let backup = directory.appendingPathComponent("settings.json.tiny-usage-backup")
                if !FileManager.default.fileExists(atPath: backup.path) { try write(bytes, to: backup) }
            }
            try write(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), to: recordURL)
            try write(Data(scriptBody(chained: command, directory: directory.path).utf8), to: scriptURL, permissions: 0o700)
            // Detect intervening changes. Atomic replacement prevents partial JSON; this is not a
            // lock shared with Claude Code, so a concurrent external writer can still race.
            guard FileManager.default.contents(atPath: settingsURL.path) == originalBytes else {
                throw HookError.message(L("The config was just changed by another program. Try again."))
            }
            try write(JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]), to: settingsURL)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("tiny-usage-wired").path, contents: Data(), attributes: [.posixPermissions: 0o600])
            return command == nil ? .enabled : .chained
        } catch let error as HookError { return .failed(error.text) }
        catch { return .failed(error.localizedDescription) }
    }
    @discardableResult static func disable() -> Outcome { disable(in: URL(fileURLWithPath: claudeDir)) }
    @discardableResult static func disable(in directory: URL) -> Outcome {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let recordURL = directory.appendingPathComponent("tiny-usage-statusline-backup.json")
        do {
            let (bytes, root) = try readSettings(settingsURL)
            guard isOurCommand((root["statusLine"] as? [String: Any])?["command"] as? String) else {
                // A foreign wrapper may still call our script: never delete it in this case.
                return .disabled
            }
            guard let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))) as? [String: Any],
                  let installed = saved["installed"] as? [String: Any],
                  let current = root["statusLine"] as? [String: Any], NSDictionary(dictionary: current).isEqual(to: installed) else {
                throw HookError.message(L("statusLine was changed externally; left as is, not overwritten."))
            }
            var updated = root
            if let original = saved["original"], !(original is NSNull) { updated["statusLine"] = original }
            else { updated.removeValue(forKey: "statusLine") }
            guard FileManager.default.contents(atPath: settingsURL.path) == bytes else { throw HookError.message(L("The config changed. Try again.")) }
            try write(JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]), to: settingsURL)
            for name in ["tiny-usage-statusline.sh", "tiny-usage-statusline-backup.json", "tiny-usage.json", "tiny-usage-wired"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            return .disabled
        } catch let error as HookError { return .failed(error.text) }
        catch { return .failed(error.localizedDescription) }
    }
    static func refreshScript() {
        // Explicit reinstallation upgrades the capture helper; background launch never writes config.
    }
    static func wireExtraDirs(_ on: Bool, accounts: [ExtraAccount] = ExtraAccount.claude) {
        for account in accounts {
            let marker = account.dir.appendingPathComponent("tiny-usage-wired")
            if on {
                guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
                _ = enable(in: account.dir)
            } else {
                _ = disable(in: account.dir)
                // Remove our marker only when a user has already removed the direct hook.
                if let data = try? Data(contentsOf: account.dir.appendingPathComponent("settings.json")),
                   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   !isOurCommand((root["statusLine"] as? [String: Any])?["command"] as? String) {
                    try? FileManager.default.removeItem(at: marker)
                }
            }
        }
    }
}
