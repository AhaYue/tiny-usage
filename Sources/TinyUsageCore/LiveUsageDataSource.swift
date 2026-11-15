import Foundation
import Security

@MainActor
final class UsageStore: ObservableObject {
    /// Launch shows the last-known readings straight away. The first refresh waits for all three
    /// providers — up to their 8-second timeouts — and until then the popover had nothing to draw
    /// but a spinner, on every launch and after every update.
    @Published var services: [ServiceStatus] = LiveUsageDataSource.fallbackServices().map {
        LiveUsageDataSource().snapshotOrFallback($0.name, iconName: $0.iconName)
    }
    @Published var isRefreshing = false
    private let source = LiveUsageDataSource()
    /// Per-service fetch cooldown: while `Date()` is before the stored value, that service is
    /// served from its snapshot instead of hitting the network (set after an HTTP 429 / expired
    /// token; cleared on the next live success). Stops Tiny Usage hammering a failing endpoint.
    private var schedule = AdaptiveUsageSchedule()
    private var pendingRefresh = false
    private var pendingAuthorization = false

    /// Services whose "couldn't fetch" banner the user dismissed. Persisted so it survives a
    /// relaunch, but cleared as soon as the service reports data again — otherwise one dismissal
    /// would silence every future outage for that provider.
    @Published private(set) var dismissedUnavailable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: UsageStore.dismissedKey) ?? [])

    private static let dismissedKey = "popover.dismissedUnavailable"

    func dismissUnavailable(_ name: String) {
        guard dismissedUnavailable.insert(name).inserted else { return }
        UserDefaults.standard.set(Array(dismissedUnavailable), forKey: Self.dismissedKey)
    }

    /// Only the explicit Authorize action passes `userInitiated: true` to permit a keychain dialog.
    /// Manual refresh, panel opening, and background refresh keep keychain access silent. An
    /// authorization asked for mid-refresh is queued, not dropped.
    func refresh(userInitiated: Bool = false, force: Bool = false) {
        guard !isRefreshing else {
            pendingRefresh = pendingRefresh || force || userInitiated
            pendingAuthorization = pendingAuthorization || userInitiated
            return
        }
        isRefreshing = true
        let now = Date()
        let skip = schedule.skipped(now: now, manual: force || userInitiated)
        let source = self.source
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await source.fetchAll(skip: skip, userInitiated: userInitiated).sorted { $0.name < $1.name }
            }.value
            defer {
                self.isRefreshing = false
                if self.pendingRefresh {
                    let authorize = self.pendingAuthorization
                    self.pendingRefresh = false
                    self.pendingAuthorization = false
                    self.refresh(userInitiated: authorize, force: true)
                }
            }
            let mode = RefreshMode.current
            for status in result where !skip.contains(status.name) { self.schedule.record(status, now: Date(), mode: mode) }
            let resolved = result.map { status -> ServiceStatus in
                guard skip.contains(status.name), let previous = self.services.first(where: { $0.name == status.name }),
                      previous.isAvailable, !previous.isStale, let observed = previous.observedAt,
                      Date().timeIntervalSince(observed) < 1800,
                      [previous.sessionResetAt, previous.weeklyResetAt].compactMap({ $0 }).allSatisfy({ $0 > Date() }) else { return status }
                // Waiting for the next scheduled request is not a fetch failure. Keep a valid
                // recent reading unless a local source actually supplied newer data.
                if let newer = status.observedAt, newer > observed, status.isAvailable { return status }
                return previous
            }
            self.forgetRecoveredDismissals(resolved)
            self.services = resolved
        }
    }

    /// Drop dismissals for services that are no longer down, so the banner returns on the next
    /// genuine outage instead of staying hidden forever.
    func forgetRecoveredDismissals(_ result: [ServiceStatus]) {
        let stillDown = Set(result.filter(\.dataUnavailable).map(\.name))
        guard !dismissedUnavailable.isSubset(of: stillDown) else { return }
        dismissedUnavailable.formIntersection(stillDown)
        UserDefaults.standard.set(Array(dismissedUnavailable), forKey: Self.dismissedKey)
    }

}

