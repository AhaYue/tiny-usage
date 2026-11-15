import XCTest
@testable import TinyUsageCore

final class CodexHomeTests: XCTestCase {
    private let source = LiveUsageDataSource()
    private let files = FileManager.default

    func testConfiguredHomeUsesItsSessionsWithoutBorrowingDefaultLogin() throws {
        let root = try makeHome()
        defer { try? files.removeItem(at: root) }
        let defaultHome = root.appendingPathComponent(".codex")
        let custom = root.appendingPathComponent("custom")
        try writeLogin("personal", in: defaultHome)
        try writeSession(used: 20, in: defaultHome)
        try writeSession(used: 70, in: custom)

        let resolved = source.codexHome(userHome: root, configuredHome: custom.path)
        let name = "Codex Home Fixture \(UUID().uuidString)"
        defer { try? files.removeItem(at: source.snapshotURL(for: name)) }
        let status = source.codexLocalOrSnapshot(name: name, home: resolved)
        XCTAssertEqual(resolved.path, custom.path)
        XCTAssertEqual(status.sessionRemainingPercent, 30)
        XCTAssertNil(status.account?.id)

        let missing = root.appendingPathComponent("missing")
        let missingHome = source.codexHome(userHome: root, configuredHome: missing.path)
        XCTAssertEqual(missingHome.path, missing.path)
        XCTAssertFalse(source.codexLocalOrSnapshot(name: name, home: missingHome).isAvailable)
    }

    func testRecognizesLegacyHomeAndKeepsDefaultLocalHistoryWhenBothExist() throws {
        let root = try makeHome()
        defer { try? files.removeItem(at: root) }
        let legacy = root.appendingPathComponent(".config/codex")
        try writeLogin("legacy", in: legacy)
        try writeSession(used: 60, in: legacy)

        let main = source.codexHome(userHome: root, configuredHome: nil)
        XCTAssertEqual(main.path, legacy.path)
        XCTAssertEqual(source.codexAccount(home: main)?.id, "legacy")
        XCTAssertEqual(source.fetchCodexLocalSessions(name: "Codex", home: main).sessionRemainingPercent, 40)

        let secondRoot = try makeHome()
        defer { try? files.removeItem(at: secondRoot) }
        let standard = secondRoot.appendingPathComponent(".codex")
        try writeSession(used: 20, in: standard)
        try writeLogin("legacy", in: secondRoot.appendingPathComponent(".config/codex"))
        let resolved = source.codexHome(userHome: secondRoot, configuredHome: nil)
        XCTAssertEqual(resolved.path, standard.path)
        XCTAssertNil(source.codexAccount(home: resolved)?.id)
        XCTAssertEqual(source.fetchCodexLocalSessions(name: "Codex", home: resolved).sessionRemainingPercent, 80)
    }

