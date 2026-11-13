import AppKit

/// Original AY Usage renderer: one native image, no image files or web runtime.
enum MenuBarRenderer {
    enum Style: Int, CaseIterable {
        case bars, percent, both
        var label: String { ["双条", "百分比", "双条＋百分比"][rawValue] }
    }
    static func displayedPercent(remaining: Int?, showRemaining: Bool) -> Int? {
        remaining.map { showRemaining ? max(0, min(100, $0)) : 100 - max(0, min(100, $0)) }
    }
    static func timePosition(resetAt: Date?, duration: TimeInterval?, remaining: Bool, now: Date) -> Double? {
        guard let resetAt, let duration, duration > 0, duration.isFinite, resetAt > now else { return nil }
        let left = max(0, min(1, resetAt.timeIntervalSince(now) / duration))
        return remaining ? left : 1 - left
    }
    @MainActor
    static func image(services: [ServiceStatus], style: Style, remaining: Bool, now: Date) -> NSImage {
        let entries = services.sortedByDisplayOrder()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let textWidths = entries.map { ceil(percentText(service: $0, remaining: remaining, font: font).size().width) }
        let widths = textWidths.map { 16 + (style == .percent ? 0 : 48) + (style == .bars ? 0 : $0 + 5) }
        let width = max(22, widths.reduce(0, +) + CGFloat(max(0, entries.count - 1)) * 16)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, service) in entries.enumerated() {
                if index > 0 {
                    NSColor.separatorColor.setFill()
                    NSRect(x: x + 7, y: 5, width: 1, height: 12).fill()
                    x += 16
                }
                let mark = BrandIconLoader.image(named: service.iconName)
                    ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: service.providerTitle)
                if let mark {
                    let rect = NSRect(x: x, y: 3, width: 16, height: 16)
                    NSColor.labelColor.setFill()
                    // Draw a template into an offscreen image so its colour follows appearance.
                    let tinted = NSImage(size: rect.size, flipped: false) { bounds in
                        mark.draw(in: bounds)
                        NSColor.labelColor.setFill()
                        bounds.fill(using: .sourceIn)
                        return true
                    }
                    tinted.draw(in: rect)
                }
                x += 16
                if style != .percent {
                    x += 5
                    let windows: [(Int?, Date?, TimeInterval?)] = [
                        (service.sessionRemainingPercent, service.sessionResetAt, 18_000),
                        (service.weeklyRemainingPercent, service.weeklyResetAt,
                         service.weeklyWindowSeconds ?? (service.iconName == "claude" ? 604_800 : nil))
                    ]
                    for (row, window) in windows.enumerated() {
                        let y: CGFloat = row == 0 ? 12 : 5
                        let track = NSRect(x: x, y: y, width: 43, height: 4)
                        NSColor.labelColor.withAlphaComponent(0.19).setFill()
                        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                        guard let quota = window.0 else { continue }
                        let value = displayedPercent(remaining: quota, showRemaining: remaining) ?? 0
                        let color = barColor(service: service, remaining: quota)
                        if value > 0 {
                            color.setFill()
                            let filled = NSRect(x: x, y: y, width: max(1, 43 * CGFloat(value) / 100), height: 4)
                            NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
                        }
                        // Time cursor, moving the same way as the bar: in "remaining" mode it is the
                        // time left (right → left), in "used" mode the time gone (left → right). Fill
                        // past the cursor = ahead of the clock. Position only — it never sets colour.
                        if let position = timePosition(resetAt: window.1, duration: window.2, remaining: remaining, now: now),
                           service.isAvailable, !service.isStale {
                            NSColor.labelColor.withAlphaComponent(0.7).setFill()
                            let cx = (x + 43 * CGFloat(position)).rounded() - 0.5
                            NSRect(x: max(x, min(x + 42, cx)), y: y - 1.5, width: 1, height: 7).fill()
                        }
                    }
                    x += 43
                }
                if style != .bars {
                    x += 5
                    percentText(service: service, remaining: remaining, font: font)
                        .draw(at: NSPoint(x: x, y: 4))
                    x += textWidths[index]
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
    /// Battery-style colour for one window: by what's left, whatever the bar is showing. A reading
    /// that isn't live (stale snapshot, unavailable) stays grey so it can't pass for current.
    static func barColor(service: ServiceStatus, remaining quota: Int) -> NSColor {
        service.isStale || !service.isAvailable ? .secondaryLabelColor : QuotaLevel(remaining: quota).color
    }

    /// "62%·30%", each number in its own window's colour.
    static func percentText(service: ServiceStatus, remaining: Bool, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, quota) in [service.sessionRemainingPercent, service.weeklyRemainingPercent].enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "·", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
            let shown = displayedPercent(remaining: quota, showRemaining: remaining).map { "\($0)%" } ?? "—"
            let color = quota.map { barColor(service: service, remaining: $0) } ?? .secondaryLabelColor
            out.append(NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    static func tooltip(services: [ServiceStatus], remaining: Bool) -> String {
        let suffix = remaining ? "剩余" : "已用"
        return services.sortedByDisplayOrder().map { service in
            let five = displayedPercent(remaining: service.sessionRemainingPercent, showRemaining: remaining).map { "\($0)%" } ?? "未知"
            let long = displayedPercent(remaining: service.weeklyRemainingPercent, showRemaining: remaining).map { "\($0)%" } ?? "未知"
            return "\(service.titleWithAccount)：5h \(suffix) \(five)，长期 \(suffix) \(long)\(service.isStale ? " · 旧数据" : "")"
        }.joined(separator: "\n")
    }
}
