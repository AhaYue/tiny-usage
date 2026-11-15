import XCTest
@testable import TinyUsageCore

/// The prompt-free statusLine hook: parsing Claude Code's `rate_limits` JSON, and the pure
/// settings-transform logic that wires/unwires the hook while chaining any existing status line.
final class ClaudeHookTests: XCTestCase {

    // MARK: - rate_limits parsing (resets_at is epoch SECONDS, unlike the OAuth API's ISO string)

    func testParseHookRateLimits() {
        let root: [String: Any] = [
            "rate_limits": [
                "five_hour": ["used_percentage": 4, "resets_at": 1_700_000_000],
                "seven_day": ["used_percentage": 81.5, "resets_at": 1_700_600_000],
            ],
            "model": ["display_name": "Opus"],
        ]
        let parsed = LiveUsageDataSource.parseHookRateLimits(root)
        XCTAssertEqual(parsed?.five?.used, 4)
        XCTAssertEqual(parsed?.five?.reset, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(parsed?.seven?.used, 81.5)
        XCTAssertEqual(parsed?.seven?.reset, Date(timeIntervalSince1970: 1_700_600_000))
    }

    func testParseHookMissingRateLimitsReturnsNil() {
        // No rate_limits at all (older Claude Code / no subscription limits) → nil, callers fall through.
        XCTAssertNil(LiveUsageDataSource.parseHookRateLimits(["model": ["display_name": "Opus"]]))
    }

    func testParseHookToleratesOneWindowMissing() {
        // Anthropic's own statusline docs confirm five_hour/seven_day can each be independently
        // absent (no session yet this launch, a Team-plan account, or a window past its reset) — a
        // partial reading must still come back rather than being discarded outright.
        let fiveOnly = LiveUsageDataSource.parseHookRateLimits([
            "rate_limits": ["five_hour": ["used_percentage": 10]]
        ])
        XCTAssertEqual(fiveOnly?.five?.used, 10)
        XCTAssertNil(fiveOnly?.seven)

        let sevenOnly = LiveUsageDataSource.parseHookRateLimits([
            "rate_limits": ["seven_day": ["used_percentage": 33]]
        ])
        XCTAssertNil(sevenOnly?.five)
        XCTAssertEqual(sevenOnly?.seven?.used, 33)
    }

    func testParseHookToleratesMissingResetAndStringNumbers() {
        let root: [String: Any] = [
            "rate_limits": [
                "five_hour": ["used_percentage": "12"],            // numeric string, no reset
                "seven_day": ["used_percentage": 50, "resets_at": "1700000000"],
            ]
        ]
        let parsed = LiveUsageDataSource.parseHookRateLimits(root)
        XCTAssertEqual(parsed?.five?.used, 12)
        XCTAssertNil(parsed?.five?.reset)                         // absent reset → nil, not a crash
        XCTAssertEqual(parsed?.seven?.reset, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - statusLine wiring (pure)

    func testWireChainsExistingStatusLine() {
        let current: [String: Any] = [
            "statusLine": ["type": "command", "command": "bash \"/Users/x/.claude/ponytail.sh\""],
            "otherKey": 42,
        ]
        let (settings, chained) = ClaudeStatusLineHook.wiredSettings(from: current)
        XCTAssertEqual(chained, "bash \"/Users/x/.claude/ponytail.sh\"")   // preserved for passthrough
        let cmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        XCTAssertTrue(ClaudeStatusLineHook.isOurCommand(cmd))               // now points at our hook
        XCTAssertEqual(settings["otherKey"] as? Int, 42)                   // untouched
    }

    func testWireFromNoStatusLine() {
        let (settings, chained) = ClaudeStatusLineHook.wiredSettings(from: [:])
        XCTAssertNil(chained)
        XCTAssertTrue(ClaudeStatusLineHook.isOurCommand(
            (settings["statusLine"] as? [String: Any])?["command"] as? String))
    }

    func testWireWhenAlreadyOursDoesntSelfChain() {
        let current: [String: Any] = ["statusLine": ["type": "command", "command": ClaudeStatusLineHook.hookCommand]]
        let (_, chained) = ClaudeStatusLineHook.wiredSettings(from: current)
        XCTAssertNil(chained)   // never chain our own hook into itself (would recurse)
    }

    // MARK: - statusLine unwiring (pure)

    func testUnwireRestoresChainedCommand() {
        let current: [String: Any] = ["statusLine": ["type": "command", "command": ClaudeStatusLineHook.hookCommand]]
        let restored = ClaudeStatusLineHook.unwiredSettings(from: current, chained: "bash \"/x/ponytail.sh\"")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String,
                       "bash \"/x/ponytail.sh\"")
    }

    func testUnwireDropsStatusLineWhenNoChain() {
        let current: [String: Any] = ["statusLine": ["type": "command", "command": ClaudeStatusLineHook.hookCommand]]
        let restored = ClaudeStatusLineHook.unwiredSettings(from: current, chained: nil)
        XCTAssertNil(restored["statusLine"])
    }

    func testUnwireLeavesForeignStatusLineUntouched() {
        // If the current statusLine isn't ours (user re-pointed it), don't clobber it.
        let current: [String: Any] = ["statusLine": ["type": "command", "command": "bash \"/x/other.sh\""]]
        let restored = ClaudeStatusLineHook.unwiredSettings(from: current, chained: "bash \"/x/ponytail.sh\"")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "bash \"/x/other.sh\"")
    }

    // MARK: - Real installation into isolated fixture directories

    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-usage hook 'space \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["TINY_USAGE_HOME"]
        setenv("TINY_USAGE_HOME", directory.appendingPathComponent("state").path, 1)
        defer {
            if let previous { setenv("TINY_USAGE_HOME", previous, 1) } else { unsetenv("TINY_USAGE_HOME") }
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    func testCaptureHelperFollowsTheBundledOne() throws {
        try fixture { directory in
            let newer = directory.appendingPathComponent("newer-helper")
            try Data("#!/bin/sh\n# v2\n".utf8).write(to: newer)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newer.path)
            // Never installed and not wired: nothing to keep in step.
            XCTAssertFalse(ClaudeStatusLineHook.refreshCapture(from: newer))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeStatusLineHook.captureURL.path))

            XCTAssertEqual(ClaudeStatusLineHook.enable(in: directory, helperSource: URL(fileURLWithPath: "/usr/bin/true")), .enabled)
            XCTAssertTrue(ClaudeStatusLineHook.refreshCapture(from: newer))
            XCTAssertEqual(try Data(contentsOf: ClaudeStatusLineHook.captureURL), try Data(contentsOf: newer))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ClaudeStatusLineHook.captureURL.path))
            // Already current: no rewrite.
            XCTAssertFalse(ClaudeStatusLineHook.refreshCapture(from: newer))
            // A missing bundled helper never removes the installed one.
            XCTAssertFalse(ClaudeStatusLineHook.refreshCapture(from: directory.appendingPathComponent("absent")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: ClaudeStatusLineHook.captureURL.path))
        }
    }

    func testFullStatusLineRestoredWithoutDiscardingLaterSettings() throws {
        try fixture { directory in
            let url = directory.appendingPathComponent("settings.json")
            let original: [String: Any] = ["statusLine": ["type": "command", "command": "cat", "padding": 3], "other": 1]
            try JSONSerialization.data(withJSONObject: original).write(to: url)
            XCTAssertEqual(ClaudeStatusLineHook.enable(in: directory, helperSource: URL(fileURLWithPath: "/usr/bin/true")), .chained)
            var installed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            XCTAssertEqual((installed["statusLine"] as? [String: Any])?["padding"] as? Int, 3)
            installed["other"] = 42
            try JSONSerialization.data(withJSONObject: installed).write(to: url)
            XCTAssertEqual(ClaudeStatusLineHook.disable(in: directory), .disabled)
            let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            XCTAssertEqual(restored["other"] as? Int, 42)
            XCTAssertEqual((restored["statusLine"] as? [String: Any])?["padding"] as? Int, 3)
            XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "cat")
            XCTAssertEqual(ClaudeStatusLineHook.disable(in: directory), .disabled)
        }
    }

    func testChangedWrapperIsNotOverwrittenOrDeleted() throws {
        try fixture { directory in
            let url = directory.appendingPathComponent("settings.json")
            XCTAssertEqual(ClaudeStatusLineHook.enable(in: directory, helperSource: URL(fileURLWithPath: "/usr/bin/true")), .enabled)
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var status = root["statusLine"] as! [String: Any]
            status["padding"] = 99
            root["statusLine"] = status
            let changed = try JSONSerialization.data(withJSONObject: root)
            try changed.write(to: url)
            guard case .failed = ClaudeStatusLineHook.disable(in: directory) else { return XCTFail("Expected conflict") }
            XCTAssertEqual(try Data(contentsOf: url), changed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tiny-usage-statusline.sh").path))
        }
    }

    func testCorruptSettingsUntouchedAndMimirHookChainedLikeAnyCommand() throws {
        try fixture { directory in
            let url = directory.appendingPathComponent("settings.json")
            let bad = Data("not JSON".utf8)
            try bad.write(to: url)
            guard case .failed = ClaudeStatusLineHook.enable(in: directory) else { return XCTFail("Expected invalid JSON rejection") }
            XCTAssertEqual(try Data(contentsOf: url), bad)
            // A Mimir hook is just another statusLine: wrapped and chained, not special-cased.
            let mimir = Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"bash mimir-statusline.sh\"}}".utf8)
            try mimir.write(to: url)
            XCTAssertEqual(ClaudeStatusLineHook.enable(in: directory, helperSource: URL(fileURLWithPath: "/usr/bin/true")), .chained)
            let script = try String(contentsOf: directory.appendingPathComponent("tiny-usage-statusline.sh"), encoding: .utf8)
            XCTAssertTrue(script.contains("--previous 'bash mimir-statusline.sh'"))
            XCTAssertEqual(ClaudeStatusLineHook.enable(in: directory), .alreadyOn)
            XCTAssertEqual(ClaudeStatusLineHook.disable(in: directory), .disabled)
            let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "bash mimir-statusline.sh")
        }
    }

    func testCaptureForwardsExactStdinAndOnlyPersistsQuota() throws {
        try fixture { directory in
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = package.appendingPathComponent(".build/debug/TinyUsageCapture")
            try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: helper.path), "Build TinyUsageCapture before integration test")
            let output = directory.appendingPathComponent("quota.json")
            let bytes = Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":17,\"resets_at\":2000000000}},\"workspace\":\"do-not-store\"}\n\n".utf8)
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--output", output.path, "--previous", "/bin/cat"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: bytes)
            try stdin.fileHandleForWriting.close()
            let forwarded = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(forwarded, bytes)
            let saved = try Data(contentsOf: output)
            XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("do-not-store"))
            let quota = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
            XCTAssertNotNil(quota["rate_limits"])
            XCTAssertNil(quota["workspace"])
            let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(mode.intValue & 0o777, 0o600)
        }
    }
}
