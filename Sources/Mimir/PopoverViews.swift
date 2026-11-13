import AppKit
import MimirShared
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onDismiss: () -> Void
    /// Reports the measured content height so AppKit can size the popover.
    /// Plain callback on purpose — see the note at the construction site.
    let onContentHeightChange: (CGFloat) -> Void
    /// Everything the settings side needs. Passed in rather than reached for: the view stays a
    /// view, and AppKit keeps owning the login item, the hook and the quit.
    let settings: PopoverSettings

    /// Which face is up. The settings live on the back of the same card — flipping to them keeps
    /// the popover one surface instead of dropping a second window on top of it.
    @State private var showingSettings = false
    /// Each face's natural height. The panel takes the height of the face that's up, so the
    /// settings are never clipped under a short quota face nor padded out under a tall one.
    @State private var quotaHeight: CGFloat = 0
    @State private var settingsHeight: CGFloat = 0
    /// The panel stops at the screen's height; when cards run past it, the bottom edge fades so the
    /// rest reads as "scroll for more" rather than as the end of the list.
    @State private var moreBelow = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack {
                PopoverBackdrop()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                // Both faces stay mounted so each keeps its state; only the one up is shown. Each is
                // its own scroll view, so neither can push the other out of the panel — a fixed-height
                // settings list in a ZStack with the quotas once overflowed a short panel and was
                // centred into it, clipping the header off the top.
                ZStack(alignment: .top) {
                    quotaFace(now: context.date)
                        .opacity(showingSettings ? 0 : 1)
                        .allowsHitTesting(!showingSettings)
                    ScrollView(showsIndicators: false) {
                        SettingsFace(settings: settings, onBack: { flip() })
                            .measuringHeight { settingsHeight = $0; reportHeight() }
                    }
                    .opacity(showingSettings ? 1 : 0)
                    .allowsHitTesting(showingSettings)
                }
            }
        }
    }

    /// Straight swap, no animation: the settings are a place you go, not a trick the card does.
    private func flip() { showingSettings.toggle(); reportHeight() }

    private func reportHeight() {
        onContentHeightChange(showingSettings ? settingsHeight : quotaHeight)
    }

    @ViewBuilder
    private func quotaFace(now: Date) -> some View {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        BrandingHeader(onGear: { flip() }, refreshing: store.isRefreshing, onRefresh: settings.refresh)
                        notificationBanner
                        contentView(now: now)
                        MilowdaMark(version: settings.version)
                    }
                    .padding(.vertical, 4)
                    .measuringHeight { quotaHeight = $0; reportHeight() }
                }
                .modifier(MoreBelowTracker(moreBelow: $moreBelow))
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(moreBelow ? 0 : 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 36)
                    }
                    .animation(.easeOut(duration: 0.2), value: moreBelow)
                }
    }

    private static func supported(_ service: ServiceStatus) -> Bool {
        service.name == "Claude" || service.name.hasPrefix("Claude ") ||
        service.name == "Codex" || service.name.hasPrefix("Codex ")
    }

    /// Primary Claude/Codex services that returned nothing at all — no live data, no snapshot. They
    /// used to vanish from the panel, leaving no hint that Claude simply wasn't authorized yet; now
    /// they get a compact card with the reason and a way to fix it. Extra accounts and the optional
    /// Desktop fallback card stay hidden: their absence isn't something the user has to act on.
    static func needsSetup(_ services: [ServiceStatus]) -> [ServiceStatus] {
        services
            .filter { ($0.name == "Claude" || $0.name == "Codex") && !$0.isAvailable && !$0.isStale && !$0.dataUnavailable }
            .sortedByDisplayOrder()
    }

    /// Show live services and stale snapshots; hide services that have no data at all.
    /// A stale Antigravity snapshot (isStale) survives the filter so the user still sees
    /// the last-known reading when the IDE is closed, instead of the card vanishing.
    @ViewBuilder
    private func contentView(now: Date) -> some View {
        // Shared with the menu-bar dots so a dot can never line up with the wrong card.
        let visible = store.services
            .filter { ($0.isAvailable || $0.isStale) && Self.supported($0) }
            .sortedByDisplayOrder()
        let setup = Self.needsSetup(store.services)
        if !visible.isEmpty || !setup.isEmpty {
            // Each provider is its own card — the card border carries the hierarchy, so there are
            // no dividers or rails between them (design v2.9).
            VStack(spacing: 11) {
                ForEach(visible) { service in
                    ServiceCard(service: service, now: now)
                }
                ForEach(setup) { service in
                    SetupCard(service: service, settings: settings)
                }
            }
            .padding(.horizontal, 11)
            .padding(.top, 11)
            .padding(.bottom, 4)
        } else if store.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PopoverMetrics.placeholderHeight)
        } else {
            emptyState
        }
    }

    /// General alert area (not tied to a model row): surfaces providers whose live source has been
    /// unreachable too long, with the actionable hint. Hidden when there's nothing to report.
    @ViewBuilder
    private var notificationBanner: some View {
        let down = store.services
            .filter { Self.supported($0) && $0.dataUnavailable && !store.dismissedUnavailable.contains($0.name) }
            .sortedByDisplayOrder()
        if !down.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(down) { svc in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(svc.titleWithAccount)：无法获取最新数据")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { AppTarget.open(svc.name) }
                            .pointingHandCursor()
                        // Dismissing is per-service and lasts only until that service reports data
                        // again (see UsageStore.forgetRecoveredDismissals), so hiding this notice
                        // can't permanently mute a provider that is genuinely broken.
                        Button { store.dismissUnavailable(svc.name) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.45))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help(String(localized: "popover.unavailable.dismiss"))
                        .accessibilityLabel(String(localized: "popover.unavailable.dismiss"))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
            Text("暂无 Claude 或 Codex 用量数据")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("授权凭据", action: settings.authorizeCredentials)
                Button("刷新", action: settings.refresh)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: PopoverMetrics.placeholderHeight)
        .padding(.horizontal, 8)
    }
}

