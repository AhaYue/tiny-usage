import AppKit
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
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system

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
    @State private var localCaptureState: ClaudeLocalCaptureState = .disabled

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
                        SettingsFace(settings: settings, language: $language, onBack: { flip() })
                            .measuringHeight { settingsHeight = $0; reportHeight() }
                    }
                    .opacity(showingSettings ? 1 : 0)
                    .allowsHitTesting(showingSettings)
                }
            }
        }
        .id(language)
        .containerShape(PopoverMetrics.panelShape)
        .onAppear { localCaptureState = settings.localCaptureState() }
        .onChange(of: store.isRefreshing) { _, _ in localCaptureState = settings.localCaptureState() }
        .onChange(of: language) { _, _ in settings.languageDidChange() }
    }

    /// Straight swap, no animation: the settings are a place you go, not a trick the card does.
    private func flip() {
        showingSettings.toggle()
        localCaptureState = settings.localCaptureState()
        reportHeight()
    }

    private func claudeHelp(for service: ServiceStatus) -> ClaudeUsageHelp? {
        guard let guidance = ClaudeUsageGuidance.resolve(service: service, capture: localCaptureState) else { return nil }
        return ClaudeUsageHelp(guidance: guidance, refreshing: store.isRefreshing,
                               authorize: settings.authorize, refresh: settings.refresh)
    }

    /// A live Claude card without reset passes offers the one thing authorizing adds, until the
    /// user has authorized once (after that the Settings row is the way back).
    private func resetHint(for service: ServiceStatus) -> (() -> Void)? {
        guard service.name == "Claude", !settings.didAuthorize(),
              !service.models.contains(where: { $0.groupLabel == ModelStatus.renewalCreditGroup }) else { return nil }
        return settings.authorize
    }

    private func reportHeight() {
        onContentHeightChange(showingSettings ? settingsHeight : quotaHeight)
    }

    @ViewBuilder
    private func quotaFace(now: Date) -> some View {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        BrandingHeader(onGear: { flip() }, refreshing: store.isRefreshing, onRefresh: settings.refresh,
                                       updatedAt: store.services.compactMap(\.observedAt).max(), now: now)
                        notificationBanner
                        contentView(now: now)
                    }
                    .padding(.vertical, PopoverMetrics.faceVerticalPadding)
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
        service.name == "Codex" || service.name.hasPrefix("Codex ") ||
        service.name == AntigravityConfiguration.name ||
        service.name == OpenCodeGoConfiguration.name
    }

    /// Primary Claude/Codex services that returned nothing at all — no live data, no snapshot. They
    /// used to vanish from the panel, leaving no hint that Claude simply wasn't authorized yet; now
    /// they get a compact card with the reason and a way to fix it. Extra accounts and the optional
    /// Desktop fallback card stay hidden: their absence isn't something the user has to act on.
    static func needsSetup(_ services: [ServiceStatus]) -> [ServiceStatus] {
        services
            .filter { serviceDisplayOrder.contains($0.name) && !$0.isAvailable && !$0.isStale }
            .sortedByDisplayOrder()
    }

    /// Show live services and stale snapshots; hide services that have no data at all.
    /// A stale snapshot (isStale) survives the filter so the user still sees the last-known
    /// reading instead of the card vanishing.
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
                ForEach((visible + setup).sortedByDisplayOrder()) { service in
                    let recovery = claudeHelp(for: service)
                    if service.isAvailable || service.isStale {
                        ServiceCard(service: service, now: now, recovery: recovery,
                                    onAuthorize: recovery == nil ? resetHint(for: service) : nil,
                                    onConfigureOpenCode: service.name == OpenCodeGoConfiguration.name ? settings.configureOpenCodeGo : nil)
                    } else {
                        SetupCard(service: service, settings: settings, recovery: recovery,
                                  refreshing: store.isRefreshing)
                    }
                }
            }
            .padding([.top, .horizontal], PopoverMetrics.cardInset)
            .padding(.bottom, PopoverMetrics.cardInset - PopoverMetrics.faceVerticalPadding)
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
            .filter { Self.supported($0) && $0.dataUnavailable && ($0.isAvailable || $0.isStale)
                && !store.dismissedUnavailable.contains($0.name) }
            .sortedByDisplayOrder()
        if !down.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(down) { svc in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L("\(svc.titleWithAccount): couldn't get the latest data"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .help(L("popover.unavailable.dismiss"))
                        .accessibilityLabel(L("popover.unavailable.dismiss"))
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
            Text(L("No Claude or Codex usage data yet"))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("Refresh"), action: settings.refresh)
                .disabled(store.isRefreshing)
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
    var launchAtLogin: () -> Bool
    var toggleLaunchAtLogin: () -> Void
    /// Local statusLine capture is independent of the selected query mode.
    var localCaptureState: () -> ClaudeLocalCaptureState
    var showRemaining: () -> Bool
    var setShowRemaining: (Bool) -> Void
    var menuStyle: () -> Int
    var setMenuStyle: (Int) -> Void
    var menuBarColors: () -> MenuBarColors
    var setMenuBarColors: (MenuBarColors) -> Void
    var menuBarProviders: () -> Set<MenuBarProvider>
    var setMenuBarProviders: (Set<MenuBarProvider>) -> Void
    var refreshMode: () -> Int
    var setRefreshMode: (Int) -> Void
    var languageDidChange: () -> Void = {}
    /// The one action that may show the macOS keychain dialog, after its own confirmation.
    var authorize: () -> Void
    var didAuthorize: () -> Bool
    var refresh: () -> Void
    var antigravityEnabled: () -> Bool = { false }
    var setAntigravityEnabled: (Bool) -> Void = { _ in }
    var configureOpenCodeGo: () -> Void = {}
    var openDataFolder: () -> Void
    var about: () -> Void
    /// False in dev builds without a feed, where the row is hidden.
    var canCheckForUpdates: Bool = false
    var checkForUpdates: () -> Void = {}
    var quit: () -> Void
}

