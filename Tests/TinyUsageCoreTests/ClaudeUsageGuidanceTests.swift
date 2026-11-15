import XCTest
@testable import TinyUsageCore

final class ClaudeUsageGuidanceTests: XCTestCase {
    private func status(available: Bool = false, stale: Bool = false, down: Bool = false,
                        note: String = "claude token missing") -> ServiceStatus {
        ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: nil, weeklyResetAt: nil,
                      models: [], isAvailable: available, statusNote: note,
                      isStale: stale, dataUnavailable: down)
    }

    /// Local capture is wired silently, so it is never offered; authorizing is the only step.
    func testNoLiveReadingOffersOnlyAuthorize() throws {
        let off = try XCTUnwrap(ClaudeUsageGuidance.resolve(service: status(), capture: .disabled))
        XCTAssertEqual(off.state, .waiting)
        XCTAssertNil(off.detail)
        XCTAssertTrue(off.offersAuthorize)
        let first = try XCTUnwrap(ClaudeUsageGuidance.resolve(service: status(), capture: .waiting))
        XCTAssertEqual(first.title, L("Waiting for first local data"))
        XCTAssertEqual(first.detail, L("Usage appears after you use Claude Code."))
        XCTAssertTrue(first.offersAuthorize)
        for capture in [ClaudeLocalCaptureState.outdated, .ready] {
            XCTAssertEqual(ClaudeUsageGuidance.resolve(service: status(), capture: capture)?.title, L("Waiting for a usage update"))
        }
    }

    func testSavedUsageExplainsTheWaitAndOffersAuthorization() throws {
        for capture in [ClaudeLocalCaptureState.waiting, .disabled] {
            for service in [status(available: true, stale: true),
                            status(available: true, down: true),
                            status(available: true, note: "snapshot")] {
                let guide = try XCTUnwrap(ClaudeUsageGuidance.resolve(service: service, capture: capture))
                XCTAssertEqual(guide.title, L("Last usage · Waiting to update"))
                XCTAssertNil(guide.detail)
                XCTAssertTrue(guide.offersAuthorize)
            }
        }
    }

    /// A failed request or a lapsed login isn't fixed by authorizing again, so neither offers it.
    func testFailuresAuthorizingCannotFixOfferNoAuthorize() throws {
        for note in ["claude http 429", "claude request failed", "claude http 500"] {
            let guide = try XCTUnwrap(ClaudeUsageGuidance.resolve(service: status(note: note), capture: .disabled))
            XCTAssertEqual(guide.state, .unavailable)
            XCTAssertFalse(guide.offersAuthorize)
        }
        let expiredNote = L("token expired — open Claude Code")
        let expired = try XCTUnwrap(ClaudeUsageGuidance.resolve(service: status(note: expiredNote), capture: .waiting))
        XCTAssertEqual(expired.state, .loginExpired)
        XCTAssertFalse(expired.offersAuthorize)
        let saved = status(available: true, stale: true, note: expiredNote)
        XCTAssertEqual(ClaudeUsageGuidance.resolve(service: saved, capture: .waiting), expired)
    }

    /// Recent last-known numbers are shown as they are: no nagging card on a reading that's still valid.
    func testValidCachedReadingWithoutCredentialsShowsNoGuidance() {
        XCTAssertNil(ClaudeUsageGuidance.resolve(
            service: status(available: true, note: String(localized: "authorize in Settings to read the Claude credential", bundle: .tinyUsage)), capture: .disabled))
    }

    /// No credentials, no prompt: the chain falls through to the hook, and its exhausted 0% is data.
    func testUnauthorizedRefreshKeepsRealExhaustedHookReading() async throws {
        guard ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] != nil else {
            throw XCTSkip("Run through scripts/test.sh to keep real usage files untouched")
        }
        let url = URL(fileURLWithPath: ClaudeStatusLineHook.usagePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let reset = Date().addingTimeInterval(3600).timeIntervalSince1970
        try JSONSerialization.data(withJSONObject: ["rate_limits": [
            "five_hour": ["used_percentage": 100, "resets_at": reset],
            "seven_day": ["used_percentage": 19, "resets_at": reset]
        ]]).write(to: url)
        let cards = await LiveUsageDataSource().fetchClaudeCards(userInitiated: false)
        let card = try XCTUnwrap(cards.first(where: { $0.name == "Claude" }))
        XCTAssertTrue(card.isAvailable)
        XCTAssertEqual(card.sessionRemainingPercent, 0)
        XCTAssertEqual(card.weeklyRemainingPercent, 81)
        XCTAssertNil(ClaudeUsageGuidance.resolve(service: card, capture: .ready))
    }

    func testExtraAccountReadsItsHook() async throws {
        guard ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] != nil else {
            throw XCTSkip("Run through scripts/test.sh to keep the real keychain untouched")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: ["rate_limits": [
            "five_hour": ["used_percentage": 25, "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970]
        ]]).write(to: dir.appendingPathComponent("tiny-usage.json"))
        let card = await LiveUsageDataSource().fetchClaudeExtraAccount(
            name: "Claude Test \(UUID().uuidString)", dir: dir, userInitiated: false)
        XCTAssertTrue(card.isAvailable)
        XCTAssertEqual(card.sessionRemainingPercent, 75)
    }

    @MainActor
    func testExhaustedQuotaRemainsDataAndDoesNotShowSetupOrPermissionGuidance() {
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let service = LiveUsageDataSource().buildClaudeStatus(from: [
            "five_hour": ["utilization": 100, "resets_at": reset],
            "seven_day": ["utilization": 19, "resets_at": reset]
        ], note: "本地状态栏")
        XCTAssertTrue(service.isAvailable)
        XCTAssertEqual(service.sessionRemainingPercent, 0)
        XCTAssertEqual(service.weeklyRemainingPercent, 81)
        XCTAssertNil(ClaudeUsageGuidance.resolve(service: service, capture: .ready))
        XCTAssertTrue(PopoverView.needsSetup([service]).isEmpty)
    }

    func testHealthyUsageDoesNotShowSetupEvenIfLocalCaptureIsOff() {
        XCTAssertNil(ClaudeUsageGuidance.resolve(service: status(available: true, note: "oauth usage api"), capture: .disabled))
    }
}