/// What the settings face can do. Read the flags through closures rather than copying them in:
/// the login item, the hook and the telemetry flag all live outside SwiftUI, and a copy taken at
/// construction would show yesterday's answer.
struct PopoverSettings {
    var version: String
    var launchAtLogin: () -> Bool
    var toggleLaunchAtLogin: () -> Void
    var claudeHook: () -> Bool
    var toggleClaudeHook: () -> Void
    var desktopFallback: () -> Bool
    var toggleDesktopFallback: () -> Void
    var showRemaining: () -> Bool
    var toggleShowRemaining: () -> Void
    var menuStyle: () -> String
    var cycleMenuStyle: () -> Void
    var refreshMode: () -> String
    var cycleRefreshMode: () -> Void
    var authorizeCredentials: () -> Void
    var refresh: () -> Void
    var openDataFolder: () -> Void
    var quit: () -> Void
}

/// The back of the card: every setting in one list, the way a menu-bar app's settings should read
/// — a row is an icon, what it does, and a line saying what that means. One card, not three: the
/// groups were separating things nobody needed separated.
struct SettingsFace: View {
    let settings: PopoverSettings
    let onBack: () -> Void

    /// Every flag here lives outside SwiftUI — a login item, a file on disk, a defaults key — so
    /// none of them can be observed. They're read into state when the face appears and after each
    /// toggle. An earlier attempt leaned on a counter the body merely mentioned (`let _ = tick`);
    /// the compiler is free to drop a read into `_`, so nothing depended on it and every row kept
    /// showing whatever it showed first — a checkmark beside a setting that was actually off.
    @State private var flags = Flags()
    @State private var hovered: String?

    private struct Flags {
        var launchAtLogin = false
        var claudeHook = false
        var desktopFallback = false
        var showRemaining = false
        var menuStyle = ""
        var refreshMode = ""
    }