struct LiveUsageDataSource {
    static func fallbackServices() -> [ServiceStatus] {
        [
            ServiceStatus(
                name: "Claude",
                iconName: "claude",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [],
                isAvailable: false,
                statusNote: L("no local source")
            ),
            ServiceStatus(
                name: "Codex",
                iconName: "codex",
                sessionResetAt: nil,
                weeklyResetAt: nil,
                models: [],
                isAvailable: false,
                statusNote: L("no local source")
            )
        ]
    }

    /// Fetch every service. Services named in `skip` are in a fetch cooldown (e.g. after a 429)
    /// and are served from their snapshot instead of hitting the network. A live fetch that times
    /// out also falls back to the snapshot, so a transient failure never empties a card.
    func fetchAll(skip: Set<String> = [], userInitiated: Bool = false) async -> [ServiceStatus] {
        let order = ["Claude", "Codex"]
        // A second config dir signed in to a login another card already reads is the same account:
        // one card, not two. Read from local profiles only, so this costs no request.
        let claudeMain = Self.claudeAccount(configFile: ClaudeStatusLineHook.claudeConfigFile)
        let codexMain = codexAccount(home: nil)
        let claudeExtras = Self.distinct(ExtraAccount.claude, seen: claudeMain?.id) {
            Self.claudeAccount(configFile: $0.dir.appendingPathComponent(".claude.json"))
        }
        let codexExtras = Self.distinct(ExtraAccount.codex, seen: codexMain?.id) { codexAccount(home: $0.dir) }

        return await withTaskGroup(of: [ServiceStatus].self) { group in
            group.addTask {
                if skip.contains("Claude") {
                    let card = self.readClaudeHookUsage(maxAge: 30 * 60).map { self.claudeCardFromHook($0) }
                        ?? self.snapshotOrFallback("Claude", iconName: "claude")
                    let other = self.claudeOtherAccountSnapshot(cliOrg: claudeMain?.org)
                    return [card.withAccount(claudeMain)] + [other].compactMap { $0 }
                }
                let cards = await withTimeout(seconds: 8) { await fetchClaudeCards(userInitiated: userInitiated) }
                    ?? [self.snapshotOrFallback("Claude", iconName: "claude")]
                return cards.map { $0.name == "Claude" ? $0.withAccount(claudeMain) : $0 }
            }
            group.addTask {
                if skip.contains("Codex") { return [self.codexLocalOrSnapshot().withAccount(codexMain)] }
                return [(await withTimeout(seconds: 8) { await fetchCodex() }
                    ?? self.snapshotOrFallback("Codex", iconName: "codex")).withAccount(codexMain)]
            }
            // Second logins (`~/.claude-work`, `~/.codex-work`): one card each, only when the dir exists.
            for (extra, account) in claudeExtras {
                group.addTask {
                    if skip.contains(extra.name) {
                        return [self.snapshotOrFallback(extra.name, iconName: "claude").withAccount(account)]
                    }
                    return [(await withTimeout(seconds: 8) {
                        await fetchClaudeExtraAccount(name: extra.name, dir: extra.dir, userInitiated: userInitiated,
                                                     accountID: account?.id)
                    } ?? self.snapshotOrFallback(extra.name, iconName: "claude")).withAccount(account)]
                }
            }
            for (extra, account) in codexExtras {
                group.addTask {
                    if skip.contains(extra.name) { return [self.codexLocalOrSnapshot(name: extra.name, home: extra.dir).withAccount(account)] }
                    return [(await withTimeout(seconds: 8) { await fetchCodex(name: extra.name, home: extra.dir) }
                        ?? self.snapshotOrFallback(extra.name, iconName: "codex")).withAccount(account)]
                }
            }

            var out: [ServiceStatus] = []
            for await items in group {
                out.append(contentsOf: items)
            }
            return out.sorted { order.firstIndex(of: $0.name) ?? 99 < order.firstIndex(of: $1.name) ?? 99 }
        }
    }

