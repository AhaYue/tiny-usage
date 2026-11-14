import XCTest
@testable import Mimir

final class TinyUsageRegressionTests: XCTestCase {
    func testResetGrantsKeepModelScopeAndIndependentExpiries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let f = ISO8601DateFormatter()
        let root: [String: Any] = ["cedar_ember": ["grants": [
            ["resets_left": 2, "ends_at": f.string(from: now.addingTimeInterval(86400)), "scope": ["model": ["display_name": "Fable"]]],
            ["resets_left": 1, "ends_at": f.string(from: now.addingTimeInterval(864000)), "scope": "weekly"]
        ]]]
        let rows = LiveUsageDataSource().claudeResetGrantRows(root, now: now)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.caption), ["Fable", "Fable", "周配额"])
        XCTAssertEqual(rows.last?.resetAt, now.addingTimeInterval(864000))
    }
    func testSupplementaryEndpointCooldownSurvivesRestart() async throws {
        let suite = "tinyusage.backoff.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = EndpointBackoff(suiteName: suite)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.test/usage")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "600"]))
        await first.record(response, key: "desktop", now: now)
        let restored = EndpointBackoff(suiteName: suite)
        let blocked = await restored.remaining("desktop", now: now.addingTimeInterval(60))
        let unrelated = await restored.remaining("another-account", now: now)
        XCTAssertEqual(blocked, 540)
        XCTAssertEqual(unrelated, 0)
    }
    func testChangedQuotaRestoresFastRefreshAfterIdleBackoff() throws {
        let suite = "tinyusage.schedule.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var schedule = AdaptiveUsageSchedule(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func status(_ percent: Int) -> ServiceStatus {
            ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                          sessionRemainingPercent: percent, models: [], isAvailable: true, statusNote: nil)
        }
        schedule.record(status(80), now: now)
        schedule.record(status(80), now: now.addingTimeInterval(120))
        XCTAssertTrue(schedule.skipped(now: now.addingTimeInterval(250), manual: false).contains("Codex"))
        schedule.record(status(70), now: now.addingTimeInterval(360))
        XCTAssertFalse(schedule.skipped(now: now.addingTimeInterval(481), manual: false).contains("Codex"))
    }
    func testLocalSessionSearchFallsBackWhenNewestFileHasNoQuota() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let reset = Int(Date().addingTimeInterval(86400).timeIntervalSince1970)
        let record = "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":25,\"window_minutes\":10080,\"resets_at\":\(reset)}}}}\n"
        let old = sessions.appendingPathComponent("old.jsonl")
        try Data(record.utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: old.path)
        try Data("{\"type\":\"session_meta\"}\n".utf8).write(to: sessions.appendingPathComponent("new.jsonl"))
        let result = LiveUsageDataSource().fetchCodexLocalSessions(name: "Codex", home: home)
        XCTAssertEqual(result.weeklyRemainingPercent, 75)
        XCTAssertNil(result.sessionRemainingPercent)
        XCTAssertFalse(result.isStale)
    }

    @MainActor
    func testServiceWithNoDataGetsSetupCardInsteadOfVanishing() {
        func status(_ name: String, available: Bool = false, stale: Bool = false, down: Bool = false) -> ServiceStatus {
            ServiceStatus(name: name, iconName: "claude", sessionResetAt: nil, weeklyResetAt: nil,
                          models: [], isAvailable: available, statusNote: "open Mimir to refresh Claude",
                          isStale: stale, dataUnavailable: down)
        }
        let services = [
            status("Claude"),                       // nothing at all → needs setup
            status("Codex", available: true),       // live → normal card
            status("Claude Desktop"),               // optional fallback → stays hidden
            status("Claude · work"),                // extra account → stays hidden
        ]
        XCTAssertEqual(PopoverView.needsSetup(services).map(\.name), ["Claude"])
        // A stale snapshot or the "can't refresh" banner already tells the story.
        XCTAssertTrue(PopoverView.needsSetup([status("Claude", stale: true)]).isEmpty)
        XCTAssertTrue(PopoverView.needsSetup([status("Codex", down: true)]).isEmpty)
    }
}
