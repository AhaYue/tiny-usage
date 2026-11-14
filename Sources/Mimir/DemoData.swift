import AppKit
import SwiftUI

/// Explicit synthetic data for preview and profiling; never mixed with live snapshots.
enum DemoData {
    static func services(now: Date = Date()) -> [ServiceStatus] {
        let source = LiveUsageDataSource()
        func iso(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)) }
        let claudeGrants = source.claudeResetGrantRows([
            "cedar_ember": ["grants": [
                ["resets_left": 2, "resets_total": 2, "paused": false, "usable_now": true,
                 "ends_at": iso(3 * 86_400 + 18 * 3600), "scope": ["model": ["display_name": "Fable"]]],
                ["resets_left": 1, "resets_total": 1, "paused": false, "usable_now": true,
                 "ends_at": iso(27 * 86_400 + 8 * 3600), "scope": "weekly"]
            ]]
        ], now: now)
        let codexGrants = source.codexResetCreditRows(fromRoot: ["credits": [
            ["status": "available", "expires_at": iso(17 * 86_400 + 6 * 3600)],
            ["status": "available", "expires_at": iso(17 * 86_400 + 6 * 3600)],
            ["status": "available", "expires_at": iso(18 * 86_400 + 8 * 3600)],
            ["status": "available", "expires_at": iso(29 * 86_400 + 8 * 3600)]
        ]], now: now)
        return [
            ServiceStatus(name: "Claude", iconName: "claude",
                          sessionResetAt: now.addingTimeInterval(4.5 * 3600), weeklyResetAt: now.addingTimeInterval(6 * 86_400 + 22 * 3600),
                          sessionRemainingPercent: 83, weeklyRemainingPercent: 99, weeklyWindowSeconds: 604_800,
                          models: [ModelStatus(name: "Fable", remainingPercent: 100,
                                               resetAt: now.addingTimeInterval(6 * 86_400 + 22 * 3600), window: .weekly)] + claudeGrants,
                          isAvailable: true, statusNote: "演示数据",
                          account: AccountInfo(plan: "Max", email: nil), observedAt: now),
            ServiceStatus(name: "Codex", iconName: "codex",
                          sessionResetAt: now.addingTimeInterval(4 * 3600 + 34 * 60), weeklyResetAt: now.addingTimeInterval(4 * 86_400 + 17 * 3600),
                          sessionRemainingPercent: 89, weeklyRemainingPercent: 41, weeklyWindowSeconds: 604_800,
                          models: codexGrants, isAvailable: true, statusNote: "演示数据",
                          account: AccountInfo(plan: "Plus", email: nil), observedAt: now)
        ]
    }
}

@MainActor
enum PreviewRenderer {
    static func render(store: UsageStore, to url: URL) {
        let now = Date()
        for dark in [true, false] {
            let content = VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tiny Usage").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text("演示预览").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.top, 8)
                ForEach(store.services.sortedByDisplayOrder()) { service in ServiceCard(service: service, now: now) }
                Text("基于 Mimir · 剩余配额 / 重置卡 / 到期时间")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 7)
            }
            .padding(12)
            .frame(width: PopoverMetrics.width)
            .background(dark ? Color(nsColor: .init(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 1)) : Color(nsColor: .init(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1)))
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let path = url.deletingPathExtension().path + (dark ? "-dark.png" : "-light.png")
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
        let image = MenuBarRenderer.image(services: store.services, style: .both, remaining: true, now: now)
        if let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url.deletingLastPathComponent().appendingPathComponent("menu-bar.png"))
        }
    }
}
