import AppKit
import SwiftUI

/// Explicit synthetic data for preview and profiling; never mixed with live snapshots.
enum DemoData {
    static func services(now: Date = Date()) -> [ServiceStatus] {
        let source = LiveUsageDataSource()
        func iso(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)) }
        let claudeRoot: [String: Any] = [
            "cedar_ember": ["grants": [
                ["resets_left": 2, "resets_total": 2, "paused": false, "usable_now": true,
                 "ends_at": iso(3 * 86_400 + 18 * 3600), "scope": ["model": ["display_name": "Fable"]]],
                ["resets_left": 1, "resets_total": 1, "paused": false, "usable_now": true,
                 "ends_at": iso(27 * 86_400 + 8 * 3600), "scope": "weekly"]
            ]]
        ]
        let claudeGrants = source.claudeResetGrantRows(claudeRoot, now: now)
        let codexRoot: [String: Any] = ["credits": [
            ["status": "available", "expires_at": iso(17 * 86_400 + 6 * 3600)],
            ["status": "available", "expires_at": iso(17 * 86_400 + 6 * 3600)],
            ["status": "available", "expires_at": iso(18 * 86_400 + 8 * 3600)],
            ["status": "available", "expires_at": iso(29 * 86_400 + 8 * 3600)]
        ]]
        let codexGrants = source.codexResetCreditRows(fromRoot: codexRoot, now: now)
        return [
            ServiceStatus(name: "Claude", iconName: "claude",
                          sessionResetAt: now.addingTimeInterval(4.5 * 3600), weeklyResetAt: now.addingTimeInterval(6 * 86_400 + 22 * 3600),
                          sessionRemainingPercent: 83, weeklyRemainingPercent: 99, weeklyWindowSeconds: 604_800,
                          models: [ModelStatus(name: "Fable", remainingPercent: 100,
                                               resetAt: now.addingTimeInterval(6 * 86_400 + 22 * 3600), window: .weekly)] + claudeGrants,
                          isAvailable: true, statusNote: "Demo data",
                          account: AccountInfo(plan: "Max", email: nil), observedAt: now),
            ServiceStatus(name: "Codex", iconName: "codex",
                          sessionResetAt: now.addingTimeInterval(4 * 3600 + 34 * 60), weeklyResetAt: now.addingTimeInterval(4 * 86_400 + 17 * 3600),
                          sessionRemainingPercent: 89, weeklyRemainingPercent: 41, weeklyWindowSeconds: 604_800,
                          models: codexGrants, isAvailable: true, statusNote: "Demo data",
                          account: AccountInfo(plan: "Plus", email: nil), observedAt: now)
        ]
    }
}

/// Synthetic inputs shared by `#Preview` blocks and `--render-preview`. Nothing here reads or
/// changes settings, credentials or real quota files.
@MainActor
enum PreviewFixtures {
    static func settings(capture: ClaudeLocalCaptureState = .ready, didAuthorize: Bool = true,
                         menuBarProviders: Set<MenuBarProvider> = MenuBarProvider.all) -> PopoverSettings {
        PopoverSettings(
            launchAtLogin: { false }, toggleLaunchAtLogin: {},
            localCaptureState: { capture },
            showRemaining: { true }, setShowRemaining: { _ in }, menuStyle: { 0 }, setMenuStyle: { _ in },
            menuBarProviders: { menuBarProviders }, setMenuBarProviders: { _ in },
            refreshMode: { 0 }, setRefreshMode: { _ in },
            authorize: {}, didAuthorize: { didAuthorize }, refresh: {},
            openDataFolder: {}, about: {}, quit: {})
    }

    static func store(_ services: [ServiceStatus] = DemoData.services()) -> UsageStore {
        UsageStore(services: services)
    }

    static func openCodeGo(now: Date = Date(), cached: Bool = false) -> ServiceStatus {
        ServiceStatus(name: OpenCodeGoConfiguration.name, iconName: OpenCodeGoConfiguration.iconName,
                      sessionResetAt: cached ? nil : now.addingTimeInterval(45 * 60),
                      weeklyResetAt: now.addingTimeInterval(39 * 3600),
                      sessionRemainingPercent: cached ? nil : 65, weeklyRemainingPercent: 30,
                      weeklyWindowSeconds: 7 * 86_400, monthlyResetAt: now.addingTimeInterval(19 * 86_400),
                      monthlyRemainingPercent: 78, models: [], isAvailable: true,
                      statusNote: cached ? "snapshot" : "OpenCode Go usage", isStale: cached,
                      observedAt: cached ? now.addingTimeInterval(-3600) : now)
    }

    static func settingsFace(menuBarProviders: Set<MenuBarProvider> = MenuBarProvider.all) -> some View {
        SettingsFace(settings: settings(menuBarProviders: menuBarProviders),
                     language: .constant(AppLanguage.current), onBack: {})
    }