    func testExtraHomesDeduplicateByCanonicalDirectoryAndKnownAccount() throws {
        let root = try makeHome()
        defer { try? files.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        let alias = root.appendingPathComponent("alias")
        let work = root.appendingPathComponent("work")
        let duplicateWork = root.appendingPathComponent("work-copy")
        try files.createDirectory(at: main, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: alias, withDestinationURL: main)
        try writeLogin("work", in: work)
        try writeLogin("work", in: duplicateWork)

        let candidates = [ExtraAccount(name: "Codex Alias", dir: alias),
                          ExtraAccount(name: "Codex Work", dir: work),
                          ExtraAccount(name: "Codex Work Copy", dir: duplicateWork)]
        XCTAssertEqual(source.codexExtraAccounts(mainHome: main, candidates: candidates).map(\.name), ["Codex Work"])
    }

    func testScopedSnapshotDoesNotCrossHomesEvenWithSameAccountID() throws {
        let root = try makeHome()
        defer { try? files.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try writeLogin("same", in: first)
        try writeLogin("same", in: second)
        try writeSession(used: 70, in: second)

        let name = "Codex Home Fixture \(UUID().uuidString)"
        defer { try? files.removeItem(at: source.snapshotURL(for: name)) }
        saveSnapshot(name: name, account: "same", directory: first)
        XCTAssertEqual(source.codexSnapshotOrFallback(name: name, home: first).models.count, 1)
        XCTAssertFalse(source.codexSnapshotOrFallback(name: name, home: second).isAvailable)
        let status = source.codexLocalOrSnapshot(name: name, home: second)
        XCTAssertEqual(status.sessionRemainingPercent, 30)
        XCTAssertTrue(status.models.isEmpty)
    }

    func testSameHomeSwitchSuppressesOldSnapshotAndHistoricalQuota() throws {
        let home = try makeHome()
        defer { try? files.removeItem(at: home) }
        let name = "Codex Home Fixture \(UUID().uuidString)"
        defer { try? files.removeItem(at: source.snapshotURL(for: name)) }
        saveSnapshot(name: name, account: "old", directory: home)
        try writeLogin("new", in: home, modifiedAt: Date(timeIntervalSinceNow: -30))
        try writeSession(used: 30, in: home, observedAt: Date(timeIntervalSinceNow: -60))

        XCTAssertFalse(source.codexSnapshotOrFallback(name: name, home: home).isAvailable)
        let stale = source.codexLocalOrSnapshot(name: name, home: home)
        XCTAssertFalse(stale.isAvailable)
        XCTAssertEqual(stale.account?.id, "new")

        try writeSession(used: 20, in: home)
        let recovered = source.codexLocalOrSnapshot(name: name, home: home)
        XCTAssertEqual(recovered.sessionRemainingPercent, 80)
        XCTAssertEqual(recovered.account?.id, "new")
        XCTAssertTrue(recovered.models.isEmpty)
    }

    func testLegacySnapshotRequiresMatchingKnownAccountOutsideDefaultHome() throws {
        let home = try makeHome()
        defer { try? files.removeItem(at: home) }
        let name = "Codex Home Fixture \(UUID().uuidString)"
        defer { try? files.removeItem(at: source.snapshotURL(for: name)) }
        saveSnapshot(name: name, account: nil, directory: nil)
        XCTAssertFalse(source.codexSnapshotOrFallback(name: name, home: home).isAvailable)

        try writeLogin("fixture", in: home)
        saveSnapshot(name: name, account: "fixture", directory: nil)
        let recovered = source.codexSnapshotOrFallback(name: name, home: home)
        XCTAssertEqual(recovered.sessionRemainingPercent, 90)
        XCTAssertEqual(recovered.account?.id, "fixture")
        XCTAssertNotNil(recovered.sourceID)
    }

    private func makeHome() throws -> URL {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        return home.resolvingSymlinksInPath()
    }

    private func writeLogin(_ account: String, in home: URL, modifiedAt: Date = Date()) throws {
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("auth.json")
        let data = try JSONSerialization.data(withJSONObject: ["access_token": "fixture-token", "account_id": account])
        try data.write(to: file)
        try files.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
    }

    private func writeSession(used: Int, in home: URL, observedAt: Date = Date()) throws {
        let sessions = home.appendingPathComponent("sessions")
        try files.createDirectory(at: sessions, withIntermediateDirectories: true)
        let reset = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let record = """
        {"timestamp":"\(ISO8601DateFormatter().string(from: observedAt))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\(used),"window_minutes":300,"resets_at":\(reset)}}}}
        """
        try Data(record.utf8).write(to: sessions.appendingPathComponent("fixture.jsonl"))
    }

    private func saveSnapshot(name: String, account: String?, directory: URL?) {
        let reset = Date(timeIntervalSinceNow: 3_600)
        let status = ServiceStatus(name: name, iconName: "codex", sessionResetAt: reset, weeklyResetAt: nil,
                                   sessionRemainingPercent: 90,
                                   models: [ModelStatus(name: "Fixture credit", remainingPercent: 0, resetAt: reset,
                                                        valueText: "1", groupLabel: ModelStatus.renewalCreditGroup)],
                                   isAvailable: true, statusNote: nil,
                                   account: account.map { AccountInfo(plan: nil, email: nil, id: $0) },
                                   sourceID: directory.map { "codex:\($0.path)" })
        source.saveSnapshot(status)
    }
}
