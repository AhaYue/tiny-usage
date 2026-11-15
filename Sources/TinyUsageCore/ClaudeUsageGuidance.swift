import Foundation

/// Describes the local source without probing credentials or requesting keychain access.
enum ClaudeLocalCaptureState: Equatable {
    case disabled, waiting, outdated, ready

    static func current() -> Self {
        guard ClaudeStatusLineHook.isWired() else { return .disabled }
        guard FileManager.default.fileExists(atPath: ClaudeStatusLineHook.usagePath) else { return .waiting }
        return LiveUsageDataSource().readClaudeHookUsage(maxAge: 30 * 60) == nil ? .outdated : .ready
    }
}

/// Guidance for Claude when usage is missing or an earlier reading is shown.
struct ClaudeUsageGuidance: Equatable {
    enum State: Equatable {
        /// Waiting for Claude Code to write usage; authorizing would read it over the network now.
        case waiting
        /// Claude Code's login lapsed; only Claude Code can renew it.
        case loginExpired
        /// The request itself failed (rate limit, network); nothing to do but retry later.
        case unavailable
    }

    let state: State
    let title: String
    let detail: String?
    let offersAuthorize: Bool

    static func resolve(service: ServiceStatus, capture: ClaudeLocalCaptureState) -> Self? {
        guard service.name == "Claude" else { return nil }
        let note = service.statusNote ?? ""
        let saved = service.isStale || (service.isAvailable && (service.dataUnavailable || note == "snapshot"))
        guard !service.isAvailable || saved else { return nil }

        if note.hasPrefix("claude http ") || note == "claude request failed" || note == "claude no http response" {
            return Self(state: .unavailable, title: L("Can't update right now"), detail: nil, offersAuthorize: false)
        }
        if note == L("token expired — open Claude Code") {
            return Self(state: .loginExpired, title: L("Claude login expired"), detail: L("Open Claude Code to restore it."),
                        offersAuthorize: false)
        }
        if saved {
            return Self(state: .waiting, title: L("Last usage · Waiting to update"), detail: nil, offersAuthorize: true)
        }
        let title = capture == .outdated || capture == .ready ? L("Waiting for a usage update") : L("Waiting for first local data")
        let detail = capture == .disabled ? nil : L("Usage appears after you use Claude Code.")
        return Self(state: .waiting, title: title, detail: detail, offersAuthorize: true)
    }
}
