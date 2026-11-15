import XCTest
@testable import TinyUsageCore

/// The claude.ai desktop-session path: org selection + the cookie-decryption format guards. The AES
/// round-trip itself needs the machine's real Safe Storage key, so it's exercised live in the app, not
/// here; these pin down the pure decision/guard logic that would otherwise fail silently.
final class ClaudeDesktopTests: XCTestCase {
    private let ds = LiveUsageDataSource()

    /// Claude.app's separate card is kept only while it provably names another organization; a
    /// snapshot of the CLI's own login, or one without an organization, would be the same account twice.
    func testOtherAccountCardOnlyForAnotherOrganization() {
        func card(org: String?) -> ServiceStatus {
            ServiceStatus(name: LiveUsageDataSource.claudeDesktopCardName, iconName: "claude",
                          sessionResetAt: nil, weeklyResetAt: nil, models: [], isAvailable: true,
                          statusNote: nil).withAccount(AccountInfo(plan: "Team", org: org))
        }
        XCTAssertNotNil(LiveUsageDataSource.otherAccountCard(card(org: "b"), cliOrg: "a"))
        XCTAssertNil(LiveUsageDataSource.otherAccountCard(card(org: "a"), cliOrg: "a"))
        XCTAssertNil(LiveUsageDataSource.otherAccountCard(card(org: nil), cliOrg: "a"))
        XCTAssertNil(LiveUsageDataSource.otherAccountCard(card(org: "b"), cliOrg: nil))
        XCTAssertNil(LiveUsageDataSource.otherAccountCard(nil, cliOrg: "a"))
    }

    func testOrgSelectionPrefersChatCapabilityThenFirst() {
        let orgs: [[String: Any]] = [
            ["uuid": "a", "capabilities": ["billing"]],
            ["uuid": "b", "capabilities": ["chat", "claude_pro"]],
        ]
        XCTAssertEqual(LiveUsageDataSource.selectClaudeOrgUUID(orgs), "b")
        // No capability match → first org.
        XCTAssertEqual(LiveUsageDataSource.selectClaudeOrgUUID([["uuid": "x"], ["uuid": "y"]]), "x")
        XCTAssertNil(LiveUsageDataSource.selectClaudeOrgUUID([]))
    }

    func testDecryptRejectsNonChromiumBlobs() {
        // Missing/short → nil, wrong tag → nil (never crashes on junk cookie bytes).
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data(), safeStoragePassword: "pw"))
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data("v10".utf8), safeStoragePassword: "pw"))
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data("xx0abcdefghijklmnop".utf8), safeStoragePassword: "pw"))
        // v10 tag but ciphertext not a whole number of AES blocks → nil, not a crash.
        XCTAssertNil(LiveUsageDataSource.decryptChromiumCookie(Data("v10short".utf8), safeStoragePassword: "pw"))
    }

    func testOAuthTokenPicksLongestLivingUnexpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache: [String: Any] = [
            "a:user:inference": ["token": "sk-ant-oat01-old", "expiresAt": 1_799_000_000_000.0],   // expired, ms
            "b:user:profile": ["token": "sk-ant-oat01-short", "expiresAt": 1_800_003_600.0],       // seconds
            "nested": [["accessToken": "sk-ant-oat01-long", "expiresAt": "2027-06-01T00:00:00Z"]],
            "junk": ["token": "not-a-token", "expiresAt": 1_900_000_000.0],
        ]
        XCTAssertEqual(LiveUsageDataSource.claudeOAuthToken(in: cache, now: now), "sk-ant-oat01-long")
        XCTAssertNil(LiveUsageDataSource.claudeOAuthToken(in: ["x": ["token": "sk-ant-oat01-a"]], now: now))  // no expiry
    }
}
