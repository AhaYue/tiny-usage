import SwiftUI

#if DEBUG
// Xcode: open the tiny-usage workspace, pick the TinyUsageCore scheme, open this file,
// and the canvas (⌥⌘↩) shows these. Same fixtures as `scripts/preview.sh`.
#Preview("面板 · 演示数据") { PreviewFixtures.panel(PreviewFixtures.store()) }
#Preview("面板 · 浅色") { PreviewFixtures.panel(PreviewFixtures.store()).preferredColorScheme(.light) }
#Preview("面板 · 首次使用") {
    PreviewFixtures.panel(PreviewFixtures.store([PreviewFixtures.emptyClaude]), capture: .waiting)
}
#Preview("设置") {
    ScrollView { PreviewFixtures.settingsFace() }
        .frame(width: PopoverMetrics.width, height: 620)
        .background(PopoverBackdrop())
}
#Preview("设置 · 菜单栏只显示 Codex") {
    ScrollView { PreviewFixtures.settingsFace(menuBarProviders: [.codex]) }
        .frame(width: PopoverMetrics.width, height: 620)
        .background(PopoverBackdrop())
}
#Preview("服务卡片") {
    VStack(spacing: 11) {
        ForEach(DemoData.services()) { ServiceCard(service: $0, now: Date()) }
    }
    .padding(11).frame(width: PopoverMetrics.width).background(PopoverBackdrop())
}
#Preview("关于") { AboutView(version: "预览").frame(width: 460, height: 560) }
#Preview("面板 · 缓存用量") {
    PreviewFixtures.panel(PreviewFixtures.store([PreviewFixtures.savedClaude()]), capture: .waiting)
}
#Preview("面板 · OpenCode Go") {
    PreviewFixtures.panel(PreviewFixtures.store(DemoData.services() + [PreviewFixtures.openCodeGo()]))
}
#Preview("OpenCode Go · 缓存用量") {
    PreviewFixtures.panel(PreviewFixtures.store([PreviewFixtures.openCodeGo(cached: true)]))
}
#Preview("设置 · 自定义菜单栏配色") {
    ScrollView { PreviewFixtures.settingsFace(colorMode: .custom) }
        .frame(width: PopoverMetrics.width, height: 620)
        .background(PopoverBackdrop())
}
#endif
