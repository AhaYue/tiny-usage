import Foundation
import XCTest
@testable import Mimir

final class AYUsageSchedulingTests: XCTestCase {
    func testRetryAfterAndPersistedCooldown() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(AdaptiveUsageSchedule.retryAfter("120", now: now), 120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(AdaptiveUsageSchedule.retryAfter(formatter.string(from: now.addingTimeInterval(300)), now: now), 300)
        let suite = "ay.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var schedule = AdaptiveUsageSchedule(defaults: defaults)
        let card = ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil, models: [], isAvailable: false, statusNote: nil, cooldownHint: 300)
        schedule.record(card, now: now)
        let restored = AdaptiveUsageSchedule(defaults: defaults)
        XCTAssertTrue(restored.skipped(now: now.addingTimeInterval(10), manual: true).contains("Codex"))
        XCTAssertFalse(restored.skipped(now: now.addingTimeInterval(301), manual: true).contains("Codex"))
    }

    func testHookOmitsMissingWindow() {
        let source = LiveUsageDataSource()
        let hook = LiveUsageDataSource.parseHookRateLimits(["rate_limits": ["five_hour": ["used_percentage": 20.0]]])!
        let status = source.claudeCardFromHook(hook)
        XCTAssertEqual(status.sessionRemainingPercent, 80)
        XCTAssertNil(status.weeklyRemainingPercent)
    }

    func testHookPreservesCachedResetCredits() throws {
        let source = LiveUsageDataSource()
        let expiry = Date().addingTimeInterval(86400)
        let iso = ISO8601DateFormatter().string(from: expiry)
        let cache: [String: Any] = ["cedar_ember": ["grants": [["resets_left": 1, "ends_at": iso]]]]
        source.writeClaudeUsageCache(try JSONSerialization.data(withJSONObject: cache))
        defer { try? FileManager.default.removeItem(at: LiveUsageDataSource.supportDirectory.appendingPathComponent("claude_usage.json")) }
        let hook = LiveUsageDataSource.parseHookRateLimits(["rate_limits": ["five_hour": ["used_percentage": 20.0]]])!
        let status = source.claudeCardFromHook(hook)
        XCTAssertEqual(status.models.count, 1)
        XCTAssertEqual(status.models.first?.resetAt?.timeIntervalSince1970 ?? 0, expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(status.weeklyRemainingPercent)
    }

    func testExpiredSnapshotWindowIsUnknown() {
        let source = LiveUsageDataSource()
        let status = source.staleClassifiedCard(name: "Codex", iconName: "codex", sessionPct: 10, sessionReset: Date().addingTimeInterval(-1), weeklyPct: nil, weeklyReset: nil, models: [], freshNote: "snapshot", staleNote: "old")
        XCTAssertNil(status?.sessionRemainingPercent)
        XCTAssertEqual(status?.isStale, true)
    }

    func testCodexReadsBoundedTailAndClassifiesWeekly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let reset = Int(Date().addingTimeInterval(86400).timeIntervalSince1970)
        let record = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":25,\"window_minutes\":10080,\"resets_at\":\(reset)}}}}\n"
        var data = Data(repeating: 32, count: 2_000_000)
        data.append(Data("\n\(record)".utf8))
        try data.write(to: file)
        let status = LiveUsageDataSource().fetchCodexLocalSessions(name: "Codex", home: home)
        XCTAssertNil(status.sessionRemainingPercent)
        XCTAssertEqual(status.weeklyRemainingPercent, 75)
        XCTAssertEqual(status.isStale, true)
        XCTAssertNotNil(status.observedAt)
    }

    func testSlowRefreshModeIsNeverUndercutByChangedDataOrResets() throws {
        let suite = "ay.schedule.mode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var schedule = AdaptiveUsageSchedule(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func status(_ percent: Int) -> ServiceStatus {
            // A reset five minutes out: auto mode would wake for it, a 15-minute mode must not.
            ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: now.addingTimeInterval(300), weeklyResetAt: nil,
                          sessionRemainingPercent: percent, models: [], isAvailable: true, statusNote: nil)
        }
        schedule.record(status(80), now: now, mode: .every15)
        XCTAssertTrue(schedule.skipped(now: now.addingTimeInterval(600), manual: false).contains("Codex"))
        XCTAssertFalse(schedule.skipped(now: now.addingTimeInterval(901), manual: false).contains("Codex"))
        // Changed data snaps back to the floor — the 15-minute floor, not two minutes.
        schedule.record(status(70), now: now.addingTimeInterval(901), mode: .every15)
        XCTAssertTrue(schedule.skipped(now: now.addingTimeInterval(901 + 300), manual: false).contains("Codex"))
        // Manual refresh still goes through.
        XCTAssertFalse(schedule.skipped(now: now.addingTimeInterval(901 + 300), manual: true).contains("Codex"))

        var auto = AdaptiveUsageSchedule(defaults: defaults)
        auto.record(status(60), now: now, mode: .auto)
        XCTAssertFalse(auto.skipped(now: now.addingTimeInterval(303), manual: false).contains("Codex"))
    }

    func testRefreshModeTickPacing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(RefreshMode.auto.tickShouldRefresh(lastRefresh: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(RefreshMode.every15.tickShouldRefresh(lastRefresh: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(RefreshMode.every15.tickShouldRefresh(lastRefresh: now.addingTimeInterval(-900), now: now))
        XCTAssertFalse(RefreshMode.manual.tickShouldRefresh(lastRefresh: nil, now: now))
        XCTAssertEqual(RefreshMode.manual.next, .auto)
    }
}
