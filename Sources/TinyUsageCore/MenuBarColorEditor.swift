import SwiftUI

struct MenuBarColorEditor: View {
    @Binding var rgb: UInt32
    @State private var hexText: String
    @FocusState private var hexFocused: Bool

    init(rgb: Binding<UInt32>) {
        _rgb = rgb
        _hexText = State(initialValue: Self.hexString(rgb.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(L("Hex color"))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(L("Hex color"), text: $hexText)
                    .labelsHidden()
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 76)
                    .focused($hexFocused)
                    .onSubmit { hexText = Self.hexString(rgb) }
            }
            channelSlider(L("Red"), shift: 16)
            channelSlider(L("Green"), shift: 8)
            channelSlider(L("Blue"), shift: 0)
        }
        .font(.system(size: 11))
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .onChange(of: hexText) { _, text in
            if let value = Self.parseHex(text), value != rgb { rgb = value }
        }
        .onChange(of: rgb) { _, value in
            if Self.parseHex(hexText) != value { hexText = Self.hexString(value) }
        }
        .onChange(of: hexFocused) { _, focused in
            if !focused { hexText = Self.hexString(rgb) }
        }
    }

    private func channelSlider(_ label: String, shift: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 37, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { Double((rgb >> shift) & 0xff) }, set: { value in
                let mask: UInt32 = 0xff << shift
                rgb = (rgb & ~mask) | (UInt32(value.rounded()) << shift)
            }), in: 0...255, step: 1) { Text(label) }
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private static func hexString(_ rgb: UInt32) -> String {
        String(format: "#%06X", rgb)
    }

    nonisolated static func parseHex(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.first == "#" ? trimmed.dropFirst() : trimmed[...]
        guard digits.utf8.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }
}
