import Foundation

extension LiveUsageDataSource {
    /// `home` is the resolved directory for this card. Nil resolves the main login.
    func fetchCodex(name: String = "Codex", home: URL? = nil) async -> ServiceStatus {
        let directory = codexHome(explicit: home)
        let login = readCodexLogin(in: directory)
        guard let login, !login.isExpired else {
            return codexLocalOrSnapshot(name: name, directory: directory, login: login)
        }

        let cached = codexSnapshot(name: name, directory: directory, account: login.account)
        let apiStatus = await fetchCodexUsageAPI(name: name, accessToken: login.accessToken,
                                                accountID: login.account.id, cached: cached)
        let currentLogin = readCodexLogin(in: directory)
        guard !Task.isCancelled else {
            return codexSnapshotOrFallback(name: name, home: directory)
        }
        guard login.matches(currentLogin) else {
            return codexLocalOrSnapshot(name: name, directory: directory, login: currentLogin, accountChanged: true)
        }
        if let apiStatus, apiStatus.isAvailable && !apiStatus.isStale {
            let status = apiStatus.withAccount(currentLogin?.account).withSourceID(codexSourceID(directory))
            saveSnapshot(status)
            return status
        }
        return codexLocalOrSnapshot(name: name, directory: directory, login: currentLogin)
            .withCooldownHint(apiStatus?.cooldownHint)
    }

    func codexLocalOrSnapshot(name: String = "Codex", home: URL? = nil) -> ServiceStatus {
        let directory = codexHome(explicit: home)
        return codexLocalOrSnapshot(name: name, directory: directory, login: readCodexLogin(in: directory))
    }

    private func codexLocalOrSnapshot(name: String, directory: URL, login: CodexLogin?,
                                      accountChanged: Bool = false) -> ServiceStatus {
        let account = login?.account
        let sourceID = codexSourceID(directory)
        let note = login?.isExpired == true ? "token expired — run codex login" : nil
        let previous = loadSnapshot(for: name, iconName: "codex", staleNote: note ?? "out of date")
        let snapshot = previous.flatMap { matchingCodexSnapshot($0, directory: directory, account: account) }

        // JSONL quotas do not identify the login. When the last reading proves a switch in this
        // directory, skip readings that predate the current login file.
        let switched = (previous?.sourceID == sourceID || (previous?.sourceID == nil && directory.path == defaultCodexHome.path))
            && previous?.account?.id != nil && account?.id != nil && previous?.account?.id != account?.id
        let cutoff = switched || accountChanged ? login?.modifiedAt ?? .distantFuture : nil
        var local = codexSessionStatus(name: name, directory: directory, after: cutoff)
            .withAccount(account).withSourceID(sourceID)
        if local.isAvailable, let snapshot, account?.id != nil, !snapshot.models.isEmpty {
            local = local.withModels(snapshot.models).markedStale("local usage; credits from previous snapshot")
                .withObservedAt(snapshot.observedAt)
        }
        if local.isAvailable {
            let status = note.map(local.markedStale) ?? local
            saveSnapshot(status)
            return status
        }
        return (note.flatMap { snapshot?.markedStale($0) } ?? snapshot) ?? local
    }

    /// Used for startup and timeouts, where a local-file scan must not delay the response.
    func codexSnapshotOrFallback(name: String = "Codex", home: URL? = nil) -> ServiceStatus {
        let directory = codexHome(explicit: home)
        let account = readCodexLogin(in: directory)?.account
        return codexSnapshot(name: name, directory: directory, account: account)
            ?? unavailableService(name: name, iconName: "codex", models: [])
                .withAccount(account).withSourceID(codexSourceID(directory))
    }

    func codexAccount(home: URL?) -> AccountInfo? {
        readCodexLogin(in: codexHome(explicit: home))?.account
    }

    func codexHome(explicit: URL? = nil) -> URL {
        let env = ProcessInfo.processInfo.environment
        return codexHome(explicit: explicit, userHome: Self.userHome,
                         configuredHome: env["TINY_USAGE_TEST_HOME"] == nil ? env["CODEX_HOME"] : nil)
    }