    static let emptyClaude = ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: nil,
                                           weeklyResetAt: nil, models: [], isAvailable: false,
                                           statusNote: "claude token missing")

    static func savedClaude(now: Date = Date()) -> ServiceStatus {
        let models = DemoData.services(now: now).first?.models ?? []
        return ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: now.addingTimeInterval(1800),
                             weeklyResetAt: now.addingTimeInterval(86400), sessionRemainingPercent: 0,
                             weeklyRemainingPercent: 81, models: models, isAvailable: true,
                             statusNote: "snapshot", isStale: true, observedAt: now.addingTimeInterval(-7200))
    }

    /// First-run and recovery states: (file name, Claude service, local capture state).
    static func recoveryExamples(now: Date = Date()) -> [(String, ServiceStatus, ClaudeLocalCaptureState)] {
        [
            ("waiting-first-data", emptyClaude, .waiting),
            ("waiting-update", emptyClaude, .outdated),
            ("saved-data", savedClaude(now: now), .waiting),
            ("login-expired", emptyClaude.withStatusNote("token expired — open Claude Code"), .waiting),
            ("rate-limited", emptyClaude.withStatusNote("claude http 429"), .waiting)
        ]
    }

    /// The real popover with a fixed size, for previews (AppKit sizes it in the app).
    static func panel(_ store: UsageStore, capture: ClaudeLocalCaptureState = .ready) -> some View {
        PopoverView(store: store, onDismiss: {}, onContentHeightChange: { _ in },
                    settings: settings(capture: capture))
            .frame(width: PopoverMetrics.width, height: 620)
    }
}

/// `--render-preview <dir>/name.png` → PNGs of the real views, dark and light, without the .app:
/// `scripts/preview.sh` builds the bare binary and runs this in a couple of seconds.
@MainActor
enum PreviewRenderer {
    static func render(store: UsageStore, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filter = ProcessInfo.processInfo.environment["PREVIEW_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        func wanted(_ name: String) -> Bool { filter.map { name.contains($0) } ?? true }
        let now = Date()

        // The real popover, quota face. Its height is whatever it reports, as in the app.
        if wanted("panel") {
            for dark in [true, false] {
                var height: CGFloat = 0
                let view = PopoverView(store: store, onDismiss: {}, onContentHeightChange: { height = $0 },
                                       settings: PreviewFixtures.settings())
                snapshot(view, dark: dark, to: directory.appendingPathComponent("panel-\(dark ? "dark" : "light").png"),
                         measuredHeight: { height })
            }
        }
        // The settings face (the back of the card).
        let settingsExamples: [(String, Set<MenuBarProvider>)] = [
            ("settings", MenuBarProvider.all), ("settings-codex-only", [.codex])
        ]
        for (name, providers) in settingsExamples where wanted(name) {
            for dark in [true, false] {
                snapshot(PreviewFixtures.settingsFace(menuBarProviders: providers).padding(.vertical, 4)
                            .background(PopoverBackdrop()),
                         dark: dark, to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        // First-run and recovery cards.
        for (name, service, capture) in PreviewFixtures.recoveryExamples(now: now) where wanted(name) {
            let recovery = ClaudeUsageGuidance.resolve(service: service, capture: capture).map {
                ClaudeUsageHelp(guidance: $0, refreshing: false, authorize: {}, refresh: {})
            }
            let settings = PreviewFixtures.settings(capture: capture)
            for dark in [true, false] {
                let content = Group {
                    if service.isAvailable {
                        ServiceCard(service: service, now: now, recovery: recovery)
                    } else {
                        SetupCard(service: service, settings: settings, recovery: recovery)
                    }
                }
                .padding(11)
                .background(PopoverBackdrop())
                snapshot(content, dark: dark, to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        if wanted("menu-bar") {
            let services = store.services + [PreviewFixtures.openCodeGo(now: now)]
            let image = MenuBarRenderer.image(services: services, style: .both, remaining: true, now: now)
            if let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("menu-bar.png"))
            }
        }
        for cached in [false, true] {
            let name = cached ? "opencode-cached" : "opencode-panel"
            guard wanted(name) else { continue }
            let store = PreviewFixtures.store(DemoData.services(now: now) + [PreviewFixtures.openCodeGo(now: now, cached: cached)])
            for dark in [true, false] {
                snapshot(PreviewFixtures.panel(store), dark: dark,
                         to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// Hosts the view in an offscreen window (ImageRenderer drops native AppKit controls such as
    /// buttons and pickers) and writes a 2x PNG. A solid backdrop stands in for the desktop blur.
    private static func snapshot<V: View>(_ view: V, dark: Bool, to url: URL,
                                          measuredHeight: (() -> CGFloat)? = nil) {
        let width = PopoverMetrics.width
        let host = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
                                      : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        // Let SwiftUI lay out and report preference-driven heights before sizing.
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let reported = measuredHeight?() ?? 0
        let height = reported > 0 ? min(reported, PopoverMetrics.maxHeight) : host.fittingSize.height
        window.setContentSize(NSSize(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let rect = host.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        window.backgroundColor.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
        host.cacheDisplay(in: rect, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        window.close()
    }
}
