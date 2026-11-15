import CryptoKit
import Foundation
import Security
import LocalAuthentication

extension LiveUsageDataSource {
    /// Claude's cards. Claude Code's login comes first: it is the account the user works in, and its
    /// profile names the e-mail and plan. Claude.app's session serves that same card when the app is
    /// signed in to the same organization — it is the one source of the reset passes, and it never
    /// prompts — and becomes its own "Claude Desktop" card when the app is on another account.
    /// Without a CLI login the app's session is the Claude card, as before.
    ///
    /// One chain, one switch. Every source is tried silently on every refresh — a silent keychain read
    /// succeeds only for a source the user has already granted, so nothing here needs a mode to stay
    /// off the network or quiet. `userInitiated` (the explicit Authorize action, nothing else) only
    /// lets the granting reads show the macOS dialog: Claude Safe Storage first, whose grant sticks,
    /// and Claude Code's own item only when the app's session doesn't already cover this account.
    func fetchClaudeCards(userInitiated: Bool) async -> [ServiceStatus] {
        let cli = Self.claudeAccount(configFile: ClaudeStatusLineHook.claudeConfigFile)
        if let org = cli?.org { noteClaudeAccount(org) }

        let desktop = await fetchClaudeDesktopWebUsage(userInitiated: userInitiated, cliOrg: cli?.org)
        var main: ServiceStatus
        var separate: ServiceStatus?
        if let desktop, desktop.sameAccount {
            // The app is on the CLI's account: one card, and it carries the reset passes.
            try? FileManager.default.removeItem(at: snapshotURL(for: Self.claudeDesktopCardName))
            main = desktop.status
        } else {
            main = await fetchClaude(userInitiated: userInitiated, cliOrg: cli?.org)
            separate = desktop?.status
            if separate == nil, cli == nil, !main.isAvailable { separate = await fetchClaudeDesktopOAuthUsage() }
            if separate == nil { separate = claudeOtherAccountSnapshot(cliOrg: cli?.org) }
        }
        if cli?.org != nil, !main.models.contains(where: { $0.groupLabel == ModelStatus.renewalCreditGroup }),
           let cached = readClaudeUsageCache(maxAge: 24 * 3600) {
            let grants = claudeResetGrantRows(cached)
            if !grants.isEmpty {
                main = main.withModels(main.models + grants).withStatusNote(L("Quota updated · reset credits from last capture"))
            }
        }
        return [main.withAccount(cli)] + [separate].compactMap { $0 }
    }

    /// Claude.app's last separate card, kept only while it names an organization other than the
    /// CLI's — a snapshot of the CLI's own login (or one saved without an organization) would be the
    /// same account twice, so it goes. Without a CLI login there is no second account to show.
    func claudeOtherAccountSnapshot(cliOrg: String?) -> ServiceStatus? {
        let snapshot = loadSnapshot(for: Self.claudeDesktopCardName, iconName: "claude")
        if let card = Self.otherAccountCard(snapshot, cliOrg: cliOrg) { return card }
        if snapshot != nil { try? FileManager.default.removeItem(at: snapshotURL(for: Self.claudeDesktopCardName)) }
        return nil
    }

    /// Pure → unit-testable: the card stays only when both organizations are known and differ.
    static func otherAccountCard(_ card: ServiceStatus?, cliOrg: String?) -> ServiceStatus? {
        guard let cliOrg, let org = card?.account?.org, org != cliOrg else { return nil }
        return card
    }

    /// The login a Claude Code config holds, from its `.claude.json` profile — no keychain, no
    /// network. nil when the config has no signed-in account.
    static func claudeAccount(configFile: URL) -> AccountInfo? {
        guard let data = try? Data(contentsOf: configFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any] else { return nil }
        return claudeAccount(oauthAccount: oauth)
    }

