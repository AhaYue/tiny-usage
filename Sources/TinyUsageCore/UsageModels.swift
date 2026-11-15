import Foundation

struct ServiceStatus: Identifiable {
    var id: String { name }
    let observedAt: Date?
    let name: String
    let iconName: String
    let sessionResetAt: Date?
    let weeklyResetAt: Date?
    let sessionRemainingPercent: Int?
    let weeklyRemainingPercent: Int?
    /// Real length of the non-session window above, when the provider reports one (Codex does).
    /// The UI labels that window from this rather than assuming 7 days — OpenAI's Go plan uses a
    /// ~30-day window. nil = unknown, and the UI then falls back to its plain weekly label.
    let weeklyWindowSeconds: TimeInterval?
    let monthlyResetAt: Date?
    let monthlyRemainingPercent: Int?
    let models: [ModelStatus]
    let isAvailable: Bool
    /// A localization key or diagnostic text. Translate it at presentation time.
    let statusNote: String?
    /// Last-known data shown because the live source is gone (e.g. the live source was unreachable).
    /// Not "available", but must survive the popover's unavailable-service filter so the
    /// user still sees the snapshot instead of the service silently vanishing.
    let isStale: Bool
    /// Optional explainer surfaced behind an (i) icon on the card — e.g. how the data is
    /// sourced and what the user must do to refresh it.
    let infoText: String?
    /// Transient signal (not displayed) telling `UsageStore` how to update this service's
    /// fetch cooldown: `nil` = leave cooldown unchanged, `0` = clear it (live success),
    /// `> 0` = back off for that many seconds (e.g. an HTTP 429 `Retry-After`).
    let cooldownHint: TimeInterval?
    /// True when the live source has been unreachable long enough (>15 min) that the last-known data
    /// is no longer trustworthy — the UI shows an actionable "couldn't fetch" state (popover banner)
    /// instead of stale numbers. The model labels are kept so
    /// those surfaces still know which rows to render.
    let dataUnavailable: Bool
    /// Which login this card reads — its plan and e-mail, shown under the provider's name so two
    /// cards of one provider can be told apart. nil when the source doesn't say.
    let account: AccountInfo?
    /// Internal identity of the directory or credential that produced this reading.
    let sourceID: String?

    var quotaResetDates: [Date] {
        [sessionResetAt, weeklyResetAt, monthlyResetAt].compactMap { $0 }
    }

    init(
        name: String,
        iconName: String,
        sessionResetAt: Date?,
        weeklyResetAt: Date?,
        sessionRemainingPercent: Int? = nil,
        weeklyRemainingPercent: Int? = nil,
        weeklyWindowSeconds: TimeInterval? = nil,
        monthlyResetAt: Date? = nil,
        monthlyRemainingPercent: Int? = nil,
        models: [ModelStatus],
        isAvailable: Bool,
        statusNote: String?,
        isStale: Bool = false,
        infoText: String? = nil,
        cooldownHint: TimeInterval? = nil,
        dataUnavailable: Bool = false,
        account: AccountInfo? = nil,
        observedAt: Date? = nil,
        sourceID: String? = nil
    ) {
        self.observedAt = observedAt
        self.name = name
        self.iconName = iconName
        self.sessionResetAt = sessionResetAt
        self.weeklyResetAt = weeklyResetAt
        self.sessionRemainingPercent = sessionRemainingPercent
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.weeklyWindowSeconds = weeklyWindowSeconds
        self.monthlyResetAt = monthlyResetAt
        self.monthlyRemainingPercent = monthlyRemainingPercent
        self.models = models
        self.isAvailable = isAvailable
        self.statusNote = statusNote
        self.isStale = isStale
        self.infoText = infoText
        self.cooldownHint = cooldownHint
        self.dataUnavailable = dataUnavailable
        self.account = account
        self.sourceID = sourceID
    }

    /// Return a copy with `infoText` attached. Lets the data layer set the explainer once
    /// at a single chokepoint rather than threading it through every construction site.
    func withInfoText(_ text: String?) -> ServiceStatus {
        copy(infoText: .some(text))
    }