/// The back of the card: every setting in one list, the way a menu-bar app's settings should read
/// — a row is an icon, what it does, and a line saying what that means. One card, not three: the
/// groups were separating things nobody needed separated.
struct SettingsFace: View {
    let settings: PopoverSettings
    @Binding var language: AppLanguage
    let onBack: () -> Void

    /// Every flag here lives outside SwiftUI — a login item, a file on disk, a defaults key — so
    /// none of them can be observed. They're read into state when the face appears and after each
    /// toggle. An earlier attempt leaned on a counter the body merely mentioned (`let _ = tick`);
    /// the compiler is free to drop a read into `_`, so nothing depended on it and every row kept
    /// showing whatever it showed first — a switch showing on for a setting that was actually off.
    @State private var flags = Flags()
    @State private var hovered: String?
    @State private var editingColor: QuotaLevel?

    init(settings: PopoverSettings, language: Binding<AppLanguage>, editingColor: QuotaLevel? = nil,
         onBack: @escaping () -> Void) {
        self.settings = settings
        _language = language
        _editingColor = State(initialValue: editingColor)
        self.onBack = onBack
    }

    private struct Flags {
        var launchAtLogin = false
        var showRemaining = true
        var menuStyle = 0
        var menuBarColors = MenuBarColors()
        var menuBarProviders = MenuBarProvider.all
        var refreshMode = 0
        var antigravityEnabled = false
    }