    private func reload() {
        flags = Flags(launchAtLogin: settings.launchAtLogin(),
                      claudeHook: settings.claudeHook(),
                      desktopFallback: settings.desktopFallback(),
                      showRemaining: settings.showRemaining(),
                      menuStyle: settings.menuStyle(),
                      refreshMode: settings.refreshMode())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandingHeader(onGear: onBack)

            VStack(spacing: 0) {
                row("power", "登录时启动", "登录后自动打开 AY Usage。",
                    checked: flags.launchAtLogin, action: settings.toggleLaunchAtLogin)
                row("lock.open", "Claude 免提示读取", "通过 Claude Code hook 读取用量。",
                    checked: flags.claudeHook, action: settings.toggleClaudeHook)
                row("desktopcomputer", "桌面版备用来源", "允许使用桌面版数据作为备用来源。",
                    checked: flags.desktopFallback, action: settings.toggleDesktopFallback)
                row("percent", "菜单栏显示剩余额度", "仅影响菜单栏，详情始终显示剩余量。",
                    checked: flags.showRemaining, action: settings.toggleShowRemaining)
                row("menubar.rectangle", "菜单栏样式", flags.menuStyle, action: settings.cycleMenuStyle)
                row("timer", "刷新频率", flags.refreshMode, action: settings.cycleRefreshMode)
                row("key", "授权凭据", nil, action: settings.authorizeCredentials)
                row("arrow.clockwise", "刷新用量", nil, action: settings.refresh)
                row("folder", "打开数据文件夹", nil, action: settings.openDataFolder)
                row("xmark.circle", "退出 AY Usage", nil,
                    shortcut: "⌘Q", action: settings.quit)
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
            // Same insets as the quota cards (contentView), so the card edges line up across faces.
            .padding(.horizontal, 11)
            .padding(.top, 11)
            .padding(.bottom, 4)

            MilowdaMark(version: settings.version)
        }
        .padding(.vertical, 4)
        .onAppear(perform: reload)
    }

    /// One setting. `checked` present makes it a switch (a plain tick, not a control — the row is
    /// the control); absent makes it an action. `shortcut` shows the key that does the same thing
    /// without opening this screen.
    private func row(_ symbol: String, _ title: String, _ subtitle: String?,
                     checked: Bool? = nil, shortcut: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button {
            action()
            reload()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.92))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                }
                Spacer(minLength: 8)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.35))
                }
                if checked == true {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered == title ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovered = $0 ? title : (hovered == title ? nil : hovered) }
    }
}

/// The footer on both faces: which build this is on the left, who made it on the right. The badge
/// moved down here from the header — beside the wordmark it made "mimir" read as a caption to it.
struct MilowdaMark: View {
    let version: String

    var body: some View {
        HStack {
            Text("AY Usage \(version)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.5))
            Spacer(minLength: 0)
            Text("基于 Mimir · MIT 许可")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.5))
        }
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 11)
    }
}

/// Header: "mimir" and its build badge on the left, the settings gear on the right. At the top
/// rather than the bottom because the gear is the only control in the popover — a control the eye
/// has to scroll past everything to find is one nobody finds.
struct BrandingHeader: View {
    /// The gear flips between the faces, both ways.
    let onGear: () -> Void
    /// While a refresh is out, a wave runs through the wordmark left to right, letter by letter; it
    /// settles when the numbers are in. Opening the popover is itself the refresh, so this is the
    /// whole of the refresh UI — no button, no timestamp.
    var refreshing = false
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Text("AY Usage")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.55))
            .animation(.easeOut(duration: 0.25), value: refreshing)

            Spacer(minLength: 6)

            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: refreshing ? "hourglass" : "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .help(refreshing ? "正在刷新" : "刷新")
            }
            Button(action: onGear) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(String(localized: "Settings"))
        }
        // Line the header up with the cards below it: "mimir" starts where a card's brand icon does.
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Opacity of letter `index` at `date`: one dip per 1.2s cycle, each letter 0.12s behind the
    /// one on its left, so the dip travels m → i → m → i → r.
    static func wave(_ date: Date, _ index: Int) -> Double {
        let phase = date.timeIntervalSinceReferenceDate / 1.2 - Double(index) * 0.1
        return 0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * phase))
    }
}

extension View {
    /// Show the link/pointing-hand cursor while hovering — the default cursor behaviour
    /// for clickable text, which SwiftUI doesn't apply on its own here.
    /// Calls `onChange` with this view's laid-out height, now and whenever it changes.
    func measuringHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onChange(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in onChange(height) }
            }
        }
    }

    /// Set, not pushed: the panel never becomes key, so AppKit keeps resetting the cursor to the
    /// arrow and a one-off push on entry was lost straight away. Setting it on every move holds.
    func pointingHandCursor() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

enum PopoverMetrics {
    static let edgeInset: CGFloat = 14
    /// Resting top/bottom padding.
    static let contentInset: CGFloat = 18
    static let width: CGFloat = 288
    /// Safety ceiling only; the popover otherwise grows to fit all content (no inner scroll).
    static let maxHeight: CGFloat = 1400
    static let placeholderHeight: CGFloat = 200
}