    /// Return a copy with a different `statusNote` — used to stamp an actionable reason
    /// (e.g. "token expired — open Claude Code") onto a loaded snapshot without rebuilding it.
    func withStatusNote(_ note: String?) -> ServiceStatus {
        copy(statusNote: .some(note))
    }

    /// Return a dimmed copy that says why it's old — a reading the live source couldn't confirm.
    func markedStale(_ note: String) -> ServiceStatus {
        copy(statusNote: .some(note), isStale: true)
    }

    /// Return a copy carrying a cooldown signal for `UsageStore` (see `cooldownHint`).
    func withCooldownHint(_ hint: TimeInterval?) -> ServiceStatus {
        copy(cooldownHint: .some(hint))
    }

    /// Return a copy carrying `account`, unless the source already named one — a provider that read
    /// the plan from its own response knows better than the local config file.
    func withAccount(_ account: AccountInfo?) -> ServiceStatus {
        copy(account: .some(self.account ?? account))
    }

    func withModels(_ models: [ModelStatus]) -> ServiceStatus {
        copy(models: models)
    }

    func withObservedAt(_ date: Date?) -> ServiceStatus {
        copy(observedAt: .some(date))
    }

    func withSourceID(_ id: String?) -> ServiceStatus {
        copy(sourceID: .some(id))
    }

    /// The provider's own name — "Claude" for the second login stored as "Claude Work". `name` stays
    /// the card's identity (snapshots, cooldowns); this is what the user reads.
    var providerTitle: String {
        serviceDisplayOrder.first { name == $0 || name.hasPrefix("\($0) ") } ?? name
    }

    /// The provider and the login in one line — "Claude (eray@milowda.com)" — for the places that
    /// have no room for a second line: notifications, the banner.
    var titleWithAccount: String {
        account?.email.map { "\(providerTitle) (\($0))" } ?? providerTitle
    }

    /// One-field copy. Each parameter is a double optional: `nil` keeps the current value,
    /// `.some(x)` overwrites it (so passing `.some(nil)` can clear an optional field).
    private func copy(
        statusNote: String?? = nil,
        isStale: Bool? = nil,
        infoText: String?? = nil,
        cooldownHint: TimeInterval?? = nil,
        account: AccountInfo?? = nil,
        observedAt: Date?? = nil,
        models: [ModelStatus]? = nil,
        sourceID: String?? = nil
    ) -> ServiceStatus {
        ServiceStatus(
            name: name,
            iconName: iconName,
            sessionResetAt: sessionResetAt,
            weeklyResetAt: weeklyResetAt,
            sessionRemainingPercent: sessionRemainingPercent,
            weeklyRemainingPercent: weeklyRemainingPercent,
            weeklyWindowSeconds: weeklyWindowSeconds,
            monthlyResetAt: monthlyResetAt,
            monthlyRemainingPercent: monthlyRemainingPercent,
            models: models ?? self.models,
            isAvailable: isAvailable,
            statusNote: statusNote ?? self.statusNote,
            isStale: isStale ?? self.isStale,
            infoText: infoText ?? self.infoText,
            cooldownHint: cooldownHint ?? self.cooldownHint,
            dataUnavailable: dataUnavailable,
            account: account ?? self.account,
            observedAt: observedAt ?? self.observedAt,
            sourceID: sourceID ?? self.sourceID
        )
    }
}

/// The login behind a card: its plan ("Team", "Plus", "AI Pro") and e-mail for display, and `id` —
/// stable across token refreshes — so two sources that turn out to be one login become one card.
struct AccountInfo: Equatable {
    var plan: String?
    var email: String?
    var id: String?
    /// Claude's organization UUID — what Claude.app's session is matched on, since the app's
    /// organization list carries no account id.
    var org: String? = nil

