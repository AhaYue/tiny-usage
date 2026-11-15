import AppKit
import Foundation

@MainActor
enum BrandIconLoader {
    private static var images: [String: NSImage] = [:]
    static func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let url = ResourceLookup.url(forResource: name, withExtension: "svg", subdirectory: "BrandIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        images[name] = image
        return image
    }
}

/// The shipped .app flattens resources into Contents/Resources (Bundle.main). A bare `swift build`
/// binary, a test run and Xcode Previews keep them in the SwiftPM bundle instead. Look there too —
/// without `Bundle.module`, whose accessor traps when the bundle is absent (as it is in the .app).
enum ResourceLookup {
    private final class Token {}
    static let bundles: [Bundle] = {
        var found = [Bundle.main]
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: Token.self).resourceURL,
                     Bundle(for: Token.self).bundleURL, Bundle(for: Token.self).bundleURL.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent("TinyUsage_TinyUsageCore.bundle")), !found.contains(bundle) {
                found.append(bundle)
            }
        }
        return found
    }()

    static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        for bundle in bundles {
            if let subdirectory, let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources/" + subdirectory) { return url }
            if let url = bundle.url(forResource: name, withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources") { return url }
        }
        return nil
    }
}

extension Bundle {
    /// Where the app's Localizable.strings live: Contents/Resources in the shipped .app, the SwiftPM
    /// resource bundle in Xcode Previews, tests and bare builds. `String(localized:)` defaults to
    /// Bundle.main, which in a preview is Xcode's host and has none of the app's strings.
    static let tinyUsage: Bundle = ResourceLookup.bundles.first {
        $0.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans") != nil
            || $0.path(forResource: "Localizable", ofType: "strings", inDirectory: "Resources/zh-Hans.lproj") != nil
    } ?? .main
}