    func codexHome(explicit: URL? = nil, userHome: URL, configuredHome: String?) -> URL {
        if let explicit { return canonicalCodexDirectory(explicit) }
        if let path = configuredHome, path.hasPrefix("/") {
            return canonicalCodexDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }
        let main = canonicalCodexDirectory(userHome.appendingPathComponent(".codex", isDirectory: true))
        if readCodexLogin(in: main) != nil { return main }
        let legacy = canonicalCodexDirectory(userHome.appendingPathComponent(".config/codex", isDirectory: true))
        let legacyHasData = readCodexLogin(in: legacy) != nil || !codexSessionFiles(in: legacy).isEmpty
        return legacyHasData && codexSessionFiles(in: main).isEmpty ? legacy : main
    }

    func codexExtraAccounts(mainHome: URL, candidates: [ExtraAccount] = ExtraAccount.codex) -> [ExtraAccount] {
        let main = canonicalCodexDirectory(mainHome)
        var directories = Set([main.path])
        var accounts = Set([readCodexLogin(in: main)?.account.id].compactMap { $0 })
        return candidates.compactMap { extra in
            let directory = canonicalCodexDirectory(extra.dir)
            guard directories.insert(directory.path).inserted else { return nil }
            if let id = readCodexLogin(in: directory)?.account.id, !accounts.insert(id).inserted { return nil }
            return ExtraAccount(name: extra.name, dir: directory)
        }
    }

    private var defaultCodexHome: URL {
        canonicalCodexDirectory(Self.userHome.appendingPathComponent(".codex", isDirectory: true))
    }

    private func canonicalCodexDirectory(_ home: URL) -> URL {
        home.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func codexSourceID(_ home: URL) -> String { "codex:\(home.path)" }

    private func codexSnapshot(name: String, directory: URL, account: AccountInfo?) -> ServiceStatus? {
        loadSnapshot(for: name, iconName: "codex").flatMap {
            matchingCodexSnapshot($0, directory: directory, account: account)
        }
    }

    private func matchingCodexSnapshot(_ snapshot: ServiceStatus, directory: URL,
                                       account: AccountInfo?) -> ServiceStatus? {
        guard snapshot.account?.id == account?.id else { return nil }
        let sourceID = codexSourceID(directory)
        if let savedSourceID = snapshot.sourceID {
            return savedSourceID == sourceID ? snapshot : nil
        }
        guard account?.id != nil || (snapshot.name == "Codex" && directory.path == defaultCodexHome.path) else { return nil }
        return snapshot.withSourceID(sourceID)
    }

    func fetchCodexLocalSessions(name: String, home: URL?) -> ServiceStatus {
        codexSessionStatus(name: name, directory: codexHome(explicit: home), after: nil)
    }

    private func codexSessionFiles(in directory: URL) -> [URL] {
        SessionFileIndex.shared.files(in: directory.appendingPathComponent("sessions", isDirectory: true))
    }

    private func codexSessionStatus(name: String, directory: URL, after cutoff: Date?) -> ServiceStatus {
        for file in codexSessionFiles(in: directory) {
            let status = readCodexSessionFile(file, name: name)
            guard status.isAvailable else { continue }
            if let cutoff, (status.observedAt ?? .distantPast) <= cutoff { continue }
            return status
        }
        return unavailableService(name: name, iconName: "codex", models: [])
    }

    private func readCodexSessionFile(_ file: URL, name: String) -> ServiceStatus {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return unavailableService(name: name, iconName: "codex", models: []) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return unavailableService(name: name, iconName: "codex", models: []) }
        let start = size > 1_048_576 ? size - 1_048_576 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: 1_048_576) else {
            return unavailableService(name: name, iconName: "codex", models: [])
        }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n")
        if start > 0 && !lines.isEmpty { lines.removeFirst() }
        let reversedLines = lines.reversed()
        var observedAt: Date?
        var sessionRemaining: Int?
        var weeklyRemaining: Int?
        var sessionReset: Date?
        var weeklyReset: Date?
        var weeklyWindow: TimeInterval?

