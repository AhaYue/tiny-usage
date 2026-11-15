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
    ScrollView { SettingsFace(settings: PreviewFixtures.settings(), onBack: {}) }
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
#endif
