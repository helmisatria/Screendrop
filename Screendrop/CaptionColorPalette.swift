import SwiftUI

struct CaptionColorPalettePicker: View {
    let title: String
    @Binding var selection: CaptionColor
    let defaultColor: CaptionColor
    @State private var isPresented = false

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Button { isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    CaptionColorSwatch(color: selection).frame(width: 16, height: 16)
                    Text(CaptionPaletteColor.name(for: selection)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) color")
            .accessibilityValue(CaptionPaletteColor.name(for: selection))
            .popover(isPresented: $isPresented) {
                CaptionColorPalette(title: title, selection: $selection, defaultColor: defaultColor)
            }
        }
    }
}

struct CaptionColorPalette: View {
    let title: String
    @Binding var selection: CaptionColor
    let defaultColor: CaptionColor
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(CaptionPaletteColor.name(for: selection))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                paletteRow(CaptionPaletteColor.neutrals)
                Divider().padding(.vertical, 2)
                ForEach(0..<3) { row in
                    paletteRow(Array(CaptionPaletteColor.colors[(row * 7)..<(row * 7 + 7)]))
                }
            }
            HStack {
                Button {
                    selection.alpha = 0
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.slash")
                        Text("None")
                        if selection.alpha == 0 { Image(systemName: "checkmark") }
                    }
                }.buttonStyle(.plain).accessibilityLabel("No \(title.lowercased()) color")
                Spacer()
                Text("\(Int((selection.alpha * 100).rounded()))% opacity")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.font(.system(size: 11))
            Slider(value: $selection.alpha, in: 0...1)
                .controlSize(.small).accessibilityLabel("\(title) opacity")
            Button {
                selection = defaultColor
            } label: {
                Label("Reset to default", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .disabled(selection == defaultColor)
            .accessibilityLabel("Reset \(title.lowercased()) color to default")
            Divider()
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                ColorPicker("Custom color", selection: Binding(
                    get: { selection.color },
                    set: { selection = CaptionColor($0) }
                ), supportsOpacity: true)
                .padding(.top, 8)
            }.font(.system(size: 11))
        }
        .padding(16)
        .frame(width: 290)
    }

    private func paletteRow(_ colors: [CaptionPaletteColor]) -> some View {
        HStack(spacing: 8) {
            ForEach(colors) { swatch in
                let selected = selection.alpha > 0 && swatch.matches(selection)
                Button {
                    var color = swatch.color
                    // Keep the chosen opacity, but make a color visible after None.
                    color.alpha = selection.alpha > 0 ? selection.alpha : 1
                    selection = color
                } label: {
                    CaptionColorSwatch(color: swatch.color)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(swatch.isLight ? Color.black : Color.white)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .padding(1)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? Color.primary.opacity(0.65) : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }
}

private struct CaptionColorSwatch: View {
    let color: CaptionColor
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color.alpha == 0 ? Color.clear : color.color)
            .background {
                if color.alpha < 1 {
                    Canvas { context, size in
                        let cell: CGFloat = 4
                        for row in 0..<Int(ceil(size.height / cell)) {
                            for column in 0..<Int(ceil(size.width / cell)) {
                                let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                                context.fill(Path(rect), with: .color((row + column).isMultiple(of: 2) ? .white : .gray.opacity(0.4)))
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
    }
}

private struct CaptionPaletteColor: Identifiable {
    let name: String
    let hex: UInt32
    var id: String { name }
    var color: CaptionColor {
        CaptionColor(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
    var isLight: Bool { color.red * 0.299 + color.green * 0.587 + color.blue * 0.114 > 0.62 }
    func matches(_ other: CaptionColor) -> Bool {
        abs(color.red - other.red) < 0.005 && abs(color.green - other.green) < 0.005 && abs(color.blue - other.blue) < 0.005
    }
    static func name(for color: CaptionColor) -> String {
        if color.alpha == 0 { return "None" }
        return (neutrals + colors).first { $0.matches(color) }?.name ?? "Custom"
    }

    // Tailwind's sRGB palette: neutrals, then 300 / 500 / 800 shades by hue.
    // https://v3.tailwindcss.com/docs/customizing-colors
    static let neutrals: [Self] = [
        .init(name: "White", hex: 0xffffff), .init(name: "Slate 100", hex: 0xf1f5f9),
        .init(name: "Slate 300", hex: 0xcbd5e1), .init(name: "Slate 500", hex: 0x64748b),
        .init(name: "Slate 700", hex: 0x334155), .init(name: "Slate 900", hex: 0x0f172a),
        .init(name: "Black", hex: 0x000000)
    ]
    static let colors: [Self] = [
        .init(name: "Rose 300", hex: 0xfda4af), .init(name: "Orange 300", hex: 0xfdba74),
        .init(name: "Amber 300", hex: 0xfcd34d), .init(name: "Emerald 300", hex: 0x6ee7b7),
        .init(name: "Sky 300", hex: 0x7dd3fc), .init(name: "Blue 300", hex: 0x93c5fd),
        .init(name: "Violet 300", hex: 0xc4b5fd),
        .init(name: "Rose 500", hex: 0xf43f5e), .init(name: "Orange 500", hex: 0xf97316),
        .init(name: "Amber 500", hex: 0xf59e0b), .init(name: "Emerald 500", hex: 0x10b981),
        .init(name: "Sky 500", hex: 0x0ea5e9), .init(name: "Blue 500", hex: 0x3b82f6),
        .init(name: "Violet 500", hex: 0x8b5cf6),
        .init(name: "Rose 800", hex: 0x9f1239), .init(name: "Orange 800", hex: 0x9a3412),
        .init(name: "Amber 800", hex: 0x92400e), .init(name: "Emerald 800", hex: 0x065f46),
        .init(name: "Sky 800", hex: 0x075985), .init(name: "Blue 800", hex: 0x1e40af),
        .init(name: "Violet 800", hex: 0x5b21b6)
    ]
}