        for line in reversedLines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(CodexSessionRecord.self, from: data),
                  record.type == "event_msg",
                  record.payload?.type == "token_count",
                  let rl = record.payload?.rate_limits else { continue }
            observedAt = record.timestamp.flatMap(parseISO8601)

            // Classify each window by its real length, not its slot (see codexStatus): a window of
            // <= 6h is the 5-hour session, anything longer is the weekly one. Since July 2026 the
            // sole window OpenAI returns can be the weekly one (window_minutes 10080), so "primary"
            // no longer implies "5-hour".
            let now = Date()
            for (w, slotIsPrimary) in [(rl.primary, true), (rl.secondary, false)] {
                guard let w, let summary = summarizeCodexWindow(w, now: now) else { continue }
                let periodSeconds = w.window_minutes.map { Double($0) * 60 }
                let isSession = codexWindowIsSession(periodSeconds: periodSeconds,
                                                     resetAt: summary.resetAt,
                                                     slotIsPrimary: slotIsPrimary, now: now)
                if isSession, sessionRemaining == nil {
                    sessionRemaining = remainingPercent(fromUsed: summary.usedPercent)
                    sessionReset = summary.resetAt
                } else if weeklyRemaining == nil {
                    weeklyRemaining = remainingPercent(fromUsed: summary.usedPercent)
                    weeklyReset = summary.resetAt
                    // Keep the real length so the UI can label a 30-day (Go plan) window correctly.
                    weeklyWindow = periodSeconds
                }
            }