    private func reload() {
        flags = Flags(launchAtLogin: settings.launchAtLogin(),
                      showRemaining: settings.showRemaining(),
                      menuStyle: settings.menuStyle(),
                      menuBarColors: settings.menuBarColors(),
                      menuBarProviders: settings.menuBarProviders(),
                      refreshMode: settings.refreshMode(),
                      antigravityEnabled: settings.antigravityEnabled())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandingHeader(onGear: onBack, closing: true)

            VStack(spacing: 0) {
                menuBarProvidersRow
                pickerRow("menubar.rectangle", L("Menu bar"), nil,
                          selection: Binding(get: { flags.menuStyle }, set: { settings.setMenuStyle($0); reload() }),
                          options: MenuBarRenderer.Style.allCases.map { ($0.rawValue, $0.label) })
                pickerRow("percent", L("Display"), L("Colour follows what's left."),
                          selection: Binding(get: { flags.showRemaining ? 0 : 1 },
                                             set: { settings.setShowRemaining($0 == 0); reload() }),
                          options: [(0, L("Remaining")), (1, L("Used"))])
                menuBarColorsRow

                pickerRow("timer", L("Refresh rate"), RefreshMode(rawValue: flags.refreshMode)?.detail,
                          selection: Binding(get: { flags.refreshMode }, set: { settings.setRefreshMode($0); reload() }),
                          options: RefreshMode.allCases.map { ($0.rawValue, $0.label) })
                row("arrow.clockwise", L("Refresh usage"), nil, action: settings.refresh)
                row("key", L("Authorize reset credits"), L("Queries Claude reset credits and the full quota."), action: settings.authorize)
                switchRow(AntigravityConfiguration.iconName, AntigravityConfiguration.name,
                          L("Reads local app or agy CLI quota."), brandIcon: true,
                          isOn: flags.antigravityEnabled) { settings.setAntigravityEnabled($0) }
                row(OpenCodeGoConfiguration.iconName, OpenCodeGoConfiguration.name, L("Manage the key for Go quotas."), brandIcon: true,
                    action: settings.configureOpenCodeGo)

                switchRow("power", L("Launch at login"), L("Opens Tiny Usage after you log in."),
                          isOn: flags.launchAtLogin) { _ in settings.toggleLaunchAtLogin() }
                pickerRow("globe", L("Language"), nil, selection: $language,
                          options: AppLanguage.allCases.map { ($0, $0.label) })
                row("folder", L("Open data folder"), nil, action: settings.openDataFolder)
                if settings.canCheckForUpdates {
                    row("arrow.down.circle", L("Check for updates"), nil, action: settings.checkForUpdates)
                }
                row("info.circle", L("About"), L("Version and open-source licenses."), action: settings.about)
                row("xmark.circle", L("Quit Tiny Usage"), nil,
                    shortcut: "⌘Q", action: settings.quit)
            }
            .padding(.vertical, 4)
            .modifier(PopoverCardSurface())
            // Same insets as the quota cards (contentView), so the card edges line up across faces.
            .padding([.top, .horizontal], PopoverMetrics.cardInset)
            .padding(.bottom, PopoverMetrics.cardInset - PopoverMetrics.faceVerticalPadding)
        }
        .padding(.vertical, PopoverMetrics.faceVerticalPadding)
        .onAppear(perform: reload)
    }

    private var menuBarColorsRow: some View {
        VStack(spacing: 0) {
            pickerRow("paintpalette", L("Menu bar colors"), nil,
                      selection: Binding(get: { flags.menuBarColors.mode }, set: { mode in
                          flags.menuBarColors.mode = mode
                          editingColor = nil
                          settings.setMenuBarColors(flags.menuBarColors)
                      }),
                      options: MenuBarColors.Mode.allCases.map { ($0, $0.label) })
            if flags.menuBarColors.mode == .custom {
                HStack(spacing: 4) {
                    quotaColorSwatch(L("50%+"), level: .plenty)
                    quotaColorSwatch(L("20–49%"), level: .low)
                    quotaColorSwatch(L("Below 20%"), level: .critical)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                if let editingColor {
                    MenuBarColorEditor(rgb: Binding(get: { flags.menuBarColors[editingColor] }, set: { rgb in
                        flags.menuBarColors[editingColor] = rgb
                        settings.setMenuBarColors(flags.menuBarColors)
                    }))
                    .id(editingColor)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func quotaColorSwatch(_ title: String, level: QuotaLevel) -> some View {
        let rgb = flags.menuBarColors[level]
        return Button {
            editingColor = editingColor == level ? nil : level
        } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: rgb))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(editingColor == level ? 0.9 : 0.25), lineWidth: 1))
                    .frame(width: 33, height: 17)
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: "#%06X", rgb))
        .accessibilityAddTraits(editingColor == level ? .isSelected : [])
    }

    private var menuBarProvidersRow: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "checklist")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text(L("Show in menu bar"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(MenuBarProvider.allCases, id: \.self) { provider in
                    Toggle(provider.title, isOn: Binding(get: { flags.menuBarProviders.contains(provider) }, set: { on in
                        var selection = flags.menuBarProviders
                        if on { selection.insert(provider) } else { selection.remove(provider) }
                        settings.setMenuBarProviders(selection)
                        reload()
                    }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    // Mirror only the native checkbox so its label stays clickable on the left.
                    .environment(\.layoutDirection, .rightToLeft)
                    .fixedSize()
                    .frame(minHeight: 22)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Show in menu bar"))
    }

    /// A setting with a few named values: the title and what it means on the left, a pop-up menu
    /// with the current value on the right — the choices are visible, not hidden behind clicks.
    private func pickerRow<Value: Hashable>(_ symbol: String, _ title: String, _ subtitle: String?,
                                           selection: Binding<Value>, options: [(Value, String)]) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color.primary.opacity(0.6))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .fixedSize(horizontal: true, vertical: false)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Without this the spacer takes half the row and longer (English) text wraps early.
            .layoutPriority(1)
            Spacer(minLength: 8)
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An on/off setting: same layout as the picker rows, a system switch on the right.
    private func switchRow(_ symbol: String, _ title: String, _ subtitle: String?,
                           brandIcon: Bool = false, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 11) {
            Group {
                if brandIcon {
                    BrandIconView(iconName: symbol, size: 15)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .light))
                }
            }
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(get: { isOn }, set: { set($0); reload() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One action. `shortcut` shows the key that does the same thing without opening this screen.
    private func row(_ symbol: String, _ title: String, _ subtitle: String?,
                     shortcut: String? = nil, brandIcon: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button {
            action()
            reload()
        } label: {
            HStack(spacing: 11) {
                Group {
                    if brandIcon {
                        BrandIconView(iconName: symbol, size: 15)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .light))
                    }
                }
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
                .layoutPriority(1)
                Spacer(minLength: 8)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.35))
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

/// Shows the Tiny Usage wordmark, refresh status, and settings control.
struct BrandingHeader: View {
    /// The gear flips between the faces, both ways.
    let onGear: () -> Void
    /// While a refresh is out, a wave runs through the wordmark left to right, letter by letter; it
    /// settles when the numbers are in. Opening the popover is itself the refresh, so this is the
    /// whole of the refresh UI — no button, no timestamp.
    var refreshing = false
    var onRefresh: (() -> Void)? = nil
    /// Newest observation across the cards, shown as "更新于 3 分钟前" beside the refresh button.
    var updatedAt: Date? = nil
    var now: Date = Date()
    /// On the settings face the same button closes them: an ✕, so it reads as "back", not "more settings".
    var closing = false

    var body: some View {
        HStack(spacing: 7) {
            Text("Tiny Usage")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .fixedSize()
            .animation(.easeOut(duration: 0.25), value: refreshing)

            Spacer(minLength: 6)

            if let updatedAt {
                Text(Self.updatedText(updatedAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(updatedAt.formatted(date: .abbreviated, time: .standard))
            }
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: refreshing ? "hourglass" : "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .help(refreshing ? L("Refreshing") : L("Refresh"))
            }
            Button(action: onGear) {
                Image(systemName: closing ? "xmark" : "gearshape")
                    .font(.system(size: closing ? 13 : 15, weight: closing ? .semibold : .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(closing ? L("Close settings") : L("Settings"))
        }
        // Line the header up with the cards below it: the wordmark starts where a card's brand icon does.
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    static func updatedText(_ at: Date, now: Date) -> String {
        let age = now.timeIntervalSince(at)
        if age < 90 { return L("Just now") }
        if age < 3600 { return L("\(Int(age / 60)) min ago") }
        return L("Updated \(at.formatted(date: .omitted, time: .shortened))")
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
    static let cardInset: CGFloat = 11
    static let faceVerticalPadding: CGFloat = 4
    static let cardCornerRadius: CGFloat = 14
    static let panelCornerRadius = cardCornerRadius + cardInset
    static var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCornerRadius, style: .circular)
    }
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
        view.material = .popover
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

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

            if dark {
                // Keep the system popover material legible over bright wallpaper.
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
            }
        }
        .ignoresSafeArea()
    }
}

private struct PopoverCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let fill = scheme == .dark
            ? AnyShapeStyle(Color.primary.opacity(0.06))
            : AnyShapeStyle(.regularMaterial)

        content.background {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(PopoverMetrics.cardCornerRadius)))
                shape.fill(fill)
                    .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 2).clipShape(shape))
            } else {
                fixedBackground(fill)
            }
            #else
            fixedBackground(fill)
            #endif
        }
    }

    private func fixedBackground(_ fill: AnyShapeStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: PopoverMetrics.cardCornerRadius, style: .circular)
        return shape.fill(fill)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// One provider = one card. Each quota pair is drawn as a panel: the five-hour window tints that
