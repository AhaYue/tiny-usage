import AppKit
import Combine
import ServiceManagement
import SwiftUI

private final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    override public init() {
        demo = ["--demo", "--render-preview", "--smoke-test"].contains { CommandLine.arguments.contains($0) }
        store = UsageStore(services: demo ? DemoData.services() : nil)
        super.init()
    }
    private let store: UsageStore
    private var statusItem: NSStatusItem?
    private var panel: QuotaPanel?
    private var timer: Timer?
    private var subscribers: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isSleeping = false
    /// When the background tick last read local sources — paces it to `RefreshMode.localInterval`.
    private var lastAutoRefresh: Date?
    private var updater: AppUpdater?
    private let demo: Bool
    private var style: MenuBarRenderer.Style {
        MenuBarRenderer.Style(rawValue: UserDefaults.standard.integer(forKey: "tinyusage.menuStyle")) ?? .bars
    }
    private var remaining: Bool { UserDefaults.standard.bool(forKey: "tinyusage.showRemaining") }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["tinyusage.showRemaining": true, "tinyusage.menuStyle": 0])
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            PreviewRenderer.render(store: store, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        store.$services.receive(on: RunLoop.main).sink { [weak self] _ in self?.renderTitle() }.store(in: &subscribers)
        NSApp.publisher(for: \.effectiveAppearance).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderTitle() }.store(in: &subscribers)
        renderTitle()
        wireClaudeHookIfNeeded()
        if !demo { updater = AppUpdater() }
        if !demo, RefreshMode.current != .manual { lastAutoRefresh = Date(); store.refresh() }
        startTimer()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isSleeping = true; self?.timer?.invalidate(); self?.timer = nil }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSleeping = false
                self?.startTimer()
                self?.renderTitle()
                if self?.demo == false, RefreshMode.current != .manual { self?.lastAutoRefresh = Date(); self?.store.refresh() }
            }
        })
        if CommandLine.arguments.contains("--show-panel") { showPanel() }
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.indices.contains(index + 1) {
            runSmokeTest(in: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if !demo { showFirstUsePanelIfNeeded() }
    }

    // MARK: - Local first, authorization only for the extras

    static let hookRemovedKey = "tinyusage.claudeHookRemoved"
    static let didAuthorizeKey = "tinyusage.didAuthorizeClaude"

    /// Claude's usage is read locally by default: the status-line hook is wired silently, keeping
    /// any status line the user already has. Only a removal from About keeps it off. Never in demo,
    /// smoke-test or isolated-test runs, which must not touch the real Claude Code config.
    private func wireClaudeHookIfNeeded() {
        guard !demo, !CommandLine.arguments.contains("--smoke-test"),
              ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] == nil,
              !UserDefaults.standard.bool(forKey: Self.hookRemovedKey) else { return }
        // An app update brings a new capture helper; the installed copy follows it.
        ClaudeStatusLineHook.refreshCapture()
        guard !ClaudeStatusLineHook.isWired() else { return }
        ClaudeStatusLineHook.enable()
    }

    /// About's fallback switch. Removing is remembered so launch doesn't wire it straight back.
    private func setClaudeHook(_ on: Bool) {
        guard !demo else { return }
        if case .failed(let message) = on ? ClaudeStatusLineHook.enable() : ClaudeStatusLineHook.disable() {
            alert(on ? L("Couldn't connect the Claude status line") : L("Couldn't disconnect the Claude status line"), message)
            return
        }
        UserDefaults.standard.set(!on, forKey: Self.hookRemovedKey)
        store.refresh(force: true)
    }


    private static let didOfferLocalKey = "tinyusage.didOfferLocal"

    /// First use opens the inline setup card; enabling capture needs no extra modal.
    private func showFirstUsePanelIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didOfferLocalKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.didOfferLocalKey)
        if store.services.contains(where: { $0.name == "Claude" && !$0.isAvailable }) { showPanel() }
    }

    /// The only path that may show the macOS keychain dialog, and only after this confirmation.
    /// Only the fact of having asked is remembered (it hides the card's hint): a granted source is
    /// read silently on every refresh from then on, a refused one simply stays unavailable, and
    /// the button can be pressed again.
    private func authorize() {
        guard !demo else { return }
        let alert = NSAlert()
        alert.messageText = L("Authorize viewing Claude reset credits?")
        alert.informativeText = L("Only reads the login credential to query reset credits and the full quota; it doesn't change your login. When macOS asks, choose “Always Allow” and it won't ask again.")
        alert.addButton(withTitle: L("Authorize"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(true, forKey: Self.didAuthorizeKey)
        store.refresh(userInitiated: true, force: true)
    }

    private func configureOpenCodeGo() {
        guard !demo else { return }
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)

        let dialog = NSAlert()
        dialog.messageText = L("Configure OpenCode Go")
        dialog.informativeText = L("Use the key already connected in OpenCode, or enter a personal key from the Go subscription’s workspace.")
        dialog.addButton(withTitle: L("Use OpenCode key"))
        dialog.addButton(withTitle: L("Enter personal key"))
        dialog.addButton(withTitle: L("Cancel")).keyEquivalent = "\u{1b}"
        let connected = OpenCodeGoConfiguration.mode != .disabled
        if connected {
            dialog.addButton(withTitle: L("Disconnect")).hasDestructiveAction = true
        }
        dialog.addButton(withTitle: L("Open billing"))
        let answer = dialog.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch (answer, connected) {
        case (0, _): updateOpenCodeGo(.reuse)
        case (1, _):
            let keyDialog = NSAlert()
            keyDialog.messageText = L("Enter an OpenCode Go key")
            keyDialog.informativeText = L("The key is stored in your Mac’s keychain.")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = L("Personal API key")
            keyDialog.accessoryView = field
            keyDialog.addButton(withTitle: L("Save"))
            keyDialog.addButton(withTitle: L("Cancel"))
            keyDialog.window.initialFirstResponder = field
            if keyDialog.runModal() == .alertFirstButtonReturn {
                updateOpenCodeGo(.personalKey, personalKey: field.stringValue)
            }
        case (3, true): updateOpenCodeGo(.disabled)
        case (4, true), (3, false):
            if let url = URL(string: "https://opencode.ai/console") { NSWorkspace.shared.open(url) }
            return
        default: break
        }
        showPanel()
    }

    private func updateOpenCodeGo(_ mode: OpenCodeGoConfiguration.Mode, personalKey: String? = nil) {
        do {
            try OpenCodeGoConfiguration.setMode(mode, personalKey: personalKey)
            store.openCodeConfigurationChanged()
        } catch {
            alert(L("Configure OpenCode Go"), error.localizedDescription)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSleeping else { return }
                self.renderTitle()
                // The redraw above is every minute; reading files and the network follows the
                // user's refresh setting.
                let now = Date()
                if !self.demo, RefreshMode.current.tickShouldRefresh(lastRefresh: self.lastAutoRefresh, now: now) {
                    self.lastAutoRefresh = now
                    self.store.refresh()
                }
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "tinyusage" {
            switch url.host {
            case "hide": hidePanel()
            case "toggle-display": toggleRemaining()
            case "refresh": if !demo { store.refresh(force: true) }
            default: showPanel()
            }
        }
    }
    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        removeMonitors()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func renderTitle() {
        guard let button = statusItem?.button else { return }
        let selected = MenuBarProvider.selectedServices(from: store.services, selection: MenuBarProvider.selection())
        var services = selected.sortedByDisplayOrder()
        // Bound width on crowded menu bars; the tooltip still lists every selected account.
        let budget = max(100, (button.window?.screen?.auxiliaryTopRightArea?.width
            ?? button.window?.screen?.frame.width ?? 900) - 260)
        let style = self.style, remaining = self.remaining, now = Date()
        var image = MenuBarRenderer.image(services: services, style: style, remaining: remaining, now: now)
        while services.count > 1 && image.size.width > budget {
            services.removeLast()
            image = MenuBarRenderer.image(services: services, style: style, remaining: remaining, now: now)
        }
        let widthChanged = button.image?.size.width != image.size.width
        button.image = image
        button.imagePosition = .imageOnly
        let usage = MenuBarRenderer.tooltip(services: selected, remaining: remaining)
        button.toolTip = usage.isEmpty ? "Tiny Usage" : "Tiny Usage\n" + usage
        button.setAccessibilityLabel(button.toolTip)
        if widthChanged, panel?.isVisible == true {
            DispatchQueue.main.async { [weak self] in self?.positionPanel() }
        }
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }
    private func showPanel() {
        if panel?.isVisible == true { panel?.makeKey(); return }
        let panel = QuotaPanel(contentRect: NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: 500),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel
        let host = NSHostingView(rootView: PopoverView(
            store: store,
            onDismiss: { [weak self] in self?.hidePanel() },
            onContentHeightChange: { [weak self] height in self?.resizePanel(height) },
            settings: settings()
        ))
        host.wantsLayer = true
        host.layer?.cornerRadius = PopoverMetrics.panelCornerRadius
        host.layer?.masksToBounds = true
        panel.contentView = host
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hidePanel() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 { self?.hidePanel(); return nil }
            if event.type != .keyDown, let window = event.window, window !== self?.panel,
               window !== self?.statusItem?.button?.window { self?.hidePanel() }
            return event
        }
    }
    private func resizePanel(_ height: CGFloat) {
        guard let panel else { return }
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let maximum = min(PopoverMetrics.maxHeight, (screen?.visibleFrame.height ?? 900) - 30)
        panel.setContentSize(NSSize(width: PopoverMetrics.width, height: min(maximum, max(120, height))))
        positionPanel()
    }
    private func positionPanel() {
        guard let panel, let button = statusItem?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = max(visible.minX + 8, min(anchor.midX - panel.frame.width / 2, visible.maxX - panel.frame.width - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 8, anchor.minY - panel.frame.height - 6)))
    }
    private func hidePanel() {
        removeMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil  // Release the view tree and its TimelineView while hidden.
        panel?.close()
        panel = nil
    }
    private func removeMonitors() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
    }
    private func settings() -> PopoverSettings {
        PopoverSettings(
            launchAtLogin: { SMAppService.mainApp.status == .enabled },
            toggleLaunchAtLogin: { [weak self] in self?.toggleLogin() },
            localCaptureState: { ClaudeLocalCaptureState.current() },
            showRemaining: { [weak self] in self?.remaining ?? true },
            setShowRemaining: { [weak self] in UserDefaults.standard.set($0, forKey: "tinyusage.showRemaining"); self?.renderTitle() },
            menuStyle: { [weak self] in self?.style.rawValue ?? 0 },
            setMenuStyle: { [weak self] in UserDefaults.standard.set($0, forKey: "tinyusage.menuStyle"); self?.renderTitle() },
            menuBarProviders: { MenuBarProvider.selection() },
            setMenuBarProviders: { [weak self] in MenuBarProvider.save($0); self?.renderTitle() },
            refreshMode: { RefreshMode.current.rawValue },
            setRefreshMode: { UserDefaults.standard.set($0, forKey: RefreshMode.defaultsKey) },
            languageDidChange: { [weak self] in
                guard let self else { return }
                self.renderTitle()
                if let aboutWindow = self.aboutWindow { self.localizeAboutWindow(aboutWindow) }
            },
            authorize: { [weak self] in self?.authorize() },
            didAuthorize: { UserDefaults.standard.bool(forKey: Self.didAuthorizeKey) },
            refresh: { [weak self] in if self?.demo == false { self?.store.refresh(force: true) } },
            configureOpenCodeGo: { [weak self] in self?.configureOpenCodeGo() },
            openDataFolder: {
                try? FileManager.default.createDirectory(at: LiveUsageDataSource.supportDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(LiveUsageDataSource.supportDirectory)
            },
            about: { [weak self] in self?.showAbout() },
            canCheckForUpdates: updater?.isAvailable == true,
            checkForUpdates: { [weak self] in self?.hidePanel(); self?.updater?.checkForUpdates() },
            quit: { NSApp.terminate(nil) }
        )
    }
    private var aboutWindow: NSWindow?
    /// A plain window rather than a third popover face: license text is long and wants to scroll
    /// and be selectable, and it should stay open while the popover closes.
    private func showAbout() {
        hidePanel()
        if aboutWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            localizeAboutWindow(window)
            window.center()
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }
    private func localizeAboutWindow(_ window: NSWindow) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        window.title = L("About Tiny Usage")
        window.contentView = NSHostingView(rootView: AboutView(
            version: version, hookWired: { ClaudeStatusLineHook.isWired() },
            setHook: { [weak self] in self?.setClaudeHook($0) }))
    }
    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert(L("Couldn't change launch at login"), error.localizedDescription) }
    }
    /// Drive our own AppKit button and window; no Accessibility or screen-recording permission.
    /// Explicit smoke-test mode uses synthetic data and never installs hooks or accesses logins.
    private func runSmokeTest(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture(_ name: String) {
            guard let view = self.panel?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent(name))
            }
        }
        statusItem?.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let opened = self.panel?.isVisible == true
            capture("window-quota.png")
            if let panel = self.panel {
                let point = NSPoint(x: panel.frame.width - 33, y: panel.frame.height - 25)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                        panel.sendEvent(event)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                capture("window-settings.png")
                let oldDisplay = self.remaining
                self.toggleRemaining()
                let changed = oldDisplay != self.remaining
                self.toggleRemaining()
                self.hidePanel()
                let released = self.panel == nil
                self.statusItem?.button?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    let reopened = self.panel?.isVisible == true
                    capture("window-reopened.png")
                    self.hidePanel()
                    self.showAbout()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        if let view = self?.aboutWindow?.contentView,
                           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?
                                .write(to: directory.appendingPathComponent("window-about.png"))
                        }
                        self?.aboutWindow?.close()
                    }
                    let result: [String: Any] = ["mode": "synthetic", "panelOpened": opened, "displayToggle": changed,
                                                 "panelReleasedOnHide": released, "panelReopened": reopened,
                                                 "settingsClickSent": true]
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: directory.appendingPathComponent("smoke-result.json"))
                    }
                }
            }
        }
    }

    @objc private func toggleRemaining() {
        UserDefaults.standard.set(!remaining, forKey: "tinyusage.showRemaining")
        renderTitle()
    }
}