    /// `claude_team` → "Team", `claude_max` → "Max". Unknown values keep their own word, so a new
    /// plan shows up as itself instead of vanishing.
    /// Max 20x is sold as "Ultra", but its organization type still says `claude_max`; only the
    /// rate-limit tier tells the two apart.
    static func claudePlan(_ organizationType: String?, rateLimitTier: String? = nil) -> String? {
        if organizationType == "claude_max", rateLimitTier?.hasSuffix("max_20x") == true { return "Ultra" }
        return planWord(organizationType.map { $0.hasPrefix("claude_") ? String($0.dropFirst(7)) : $0 })
    }

    /// Codex's `chatgpt_plan_type`: `plus` → "Plus", `team` → "Team". The Pro tiers take the names
    /// Codex's own `/status` gives them, since `prolite`/`promax` don't read as words.
    static func codexPlan(_ planType: String?) -> String? {
        switch planType {
        case "pro": "Pro 200"
        case "prolite": "Pro 100"
        case "promax": "Pro 500"
        default: planWord(planType)
        }
    }

    private static func planWord(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
}

/// Which quota window a model row belongs to. Lets the UI place a row in the weekly
/// summary vs the prominent session block without parsing (localized) labels.
enum ModelWindow {
    case weekly
    case session
}

/// The single top→bottom display order for the services, read by BOTH the popover cards
/// (`PopoverView.contentView`) and the menu bar. Keeping it in one place is load-bearing: when
/// the two defined the order independently they drifted, and a dot lined up with the wrong card.
let serviceDisplayOrder = ["Claude", "Codex", OpenCodeGoConfiguration.name]

extension Array where Element == ServiceStatus {
    /// Sorted into the canonical display order (Claude, Codex); unknown names last.
    /// Shared by the popover's cards and its notification banner so a service can't reorder between them.
    /// A second account ("Claude Work") sits right after its provider's main card.
    func sortedByDisplayOrder() -> [ServiceStatus] {
        func rank(_ name: String) -> Int {
            serviceDisplayOrder.firstIndex { name == $0 || name.hasPrefix("\($0) ") } ?? 99
        }
        return sorted { (rank($0.name), $0.name) < (rank($1.name), $1.name) }
    }
}

/// A second CLI login kept in its own config dir — `~/.claude-work` (`CLAUDE_CONFIG_DIR`) or
/// `~/.codex-work` (`CODEX_HOME`). Each one found becomes its own card, named after the dir's
/// suffix: `~/.codex-work` → "Codex Work". Nobody without such a dir sees any change.
struct ExtraAccount: Equatable {
    let name: String
    let dir: URL

    /// Dirs named `<base>-<suffix>` in the home folder that hold `marker` (the file that proves the
    /// CLI actually uses it), e.g. `~/.codex-work` holding `auth.json`.
    static func find(base: String, title: String, marker: String,
                     home: URL = LiveUsageDataSource.userHome) -> [ExtraAccount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0.hasPrefix("\(base)-") }.sorted().compactMap { entry in
            let suffix = String(entry.dropFirst(base.count + 1))
            let dir = home.appendingPathComponent(entry)
            guard !suffix.isEmpty,
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path) else { return nil }
            return ExtraAccount(name: "\(title) \(suffix.capitalized)", dir: dir)
        }
    }

    static var claude: [ExtraAccount] { find(base: ".claude", title: "Claude", marker: ".claude.json") }
    static var codex: [ExtraAccount] { find(base: ".codex", title: "Codex", marker: "auth.json") }
}

/// One 5-hour session window a service exposes, paired with the weekly (7g) quota that gates it.
/// Claude/Codex carry a single account-level session; a provider with per-model `.session` rows
/// expands to one window per row (its weekly matched by name). The one source of truth for "what
/// gates a 5h window" for the menu-bar dots.
struct SessionWindow: Equatable {
    let label: String
    let sessionPercent: Int?      // nil = no current reading
    let sessionResetAt: Date?
    let weeklyPercent: Int?
    let weeklyResetAt: Date?
    /// Real length of the weekly window, when known, so a 30-day window is labelled as such
    /// instead of "7d". nil for per-model windows and unknown providers.
    var weeklyWindowSeconds: TimeInterval? = nil
}

