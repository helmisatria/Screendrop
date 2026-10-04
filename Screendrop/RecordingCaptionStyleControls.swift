import SwiftUI

struct RecordingCaptionStyleControls: View {
    @Bindable var model: RecordingStudioModel
    @State private var showsFonts = false
    @State private var search = ""
    @State private var pendingSelection: UUID?
    @State private var downloading: String?
    @State private var fontError: String?

    private var library: RecordingGoogleFonts { .shared }
    private var selectedFamily: RecordingFontFamily? {
        library.families.first { $0.family == model.subtitleStyle.googleFont?.family }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Caption Style").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Reset") {
                    pendingSelection = nil
                    downloading = nil
                    fontError = nil
                    var style = SubtitleBarStyle()
                    style.verticalPosition = model.subtitleStyle.verticalPosition
                    style.fontScale = model.subtitleStyle.fontScale
                    style.highlightsSpokenWord = model.subtitleStyle.highlightsSpokenWord
                    model.setSubtitleStyle(style)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button { showsFonts.toggle() } label: {
                HStack {
                    Text(model.subtitleStyle.googleFont?.family ?? "System Rounded")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                }.contentShape(Rectangle())
            }
            .popover(isPresented: $showsFonts) { fontPicker }

            if let font = model.subtitleStyle.googleFont {
                if let family = selectedFamily {
                    Picker("Style", selection: Binding(get: { font.variant }, set: { select(family, variant: $0) })) {
                        ForEach(family.variants, id: \.self) { variant in
                            Text(RecordingFontFamily.variantTitle(variant)).tag(variant)
                        }
                    }
                } else {
                    Text(RecordingFontFamily.variantTitle(font.variant)).foregroundStyle(.secondary)
                }
            }
            if let downloading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(downloading)…").lineLimit(2)
                }
            }
            if let fontError {
                Text(fontError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !library.isReady(model.subtitleStyle.googleFont) {
                Button("Retry font download") {
                    Task {
                        do { try await library.prepare(model.subtitleStyle.googleFont); fontError = nil }
                        catch { fontError = error.localizedDescription }
                    }
                }
            }
            CaptionColorPalettePicker(title: "Text", selection: colorBinding(\.textColor), defaultColor: SubtitleBarStyle().textColor)
            CaptionColorPalettePicker(title: "Background", selection: colorBinding(\.backgroundColor), defaultColor: SubtitleBarStyle().backgroundColor)
            CaptionColorPalettePicker(title: "Highlight text", selection: colorBinding(\.highlightColor), defaultColor: SubtitleBarStyle().highlightColor)
                .disabled(!model.subtitleStyle.highlightsSpokenWord)
            CaptionColorPalettePicker(title: "Highlight background", selection: colorBinding(\.highlightBackgroundColor), defaultColor: SubtitleBarStyle().highlightBackgroundColor)
                .disabled(!model.subtitleStyle.highlightsSpokenWord)
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }

    private var fontPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Google Fonts").font(.headline)
            TextField("Search fonts", text: $search).textFieldStyle(.roundedBorder)
            if library.isLoadingCatalog { ProgressView().controlSize(.small) }
            if let error = library.catalogError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await library.loadCatalog(force: true) } }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fontRow("System Rounded", selected: model.subtitleStyle.googleFont == nil) {
                        pendingSelection = nil
                        downloading = nil
                        fontError = nil
                        var style = model.subtitleStyle
                        style.googleFont = nil
                        model.setSubtitleStyle(style)
                        showsFonts = false
                    }
                    ForEach(library.families.filter { search.isEmpty || $0.family.localizedCaseInsensitiveContains(search) }) { family in
                        fontRow(family.family, selected: model.subtitleStyle.googleFont?.family == family.family) {
                            let variant = family.variants.contains("600") ? "600" :
                                (family.variants.contains("regular") ? "regular" : family.variants.first ?? "regular")
                            select(family, variant: variant)
                            showsFonts = false
                        }
                    }
                }
            }.frame(height: 310)
            Text("Fonts download when selected and stay available offline.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 310)
        .task { await library.loadCatalog() }
    }

    private func fontRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }.padding(.vertical, 7).padding(.horizontal, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func colorBinding(_ key: WritableKeyPath<SubtitleBarStyle, CaptionColor>) -> Binding<CaptionColor> {
        Binding(get: { model.subtitleStyle[keyPath: key] }, set: { color in
            var style = model.subtitleStyle
            style[keyPath: key] = color
            model.setSubtitleStyle(style)
        })
    }

    private func select(_ family: RecordingFontFamily, variant: String) {
        let token = UUID()
        pendingSelection = token
        downloading = family.family
        fontError = nil
        Task {
            do {
                let font = try await library.select(family, variant: variant)
                guard pendingSelection == token else { return }
                var style = model.subtitleStyle
                style.googleFont = font
                model.setSubtitleStyle(style)
            } catch {
                guard pendingSelection == token else { return }
                fontError = error.localizedDescription
            }
            if pendingSelection == token { downloading = nil; pendingSelection = nil }
        }
    }
}