    static func claudeAccount(oauthAccount o: [String: Any]) -> AccountInfo? {
        let user = o["accountUuid"] as? String, org = o["organizationUuid"] as? String
        guard user != nil || org != nil else { return nil }
        // Claude Code writes the plan's own name ("Ultra") when it knows it; that beats deriving one.
        return AccountInfo(plan: (o["planDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                               ?? AccountInfo.claudePlan(o["organizationType"] as? String,
                                                         rateLimitTier: o["organizationRateLimitTier"] as? String)
                               ?? org.flatMap { UserDefaults.standard.string(forKey: claudePlanKey($0)) },
                           email: o["emailAddress"] as? String,
                           id: "\(user ?? "-")|\(org ?? "-")", org: org)
    }

    /// Claude Code's own login: the usage cache, the statusLine hook, then its OAuth token.
    /// `userInitiated` gates whether this fetch may read Claude Code's *own* keychain item — the
    /// only source that pops the macOS permission prompt, because Claude Code resets the item's ACL
    /// (wiping our "Always Allow") every time it rotates its token. A background tick passes `false`
    /// and stays on prompt-free sources (usage cache, the on-disk credential file, Tiny Usage's own token
    /// cache); only the explicit Authorize action passes `true` and may read that item.
    /// Any failure lands in `claudeFailure`: the fresh hook, then the cache and snapshot.
    func fetchClaude(userInitiated: Bool, cliOrg: String?) async -> ServiceStatus {

        // When Claude Code's prompt-free statusLine hook is fresh it already carries the live
        // session/weekly numbers, so a routine open must NOT reach for the prompting keychain read.
        // Claude Code wipes its item's ACL on every token refresh, so our "Always Allow" doesn't
        // survive — a prompting read would then re-pop the dialog every few hours (once per refresh).
        // Gate the prompt behind "no fresh hook": while the hook covers us we do silent reads only, so
        // the keychain (and its dialog) is touched solely when the hook can't (Claude Code idle).

        // Reuse the in-memory token while it's comfortably valid, so the keychain — and its macOS
        // permission prompt — is touched only at launch and around token expiry, not every refresh.
        var tokenInfo = await Self.claudeTokenCache.get()
        let needsKeychain = tokenInfo.map { $0.expiresAt.map { $0.timeIntervalSinceNow <= 300 } ?? false } ?? true

        if needsKeychain {
            guard let read = readClaudeTokenInfo(userInitiated: userInitiated) else {
                // No prompt-free source had a usable token. The Authorize action in Settings
                // allows an interactive read of Claude Code's keychain item.
                let note = userInitiated
                    ? L("claude token missing")
                    : L("authorize in Settings to read the Claude credential")
                return claudeFailure(note: note)
            }
            tokenInfo = read

            // Tiny Usage does NOT refresh Claude Code's OAuth token. Anthropic rotates the refresh token
            // single-use, so refreshing here consumes the token Claude Code still holds and logs it
            // out. We only READ whatever token Claude Code currently has and use it while valid;
            // once it's actually expired, Claude Code refreshes it on its own next use — Tiny Usage just
            // asks the user to open it. ponytail: not our token to rotate — read-only is the safe
            // posture (the 30s buffer keeps a token from dying mid-request).
            if let exp = read.expiresAt, exp.timeIntervalSinceNow <= 30 {
                // Token is dead — but DON'T arm a fetch cooldown. The cooldown makes the store skip
                // fetchClaude entirely (LiveUsageDataSource: `skip.contains("Claude")` → snapshotOrFallback),
                // and with it the prompt-free hook read — which froze the card on a stale snapshot even
                // after Claude Code wrote fresh hook numbers. We make NO network call with a dead token,
                // so there's nothing to rate-limit; fall straight to claudeFailure, which reads the fresh
                // hook every tick and shows live session/weekly numbers without a prompt.
                let note = L("token expired — open Claude Code")
                return claudeFailure(note: note, staleNote: note, expired: true)
            }
            await Self.claudeTokenCache.set(tokenInfo)
            // Mirror the access token into Tiny Usage's own keychain item so the next background tick can
            // reuse it without prompting (see cacheClaudeToken — access token only, no refresh).
            if let tokenInfo { cacheClaudeToken(tokenInfo) }
        }

        guard let token = tokenInfo else {
            return claudeFailure(note: L("claude token missing"))
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return claudeFailure(note: "claude no http response")
            }
            guard 200 ... 299 ~= http.statusCode else {
                // A rejected token is likely stale (rotated out by Claude Code); drop both caches so
                // the next refresh re-reads a fresh token instead of replaying the dead one. Dropping
                // Tiny Usage's own cache is load-bearing in the background: the keychain that holds a fresh
                // token is gated to user actions, so a kept-but-dead cache would 401 on every tick.
                if http.statusCode == 401 || http.statusCode == 403 {
                    await Self.claudeTokenCache.set(nil)
                    deleteCachedClaudeToken()
                }
                // Back off on rate limiting so we stop pounding a 429ing endpoint.
                let cooldown: TimeInterval? = http.statusCode == 429 ? (retryAfterSeconds(http) ?? 15 * 60) : ((http.statusCode == 401 || http.statusCode == 403) ? 1800 : nil)
                return claudeFailure(note: "claude http \(http.statusCode)").withCooldownHint(cooldown)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.claudeHasQuota(root) else {
                return claudeFailure(note: "claude response parse fail")
            }
            writeClaudeUsageCache(data)
            if Self.claudeAccount(configFile: ClaudeStatusLineHook.claudeConfigFile)?.plan == nil {
                await rememberClaudePlan(token.accessToken)
            }
            let status = buildClaudeStatus(from: root, note: "oauth usage api")
                .withAccount(Self.claudeAccount(configFile: ClaudeStatusLineHook.claudeConfigFile))
                .withObservedAt(Date())
            saveSnapshot(status)
            return status.withCooldownHint(0)   // live success → clear any cooldown
        } catch {
            return claudeFailure(note: "claude request failed")
        }
    }

    /// Claude's live fetch failed — show last-known data instead of vanishing: the still-valid
    /// 24h usage cache, else the persisted snapshot (dimmed when its windows have reset), else
    /// the hidden unavailable card (only when nothing was ever cached).
    private func claudeFailure(note: String, staleNote: String = L("out of date"),
                               expired: Bool = false) -> ServiceStatus {
        // The recent statusLine hook supplies live session and weekly numbers without a token.
        // Prefer it to the 24h cache and snapshot when a live fetch fails.
        if let hook = readClaudeHookUsage(maxAge: 30 * 60) {
            return claudeCardFromHook(hook)
        }
        let card = claudeLastKnown(note: note, staleNote: staleNote)
        // An expired login can't refresh these numbers until it is renewed: grey, so opening Tiny Usage
        // renews it, however much of the windows is still left.
        return expired && card.isAvailable ? card.markedStale(staleNote) : card
    }

    private func claudeLastKnown(note: String, staleNote: String) -> ServiceStatus {
        // Recent cache → normal card (seed a snapshot so the cooldown/skip path can serve it too).
        // This is a failure fallback, so reset-classify it (`live: false`): a window that refilled
        // since this cache was written shouldn't show a phantom percent.
        if let cached = readClaudeUsageCache(maxAge: 24 * 60 * 60) {
            let status = buildClaudeStatus(from: cached, note: note, live: false)
            return status
        }
        // Persisted snapshot, else an older cache trusted by reset time (windows still within their
        // reset show dimmed; refilled windows are blanked) — seeded as a snapshot for next time.
        if let snap = loadSnapshot(for: "Claude", iconName: "claude", staleNote: staleNote) {
            return snap
        }
        if let stale = claudeCardFromStaleCache(staleNote: staleNote) {
            return stale
        }
        return unavailableService(name: "Claude", iconName: "claude", models: [], note: note)
    }

    /// Build a Claude card from the cache at any age, trusting each window by its reset time, so a
    /// still-valid weekly number survives even when the 24h cache window and the token have lapsed.
    private func claudeCardFromStaleCache(staleNote: String) -> ServiceStatus? {
        guard let root = readClaudeUsageCacheRaw() else { return nil }
        let full = buildClaudeStatus(from: root, note: "snapshot")
        return staleClassifiedCard(
            name: "Claude", iconName: "claude",
            sessionPct: full.sessionRemainingPercent, sessionReset: full.sessionResetAt,
            weeklyPct: full.weeklyRemainingPercent, weeklyReset: full.weeklyResetAt,
            models: full.models, freshNote: "snapshot", staleNote: staleNote)
    }

    /// Parse an HTTP `Retry-After` header (delta-seconds or HTTP-date) into a backoff interval.
    private func retryAfterSeconds(_ http: HTTPURLResponse) -> TimeInterval? {
        AdaptiveUsageSchedule.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
    }

    /// Build a Claude card from the usage JSON. `live` (the API success path and the <5 min cache)
    /// trusts the percents as-is; the stale fallbacks (24h cache / snapshot) pass `live: false` to
    /// reset-classify — there a window whose reset has passed is blanked because it really refilled.
    func buildClaudeStatus(from root: [String: Any], note: String, live: Bool = true,
                           name: String = "Claude") -> ServiceStatus {
        let fiveHour = mergeClaudeWindows(root: root, baseKey: "five_hour")
        let sevenDay = mergeClaudeWindows(root: root, baseKey: "seven_day")

        // Per-model weekly rows (e.g. "Fable") now come from the `limits` array, keyed by
        // `scope.model.display_name` — not the old flat `seven_day_<model>` keys, which the API
        // has stopped populating (they read back as null). Reading the array generically means a
        // new model tier shows up with no code change, instead of needing another hardcoded key
        // every time Anthropic ships one.
        var models: [ModelStatus] = claudeScopedModelRows(root["limits"], weeklyResetAt: sevenDay.resetAt)
        models.append(contentsOf: claudeResetGrantRows(root))
        models.append(contentsOf: claudeDollarCreditRows(root))
        if let billing = claudeBillingRow(root) {
            models.append(billing)
        }

        // A window the plan doesn't have stays nil — no capsule, no number. Read as "nothing used"
        // it showed a full weekly bar for a Team seat that has no weekly limit at all.
        let sessionPct = fiveHour.utilization.map { remainingPercent(fromUsed: $0) }
        let weeklyPct = sevenDay.utilization.map { remainingPercent(fromUsed: $0) }

        // Live data is authoritative: trust the percents even if a window's reset has *just* lapsed.
        // Right after a 5-hour boundary the API briefly returns the old window's `resets_at` (already
        // past) before rolling to the next; reset-classifying that — as we do for genuinely stale
        // cache — would blank the whole session, so Claude's card vanishes for a few minutes.
        if live {
            return ServiceStatus(
                name: name, iconName: "claude",
                sessionResetAt: fiveHour.resetAt, weeklyResetAt: sevenDay.resetAt,
                sessionRemainingPercent: sessionPct, weeklyRemainingPercent: weeklyPct,
                models: models, isAvailable: true, statusNote: note)
        }

        // Stale fallback: a window whose reset has already passed is blanked (it refilled) rather than
        // shown as if current.
        return staleClassifiedCard(
            name: name, iconName: "claude",
            sessionPct: sessionPct, sessionReset: fiveHour.resetAt,
            weeklyPct: weeklyPct, weeklyReset: sevenDay.resetAt,
            models: models, freshNote: note, staleNote: note)
            ?? unavailableService(name: name, iconName: "claude", models: [], note: note)
    }
    /// One row per weekly-scoped model in the `limits` array (e.g. `{"kind": "weekly_scoped",
    /// "group": "weekly", "percent": 66, "scope": {"model": {"display_name": "Fable"}}}`). The
    /// array is already presentation-ordered by the API, so rows are emitted in that order. When a
    /// scoped entry omits its own `resets_at`, fall back to the account-wide weekly reset since they
    /// reset together (mirrors the old Sonnet-specific fallback).
    private func claudeScopedModelRows(_ raw: Any?, weeklyResetAt: Date?) -> [ModelStatus] {
        guard let limits = raw as? [[String: Any]] else { return [] }
        return limits.compactMap { entry -> ModelStatus? in
            guard entry["group"] as? String == "weekly",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let displayName = model["display_name"] as? String else { return nil }
            guard let percent = doubleValue(entry["percent"]), percent.isFinite else { return nil }
            let resetAt = (entry["resets_at"] as? String).flatMap(parseISO8601) ?? weeklyResetAt
            return ModelStatus(name: displayName, remainingPercent: remainingPercent(fromUsed: percent), resetAt: resetAt)
        }
    }

    /// Usage-limit reset grants — the "Resets" card on claude.ai: a one-shot pass that clears the
    /// spent five-hour and weekly windows, with its own expiry. This is Codex's renewal credit in
    /// all but name, so it carries the same heading and the same icon: one thing, named once,
    /// wherever it comes from.
    ///
    /// Only the desktop path carries this (`ClaudeDesktopSession` asks for `?cedar_ember=1`); the
    /// CLI's endpoint gates the same field behind Claude Code's own User-Agent, so on that path the
    /// key is simply absent and no row appears.
    ///
    /// A grant is listed only while it can actually be used: unspent, unexpired and not paused.
    /// `usable_now` is the API's own verdict and wins when present — a grant can be withheld for
    /// reasons we don't model (a cooldown, a limit that must be hit first) and guessing past that
    /// would promise the user something the button won't honour.
    func claudeResetGrantRows(_ root: [String: Any], now: Date = Date()) -> [ModelStatus] {
        guard let cedar = root["cedar_ember"] as? [String: Any],
              let grants = cedar["grants"] as? [[String: Any]] else { return [] }
        // Models with their own weekly row ("Fable"): a grant whose label names one gives back that
        // model's usage only.
        let scopedModels = (root["limits"] as? [[String: Any]] ?? []).compactMap {
            (($0["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        }

        return grants.compactMap { grant -> (date: Date, rows: [ModelStatus])? in
            guard let rawLeft = doubleValue(grant["resets_left"]), rawLeft.isFinite, rawLeft >= 1,
                  grant["paused"] as? Bool != true else { return nil }
            let left = Int(min(100, rawLeft))
            guard let endsAt = (grant["ends_at"] as? String).flatMap(parseISO8601), endsAt > now else { return nil }
            if let usable = grant["usable_now"] as? Bool, !usable { return nil }

            // One line per usable reset, shaped exactly like Codex's renewal credits: the date it
            // lapses on the left, a live countdown to that date on the right. A grant holding two
            // passes draws two lines for the same reason Codex does — a line is a pass you can
            // still spend, and a count tucked into one line reads as a quantity, not as two things
            // you could use on two different days.
            // One line per pass. The chip above them carries the count; these carry the dates.
            let date = Self.shortDateFormatter.string(from: endsAt)
            let caption = Self.resetGrantKind(grant, scopedModels: scopedModels)
            return (endsAt, (0 ..< left).map { _ in
                ModelStatus(name: date, remainingPercent: 0, resetAt: endsAt,
                            valueText: TimeFormatter.compact(from: endsAt.timeIntervalSince(now)),
                            caption: caption, symbol: "plus.circle",
                            groupLabel: ModelStatus.renewalCreditGroup)
            })
        }
        // Soonest to expire first: the one you'd lose next is the one worth seeing.
        .sorted { $0.date < $1.date }
        .flatMap(\.1)
    }

    /// What a grant gives back. `type` is "full" for every kind, so: an explicit `scope` if sent; a
    /// grant that `clears` the seven-day window resets the week; otherwise the model its label names.
    static func resetGrantKind(_ grant: [String: Any], scopedModels: [String]) -> String? {
        if let scope = resetScopeLabel(grant["scope"]) { return scope }
        if (grant["clears"] as? [String])?.contains("seven_day") == true { return ModelStatus.weeklyRenewalScope }
        let label = grant["label"] as? String ?? ""
        return scopedModels.first { !label.isEmpty && label.contains($0) }
    }

    static func resetScopeLabel(_ raw: Any?) -> String? {
        if let object = raw as? [String: Any] {
            if let model = object["model"] as? [String: Any], let name = model["display_name"] as? String { return name }
            if let name = object["display_name"] as? String { return name }
            return resetScopeLabel(object["window"] ?? object["type"])
        }
        guard let text = raw as? String else { return nil }
        switch text.lowercased() {
        case "weekly", "seven_day": return ModelStatus.weeklyRenewalScope
        case "session", "five_hour": return "5h"
        case "all", "all_models": return ModelStatus.allModelsRenewalScope
        default: return text.isEmpty ? nil : text
        }
    }

    /// Dollar-denominated credit windows — Claude Code's usage panel calls the one that exists today
    /// "Cloud session credits" ($250, expiring on its own date, spent before the plan's own quota).
    ///
    /// The usage response carries these under rotating internal code names (`iguana_necktie` at the
    /// time of writing, alongside a dozen other codenamed keys that are null for most accounts), so
    /// matching by name would break the first time Anthropic renames one — and a new credit type
    /// would need a code change to appear at all. What identifies them is their shape: a top-level
    /// object carrying a `limit_dollars`. Reading the shape means any such credit shows up on its
    /// own, and a renamed one keeps working.
    func claudeDollarCreditRows(_ root: [String: Any]) -> [ModelStatus] {
        // Sorted by key so two credits never swap places between refreshes for no reason.
        root.keys.sorted().compactMap { key -> ModelStatus? in
            guard let obj = root[key] as? [String: Any],
                  let limit = doubleValue(obj["limit_dollars"]), limit > 0 else { return nil }
            // Prefer the API's own remaining figure; fall back to limit − used so a response that
            // ships only one of the two still reads correctly.
            let remaining = doubleValue(obj["remaining_dollars"])
                ?? limit - (doubleValue(obj["used_dollars"]) ?? 0)
            // Whole dollars: cents push the row past its width and say nothing at this scale.
            let text = "\(formattedMoney(remaining.rounded(), currency: "USD")) / \(formattedMoney(limit.rounded(), currency: "USD"))"
            // One row: the name carries the date it lapses, the value carries what's left. No
            // group heading — a single credit doesn't need a section to sit under.
            let expiry = (obj["resets_at"] as? String).flatMap(parseISO8601)
            let label = L("Cloud credit")
            let name = expiry.map { "\(label) \(Self.shortDateFormatter.string(from: $0))" } ?? label
            return ModelStatus(name: name, remainingPercent: 0, resetAt: expiry,
                               valueText: text, isLow: remaining <= 0, symbol: "cloud")
        }
    }

    /// Billing/credits row. Prefers the new `spend` object (richer: cap, balance, auto_reload,
    /// disclaimer) and falls back to the legacy `extra_usage` shape for accounts the API hasn't
    /// migrated yet — both are read defensively since neither's rollout is guaranteed complete.

    /// Money as the symbol plus the amount ("$18.40"), which reads shorter than "18.40 USD" in a row
    /// that has to fit a used/limit pair. A currency with no known symbol keeps its code ("TRY 18.40"),
    /// so an unfamiliar one is still unambiguous. Whole amounts drop the ".00".
    func formattedMoney(_ value: Double, currency: String) -> String {
        let whole = value.truncatingRemainder(dividingBy: 1) == 0
        guard !currency.isEmpty else { return whole ? String(Int(value)) : String(format: "%.2f", value) }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = whole ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
    }

    private func claudeBillingRow(_ root: [String: Any]) -> ModelStatus? {
        if let spend = root["spend"] as? [String: Any], spend["enabled"] as? Bool == true {
            return claudeSpendBillingRow(spend)
        }
        return claudeLegacyBillingRow(root["extra_usage"])
    }

    private func claudeSpendBillingRow(_ spend: [String: Any]) -> ModelStatus? {
        guard let usedObj = spend["used"] as? [String: Any] else { return nil }
        let exponent = (usedObj["exponent"] as? Int) ?? 2
        let scale = pow(10, Double(exponent))
        let used = (doubleValue(usedObj["amount_minor"]) ?? 0) / scale
        let cur = (usedObj["currency"] as? String)?.uppercased() ?? ""
        let limit = (spend["limit"] as? [String: Any]).flatMap { doubleValue($0["amount_minor"]) }.map { $0 / scale }
        func money(_ v: Double) -> String { formattedMoney(v, currency: cur) }
        let text = limit.map { "\(money(used)) / \(money($0))" } ?? money(used)
        let util = doubleValue(spend["percent"]) ?? (limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0)
        // Prefer the API's own judgement when it ships one; otherwise the 80%-of-cap heuristic.
        let low = (spend["severity"] as? String)
            .map { !["none", "normal", "ok"].contains($0.lowercased()) } ?? (util >= 80)
        return ModelStatus(name: L("Spending"), remainingPercent: 0, resetAt: nil,
                           valueText: text, isLow: low, symbol: "dollarsign.circle")
    }

    private func claudeLegacyBillingRow(_ raw: Any?) -> ModelStatus? {
        guard let e = raw as? [String: Any], e["is_enabled"] as? Bool == true else { return nil }
        let used = doubleValue(e["used_credits"]) ?? 0
        let limit = doubleValue(e["monthly_limit"])
        let cur = (e["currency"] as? String).map { $0.uppercased() } ?? ""
        func money(_ v: Double) -> String { formattedMoney(v, currency: cur) }
        let text = limit.map { "\(money(used)) / \(money($0))" } ?? money(used)
        let util = doubleValue(e["utilization"]) ?? (limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0)
        return ModelStatus(name: L("Spending"), remainingPercent: 0, resetAt: nil,
                           valueText: text, isLow: util >= 80, symbol: "dollarsign.circle")
    }
    private func mergeClaudeWindows(root: [String: Any], baseKey: String) -> (utilization: Double?, resetAt: Date?) {
        var bestUtil: Double?
        var resetDates: [Date] = []
        for (k, raw) in root where k == baseKey || k.hasPrefix("\(baseKey)_") {
            guard let obj = raw as? [String: Any] else { continue }
            if let utilization = doubleValue(obj["utilization"]) { bestUtil = max(bestUtil ?? utilization, utilization) }
            if let resetRaw = obj["resets_at"] as? String, let date = parseISO8601(resetRaw) {
                resetDates.append(date)
            }
        }
        return (bestUtil, resetDates.sorted().first)
    }
    struct ClaudeToken: Equatable {
        let accessToken: String
        let expiresAt: Date?   // nil when the source is a bare token with no expiry metadata
    }

    /// Pick which Claude token to use from the available sources, in prompt-free-first order:
    ///   1. the on-disk credential file (`file`) — no keychain prompt;
    ///   2. Tiny Usage's own cached access token (`appCache`) — only while it still has more than
    ///      5 minutes of validity (it carries no refresh token, so a near-dead one is useless);
    ///   3. Claude Code's keychain item (`keychain`) — the only prompting source, read solely on a
    ///      user action (`userInitiated`).
    /// `appCache` and `keychain` are closures so a source is touched only if it's actually reached
    /// — in particular the keychain (the prompt) is never invoked when a prompt-free source suffices.
    /// Pure: the ordering/gating rules are testable without the filesystem, the keychain, or the clock.
    static func selectClaudeToken(
        file: ClaudeToken?,
        userInitiated: Bool,
        now: Date,
        appCache: () -> ClaudeToken?,
        silentKeychain: () -> ClaudeToken?,
        keychain: () -> ClaudeToken?
    ) -> ClaudeToken? {
        if let file { return file }
        if let cached = appCache(), let exp = cached.expiresAt, exp.timeIntervalSince(now) > 300 {
            return cached
        }
        // A SILENT keychain read (interaction-not-allowed): returns a token only if Tiny Usage was already
        // granted access to Claude Code's item, so even a background tick stays on LIVE data once the
        // user has allowed it once — and it never pops the macOS dialog (fails quietly otherwise).
        if let silent = silentKeychain() { return silent }
        // The one-time GRANT read can show the dialog, so it's reserved for a user action; a background
        // tick stops here and rides the prompt-free hook/usage cache instead of ever prompting.
        guard userInitiated else { return nil }
        return keychain()
    }

    /// In-memory cache of the Claude OAuth token so the keychain is read only at launch and around
    /// token expiry — not on every refresh. The "Claude Code-credentials" item is owned by Claude
    /// Code, which resets the item's ACL each time it rewrites the entry on its own token refresh;
    /// reading it repeatedly therefore re-triggers the macOS permission prompt. Mirroring Claude
    /// Code's own "read once, reuse" behaviour keeps that prompt rare. An actor because refreshes
    /// run off the main thread.
    private actor ClaudeTokenCache {
        private var token: ClaudeToken?
        func get() -> ClaudeToken? { token }
        func set(_ value: ClaudeToken?) { token = value }
    }
    private static let claudeTokenCache = ClaudeTokenCache()

    /// Read the Claude Code OAuth token plus its expiry, wiring the live sources (file, Tiny Usage's own
    /// cache, Claude Code's keychain item) into `selectClaudeToken`, which holds the prompt-free-first
    /// ordering and the user-action gate. The keychain — the only prompting source — is a closure, so
    /// it's reached only when no prompt-free source has a usable token and the read is user-initiated.
    /// `expiresAt` drives whether `fetchClaude` refreshes before calling the usage API.
    private func readClaudeTokenInfo(userInitiated: Bool) -> ClaudeToken? {
        if ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] != nil { return readClaudeCredentialFileToken() }
        return Self.selectClaudeToken(
            file: readClaudeCredentialFileToken(),
            userInitiated: userInitiated,
            now: Date(),
            appCache: { readCachedClaudeToken() },
            silentKeychain: {
                guard let raw = readClaudeKeychainItem(interactive: false) else { return nil }
                return parseClaudeToken(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            keychain: {
                guard let raw = readClaudeKeychainItem(interactive: true) else { return nil }
                return parseClaudeToken(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            })
    }

    /// Claude Code's statusLine hook writes its own session JSON — including the official 5h/7d
    /// rate-limit numbers it already fetched server-side — to `~/.claude/tiny-usage.json` on every
    /// render (see `ClaudeStatusLineHook`). Reading that file is the prompt-free primary source for the
    /// session/weekly windows: no keychain, no token, no network. Returns nil when the file is absent,
    /// older than `maxAge`, malformed, or carries no `rate_limits` at all (older Claude Code / no
    /// subscription limits). Either window inside may still be individually nil — Anthropic's own
    /// statusline docs confirm `five_hour`/`seven_day` can each be independently absent (no session yet
    /// this launch, a Team-plan account that never gets `rate_limits`, or a window Claude Code has
    /// already dropped once its `resets_at` passed) — the caller (`claudeCardFromHook`) fills in
    /// whichever one is missing from the existing usage cache instead of losing the whole reading. Note
    /// `resets_at` here is epoch SECONDS (a number), unlike the OAuth API's ISO string.
    func readClaudeHookUsage(maxAge: TimeInterval, path: String = ClaudeStatusLineHook.usagePath)
        -> (five: (used: Double, reset: Date?)?, seven: (used: Double, reset: Date?)?)? {
        let now = Date()
        for candidate in [URL(fileURLWithPath: path)] {
            guard let vals = try? candidate.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = vals.contentModificationDate, (vals.fileSize ?? 0) <= 1_048_576,
                  now.timeIntervalSince(mtime) >= -60, now.timeIntervalSince(mtime) <= maxAge,
                  let data = try? Data(contentsOf: candidate),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsed = Self.parseHookRateLimits(root) else { continue }
            let captured = Self.doubleFromJSON(root["captured_at"]).map(Date.init(timeIntervalSince1970:)) ?? mtime
            guard now.timeIntervalSince(captured) >= -60, now.timeIntervalSince(captured) <= maxAge else { continue }
            let five = parsed.five.flatMap { $0.reset.map { $0 > now } == false ? nil : $0 }
            let seven = parsed.seven.flatMap { $0.reset.map { $0 > now } == false ? nil : $0 }
            if five != nil || seven != nil { return (five, seven) }
        }
        return nil
    }

    func hookObservedAt(path: String = ClaudeStatusLineHook.usagePath) -> Date? {
        for url in [URL(fileURLWithPath: path)] {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, Date().timeIntervalSince(modified) <= 1800,
                  let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let captured = Self.doubleFromJSON(root["captured_at"]).map(Date.init(timeIntervalSince1970:)) ?? modified
            if Date().timeIntervalSince(captured) <= 1800 { return min(captured, modified) }
        }
        return nil
    }

    /// Pure: pull the 5h/7d windows out of a statusLine JSON root. `resets_at` is epoch SECONDS.
    /// Returns nil only when `rate_limits` itself is missing; either window inside it may still come
    /// back nil on its own (see `readClaudeHookUsage`) as long as at least one is present. Testable
    /// without the filesystem.
    static func parseHookRateLimits(_ root: [String: Any])
        -> (five: (used: Double, reset: Date?)?, seven: (used: Double, reset: Date?)?)? {
        guard let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> (used: Double, reset: Date?)? {
            guard let obj = limits[key] as? [String: Any],
                  let used = doubleFromJSON(obj["used_percentage"]) else { return nil }
            let reset = doubleFromJSON(obj["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            return (used, reset)
        }
        let five = window("five_hour")
        let seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return (five, seven)
    }

    /// A JSON number (or numeric string) as Double — free function so `parseHookRateLimits` can stay
    /// `static` (the instance `doubleValue` isn't reachable from a static context).
    static func doubleFromJSON(_ any: Any?) -> Double? {
        let value = (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init)
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    /// A second Claude Code login (`ExtraAccount`). Its status line hook file is prompt-free, but
    /// Claude Code only renders a status line in an interactive session (a login driven by `claude -p`
    /// never writes it) and it carries no per-model limits. So the login's own keychain item serves
    /// the API too, under the main card's rules: silent once granted, the prompting read only on the
    /// Authorize action. Then the hook, then the snapshot.
    func fetchClaudeExtraAccount(name: String, dir: URL, userInitiated: Bool,
                                 accountID: String? = nil) async -> ServiceStatus {
        let hookPath = dir.appendingPathComponent("tiny-usage.json").path
        let service = Self.claudeKeychainService(forConfigDir: dir.path)
        // Tiny Usage's own copy of this login's access token: read back without a prompt, so the keychain
        // prompt comes at most once per token, not on every open.
        let mirror = "\(Self.claudeTokenCacheService)-\(service)"
        // Another login in the same dir: the previous one's token, hook and snapshot would show its
        // numbers under the new login's name, so they go before anything reads them.
        if await Self.extraTokenCache.switched(service, to: accountID) {
            await Self.extraTokenCache.set(service, nil)
            deleteCachedClaudeToken(service: mirror)
            try? FileManager.default.removeItem(at: snapshotURL(for: name))
        }
        let hook = readClaudeHookUsage(maxAge: 30 * 60, path: hookPath)
        // An isolated test home never touches the real keychain.
        if ProcessInfo.processInfo.environment["TINY_USAGE_TEST_HOME"] != nil {
            return hook.map { claudeExtraCardFromHook($0, name: name, path: hookPath) }
                ?? snapshotOrFallback(name, iconName: "claude")
        }

        // The API too, for what the hook lacks (Fable's own weekly, say) — silent unless authorizing.
        var expired = false
        do {
            var token = await Self.extraTokenCache.get(service)
                ?? readCachedClaudeToken(service: mirror).flatMap { ($0.expiresAt?.timeIntervalSinceNow ?? 0) > 300 ? $0 : nil }
            if token.map({ ($0.expiresAt?.timeIntervalSinceNow ?? 0) <= 300 }) ?? true {
                let raw = readClaudeKeychainItem(interactive: false, service: service)
                    ?? (userInitiated
                        ? readClaudeKeychainItem(interactive: true, service: service) : nil)
                let parsed = raw.flatMap { parseClaudeToken($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                expired = parsed.map { ($0.expiresAt?.timeIntervalSinceNow ?? 0) <= 30 } ?? false
                token = expired ? nil : parsed
                await Self.extraTokenCache.set(service, token)
                if let token { cacheClaudeToken(token, service: mirror) }
            }
            if let token {
                if let root = await fetchClaudeOAuthUsage(token.accessToken, accountKey: name) {
                    if Self.claudeAccount(configFile: dir.appendingPathComponent(".claude.json"))?.plan == nil {
                        await rememberClaudePlan(token.accessToken)
                    }
                    let status = buildClaudeStatus(from: root, note: "oauth usage api", name: name)
                        .withAccount(Self.claudeAccount(configFile: dir.appendingPathComponent(".claude.json")))
                        .withObservedAt(Date())
                    saveSnapshot(status)
                    return status
                }
                await Self.extraTokenCache.set(service, nil)
                deleteCachedClaudeToken(service: mirror)
            }
        }

        if let hook { return claudeExtraCardFromHook(hook, name: name, path: hookPath) }
        let note = expired ? L("token expired — open Claude Code") : L("out of date")
        let snapshot = loadSnapshot(for: name, iconName: "claude", staleNote: note)
        // An expired login can't refresh these numbers: grey, so opening Tiny Usage renews it.
        return (expired ? snapshot?.markedStale(note) : snapshot)
            ?? unavailableService(name: name, iconName: "claude", models: [])
    }

    private func claudeExtraCardFromHook(
        _ hook: (five: (used: Double, reset: Date?)?, seven: (used: Double, reset: Date?)?),
        name: String, path: String
    ) -> ServiceStatus {
        ServiceStatus(
            name: name, iconName: "claude",
            sessionResetAt: hook.five?.reset, weeklyResetAt: hook.seven?.reset,
            sessionRemainingPercent: hook.five.map { remainingPercent(fromUsed: $0.used) },
            weeklyRemainingPercent: hook.seven.map { remainingPercent(fromUsed: $0.used) },
            models: loadSnapshot(for: name, iconName: "claude")?.models ?? [],
            isAvailable: true, statusNote: L("Local status line · extras from last capture"), observedAt: hookObservedAt(path: path))
    }

    static func claudePlanKey(_ org: String) -> String { "claude.plan.\(org)" }

    /// Claude Code writes the plan into its profile file only after its own profile fetch, so a
    /// fresh login can lack it — and the card shows no plan, and no way to its e-mail. Then ask the
    /// endpoint Claude Code asks, and remember the answer by organization.
    func rememberClaudePlan(_ accessToken: String) async {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!, timeoutInterval: 10)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (org, plan) = Self.claudeProfilePlan(root) else { return }
        UserDefaults.standard.set(plan, forKey: Self.claudePlanKey(org))
    }

    /// The organization and plan in an `/api/oauth/profile` answer. Pure → unit-testable.
    static func claudeProfilePlan(_ root: [String: Any]) -> (org: String, plan: String)? {
        guard let org = root["organization"] as? [String: Any], let uuid = org["uuid"] as? String,
              let plan = AccountInfo.claudePlan(org["organization_type"] as? String,
                                                rateLimitTier: org["rate_limit_tier"] as? String) else { return nil }
        return (uuid, plan)
    }

    /// One GET of the OAuth usage endpoint; nil on any failure (the caller falls back to its snapshot).
    private func fetchClaudeOAuthUsage(_ accessToken: String, accountKey: String) async -> [String: Any]? {
        let key = "claude-extra:\(accountKey)"
        guard await EndpointBackoff.shared.remaining(key) <= 0 else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        await EndpointBackoff.shared.record(response, key: key)
        guard (response as? HTTPURLResponse).map({ 200 ... 299 ~= $0.statusCode }) == true else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Second logins' access tokens, by keychain service — read once, reused until near expiry.
    private actor ExtraTokenCache {
        private var tokens: [String: ClaudeToken] = [:]
        func get(_ service: String) -> ClaudeToken? { tokens[service] }
        func set(_ service: String, _ token: ClaudeToken?) { tokens[service] = token }

        private var accounts: [String: String] = [:]
        /// Records the login a dir holds; true when it differs from the one seen before.
        func switched(_ service: String, to account: String?) -> Bool {
            guard let account else { return false }
            defer { accounts[service] = account }
            return accounts[service].map { $0 != account } ?? false
        }
    }
    private static let extraTokenCache = ExtraTokenCache()

    /// Build Claude's card from the prompt-free statusLine hook. The fresh 5h/7d numbers come from the
    /// hook; the per-model rows (e.g. Fable) and the billing row are overlaid from the most recent
    /// OAuth usage cache (≤24h) so they still show — richer than the hook, and stale-safe because the
    /// hook's live session/weekly percents replace the cache's. When no recent cache exists, the card
    /// shows session/weekly only. ponytail: overlaid per-model rows are trusted within their weekly
    /// window; a real user open refreshes them live via the OAuth API.
    ///
    /// The hook is authoritative for both windows even when it reports only one (see
    /// `parseHookRateLimits`): a reported window replaces the cache's, and an omitted one is dropped
    /// rather than carried over. Claude Code omits a window once its `resets_at` has passed, so the
    /// cached copy is exactly the refilled window's stale percent — and `live: true` below skips
    /// reset-classification, so carrying it would show that percent as current. Dropped, the window
    /// reads as 0% used, which after a reset is the truth.
    func claudeCardFromHook(_ hook: (five: (used: Double, reset: Date?)?, seven: (used: Double, reset: Date?)?)) -> ServiceStatus {
        var root = readClaudeUsageCache(maxAge: 24 * 60 * 60) ?? [:]
        let iso = ISO8601DateFormatter()
        func windowDict(_ w: (used: Double, reset: Date?)) -> [String: Any] {
            var d: [String: Any] = ["utilization": w.used]
            if let r = w.reset { d["resets_at"] = iso.string(from: r) }
            return d
        }
        // A window the account has but the hook left out has reset: it reads as refilled. One the
        // account never had (a Team seat without a weekly limit) stays absent.
        for k in root.keys where k == "five_hour" || k.hasPrefix("five_hour_")
            || k == "seven_day" || k.hasPrefix("seven_day_") { root.removeValue(forKey: k) }
        if let five = hook.five { root["five_hour"] = windowDict(five) }
        if let seven = hook.seven { root["seven_day"] = windowDict(seven) }
        return buildClaudeStatus(from: root, note: L("Local status line · extras from last API capture"), live: true)
            .withObservedAt(hookObservedAt())
    }

    /// The OAuth token from the on-disk credential file only (no keychain, so no prompt).
    private func readClaudeCredentialFileToken() -> ClaudeToken? {
        let credPath = URL(fileURLWithPath: ClaudeStatusLineHook.claudePath(".credentials.json"))
        guard let data = try? Data(contentsOf: credPath),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseClaudeToken(raw)
    }

    /// When this process started. A cache entry older than this was written by a previous run —
    /// see `claudeCacheCountsAsFresh`.
    private static let launchedAt = Date()

    /// Is a cache entry fresh enough to skip a live fetch?
    ///
    /// Age alone isn't the whole rule. An entry written by an *earlier* run still loads instantly
    /// (that's what keeps the card from flashing placeholders at launch), but it must never let the
    /// app skip its first refresh: right after an update the user would otherwise stare at the
    /// previous version's numbers until the interval lapsed. `writtenThisSession` marks the callers
    /// that decide whether to fetch; the deep fallbacks pass false and keep trusting age alone.
    ///
    /// Pure so the rule can be unit-tested without touching the filesystem.
    static func claudeCacheCountsAsFresh(
        modifiedAt: Date, now: Date, maxAge: TimeInterval,
        launchedAt: Date, writtenThisSession: Bool
    ) -> Bool {
        guard now.timeIntervalSince(modifiedAt) <= maxAge else { return false }
        return writtenThisSession ? modifiedAt >= launchedAt : true
    }

    private func readClaudeUsageCache(maxAge: TimeInterval, writtenThisSession: Bool = false) -> [String: Any]? {
        let url = claudeUsageCacheURL()
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate,
              Self.claudeCacheCountsAsFresh(modifiedAt: modifiedAt, now: Date(), maxAge: maxAge,
                                            launchedAt: Self.launchedAt,
                                            writtenThisSession: writtenThisSession) else {
            return nil
        }
        return readClaudeUsageCacheRaw()
    }

    /// Drop the cached usage and the saved snapshot when the account that produced them is not the
    /// one we just read. Without this the previous account's percentages survive the switch: the
    /// 5-minute cache shows them until it ages out, and the snapshot can show them for up to a day
    /// whenever a live fetch fails.
    ///
    /// The id is the organization UUID: Claude Code's profile (`.claude.json`) names it, and so does
    /// Claude.app's session, so a switch made through either is caught.
    func noteClaudeAccount(_ accountID: String) {
        let url = claudeAccountFileURL()
        let previous = try? String(contentsOf: url, encoding: .utf8)
        if let previous, previous != accountID {
            try? FileManager.default.removeItem(at: claudeUsageCacheURL())
            try? FileManager.default.removeItem(at: snapshotURL(for: "Claude"))
        }
        if previous != accountID {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? accountID.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func claudeAccountFileURL() -> URL {
        LiveUsageDataSource.supportDirectory.appendingPathComponent("claude_account")
    }

    /// The cached usage JSON regardless of age — used as a deep fallback that is trusted not by
    /// age but by each window's reset time (a weekly number from a 3-day-old cache is still right
    /// if that week hasn't reset yet).
    private func readClaudeUsageCacheRaw() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeUsageCacheURL()),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
    }

    func writeClaudeUsageCache(_ data: Data) {
        let url = claudeUsageCacheURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if payload["cedar_ember"] != nil {
                payload["_ay_reset_observed_at"] = Date().timeIntervalSince1970
            } else if let old = readClaudeUsageCacheRaw(), let grants = old["cedar_ember"] {
                payload["cedar_ember"] = grants
                payload["_ay_reset_observed_at"] = old["_ay_reset_observed_at"]
            }
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            try Self.secureAtomicWrite(data: bytes, to: url)
        } catch {
            // Cache is an optimization; the live result is still usable.
        }
    }

    private func claudeUsageCacheURL() -> URL {
        LiveUsageDataSource.supportDirectory.appendingPathComponent("claude_usage.json")
    }

    private func parseClaudeToken(_ raw: String) -> ClaudeToken? {
        if raw.hasPrefix("sk-ant-") || raw.hasPrefix("sk-ant-oat") {
            return ClaudeToken(accessToken: raw, expiresAt: nil)
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String {
            return ClaudeToken(accessToken: token, expiresAt: epochMillisToDate(oauth["expiresAt"]))
        }
        if let token = obj["accessToken"] as? String {
            return ClaudeToken(accessToken: token, expiresAt: epochMillisToDate(obj["expiresAt"]))
        }
        return nil
    }
    /// Claude Code no longer keeps its login only under the exact legacy service name — newer
    /// versions write per-config items named "Claude Code-credentials-<hash>" and leave the legacy
    /// item behind with a dead token. List every matching item's ATTRIBUTES (no kSecReturnData, so
    /// this never pops the keychain prompt) and order newest-modified first: the item Claude Code
    /// last rewrote is the live login.
    ///
    /// `excluding` drops the items a second login owns (see `claudeKeychainService(forConfigDir:)`):
    /// newest-first would otherwise hand the main card whichever account refreshed last.
    static func claudeKeychainServicesOrdered(_ items: [(service: String, modifiedAt: Date?)],
                                              excluding: Set<String> = []) -> [String] {
        items.filter { $0.service == claudeKeychainService || $0.service.hasPrefix("\(claudeKeychainService)-") }
            .filter { !excluding.contains($0.service) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .map(\.service)
    }

    private func claudeKeychainCandidates() -> [(service: String, account: String?, modifiedAt: Date?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard KeychainAccess.perform({ SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let attrs = items.compactMap { dict -> (service: String, account: String?, modifiedAt: Date?)? in
            guard let service = dict[kSecAttrService as String] as? String else { return nil }
            return (service, dict[kSecAttrAccount as String] as? String,
                    dict[kSecAttrModificationDate as String] as? Date)
        }
        let others = Set(ExtraAccount.claude.map { Self.claudeKeychainService(forConfigDir: $0.dir.path) })
        let ordered = Self.claudeKeychainServicesOrdered(attrs.map { ($0.service, $0.modifiedAt) },
                                                         excluding: others)
        return ordered.compactMap { service in
            attrs.first { $0.service == service }
        }
    }

    /// One named item's attributes (no data, so no prompt); a missing item still yields the name.
    private func keychainAttributes(_ service: String) -> (service: String, account: String?, modifiedAt: Date?) {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnAttributes as String: true]
        let status = KeychainAccess.perform { SecItemCopyMatching(query as CFDictionary, &result) }
        let attrs = status == errSecSuccess ? result as? [String: Any] : nil
        return (service, attrs?[kSecAttrAccount as String] as? String, attrs?[kSecAttrModificationDate as String] as? Date)
    }

    /// The item Claude Code keeps a `CLAUDE_CONFIG_DIR` login under: the service name plus the first
    /// 8 hex digits of the dir's SHA-256 (Claude Code's own naming).
    static func claudeKeychainService(forConfigDir dir: String) -> String {
        let hash = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(claudeKeychainService)-\(hash.prefix(8))"
    }

    /// Read the DATA of a SINGLE Claude Code keychain item — the newest-modified one, which is the
    /// login Claude Code last wrote (on macOS normally the plain "Claude Code-credentials"). Reading an
    /// item's data pops the macOS permission prompt when Tiny Usage isn't in that item's ACL, so we read
    /// exactly ONE item: one prompt, not one per item. Looping data-reads over every candidate (24+
    /// stale per-config items on a long-lived machine) fired a prompt for each until one parsed — a
    /// storm — and because each item has its own ACL, the user's "Always Allow" on one never covered
    /// the next, so the storm never stopped. Reading the same single item every time means one
    /// "Always Allow" sticks (grant tied to Tiny Usage's stable release signature). If it doesn't parse we
    /// return nil rather than reach for the next item: the prompt-free hook/usage cache already carry
    /// the card, so a missed enrichment is far cheaper than a prompt storm.
    /// `service` names a second login's item outright (see `claudeKeychainService(forConfigDir:)`).
    private func readClaudeKeychainItem(interactive: Bool, service: String? = nil) -> String? {
        guard let candidate = service.map(keychainAttributes) ?? claudeKeychainCandidates().first else { return nil }
        let query: [String: Any] = {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            // A background read attaches an interaction-not-allowed context: if Tiny Usage is already in the
            // item's ACL (the user granted once) the read succeeds SILENTLY and keeps the card on live
            // data; if not, it fails with errSecInteractionNotAllowed — never a prompt. Verified: this
            // suppresses the macOS keychain dialog. The prompting (grant) read is reserved for a user
            // action (opening Tiny Usage), so a background tick can never pop the dialog.
            if !interactive {
                let ctx = LAContext()
                ctx.interactionNotAllowed = true
                q[kSecUseAuthenticationContext as String] = ctx
            }
            return q
        }()

        // Interactive access is reached only after explicit authorization confirmation. Allow
        // another deliberate attempt after a refusal; ordinary refreshes always remain silent.

        var result: CFTypeRef?
        guard KeychainAccess.perform(interactive: interactive, credentialService: candidate.service, {
            SecItemCopyMatching(query as CFDictionary, &result)
        }) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              parseClaudeToken(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            return nil
        }
        return value
    }

    static var claudeTokenCacheService: String {
        if let session = KeychainAccess.newUserSessionID { return "TinyUsage-claude-oauth-newuser-\(session)" }
        return "TinyUsage-claude-oauth"
    }

    /// Cache ONLY the short-lived access token (+ its expiry) in Tiny Usage's OWN keychain item. We never
    /// store the refresh token here: refresh tokens rotate single-use and are shared with Claude
    /// Code, so refreshing from a private copy would silently invalidate Claude Code's own login.
    /// This item can also need a new ACL grant after a development rebuild. Cache operations are
    /// always noninteractive; an inaccessible mirror is optional, so reuse the in-memory token.
    private func cacheClaudeToken(_ token: ClaudeToken, service: String = claudeTokenCacheService) {
        guard let expiresAt = token.expiresAt else { return }  // nothing to expiry-check → don't cache
        let payload: [String: Any] = [
            "accessToken": token.accessToken,
            "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName()
        ]
        _ = KeychainAccess.perform {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecItemNotFound else { return status }
            var add = query
            add[kSecValueData as String] = data
            // Background refreshes run while the screen may be locked, so the item must be readable
            // after the first unlock — not only while unlocked (the SecItemAdd default).
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Drop Tiny Usage's cached access token. Called when the server rejects it (401/403): otherwise a
    /// background tick would keep replaying the dead token, since the keychain holding a fresh one is
    /// read only on a user action. Safe to call when the item is absent (`SecItemDelete` no-ops).
    private func deleteCachedClaudeToken(service: String = claudeTokenCacheService) {
        _ = KeychainAccess.perform {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ] as CFDictionary)
        }
    }

    /// Read Tiny Usage's own cached access token (prompt-free — Tiny Usage owns this item). Returns nil when
    /// the item is missing or malformed; the caller checks `expiresAt` before trusting it.
    private func readCachedClaudeToken(service: String = claudeTokenCacheService) -> ClaudeToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard KeychainAccess.perform({ SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess,
              let data = result as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accessToken"] as? String, !access.isEmpty else {
            return nil
        }
        return ClaudeToken(accessToken: access, expiresAt: epochMillisToDate(obj["expiresAt"]))
    }
}
