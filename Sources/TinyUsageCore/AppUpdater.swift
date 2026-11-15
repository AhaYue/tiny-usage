import Foundation
import Sparkle

/// Sparkle auto-update. The feed and public key live in Info.plist (written by build-app.sh);
/// releases are built, EdDSA-signed and published by .github/workflows/release.yml.
///
/// Starts only inside a real bundle that names a feed, so `swift test`, `swift run` and the
/// preview renderer never touch the network or show Sparkle UI.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let inBundle = Bundle.main.bundleURL.pathExtension == "app"
        controller = (feed?.isEmpty == false && inBundle)
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