            break
        }

        guard sessionRemaining != nil || weeklyRemaining != nil else {
            return unavailableService(name: name, iconName: "codex", models: [])
        }

        let statusNote = sessionReset == nil
            ? "local .codex sessions (reset time not found in file)"
            : "local .codex sessions"

        // A window that isn't present stays nil (no misleading "100%"): when there's no 5-hour window
        // the popover drops the 5s block and promotes the weekly reading instead (see PopoverViews).
        return ServiceStatus(
            name: name,
            iconName: "codex",
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset,
            sessionRemainingPercent: sessionRemaining,
            weeklyRemainingPercent: weeklyRemaining,
            weeklyWindowSeconds: weeklyWindow,
            models: [],
            isAvailable: true,
            statusNote: statusNote,
            isStale: observedAt.map { Date().timeIntervalSince($0) > 1800 } ?? true,
            observedAt: observedAt
        )
    }

    private func fetchCodexUsageAPI(name: String, accessToken: String, accountID: String?,
                                    cached: ServiceStatus?) async -> ServiceStatus? {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TinyUsage/0.1", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, [401, 403, 429].contains(http.statusCode) {
                let delay = http.statusCode == 429 ? (AdaptiveUsageSchedule.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 900) : 1800
                return unavailableService(name: name, iconName: "codex", models: []).withCooldownHint(delay)
            }
            guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["rate_limit"] is [String: Any] || codexIndividualLimit(root) != nil else {
                return nil
            }
            Self.recordCodexShape(root)
            let fetched = await fetchCodexResetCredits(accessToken: accessToken, accountID: accountID)
            let previous = accountID != nil
                ? cached?.models.filter { $0.groupLabel == ModelStatus.renewalCreditGroup && ($0.resetAt.map { $0 > Date() } ?? false) } ?? [] : []
            let status = codexStatus(fromUsageRoot: root, extraRows: fetched ?? previous, name: name).withObservedAt(Date())
            return fetched == nil && !previous.isEmpty ? status.withStatusNote("Quota API · reset credits from last capture") : status
        } catch {
            return nil
        }
    }

    // ponytail: temporary probe for #77 (Luna Reserve) — local builds only. Records the *shape* of
    // `wham/usage` (key paths, and the short enum-like strings under name/type/banner/model/plan
    // keys) each time it changes, so the reserve quota's fields can be read off a real response the
    // day the main quota runs out. No token, no ids, no numbers. Delete once #77 is decided.
    nonisolated(unsafe) private static var lastCodexShape = ""

    private static func recordCodexShape(_ root: [String: Any]) {
        guard ProcessInfo.processInfo.environment["TINY_USAGE_DEBUG_CODEX_SHAPE"] == "1" else { return }
        var lines: [String] = []
        func walk(_ value: Any, _ path: String) {
            switch value {
            case let dict as [String: Any]:
                for key in dict.keys.sorted() { walk(dict[key]!, path.isEmpty ? key : "\(path).\(key)") }
            case let array as [Any]:
                if array.isEmpty { lines.append("\(path)[] empty") }
                for item in array { walk(item, "\(path)[]") }
            case let text as String:
                let key = path.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
                let enumLike = ["name", "type", "banner", "model", "plan", "reason", "status"]
                    .contains { key.contains($0) } && text.count <= 40
                lines.append("\(path) = \(enumLike ? "\"\(text)\"" : "<string>")")
            case is NSNull:
                lines.append("\(path) = null")
            default:
                lines.append("\(path) = <\(type(of: value))>")
            }
        }
        walk(root, "")
        let shape = Array(Set(lines)).sorted().joined(separator: "\n")
        guard shape != lastCodexShape else { return }
        lastCodexShape = shape
        let url = LiveUsageDataSource.supportDirectory.appendingPathComponent("codex-shape.log")
        let entry = "=== \(ISO8601DateFormatter().string(from: Date()))\n\(shape)\n\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Build the Codex `ServiceStatus` from a parsed `wham/usage` response root. Pure (no I/O) so it's
    /// unit-testable. Classifies each present window by its real PERIOD, not its slot: OpenAI
    /// temporarily removed Codex's 5-hour limit in July 2026, so the sole window it now returns can be
    /// the WEEKLY one sitting in the `primary_window` slot (limit_window_seconds 604800) — "primary" no
    /// longer implies "5-hour". A window of <= 6h is the 5-hour session, anything longer is the weekly
    /// one; see `codexWindowIsSession` for what happens when the period field is missing. An absent
    /// window stays nil (no misleading "100%"). If the 5h window returns later, it's the session again.
    func codexStatus(fromUsageRoot root: [String: Any], now: Date = Date(), extraRows: [ModelStatus] = [],
                     name: String = "Codex") -> ServiceStatus {
        var (session, weekly, weeklyWindow) = codexWindows(root["rate_limit"] as? [String: Any] ?? [:], now: now)
        // A workspace member capped only by a monthly credit limit gets no rate-limit windows at all.
        if session == nil, weekly == nil, let cap = codexIndividualLimit(root) {
            weekly = cap
            weeklyWindow = 30 * 86_400
        }

        return ServiceStatus(
            name: name,
            iconName: "codex",
            sessionResetAt: session?.resetAt,
            weeklyResetAt: weekly?.resetAt,
            sessionRemainingPercent: session.flatMap(\.percent),
            weeklyRemainingPercent: weekly.flatMap(\.percent),
            weeklyWindowSeconds: weeklyWindow,
            models: (codexCreditRow(root["credits"]).map { [$0] } ?? []) + extraRows
                + codexAdditionalLimitRows(root["additional_rate_limits"], now: now),
            isAvailable: true,
            statusNote: "chatgpt usage api"
        )
    }

    /// Marks the rows that are a separate quota of their own, drawn as their own panel on the card.
    static let codexExtraLimitGroup = "codex.additional-limit"

    /// `additional_rate_limits`: quotas that sit beside the plan's own — Luna Reserve, the fallback
    /// model Codex moves you to once the main quota is spent, or a model-specific limit. Each entry
    /// is `{ limit_name, metered_feature, rate_limit: { primary_window, secondary_window } }`, the
    /// same window shape as the main `rate_limit` (from OpenAI's own Codex client types). Shown only
    /// while the API reports one; `null` on an account that has none.
    func codexAdditionalLimitRows(_ raw: Any?, now: Date = Date()) -> [ModelStatus] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [ModelStatus] in
            guard let raw = [entry["limit_name"], entry["metered_feature"]]
                    .compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespaces) })
                    .first(where: { !$0.isEmpty }),
                  let rateLimit = entry["rate_limit"] as? [String: Any] else { return [] }
            // Codex's own client names the reserve `gpt-reserve` on the wire and "Luna Reserve" on screen.
            let name = raw.caseInsensitiveCompare("gpt-reserve") == .orderedSame ? "Luna Reserve" : raw
            let (session, weekly, _) = codexWindows(rateLimit, now: now)
            return [(session, ModelWindow.session), (weekly, .weekly)].compactMap { pair, window in
                guard let pair, let percent = pair.percent else { return nil }
                return ModelStatus(name: name, remainingPercent: percent, resetAt: pair.resetAt,
                                   window: window, groupLabel: Self.codexExtraLimitGroup)
            }
        }
    }

    /// The session and long window out of one `rate_limit` object, by length rather than by slot.
    private func codexWindows(_ rateLimit: [String: Any], now: Date)
        -> (session: (percent: Int?, resetAt: Date?)?, weekly: (percent: Int?, resetAt: Date?)?, weeklyWindow: TimeInterval?) {
        var session: (percent: Int?, resetAt: Date?)?
        var weekly: (percent: Int?, resetAt: Date?)?
        var weeklyWindow: TimeInterval?
        for (raw, slotIsPrimary) in [(rateLimit["primary_window"], true), (rateLimit["secondary_window"], false)] {
            guard let obj = raw as? [String: Any] else { continue }
            let window = codexAPIWindow(obj)
            // A window returned without `used_percent` has an UNKNOWN percent, not a full one. Reading it
            // as 100 made a partial response look like a fresh reset, which fired "quota refilled" in the
            // middle of a 30-day (Go) window. nil keeps the countdown and drops only the number.
            let percent = window.usedPercent.map(remainingPercent(fromUsed:))
            let periodSeconds = doubleValue(obj["limit_window_seconds"])
            let isSession = codexWindowIsSession(periodSeconds: periodSeconds,
                                                 resetAt: window.resetAt,
                                                 slotIsPrimary: slotIsPrimary, now: now)
            // A second window that also reads as the session lands in the weekly slot rather than
            // being dropped — better a slightly mislabelled reading than a missing one.
            if isSession, session == nil {
                session = (percent, window.resetAt)
            } else if weekly == nil {
                weekly = (percent, window.resetAt)
                // Keep the real length so the UI can label a 30-day (Go plan) window correctly.
                weeklyWindow = periodSeconds
            }
        }
        return (session, weekly, weeklyWindow)
    }

    /// The monthly credit cap a workspace sets per member: `individual_limit: { limit, used,
    /// remaining_percent, reset_at }`, at the root, under `rate_limit` or under `spend_control`
    /// depending on the account. An account without a cap sends `"individual_limit": null`.
    func codexIndividualLimit(_ root: [String: Any]) -> (percent: Int?, resetAt: Date?)? {
        let rateLimit = root["rate_limit"] as? [String: Any]
        let spendControl = root["spend_control"] as? [String: Any]
        guard let cap = [root["individual_limit"], rateLimit?["individual_limit"], spendControl?["individual_limit"]]
            .lazy.compactMap({ $0 as? [String: Any] }).first else { return nil }
        let limit = doubleValue(cap["limit"])
        let used = doubleValue(cap["remaining_percent"]).map { 100 - $0 }
            ?? limit.flatMap { limit in limit > 0 ? doubleValue(cap["used"]).map { $0 / limit * 100 } : nil }
        let resetEpoch = doubleValue(cap["reset_at"]) ?? doubleValue(cap["resets_at"])
        guard used != nil || resetEpoch != nil else { return nil }
        return (used.map(remainingPercent(fromUsed:)),
                resetEpoch.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
    }

    /// Codex premium credit balance from `wham/usage` `credits: { has_credits, unlimited, balance }`.
    /// Returns nil for free/Plus accounts with no credits, so the row is simply omitted.
    private func codexCreditRow(_ raw: Any?) -> ModelStatus? {
        guard let c = raw as? [String: Any] else { return nil }
        let label = L("Credit balance")
        if c["unlimited"] as? Bool == true {
            return ModelStatus(name: label, remainingPercent: 0, resetAt: nil,
                               valueText: L("Unlimited"), symbol: "dollarsign.circle")
        }
        guard c["has_credits"] as? Bool == true else { return nil }
        let amount = (c["balance"] as? String).flatMap(Double.init) ?? doubleValue(c["balance"]) ?? 0
        guard amount > 0 else { return nil }
        let text = amount.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(amount)) : String(amount)
        return ModelStatus(name: label, remainingPercent: 0, resetAt: nil,
                           valueText: String(format: L("%@ credits"), text), isLow: amount < 5,
                           symbol: "dollarsign.circle")
    }

    /// Reset credits ("yenileme hakkı") from `wham/rate-limit-reset-credits`: one-shot passes that
    /// clear a spent rate-limit window. One row per credit, soonest expiry first — a count alone hid
    /// the fact that credits expire on their own dates, and the "first expires in …" caption read
    /// oddly when there was only one. Only credits still available AND not yet expired count: a credit
    /// can lapse between polls, and `available_count` doesn't re-check that. Empty → no rows at all.
    func codexResetCreditRows(fromRoot root: [String: Any], now: Date = Date()) -> [ModelStatus] {
        let expiries = (root["credits"] as? [[String: Any]] ?? []).compactMap { item -> Date? in
            guard (item["status"] as? String)?.lowercased() == "available",
                  let raw = item["expires_at"] as? String,
                  let expiresAt = parseISO8601(raw), expiresAt > now else { return nil }
            return expiresAt
        }.sorted()

        // One line per credit, labelled by the date it lapses; the popover groups them under a single
        // "Renewal credits" heading, so neither the icon nor the label repeats. `resetAt` carries the
        // expiry: the line draws a live countdown off it, and the expiry warning reads it from here
        // rather than from the formatted text.
        // One line per credit: the chip above them carries the count, these carry the dates.
        return expiries.map { expiresAt in
            ModelStatus(name: Self.shortDateFormatter.string(from: expiresAt),
                        remainingPercent: 0, resetAt: expiresAt,
                        valueText: TimeFormatter.compact(from: expiresAt.timeIntervalSince(now)),
                        symbol: "plus.circle", groupLabel: ModelStatus.renewalCreditGroup)
        }
    }

    /// A credit's expiry is a calendar date, not a countdown, so it reads as one: "13.10.26", with
    /// the century left off since a line that says what the date is for never raises the question.
    /// Not the locale's short style — that dropped the leading zero ("8.09.26"), so a column of
    /// dates didn't line up. `yy` (calendar year), never `YY` (week-year, off by one in late
    /// December). POSIX locale so a non-Gregorian regional calendar can't reformat it.
    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "dd.MM.yy"
        return f
    }()

    /// GET the reset-credit endpoint with the same auth as `wham/usage`. Failure returns nil and the
    /// row is dropped — this is a bonus reading, never a reason to fail the whole Codex fetch.
    private func fetchCodexResetCredits(accessToken: String, accountID: String?) async -> [ModelStatus]? {
        let endpointKey = "codex-reset:\(accountID ?? "default")"
        guard await EndpointBackoff.shared.remaining(endpointKey) <= 0 else { return nil }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
                             timeoutInterval: 10)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TinyUsage/0.1", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        await EndpointBackoff.shared.record(response, key: endpointKey)
        guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return codexResetCreditRows(fromRoot: root)
    }
    private func summarizeCodexWindow(_ window: CodexRateWindow?, now: Date) -> CodexWindowSummary? {
        guard let window else { return nil }
        guard let used = window.used_percent else { return nil }
        guard let resetEpoch = window.resets_at else {
            return CodexWindowSummary(usedPercent: used, resetAt: nil)
        }

        let reset = Date(timeIntervalSince1970: TimeInterval(resetEpoch))
        guard reset > now else { return nil }
        return CodexWindowSummary(usedPercent: used, resetAt: reset)
    }

    func codexAPIWindow(_ raw: Any?) -> (usedPercent: Double?, resetAt: Date?) {
        guard let obj = raw as? [String: Any] else {
            return (nil, nil)
        }

        let used = doubleValue(obj["used_percent"])
        // The reset epoch has appeared under both spellings across Codex surfaces (`reset_at` in the
        // usage API, `resets_at` in the session files), so accept either rather than silently losing
        // the countdown if this response switches.
        let resetEpoch = doubleValue(obj["reset_at"]) ?? doubleValue(obj["resets_at"])
        return (used, resetEpoch.map { Date(timeIntervalSince1970: $0) })
    }

    /// Is this rate-limit window the 5-hour session (vs the weekly one)? Decided by the window's real
    /// PERIOD — "primary" no longer implies "5-hour" (see `codexStatus`). The period field is the only
    /// reliable signal, so when it's absent fall back to how far the reset is: a 5-hour window can
    /// never reset more than 5h out. That fallback misreads a weekly window in its final hours, which
    /// is still better than trusting the slot; the slot is the last resort.
    func codexWindowIsSession(periodSeconds: Double?, resetAt: Date?, slotIsPrimary: Bool, now: Date) -> Bool {
        if let periodSeconds { return periodSeconds <= 6 * 3600 }
        if let resetAt, resetAt > now { return resetAt.timeIntervalSince(now) <= 8 * 3600 }
        return slotIsPrimary
    }

    /// Read the identity and access token from one copy of the CLI's auth file. The CLI owns renewal.
    private func readCodexLogin(in directory: URL) -> CodexLogin? {
        let file = directory.appendingPathComponent("auth.json").resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: file),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = codexAccessToken(in: auth) else { return nil }

        let idToken = (auth["tokens"] as? [String: Any])?["id_token"] as? String ?? auth["id_token"] as? String
        let claims = idToken.flatMap(decodeJWTPayload)
        let openai = claims?["https://api.openai.com/auth"] as? [String: Any]
        let account = AccountInfo(plan: AccountInfo.codexPlan(openai?["chatgpt_plan_type"] as? String),
                                  email: claims?["email"] as? String, id: codexAccountID(from: auth))
        return CodexLogin(account: account, accessToken: accessToken, expiresAt: jwtExpiry(accessToken),
                          modifiedAt: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }

    private func codexAccessToken(in auth: [String: Any]) -> String? {
        if let token = auth["access_token"] as? String, !token.isEmpty { return token }
        if let tokens = auth["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }


    private func codexAccountID(from auth: [String: Any]) -> String? {
        if let accountID = auth["account_id"] as? String, !accountID.isEmpty { return accountID }
        if let tokens = auth["tokens"] as? [String: Any] {
            if let accountID = tokens["account_id"] as? String, !accountID.isEmpty { return accountID }
            if let idToken = tokens["id_token"] as? String,
               let accountID = codexAccountID(fromJWT: idToken) {
                return accountID
            }
        }
        if let idToken = auth["id_token"] as? String,
           let accountID = codexAccountID(fromJWT: idToken) {
            return accountID
        }
        return nil
    }

    private func codexAccountID(fromJWT token: String) -> String? {
        guard let payload = decodeJWTPayload(token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

}


private struct CodexSessionRecord: Decodable {
    let timestamp: String?
    let type: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    let type: String?
    let rate_limits: CodexRateLimits?
}

private struct CodexRateLimits: Decodable {
    let limit_id: String?
    let primary: CodexRateWindow?
    let secondary: CodexRateWindow?
}

private struct CodexRateWindow: Decodable {
    let used_percent: Double?
    let window_minutes: Int?
    let resets_at: Int?
}

private struct CodexLogin {
    let account: AccountInfo
    let accessToken: String
    let expiresAt: Date?
    let modifiedAt: Date?

    var isExpired: Bool { expiresAt.map { $0.timeIntervalSinceNow <= 30 } ?? false }

    func matches(_ current: CodexLogin?) -> Bool {
        guard let current else { return false }
        if let id = account.id { return id == current.account.id }
        return current.account.id == nil && current.accessToken == accessToken
    }
}

private struct CodexWindowSummary {
    let usedPercent: Double
    let resetAt: Date?
}

