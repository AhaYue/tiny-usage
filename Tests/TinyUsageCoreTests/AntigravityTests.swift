import Foundation
import XCTest
@testable import TinyUsageCore

final class AntigravityTests: XCTestCase {
    func testParseCLIUsageReportWithGeminiAndClaudeGPTGroups() throws {
        let json = Data("""
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "duration_seconds": 0,
          "num_turns": 0,
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "window": "weekly",
                      "remaining_fraction": 0.9700822830200195,
                      "reset_time": "2026-12-04T03:52:45Z"
                    },
                    {
                      "id": "gemini-5h",
                      "window": "5h",
                      "remaining_fraction": 0.8803291916847229,
                      "reset_time": "2026-11-27T08:52:45Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "window": "weekly",
                      "remaining_fraction": 0.9990471601486206,
                      "reset_time": "2026-12-04T04:00:42Z"
                    },
                    {
                      "id": "3p-5h",
                      "window": "5h",
                      "remaining_fraction": 0.002,
                      "reset_time": "2026-11-27T09:00:42Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """.utf8)

        let now = Date(timeIntervalSince1970: 1_795_700_000)
        let reading = try XCTUnwrap(AntigravityCLIUsage.parseCLIReport(json, now: now))
        let iso = ISO8601DateFormatter()

        XCTAssertEqual(reading.sourceNote, AntigravityUsage.cliSourceNote)
        XCTAssertEqual(reading.primary.name, "Gemini")
        XCTAssertEqual(reading.primary.session, .init(remaining: 88, resetAt: iso.date(from: "2026-11-27T08:52:45Z")))
        XCTAssertEqual(reading.primary.weekly, .init(remaining: 97, resetAt: iso.date(from: "2026-12-04T03:52:45Z")))

        XCTAssertEqual(reading.extras.count, 1)
        XCTAssertEqual(reading.extras[0].name, "Claude + GPT")
        XCTAssertEqual(reading.extras[0].session, .init(remaining: 1, resetAt: iso.date(from: "2026-11-27T09:00:42Z")))
        XCTAssertEqual(reading.extras[0].weekly, .init(remaining: 100, resetAt: iso.date(from: "2026-12-04T04:00:42Z")))
    }

