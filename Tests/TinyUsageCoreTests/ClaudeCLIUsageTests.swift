import XCTest
@testable import TinyUsageCore

final class ClaudeCLIUsageTests: XCTestCase {
    func testParsesVerboseResultAndAccountWindowsWithResetTimeZones() throws {
        let now = try date("2026-10-01T07:00:00Z")
        let result = try Self.response("""
            Current session: 100% used · resets Oct 1 at 3:30pm (Asia/Shanghai)
            Current week (Sonnet only): 82% used · resets 3pm (UTC)
            Current week (all models): 17.5% used · resets Oct 5, 2:59PM (UTC)
            """, verbose: true)
        let reading = try XCTUnwrap(ClaudeCLIUsage.parse(result, now: now))
        XCTAssertEqual(reading.session?.used, 100)
        XCTAssertEqual(reading.session?.resetAt, try date("2026-10-01T07:30:00Z"))
        XCTAssertEqual(reading.weekly?.used, 17.5)
        XCTAssertEqual(reading.weekly?.resetAt, try date("2026-10-05T14:59:00Z"))
    }

    func testPartialAndExpiredWindowsKeepOnlyCurrentQuota() throws {
        let now = try date("2026-12-31T23:00:00Z")
        let reading = try XCTUnwrap(ClaudeCLIUsage.parse(Self.response("""
            Current session: 50% used · resets Dec 31, 10pm (UTC)
            Current week (all models): 10% used · resets Jan 1 at 2:30am (UTC)
            """), now: now))
        XCTAssertNil(reading.session)
        XCTAssertEqual(reading.weekly?.resetAt, try date("2027-01-01T02:30:00Z"))
        let withoutReset = try XCTUnwrap(ClaudeCLIUsage.parse(Self.response("Current session: 20% used"), now: now))
        XCTAssertEqual(withoutReset.session?.used, 20)
        XCTAssertNil(withoutReset.session?.resetAt)
        XCTAssertNil(withoutReset.weekly)
    }

