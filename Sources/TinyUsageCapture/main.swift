import Foundation

// A separate Foundation-only executable keeps Claude Code's statusLine path small.
// Full stdin is only forwarded in memory; only quota fields are ever persisted.
let arguments = CommandLine.arguments
func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
let input = FileHandle.standardInput.readDataToEndOfFile()
let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
if let output = argument("--output"), let limits = root?["rate_limits"] as? [String: Any] {
    var filtered: [String: Any] = [:]
    for kind in ["five_hour", "seven_day"] {
        guard let window = limits[kind] as? [String: Any] else { continue }
        var fields: [String: Any] = [:]
        for key in ["used_percentage", "resets_at"] {
            if let value = window[key], value is NSNumber || value is String { fields[key] = value }
        }
        if fields["used_percentage"] != nil { filtered[kind] = fields }
    }
    if !filtered.isEmpty {
        let payload: [String: Any] = ["rate_limits": filtered, "captured_at": Date().timeIntervalSince1970]
        let target = URL(fileURLWithPath: output)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".tiny-usage-quota-\(UUID().uuidString).tmp")
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            if rename(temporary.path, target.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        }
    }
}
if let previous = argument("--previous"), !previous.isEmpty {
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/bin/sh")
    command.arguments = ["-c", previous]
    let pipe = Pipe()
    command.standardInput = pipe
    command.standardOutput = FileHandle.standardOutput
    command.standardError = FileHandle.standardError
    do {
        try command.run()
        // Ignore a previous command that deliberately closes stdin early (SIGPIPE).
        signal(SIGPIPE, SIG_IGN)
        try? pipe.fileHandleForWriting.write(contentsOf: input)
        try? pipe.fileHandleForWriting.close()
        command.waitUntilExit()
        exit(command.terminationStatus)
    } catch { exit(0) }
} else if let limits = root?["rate_limits"] as? [String: Any] {
    // No bundle here, so the one visible string follows the system language directly.
    let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    let values = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label -> String? in
        guard let window = limits[key] as? [String: Any] else { return nil }
        let raw = (window["used_percentage"] as? NSNumber)?.doubleValue
            ?? (window["used_percentage"] as? String).flatMap(Double.init)
        guard let raw, raw.isFinite else { return nil }
        let left = Int(max(0, min(100, 100 - raw)).rounded())
        return chinese ? "\(label) 剩余 \(left)%" : "\(label) \(left)% left"
    }
    if !values.isEmpty { print("Tiny Usage  " + values.joined(separator: " · ")) }
}