extension ServiceStatus {
    var sessionWindows: [SessionWindow] {
        // A plan's extra quota (Codex's Luna Reserve) has a session row too, but it's not the
        // account's own: taken here, it replaced Codex's session in the menu bar.
        let sessionModels = models.filter { $0.window == .session && $0.groupLabel == nil }
        if !sessionModels.isEmpty {
            return sessionModels.map { m in
                let weekly = models.first { $0.window == .weekly && $0.name == m.name }
                return SessionWindow(label: m.name, sessionPercent: m.remainingPercent, sessionResetAt: m.resetAt,
                                     weeklyPercent: weekly?.remainingPercent, weeklyResetAt: weekly?.resetAt)
            }
        }
        // No per-model sessions → the account-level session (Claude/Codex). `sessionPercent` may be
        // nil (a service visible only on its weekly reading): kept as one window so the menu bar still
        // shows a placeholder dot.
        return [SessionWindow(label: name, sessionPercent: sessionRemainingPercent, sessionResetAt: sessionResetAt,
                              weeklyPercent: weeklyRemainingPercent, weeklyResetAt: weeklyResetAt,
                              weeklyWindowSeconds: weeklyWindowSeconds)]
    }
}

struct ModelStatus: Identifiable {
    static let renewalCreditGroup = "renewal-credit"
    static let weeklyRenewalScope = "weekly-quota"
    static let allModelsRenewalScope = "all-models"

    let id = UUID()
    let name: String
    let remainingPercent: Int
    let resetAt: Date?
    let valueText: String?
    /// For a `valueText` row (e.g. a credit balance) whose level isn't a 0–100 percent: set true
    /// when it's below its threshold, so the menu-bar low-quota badge can trigger on it. Percentage
    /// rows leave this false and are judged by `remainingPercent` instead.
    let isLow: Bool
    /// Weekly vs session window. `nil` for credit rows.
    let window: ModelWindow?
    /// Sub-line under a `valueText` row (e.g. "first expires in 3d" under the reset credits count).
    let caption: String?
    /// SF Symbol drawn left of a `valueText` row's label. nil → no icon.
    let symbol: String?
    /// Stable key identifying the group a row belongs to. A nil key denotes a standalone row.
    let groupLabel: String?

    /// Older snapshots and live providers can carry either localized spelling of a billing label.
    var displayValueRowName: String {
        if AppLanguage.matches(name, key: "Spending") { return L("Spending") }
        if AppLanguage.matches(name, key: "Credit balance") { return L("Credit balance") }
        if symbol == "cloud" {
            for language in [AppLanguage.english, .simplifiedChinese] {
                let label = language.text("Cloud credit")
                if name == label || name.hasPrefix(label + " ") {
                    return L("Cloud credit") + name.dropFirst(label.count)
                }
            }
        }
        return name
    }

    var displayValueRowText: String? {
        guard let valueText, AppLanguage.matches(name, key: "Credit balance") else { return valueText }
        if AppLanguage.matches(valueText, key: "Unlimited") { return L("Unlimited") }
        for language in [AppLanguage.english, .simplifiedChinese] {
            // The balance is stored as a number followed by the locale's unit.
            let suffix = language.text("%@ credits").dropFirst(2)
            if valueText.hasSuffix(suffix) {
                let amount = String(valueText.dropLast(suffix.count))
                return String(format: L("%@ credits"), amount)
            }
        }
        return valueText
    }

    var renewalScopeLabel: String? {
        switch caption {
        case Self.weeklyRenewalScope: L("Weekly quota")
        case Self.allModelsRenewalScope: L("All models")
        default: caption
        }
    }

    init(name: String, remainingPercent: Int, resetAt: Date?, valueText: String? = nil, isLow: Bool = false,
         window: ModelWindow? = nil, caption: String? = nil, symbol: String? = nil,
         groupLabel: String? = nil) {
        self.name = name
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.valueText = valueText
        self.isLow = isLow
        self.window = window
        self.caption = caption
        self.symbol = symbol
        self.groupLabel = groupLabel
    }
}

