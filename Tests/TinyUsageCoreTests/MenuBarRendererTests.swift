import AppKit
import XCTest
@testable import TinyUsageCore

final class MenuBarRendererTests: XCTestCase {
    func testColorModesPreserveIndependentlyEditedQuotaColors() throws {
        let suite = "MenuBarColorsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var colors = MenuBarColors.load(from: defaults)
        XCTAssertEqual(colors.mode, .standard)
        colors.mode = .custom
        colors[.plenty] = try XCTUnwrap(MenuBarColorEditor.parseHex("#F4F5FB"))
        colors[.low] = try XCTUnwrap(MenuBarColorEditor.parseHex("663399"))
        colors[.critical] = try XCTUnwrap(MenuBarColorEditor.parseHex("4589ab"))
        XCTAssertNil(MenuBarColorEditor.parseHex("#123"))
        XCTAssertNil(MenuBarColorEditor.parseHex("#FFFFFZ"))
        colors.save(to: defaults)

        colors = MenuBarColors.load(from: defaults)
        XCTAssertEqual(colors.mode, .custom)
        XCTAssertEqual(colors.color(for: .plenty), NSColor(hex: 0xF4F5FB))
        XCTAssertEqual(colors.color(for: .low), NSColor(hex: 0x663399))
        XCTAssertEqual(colors.color(for: .critical), NSColor(hex: 0x4589AB))

        colors.mode = .subtle
        colors.save(to: defaults)
        colors = MenuBarColors.load(from: defaults)
        XCTAssertEqual(colors.color(for: .plenty), .labelColor)
        XCTAssertEqual(colors.color(for: .low), QuotaLevel.low.color)
        XCTAssertEqual(colors.color(for: .critical), QuotaLevel.critical.color)
        XCTAssertEqual(colors[.plenty], 0xF4F5FB)
    }

    func testProviderSelectionPreservesDefaultsAndExplicitlyHidingAll() throws {
        let suite = "MenuBarProviderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MenuBarProvider.selection(in: defaults), [.claude, .codex, .openCodeGo])
        MenuBarProvider.save([.codex, .openCodeGo], in: defaults)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(MenuBarProvider.selection(in: reloaded), [.codex, .openCodeGo])
        MenuBarProvider.save([], in: defaults)
        XCTAssertTrue(MenuBarProvider.selection(in: reloaded).isEmpty)
    }

    func testMenuBarSelectionAppliesToAllAccountsForAProvider() {
        func service(_ name: String, icon: String) -> ServiceStatus {
            ServiceStatus(name: name, iconName: icon, sessionResetAt: nil, weeklyResetAt: nil,
                          models: [], isAvailable: true, statusNote: nil)
        }
        let services = [service("Claude", icon: "claude"), service("Claude Desktop", icon: "claude"),
                        service("Codex", icon: "codex"), service("Codex Work", icon: "codex"),
                        service(OpenCodeGoConfiguration.name, icon: OpenCodeGoConfiguration.iconName)]

        XCTAssertEqual(MenuBarProvider.selectedServices(from: services, selection: [.codex, .openCodeGo]).map(\.name),
                       ["Codex", "Codex Work", OpenCodeGoConfiguration.name])
        XCTAssertTrue(MenuBarProvider.selectedServices(from: services, selection: []).isEmpty)
    }

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
