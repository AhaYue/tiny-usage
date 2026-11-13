import XCTest
@testable import Mimir

final class AppTargetTests: XCTestCase {
    func testOnlyGuiAppsMap() {
        XCTAssertNotNil(AppTarget.bundleID(for: "Antigravity"))
        XCTAssertNil(AppTarget.bundleID(for: "Claude"))
        XCTAssertNil(AppTarget.bundleID(for: "Codex"))
        XCTAssertNil(AppTarget.bundleID(for: "Nonexistent"))
    }
}
// Mimir's Sparkle beta/stable build-number tests do not apply: AY Usage has no Sparkle
// release channels or upstream release scripts.