enum TimeFormatter {
    /// Localised single-letter unit suffixes — en: d/h/m, tr: g/s/d.
    static var dayUnit: String { L("duration.unit.day") }
    static var hourUnit: String { L("duration.unit.hour") }
    static var minuteUnit: String { L("duration.unit.minute") }

    /// Countdown in the panel's compact form — "6d 20h", "2h 30m" — whatever the UI language, so
    /// the countdown column stays narrow and every row reads the same.
    static func compact(from interval: TimeInterval) -> String {
        duration(from: interval, day: "d", hour: "h", minute: "m")
    }

    static func duration(from interval: TimeInterval) -> String {
        duration(from: interval, day: dayUnit, hour: hourUnit, minute: minuteUnit)
    }

    /// Unit-injectable core so the numeric breakdown can be unit-tested without a locale,
    /// and so the localised suffixes are applied in exactly one place.
    static func duration(from interval: TimeInterval, day: String, hour: String, minute: String) -> String {
        let clamped = max(0, Int(interval.rounded(.down)))
        let days = clamped / 86_400
        let hours = (clamped % 86_400) / 3_600
        let minutes = (clamped % 3_600) / 60

        if days > 0 {
            if hours > 0 { return "\(days)\(day) \(hours)\(hour)" }
            return "\(days)\(day)"
        }

        if hours > 0 {
            if minutes > 0 { return "\(hours)\(hour) \(minutes)\(minute)" }
            return "\(hours)\(hour)"
        }

        return "\(max(minutes, 1))\(minute)"
    }
}

/// Has the reset we armed come round? A refill is announced off the window's own reset CLOCK rather
/// than off a percent jumping back to 100 — a reading can flicker to full for reasons that aren't a
/// reset (a partial response, the local session file standing in for the usage API), which is what
/// announced "quota refilled" mid-month on a 30-day ChatGPT Go window. `announced` pins the reset we
/// already told the user about, so a relaunch can't repeat it.
func refillIsDue(armed: Double, announced: Double, now: Double) -> Bool {
    armed > 0 && now >= armed && announced != armed
}

/// The reset to arm next, or nil to leave the current arming alone: only when nothing is armed, the
/// reset is still in the future, and it isn't the one already announced (so the data rolling forward
/// at reset time can't clobber a refill we still owe).
func nextArmedReset(armed: Double, announced: Double, resetAt: Date?, now: Date) -> Double? {
    guard armed == 0, let resetAt else { return nil }
    let stamp = resetAt.timeIntervalSince1970
    guard stamp > now.timeIntervalSince1970, stamp != announced else { return nil }
    return stamp
}

/// Remaining-percent at which a long quota window counts as "running out". Anchored on the 7-day
/// week's 10%: a flat percent warns far too early on a longer window — 10% of a 30-day ChatGPT Go
/// quota is three days' worth of budget still in hand, announced as if the month were over. Scaling
/// by length puts the warning at a comparable time-to-empty instead, with a 5% floor so it can never
/// tighten to the point of arriving too late to act on. Windows at or under the base keep the base.
func lowQuotaThreshold(windowSeconds: TimeInterval?,
                       base: Int = 10,
                       baseWindow: TimeInterval = 7 * 86_400,
                       floor: Int = 5) -> Int {
    guard let windowSeconds, windowSeconds > baseWindow else { return base }
    return max(floor, Int((Double(base) * baseWindow / windowSeconds).rounded()))
}

/// Should the low-quota warning fire? Once per window, keyed on the reset it belongs to. Codex's
/// 5-hour `reset_at` drifts forward WITHIN a window (it's anchored on usage, not on a fixed clock),
/// so plain "stamp changed" re-warned every poll while the quota sat at zero. A reset we've already
/// warned about that hasn't come round yet means we're still inside that same window: stay quiet
/// until it passes. A service reporting no reset at all stores 0 and warns once, as before.
func lowAlertIsDue(lastWarnedReset: Double?, resetStamp: Double, now: Double) -> Bool {
    guard let last = lastWarnedReset else { return true }
    return last != resetStamp && last <= now
}