/// Behind-window blur: blurs the actual desktop behind the popover (not just the
/// window's own content like SwiftUI's `.ultraThinMaterial`). This is what makes
/// the panel read as transparent glass over the wallpaper.
struct DesktopBlur: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        apply(view)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { apply(nsView) }

    private func apply(_ view: NSVisualEffectView) {
        // hudWindow is a dark vibrant blur; popover is the light counterpart.
        view.material = dark ? .hudWindow : .popover
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

/// Outer ambient layer behind the inner panel: behind-window desktop blur, a dark
/// base, and faint brand-tinted glows in the corners (the v4 showcase frame). The
/// inner panel sits inset on top of this, giving the panel-in-panel depth.
/// Whether a scroll view has content left below its visible part. ponytail: macOS 15+ only
/// (`onScrollGeometryChange`); on 14 the fade simply never shows.
private struct MoreBelowTracker: ViewModifier {
    @Binding var moreBelow: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height > 4
            } action: { _, value in
                moreBelow = value
            }
        } else {
            content
        }
    }
}

struct PopoverBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            DesktopBlur(dark: dark)

            // Tint kept minimal so the behind-window blur (the desktop) carries the
            // look — frosted glass rather than a solid panel.
            LinearGradient(
                colors: dark
                    ? [Color(hex: 0x12121A), Color(hex: 0x0C0D14), Color(hex: 0x08090E)]
                    : [Color(hex: 0xF4F4F7), Color(hex: 0xECECEF), Color(hex: 0xE6E6EA)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(dark ? 0.05 : 0.04)

            RadialGradient(colors: [Color(hex: 0x7E8BF2).opacity(dark ? 0.10 : 0.07), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 280)
            RadialGradient(colors: [Color(hex: 0xE6885B).opacity(dark ? 0.08 : 0.06), .clear],
                           center: .bottomLeading, startRadius: 8, endRadius: 280)
        }
        .ignoresSafeArea()
    }
}

/// One provider = one card. The card is the widget: each quota pair is drawn as the medium
/// widget's face — the five-hour window tints that share of the panel from the left, its number
/// sits top right with the reset clock and countdown, and the long window rides a capsule below.
/// Popover and widget then say the same thing the same way. A provider with independent families
/// (Antigravity) gets one panel per family; everyone else gets one.
///
/// Under the panels: the renewal passes as a single chip that opens into its own list, then the
/// money and balance rows, which are always visible — they're short, they're one per provider, and
/// hiding a number behind a disclosure only makes it a number nobody checks.
struct ServiceCard: View {
    let service: ServiceStatus
    let now: Date

