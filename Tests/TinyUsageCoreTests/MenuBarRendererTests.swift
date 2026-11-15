import XCTest
@testable import TinyUsageCore

final class MenuBarRendererTests: XCTestCase {
    func testRemainingModeKeepsUnknownAndZero() {
        XCTAssertNil(MenuBarRenderer.displayedPercent(remaining: nil, showRemaining: true))
        XCTAssertEqual(MenuBarRenderer.displayedPercent(remaining: 0, showRemaining: true), 0)
        XCTAssertEqual(MenuBarRenderer.displayedPercent(remaining: 100, showRemaining: false), 0)
        XCTAssertEqual(MenuBarRenderer.displayedPercent(remaining: 83, showRemaining: false), 17)
    }
    func testPaceRequiresActualWindowAndFutureReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(MenuBarRenderer.timePosition(resetAt: now, duration: 18000, remaining: true, now: now))
        XCTAssertNil(MenuBarRenderer.timePosition(resetAt: now.addingTimeInterval(9000), duration: nil, remaining: true, now: now))
        XCTAssertEqual(MenuBarRenderer.timePosition(resetAt: now.addingTimeInterval(9000), duration: 18000, remaining: true, now: now), 0.5)
        XCTAssertEqual(MenuBarRenderer.timePosition(resetAt: now.addingTimeInterval(4500), duration: 18000, remaining: false, now: now), 0.75)
    }
    @MainActor
    func testCombinedTitleHasNativeVariableWidthAndUnknownTooltip() {
        let status = ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                                   sessionRemainingPercent: nil, weeklyRemainingPercent: 41,
                                   models: [], isAvailable: true, statusNote: nil)
        let image = MenuBarRenderer.image(services: [status], style: .both, remaining: true, now: Date())
        XCTAssertEqual(image.size.height, 22)
        XCTAssertGreaterThan(image.size.width, 64)
        XCTAssertFalse(image.isTemplate)
        XCTAssertTrue(MenuBarRenderer.tooltip(services: [status], remaining: true).contains(L("unknown")))
    }

    func testQuotaLevelReadsLikeABatteryByRemainingOnly() {
        XCTAssertEqual(QuotaLevel(remaining: 100), .plenty)
        XCTAssertEqual(QuotaLevel(remaining: 50), .plenty)
        XCTAssertEqual(QuotaLevel(remaining: 49), .low)
        XCTAssertEqual(QuotaLevel(remaining: 20), .low)
        XCTAssertEqual(QuotaLevel(remaining: 19), .critical)
        XCTAssertEqual(QuotaLevel(remaining: -5), .critical)
    }
}
