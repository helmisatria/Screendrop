import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppEntryCoordinator {
    static let shared = AppEntryCoordinator()
    private let editors = NSHashTable<NSWindow>.weakObjects()
    private weak var latestEditor: NSWindow?

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowClosed(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    func registerEditor(_ window: NSWindow?) {
        guard let window else { return }
        editors.add(window)
        if latestEditor == nil || window.isKeyWindow { latestEditor = window }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, editors.contains(window) else { return }
        latestEditor = window
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        editors.remove(window)
        if latestEditor === window { latestEditor = nil }
    }

    func show() {
        if ScreenRecordingManager.shared.isActive {
            ScreenRecordingManager.shared.showRecordingControls()
            return
        }
        if let editor = latestEditor ?? NSApp.orderedWindows.first(where: { editors.contains($0) }) ?? editors.allObjects.first {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            editor.deminiaturize(nil)
            editor.makeKeyAndOrderFront(nil)
            return
        }
        HomeWindowController.show()
    }
}

@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: HomeWindowController?
    static var openFile: ((URL) -> Void)?

    static func show() {
        RecordingProjectStore.shared.reload()
        ScreenshotHistoryStore.shared.reload()
        if shared == nil { shared = HomeWindowController() }
        guard let window = shared?.window else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() { shared?.close() }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "Screendrop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)
        window.minSize = NSSize(width: 640, height: 480)
        window.setFrameAutosaveName("ScreendropHome")
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ScreendropHomeView())
        PreviewWindowCaptureExclusion.shared.register(window: window)
        AppActivationPolicy.enter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.leave()
        Self.shared = nil
    }

    static func chooseFile() {
        guard let window = shared?.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            openFile?(url)
        }
    }
}

private struct HomeRecentItem: Identifiable {
    let id: URL
    let name: String
    let date: Date
    let symbol: String
    let detail: String
    let open: () -> Void
}

private struct HomeCardStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: BarMetrics.cornerRadius, style: .continuous)
        configuration.label
            .background {
                shape.fill(BarMetrics.hoverFill)
                    .opacity(isHovered || configuration.isPressed ? 1 : 0)
            }
            .compatibleGlassEffect(in: shape, interactive: true)
            .overlay {
                shape.strokeBorder(BarMetrics.edge, lineWidth: 0.5)
            }
            .onHover { isHovered = $0 }
    }
}

// Keep recency readable at a glance instead of displaying a running stopwatch.
func homeRelativeTime(since date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "Just now" }
    let units: [(seconds: Double, name: String)] = [
        (31_536_000, "year"), (2_592_000, "month"), (604_800, "week"),
        (86_400, "day"), (3_600, "hour"), (60, "minute")
    ]
    for unit in units where seconds >= unit.seconds {
        let count = Int(seconds / unit.seconds)
        return "\(count) \(unit.name)\(count == 1 ? "" : "s") ago"
    }
    return "Just now"
}

private struct ScreendropHomeView: View {
    @State private var projects = RecordingProjectStore.shared
    @State private var history = ScreenshotHistoryStore.shared

    private var recentItems: [HomeRecentItem] {
        let recordings = projects.projects.map { project in
            HomeRecentItem(
                id: project.id, name: project.displayName, date: project.lastActivityAt,
                symbol: "film", detail: project.hasUnsavedDraft ? "Recording · Draft saved" : "Recording",
                open: { RecordingProjectOpener.shared.open(project.session) }
            )
        }
        let captures = history.items.filter { $0.recordingSession == nil }.map { item in
            HomeRecentItem(
                id: item.url, name: item.fileName, date: item.updatedAt,
                symbol: item.isVideo ? "film" : "photo", detail: item.isVideo ? "Video" : "Screenshot",
                open: {
                    if item.isVideo {
                        PreviewPanelPresenter.shared.onEditVideo?(item.editorURL)
                    } else {
                        PreviewPanelPresenter.shared.onAnnotate?(item.url)
                    }
                }
            )
        }
        return Array((recordings + captures).sorted { $0.date > $1.date }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Screendrop").font(.title2.weight(.semibold))
                        Text("What would you like to create?").foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    Button { SettingsWindowController.show(tab: .general) } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17))
                            .frame(width: BarMetrics.controlSize, height: BarMetrics.controlSize)
                            .compatibleGlassEffect(interactive: true)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .accessibilityLabel("Settings")
                    .keyboardShortcut(",", modifiers: .command)
                }

                HStack(spacing: 12) {
                    action("Take Screenshot", symbol: "viewfinder", detail: "Select an area") {
                        HomeWindowController.close()
                        CaptureCoordinator.shared.captureArea()
                    }
                    action("Record Screen", symbol: "record.circle", detail: "Choose what to record") {
                        HomeWindowController.close()
                        RecordingPickerPresenter.shared.show()
                    }
                    action("Open File", symbol: "folder", detail: "Edit an image or video") {
                        HomeWindowController.chooseFile()
                    }
                }

                if let latest = recentItems.first {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Continue latest work").font(.headline)
                        recentRow(latest, prominent: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent work").font(.headline)
                        Spacer()
                        Button("All Recordings") { CaptureLibraryModel.shared.show(filter: .recordings) }
                        Button("All History") { CaptureLibraryModel.shared.show(filter: .all) }
                    }
                    if recentItems.isEmpty {
                        ContentUnavailableView(
                            "Your work starts here", systemImage: "photo.on.rectangle.angled",
                            description: Text("Take a screenshot, record your screen, or open a file. Your recent work will appear here.")
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(recentItems.dropFirst()) { item in
                            recentRow(item)
                        }
                        if recentItems.count == 1 {
                            Text("More captures will appear here as you create them.")
                                .font(.callout).foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .padding(28)
        }
        .foregroundStyle(BarMetrics.activeTint)
        .background(AnnotationEditorWorkspaceBackground())
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, symbol: String, detail: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(symbol == "record.circle" ? BarMetrics.recordTint : BarMetrics.activeTint)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .contentShape(RoundedRectangle(cornerRadius: BarMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(HomeCardStyle())
    }

    private func recentRow(_ item: HomeRecentItem, prominent: Bool = false) -> some View {
        Button(action: item.open) {
            HStack(spacing: 14) {
                Image(systemName: item.symbol)
                    .font(.system(size: 20, weight: .regular)).foregroundStyle(BarMetrics.activeTint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).fontWeight(.medium).lineLimit(1)
                    Text(item.detail).font(.caption).foregroundStyle(Color.secondary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(homeRelativeTime(since: item.date, now: context.date))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize()
                        .help("Last activity: " + item.date.formatted(date: .abbreviated, time: .shortened))
                }
                Image(systemName: "arrow.right").foregroundStyle(Color.secondary)
            }
            .padding(prominent ? 18 : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeCardStyle())
    }
}