    func testErrorOrModelOnlyReadingHasNoAccountQuota() throws {
        let now = Date()
        XCTAssertNil(ClaudeCLIUsage.parse(Data("invalid".utf8), now: now))
        XCTAssertNil(ClaudeCLIUsage.parse(try Self.response("Current week (Sonnet): 100% used"), now: now))
        XCTAssertNil(ClaudeCLIUsage.parse(try Self.response("Current session: 120% used"), now: now))
        let rejected = Data(#"{"type":"result","is_error":true,"result":"Current session: 20% used"}"#.utf8)
        XCTAssertNil(ClaudeCLIUsage.parse(rejected, now: now))
    }

    @MainActor
    func testCLIQuerySuppliesFirstReadingAndIsReusedWhenFresh() async throws {
        let profile = try isolatedProfile()
        defer { cleanProfile(profile) }
        try Self.writeProfile("first", to: profile)
        let response = try Self.response("Current session: 100% used\nCurrent week (all models): 22% used")
        let requests = RequestCounter()
        let cli = ClaudeCLIUsage { path, home in
            XCTAssertEqual(path, home.appendingPathComponent(".claude").path)
            await requests.record()
            return response
        }
        let source = LiveUsageDataSource()
        for _ in 0 ..< 2 {
            let status = await source.fetchClaudeCards(userInitiated: false, cliUsage: cli).first
            XCTAssertEqual(status?.sessionRemainingPercent, 0)
            XCTAssertEqual(status?.weeklyRemainingPercent, 78)
            XCTAssertEqual(status?.account?.id, "first|fixture")
        }
        let count = await requests.count
        XCTAssertEqual(count, 1)
        let snapshot = source.claudePrimarySnapshot(account: LiveUsageDataSource.claudeAccount(configFile: profile))
        XCTAssertTrue(snapshot.isStale)
        XCTAssertEqual(snapshot.sessionRemainingPercent, 0)
    }

    @MainActor
    func testFailedQueryIsThrottledAndDifferentAccountCanQueryImmediately() async throws {
        let profile = try isolatedProfile()
        defer { cleanProfile(profile) }
        try Self.writeProfile("first", to: profile)
        let requests = RequestCounter()
        let cli = ClaudeCLIUsage { _, _ in
            await requests.record()
            return nil
        }
        let source = LiveUsageDataSource()
        for _ in 0 ..< 2 {
            let status = await source.fetchClaudeCards(userInitiated: false, cliUsage: cli).first
            XCTAssertFalse(try XCTUnwrap(status).isAvailable)
        }
        let count = await requests.count
        XCTAssertEqual(count, 1)
        try Self.writeProfile("second", to: profile)
        _ = await source.fetchClaudeCards(userInitiated: false, cliUsage: cli)
        let separate = await requests.count
        XCTAssertEqual(separate, 2)
    }

    @MainActor
    func testDiscardInFlightReadingWhenAccountChanges() async throws {
        let profile = try isolatedProfile()
        defer { cleanProfile(profile) }
        try Self.writeProfile("first", to: profile)
        let response = try Self.response("Current session: 25% used")
        let cli = ClaudeCLIUsage { _, _ in
            try? Self.writeProfile("second", to: profile)
            return response
        }
        let source = LiveUsageDataSource()
        let status = await source.fetchClaudeCards(userInitiated: false, cliUsage: cli).first
        XCTAssertFalse(try XCTUnwrap(status).isAvailable)
        XCTAssertNil(source.loadSnapshot(for: "Claude", iconName: "claude"))
    }

    @MainActor
    func testRateLimitedOAuthKeepsCooldownAndDoesNotRunCLI() async throws {
        let profile = try isolatedProfile()
        defer { cleanProfile(profile) }
        try Self.writeProfile("rate-limited", to: profile)
        let credentials = URL(fileURLWithPath: ClaudeStatusLineHook.claudePath(".credentials.json"))
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: credentials) }
        try Data(#"{"claudeAiOauth":{"accessToken":"fixture-token"}}"#.utf8).write(to: credentials)
        let cli = ClaudeCLIUsage { _, _ in
            XCTFail("A CLI query must not bypass the OAuth rate limit")
            return nil
        }
        let source = LiveUsageDataSource()
        let status = await source.fetchClaudeCards(userInitiated: false, cliUsage: cli) { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 429,
                                                        httpVersion: nil, headerFields: ["Retry-After": "73"]))
            return (Data(), response)
        }.first
        XCTAssertEqual(status?.cooldownHint, 73)
        XCTAssertFalse(try XCTUnwrap(status).isAvailable)
    }

    @MainActor
    func testFreshHookWinsUntilAccountChanges() async throws {
        let profile = try isolatedProfile()
        defer { cleanProfile(profile) }
        try Self.writeProfile("hook", to: profile)
        let usage = URL(fileURLWithPath: ClaudeStatusLineHook.usagePath)
        try FileManager.default.createDirectory(at: usage.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: usage) }
        try Data(#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#.utf8).write(to: usage)
        let cli = ClaudeCLIUsage { _, _ in
            XCTFail("Fresh hook data already supplies the 5-hour window")
            return nil
        }
        let source = LiveUsageDataSource()
        let status = await source.fetchClaudeCards(userInitiated: false, cliUsage: cli).first
        XCTAssertEqual(status?.sessionRemainingPercent, 58)

        let response = try Self.response("Current session: 20% used")
        try Self.writeProfile("new-login", to: profile)
        let switched = await source.fetchClaudeCards(userInitiated: false, cliUsage: ClaudeCLIUsage { _, _ in response }).first
        XCTAssertEqual(switched?.sessionRemainingPercent, 80)
        XCTAssertEqual(switched?.account?.id, "new-login|fixture")
    }

    @MainActor
    func testCommandCapturesOutputAndCancelsUnresponsiveChild() async throws {
        let completed = await ClaudeCLIUsage.run(executable: "/bin/sh", arguments: ["-c", "printf sample"], environment: [:])
        XCTAssertEqual(completed, Data("sample".utf8))

        let clock = ContinuousClock()
        let started = clock.now
        let timedOut = await ClaudeCLIUsage.run(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 10 & wait"],
                                               environment: [:], timeout: .milliseconds(100))
        XCTAssertNil(timedOut)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(5))

        let cancelled = Task {
            await ClaudeCLIUsage.run(executable: "/bin/sleep", arguments: ["10"], environment: [:])
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(5))
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private static func response(_ result: String, verbose: Bool = false) throws -> Data {
        let event: [String: Any] = ["type": "result", "is_error": false, "result": result]
        return try JSONSerialization.data(withJSONObject: verbose ? [["type": "system"], event] : event)
    }

    private func isolatedProfile() throws -> URL {
        guard ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] != nil else {
            throw XCTSkip("Run through scripts/test.sh to isolate the Claude profile and keychain")
        }
        let profile = ClaudeStatusLineHook.claudeConfigFile
        cleanProfile(profile)
        return profile
    }

    private func cleanProfile(_ profile: URL) {
        let source = LiveUsageDataSource()
        try? FileManager.default.removeItem(at: profile)
        try? FileManager.default.removeItem(at: source.snapshotURL(for: "Claude"))
        try? FileManager.default.removeItem(at: LiveUsageDataSource.supportDirectory.appendingPathComponent("claude_account"))
    }

    private static func writeProfile(_ account: String, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": account, "organizationUuid": "fixture"]])
        try data.write(to: url, options: .atomic)
    }

    private actor RequestCounter {
        var count = 0
        func record() { count += 1 }
    }
}