    /// Opens the renewal-pass list. The chip already carries the count and the nearest expiry, so
    /// the list is for the dates behind them; collapsed is the resting state.
    @State private var expandedGrantScopes: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(panels.enumerated()), id: \.offset) { _, panel in
                ProviderPanel(panel: panel.promotingLoneWindow(), now: now)
            }

            ForEach(Array(modelLimitRows.enumerated()), id: \.offset) { _, row in
                modelLimitPill(row)
            }

            ForEach(renewalGroups) { group in
                Button {
                    if expandedGrantScopes.contains(group.id) { expandedGrantScopes.remove(group.id) }
                    else { expandedGrantScopes.insert(group.id) }
                } label: {
                    renewalPill(count: group.rows.count, expiry: group.rows.first?.resetAt,
                                fallback: group.rows.first?.valueText, scope: group.scope,
                                chevron: group.rows.count > 1, expanded: expandedGrantScopes.contains(group.id))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(group.rows.count > 1)
                .pointingHandCursor()
                if expandedGrantScopes.contains(group.id) {
                    ForEach(Array(group.rows.dropFirst().enumerated()), id: \.offset) { index, row in
                        renewalPill(count: group.rows.count - index - 1, expiry: row.resetAt,
                                    fallback: row.valueText, scope: group.scope)
                    }
                }
            }

            if !alwaysRows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(alwaysRows) { row in
                        valueRow(row)
                    }
                }
                .padding(.leading, Self.chipInset)
            }
            VStack(alignment: .leading, spacing: 3) {
                if service.isStale || service.dataUnavailable {
                    Label("旧数据 · 尚未获得最新配额", systemImage: "exclamationmark.triangle")
                }
                if let note = service.statusNote, !note.isEmpty {
                    Text(note).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let observedAt = service.observedAt {
                    Text("采集于 \(observedAt.formatted(date: .omitted, time: .shortened))")
                        .help(observedAt.formatted(date: .complete, time: .standard))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.primary.opacity(0.60))
            .padding(.horizontal, Self.chipInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        // Dim a stale snapshot so it reads as "last known, not live".
        .opacity(service.isStale ? 0.66 : 1)
    }

    // MARK: Renewal passes

    private struct GrantGroup: Identifiable {
        let scope: String?
        let rows: [ModelStatus]
        var id: String { scope ?? "__all__" }
    }
    private var renewalGroups: [GrantGroup] {
        Dictionary(grouping: renewalRows, by: { $0.caption ?? "" }).map { scope, rows in
            GrantGroup(scope: scope.isEmpty ? nil : scope, rows: rows.sorted { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) })
        }.sorted { ($0.rows.first?.resetAt ?? .distantFuture) < ($1.rows.first?.resetAt ?? .distantFuture) }
    }

    /// One pill: the count badge, the label, how long until it lapses. Its text takes the urgency
    /// colour of that expiry — a pass you lose tomorrow should not read the same as one with a
    /// month on it.
    private func renewalPill(count: Int, expiry: Date?, fallback: String?, scope: String? = nil, chevron: Bool = false, expanded: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
            Text("重置卡")
            if let scope { Text("· \(scope)").lineLimit(1) }
            Text("|").foregroundStyle(Color.primary.opacity(0.18))
            Text(relDuration(expiry, now) ?? fallback ?? "—").monospacedDigit()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(expiryColor(expiry))
        .padding(.horizontal, Self.chipInset).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .contentShape(Capsule())
    }

    /// A model's own weekly as a full-width row: what's left, the model, when it resets — in the
    /// quota's own green / amber / red, the same colours its panel number would take.
    private func modelLimitPill(_ row: (name: String, percent: Int, resetAt: Date?)) -> some View {
        HStack(spacing: 6) {
            Text("\(row.percent)%")
                .monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
            Text(row.name)
            Spacer(minLength: 6)
            Text(relDuration(row.resetAt, now) ?? "—").monospacedDigit()
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(quotaStatusColor(row.percent))
        .padding(.horizontal, Self.chipInset).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(String(localized: "Weekly limit for this model"))
    }

    /// Under three days an expiry is worth noticing, under a day it's worth acting on. Above that
    /// it's just a date, and reads in the same quiet grey as everything else.
    private func expiryColor(_ at: Date?) -> Color {
        guard let at else { return Color.primary.opacity(0.42) }
        let left = at.timeIntervalSince(now)
        if left <= 24 * 3600 { return quotaStatusColor(0) }
        if left <= 3 * 86_400 { return quotaStatusColor(20) }
        return Color.primary.opacity(0.42)
    }

    /// A money or balance row. Deliberately identical to a renewal line — same icon column, same
    /// weight, same tone on both sides — because the two sit in one list under the chip and any
    /// difference reads as a distinction that isn't there. A spent balance is the one exception:
    /// it takes the red an empty quota would.
    private func valueRow(_ row: ModelStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: row.symbol ?? "dollarsign.circle").font(.system(size: 11, weight: .regular))
                .frame(width: Self.iconColumn)
            Text(row.name)
            Spacer(minLength: 6)
            Text(row.valueText ?? "")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(row.isLow ? quotaStatusColor(0) : Color.primary.opacity(0.42))
        .lineLimit(1)
    }

    // MARK: Data shaping

    /// One panel per quota pair. Antigravity's families are independent quotas that happen to
    /// share an account, so each gets its own panel under its own name; every other provider has
    /// exactly one pair and so exactly one panel.
    private var panels: [PanelData] {
        var panels = quotaPanels
        for i in panels.indices { panels[i].stale = service.isStale }
        if !panels.isEmpty {
            panels[0].plan = service.account?.plan
            panels[0].email = service.account?.email
        }
        return panels
    }

    private var quotaPanels: [PanelData] {
        guard hasServiceQuotas else {
            return antigravityPanelFamilies.map { family in
                PanelData(title: family.name, iconName: service.iconName,
                          session: family.session.map { ($0.percent, $0.resetAt) },
                          weekly: family.weekly.map { ($0.percent, $0.resetAt) },
                          weeklyLabel: "7\(TimeFormatter.dayUnit)",
                          sessionFallback: 5 * 3600, weeklyWindow: 7 * 86_400,
                          gated: family.weekly?.percent == 0)
            }
        }
        return [PanelData(title: service.providerTitle, iconName: service.iconName,
                          session: service.sessionRemainingPercent.map { ($0, service.sessionResetAt) },
                          weekly: service.weeklyRemainingPercent.map { ($0, service.weeklyResetAt) },
                          weeklyLabel: longWindowLabel ?? "7\(TimeFormatter.dayUnit)",
                          sessionFallback: 5 * 3600,
                          weeklyWindow: service.weeklyWindowSeconds ?? 7 * 86_400,
                          gated: service.weeklyRemainingPercent == 0 && service.sessionRemainingPercent != nil)]
            // A quota beside the plan's own (Codex's Luna Reserve) is a quota in its own right, so it
            // gets its own panel under its own name — the same treatment as an Antigravity family.
            + families(in: service.models.filter { $0.groupLabel == LiveUsageDataSource.codexExtraLimitGroup })
                .map { family in
                    PanelData(title: family.name, iconName: service.iconName,
                              session: family.session.map { ($0.percent, $0.resetAt) },
                              weekly: family.weekly.map { ($0.percent, $0.resetAt) },
                              weeklyLabel: "7\(TimeFormatter.dayUnit)",
                              sessionFallback: 5 * 3600, weeklyWindow: 7 * 86_400,
                              gated: family.weekly?.percent == 0)
                }
    }

    /// The renewal passes, soonest to lapse first.
    private var renewalRows: [ModelStatus] {
        service.models.filter { $0.groupLabel == String(localized: "Renewal credit") && ($0.resetAt.map { $0 > now } ?? true) }
    }

    private var soonestPass: Date? {
        passes.first?.resetAt
    }

    /// The passes nearest expiry first; one with no date goes last.
    private var passes: [ModelStatus] {
        renewalRows.sorted { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) }
    }

    /// Money and balances — always on the card.
    private var alwaysRows: [ModelStatus] {
        service.models.filter { $0.valueText != nil && $0.groupLabel != String(localized: "Renewal credit") }
    }

    /// Antigravity grouped by family, preserving first-seen order, each family carrying
    /// its own session (5h) and weekly (7g) so they render together.
    private var antigravityFamilies: [(name: String, session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] {
        families(in: service.models)
    }

    /// The families that get a panel: those with a five-hour window. A weekly-only family is one
    /// model's own cap and goes to a chip — unless no family has a session, when all stay panels.
    private var antigravityPanelFamilies: [(name: String, session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] {
        let withSession = antigravityFamilies.filter { $0.session != nil }
        return withSession.isEmpty ? antigravityFamilies : withSession
    }

    /// Weekly caps on a single model (Claude's Fable, Antigravity's Gemini 4 Argon). They only bite
    /// when you pick that model, so each rides a chip under the panels instead of claiming one.
    private var modelLimitRows: [(name: String, percent: Int, resetAt: Date?)] {
        if hasServiceQuotas {
            return service.models.filter { $0.valueText == nil && $0.groupLabel == nil }
                .map { ($0.name, $0.remainingPercent, $0.resetAt) }
        }
        let panelNames = Set(antigravityPanelFamilies.map(\.name))
        return antigravityFamilies.compactMap { family in
            guard !panelNames.contains(family.name), let weekly = family.weekly else { return nil }
            return (family.name, weekly.percent, weekly.resetAt)
        }
    }

    /// Rows grouped by name into session/weekly pairs, in the order they first appear.
    private func families(in models: [ModelStatus]) -> [(name: String, session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] {
        var order: [String] = []
        var bag: [String: (session: (percent: Int, resetAt: Date?)?, weekly: (percent: Int, resetAt: Date?)?)] = [:]
        for model in models where model.valueText == nil {
            if bag[model.name] == nil { order.append(model.name); bag[model.name] = (nil, nil) }
            if model.window == .weekly {
                bag[model.name]?.weekly = (model.remainingPercent, model.resetAt)
            } else {
                bag[model.name]?.session = (model.remainingPercent, model.resetAt)
            }
        }
        return order.map { (name: $0, session: bag[$0]?.session ?? nil, weekly: bag[$0]?.weekly ?? nil) }
    }

    /// True when the provider reports account-level windows (Claude/Codex) rather than per-family
    /// ones (Antigravity).
    private var hasServiceQuotas: Bool {
        service.sessionRemainingPercent != nil || service.weeklyRemainingPercent != nil
    }

    /// "7d" / "30d", from the window's REAL length. nil when the provider didn't report one.
    private var longWindowLabel: String? {
        quotaWindowDays(service.weeklyWindowSeconds).map { "\($0)\(TimeFormatter.dayUnit)" }
    }

    /// Width of the leading icon column, so a symbol and a status dot line up.
    static let iconColumn: CGFloat = 12
    /// The chip's horizontal padding. The lines under it are inset by the same amount so their
    /// icons sit directly below the chip's own, rather than a step to its left.
    static let chipInset: CGFloat = 8
}

/// One quota pair, ready to draw.
struct PanelData {
    let title: String
    let iconName: String
    let session: (percent: Int, resetAt: Date?)?
    let weekly: (percent: Int, resetAt: Date?)?
    let weeklyLabel: String
    let sessionFallback: TimeInterval
    let weeklyWindow: TimeInterval
    let gated: Bool
    /// A last-known reading, not a live one: drawn grey like a gated panel, so it can't read as usable.
    var stale = false
    /// The login, on the card's first panel only: plan beside the title, e-mail under it.
    var plan: String? = nil
    var email: String? = nil

    /// A plan with one long window and no session (Codex Go's 30 days) shows it where the session
    /// sits — the big number, the clock and the face — instead of an empty corner above a capsule.
    func promotingLoneWindow() -> PanelData {
        guard session == nil, let weekly else { return self }
        return PanelData(title: title, iconName: iconName, session: weekly, weekly: nil,
                         weeklyLabel: weeklyLabel, sessionFallback: weeklyWindow,
                         weeklyWindow: weeklyWindow, gated: false, stale: stale, plan: plan, email: email)
    }
}

/// The medium widget, shrunk to fit a card. The panel's face IS the five-hour gauge: what's left
/// of that window tints the same share of the panel from the left, so the reading is the shape of
/// the thing, not a bar next to it. Its number sits top right with the reset clock above the
/// countdown; the long window runs along the bottom as a capsule carrying its own percent.
///
/// Deliberately the same geometry as `DetailedWidget`'s medium size — a user who has both on
/// screen should not have to learn two pictures of one quota.
struct ProviderPanel: View {
    let panel: PanelData
    let now: Date

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// The login's e-mail, raised by a click on the plan and gone again on its own.
    @State private var accountShown = ProcessInfo.processInfo.environment["MIMIR_DEMO_ACCOUNT"] != nil
    @State private var hideAccount: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let session = panel.session {
                quotaRow(label: sessionLabel, percent: session.percent, resetAt: session.resetAt,
                         window: panel.sessionFallback, locked: panel.gated)
            }
            if let weekly = panel.weekly {
                quotaRow(label: panel.weeklyLabel, percent: weekly.percent, resetAt: weekly.resetAt,
                         window: panel.weeklyWindow, locked: false)
            }
            if panel.session == nil && panel.weekly == nil {
                Text("暂无配额数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if panel.gated {
                Text("长期配额已用完，5 小时配额暂时无法使用")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(quotaStatusColor(0))
            }
        }
        .padding(10)
        .overlay(alignment: .topLeading) {
            // Just the address, just under the plan it came from, over whatever sits there.
            if accountShown, let email = panel.email {
                Text(email)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    .padding(.top, 28).padding(.leading, 6)
                    .onTapGesture { setAccountShown(false) }
                    .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// "5 小时" for the session window; a lone long window promoted into its place keeps its own name.
    private var sessionLabel: String {
        panel.sessionFallback == 5 * 3600 ? "5小时" : panel.weeklyLabel
    }

    /// One window, read left to right: what it is, how full, how much. The reset sits underneath in
    /// small type.
    private func quotaRow(label: String, percent: Int, resetAt: Date?, window: TimeInterval, locked: Bool) -> some View {
        let value = clampPct(percent)
        let color = locked || panel.stale ? lockedQuotaColor : quotaStatusColor(value)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .frame(width: 40, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(color)
                            .frame(width: value > 0 ? max(4, geo.size.width * CGFloat(value) / 100) : 0)
                    }
                }
                .frame(height: 7)
                Text("\(value)%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .frame(width: 42, alignment: .trailing)
            }
            Text(resetText(resetAt))
                .foregroundStyle(Color.primary.opacity(0.45))
            .font(.system(size: 10.5).monospacedDigit())
            .lineLimit(1)
            .padding(.leading, 48)
        }
        .accessibilityElement(children: .combine)
    }

    /// "2小时13分 后重置 · 14:30", with the weekday once the reset is more than a day out.
    private func resetText(_ at: Date?) -> String {
        guard let at, let rel = relDuration(at, now) else { return "重置时间未知" }
        let clock = at.timeIntervalSince(now) > 86_400 ? Self.dayClockFormatter : Self.clockFormatter
        return "\(rel) 后重置 · \(clock.string(from: at))"
    }

    private static let dayClockFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE HH:mm"); return f
    }()

    /// The name with its plan beside it in a quieter tone — "Claude Team", as Claude's own usage page
    /// writes it — then the reset clock over the countdown and the number. The plan is the way to the
    /// login: a click shows the e-mail the card reads, just under it.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 4) {
                BrandIconView(iconName: panel.iconName, size: 13)
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .frame(width: 13, height: 13)
                    .padding(.trailing, 2)
                Text(panel.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let plan = panel.plan {
                    let label = Text(plan)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .lineLimit(1)
                        .fixedSize()
                    if panel.email != nil {
                        Button { setAccountShown(!accountShown) } label: { label }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                    } else {
                        label
                    }
                }
            }
            // Every point left of the clock goes to the name before the spacer takes any: shared
            // evenly, the spacer took half and cut "Claude" to "Clau…".
            .layoutPriority(1)
            // No minimum: the row's own spacing already parts the name from the clock, and the
            // six points it held are what "Claude Team" was short of.
            Spacer(minLength: 0)
        }
    }

    private func setAccountShown(_ shown: Bool) {
        hideAccount?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { accountShown = shown }
        guard shown else { return }
        hideAccount = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { accountShown = false }
        }
    }

}

