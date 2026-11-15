import Foundation
import XCTest
@testable import TinyUsageCore

final class OpenCodeGoTests: XCTestCase {
    func testParseIndependentWindowsAndExplicitExhaustion() throws {
        let response = Data("""
        {"usage":{
          "rolling":{"status":"ok","percent":0,"resetsAt":"2026-11-21T03:02:01.000Z"},
          "weekly":{"status":"ok","percent":99.9,"resetsAt":"2026-11-24T03:02:01-08:00"},
          "monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-12-01T03:02:01.000Z"}
        }}
        """.utf8)
        let reading = try XCTUnwrap(OpenCodeGoUsage.parse(response))
        let dates = ISO8601DateFormatter()
        XCTAssertEqual(reading.rolling, .init(remaining: 100, resetAt: nil))
        XCTAssertEqual(reading.weekly, .init(remaining: 1, resetAt: dates.date(from: "2026-11-24T11:02:01Z")))
        XCTAssertEqual(reading.monthly, .init(remaining: 0, resetAt: dates.date(from: "2026-12-01T03:02:01Z")))
    }

    func testMonthOnlySurvivesMalformedNeighborsAndMissingReset() throws {
        let response = Data(#"{"usage":{"rolling":{"percent":false},"weekly":{"percent":125},"monthly":{"percent":6.9,"resetsAt":42}}}"#.utf8)
        let reading = try XCTUnwrap(OpenCodeGoUsage.parse(response))
        XCTAssertNil(reading.rolling)
        XCTAssertNil(reading.weekly)
        XCTAssertEqual(reading.monthly, .init(remaining: 93, resetAt: nil))
        XCTAssertNil(OpenCodeGoUsage.parse(Data(#"{"usage":{"rolling":{"percent":"0"}}}"#.utf8)))
        XCTAssertNil(OpenCodeGoUsage.parse(Data(#"{"usage":{}}"#.utf8)))
    }

    func testReuseReadsOnlyTheGoAPIKeyAndTracksRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")

        try Data(#"{"opencode":{"type":"api","key":"unrelated"},"opencode-go":{"type":"oauth","key":"oauth"}}"#.utf8).write(to: file)
        XCTAssertNil(try OpenCodeGoConfiguration.reusableKey(at: file))
        try Data(#"{"opencode-go":{"type":"api","key":"  fixture-a  "}}"#.utf8).write(to: file)
        let first = try XCTUnwrap(OpenCodeGoConfiguration.reusableKey(at: file))
        XCTAssertEqual(first, "fixture-a")
        try Data(#"{"opencode-go":{"type":"api","key":"fixture-b"}}"#.utf8).write(to: file)
        let second = try XCTUnwrap(OpenCodeGoConfiguration.reusableKey(at: file))
        XCTAssertEqual(second, "fixture-b")
        let firstID = OpenCodeGoConfiguration.sourceID(mode: .reuse, key: first)
        XCTAssertFalse(firstID.contains(first))
        XCTAssertNotEqual(firstID, OpenCodeGoConfiguration.sourceID(mode: .reuse, key: second))
        XCTAssertNotEqual(firstID, OpenCodeGoConfiguration.sourceID(mode: .personalKey, key: first))
        XCTAssertNotEqual(firstID, OpenCodeGoConfiguration.sourceID(mode: .reuse, key: nil))

        try Data(#"{"opencode-go":{"type":"api","key":"fixture\ninjected"}}"#.utf8).write(to: file)
        XCTAssertNil(try OpenCodeGoConfiguration.reusableKey(at: file))
    }

    @MainActor
    func testUsageRequestUsesTheFixedEndpointAndMatchingSessionHeaders() async throws {
        let result = await OpenCodeGoUsage.fetch(key: "fixture-key") { request in
            XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/inference/go/v1/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertFalse(request.httpShouldHandleCookies)
            let session = try XCTUnwrap(request.value(forHTTPHeaderField: "x-opencode-session"))
            XCTAssertEqual(session, request.value(forHTTPHeaderField: "x-opencode-session-id"))
            XCTAssertNotNil(session.range(of: #"^ses_[0-9a-f]{12}[a-zA-Z0-9]{14}$"#, options: .regularExpression))
            let reply = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                                      httpVersion: nil, headerFields: nil))
            return (Data(#"{"usage":{"monthly":{"percent":37}}}"#.utf8), reply)
        }
        XCTAssertEqual(result, .reading(.init(rolling: nil, weekly: nil, monthly: .init(remaining: 63, resetAt: nil))))
    }

    @MainActor
    func testAuthenticationTimeoutAndBackoffResponses() async {
        for (code, headers, expected): (Int, [String: String], OpenCodeGoUsage.Result) in [
            (401, [:], .failed(note: "OpenCode Go rejected the key")),
            (403, [:], .failed(note: "This key cannot read OpenCode Go usage")),
            (429, ["Retry-After": "57"], .failed(note: OpenCodeGoUsage.unavailableNote, cooldown: 57)),
            (429, [:], .failed(note: OpenCodeGoUsage.unavailableNote, cooldown: 900)),
            (200, [:], .failed(note: OpenCodeGoUsage.unavailableNote)),
            (500, [:], .failed(note: OpenCodeGoUsage.unavailableNote)),
        ] {
            let actual = await OpenCodeGoUsage.fetch(key: "fixture-key") { request in
                let reply = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: code,
                                                          httpVersion: nil, headerFields: headers))
                return (Data(), reply)
            }
            XCTAssertEqual(actual, expected, "HTTP \(code)")
        }
        let timeout = await OpenCodeGoUsage.fetch(key: "fixture-key") { _ in throw URLError(.timedOut) }
        XCTAssertEqual(timeout, .failed(note: OpenCodeGoUsage.unavailableNote))
    }

    @MainActor
    func testIsolatedRefreshAndMonthlySnapshotCredentialScoping() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] != nil,
                          "Run with scripts/test.sh for isolated credentials and snapshot storage")
        let source = LiveUsageDataSource()
        XCTAssertEqual(OpenCodeGoConfiguration.mode, .disabled)
        XCTAssertNil(source.openCodeGoCachedStatus())
        let disabledFetch = await source.fetchOpenCodeGo()
        XCTAssertNil(disabledFetch)
        XCTAssertThrowsError(try OpenCodeGoConfiguration.setMode(.personalKey, personalKey: "fixture-key"))

        let name = OpenCodeGoConfiguration.name
        defer { try? FileManager.default.removeItem(at: source.snapshotURL(for: name)) }
        let id = OpenCodeGoConfiguration.sourceID(mode: .reuse, key: "fixture-key")
        let reset = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded(.down))
        let card = ServiceStatus(name: name, iconName: OpenCodeGoConfiguration.iconName,
                                 sessionResetAt: nil, weeklyResetAt: nil,
                                 monthlyResetAt: reset, monthlyRemainingPercent: 77,
                                 models: [], isAvailable: true, statusNote: nil).withSourceID(id)
        source.saveSnapshot(card)
        let cached = try XCTUnwrap(source.loadOpenCodeGoSnapshot(sourceID: id, note: "snapshot"))
        XCTAssertEqual(cached.monthlyRemainingPercent, 77)
        XCTAssertEqual(cached.monthlyResetAt, reset)
        XCTAssertTrue(cached.isStale)
        XCTAssertNil(source.loadOpenCodeGoSnapshot(sourceID: "different", note: "snapshot"))
    }
}