    /// Second logins paired with their account, dropping any whose login a card already reads
    /// (`seen` is the main card's) or an earlier dir already holds. A dir whose profile can't be
    /// read is kept — better a card too many than a login silently missing.
    static func distinct(_ extras: [ExtraAccount], seen main: String?,
                         account: (ExtraAccount) -> AccountInfo?) -> [(ExtraAccount, AccountInfo?)] {
        var seen = Set([main].compactMap { $0 })
        return extras.compactMap { extra in
            let info = account(extra)
            if let id = info?.id, !seen.insert(id).inserted { return nil }
            return (extra, info)
        }
    }

    func remainingPercent(fromUsed used: Double) -> Int {
        guard used.isFinite else { return 0 }
        return Int(max(0, min(100, 100 - used)).rounded())
    }

    /// Claude pay-as-you-go billing from the usage API's `extra_usage: { is_enabled, monthly_limit,
    /// used_credits, utilization, currency }`. Returns nil when not enabled (Pro without overage), so
    /// the row is omitted — matching the issue's "fall back silently when billing isn't applicable".



    // MARK: - Generic last-known snapshot (shared by all services)

    /// Where Tiny Usage keeps its caches and snapshots.
    static var userHome: URL {
        if let path = ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var supportDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("Library/Application Support/Tiny Usage")
        }
        if let path = ProcessInfo.processInfo.environment["TINY_USAGE_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return userHome.appendingPathComponent("Library/Application Support/Tiny Usage")
    }

    func snapshotURL(for service: String) -> URL {
        Self.supportDirectory.appendingPathComponent("\(service.lowercased())_snapshot.json")
    }

