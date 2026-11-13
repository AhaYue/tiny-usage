import AppKit
import Foundation

@MainActor
enum BrandIconLoader {
    private static var images: [String: NSImage] = [:]
    static func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "BrandIcons")
                ?? Bundle.main.url(forResource: name, withExtension: "svg")
                ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources/BrandIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        images[name] = image
        return image
    }
}
