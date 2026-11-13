import AppKit
import Combine
import ServiceManagement
import SwiftUI

private final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
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
    private let demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--smoke-test")
    private var style: MenuBarRenderer.Style {
        MenuBarRenderer.Style(rawValue: UserDefaults.standard.integer(forKey: "ay.menuStyle")) ?? .bars
    }
    private var remaining: Bool { UserDefaults.standard.bool(forKey: "ay.showRemaining") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["ay.showRemaining": true, "ay.menuStyle": 0])
        NSApp.setActivationPolicy(.accessory)
        if demo { store.services = DemoData.services() }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "ayusage" {
            switch url.host {
            case "hide": hidePanel()
            case "toggle-display": toggleRemaining()
            case "refresh": if !demo { store.refresh(force: true) }
            default: showPanel()
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        removeMonitors()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func renderTitle() {
        guard let button = statusItem?.button else { return }
        var services = store.services.sortedByDisplayOrder()
        // Bound width on crowded menu bars; all accounts remain in the panel and tooltip.
        let budget = max(100, (button.window?.screen?.auxiliaryTopRightArea?.width
            ?? button.window?.screen?.frame.width ?? 900) - 260)
        while services.count > 1 && MenuBarRenderer.image(services: services, style: style, remaining: remaining, now: Date()).size.width > budget {
            services.removeLast()
        }
        button.image = MenuBarRenderer.image(services: services, style: style, remaining: remaining, now: Date())
        button.imagePosition = .imageOnly
        button.toolTip = "AY Usage\n" + MenuBarRenderer.tooltip(services: store.services, remaining: remaining)
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
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
        host.layer?.cornerRadius = 20
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
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            launchAtLogin: { SMAppService.mainApp.status == .enabled },
            toggleLaunchAtLogin: { [weak self] in self?.toggleLogin() },
            claudeHook: { MimirStatusLineHook.isWired() },
            toggleClaudeHook: { [weak self] in self?.toggleHook() },
            desktopFallback: { UserDefaults.standard.bool(forKey: "ay.desktopFallbackEnabled") },
            toggleDesktopFallback: { [weak self] in
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "ay.desktopFallbackEnabled"), forKey: "ay.desktopFallbackEnabled")
                if self?.demo == false, RefreshMode.current != .manual { self?.lastAutoRefresh = Date(); self?.store.refresh() }
            },
            showRemaining: { [weak self] in self?.remaining ?? true },
            toggleShowRemaining: { [weak self] in self?.toggleRemaining() },
            menuStyle: { [weak self] in self?.style.label ?? "双条" },
            cycleMenuStyle: { [weak self] in self?.cycleStyle() },
            refreshMode: { RefreshMode.current.summary },
            cycleRefreshMode: { UserDefaults.standard.set(RefreshMode.current.next.rawValue, forKey: RefreshMode.defaultsKey) },
            authorizeCredentials: { [weak self] in if self?.demo == false { self?.store.refresh(userInitiated: true, force: true) } },
            refresh: { [weak self] in if self?.demo == false { self?.store.refresh(force: true) } },
            openDataFolder: {
                try? FileManager.default.createDirectory(at: LiveUsageDataSource.supportDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(LiveUsageDataSource.supportDirectory)
            },
            quit: { NSApp.terminate(nil) }
        )
    }
    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert("无法更改开机启动", error.localizedDescription) }
    }
    private func toggleHook() {
        guard !demo else { alert("演示模式", "演示模式不会修改 Claude Code 配置。"); return }
        let result = MimirStatusLineHook.isWired() ? MimirStatusLineHook.disable() : MimirStatusLineHook.enable()
        switch result {
        case .failed(let message): alert("状态栏采集未更改", message)
        case .alreadyOn: alert("已存在采集配置", "如果已安装 Mimir hook，AY Usage 会直接读取它，无需重复注入。")
        case .enabled, .chained: alert("已启用本地配额采集", "原状态栏会继续运行。Claude Code 下次更新状态栏后会出现配额；可在此关闭并恢复原配置。")
        case .disabled: break
        }
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
        UserDefaults.standard.set(!remaining, forKey: "ay.showRemaining")
        renderTitle()
    }
    @objc private func cycleStyle() {
        UserDefaults.standard.set((style.rawValue + 1) % MenuBarRenderer.Style.allCases.count, forKey: "ay.menuStyle")
        renderTitle()
    }
    @objc private func refreshNow() { if !demo { store.refresh(force: true) } }
    @objc private func quit() { NSApp.terminate(nil) }
    private func showContextMenu() {
        let menu = NSMenu()
        for (title, action) in [("打开 AY Usage", #selector(togglePanel)), ("刷新配额", #selector(refreshNow)),
                                (remaining ? "切换为已用量" : "切换为剩余量", #selector(toggleRemaining)),
                                ("菜单栏样式：\(style.label)", #selector(cycleStyle)), ("退出 AY Usage", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        guard let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
}
