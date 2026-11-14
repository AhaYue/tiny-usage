import XCTest
@testable import Mimir

/// Which login a card reads: its plan and e-mail, Claude.app matched to Claude Code's organization,
/// and one card per login however many sources reach it.
final class AccountInfoTests: XCTestCase {
    func testPlanNames() {
        XCTAssertEqual(AccountInfo.claudePlan("claude_team"), "Team")
        XCTAssertEqual(AccountInfo.claudePlan("claude_max"), "Max")
        XCTAssertEqual(AccountInfo.claudePlan("claude_enterprise"), "Enterprise")
        XCTAssertNil(AccountInfo.claudePlan(nil))
        XCTAssertEqual(AccountInfo.codexPlan("plus"), "Plus")
        XCTAssertEqual(AccountInfo.codexPlan("team"), "Team")
    }

    func testClaudeProfileNamesTheLogin() {
        let info = LiveUsageDataSource.claudeAccount(oauthAccount: [
            "accountUuid": "u1", "organizationUuid": "o1",
            "emailAddress": "me@example.com", "organizationType": "claude_team",
        ])
        XCTAssertEqual(info, AccountInfo(plan: "Team", email: "me@example.com", id: "u1|o1", org: "o1"))
        XCTAssertNil(LiveUsageDataSource.claudeAccount(oauthAccount: ["emailAddress": "x"]))
    }

    func testDesktopReadsTheCLIOrganizationElseAPaidOne() {
        let orgs: [[String: Any]] = [
            ["uuid": "personal", "capabilities": ["chat"]],
            ["uuid": "team", "capabilities": ["chat", "raven"]],
            ["uuid": "other", "capabilities": ["chat", "claude_max"]],
        ]
        // Claude Code's organization wins whenever the app's session can reach it.
        XCTAssertEqual(LiveUsageDataSource.selectClaudeOrgUUID(orgs, preferring: "other"), "other")
        // Otherwise a paid one, never the plan-less personal organization that comes first.
        XCTAssertEqual(LiveUsageDataSource.selectClaudeOrgUUID(orgs, preferring: "elsewhere"), "team")
        XCTAssertEqual(LiveUsageDataSource.selectClaudeOrgUUID(orgs), "team")
        XCTAssertEqual(LiveUsageDataSource.claudeOrgPlan(orgs[2]), "Max")
        XCTAssertNil(LiveUsageDataSource.claudeOrgPlan(orgs[0]))
    }

    func testAnAnswerWithEveryWindowNullIsNoQuota() {
        XCTAssertFalse(LiveUsageDataSource.claudeHasQuota(["five_hour": NSNull(), "seven_day": NSNull(), "limits": []]))
        XCTAssertTrue(LiveUsageDataSource.claudeHasQuota(["five_hour": ["utilization": 12.0], "seven_day": NSNull()]))
        // Spending alone is still something to show; a disabled one isn't.
        XCTAssertTrue(LiveUsageDataSource.claudeHasQuota(["five_hour": NSNull(), "spend": ["enabled": true]]))
        XCTAssertTrue(LiveUsageDataSource.claudeHasQuota(["seven_day": NSNull(), "extra_usage": ["is_enabled": true]]))
        XCTAssertFalse(LiveUsageDataSource.claudeHasQuota(["five_hour": NSNull(), "extra_usage": ["is_enabled": false]]))
    }

    func testAWindowThePlanLacksShowsNoBar() {
        // A Team seat without a weekly limit: the session reads, the week stays empty.
        let card = LiveUsageDataSource().buildClaudeStatus(
            from: ["five_hour": ["utilization": 9.0], "seven_day": NSNull()], note: "test")
        XCTAssertEqual(card.sessionRemainingPercent, 91)
        XCTAssertNil(card.weeklyRemainingPercent)
    }

    func testOneCardPerLogin() {
        let extras = [ExtraAccount(name: "Codex Work", dir: URL(fileURLWithPath: "/a")),
                      ExtraAccount(name: "Codex Mirror", dir: URL(fileURLWithPath: "/b")),
                      ExtraAccount(name: "Codex Again", dir: URL(fileURLWithPath: "/c")),
                      ExtraAccount(name: "Codex Unknown", dir: URL(fileURLWithPath: "/d"))]
        let ids = ["/a": "work", "/b": "main", "/c": "work"]
        let kept = LiveUsageDataSource.distinct(extras, seen: "main") { extra in
            ids[extra.dir.path].map { AccountInfo(id: $0) }
        }
        // The main card's login and a repeat are dropped; an unreadable profile is kept.
        XCTAssertEqual(kept.map(\.0.name), ["Codex Work", "Codex Unknown"])
    }

    func testCardTitleIsTheProviderAndTheSourceKeepsItsAccount() {
        let card = ServiceStatus(name: "Claude Work", iconName: "claude", sessionResetAt: nil, weeklyResetAt: nil,
                                 models: [], isAvailable: true, statusNote: nil,
                                 account: AccountInfo(plan: "Max"))
        XCTAssertEqual(card.providerTitle, "Claude")
        // What the source read itself outranks the local profile.
        XCTAssertEqual(card.withAccount(AccountInfo(plan: "Team", email: "x@y")).account?.plan, "Max")
        XCTAssertEqual(card.withAccount(AccountInfo(email: "x@y")).titleWithAccount, "Claude")
        XCTAssertEqual(ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                                     models: [], isAvailable: true, statusNote: nil)
                        .withAccount(AccountInfo(email: "me@gmail.com")).titleWithAccount, "Codex (me@gmail.com)")
    }
}