    func testParseCLIUsageReportRejectsFailureAndSkipsDisabledBuckets() throws {
        let failed = Data(#"{"status":"ERROR","command":{"name":"usage","data":{"groups":[]}}}"#.utf8)
        XCTAssertNil(AntigravityCLIUsage.parseCLIReport(failed))

        let exhausted = Data("""
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.0, "reset_time": "2026-11-27T08:52:45Z"},
                    {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.5, "disabled": true}
                  ]
                }
              ]
            }
          }
        }
        """.utf8)
        let reading = try XCTUnwrap(AntigravityCLIUsage.parseCLIReport(exhausted))
        XCTAssertEqual(reading.primary.session?.remaining, 0)
        XCTAssertNil(reading.primary.weekly)
    }

    func testParseLocalSummaryHandlesProtoZeroValueOmissionAndUserStatus() throws {
        let summary = Data("""
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-11-27T08:52:45Z"},
                  {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.64, "resetTime": "2026-12-04T03:52:45Z"}
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.5, "resetTime": "2026-11-27T09:00:42Z"}
                ]
              }
            ]
          }
        }
        """.utf8)
        let reading = try XCTUnwrap(AntigravityLocalRPC.parseSummary(summary))
        XCTAssertEqual(reading.sourceNote, AntigravityUsage.localSourceNote)
        XCTAssertEqual(reading.primary.session?.remaining, 0)
        XCTAssertEqual(reading.primary.weekly?.remaining, 64)
        XCTAssertEqual(reading.extras.first?.name, "Claude + GPT")
        XCTAssertEqual(reading.extras.first?.session?.remaining, 50)

        let userStatus = Data("""
        {
          "userStatus": {
            "email": "dev@example.com",
            "planStatus": { "planInfo": { "planName": "Google AI Pro" } }
          }
        }
        """.utf8)
        let account = try XCTUnwrap(AntigravityLocalRPC.parseUserStatus(userStatus))
        XCTAssertEqual(account.email, "dev@example.com")
        XCTAssertEqual(account.plan, "Google AI Pro")
    }

    func testParseProcessesAndLoopbackPorts() {
        let psOutput = """
          101 /Applications/Other.app/Contents/MacOS/language_server --csrf_token wrong
          202 /Applications/Antigravity.app/Contents/Resources/app/bin/language_server_macos_arm --csrf_token=tok-eq-123 --extension_server_port 5000
          303 /Users/me/Applications/Antigravity.app/Contents/MacOS/language_server --csrf_token tok-space-456
          404 /Applications/Antigravity.app/Contents/MacOS/language_server --no_token
        """
        let servers = AntigravityLocalRPC.parseServers(fromProcessList: psOutput)
        XCTAssertEqual(servers, [
            .init(pid: 202, csrfToken: "tok-eq-123"),
            .init(pid: 303, csrfToken: "tok-space-456"),
        ])

        let lsofOutput = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language  202   me   12u  IPv4 0x1234      0t0  TCP 127.0.0.1:41234 (LISTEN)
        language  202   me   13u  IPv6 0x1235      0t0  TCP [::1]:41235 (LISTEN)
        language  202   me   14u  IPv4 0x1236      0t0  TCP *:9999 (LISTEN)
        language  202   me   15u  IPv4 0x1237      0t0  TCP 127.0.0.1:41234->127.0.0.1:50000 (ESTABLISHED)
        """
        XCTAssertEqual(AntigravityLocalRPC.parseLoopbackPorts(fromLsof: lsofOutput), [41234, 41235])
    }

    func testInitialEnablementAutoDetectsOnceThenRespectsManualToggle() throws {
        let suite = "AntigravityConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var probes = 0
        let first = AntigravityConfiguration.resolveEnabled(defaults: defaults) {
            probes += 1
            return false
        }
        XCTAssertFalse(first)
        XCTAssertEqual(probes, 1)

        // Second check reads persisted value without re-probing.
        let second = AntigravityConfiguration.resolveEnabled(defaults: defaults) {
            probes += 1
            return true
        }
        XCTAssertFalse(second)
        XCTAssertEqual(probes, 1)

        // Manual enable wins permanently.
        AntigravityConfiguration.setEnabled(true, defaults: defaults)
        XCTAssertTrue(AntigravityConfiguration.resolveEnabled(defaults: defaults) { false })

        // Fresh defaults with installed binary auto-enables.
        let suite2 = "AntigravityConfigTests.\(UUID().uuidString)"
        let defaults2 = try XCTUnwrap(UserDefaults(suiteName: suite2))
        defer { defaults2.removePersistentDomain(forName: suite2) }
        XCTAssertTrue(AntigravityConfiguration.resolveEnabled(defaults: defaults2) { true })
    }

    func testCLIVersionGateAndFreshnessCache() async throws {
        XCTAssertEqual(AntigravityCLIUsage.parseVersion("1.5.18\n"), .init(major: 1, minor: 5, patch: 18))
        XCTAssertEqual(AntigravityCLIUsage.parseVersion("agy v1.1.11 (darwin/arm64)"), .init(major: 1, minor: 1, patch: 11))
        XCTAssertNil(AntigravityCLIUsage.parseVersion("unknown"))

        final class Counter: @unchecked Sendable {
            var usageCalls = 0
        }
        let counter = Counter()
        let report = Data("""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-5h","window":"5h","remaining_fraction":0.8,"reset_time":"2099-01-01T00:00:00Z"}
          ]}
        ]}}}
        """.utf8)

        let oldCLI = AntigravityCLIUsage(
            locateBinary: { "/fake/agy" },
            runVersion: { _, _ in Data("1.1.10\n".utf8) },
            runUsage: { _, _ in counter.usageCalls += 1; return report }
        )
        let rejected = await oldCLI.read(home: URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(rejected)
        XCTAssertEqual(counter.usageCalls, 0)

        let newCLI = AntigravityCLIUsage(
            locateBinary: { "/fake/agy" },
            runVersion: { _, _ in Data("1.5.18\n".utf8) },
            runUsage: { _, _ in counter.usageCalls += 1; return report }
        )
        let t0 = Date()
        let first = await newCLI.read(home: URL(fileURLWithPath: "/tmp"), now: t0)
        let cached = await newCLI.read(home: URL(fileURLWithPath: "/tmp"), now: t0.addingTimeInterval(60))
        let forced = await newCLI.read(home: URL(fileURLWithPath: "/tmp"), now: t0.addingTimeInterval(60), force: true)
        XCTAssertEqual(first?.primary.session?.remaining, 80)
        XCTAssertEqual(cached?.primary.session?.remaining, 80)
        XCTAssertEqual(forced?.primary.session?.remaining, 80)
        XCTAssertEqual(counter.usageCalls, 2)
    }

    func testSubprocessBlocksBrowserLaunchersAndRunsInEmptyTempDirectory() async throws {
        let script = """
        pwd
        echo "AUTO=$AGY_CLI_DISABLE_AUTO_UPDATE"
        echo "BROWSER=$BROWSER"
        which open
        open https://example.com && echo "OPEN_OK" || echo "OPEN_BLOCKED"
        ls -A | sort | tr '\\n' ','
        """
        let rawOutput = await AntigravitySubprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: [
                "PATH": "/usr/bin:/bin",
                "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
            ],
            timeout: .seconds(5),
            blockBrowserLaunchers: true
        )
        let output = try XCTUnwrap(rawOutput)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("AUTO=true"))
        XCTAssertTrue(text.contains("OPEN_BLOCKED"))
        XCTAssertFalse(text.contains("OPEN_OK"))
        XCTAssertTrue(text.contains("tiny-usage-agy-"))
        // Only our open/xdg-open stubs and stdout capture exist in the isolated working directory.
        XCTAssertTrue(text.contains("open,stdout,xdg-open,"))
    }

    func testSnapshotRoundTripPreservesPrimaryAndExtraPanels() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] != nil,
                          "Run with scripts/test.sh for isolated snapshot storage")
        let source = LiveUsageDataSource()
        defer { try? FileManager.default.removeItem(at: source.snapshotURL(for: AntigravityConfiguration.name)) }

        let now = Date()
        let sessionReset = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 3600).rounded(.down))
        let weeklyReset = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 86_400).rounded(.down))
        let reading = AntigravityUsage.Reading(
            primary: .init(name: "Gemini",
                           session: .init(remaining: 88, resetAt: sessionReset),
                           weekly: .init(remaining: 97, resetAt: weeklyReset)),
            extras: [
                .init(name: "Claude + GPT",
                      session: .init(remaining: 99, resetAt: sessionReset),
                      weekly: .init(remaining: 100, resetAt: weeklyReset)),
            ],
            account: AccountInfo(plan: "Google AI Pro", email: "dev@example.com", id: "dev@example.com"),
            sourceNote: AntigravityUsage.localSourceNote,
            observedAt: now
        )

        let card = source.antigravityServiceStatus(from: reading)
        source.saveSnapshot(card)

        let restored = try XCTUnwrap(source.loadSnapshot(for: AntigravityConfiguration.name,
                                                         iconName: AntigravityConfiguration.iconName))
        XCTAssertEqual(restored.sessionRemainingPercent, 88)
        XCTAssertEqual(restored.weeklyRemainingPercent, 97)
        XCTAssertEqual(restored.account?.plan, "Google AI Pro")
        XCTAssertEqual(restored.account?.email, "dev@example.com")
        XCTAssertEqual(restored.models.count, 2)
        XCTAssertEqual(restored.models[0].name, "Claude + GPT")
        XCTAssertEqual(restored.models[0].groupLabel, AntigravityConfiguration.extraLimitGroup)
        XCTAssertEqual(restored.models[0].window, .session)
        XCTAssertEqual(restored.models[1].window, .weekly)
    }
}