/// share of the panel from the left, its number sits top right with the reset clock and countdown,
/// and the long window rides a capsule below.
///
/// Under the panels: the renewal passes as a single chip that opens into its own list, then the
/// money and balance rows, which are always visible — they're short, they're one per provider, and
/// hiding a number behind a disclosure only makes it a number nobody checks.
struct ServiceCard: View {
    let service: ServiceStatus
    let now: Date
    var recovery: ClaudeUsageHelp? = nil
    /// Shown as a quiet link at the bottom of a live Claude card that has no reset passes yet.
    var onAuthorize: (() -> Void)? = nil
    var onConfigureOpenCode: (() -> Void)? = nil

    /// Opens the renewal-pass list. The chip already carries the count and the nearest expiry, so
    /// the list is for the dates behind them; collapsed is the resting state.
    @State private var expandedGrantScopes: Set<String> = []

    var body: some View {
        let providerPanels = panels
        let grantGroups = renewalGroups

        VStack(alignment: .leading, spacing: 8) {
            if !providerPanels.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(providerPanels.enumerated()), id: \.offset) { index, panel in
                        ProviderPanel(panel: panel.promotingLoneWindow(), now: now)
                            .padding(.top, index > 0 ? 8 : 0)
                    }
                    ForEach(Array(modelLimitRows.enumerated()), id: \.offset) { _, row in
                        modelLimitPill(row)
                    }
                }
                .padding(.bottom, 5)
            }

            if !grantGroups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(grantGroups) { group in
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
                }
                .padding(.vertical, 6)
            }

            if !alwaysRows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(alwaysRows) { row in
                        valueRow(row)
                    }
                }
                .padding(.leading, Self.chipInset)
            }
            if let recovery {
                recovery
            } else if service.isStale || service.dataUnavailable || service.statusNote == "snapshot" {
                Label(L("Cached usage"), systemImage: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let onConfigureOpenCode, let note = service.statusNote,
                   note == OpenCodeGoUsage.rejectedKeyNote || note == OpenCodeGoUsage.permissionNote {
                    Text(AppLanguage.current.text(forKey: note))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(L("Configure OpenCode Go"), action: onConfigureOpenCode)
                        .controlSize(.small)
                }
            } else if let onAuthorize {
                Button(action: onAuthorize) {
                    Label(L("Authorize reset credits"), systemImage: "key")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L("Reads the Claude login credential from the keychain; macOS asks only after you confirm"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .modifier(PopoverCardSurface())
    }

    // MARK: Renewal passes

    private struct GrantGroup: Identifiable {
        let id: String
        let rows: [ModelStatus]
        var scope: String? { rows.first?.renewalScopeLabel }
    }
    private var renewalGroups: [GrantGroup] {
        Dictionary(grouping: renewalRows, by: { $0.caption ?? "" }).map { scope, rows in
            GrantGroup(id: scope, rows: rows.sorted { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) })
        }.sorted { ($0.rows.first?.resetAt ?? .distantFuture) < ($1.rows.first?.resetAt ?? .distantFuture) }
    }

    /// One pill with the count, scope, and a countdown that highlights imminent expiry.
    private func renewalPill(count: Int, expiry: Date?, fallback: String?, scope: String? = nil, chevron: Bool = false, expanded: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise")
                    .accessibilityHidden(true)
                Text(L("Renewal credit"))
            }
            .fixedSize(horizontal: true, vertical: false)
            if let scope { Text("· \(scope)").lineLimit(1) }
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 9)
                .accessibilityHidden(true)
            Text(relDuration(expiry, now) ?? fallback ?? "—")
                .monospacedDigit()
                .foregroundStyle(expiryColor(expiry))
                .fixedSize(horizontal: true, vertical: false)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .contentShape(Capsule())
    }

    /// A model's own weekly limit, in the same one-line form as the windows above it.
    private func modelLimitPill(_ row: (name: String, percent: Int, resetAt: Date?)) -> some View {
        QuotaLine(label: row.name, percent: row.percent, resetAt: row.resetAt, now: now,
                  color: service.isStale ? lockedQuotaColor : quotaStatusColor(row.percent), isStale: service.isStale)
            .help(L("Weekly limit for this model"))
    }

    /// Under three days an expiry is worth noticing, under a day it's worth acting on. Above that
    /// it's just a date, and reads in the same quiet grey as everything else.
    private func expiryColor(_ at: Date?) -> Color {
        guard let at else { return .secondary }
        let left = at.timeIntervalSince(now)
        if left <= 24 * 3600 { return quotaStatusColor(0) }
        if left <= 3 * 86_400 { return quotaStatusColor(20) }
        return .secondary
    }

    /// A money or balance row. Deliberately identical to a renewal line — same icon column, same
    /// weight, same tone on both sides — because the two sit in one list under the chip and any
    /// difference reads as a distinction that isn't there. A spent balance is the one exception:
    /// it takes the red an empty quota would.
    private func valueRow(_ row: ModelStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: row.symbol ?? "dollarsign.circle").font(.system(size: 11, weight: .regular))
                .frame(width: Self.iconColumn)
            Text(row.displayValueRowName)
            Spacer(minLength: 6)
            Text(row.displayValueRowText ?? "")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(row.isLow ? quotaStatusColor(0) : Color.primary.opacity(0.42))
        .lineLimit(1)
    }

    // MARK: Data shaping

    /// One panel per quota pair: the provider's own, plus one for each extra limit beside it
    /// (Codex's Luna Reserve).
    private var panels: [PanelData] {
        var panels = quotaPanels
        for i in panels.indices { panels[i].stale = service.isStale }
        if !panels.isEmpty {
            panels[0].plan = service.account?.plan
            panels[0].email = service.account?.email
            panels[0].source = service.statusNote.map(AppLanguage.current.text(forKey:))
            panels[0].observedAt = service.observedAt
            if service.name == OpenCodeGoConfiguration.name {
                panels[0].showsAllWindows = true
                panels[0].monthly = service.monthlyRemainingPercent.map { ($0, service.monthlyResetAt) }
            }
        }
        return panels
    }

    private var quotaPanels: [PanelData] {
        guard hasServiceQuotas || service.name == OpenCodeGoConfiguration.name else { return [] }
        return [PanelData(title: service.providerTitle, iconName: service.iconName,
                          session: service.sessionRemainingPercent.map { ($0, service.sessionResetAt) },
                          weekly: service.weeklyRemainingPercent.map { ($0, service.weeklyResetAt) },
                          weeklyLabel: longWindowLabel ?? "7\(TimeFormatter.dayUnit)",
                          sessionFallback: 5 * 3600,
                          weeklyWindow: service.weeklyWindowSeconds ?? 7 * 86_400,
                          gated: service.weeklyRemainingPercent == 0 && service.sessionRemainingPercent != nil)]
            // A quota beside the plan's own (Codex's Luna Reserve, Antigravity's Claude + GPT) is a
            // quota in its own right, so it gets its own panel under its own name.
            + families(in: service.models.filter {
                $0.groupLabel == LiveUsageDataSource.codexExtraLimitGroup
                    || $0.groupLabel == AntigravityConfiguration.extraLimitGroup
            })
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
        service.models.filter { $0.groupLabel == ModelStatus.renewalCreditGroup && ($0.resetAt.map { $0 > now } ?? true) }
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
        service.models.filter { $0.valueText != nil && $0.groupLabel != ModelStatus.renewalCreditGroup }
    }

    /// Weekly caps on a single model (Claude's Fable). They only bite
    /// when you pick that model, so each rides a chip under the panels instead of claiming one.
    private var modelLimitRows: [(name: String, percent: Int, resetAt: Date?)] {
        guard hasServiceQuotas else { return [] }
        return service.models.filter { $0.valueText == nil && $0.groupLabel == nil }
            .map { ($0.name, $0.remainingPercent, $0.resetAt) }
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

    /// True when the provider reports account-level windows (Claude/Codex).
    private var hasServiceQuotas: Bool {
        service.sessionRemainingPercent != nil || service.weeklyRemainingPercent != nil ||
        service.monthlyRemainingPercent != nil
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
    /// Where the numbers came from ("oauth usage api", "本地状态栏" …) and when — beside the title.
    var source: String? = nil
    var observedAt: Date? = nil
    var showsAllWindows = false
    var monthly: (percent: Int, resetAt: Date?)? = nil

    /// A plan with one long window and no session (Codex Go's 30 days) shows it where the session
    /// sits — the big number, the clock and the face — instead of an empty corner above a capsule.
    func promotingLoneWindow() -> PanelData {
        guard !showsAllWindows, session == nil, let weekly else { return self }
        return PanelData(title: title, iconName: iconName, session: weekly, weekly: nil,
                         weeklyLabel: weeklyLabel, sessionFallback: weeklyWindow,
                         weeklyWindow: weeklyWindow, gated: false, stale: stale, plan: plan, email: email,
                         source: source, observedAt: observedAt)
    }
}

/// One quota panel. The panel's face IS the five-hour gauge: what's left
/// of that window tints the same share of the panel from the left, so the reading is the shape of
/// the thing, not a bar next to it. Its number sits top right with the reset clock above the
/// countdown; the long window runs along the bottom as a capsule carrying its own percent.
struct ProviderPanel: View {
    let panel: PanelData
    let now: Date

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// The login's e-mail, raised by a click on the plan and gone again on its own.
    @State private var accountShown = ProcessInfo.processInfo.environment["TINY_USAGE_DEMO_ACCOUNT"] != nil
    @State private var hideAccount: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            VStack(alignment: .leading, spacing: 7) {
                if panel.session != nil || panel.showsAllWindows {
                    quotaRow(label: sessionLabel, reading: panel.session, locked: panel.gated)
                }
                if panel.weekly != nil || panel.showsAllWindows {
                    quotaRow(label: panel.weeklyLabel, reading: panel.weekly, locked: false)
                }
                if panel.showsAllWindows {
                    quotaRow(label: L("Monthly"), reading: panel.monthly, locked: false)
                } else if panel.session == nil && panel.weekly == nil {
                    Text(L("No quota data"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if panel.gated {
                    Text(L("Long-term quota is used up; the 5-hour quota is unavailable for now"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(quotaStatusColor(0))
                }
            }
        }
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
    }

    /// Where the numbers came from and when — on hover over the name, not on the card.
    private var sourceHelp: String {
        let time = panel.observedAt.map { L("Captured \($0.formatted(date: .abbreviated, time: .shortened))") }
        return [panel.source, time].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// "5 小时" for the session window; a lone long window promoted into its place keeps its own name.
    private var sessionLabel: String {
        panel.sessionFallback == 5 * 3600 ? L("5h") : panel.weeklyLabel
    }

    /// One window on one line; see `QuotaLine`.
    private func quotaRow(label: String, reading: (percent: Int, resetAt: Date?)?, locked: Bool) -> some View {
        let color = locked || panel.stale ? lockedQuotaColor : reading.map { quotaStatusColor($0.percent) } ?? .secondary
        return QuotaLine(label: label, percent: reading?.percent, resetAt: reading?.resetAt, now: now,
                         color: color, isStale: panel.stale)
    }


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
                    .help(sourceHelp)
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


func clampPct(_ percent: Int) -> Int { max(0, min(100, percent)) }

/// A model whose weekly (7g) quota is spent is unusable until it resets — its session number, bar,
/// and 7g dot drop to this muted grey so a fresh 5h window can't read as "available" when the week
/// is gone (the "green even though I can't use it" case).
let lockedQuotaColor = Color.primary.opacity(0.4)

func relDuration(_ resetAt: Date?, _ now: Date) -> String? {
    guard let resetAt, resetAt.timeIntervalSince(now) > 0 else { return nil }
    return TimeFormatter.compact(from: resetAt.timeIntervalSince(now))
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


/// One quota on one line: name, bar, what's left, and the countdown at the end — every card's
/// countdowns line up in one column, so a glance down the right edge says when things reset. The
/// exact reset time is in the hover help rather than on a second line.
struct QuotaLine: View {
    let label: String
    let percent: Int?
    let resetAt: Date?
    let now: Date
    /// Chosen from what's *left*, whichever number is shown — 90% used is red either way.
    let color: Color
    let isStale: Bool
    /// The "显示数值" setting, shared with the menu bar; observed so a change applies at once.
    @AppStorage("tinyusage.showRemaining") private var showRemaining = true

    var body: some View {
        let value = MenuBarRenderer.displayedPercent(remaining: percent, showRemaining: showRemaining)
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    if let value, value > 0 {
                        Capsule().fill(color)
                            .frame(width: max(4, geo.size.width * CGFloat(value) / 100))
                    }
                }
            }
            .frame(height: 6)
            Text(value.map { "\($0)%" } ?? "—")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isStale ? .secondary : color)
                .frame(width: 40, alignment: .trailing)
            Text(relDuration(resetAt, now) ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(height: 18)
        .help(resetHelp)
        .accessibilityElement(children: .combine)
    }

    private var resetHelp: String {
        guard let resetAt, resetAt > now else {
            return showRemaining ? L("\(label) remaining: reset time unknown") : L("\(label) used: reset time unknown")
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(resetAt.timeIntervalSince(now) > 86_400 ? "EEEE HH:mm" : "HH:mm")
        let time = f.string(from: resetAt)
        return showRemaining ? L("\(label) remaining: resets \(time)") : L("\(label) used: resets \(time)")
    }
}

/// Recovery actions for Claude with missing or earlier usage.
struct ClaudeUsageHelp: View {
    let guidance: ClaudeUsageGuidance
    let refreshing: Bool
    let authorize: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guidance.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let detail = guidance.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if guidance.offersAuthorize {
                    Button(L("Authorize query"), action: authorize)
                        .help(L("Reads the Claude login credential from the keychain to query quota; macOS asks only after you confirm"))
                }
                Button(action: refresh) {
                    if refreshing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(L("Reading…"))
                        }
                    } else { Text(L("Refresh")) }
                }
            }
            .controlSize(.small)
            .disabled(refreshing)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Empty is distinct from a real 0% reading. Offer recovery instead of an empty gauge.
struct SetupCard: View {
    let service: ServiceStatus
    let settings: PopoverSettings
    var recovery: ClaudeUsageHelp? = nil
    var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandIconView(iconName: service.iconName, size: 16)
                Text(service.titleWithAccount)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if refreshing {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel(L("Reading"))
                }
            }
            if let recovery {
                recovery
            } else if service.name == AntigravityConfiguration.name {
                Text(AppLanguage.current.text(forKey: service.statusNote ?? AntigravityUsage.signInHintNote))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(refreshing ? L("Reading…") : L("Refresh"), action: settings.refresh)
                    .controlSize(.small)
                    .disabled(refreshing)
            } else if service.name == OpenCodeGoConfiguration.name {
                Text(AppLanguage.current.text(forKey: service.statusNote ?? "OpenCode Go usage is temporarily unavailable"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Configure OpenCode Go"), action: settings.configureOpenCodeGo)
                    .controlSize(.small)
            } else {
                Text(L("Waiting for Codex local usage to update."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(refreshing ? L("Reading…") : L("Refresh"), action: settings.refresh)
                    .controlSize(.small)
                    .disabled(refreshing)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PopoverCardSurface())
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