// Color(hex:) now lives in MimirShared (shared with the widget); imported via `import MimirShared`.

func clampPct(_ percent: Int) -> Int { max(0, min(100, percent)) }

/// A model whose weekly (7g) quota is spent is unusable until it resets — its session number, bar,
/// and 7g dot drop to this muted grey so a fresh 5h window can't read as "available" when the week
/// is gone (the "green even though I can't use it" case).
let lockedQuotaColor = Color.primary.opacity(0.4)

func relDuration(_ resetAt: Date?, _ now: Date) -> String? {
    guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
    return TimeFormatter.duration(from: resetAt.timeIntervalSince(now))
}

/// Status colour for a remaining-quota level — the same bands as the menu bar (see `QuotaLevel`).
func quotaStatusColor(_ percent: Int) -> Color {
    Color(nsColor: QuotaLevel(remaining: percent).color)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}


/// Stand-in for a service that has no data yet: says so, says why, and offers the one action that
/// can fix it. Never shows a percentage — there is none to show.
struct SetupCard: View {
    let service: ServiceStatus
    let settings: PopoverSettings

    private var isClaude: Bool { service.name == "Claude" }

    private var hint: String {
        isClaude
            ? "点「授权凭据」读取 Claude Code 的登录凭证，系统会询问一次钥匙串权限。也可以在设置中开启「Claude 免提示读取」。"
            : "未读到 Codex 登录信息。在终端运行 codex login 后点「刷新」。"
    }

    /// The provider's own reason, when it's more than the generic "authorize in settings" line the
    /// hint above already covers.
    private var reason: String? {
        guard let note = service.statusNote, !note.isEmpty,
              note != String(localized: "open Mimir to refresh Claude") else { return nil }
        return note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BrandIconView(iconName: service.iconName, size: 16)
                Text(service.titleWithAccount)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("暂无数据")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text("原因：\(reason)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if isClaude {
                    Button("授权凭据", action: settings.authorizeCredentials)
                        .controlSize(.small)
                }
                Button("刷新", action: settings.refresh)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct BrandIconView: View {
    let iconName: String
    let size: CGFloat

    var body: some View {
        if let image = BrandIconLoader.image(named: iconName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle")
                .symbolRenderingMode(.monochrome)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary.opacity(0.5))
                .accessibilityHidden(true)
        }
    }
}