    /// Persist the last live reading of any service so it can be shown (dimmed, marked stale)
    /// when the live source later fails, instead of the card silently vanishing. Never persists
    /// an unavailable reading. Captures the two account-level windows (Claude/Codex) and/or the
    /// per-model rows; every key is optional, so each service writes only what it has.
    func saveSnapshot(_ status: ServiceStatus) {
        guard status.isAvailable, !status.isStale else { return }
        let hasData = status.sessionRemainingPercent != nil
            || status.weeklyRemainingPercent != nil
            || !status.models.isEmpty
        guard hasData else { return }

        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = ["version": 2, "savedAt": iso.string(from: status.observedAt ?? Date())]
        if let p = status.sessionRemainingPercent { payload["sessionRemainingPercent"] = p }
        if let p = status.weeklyRemainingPercent { payload["weeklyRemainingPercent"] = p }
        if let d = status.sessionResetAt { payload["sessionResetAt"] = iso.string(from: d) }
        if let d = status.weeklyResetAt { payload["weeklyResetAt"] = iso.string(from: d) }
        // Without the window's real length a restored snapshot falls back to "7 days", which both
        // mislabels a longer window (ChatGPT Go's ~30-day one) and rolls a lapsed reset forward by
        // the wrong step.
        if let s = status.weeklyWindowSeconds { payload["weeklyWindowSeconds"] = s }
        // Which login the numbers belong to, so a card shown from its snapshot still names it.
        if let plan = status.account?.plan { payload["plan"] = plan }
        if let email = status.account?.email { payload["email"] = email }
        if let id = status.account?.id { payload["accountID"] = id }
        if let org = status.account?.org { payload["org"] = org }
        if !status.models.isEmpty {
            payload["models"] = status.models.map { m -> [String: Any] in
                var dict: [String: Any] = ["name": m.name, "remainingPercent": m.remainingPercent]
                if let reset = m.resetAt { dict["resetAt"] = iso.string(from: reset) }
                if let valueText = m.valueText { dict["valueText"] = valueText }
                if let w = m.window { dict["window"] = (w == .weekly) ? "weekly" : "session" }
                // Without these a restored card loses its grouping: renewal passes fall out of their
                // chip and a plan's extra quota reads as a single-model limit.
                if let g = m.groupLabel { dict["groupLabel"] = g }
                if let sym = m.symbol { dict["symbol"] = sym }
                if let c = m.caption { dict["caption"] = c }
                if m.isLow { dict["isLow"] = true }
                return dict
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = snapshotURL(for: status.name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Write `data` to `targetURL` without ever exposing it through a world-readable window. The usual
    /// `write(.atomic)` + `setAttributes(0o600)` leaves the file briefly at the umask default (e.g.
    /// 0644) before the chmod — a TOCTOU window where another local process could read a token. Instead,
    /// create a temp file already at `permissions`, then atomically swap it in. Used for the credential/
    /// token writes (Codex auth, Claude credential file), not the non-secret quota snapshots.
    static func secureAtomicWrite(data: Data, to targetURL: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        // Follow symlinks to the real file: if the credential path is a symlink (a common dotfile-
        // manager pattern, e.g. ~/.codex/auth.json → elsewhere), update the linked file and keep the
        // link, rather than replacing the symlink node itself and stranding the real file. The old
        // `write(.atomic)` wrote through the link, so this preserves that behaviour.
        let target = targetURL.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tempURL = dir.appendingPathComponent(UUID().uuidString)
        guard fm.createFile(atPath: tempURL.path, contents: data,
                            attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: target.path) {
                // `.usingNewMetadataOnly` keeps the temp's restrictive permissions instead of
                // inheriting the original file's (which may be looser).
                _ = try fm.replaceItemAt(target, withItemAt: tempURL, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: tempURL, to: target)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }

    /// Load a service's snapshot, classifying each window by reset time: a window whose reset is
    /// still in the future shows its cached percent; one that has already reset is blanked (the
    /// real quota has refilled). Any fresh window/model → a normal (available) card from cache;
    /// all stale → a dimmed `isStale` card marked with `staleNote`, still visible so the service
    /// never vanishes. Returns nil only when the file is missing, corrupt, or past the 30-day cap.
    func loadSnapshot(for service: String, iconName: String,
                              freshNote: String = "snapshot", staleNote: String = L("out of date")) -> ServiceStatus? {
        guard let data = try? Data(contentsOf: snapshotURL(for: service)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let now = Date()
        // Past ~30 days a snapshot is archaeology, not data.
        if let savedRaw = root["savedAt"] as? String, let saved = parseISO8601(savedRaw),
           now.timeIntervalSince(saved) > 30 * 24 * 3_600 {
            return nil
        }

        let allModels: [ModelStatus] = (root["models"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let percent = dict["remainingPercent"] as? Int ?? 0
            let reset = (dict["resetAt"] as? String).flatMap { parseISO8601($0) }
            let window: ModelWindow? = switch dict["window"] as? String {
            case "weekly": .weekly
            case "session": .session
            default: nil
            }
            // Earlier snapshots stored translated grouping labels.
            let storedGroup = dict["groupLabel"] as? String
            let group: String? = switch storedGroup {
            case "Renewal credit", "Reset credit", "重置卡": ModelStatus.renewalCreditGroup
            default: storedGroup
            }
            let storedCaption = dict["caption"] as? String
            let caption: String? = if group == ModelStatus.renewalCreditGroup {
                switch storedCaption {
                case "Weekly quota", "周配额": ModelStatus.weeklyRenewalScope
                case "All models", "全部模型": ModelStatus.allModelsRenewalScope
                default: storedCaption
                }
            } else {
                storedCaption
            }
            return ModelStatus(name: name, remainingPercent: percent, resetAt: reset,
                               valueText: dict["valueText"] as? String, isLow: dict["isLow"] as? Bool ?? false,
                               window: window, caption: caption,
                               symbol: dict["symbol"] as? String, groupLabel: group)
        }
        let sessionReset = (root["sessionResetAt"] as? String).flatMap { parseISO8601($0) }
        let weeklyReset = (root["weeklyResetAt"] as? String).flatMap { parseISO8601($0) }
        // Absent in snapshots written before this key existed — nil then, and the callers fall back
        // to the 7-day default exactly as they did before. Bounds-checked because the on-disk value
        // is untrusted: a corrupt/hand-edited number outside (6h, 366d] would trap in the
        // Double→Int of quotaWindowDays (e.g. 1e300) or hang rollForward's stepping loop (≤0).
        let weeklyWindow = (root["weeklyWindowSeconds"] as? NSNumber)
            .map(\.doubleValue)
            .flatMap { $0.isFinite && $0 > 6 * 3600 && $0 <= 366 * 86_400 ? $0 : nil }
        let plan = root["plan"] as? String, email = root["email"] as? String
        let id = root["accountID"] as? String, org = root["org"] as? String
        let account = plan == nil && email == nil && id == nil && org == nil ? nil : AccountInfo(plan: plan, email: email, id: id, org: org)

        return staleClassifiedCard(
            name: service, iconName: iconName,
            sessionPct: root["sessionRemainingPercent"] as? Int, sessionReset: sessionReset,
            weeklyPct: root["weeklyRemainingPercent"] as? Int, weeklyReset: weeklyReset,
            weeklyWindowSeconds: weeklyWindow,
            models: allModels, freshNote: freshNote, staleNote: staleNote)?
            .withAccount(account).withObservedAt((root["savedAt"] as? String).flatMap(parseISO8601))
    }

    /// Standard reset periods for the quota windows both providers expose: a 5-hour session and a
    /// 7-day week. Used only to roll a *lapsed* last-known reset forward to the next boundary so the
    /// countdown stays meaningful (the window itself really did refill); the live fetch always carries
    /// the exact `resets_at`.
    static let sessionResetPeriod: TimeInterval = 5 * 60 * 60
    static let weeklyResetPeriod: TimeInterval = 7 * 24 * 60 * 60

    /// Classify a last-known reading by reset time. A window/model still within its reset keeps its
    /// real percent; one whose reset has already passed has *refilled to full*, so it shows 100% with
    /// its reset rolled forward to the next boundary — NOT blanked (which made the session vanish and
    /// dropped the provider from the menu bar) and NOT dropped (which made per-model rows like Fable
    /// disappear). When every row is only a refilled estimate (nothing still inside its original
    /// window) the card is dimmed (`isStale`) so it reads as last-known rather than live. Returns nil
    /// only when there is no data at all.
    func staleClassifiedCard(name: String, iconName: String,
                                     sessionPct: Int?, sessionReset: Date?,
                                     weeklyPct: Int?, weeklyReset: Date?,
                                     weeklyWindowSeconds: TimeInterval? = nil,
                                     models: [ModelStatus],
                                     freshNote: String, staleNote: String) -> ServiceStatus? {
        guard sessionPct != nil || weeklyPct != nil || !models.isEmpty else { return nil }
        let now = Date()
        // Roll a lapsed reset forward by the window's REAL length. Assuming 7 days would land a
        // ~30-day window (ChatGPT Go) on a boundary it never has.
        let weeklyPeriod = weeklyWindowSeconds ?? Self.weeklyResetPeriod

        // Advance a passed reset to the next future boundary so a refilled window still shows a live
        // countdown instead of a stale/blank one.
        func rollForward(_ reset: Date?, _ period: TimeInterval) -> Date? {
            guard let reset, period > 0, reset <= now else { return reset }
            let steps = (now.timeIntervalSince(reset) / period).rounded(.down) + 1
            return reset.addingTimeInterval(steps * period)
        }
        // (displayPct, displayReset, stillInWindow) for a window: in-window keeps its real number,
        // lapsed refills to 100% with the reset rolled forward.
        func window(_ pct: Int?, _ reset: Date?, _ period: TimeInterval) -> (pct: Int?, reset: Date?, live: Bool) {
            guard let pct else { return (nil, nil, false) }
            let live = reset.map { now < $0 } ?? true
            return live ? (pct, reset, true) : (nil, reset, false)
        }

        let s = window(sessionPct, sessionReset, Self.sessionResetPeriod)
        let w = window(weeklyPct, weeklyReset, weeklyPeriod)
        // Keep every model row: an in-window one as-is, a lapsed (refilled) one at 100% with its weekly
        // reset rolled forward. Value rows (billing) carry no resetting percent — pass them through.
        let rows = models.compactMap { m -> (row: ModelStatus, live: Bool)? in
            if m.valueText != nil { return (m, true) }
            let live = m.resetAt.map { now < $0 } ?? true
            if live { return (m, true) }
            return nil
        }

        let anyLive = s.live || w.live || rows.contains { $0.live }
        // A refilled window/model is an ESTIMATE (we inferred "reset → 100%", we didn't observe it), so
        // mark the whole card `isStale` whenever anything was refilled — not only when everything is.
        // This keeps the refill out of the notification path: reset alerts fire on `!isStale` cards only
        // (a genuine reset is seen by a LIVE fetch, which never goes through here), so a stale card
        // bouncing to a refilled 100 can't spam a false "weekly quota refilled" notification.
        return ServiceStatus(
            name: name, iconName: iconName,
            sessionResetAt: s.reset, weeklyResetAt: w.reset,
            sessionRemainingPercent: s.pct, weeklyRemainingPercent: w.pct,
            weeklyWindowSeconds: weeklyWindowSeconds,
            models: rows.map(\.row),
            isAvailable: true,
            statusNote: anyLive ? freshNote : staleNote,
            isStale: true)
    }

    /// Last-known snapshot for a service, else its hidden fallback card. Used when a fetch is
    /// skipped (cooldown) or times out, so the card shows stale data instead of disappearing.
    func snapshotOrFallback(_ name: String, iconName: String) -> ServiceStatus {
        loadSnapshot(for: name, iconName: iconName)
            ?? Self.fallbackServices().first { $0.name == name }
            ?? unavailableService(name: name, iconName: iconName, models: [])
    }



    func unavailableService(name: String, iconName: String, models: [String], note: String? = nil) -> ServiceStatus {
        ServiceStatus(
            name: name,
            iconName: iconName,
            sessionResetAt: nil,
            weeklyResetAt: nil,
            models: models.map { ModelStatus(name: $0, remainingPercent: 0, resetAt: nil) },
            isAvailable: false,
            statusNote: note ?? "source unavailable"
        )
    }

    func latestJSONLFile(in directory: URL) -> URL? {
        latestFile(in: directory, pathExtension: "jsonl")
    }

    func latestFile(in directory: URL, pathExtension: String) -> URL? {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        var latest: (URL, Date)?
        while let raw = e.nextObject() {
            guard let url = raw as? URL, url.pathExtension == pathExtension,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { continue }
            if latest == nil || date > latest!.1 {
                latest = (url, date)
            }
        }
        return latest?.0
    }



    /// Claude stores `expiresAt` as epoch milliseconds (distinct from the ISO8601 used elsewhere).
    func epochMillisToDate(_ raw: Any?) -> Date? {
        guard let ms = doubleValue(raw), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static let claudeKeychainService = "Claude Code-credentials"


    func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    func jwtExpiry(_ token: String) -> Date? {
        guard let payload = decodeJWTPayload(token),
              let exp = doubleValue(payload["exp"]) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }


    func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let standard = ISO8601DateFormatter()
        return standard.date(from: raw)
    }

    func extractFlag(_ key: String, from command: String) -> String? {
        // Handles both --key value and --key=value styles
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))(?:[\\s=]+)([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = command as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: command, range: range), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Tiny Usage never refreshes a CLI's token itself — Claude Code's and Codex's refresh tokens are
    /// single-use, and rotating one would log the CLI out. Their own `doctor` does: its auth check
    /// renews an expired login and stores it where the CLI reads it (Codex's `auth.json`, Claude
    /// Code's keychain item), so nothing is left holding the old token. Only when Tiny Usage is opened,
    /// never on the timer. `dir` is a second login's config dir; nil is the main one.
    func runShell(_ script: String, timeout: TimeInterval? = nil) -> String {
        runCommand("/bin/zsh", ["-lc", script], timeout: timeout)
    }

    /// `stdin`, when set, is written to the process's standard input. Used to feed
    /// secrets (e.g. a curl `--config -` block) without exposing them in `arguments`,
    /// which are world-readable via the process table (`ps aux`).
    func runCommand(_ launchPath: String, _ args: [String], stdin: String? = nil,
                    timeout: TimeInterval? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        let input: Pipe? = stdin != nil ? Pipe() : nil
        if let input { p.standardInput = input }
        do {
            try p.run()
            if let input, let stdin {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                input.fileHandleForWriting.closeFile()
            }
            if let timeout {
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                if p.isRunning { p.terminate() }
            }
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

}

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

