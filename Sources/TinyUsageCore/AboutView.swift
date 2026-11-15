import SwiftUI

/// Settings › 关于: version, the projects Tiny Usage builds on or borrowed from (link + license
/// name only), and the full text of Tiny Usage's own license, read from the bundled LICENSE.txt so
/// the text shown is the text shipped.
struct AboutView: View {
    let version: String
    var hookWired: () -> Bool = { false }
    var setHook: (Bool) -> Void = { _ in }
    @State private var wired = false

    private struct Credit: Identifiable {
        let name: String
        let url: String
        let role: String
        let license: String
        var id: String { name }
    }

    private static let credits = [
        Credit(name: "Mimir", url: "https://github.com/erayendes/mimir",
               role: L("Upstream project: Tiny Usage is derived from Mimir (© 2026 Eray Endes)."),
               license: L("MIT License")),
        Credit(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle",
               role: L("In-app updates (© Sparkle Project and contributors)."),
               license: L("MIT License")),
        Credit(name: "ai-usage", url: "https://github.com/wawaka/ai-usage",
               role: L("Visual and interaction reference; none of its code or assets are used."),
               license: L("No open-source license declared")),
    ]

    private static var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "MIT License\n\nCopyright (c) 2026 AhaYue\nCopyright (c) 2026 Eray Endes (Mimir)"
        }
        return reflow(text)
    }

    /// LICENSE is hard-wrapped at ~80 columns; the window wraps too, which leaves ragged lines.
    /// Join lines inside each paragraph, but keep the copyright lines one per line.
    static func reflow(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.hasPrefix("Copyright") ? paragraph
                    : paragraph.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            .joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tiny Usage").font(.system(size: 18, weight: .semibold))
                        Text(L("Version \(version)"))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                section(L("Acknowledgements")) {
                    ForEach(Self.credits) { credit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(credit.name).font(.system(size: 12, weight: .semibold))
                                Text(credit.license)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            Text(credit.role).foregroundStyle(.secondary)
                            Link(credit.url.replacingOccurrences(of: "https://", with: ""),
                                 destination: URL(string: credit.url)!)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                }

                section(L("Claude status line")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(wired ? L("Reads usage through Claude Code's status line and keeps your existing one.")
                                   : L("Not connected. Claude usage needs authorization to query."))
                            .foregroundStyle(.secondary)
                        Button(wired ? L("Disconnect") : L("Reconnect")) {
                            setHook(!wired)
                            wired = hookWired()
                        }
                        .controlSize(.small)
                    }
                }

                section(L("Tiny Usage License")) {
                    Text(Self.licenseText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 400)
        .onAppear { wired = hookWired() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content().font(.system(size: 12))
        }
    }
}
