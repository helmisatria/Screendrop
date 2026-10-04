//
//  RecordingStudioWindow.swift
//  Screendrop
//
//  The recording studio: a Screen Studio-style editor for screen recordings.
//  Left/center is the composited live preview (background, padded rounded
//  card, zoom-follow-pointer, draggable camera bubble) over a timeline with
//  editable zoom cues; the trailing inspector uses the annotation
//  editor's design system.
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct RecordingStudioWindow: View {
    @Binding var url: URL?

    @State private var model: RecordingStudioModel?

    var body: some View {
        Group {
            if let model {
                RecordingStudioContent(model: model)
            } else {
                ProgressView()
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .modifier(CaptureLibraryEditorRegistration(url: url))
        .task(id: url) {
            guard let url else { return }
            model?.teardown()
            let newModel = RecordingStudioModel(url: url)
            model = newModel
            await newModel.load()
            guard !Task.isCancelled else {
                newModel.teardown()
                return
            }
            if model === newModel, newModel.isLoaded {
                ScreenshotPreviewStack.shared.dismissVideo(for: newModel.sessionURL)
            }
        }
        .onDisappear {
            model?.teardown()
            model = nil
        }
    }
}

private struct RecordingStudioContent: View {
    @Bindable var model: RecordingStudioModel
    @State private var features = FeatureSettings.shared
    @State private var isInspectorPresented = true
    @State private var closeGuard = EditorCloseGuard()

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = model.loadError {
                ContentUnavailableView(
                    "Couldn't open recording",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StudioCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AnnotationEditorWorkspaceBackground())

                StudioTimelineEditor(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .onChange(of: features.isEnabled(.captions)) { _, enabled in
            if !enabled { model.cancelTranscription() }
        }
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .inspector(isPresented: $isInspectorPresented) {
            StudioInspector(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isCroppingVideo {
                    videoCropActions
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            model.beginVideoCrop()
                        }
                    } label: {
                        Label("Crop", systemImage: "crop")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(!model.isLoaded || model.exportState.isExporting)
                    .help("Crop the finished video canvas")

                    if model.isProject {
                        saveStatus
                    }

                    if model.canShareToCloud {
                        shareStatus
                    }

                    exportStatus

                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                }
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onWindowChange { window in
            guard let window else {
                closeGuard.detach()
                return
            }
            configureCloseGuard()
            closeGuard.attach(to: window)
            closeGuard.refreshDocumentEdited()
            restoreKeyWindow(window)
        }
        .onChange(of: model.hasUnsavedChanges) {
            closeGuard.refreshDocumentEdited()
        }
        .onDeleteCommand {
            if let selectedCueID = model.selectedCueID {
                model.removeZoomCue(id: selectedCueID)
            } else if model.selectedAudioClipID != nil {
                model.deleteSelectedAudioClip()
            } else if model.selectedClipID != nil {
                model.deleteSelectedClip()
            }
        }
        .onAppear {
            AppActivationPolicy.enter(hidePreview: true)
        }
        .onDisappear {
            closeGuard.detach()
            AppActivationPolicy.leave(restorePreview: true)
        }
    }

    private var shareSuggestedTitle: String {
        model.projectDisplayName
    }

    @ViewBuilder
    private var videoCropActions: some View {
        Menu {
            Picker("Aspect Ratio", selection: videoCropAspectBinding) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.videoCropAspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .help("Crop aspect ratio")

        Button("Reset") {
            withAnimation(.snappy(duration: 0.18)) {
                model.resetVideoCrop()
            }
        }
        .help("Reset the selection to the whole video")

        Button("Cancel") {
            withAnimation(.snappy(duration: 0.22)) {
                model.cancelVideoCrop()
            }
        }
        .keyboardShortcut(.cancelAction)

        Button("Crop") {
            withAnimation(.snappy(duration: 0.22)) {
                model.applyVideoCrop()
            }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    }

    private var videoCropAspectBinding: Binding<CropAspectRatio> {
        Binding(
            get: { model.videoCropAspect },
            set: { aspect in
                withAnimation(.snappy(duration: 0.18)) {
                    model.setVideoCropAspect(aspect)
                }
            }
        )
    }

    /// AppKit already paints the unsaved dot in the close button; the title
    /// says it in words for anyone who reads the title bar first.
    private var windowTitle: String {
        let name = Self.friendlyTitle(for: model.projectDisplayName)
        return model.hasUnsavedChanges ? "\(name) - Edited" : name
    }

    /// Length of the edited cut and the source resolution.
    private var windowSubtitle: String {
        guard model.isLoaded else { return "" }
        let total = Int(model.duration.rounded())
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        let size = model.videoSize
        return "\(clock) · \(Int(size.width))×\(Int(size.height))"
    }

    /// Unrenamed recordings are named `Screendrop_<timestamp>_<id>` on disk;
    /// the title shows when it was recorded instead of the raw file name.
    private static func friendlyTitle(for name: String) -> String {
        let parts = name.split(separator: "_")
        guard parts.count >= 2, parts[0] == "Screendrop" else { return name }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: String(parts[1])) else { return name }
        return "Recording · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func configureCloseGuard() {
        closeGuard.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        closeGuard.offersDelete = { [weak model] in model?.hasNeverBeenSaved ?? false }
        closeGuard.projectName = { [weak model] in model?.projectDisplayName ?? "this recording" }
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return }
            switch decision {
            case .save:
                if model.saveProject() { done() }
            case .discard:
                Task {
                    await model.discardChanges()
                    done()
                }
            case .delete:
                model.deleteProject()
                done()
            case .cancel:
                break
            }
        }
    }

    private func restoreKeyWindow(_ window: NSWindow?) {
        guard let window else { return }

        // The app changes from a menu-bar accessory to a regular app while
        // Studio opens. Give macOS one run-loop pass to finish that change,
        // then make Studio key so popovers receive the active control state.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Save is a plain toolbar button rather than a menu command: Studio is
    /// reached from a menu-bar app, where the main menu isn't a reliable
    /// place to look for ⌘S.
    @ViewBuilder
    private var saveStatus: some View {
        Button {
            model.saveProject()
        } label: {
            if model.saveFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                // Icon-only: a greyed-out "Save" title read as broken
                // whenever there was nothing to save.
                Label("Save", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.hasUnsavedChanges)
        .help(model.hasUnsavedChanges ? "Save this project (⌘S)" : "All changes saved")
    }

    /// Share pipeline in one toolbar slot: render → upload → link copied.
    /// The upload leg reads the uploader's live progress so the pill keeps
    /// moving through both stages.
    @ViewBuilder
    private var shareStatus: some View {
        switch model.shareState {
        case .idle:
            CloudUploadButton(suggestedTitle: shareSuggestedTitle, onUpload: model.shareToCloud) {
                Label("Share", systemImage: "link")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.isLoaded || model.exportState.isExporting)
            .help("Upload this recording and copy the share link")
        case .rendering(let progress):
            SharePill(stage: "Rendering", progress: progress) {
                model.cancelShare()
            }
        case .uploading:
            SharePill(
                stage: "Uploading",
                progress: model.shareItemID.flatMap {
                    CloudUploader.shared.uploadProgress[$0]
                } ?? 0
            ) {
                model.cancelShare()
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Label("Link Copied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .help("Copy the share link again")

                if let shareURL = URL(string: url) {
                    Link(destination: shareURL) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .accessibilityLabel("Open Share Link")
                    .help("Open the share link in your browser")
                }

                CloudUploadButton(suggestedTitle: shareSuggestedTitle, onUpload: model.shareToCloud) {
                    Image(systemName: "link")
                }
                .help("Share Again")
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Share Failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help(message)

                CloudUploadButton(suggestedTitle: shareSuggestedTitle, onUpload: model.shareToCloud) {
                    Text("Retry")
                }
            }
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch model.exportState {
        case .idle:
            RecordingExportButton(
                currentSettings: model.exportSettings,
                onExport: model.export(settings:)
            ) {
                Label("Export", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(!model.isLoaded || model.shareState.isBusy)
        case .exporting(let progress):
            ExportProgressPill(progress: progress) {
                model.cancelExport()
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .help("Reveal exported recording in Finder")

                RecordingExportButton(
                    currentSettings: model.exportSettings,
                    onExport: model.export(settings:)
                ) {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Export Again")
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Export Failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help(message)

                RecordingExportButton(
                    currentSettings: model.exportSettings,
                    onExport: model.export(settings:)
                ) {
                    Text("Retry")
                }
            }
        }
    }
}

/// The determinate ring shared by every Studio progress affordance, so the
/// toolbar pills and the inspector's export button read as one control.
private struct StudioProgressRing: View {
    let progress: Double

    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.15), value: progress)
    }
}

/// Progress pill for the share pipeline: same ring treatment as the
/// export pill, with the stage name so render and upload read distinctly.
private struct SharePill: View {
    let stage: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StudioProgressRing(progress: progress)

            Text("\(stage) \(Int((progress * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize()
                .contentTransition(.numericText())

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel Share")
            .accessibilityLabel("Cancel Share")
        }
        .padding(.leading, 12)
    }
}

/// Single pill that replaces the old "Exporting…" button plus a separate
/// progress bar with one control: a ring showing percent complete, the
/// number itself, and a way to actually stop the export.
private struct ExportProgressPill: View {
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StudioProgressRing(progress: progress)

            Text("Exporting \(Int((progress * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize()
                .contentTransition(.numericText())

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel Export")
            .accessibilityLabel("Cancel Export")
        }
        .padding(.leading, 12)
    }
}

// MARK: - Canvas

private struct StudioCanvas: View {
    @Bindable var model: RecordingStudioModel

    /// A play/pause glyph that blooms in the middle of the canvas after a
    /// click toggles playback, then fades.
    private struct PlaybackFlash: Equatable {
        let id = UUID()
        let systemImage: String
    }

    @State private var playbackFlash: PlaybackFlash?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let available = CGSize(
                width: max(proxy.size.width - 68, 100),
                height: max(proxy.size.height - 56, 100)
            )
            let canvasSize = Self.aspectFit(model.previewCanvasSize, into: available)
            let cropEditingLayout = RecordingStudioLayout.make(
                canvasSize: canvasSize,
                style: model.style,
                includeBubble: model.hasCameraVideo,
                usesUniformPadding: model.exportAspect == .original,
                contentAspect: model.sourceVideoAspect,
                contentMode: .fit
            )

            ZStack(alignment: .topLeading) {
                StudioCanvasComposition(
                    model: model,
                    canvasSize: canvasSize,
                    isEditingVideoCrop: model.isCroppingVideo
                )
                // Clicking the picture plays or pauses, like a player.
                // The camera bubble and zoom target keep their own drags.
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded(togglePlayback),
                    including: model.isCroppingVideo ? .subviews : .all
                )

                if model.isCroppingVideo {
                    VideoCropOverlay(
                        model: model,
                        canvasSize: canvasSize,
                        videoFrame: cropEditingLayout.cardRect
                    )

                    CropResolutionBadge(size: model.videoCropPixelSize)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                } else if let skimTime {
                    StudioCanvasBadge(text: "Previewing \(studioPreciseTimecode(skimTime))")
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let playbackFlash {
                    StudioPlaybackFlashView(systemImage: playbackFlash.systemImage)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .id(playbackFlash.id)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .coordinateSpace(name: VideoCropOverlay.coordinateSpaceName)
            .frame(width: canvasSize.width, height: canvasSize.height)
            // Square like the exported video, lifted off the workspace by a
            // hairline and a soft shadow instead of a rounded mask that also
            // clipped the camera bubble.
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(canvasEdge, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .background {
                Rectangle()
                    .fill(Color.black)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 14, y: 5)
            }
            .animation(.easeOut(duration: 0.15), value: skimTime == nil)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    /// The hovered timeline moment while the preview skims away from the
    /// playhead; nil when the canvas shows the playhead frame.
    private var skimTime: TimeInterval? {
        guard !model.isPlaying,
              let hover = model.hoverPreviewTime,
              abs(hover - model.currentTime) > 0.05 else { return nil }
        return hover
    }

    private var canvasEdge: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    private func togglePlayback() {
        guard model.isLoaded else { return }
        model.togglePlayback()
        let flash = PlaybackFlash(systemImage: model.isPlaying ? "play.fill" : "pause.fill")
        withAnimation(.easeOut(duration: 0.12)) {
            playbackFlash = flash
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard playbackFlash == flash else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                playbackFlash = nil
            }
        }
    }

    private static func aspectFit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Small dark capsule for transient canvas status.
private struct StudioCanvasBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.62)))
    }
}

private struct StudioPlaybackFlashView: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(Circle().fill(Color.black.opacity(0.5)))
    }
}

/// The complete canvas composition. A video crop changes only the screen card
/// layout and viewport; background, camera and captions remain in canvas space.
/// Original sizes that canvas to the visible source plus an equal border.
private struct StudioCanvasComposition: View {
    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    let isEditingVideoCrop: Bool

    var body: some View {
        let layout = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: model.style,
            includeBubble: model.hasCameraVideo,
            usesUniformPadding: model.exportAspect == .original,
            contentAspect: isEditingVideoCrop ? model.sourceVideoAspect : model.previewContentAspect,
            contentMode: isEditingVideoCrop ? .fit : model.previewContentMode,
            contentCropRect: isEditingVideoCrop ? CropRectEditor.unit : model.videoCropRect
        )

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.isPlaying)) { _ in
            let zoomTarget = zoomTargetCue
            // While a zoom's target is on show the frame stays unzoomed, so
            // the target reads against the whole picture.
            let state = isEditingVideoCrop || zoomTarget != nil
                ? ViewportFrame.identity
                : model.previewViewportFrame(at: model.displayTime)

            ZStack {
                StudioBackgroundView(style: model.style.background)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipped()

                StudioPlayerLayerView(player: model.screenPlayer, gravity: .resize)
                    .frame(
                        width: layout.contentFillSize.width,
                        height: layout.contentFillSize.height
                    )
                    .scaleEffect(state.magnification)
                    .offset(
                        x: (0.5 - state.anchor.x) * state.magnification * layout.contentFillSize.width,
                        y: (0.5 - state.anchor.y) * state.magnification * layout.contentFillSize.height
                    )
                    .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                    .overlay {
                        if let pointer = model.pointerFrame(at: model.displayTime) {
                            StudioCursorOverlay(
                                pointer: pointer,
                                artwork: model.artwork(id: pointer.artworkID),
                                state: state,
                                cardSize: layout.cardRect.size,
                                contentSize: layout.contentFillSize,
                                cursorScale: model.style.cursorScale,
                                showsClickEffect: model.showsPressEffects
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous))
                    .overlay {
                        if let caption = model.keystrokeCaption(at: model.displayTime) {
                            StudioKeystrokeCaptionView(
                                caption: caption,
                                placement: model.keystrokePlacement,
                                cardSize: layout.cardRect.size
                            )
                        }
                    }
                    .shadow(
                        color: .black.opacity(model.style.background == .none ? 0 : 0.55 * model.style.shadow),
                        radius: min(canvasSize.width, canvasSize.height) * 0.045 * model.style.shadow,
                        y: min(canvasSize.width, canvasSize.height) * 0.016 * model.style.shadow
                    )
                    .position(x: layout.cardRect.midX, y: layout.cardRect.midY)

                if model.isCameraVisible(at: model.displayTime), layout.bubbleRect.width > 0 {
                    StudioCameraBubble(model: model, layout: layout)
                }

                if let subtitle = model.subtitleText(at: model.displayTime) {
                    StudioSubtitleBarView(
                        text: subtitle,
                        karaokeLine: model.subtitleKaraokeLine(at: model.displayTime),
                        style: model.subtitleStyle,
                        canvasSize: canvasSize
                    )
                }

                if let zoomTarget {
                    StudioZoomTargetOverlay(
                        model: model,
                        cue: zoomTarget,
                        layout: layout,
                        canvasSize: canvasSize
                    )
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// The selected zoom, shown as a target on the paused canvas.
    private var zoomTargetCue: ZoomCue? {
        guard !isEditingVideoCrop,
              !model.isPlaying,
              model.zoomEnabled,
              let cue = model.selectedCue,
              cue.isEnabled else { return nil }
        return cue
    }
}

/// Where the selected zoom will look, drawn over the unzoomed frame with
/// everything outside it dimmed. Fixed zooms can be dragged to re-aim them;
/// pointer and smart zooms follow the pointer, so their target is shown at
/// the pointer's position under the playhead and can't be moved.
private struct StudioZoomTargetOverlay: View {
    @Bindable var model: RecordingStudioModel
    let cue: ZoomCue
    let layout: RecordingStudioLayout
    let canvasSize: CGSize

    @State private var dragStartPoint: CGPoint?
    @State private var isHovering = false

    private var isMovable: Bool {
        cue.anchorMode == .pinnedAnchor
    }

    private var target: CGPoint {
        if isMovable { return cue.pinnedPoint }
        return model.pointerLocation(at: model.displayTime) ?? CGPoint(x: 0.5, y: 0.5)
    }

    var body: some View {
        let card = layout.cardRect
        let content = layout.contentFillSize
        let magnification = max(CGFloat(cue.zoom), 1)
        let size = CGSize(width: card.width / magnification, height: card.height / magnification)
        let center = CGPoint(
            x: card.midX + content.width * (target.x - 0.5),
            y: card.midY + content.height * (target.y - 0.5)
        )
        let rect = CGRect(
            x: min(max(center.x - size.width / 2, card.minX), card.maxX - size.width),
            y: min(max(center.y - size.height / 2, card.minY), card.maxY - size.height),
            width: size.width,
            height: size.height
        )
        let isActive = isHovering || dragStartPoint != nil

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRoundedRect(
                    in: card,
                    cornerSize: CGSize(width: layout.cardCornerRadius, height: layout.cardCornerRadius),
                    style: .continuous
                )
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isActive ? 1 : 0.9),
                    style: StrokeStyle(lineWidth: isActive ? 2.5 : 2, dash: isMovable ? [] : [6, 4])
                )
                .background(Color.white.opacity(0.001))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .overlay(alignment: .topLeading) {
                    StudioCanvasBadge(
                        text: isMovable
                            ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: magnification)
                            : "Follows pointer"
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                }
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 && isMovable }
                .pointerStyle(isMovable ? (dragStartPoint == nil ? PointerStyle.grabIdle : .grabActive) : nil)
                .onTapGesture {}
                .gesture(moveGesture(contentSize: content), including: isMovable ? .all : .none)
                .help(isMovable ? "Drag to aim this zoom" : "Switch Camera Focus to Fixed to aim this zoom by hand")
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func moveGesture(contentSize: CGSize) -> some Gesture {
        // Global coordinates: the target moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStartPoint == nil {
                    dragStartPoint = cue.pinnedPoint
                    model.beginZoomCueEdit()
                }
                guard let start = dragStartPoint,
                      contentSize.width > 0,
                      contentSize.height > 0 else { return }
                var updated = cue
                updated.pinnedPoint = CGPoint(
                    x: min(max(start.x + value.translation.width / contentSize.width, 0), 1),
                    y: min(max(start.y + value.translation.height / contentSize.height, 0), 1)
                )
                model.updateZoomCue(updated)
            }
            .onEnded { _ in
                dragStartPoint = nil
                model.endZoomCueEdit(actionName: "Aim Zoom")
            }
    }
}

private struct VideoCropOverlay: View {
    static let coordinateSpaceName = "VideoCropSpace"

    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    /// The uncropped screen-video card inside the surrounding canvas.
    let videoFrame: CGRect
    @State private var moveStartCrop: CGRect?

    private var cropViewRect: CGRect {
        let crop = model.workingVideoCropRect.standardized
        return CGRect(
            x: videoFrame.minX + crop.minX * videoFrame.width,
            y: videoFrame.minY + crop.minY * videoFrame.height,
            width: crop.width * videoFrame.width,
            height: crop.height * videoFrame.height
        )
    }

    private var visibleHandles: [CropHandle] {
        model.videoCropAspect.locksAspect
            ? CropHandle.allCases.filter(\.isCorner)
            : CropHandle.allCases
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(videoFrame)
                path.addRect(cropViewRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for index in 1...2 {
                    let x = cropViewRect.minX + cropViewRect.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: cropViewRect.minY))
                    path.addLine(to: CGPoint(x: x, y: cropViewRect.maxY))
                    let y = cropViewRect.minY + cropViewRect.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: cropViewRect.minX, y: y))
                    path.addLine(to: CGPoint(x: cropViewRect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: cropViewRect.width, height: cropViewRect.height)
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .shadow(color: .black.opacity(0.3), radius: 1)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(cropViewRect.width, 1), height: max(cropViewRect.height, 1))
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .gesture(moveGesture)

            ForEach(visibleHandles, id: \.self) { handle in
                VideoCropHandleView(handle: handle)
                    .position(handlePoint(handle))
                    .gesture(handleGesture(handle))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                let start = moveStartCrop ?? model.workingVideoCropRect.standardized
                if moveStartCrop == nil { moveStartCrop = start }
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.moveVideoCrop(
                    from: start,
                    byNormalized: CGSize(
                        width: value.translation.width / videoFrame.width,
                        height: value.translation.height / videoFrame.height
                    )
                )
            }
            .onEnded { _ in moveStartCrop = nil }
    }

    private func handleGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.updateVideoCrop(
                    handle: handle,
                    toNormalized: CGPoint(
                        x: (value.location.x - videoFrame.minX) / videoFrame.width,
                        y: (value.location.y - videoFrame.minY) / videoFrame.height
                    )
                )
            }
    }

    private func handlePoint(_ handle: CropHandle) -> CGPoint {
        let unit = handle.unitPoint
        return CGPoint(
            x: cropViewRect.minX + cropViewRect.width * unit.x,
            y: cropViewRect.minY + cropViewRect.height * unit.y
        )
    }
}

private struct VideoCropHandleView: View {
    let handle: CropHandle

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())

            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            } else {
                let isHorizontal = handle == .top || handle == .bottom
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                    .frame(width: isHorizontal ? 26 : 7, height: isHorizontal ? 7 : 26)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            }
        }
    }
}

/// Recorded pointer artwork, placed through the same viewport transform the
/// video card uses (see RecordingPointerTimeline for why it is reconstructed).
private struct StudioCursorOverlay: View {
    let pointer: PointerFrame
    let artwork: PointerArtwork?
    let state: ViewportFrame
    let cardSize: CGSize
    /// The video's draw size at magnification 1 - equal to the card
    /// normally, larger when a reframe aspect-fills it.
    var contentSize: CGSize?
    let cursorScale: CGFloat
    let showsClickEffect: Bool

    var body: some View {
        let content = contentSize ?? cardSize
        let tip = CGPoint(
            x: cardSize.width / 2 + content.width * state.magnification * (pointer.location.x - state.anchor.x),
            y: cardSize.height / 2 + content.height * state.magnification * (pointer.location.y - state.anchor.y)
        )

        ZStack(alignment: .topLeading) {
            if showsClickEffect, let press = pointer.press {
                let pressTip = CGPoint(
                    x: cardSize.width / 2
                        + content.width * state.magnification * (press.location.x - state.anchor.x),
                    y: cardSize.height / 2
                        + content.height * state.magnification * (press.location.y - state.anchor.y)
                )
                let effect = PointerPressEffectStyle.geometry(
                    progress: press.progress,
                    referenceHeight: content.height,
                    cursorScale: cursorScale
                )
                let accent = PointerPressEffectStyle.color
                Circle()
                    .fill(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.impactOpacity)
                    )
                    .frame(width: effect.impactRadius * 2, height: effect.impactRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
                Circle()
                    .stroke(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.rippleOpacity),
                        lineWidth: effect.rippleLineWidth
                    )
                    .frame(width: effect.rippleRadius * 2, height: effect.rippleRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
            }

            if let artwork,
               let image = StudioCursorImageCache.image(for: artwork) {
                let anchor = artwork.normalizedAnchor
                let height = content.height
                    * PointerArtworkMetrics.heightRatio
                    * cursorScale
                    * artwork.intrinsicScale
                let size = CGSize(
                    width: height * artwork.aspectRatio,
                    height: height
                )
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(
                        CGFloat(pointer.magnification),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .rotationEffect(
                        .degrees(pointer.tiltDegrees),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .position(
                        x: tip.x + (0.5 - anchor.x) * size.width,
                        y: tip.y + (0.5 - anchor.y) * size.height
                    )
                    .opacity(pointer.opacity)
                    .blur(radius: CGFloat(pointer.blurRadius))
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
    }
}

/// The keystroke caption pill: one rounded container with the chord's
/// modifiers and key. Geometry comes from KeystrokeCaptionMetrics so the
/// exporter draws the identical pill.
private struct StudioKeystrokeCaptionView: View {
    let caption: KeystrokeCaptionFrame
    let placement: RecordingKeystrokePlacement
    let cardSize: CGSize

    var body: some View {
        let metrics = KeystrokeCaptionMetrics(cardHeight: cardSize.height)
        let (modifiers, key) = KeystrokeCaptionMetrics.text(for: caption)

        (Text(modifiers).foregroundStyle(.white.opacity(KeystrokeCaptionMetrics.modifierAlpha))
            + Text(key).foregroundStyle(.white))
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, metrics.paddingHorizontal)
            .padding(.vertical, metrics.paddingVertical)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(KeystrokeCaptionMetrics.backgroundAlpha))
            )
            .scaleEffect(caption.scale)
            .opacity(caption.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
            .padding(metrics.margin)
            .frame(width: cardSize.width, height: cardSize.height)
            .allowsHitTesting(false)
    }
}

/// Uses the same Core Text layout and drawing as the exported video.
private struct StudioSubtitleBarView: View {
    let text: String
    var karaokeLine: KaraokeTimeline.Line?
    let style: SubtitleBarStyle
    let canvasSize: CGSize
    @State private var fontError: String?

    var body: some View {
        let ready = RecordingGoogleFonts.shared.isReady(style.googleFont)
        Canvas { graphics, size in
            guard ready else { return }
            graphics.withCGContext { context in
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                RecordingCaptionRenderer.draw(text: text, karaoke: karaokeLine, style: style,
                                              canvasSize: size, in: context)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .overlay(alignment: .bottom) {
            if !ready {
                Text(fontError ?? "Loading caption font…")
                    .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
            }
        }
        .allowsHitTesting(false)
        .task(id: style.googleFont) {
            fontError = nil
            do { try await RecordingGoogleFonts.shared.prepare(style.googleFont) }
            catch { fontError = "Caption font unavailable. Retry in Caption Style." }
        }
    }
}

/// One editable subtitle line: a timestamp plus the cue text as a free-form
/// field. Hovering a row skims the preview to that cue, clicking or editing
/// commits the playhead there (paused), and the row under the playhead is
/// highlighted so the list follows the video.
private struct StudioSubtitleRow: View {
    @Bindable var model: RecordingStudioModel
    let cue: RecordingSubtitleCue
    let isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.seekToSubtitle(cue)
            } label: {
                Text(timestamp ?? "–:––")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(editorTime == nil)
            .help(editorTime == nil ? "This subtitle's audio was cut out" : "Jump to this subtitle")

            RecordingCaptionTextEditor(model: model, cue: cue)
                .alignmentGuide(.firstTextBaseline) { _ in 11 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .opacity(editorTime == nil ? 0.5 : 1)
        .onTapGesture {
            model.seekToSubtitle(cue)
        }
        .onHover { hovering in
            // Hover skims the paused preview like the timeline strip does;
            // leaving hands the frame back to the real playhead.
            guard !model.isPlaying, let editorTime else { return }
            if hovering {
                model.hoverPreviewTime = editorTime
            } else if model.hoverPreviewTime == editorTime {
                model.hoverPreviewTime = nil
            }
        }
    }

    /// Where this cue lands on the edited timeline; nil when its audio was
    /// cut out entirely.
    private var editorTime: TimeInterval? {
        model.editorTime(forSourceTime: cue.start)
            ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2)
    }

    private var timestamp: String? {
        guard let editorTime else { return nil }
        let total = max(0, Int(editorTime.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Descript-style transcript editing: the narration as flowing words.
/// Clicking a word jumps the playhead there, shift-clicking selects a
/// passage, and cutting the selection removes that stretch of the video.
/// Words whose footage is already cut render struck-through; filler words
/// carry a dotted underline so the bulk action's targets are visible.
private struct StudioTranscriptEditPanel: View {
    @Bindable var model: RecordingStudioModel

    @State private var selection: ClosedRange<Int>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    transcriptFlow
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
                        .fill(InspectorControlPalette.trackFill(for: colorScheme))
                )
                .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous))
                .onChange(of: model.activeTranscriptWordIndex) { _, activeIndex in
                    // Follow playback through the transcript, but never yank
                    // it around while the user is selecting a passage.
                    guard let activeIndex, model.isPlaying, selection == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }

            if let selection {
                cutSelectionRow(selection)
            }
        }
        .onDeleteCommand(perform: cutSelection)
        .onExitCommand { selection = nil }
    }

    private var transcriptFlow: some View {
        let activeIndex = model.activeTranscriptWordIndex
        return TranscriptFlowLayout() {
            ForEach(model.transcriptWords.indices, id: \.self) { index in
                StudioTranscriptWordView(
                    text: model.transcriptWords[index].displayText,
                    isSelected: selection?.contains(index) ?? false,
                    isActive: index == activeIndex,
                    isCut: !model.transcriptWordSurvives(index),
                    isFiller: model.isFillerWord(index)
                ) {
                    handleTap(on: index)
                }
                .id(index)
            }
        }
    }

    private func cutSelectionRow(_ selection: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            InspectorActionButton(
                selection.count == 1 ? "Cut Word" : "Cut \(selection.count) Words",
                systemImage: "scissors",
                role: .destructive,
                action: cutSelection
            )

            InspectorClearButton(help: "Clear selection") {
                self.selection = nil
            }
        }
    }

    private func handleTap(on index: Int) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld, let selection {
            self.selection = min(selection.lowerBound, index)...max(selection.upperBound, index)
        } else {
            selection = index...index
            model.seekToTranscriptWord(at: index)
        }
    }

    private func cutSelection() {
        guard let selection else { return }
        model.cutTranscriptWords(in: selection)
        self.selection = nil
    }
}

/// One word in the transcript editor, drawn so the flow reads as a plain
/// paragraph: the chip's side padding doubles as the inter-word space
/// (layout spacing is zero), which also makes a multi-word selection's
/// highlight contiguous like real text selection. The font weight never
/// changes with state - a width change would reflow the whole paragraph
/// on every playback tick. Kept to plain stored values so ticks only
/// re-render the words whose state actually changed.
private struct StudioTranscriptWordView: View {
    let text: String
    let isSelected: Bool
    let isActive: Bool
    let isCut: Bool
    let isFiller: Bool
    let action: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(foreground)
            .strikethrough(isCut, color: .secondary.opacity(0.6))
            .padding(.horizontal, 1.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var foreground: Color {
        isCut ? Color.secondary.opacity(0.45) : Color.primary
    }

    private var background: Color {
        if isSelected {
            Color.accentColor.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Color.accentColor.opacity(0.2)
        } else if isFiller, !isCut {
            Color.orange.opacity(0.16)
        } else {
            Color.clear
        }
    }
}

/// Minimal left-aligned wrapping layout for the transcript's word chips.
/// Horizontal spacing lives inside the chips (see StudioTranscriptWordView),
/// so the layout only separates lines.
private struct TranscriptFlowLayout: Layout {
    var spacingX: CGFloat = 0
    var spacingY: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacingY
                rowHeight = 0
            }
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacingY
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension RecordingKeystrokePlacement {
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }
}

@MainActor
private enum StudioCursorImageCache {
    private static var capturedImages: [String: NSImage] = [:]

    static func image(for artwork: PointerArtwork) -> NSImage? {
        let cacheKey = "\(artwork.artworkID)-\(artwork.imageData.hashValue)"
        if let cached = capturedImages[cacheKey] {
            return cached
        }
        guard let image = NSImage(data: artwork.imageData) else { return nil }
        capturedImages[cacheKey] = image
        return image
    }
}

/// The draggable talking-head bubble. It snaps to the canvas corners, edge
/// midpoints and center lines (inside the same safe margin the layout keeps),
/// drawing a guide for each axis it has snapped on.
private struct StudioCameraBubble: View {
    @Bindable var model: RecordingStudioModel
    let layout: RecordingStudioLayout

    private static let snapDistance: CGFloat = 8
    private static let hoverRingPadding: CGFloat = 3

    private struct SnapGuides: Equatable {
        var x: CGFloat?
        var y: CGFloat?
    }

    /// Bubble center in canvas points when the drag began.
    @State private var dragStartCenter: CGPoint?
    @State private var guides = SnapGuides()
    @State private var isHovering = false

    var body: some View {
        let rect = layout.bubbleRect
        let canvas = layout.canvasSize
        let isActive = isHovering || dragStartCenter != nil

        ZStack(alignment: .topLeading) {
            guideLines(in: canvas)

            StudioPlayerLayerView(player: model.cameraPlayer, gravity: .resizeAspectFill)
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                }
                .overlay {
                    if isActive {
                        // Nested radius: the ring sits `hoverRingPadding` outside.
                        RoundedRectangle(
                            cornerRadius: layout.bubbleCornerRadius + Self.hoverRingPadding,
                            style: .continuous
                        )
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-Self.hoverRingPadding)
                        .allowsHitTesting(false)
                    }
                }
                .shadow(
                    color: .black.opacity(0.35),
                    radius: min(canvas.width, canvas.height) * 0.022,
                    y: min(canvas.width, canvas.height) * 0.009
                )
                .contentShape(RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous))
                .onHover { isHovering = $0 }
                .pointerStyle(dragStartCenter == nil ? PointerStyle.grabIdle : .grabActive)
                // Swallow clicks so they don't toggle playback underneath.
                .onTapGesture {}
                .gesture(dragGesture(rect: rect, canvas: canvas))
                .help("Drag to place the camera")
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func guideLines(in canvas: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let x = guides.x {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1, height: canvas.height)
                    .offset(x: x - 0.5)
            }
            if let y = guides.y {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: canvas.width, height: 1)
                    .offset(y: y - 0.5)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func dragGesture(rect: CGRect, canvas: CGSize) -> some Gesture {
        // Global coordinates: the bubble moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStartCenter == nil {
                    // Start from where the bubble is drawn, not the stored
                    // center, which the layout may have clamped.
                    dragStartCenter = CGPoint(x: rect.midX, y: rect.midY)
                }
                guard let start = dragStartCenter, canvas.width > 0, canvas.height > 0 else { return }
                let proposed = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                let margin = RecordingStudioLayout.bubbleMargin(
                    forMinDimension: min(canvas.width, canvas.height)
                )
                let (snappedX, guideX) = Self.snap(
                    proposed.x,
                    radius: rect.width / 2,
                    length: canvas.width,
                    margin: margin
                )
                let (snappedY, guideY) = Self.snap(
                    proposed.y,
                    radius: rect.height / 2,
                    length: canvas.height,
                    margin: margin
                )
                guides = SnapGuides(x: guideX, y: guideY)
                model.style.camera.center = CGPoint(
                    x: min(max(snappedX / canvas.width, 0), 1),
                    y: min(max(snappedY / canvas.height, 0), 1)
                )
            }
            .onEnded { _ in
                dragStartCenter = nil
                withAnimation(.easeOut(duration: 0.15)) {
                    guides = SnapGuides()
                }
            }
    }

    /// Snaps one axis of the bubble center to the near edge, the middle, or
    /// the far edge. Returns the snapped center and where to draw the guide.
    private static func snap(
        _ center: CGFloat,
        radius: CGFloat,
        length: CGFloat,
        margin: CGFloat
    ) -> (CGFloat, CGFloat?) {
        let targets: [(center: CGFloat, guide: CGFloat)] = [
            (margin + radius, margin),
            (length / 2, length / 2),
            (length - margin - radius, length - margin)
        ]
        guard let nearest = targets.min(by: { abs($0.center - center) < abs($1.center - center) }),
              abs(nearest.center - center) <= snapDistance else {
            return (center, nil)
        }
        return (nearest.center, nearest.guide)
    }
}

/// Renders an AnnotationBackgroundStyle as a live SwiftUI layer.
private struct StudioBackgroundView: View {
    let style: AnnotationBackgroundStyle

    var body: some View {
        switch style {
        case .none:
            Color(white: 0.04)
        case .solid(let color):
            color.color
        case .gradient(let gradient):
            LinearGradient(
                colors: gradient.colors.map(\.color),
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint
            )
        case .customWallpaper(let wallpaper):
            if let image = NSImage(contentsOf: wallpaper.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.04)
            }
        }
    }
}

/// AVPlayerLayer host for the preview canvas.
private struct StudioPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> StudioPlayerContainerView {
        let view = StudioPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: StudioPlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
    }
}

final class StudioPlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Timeline

private struct StudioTimelineEditor: View {
    private struct TimelinePosition {
        let editorTime: TimeInterval
        let displayTime: TimeInterval
    }

    @Bindable var model: RecordingStudioModel

    /// Horizontal scale of the lanes, as a multiplier over "the whole
    /// recording fits the viewport". Zoom 1 is the timeline's original
    /// fixed-width layout; anything above it scrolls.
    @State private var zoom: Double = 1
    @State private var viewportWidth: CGFloat = 1
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var trimDisplayTimeline: RecordingClipTimeline?
    @State private var rulerHoverDisplayTime: TimeInterval?
    @State private var isResetClipsConfirmationPresented = false

    /// Step per zoom button press / keyboard shortcut.
    private static let zoomStep: Double = 1.6
    /// How close to the viewport edge the playhead may drift before the
    /// lanes scroll to keep it in sight.
    private static let followMargin: CGFloat = 48

    private var scale: StudioTimelineScale {
        StudioTimelineScale(
            viewportWidth: viewportWidth,
            duration: displayTimeline.duration,
            zoom: zoom
        )
    }

    private var displayTimeline: RecordingClipTimeline {
        trimDisplayTimeline ?? model.displayClipTimeline
    }

    private var displayPlayheadTime: TimeInterval {
        if model.trimPreviewSourceTime == nil, model.currentTime >= model.duration {
            return displayTimeline.duration
        }
        let sourceTime = model.trimPreviewSourceTime ?? model.clipTimeline.sourceTime(at: model.currentTime)
        return displayTimeline.editorTime(forSourceTime: sourceTime) ?? model.currentTime
    }

    private var displayHoverTime: TimeInterval? {
        if let rulerHoverDisplayTime {
            return rulerHoverDisplayTime
        }
        guard let hoverTime = model.timelineHoverTime else { return nil }
        let sourceTime = model.clipTimeline.sourceTime(at: hoverTime)
        return displayTimeline.editorTime(forSourceTime: sourceTime) ?? hoverTime
    }

    var body: some View {
        VStack(spacing: StudioTimelineMetrics.rowSpacing) {
            transport
            if !model.skippedClips.isEmpty {
                HStack {
                    Text("Original: \(studioPreciseTimecode(model.sourceDuration)) · Output: \(studioPreciseTimecode(model.duration))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if model.selectedClipIsSkipped {
                        Button(model.isPreviewingSkippedClip ? "Stop Preview" : "Preview Skipped Section") {
                            if model.isPreviewingSkippedClip { model.endTrimPreview() }
                            else { model.previewSelectedSkippedClip() }
                        }
                        Button("Restore Clip") { model.deleteSelectedClip() }
                    }
                    Text("Delete toggles skip / restore")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            lanes
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }

    private var lanes: some View {
        GeometryReader { proxy in
            // The proxy width leads the stored one by a frame, so lay the
            // lanes out from it and keep the state copy for the controls.
            let scale = StudioTimelineScale(
                viewportWidth: max(proxy.size.width, 1),
                duration: displayTimeline.duration,
                zoom: zoom
            )

            VStack(spacing: 0) {
                StudioTimelineRuler(
                    duration: displayTimeline.duration,
                    pointsPerSecond: scale.pointsPerSecond,
                    scrollX: scrollX,
                    onHover: { time in
                        updateTimelineHover(atDisplayTime: time)
                    },
                    onScrub: { time in
                        model.pause()
                        model.seek(to: editorTime(forDisplayTime: time))
                    }
                )
                .frame(height: StudioTimelineMetrics.rulerInteractionHeight)
                .background {
                    StudioTimelineZoomEventMonitor { factor, viewportX in
                        let anchorTime = scale.time(forX: viewportX + scrollX)
                        applyZoom(factor: factor, anchorTime: anchorTime)
                    }
                }

                scrollingLanes(scale: scale)
            }
            .overlay {
                ZStack {
                    if let displayHoverTime {
                        StudioTimelineHoverIndicator(
                            time: displayHoverTime,
                            scale: scale,
                            scrollX: scrollX
                        )
                    }

                    StudioTimelinePlayhead(
                        time: displayPlayheadTime,
                        scale: scale,
                        scrollX: scrollX
                    )
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                viewportWidth = max(width, 1)
                clampZoom()
            }
        }
        .frame(height: StudioTimelineMetrics.lanesHeight(audioTrackCount: model.recordedAudioTracks.count))
        .onChange(of: displayTimeline.duration) { _, _ in clampZoom() }
        .onChange(of: model.currentTime) { _, _ in followPlayhead() }
    }

    /// The lanes that carry real edit targets live in a horizontal scroll
    /// view sized to the zoomed timeline. The ruler, playhead and lane chrome
    /// stay viewport-sized and redraw against `scrollX` instead - a rounded
    /// rectangle or Canvas tens of thousands of points wide would be a single
    /// oversized layer, while an AppKit view only ever draws its visible rect.
    private func scrollingLanes(scale: StudioTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.clipLaneHeight)
                StudioZoomLaneBackground(
                    showsHint: model.zoomEnabled && model.zoomTimelineBlocks.isEmpty
                )
                    .frame(height: StudioTimelineMetrics.zoomLaneHeight)
                ForEach(model.recordedAudioTracks) { track in
                    StudioAudioWaveformLane(
                        track: track,
                        clips: model.audioTrackEdits.first { $0.kind == track.kind }?.clips ?? [],
                        pointsPerSecond: scale.pointsPerSecond,
                        scrollX: scrollX,
                        gainDB: model.audioGainDB(for: track.kind),
                        isSelected: model.selectedAudioTrackKind == track.kind,
                        selectedClipID: model.selectedAudioTrackKind == track.kind
                            ? model.selectedAudioClipID
                            : nil,
                        isInactive: model.replacementAudio != nil,
                        onZoom: { factor, viewportX in
                            let anchorTime = scale.time(forX: viewportX + scrollX)
                            applyZoom(factor: factor, anchorTime: anchorTime)
                        }
                    )
                    .frame(height: StudioTimelineMetrics.audioLaneHeight)
                }
                Color.clear
                    .frame(height: StudioTimelineMetrics.scrollerGutter)
            }

            ScrollView(.horizontal) {
                VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                    clipLane
                        .frame(
                            width: scale.contentWidth,
                            height: StudioTimelineMetrics.clipLaneHeight
                        )

                    StudioZoomLane(
                        model: model,
                        scale: scale,
                        visibleRange: scale.visibleRange(scrollX: scrollX),
                        onZoom: { factor, anchorTime in
                            applyZoom(factor: factor, anchorTime: anchorTime)
                        }
                    )
                    .frame(
                        width: scale.contentWidth,
                        height: StudioTimelineMetrics.zoomLaneHeight
                    )

                    ForEach(model.recordedAudioTracks) { track in
                        RecordingAudioClipTimelineView(
                            trackKind: track.kind,
                            clips: model.audioTrackEdits.first { $0.kind == track.kind }?.clips ?? [],
                            selectedClipID: model.selectedAudioTrackKind == track.kind
                                ? model.selectedAudioClipID
                                : nil,
                            timelineDuration: model.displayClipTimeline.duration,
                            pointsPerSecond: scale.pointsPerSecond,
                            isInactive: model.replacementAudio != nil,
                            onSelectClip: { id in
                                model.selectAudioClip(id, in: track.kind)
                            },
                            onBeginEdit: {
                                model.beginAudioClipEdit()
                            },
                            onMove: { start in
                                model.moveSelectedAudioClip(
                                    to: start,
                                    snapThreshold: 8 / Double(scale.pointsPerSecond)
                                )
                            },
                            onTrimLeading: { start in
                                model.trimSelectedAudioClipLeadingEdge(
                                    to: start,
                                    snapThreshold: 8 / Double(scale.pointsPerSecond)
                                )
                            },
                            onTrimTrailing: { end in
                                model.trimSelectedAudioClipTrailingEdge(
                                    to: end,
                                    snapThreshold: 8 / Double(scale.pointsPerSecond)
                                )
                            },
                            onEndEdit: { actionName in
                                model.endAudioClipEdit(actionName: actionName)
                            },
                            onSelectTrack: {
                                model.selectAudioTrack(track.kind)
                            }
                        )
                            .frame(
                                width: scale.contentWidth,
                                height: StudioTimelineMetrics.audioLaneHeight
                            )
                    }

                    Color.clear
                        .frame(height: StudioTimelineMetrics.scrollerGutter)
                }
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(scale.isScrollable ? .visible : .never)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                if abs(offset - scrollX) > 0.01 {
                    scrollX = offset
                }
            }
        }
        .frame(
            height: StudioTimelineMetrics.scrollingLanesHeight(
                audioTrackCount: model.recordedAudioTracks.count
            )
        )
    }

    private var clipLane: some View {
        RecordingClipTimelineView(
            selectedClipID: $model.selectedClipID,
            playheadTime: model.displayTime(forOutputTime: model.currentTime),
            timeline: model.displayClipTimeline,
            skippedClipIDs: model.skippedClipIDs,
            sourceDuration: model.sourceDuration,
            thumbnails: model.timelineThumbnails,
            onSelect: { model.selectClip(id: $0) },
            onHover: { time in
                updateTimelineHover(atEditorTime: time.map { model.outputTime(forDisplayTime: $0) })
            },
            onSplit: { time in
                guard let location = model.displayClipTimeline.location(at: time),
                      !model.skippedClipIDs.contains(location.segmentID) else { return }
                model.splitClip(at: model.outputTime(forDisplayTime: time))
            },
            onDelete: { deleteSelection() },
            onTrim: { model.trimClip($0) },
            onDisplayTimelineChange: { timeline in
                trimDisplayTimeline = timeline
            },
            onZoom: { factor, anchorTime in
                applyZoom(factor: factor, anchorTime: anchorTime)
            },
            onStep: { seconds in
                model.pause()
                model.seek(to: model.currentTime + seconds)
            }
        )
    }

    // MARK: Zoom & scroll

    /// Rescales around `anchorTime`, keeping that moment under the same
    /// screen position so pinching or ⌘-scrolling doesn't shove the edit
    /// you were aiming at out of the viewport.
    private func applyZoom(factor: Double, anchorTime: TimeInterval?) {
        let current = scale
        guard current.duration > 0, factor.isFinite, factor > 0 else { return }
        let anchor = anchorTime ?? current.time(forX: scrollX + viewportWidth / 2)
        let anchorViewportX = current.x(for: anchor) - scrollX
        let next = min(max(zoom * factor, 1), current.maxZoom)
        guard abs(next - zoom) > 0.0001 else { return }

        // A pinch arrives as dozens of small steps; let the storyboard scale
        // with the lane and resample once the gesture settles.
        model.timelineThumbnails.deferSampling()
        zoom = next
        var zoomed = current
        zoomed.zoom = next
        scroll(to: zoomed.x(for: anchor) - anchorViewportX, in: zoomed)
    }

    private func fitTimeline() {
        guard zoom > 1 else { return }
        zoom = 1
        scrollX = 0
        scrollPosition.scrollTo(edge: .leading)
    }

    /// Keeps the zoom inside range after the viewport or the edited duration
    /// changes - a cut or a wider window can leave the old scale past the cap.
    private func clampZoom() {
        let clamped = min(max(zoom, 1), scale.maxZoom)
        if abs(clamped - zoom) > 0.0001 {
            zoom = clamped
        }
    }

    private func followPlayhead() {
        let current = scale
        guard current.isScrollable else { return }
        let x = current.x(for: displayPlayheadTime)
        guard x < scrollX + Self.followMargin
            || x > scrollX + viewportWidth - Self.followMargin else { return }
        // While playing, land the playhead a third in so there is room to
        // watch what is coming; a seek just centers it.
        let inset = model.isPlaying ? viewportWidth / 3 : viewportWidth / 2
        scroll(to: x - inset, in: current)
    }

    private func scroll(to x: CGFloat, in scale: StudioTimelineScale) {
        let clamped = min(max(x, 0), max(0, scale.contentWidth - scale.viewportWidth))
        scrollX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    /// Zoom buttons keep the playhead pinned when it is on screen, so the
    /// scale grows around the edit point rather than the viewport middle.
    private var buttonZoomAnchor: TimeInterval {
        let x = scale.x(for: displayPlayheadTime)
        if x >= scrollX, x <= scrollX + viewportWidth {
            return displayPlayheadTime
        }
        return scale.time(forX: scrollX + viewportWidth / 2)
    }

    private func editorTime(forDisplayTime time: TimeInterval) -> TimeInterval {
        timelinePosition(forDisplayTime: time).editorTime
    }

    private func timelinePosition(
        forDisplayTime time: TimeInterval
    ) -> TimelinePosition {
        guard let trimDisplayTimeline else {
            return TimelinePosition(editorTime: model.outputTime(forDisplayTime: time), displayTime: time)
        }
        let displayTime = min(max(time, 0), trimDisplayTimeline.duration)
        guard let displayLocation = trimDisplayTimeline.location(at: displayTime) else {
            return TimelinePosition(editorTime: 0, displayTime: 0)
        }

        if let exactTime = model.clipTimeline.editorTime(
            forSourceTime: displayLocation.sourceTime
        ) {
            return TimelinePosition(editorTime: exactTime, displayTime: displayTime)
        }

        // The revealed timeline includes the discarded part of a trimmed
        // clip. Keep hover and scrub pinned to the nearest kept edge instead
        // of reinterpreting the revealed timestamp inside the shorter edit.
        guard let keptClip = model.clipTimeline.segments.first(where: {
            $0.id == displayLocation.segmentID
        }), let keptRange = model.clipTimeline.editorRange(for: keptClip.id) else {
            if model.skippedClipIDs.contains(displayLocation.segmentID) {
                let next = model.clipTimeline.segments.first { $0.sourceStart >= displayLocation.sourceTime }
                let outputTime = next.flatMap { model.clipTimeline.editorRange(for: $0.id)?.lowerBound } ?? model.duration
                return TimelinePosition(editorTime: outputTime, displayTime: displayTime)
            }
            let firstSourceStart = model.clipTimeline.segments.first?.sourceStart ?? 0
            if displayLocation.sourceTime <= firstSourceStart {
                return TimelinePosition(editorTime: 0, displayTime: 0)
            }
            return TimelinePosition(
                editorTime: model.duration,
                displayTime: trimDisplayTimeline.duration
            )
        }

        let isBeforeKeptRange = displayLocation.sourceTime < keptClip.sourceStart
        if isBeforeKeptRange {
            let displayBoundary = trimDisplayTimeline.editorTime(
                forSourceTime: keptClip.sourceStart
            ) ?? displayTime
            return TimelinePosition(
                editorTime: keptRange.lowerBound,
                displayTime: displayBoundary
            )
        }

        let displayBoundary = trimDisplayTimeline.editorTime(
            forSourceTime: keptClip.sourceEnd
        ) ?? displayTime
        return TimelinePosition(
            editorTime: keptRange.upperBound,
            displayTime: displayBoundary
        )
    }

    private func updateTimelineHover(atDisplayTime time: TimeInterval?) {
        guard let time else {
            rulerHoverDisplayTime = nil
            model.timelineHoverTime = nil
            model.hoverPreviewTime = nil
            return
        }

        let position = timelinePosition(forDisplayTime: time)
        rulerHoverDisplayTime = position.displayTime
        model.timelineHoverTime = position.editorTime
        model.hoverPreviewTime = position.editorTime
    }

    private func updateTimelineHover(atEditorTime time: TimeInterval?) {
        rulerHoverDisplayTime = nil
        model.timelineHoverTime = time
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            StudioTransportTray {
                timelineButton("Zoom Out (⌘-)", systemImage: "minus.magnifyingglass") {
                    applyZoom(factor: 1 / Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1.0001)

                timelineButton("Zoom In (⌘=)", systemImage: "plus.magnifyingglass") {
                    applyZoom(factor: Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoom >= scale.maxZoom - 0.0001)

                timelineButton("Fit Timeline (⌘0)", systemImage: "arrow.left.and.right") {
                    fitTimeline()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom <= 1.0001)
            }

            if zoom > 1.0001 {
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editControls: some View {
        HStack(spacing: 6) {
            StudioTransportTray {
                timelineButton("Split at Playhead (⌘B)", systemImage: "scissors") {
                    if model.selectedAudioClipID != nil {
                        model.splitSelectedAudioClip(at: model.displayTime(forOutputTime: model.currentTime))
                    } else {
                        model.splitClip(at: model.currentTime)
                    }
                }
                .keyboardShortcut("b", modifiers: .command)

                timelineButton(model.selectedClipIsSkipped ? "Restore Clip" : "Skip Clip / Delete Selection", systemImage: model.selectedClipIsSkipped ? "arrow.uturn.backward" : "trash") {
                    deleteSelection()
                }
                .disabled(!canDeleteSelection)

                timelineButton("Reset All Clip Edits…", systemImage: "arrow.counterclockwise") {
                    isResetClipsConfirmationPresented = true
                }
                .disabled(!model.hasClipEdits)
                .confirmationDialog(
                    "Reset all clip edits?",
                    isPresented: $isResetClipsConfirmationPresented
                ) {
                    Button("Reset Clips", role: .destructive) {
                        model.resetClips()
                    }
                } message: {
                    Text("Every split, trim, deletion and speed change goes back to the original recording. You can undo this.")
                }
            }

            StudioTransportTray {
                timelineButton("Undo (⌘Z)", systemImage: "arrow.uturn.backward") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                timelineButton("Redo (⇧⌘Z)", systemImage: "arrow.uturn.forward") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            (Text(studioPreciseTimecode(model.displayTime))
                .foregroundStyle(.primary.opacity(0.9))
             + Text(" / \(studioPreciseTimecode(model.duration))")
                .foregroundStyle(.secondary))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .fixedSize()

            HStack(spacing: 4) {
                timelineButton("Back to Start", systemImage: "backward.end.fill") {
                    model.pause()
                    model.seek(to: 0)
                }

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .disabled(!model.isLoaded)

                timelineButton("Skip to End", systemImage: "forward.end.fill") {
                    model.pause()
                    model.seek(to: model.duration)
                }
            }
        }
    }

    private var transport: some View {
        ZStack {
            HStack(spacing: 0) {
                zoomControls
                Spacer(minLength: 0)
                editControls
            }

            playbackControls
        }
        .frame(height: 36)
    }

    private var canDeleteSelection: Bool {
        model.selectedCueID != nil
            || model.selectedAudioClipID != nil
            || model.canDeleteSelectedClip
    }

    private func deleteSelection() {
        if let cueID = model.selectedCueID {
            model.removeZoomCue(id: cueID)
        } else if model.selectedAudioClipID != nil {
            model.deleteSelectedAudioClip()
        } else if model.selectedClipID != nil {
            model.deleteSelectedClip()
        }
    }

    private func timelineButton(
        _ help: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(TransportIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A quiet filled tray grouping related transport buttons, the same
/// treatment as the annotator's tool grid.
private enum StudioTransportMetrics {
    static let buttonRadius: CGFloat = 6
    static let trayInset: CGFloat = 2
}

private struct StudioTransportTray<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Nested radius: the tray wraps buttons inset by `inset`.
        let shape = RoundedRectangle(
            cornerRadius: StudioTransportMetrics.buttonRadius + StudioTransportMetrics.trayInset,
            style: .continuous
        )
        HStack(spacing: 0) {
            content()
        }
        .padding(StudioTransportMetrics.trayInset)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
    }
}

private struct TransportIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                .primary.opacity(
                    isEnabled ? (configuration.isPressed || isHovering ? 0.95 : 0.78) : 0.25
                )
            )
            .background {
                RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous)
                    .fill(Color.primary.opacity(
                        isEnabled ? (configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0) : 0
                    ))
            }
            .onHover { isHovering = $0 }
    }
}

private struct StudioAudioWaveformLane: View {
    let track: RecordingAudioTrack
    let clips: [RecordingAudioClipSegment]
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat
    let gainDB: Double
    let isSelected: Bool
    let selectedClipID: UUID?
    let isInactive: Bool
    let onZoom: (Double, CGFloat) -> Void

    private var tint: Color {
        switch track.kind {
        case .system: .cyan
        case .microphone: .green
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.09 : 0.045))

            if let waveform = track.waveform {
                Canvas { context, size in
                    let centerY = size.height / 2
                    let maximumHeight = max(centerY - 4, 1)
                    let gain = Float(pow(10, gainDB / 20))
                    var sourcePath = Path()
                    var adjustedPath = Path()

                    for clip in clips {
                        let x = CGFloat(clip.timelineStart) * pointsPerSecond - scrollX
                        let width = CGFloat(clip.timelineDuration) * pointsPerSecond
                        guard x + width >= 0, x <= size.width else { continue }
                        let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 7),
                            with: .color(
                                tint.opacity(clip.id == selectedClipID ? 0.12 : 0.035)
                            )
                        )
                    }

                    for pixel in stride(from: CGFloat.zero, through: size.width, by: 1) {
                        let editorTime = Double((scrollX + pixel) / max(pointsPerSecond, 0.001))
                        guard let clip = clips.first(where: {
                            editorTime >= $0.timelineStart && editorTime <= $0.timelineEnd
                        }) else {
                            continue
                        }
                        let sourceTime = clip.sourceTime(at: editorTime)
                        let sourcePeak = min(max(waveform.peak(at: sourceTime), 0), 1)
                        let adjustedPeak = min(sourcePeak * gain, 1)
                        let sourceHeight = max(CGFloat(sourcePeak) * maximumHeight, 0.5)
                        let adjustedHeight = max(CGFloat(adjustedPeak) * maximumHeight, 0.5)

                        sourcePath.move(to: CGPoint(x: pixel, y: centerY - sourceHeight))
                        sourcePath.addLine(to: CGPoint(x: pixel, y: centerY + sourceHeight))
                        adjustedPath.move(to: CGPoint(x: pixel, y: centerY - adjustedHeight))
                        adjustedPath.addLine(to: CGPoint(x: pixel, y: centerY + adjustedHeight))
                    }

                    context.stroke(sourcePath, with: .color(tint.opacity(0.18)), lineWidth: 1)
                    context.stroke(adjustedPath, with: .color(tint.opacity(0.78)), lineWidth: 1)

                    for clip in clips {
                        let x = CGFloat(clip.timelineStart) * pointsPerSecond - scrollX
                        let width = CGFloat(clip.timelineDuration) * pointsPerSecond
                        guard x + width >= 0, x <= size.width else { continue }
                        let rect = CGRect(x: x, y: 0.5, width: width, height: size.height - 1)
                        context.stroke(
                            Path(roundedRect: rect, cornerRadius: 7),
                            with: .color(
                                clip.id == selectedClipID
                                    ? tint.opacity(0.95)
                                    : tint.opacity(0.22)
                            ),
                            lineWidth: clip.id == selectedClipID ? 1.5 : 0.5
                        )
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Analyzing waveform…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: track.kind.systemImage)
                Text(track.kind.title)
                Spacer(minLength: 8)
                Text(
                    InspectorValueFormat.audioVolumePercent()
                        .displayString(for: CGFloat(gainDB))
                )
                    .monospacedDigit()
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
                isInactive ? Color.secondary : Color.primary.opacity(0.82)
            )
            .padding(.horizontal, 9)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? tint.opacity(0.9) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        }
        .background {
            StudioTimelineZoomEventMonitor(onZoom: onZoom)
        }
        .opacity(isInactive ? 0.45 : 1)
        .accessibilityLabel(track.kind.title)
        .accessibilityValue(
            "\(InspectorValueFormat.audioVolumePercent().displayString(for: CGFloat(gainDB))), \(InspectorValueFormat.decibels().displayString(for: CGFloat(gainDB)))"
        )
    }
}

private enum StudioTimelineMetrics {
    static let rowSpacing: CGFloat = 8
    static let playheadLaneHeight: CGFloat = 14
    static let rulerHeight: CGFloat = 16
    static let rulerInteractionHeight = playheadLaneHeight + rulerHeight + rowSpacing * 2
    static let clipLaneHeight: CGFloat = 52
    static let zoomLaneHeight: CGFloat = 32
    static let audioLaneHeight: CGFloat = 42
    /// Room under the lanes for the horizontal scroller, so it never sits on
    /// top of a zoom block.
    static let scrollerGutter: CGFloat = 8

    static func scrollingLanesHeight(audioTrackCount: Int) -> CGFloat {
        clipLaneHeight + zoomLaneHeight
            + audioLaneHeight * CGFloat(audioTrackCount)
            + scrollerGutter
            + rowSpacing * CGFloat(2 + audioTrackCount)
    }

    static func lanesHeight(audioTrackCount: Int) -> CGFloat {
        playheadLaneHeight + rulerHeight
            + scrollingLanesHeight(audioTrackCount: audioTrackCount)
            + rowSpacing * 2
    }
}

/// Shared horizontal scale for every lane in the Studio timeline. `zoom` is a
/// multiplier over "the whole recording fits the viewport", so zoom 1 keeps
/// the original fixed-width timeline and higher values widen the lanes into a
/// scrolling surface where cuts, trim handles and zoom blocks stay grabbable
/// on long recordings.
private struct StudioTimelineScale: Equatable {
    /// Finest scale worth offering; past this a single frame is wider than a
    /// thumbnail tile.
    static let maximumPointsPerSecond: CGFloat = 240
    /// Ceiling on lane width, which is what actually bounds the scale on long
    /// recordings. A 30-minute take still reaches ~55 points per second here.
    static let maximumContentWidth: CGFloat = 100_000

    var viewportWidth: CGFloat
    var duration: TimeInterval
    var zoom: Double

    var contentWidth: CGFloat {
        max(viewportWidth, viewportWidth * CGFloat(zoom))
    }

    var pointsPerSecond: CGFloat {
        duration > 0 ? contentWidth / CGFloat(duration) : 0
    }

    var secondsPerPoint: Double {
        pointsPerSecond > 0 ? 1 / Double(pointsPerSecond) : 0
    }

    var isScrollable: Bool {
        contentWidth > viewportWidth + 0.5
    }

    var maxZoom: Double {
        guard duration > 0, viewportWidth > 1 else { return 1 }
        let widest = min(
            Self.maximumContentWidth,
            Self.maximumPointsPerSecond * CGFloat(duration)
        )
        return max(1, Double(widest / viewportWidth))
    }

    func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time, 0), duration)) * pointsPerSecond
    }

    func time(forX x: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return 0 }
        return min(max(Double(x / pointsPerSecond), 0), duration)
    }

    /// Editor time span currently on screen, padded a little so lane content
    /// culled against it never pops in at the edges.
    func visibleRange(scrollX: CGFloat) -> ClosedRange<TimeInterval> {
        let margin: CGFloat = 120
        let lower = time(forX: scrollX - margin)
        let upper = time(forX: scrollX + viewportWidth + margin)
        return lower...max(lower, upper)
    }
}

/// Lightweight preview marker. It shares the playhead's full-height alignment
/// but stays dashed and thinner so hover never looks like a committed seek.
private struct StudioTimelineHoverIndicator: View {
    let time: TimeInterval
    let scale: StudioTimelineScale
    let scrollX: CGFloat

    var body: some View {
        Canvas { context, size in
            let x = scale.x(for: time) - scrollX
            guard x >= -1, x <= size.width + 1 else { return }

            var path = Path()
            path.move(to: CGPoint(x: x, y: StudioTimelineMetrics.playheadLaneHeight - 2))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                path,
                with: .color(Color(red: 0.95, green: 0.50, blue: 0.48).opacity(0.7)),
                style: StrokeStyle(
                    lineWidth: 0.8,
                    lineCap: .round,
                    dash: [2, 3]
                )
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Full-height playhead marker. Input passes through to the ruler and edit
/// targets underneath, so the marker never adds another scrub surface.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let scale: StudioTimelineScale
    let scrollX: CGFloat

    private static let tint = Color(red: 0.96, green: 0.16, blue: 0.18)

    private enum Metrics {
        static let crownWidth: CGFloat = 11
        static let crownHeight: CGFloat = 13
        static let lineWidth: CGFloat = 1.5
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // Viewport space: the playhead overlay never scrolls, it just
            // tracks the scrolled lanes underneath it.
            let x = scale.x(for: time) - scrollX
            let isVisible = x >= -Metrics.lineWidth && x <= width + Metrics.lineWidth

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Self.tint)
                    .frame(
                        width: Metrics.lineWidth,
                        height: max(0, proxy.size.height - Metrics.crownHeight + 2)
                    )
                    .offset(x: x - Metrics.lineWidth / 2, y: Metrics.crownHeight - 2)

                PlayheadCrownShape()
                    .fill(LinearGradient(
                        colors: [Self.tint, Color(red: 0.76, green: 0.08, blue: 0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .overlay {
                        PlayheadCrownShape()
                            .stroke(Color.white.opacity(0.65), lineWidth: 0.75)
                    }
                    .overlay(alignment: .top) {
                        HStack(spacing: 1.5) {
                            ForEach(0..<3) { _ in
                                Capsule()
                                    .fill(Color.black.opacity(0.3))
                                    .frame(width: 0.75, height: 4)
                                    .shadow(color: .white.opacity(0.4), radius: 0, x: 0.5, y: 0.5)
                            }
                        }
                        .padding(.top, 2.5)
                    }
                    .frame(width: Metrics.crownWidth, height: Metrics.crownHeight)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .offset(x: x - Metrics.crownWidth / 2)
            }
            .opacity(isVisible ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Rounded flag with a pointed tail, the classic editor playhead pin.
private struct PlayheadCrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 3
        let tailHeight: CGFloat = 4
        let bodyBottom = rect.maxY - tailHeight

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: bodyBottom),
            control: CGPoint(x: rect.maxX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: bodyBottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyBottom - cornerRadius),
            control: CGPoint(x: rect.minX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Observes zoom gestures without becoming the hit target. This lets ruler
/// scrubbing and zoom-cue editing keep their own mouse handling while pinch
/// and Command-scroll work anywhere in the monitored row.
private struct StudioTimelineZoomEventMonitor: NSViewRepresentable {
    let onZoom: (Double, CGFloat) -> Void

    func makeNSView(context: Context) -> ZoomEventView {
        let view = ZoomEventView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ZoomEventView, context: Context) {
        nsView.onZoom = onZoom
    }

    final class ZoomEventView: NSView {
        private static let scrollPointsPerDoubling: CGFloat = 220

        var onZoom: ((Double, CGFloat) -> Void)?
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeEventMonitor()
            guard window != nil else { return }

            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .magnify]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit {
            removeEventMonitor()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }

            let factor: Double
            switch event.type {
            case .magnify:
                guard event.magnification != 0 else { return event }
                factor = 1 + Double(event.magnification)
            case .scrollWheel:
                guard event.modifierFlags.contains(.command) else { return event }
                let rawDelta = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * 16
                guard abs(rawDelta) > 0.001 else { return event }
                factor = pow(2, Double(rawDelta / Self.scrollPointsPerDoubling))
            default:
                return event
            }

            guard factor.isFinite, factor > 0 else { return event }
            onZoom?(factor, point.x)
            return nil
        }

        private func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// Absolute-time ruler above the clip lane. The ruler itself never scrolls: it
/// draws only the time span currently on screen, so a deeply zoomed timeline
/// costs the same to render as a fitted one.
private struct StudioTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat
    let onHover: (TimeInterval?) -> Void
    let onScrub: (TimeInterval) -> Void

    var body: some View {
        Canvas { context, size in
            guard duration > 0.2, pointsPerSecond > 0, size.width > 60 else { return }

            let step = Self.labelStep(forPointsPerSecond: pointsPerSecond)
            let startTime = max(0, Double(scrollX / pointsPerSecond))
            let endTime = min(duration, Double((scrollX + size.width) / pointsPerSecond))
            let endpointLabel = Self.label(for: duration, step: step)
            var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude

            func x(for time: Double) -> CGFloat {
                CGFloat(time) * pointsPerSecond - scrollX
            }

            /// `anchorX` is the tick position; `trailing` right-aligns the
            /// label onto it instead of centering, which is how the endpoint
            /// label stays inside the viewport.
            func drawLabel(_ text: String, at anchorX: CGFloat, trailing: Bool = false) {
                let label = context.resolve(
                    Text(text)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                )
                let labelSize = label.measure(in: size)
                let labelX = trailing ? anchorX - labelSize.width : anchorX - labelSize.width / 2
                let clampedX = min(max(labelX, 0), max(0, size.width - labelSize.width))
                guard clampedX >= lastLabelMaxX + 8 else { return }
                context.draw(label, in: CGRect(
                    x: clampedX,
                    y: size.height - 5 - labelSize.height,
                    width: labelSize.width,
                    height: labelSize.height
                ))
                lastLabelMaxX = clampedX + labelSize.width
            }

            var index = max(0, Int(floor(startTime / step)))
            let lastIndex = Int(ceil(endTime / step))
            while index <= lastIndex {
                let time = Double(index) * step
                index += 1
                guard time <= duration else { break }
                let tickX = x(for: time)

                context.fill(
                    Path(CGRect(x: tickX - 0.5, y: size.height - 4, width: 1, height: 4)),
                    with: .color(.primary.opacity(0.30))
                )

                let minorTime = time + step / 2
                if minorTime < duration {
                    context.fill(
                        Path(CGRect(
                            x: x(for: minorTime) - 0.5,
                            y: size.height - 2.5,
                            width: 1,
                            height: 2.5
                        )),
                        with: .color(.primary.opacity(0.16))
                    )
                }

                // A final whole-second tick can format identically to a
                // fractional endpoint (for example 4.2 -> 00:04). Let the
                // actual endpoint own that label.
                let timeLabel = Self.label(for: time, step: step)
                if time == 0 || timeLabel != endpointLabel {
                    drawLabel(timeLabel, at: tickX)
                }
            }

            // The end of the recording always gets a tick, right-aligned when
            // it lands at the trailing edge of the viewport.
            let endpointX = x(for: duration)
            if endpointX >= -1, endpointX <= size.width + 1 {
                context.fill(
                    Path(CGRect(
                        x: min(endpointX, size.width - 0.5) - 0.5,
                        y: size.height - 4,
                        width: 1,
                        height: 4
                    )),
                    with: .color(.primary.opacity(0.30))
                )
                drawLabel(endpointLabel, at: endpointX, trailing: true)
            }
        }
        // Include the crown lane and the gap above the thumbnails in the hit area.
        .padding(.top, StudioTimelineMetrics.playheadLaneHeight + StudioTimelineMetrics.rowSpacing)
        .padding(.bottom, StudioTimelineMetrics.rowSpacing)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                onHover(time(atViewportX: location.x))
            case .ended:
                onHover(nil)
            }
        }
        .gesture(
            // Only header presses start scrubbing; once captured, follow the
            // pointer's horizontal position until release, even outside the header.
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = time(atViewportX: value.location.x)
                    onHover(time)
                    onScrub(time)
                }
                .onEnded { _ in
                    onHover(nil)
                }
        )
    }

    private func time(atViewportX x: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return 0 }
        return min(max(Double((x + scrollX) / pointsPerSecond), 0), duration)
    }

    /// Smallest "nice" interval whose labels stay comfortably apart at the
    /// current scale. Sub-second steps unlock once a zoomed lane spreads a
    /// single second across most of the viewport.
    private static func labelStep(forPointsPerSecond pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [
            0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800
        ]
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 64 {
            return candidate
        }
        return candidates.last ?? 60
    }

    private static func label(for time: Double, step: Double) -> String {
        step < 1 ? studioPreciseTimecode(time) : studioTimecode(time)
    }
}

private func studioTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let total = Int(safe.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        : String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func studioPreciseTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let totalMinutes = Int(safe) / 60
    let remaining = safe.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", totalMinutes, remaining)
}

/// Frame around the zoom lane. It stays pinned to the viewport while the cue
/// blocks scroll inside it, so the lane reads as a fixed track no matter how
/// far the timeline is zoomed.
private struct StudioZoomLaneBackground: View {
    /// An empty lane explains itself instead of reading as dead space.
    var showsHint = false

    var body: some View {
        RoundedRectangle(
            cornerRadius: StudioZoomLaneMetrics.laneCornerRadius,
            style: .continuous
        )
            .fill(Color.primary.opacity(0.055))
            .overlay {
                if showsHint {
                    Label("Drag here to add a zoom", systemImage: "plus.magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
    }
}

private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    let onZoom: (Double, TimeInterval) -> Void

    /// Ignore clicks and small pointer movements when creating a zoom.
    private static let dragCreateThreshold: CGFloat = 4

    /// Held as a time rather than a position so a zoom change mid-drag can't
    /// reinterpret where the drag began.
    @State private var dragStartTime: TimeInterval?
    @State private var pendingZoomRange: ClosedRange<TimeInterval>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Contentless hit surface: the lane can be tens of thousands of
            // points wide, and the visible frame is drawn by the chrome behind
            // the scroll view.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            let time = scale.time(forX: value.location.x)

                            if dragStartTime == nil {
                                model.pause()
                                dragStartTime = time
                            }
                            guard let startTime = dragStartTime else { return }

                            if pendingZoomRange == nil,
                               abs(value.location.x - scale.x(for: startTime))
                                   < Self.dragCreateThreshold {
                                return
                            }

                            pendingZoomRange = pendingRange(from: startTime, to: time)
                        }
                        .onEnded { _ in
                            // A range clamped to nothing means the drag ran
                            // entirely into a neighboring block; there is no
                            // gap here to put a zoom in.
                            if let range = pendingZoomRange,
                               range.upperBound - range.lowerBound > 0.001 {
                                model.addZoomCue(
                                    fromEditorTime: model.outputTime(forDisplayTime: range.lowerBound),
                                    toEditorTime: model.outputTime(forDisplayTime: range.upperBound)
                                )
                            }
                            dragStartTime = nil
                            pendingZoomRange = nil
                        }
                )

            if let pendingZoomRange {
                let lowX = scale.x(for: pendingZoomRange.lowerBound)
                let highX = scale.x(for: pendingZoomRange.upperBound)
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(2, highX - lowX), height: StudioZoomLaneMetrics.blockHeight)
                    .offset(x: lowX, y: StudioZoomLaneMetrics.blockInset)
                    .allowsHitTesting(false)
            }

            // Click ticks and cue blocks are culled to the visible span: an
            // hour-long take can hold thousands of clicks, and only a screenful
            // of them can ever be seen.
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.38))
                    .frame(width: 1, height: 10)
                    .offset(x: scale.x(for: pressTime), y: 11)
                    .allowsHitTesting(false)
            }

            ForEach(visibleBlocks) { block in
                StudioZoomCueBlock(model: model, block: block, scale: scale)
            }
        }
        .background {
            StudioTimelineZoomEventMonitor { factor, localX in
                onZoom(factor, scale.time(forX: localX))
            }
        }
        .contextMenu {
            Button("Add Zoom at Playhead") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }

    /// The range a drag-created zoom would cover, stopped at the blocks on
    /// either side of where the drag began so the preview matches the cue the
    /// model will actually allow.
    private func pendingRange(
        from startTime: TimeInterval,
        to currentTime: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        let blocks = model.zoomTimelineBlocks
        let lowerLimit = blocks
            .filter { $0.editorEnd <= startTime }
            .map(\.editorEnd)
            .max() ?? 0
        let upperLimit = blocks
            .filter { $0.editorStart >= startTime }
            .map(\.editorStart)
            .min() ?? model.displayClipTimeline.duration
        let low = max(min(startTime, currentTime), lowerLimit)
        let high = min(max(startTime, currentTime), upperLimit)
        return low...max(low, high)
    }

    private var visiblePressTimes: [TimeInterval] {
        model.visibleRecordedPressTimes.filter { visibleRange.contains($0) }
    }

    private var visibleBlocks: [RecordingZoomTimelineBlock] {
        model.zoomTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

private enum StudioZoomLaneMetrics {
    static let laneInset: CGFloat = 4
    static let blockCornerRadius: CGFloat = 6
    static let laneCornerRadius = blockCornerRadius + laneInset
    static let selectionRingPadding: CGFloat = 1
    static let selectionRingCornerRadius = blockCornerRadius + selectionRingPadding
    static let blockHeight: CGFloat = 24
    static let blockInset: CGFloat = 4
    static let minimumLabelledBlockWidth: CGFloat = 48
}

private struct StudioZoomCueBlock: View {
    @Bindable var model: RecordingStudioModel
    let block: RecordingZoomTimelineBlock
    let scale: StudioTimelineScale

    /// Frozen at drag start. The live block re-derives on every model update,
    /// so measuring the drag against it would compound the translation each
    /// event and send the block flying.
    private struct DragBase {
        let cue: ZoomCue
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?

    private var isSelected: Bool {
        model.selectedCueID == block.cue.id
    }

    var body: some View {
        guard scale.pointsPerSecond > 0 else { return AnyView(EmptyView()) }

        let cue = block.cue
        let blockDuration = block.editorEnd - block.editorStart
        // Short cues keep a grabbable minimum width even when the timeline is
        // fitted; zooming in is what makes them accurate to work with.
        let width = min(
            scale.contentWidth,
            max(24, CGFloat(blockDuration) * scale.pointsPerSecond)
        )
        let x = min(
            max(scale.x(for: block.editorStart), 0),
            max(0, scale.contentWidth - width)
        )

        return AnyView(
            HStack(spacing: 0) {
                resizeHandle(edge: .leading)
                Spacer(minLength: 0)
                // Too narrow for the label: show the block bare rather
                // than a truncated "…".
                if width >= StudioZoomLaneMetrics.minimumLabelledBlockWidth {
                    Text(String(format: "%.1f×", cue.zoom))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                resizeHandle(edge: .trailing)
            }
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight)
            .background(
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(isSelected ? 0.95 : 0.72))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: StudioZoomLaneMetrics.selectionRingCornerRadius,
                        style: .continuous
                    )
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .padding(-StudioZoomLaneMetrics.selectionRingPadding)
                }
            }
            .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
            .gesture(
                // Global coordinates: the block moves under the pointer while
                // dragging, so a local-space translation would chase its own
                // updates and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var moved = dragBase.cue
                        let length = dragBase.cue.duration
                        let baseBlockDuration = dragBase.editorEnd - dragBase.editorStart
                        let editorStart = min(
                            max(0, dragBase.editorStart + delta),
                            max(0, model.displayClipTimeline.duration - baseBlockDuration)
                        )
                        moved.start = min(
                            max(0, model.displayClipTimeline.sourceTime(at: editorStart)),
                            max(0, model.sourceDuration - length)
                        )
                        moved.end = min(model.sourceDuration, moved.start + length)
                        model.moveZoomCue(moved)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: "Move Zoom")
                    }
            )
            .onTapGesture {
                model.selectZoomCue(id: cue.id)
            }
            .contextMenu {
                Button("Remove Zoom", role: .destructive) {
                    model.removeZoomCue(id: cue.id)
                }
            }
        )
    }

    private func resizeHandle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10, height: StudioZoomLaneMetrics.blockHeight)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(Color.white.opacity(isSelected ? 0.9 : 0.45))
                    .frame(width: 2.5, height: 12)
            }
            .contentShape(Rectangle())
            .gesture(
                // Global coordinates - the handle itself moves while resizing,
                // so local-space translations feed back into the drag and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: block.cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: block.cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var resized = dragBase.cue
                        switch edge {
                        case .leading:
                            let editorTime = dragBase.editorStart + delta
                            let sourceTime = model.displayClipTimeline.sourceTime(at: editorTime)
                            resized.start = min(
                                max(0, sourceTime),
                                dragBase.cue.end - ZoomCue.minimumDuration
                            )
                        case .trailing:
                            let editorTime = dragBase.editorEnd + delta
                            let sourceTime = model.displayClipTimeline.sourceTime(at: editorTime)
                            resized.end = max(
                                dragBase.cue.start + ZoomCue.minimumDuration,
                                min(model.sourceDuration, sourceTime)
                            )
                        }
                        model.updateZoomCue(resized)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: "Resize Zoom")
                    }
            )
    }
}

// MARK: - Inspector

private extension ZoomAnchorMode {
    var inspectorTitle: String {
        switch self {
        case .pointerAnchor: "Pointer"
        case .smartAnchor: "Smart"
        case .pinnedAnchor: "Fixed"
        }
    }
}

private enum StudioInspectorSection: String, Hashable, CaseIterable {
    case background
    case layout
    case motion
    case cursor
    case keystrokes
    case transcription
    case camera
    case audio
}

private enum StudioInspectorSectionState {
    static let expandedSectionsKey = "studioInspector.expandedSections"
    static let defaultSections: Set<StudioInspectorSection> = [.background, .layout, .motion]

    static func load() -> Set<StudioInspectorSection> {
        guard let rawValues = UserDefaults.standard.stringArray(forKey: expandedSectionsKey) else {
            return defaultSections
        }
        return Set(rawValues.compactMap(StudioInspectorSection.init(rawValue:)))
    }

    static func save(_ sections: Set<StudioInspectorSection>) {
        UserDefaults.standard.set(sections.map(\.rawValue), forKey: expandedSectionsKey)
    }
}

private enum StudioTranscriptTab: CaseIterable, Identifiable {
    case captions
    case edit

    var id: Self { self }

    var title: String {
        switch self {
        case .captions: "Captions"
        case .edit: "Edit Video"
        }
    }
}

private struct StudioInspector: View {
    @State private var features = FeatureSettings.shared
    /// Whole-number playback rates offered for a clip, within
    /// `RecordingClipSegment`'s 1...8 range.
    private static let clipSpeedPresets: [Double] = [1, 2, 3, 4, 6, 8]

    @Bindable var model: RecordingStudioModel
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var stylePresetStore = RecordingStudioStylePresetStore.shared
    @State private var expandedSections = StudioInspectorSectionState.load()
    @State private var transcriptTab: StudioTranscriptTab = .captions
    @State private var isAudioExportOptionsPresented = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // Timeline selections edit at the top, where attention lands
                // after clicking a zoom or clip, instead of pushing the
                // sections below around mid-panel.
                if let selected = model.selectedCue {
                    InspectorSection(
                        title: "Selected Zoom",
                        accessory: {
                            InspectorToggle(
                                "Use this zoom",
                                isOn: Binding(
                                    get: { selected.isEnabled },
                                    set: { isEnabled in
                                        var updated = selected
                                        updated.isEnabled = isEnabled
                                        model.updateZoomCue(updated)
                                    }
                                )
                            )
                        }
                    ) {
                        selectedZoomControls(for: selected)
                    }
                    InspectorSectionDivider()
                } else if let selectedClip = model.selectedClip {
                    InspectorSection("Selected Clip") {
                        selectedClipControls(for: selectedClip)
                    }
                    InspectorSectionDivider()
                }

                InspectorDisclosureSection(
                    title: "Background",
                    summary: StudioInspectorSummary.background(
                        model.style.background,
                        aspect: model.exportAspect
                    ),
                    isExpanded: expansionBinding(for: .background),
                    accessory: {
                        if model.style.background != .none {
                            InspectorClearButton(help: "Remove background") {
                                model.style.background = .none
                            }
                        }
                    }
                ) {
                    backgroundControls
                }

                InspectorDisclosureSection(
                    title: "Layout",
                    summary: usesDefaultLayout ? nil : "Custom",
                    isExpanded: expansionBinding(for: .layout),
                    accessory: {
                        if !usesDefaultLayout {
                            InspectorResetButton(help: "Reset layout") {
                                model.style.padding = 0.06
                                model.style.cornerRadius = 0.02
                                model.style.shadow = 0.45
                            }
                        }
                    }
                ) {
                    layoutControls
                }

                // Selection editing surfaces here (between Layout and Zoom &
                // Clicks) whenever a zoom or clip is selected on the timeline.
                if let selected = model.selectedCue {
                    InspectorSection(
                        title: "Selected Zoom",
                        accessory: {
                            Toggle(
                                "Use this zoom",
                                isOn: Binding(
                                    get: { selected.isEnabled },
                                    set: { isEnabled in
                                        var updated = selected
                                        updated.isEnabled = isEnabled
                                        model.updateZoomCue(updated)
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Use this zoom")
                        }
                    ) {
                        selectedZoomControls(for: selected)
                    }
                    InspectorSectionDivider()
                } else if let selectedClip = model.selectedClip {
                    InspectorSection("Selected Clip") {
                        selectedClipControls(for: selectedClip)
                    }
                    InspectorSectionDivider()
                } else if let selectedAudioTrack = model.selectedAudioTrack {
                    InspectorSection("Selected Audio") {
                        selectedAudioControls(for: selectedAudioTrack)
                    }
                    InspectorSectionDivider()
                }

                InspectorDisclosureSection(
                    title: "Zoom & Clicks",
                    summary: zoomSummary,
                    isExpanded: expansionBinding(for: .motion),
                    accessory: {
                        sectionToggle("Enable zooms", isOn: $model.zoomEnabled, section: .motion)
                    }
                ) {
                    zoomControls
                }

                if model.pointerIsSynthesized {
                    InspectorDisclosureSection(
                        title: "Cursor",
                        summary: model.style.hidesCursor
                            ? "Hidden"
                            : InspectorValueFormat.magnification(fractionDigits: 1)
                                .displayString(for: model.style.cursorScale),
                        isExpanded: expansionBinding(for: .cursor),
                        accessory: {
                            HStack(spacing: 5) {
                                if model.style.cursorScale != RecordingStudioStyle.defaultCursorScale {
                                    InspectorResetButton(help: "Reset cursor size") {
                                        model.style.cursorScale = RecordingStudioStyle.defaultCursorScale
                                    }
                                }
                                sectionToggle(
                                    "Show mouse pointer",
                                    isOn: Binding(
                                        get: { !model.style.hidesCursor },
                                        set: { model.style.hidesCursor = !$0 }
                                    ),
                                    section: .cursor
                                )
                            }
                        }
                    ) {
                        cursorControls
                    }
                }

                if model.hasKeystrokes {
                    InspectorDisclosureSection(
                        title: "Keystrokes",
                        summary: model.showsKeystrokes
                            ? StudioInspectorSummary.keystrokePlacement(model.keystrokePlacement)
                            : nil,
                        isExpanded: expansionBinding(for: .keystrokes),
                        accessory: {
                            sectionToggle("Show keystrokes", isOn: $model.showsKeystrokes, section: .keystrokes)
                        }
                    ) {
                        keystrokeControls
                    }
                }

                if features.isEnabled(.captions), model.canTranscribe || model.hasSubtitles {
                    InspectorDisclosureSection(
                        title: "Transcription",
                        summary: transcriptionSummary,
                        isExpanded: expansionBinding(for: .transcription),
                        accessory: {
                            if model.transcriptionState.isTranscribing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 24, height: 24)
                            } else if model.hasSubtitles {
                                sectionToggle(
                                    "Show subtitles",
                                    isOn: $model.showsSubtitles,
                                    section: .transcription
                                )
                            }
                        }
                    ) {
                        transcriptionControls
                    }
                }

                if model.hasCameraVideo {
                    InspectorDisclosureSection(
                        title: "Camera",
                        summary: model.style.camera.isVisible
                            ? InspectorValueFormat.percent().displayString(for: model.style.camera.size)
                            : nil,
                        isExpanded: expansionBinding(for: .camera),
                        accessory: {
                            sectionToggle("Show camera", isOn: $model.style.camera.isVisible, section: .camera)
                        }
                    ) {
                        cameraControls
                    }
                }

                InspectorDisclosureSection(
                    title: "Audio",
                    summary: audioSummary,
                    isExpanded: expansionBinding(for: .audio),
                    accessory: {
                        if model.replacementAudio != nil {
                            if model.hasRecordedAudio {
                                InspectorResetButton(help: "Use the recorded audio again") {
                                    model.removeReplacementAudio()
                                }
                            } else {
                                InspectorClearButton(help: "Remove this audio") {
                                    model.removeReplacementAudio()
                                }
                            }
                        }
                    }
                ) {
                    audioControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, PreviewPeekTab.pillHeight * 1.1)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                RecordingStudioStylePresetBar(model: model, presetStore: stylePresetStore)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 0.5)
            }
            .background(sidebarBackground)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .background(sidebarBackground)
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task {
            await wallpaperStore.reload()
        }
    }

    // MARK: Background

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Aspect ratio")

                InspectorSegmented(
                    options: ExportAspectPreset.allCases,
                    isSelected: { $0 == model.exportAspect },
                    onTap: { model.exportAspect = $0 },
                    label: { preset in
                        Text(preset.title)
                            .font(.inspectorSegment)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .help(preset.help)
                    }
                )

                if model.exportAspect != .original {
                    InspectorSegmented(
                        options: ExportAspectContentMode.allCases,
                        isSelected: { $0 == model.exportAspectMode },
                        onTap: { model.exportAspectMode = $0 },
                        label: { mode in
                            Text(mode.title)
                                .font(.inspectorSegment)
                                .help(mode.help)
                        }
                    )
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Fill")

                InspectorBackgroundFillPicker(
                    style: $model.style.background,
                    rememberedWallpaper: nil,
                    wallpaperStore: wallpaperStore,
                    onEditorAction: {},
                    onPickWallpaper: pickWallpaper
                )
            }
        }
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Video Background Wallpaper"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            wallpaperStore.addRecentWallpaper(url)
            model.style.background = .customWallpaper(AnnotationCustomWallpaper(url: url))
        }
    }

    // MARK: Layout

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Padding",
                    value: $model.style.padding,
                    range: 0...0.18,
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Corners",
                    value: $model.style.cornerRadius,
                    range: 0...0.08,
                    format: .percent()
                )
            }

            InspectorSlider(
                "Shadow",
                value: $model.style.shadow,
                range: 0...1,
                format: .percent()
            )
        }
    }

    // MARK: Zoom

    private var zoomControls: some View {
        let pressCount = model.recordedPressTimes.count
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                InspectorActionButton("Auto Zoom", systemImage: "pointer.arrow.rays") {
                    model.resynthesizeZoomCues()
                }
                .disabled(pressCount == 0)
                .help(
                    pressCount == 0
                        ? "No clicks were recorded"
                        : "Turn the \(pressCount == 1 ? "recorded click" : "\(pressCount) recorded clicks") into smooth camera moves"
                )

                InspectorActionButton("Add Zoom", systemImage: "plus.magnifyingglass") {
                    model.addZoomCue(at: model.currentTime)
                }
                .help("Add a zoom at the playhead, or drag across the zoom lane")
            }

            if model.zoomCues.isEmpty {
                InspectorHint(
                    pressCount > 0
                        ? "Auto Zoom turns your recorded clicks into camera moves."
                        : "Drag across the zoom lane on the timeline to add a zoom."
                )
            }
        }
        .disabled(!model.zoomEnabled)
        .opacity(model.zoomEnabled ? 1 : 0.48)
    }

    private func selectedZoomControls(for selected: ZoomCue) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Camera focus")

                InspectorSegmented(
                    options: ZoomAnchorMode.allCases,
                    isSelected: { $0 == selected.anchorMode },
                    onTap: { anchorMode in
                        var updated = selected
                        updated.anchorMode = anchorMode
                        if anchorMode == .pinnedAnchor,
                           let pointer = model.pointerLocation(at: model.currentTime) {
                            updated.pinnedPoint = pointer
                        }
                        model.updateZoomCue(updated)
                    },
                    label: { Text($0.inspectorTitle).font(.inspectorSegment) }
                )
            }

            if selected.anchorMode == .pinnedAnchor {
                zoomAmountSlider(for: selected)

                VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                    HStack(spacing: 8) {
                        InspectorGroupLabel("Target position")
                        Spacer(minLength: 0)
                        Text(zoomTargetPositionText(selected.pinnedPoint))
                            .font(.inspectorNumeric)
                            .foregroundStyle(.tertiary)
                    }

                    RecordingZoomFocusPad(
                        position: Binding(
                            get: { selected.pinnedPoint },
                            set: { target in
                                var updated = selected
                                updated.pinnedPoint = target
                                model.updateZoomCue(updated)
                            }
                        ),
                        magnification: selected.zoom
                    )
                }
            } else {
                InspectorFieldPair {
                    zoomAmountSlider(for: selected)
                } trailing: {
                    InspectorSlider(
                        "Edge",
                        value: Binding(
                            get: { CGFloat(selected.boundsBias) },
                            set: { boundsBias in
                                var updated = selected
                                updated.boundsBias = Double(boundsBias)
                                model.updateZoomCue(updated)
                            }
                        ),
                        range: 0...1,
                        format: .percent()
                    )
                    .help("How much of the frame's edge stays in view while zoomed")
                }
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if selected.anchorMode == .pinnedAnchor {
                    InspectorActionButton("Target Pointer", systemImage: "scope") {
                        guard let pointer = model.pointerLocation(at: model.currentTime) else { return }
                        var updated = selected
                        updated.pinnedPoint = pointer
                        model.updateZoomCue(updated)
                    }
                    .help("Aim the zoom at the pointer's position under the playhead")
                }

                InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                    model.removeZoomCue(id: selected.id)
                }
                .help("Remove the selected zoom")
            }
        }
        .disabled(!model.zoomEnabled)
        .opacity(model.zoomEnabled ? 1 : 0.48)
    }

    private func zoomAmountSlider(for selected: ZoomCue) -> some View {
        InspectorSlider(
            "Zoom",
            value: Binding(
                get: { CGFloat(selected.zoom) },
                set: { newValue in
                    var updated = selected
                    updated.zoom = Double(newValue)
                    model.updateZoomCue(updated)
                }
            ),
            range: 1.1...3,
            format: .magnification(fractionDigits: 1)
        )
    }

    private func zoomTargetPositionText(_ position: CGPoint) -> String {
        let x = Int((position.x * 100).rounded())
        let y = Int((position.y * 100).rounded())
        return "\(x), \(y)"
    }

    // MARK: Selected clip

    private func selectedClipControls(for clip: RecordingClipSegment) -> some View {
        let speedText = InspectorValueFormat
            .magnification(fractionDigits: 1)
            .displayString(for: CGFloat(clip.speed))

        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Speed",
                value: Binding(
                    get: { CGFloat(clip.speed) },
                    set: { model.setClipSpeed(Double($0), forClipID: clip.id) }
                ),
                range: CGFloat(RecordingClipSegment.minimumSpeed)...CGFloat(RecordingClipSegment.maximumSpeed),
                format: .magnification(fractionDigits: 1)
            )

            if clip.speed != 1 {
                Text("Plays this clip \(speedText) faster. Audio speeds up with it.")
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Selected audio

    private func selectedAudioControls(for track: RecordingAudioTrack) -> some View {
        let recordedAudioIsActive = model.replacementAudio == nil
        let gainDB = model.audioGainDB(for: track.kind)
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if let clip = model.selectedAudioClip {
                HStack(spacing: 8) {
                    Text("Clip")
                    Spacer(minLength: 8)
                    Text(
                        "\(studioPreciseTimecode(clip.timelineStart)) – \(studioPreciseTimecode(clip.timelineEnd))"
                    )
                    .monospacedDigit()
                }
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)

                Text("Drag the clip to move it. Drag either white edge to trim. Split with T, or delete it to leave silence.")
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                InspectorSectionDivider()
            }

            InspectorSlider(
                "Volume",
                value: Binding(
                    get: { CGFloat(model.audioGainDB(for: track.kind)) },
                    set: { model.setAudioGainDB(Double($0), for: track.kind) }
                ),
                range: CGFloat(RecordingAudioGainLimits.minimumDB)...CGFloat(RecordingAudioGainLimits.maximumDB),
                format: .audioVolumePercent()
            )
            .disabled(!recordedAudioIsActive)

            HStack(spacing: 8) {
                Text("100% = original")
                Spacer(minLength: 8)
                Text(InspectorValueFormat.decibels().displayString(for: CGFloat(gainDB)))
                    .monospacedDigit()
            }
            .font(.inspectorLabel)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                InspectorActionButton("Auto Adjust", systemImage: "wand.and.sparkles") {
                    model.autoAdjustVolume(for: track.kind)
                }
                .disabled(!recordedAudioIsActive || track.waveform == nil)

                InspectorActionButton("Reset", systemImage: "arrow.counterclockwise") {
                    model.resetAudioGain(for: track.kind)
                }
                .disabled(!recordedAudioIsActive || model.audioGainDB(for: track.kind) == 0)
            }

            Text(
                recordedAudioIsActive
                    ? "Auto Adjust sets one level for the whole track. It ignores silence and does not duck other audio."
                    : "The replacement soundtrack is active, so recorded-track volume is bypassed."
            )
            .font(.inspectorLabel)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cursor

    private var cursorControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Size",
                value: $model.style.cursorScale,
                range: 1...4,
                format: .magnification(fractionDigits: 1)
            )

            if model.canShowPressEffects {
                InspectorToggleRow("Click highlights", isOn: $model.showsClickEffects)
            }
        }
        .disabled(model.style.hidesCursor)
        .opacity(model.style.hidesCursor ? 0.48 : 1)
    }

    // MARK: Keystrokes

    private var keystrokeControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Top") {
                keystrokePlacementRow([.topLeft, .topCenter, .topRight])
            }
            InspectorRow("Bottom") {
                keystrokePlacementRow([.bottomLeft, .bottomCenter, .bottomRight])
            }
        }
        .help("Shortcuts you pressed while recording appear as a caption")
        .disabled(!model.showsKeystrokes)
        .opacity(model.showsKeystrokes ? 1 : 0.48)
    }

    private func keystrokePlacementRow(
        _ options: [RecordingKeystrokePlacement]
    ) -> some View {
        InspectorSegmented(
            options: options,
            isSelected: { $0 == model.keystrokePlacement },
            onTap: { model.keystrokePlacement = $0 },
            label: { Text($0.title).font(.inspectorSegment) }
        )
    }

    // MARK: Transcription

    @ViewBuilder
    private var transcriptionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            DisclosureGroup {
                TranscriptionSettingsControls()
                    .padding(.vertical, InspectorMetrics.rowSpacing)
            } label: {
                Text("Provider & Model")
                    .font(.inspectorLabel)
            }
            .disabled(model.transcriptionState.isTranscribing)

            Text("Transcribes the original microphone track, or the recorded audio when no separate microphone track exists. Video cuts are reflected in caption playback.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.transcriptionState {
            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.transcriptionProgress > 0 ? "Transcribing audio… \(Int(model.transcriptionProgress * 100))%" : "Transcribing audio…")
                        .font(.inspectorLabel)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { model.cancelTranscription() }
                    .font(.inspectorLabel)
                    .controlSize(.small)
            case .failed(let message):
                InspectorHint(message, tint: .orange)

                InspectorActionButton("Try Again", systemImage: "waveform") {
                    model.transcribe()
                }
            case .idle:
                if model.hasSubtitles {
                    subtitleEditor
                    transcriptionActions
                } else {
                    InspectorActionButton("Transcribe Audio", systemImage: "waveform") {
                        model.transcribe()
                    }

                    Text("Creates timed captions with breaks at pauses in speech. Open Provider & Model to choose how to transcribe.")
                        .font(.inspectorLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var transcriptionActions: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            if model.canTranscribe {
                InspectorActionButton("Transcribe Again", systemImage: "arrow.clockwise") {
                    model.transcribe()
                }
            }

            InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                model.removeTranscription()
            }
            .help("Remove the subtitles")
        }
    }

    private var subtitleEditor: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: StudioTranscriptTab.allCases,
                isSelected: { $0 == transcriptTab },
                onTap: { transcriptTab = $0 },
                label: { tab in
                    Text(tab.title)
                        .font(.inspectorSegment)
                        .lineLimit(1)
                }
            )

            switch transcriptTab {
            case .captions:
                captionControls
            case .edit:
                transcriptEditControls
            }
        }
    }

    private var captionControls: some View {
        let verticalRange = SubtitleBarStyle.verticalRange
        let fontScaleRange = SubtitleBarStyle.fontScaleRange
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Position",
                value: Binding(
                    get: { CGFloat(model.subtitleStyle.verticalPosition) },
                    set: {
                        var style = model.subtitleStyle
                        style.verticalPosition = Double($0)
                        model.setSubtitleStyle(style)
                    }
                ),
                range: CGFloat(verticalRange.lowerBound)...CGFloat(verticalRange.upperBound),
                format: .percent()
            )

            InspectorSlider(
                "Text Size",
                value: Binding(
                    get: { CGFloat(model.subtitleStyle.fontScale) },
                    set: {
                        var style = model.subtitleStyle
                        style.fontScale = Double($0)
                        model.setSubtitleStyle(style)
                    }
                ),
                range: CGFloat(fontScaleRange.lowerBound)...CGFloat(fontScaleRange.upperBound),
                format: .magnification(fractionDigits: 1)
            )

            if model.hasTranscriptWords {
                HStack(spacing: 8) {
                    Text("Highlight spoken word")
                        .font(.inspectorLabel)
                        .foregroundStyle(.primary.opacity(0.82))

                    Spacer(minLength: 8)

                    Toggle(
                        "Highlight spoken word",
                        isOn: Binding(get: { model.subtitleStyle.highlightsSpokenWord }, set: {
                            var style = model.subtitleStyle
                            style.highlightsSpokenWord = $0
                            model.setSubtitleStyle(style)
                        })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }

            RecordingCaptionStyleControls(model: model)

            subtitleList

            Text("Enter splits a caption. Shift+Enter adds a line break. Backspace at the start merges with the previous caption.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!model.showsSubtitles)
        .opacity(model.showsSubtitles ? 1 : 0.48)
    }

    @ViewBuilder
    private var transcriptEditControls: some View {
        if model.hasTranscriptWords {
            StudioTranscriptEditPanel(model: model)

            if model.removableFillerWordCount > 0 || model.trimmableSilenceCount > 0 {
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    if model.removableFillerWordCount > 0 {
                        InspectorActionButton(
                            "Fillers (\(model.removableFillerWordCount))",
                            systemImage: "scissors"
                        ) {
                            model.removeFillerWords()
                        }
                        .help("Cut every filler word, like “um” and “uh”")
                    }

                    if model.trimmableSilenceCount > 0 {
                        InspectorActionButton(
                            "Silences (\(model.trimmableSilenceCount))",
                            systemImage: "waveform.badge.minus"
                        ) {
                            model.trimNarrationSilences()
                        }
                        .help("Trim long pauses in the narration")
                    }
                }
            }

            if model.trimmableSilenceCount > 0 {
                InspectorActionButton("Skip Silences (\(model.trimmableSilenceCount))", systemImage: "forward.end") {
                    model.skipNarrationSilences()
                }
                Text("Skipped sections stay dimmed in the timeline. Select one and press Delete to restore it.")
                    .font(.caption).foregroundStyle(.secondary)
                InspectorActionButton(
                    "Trim Silences (\(model.trimmableSilenceCount))",
                    systemImage: "waveform.badge.minus"
                ) {
                    model.trimNarrationSilences()
                }
            }

            Text("Click a word to jump there. Shift-click to select a passage, then cut it to remove that part of the video.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if model.canTranscribe {
                InspectorActionButton("Transcribe Again to Edit", systemImage: "waveform") {
                    model.transcribe()
                }
            }
            Text("This transcript has caption timings only. Use a model with word timestamps to cut video by selecting words.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitleList: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    let cues = model.subtitleCues
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        StudioSubtitleRow(
                            model: model,
                            cue: cue,
                            isActive: model.activeSubtitleCue?.id == cue.id
                        )
                        .id(cue.id)

                        if index < cues.count - 1 {
                            Divider()
                                .padding(.leading, 10)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
            .clipShape(shape)
            .onChange(of: model.captionEditorFocus) { _, focus in
                if let focus { proxy.scrollTo(focus.id, anchor: .center) }
            }
            .onChange(of: model.activeSubtitleCue?.id) { _, activeID in
                // Follow playback through the list, but never yank the list
                // around while the user is scrubbing or editing.
                guard let activeID, model.isPlaying else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    // MARK: Camera

    private var cameraControls: some View {
        InspectorFieldPair {
            InspectorSlider(
                "Size",
                value: $model.style.camera.size,
                range: 0.12...0.45,
                format: .percent()
            )
        } trailing: {
            InspectorSlider(
                "Rounding",
                value: $model.style.camera.roundness,
                range: 0.05...0.5,
                format: .percent()
            )
        }
        .help("Drag the camera directly on the canvas to place it")
        .disabled(!model.style.camera.isVisible)
        .opacity(model.style.camera.isVisible ? 1 : 0.48)
    }

    // MARK: Audio

    /// The round trip around tools that clean up speech but offer no API:
    /// write the cut's soundtrack out, run it through the tool, bring the
    /// result back in as the project's audio. Two buttons and a file chip -
    /// the explaining is left to tooltips.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if model.recordedAudioTracks.count > 1 {
                InspectorActionButton("Auto Balance Tracks", systemImage: "slider.horizontal.3") {
                    model.autoBalanceRecordedAudio()
                }
                .disabled(!model.canAutoBalanceRecordedAudio)
                .help("Set one static level for each recorded track; does not duck system audio")
            }

            // A silent recording has nothing to send out, but it can still
            // be given a soundtrack - so only the export half is withheld.
            if model.hasAudio {
                InspectorSlider("Volume", value: $model.audioVolume, range: 0...2, format: .percent())
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if model.hasAudio {
                    audioExportButton
                }

                InspectorActionButton(
                    model.hasRecordedAudio ? "Replace" : "Add",
                    systemImage: "waveform.badge.plus"
                ) {
                    pickReplacementAudio()
                }
                .help(
                    model.hasRecordedAudio
                        ? "Swap in an audio file, aligned to the start of the edited timeline"
                        : "Lay an audio file over this silent recording"
                )
            }

            if let replacement = model.replacementAudio {
                replacementChip(for: replacement)
            }

            if let message = model.replacementAudioError {
                InspectorHint(message, tint: .orange)
            }

            if let message = model.audioAnalysisError {
                Text(message)
                    .font(.inspectorLabel)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One button carrying the whole export state, so progress and results
    /// never cost the section an extra row. The format is asked for at export
    /// time, the same way video export asks for its options.
    @ViewBuilder
    private var audioExportButton: some View {
        switch model.audioExportState {
        case .idle:
            InspectorActionButton("Export…", systemImage: "arrow.down.circle") {
                isAudioExportOptionsPresented = true
            }
            .help("Export just the soundtrack of the current cut")
            .popover(isPresented: $isAudioExportOptionsPresented, arrowEdge: .bottom) {
                StudioAudioExportOptions(format: $model.audioExportFormat) {
                    isAudioExportOptionsPresented = false
                    model.exportAudio()
                }
            }
        case .exporting(let progress):
            audioExportChrome(help: "Cancel") {
                model.cancelAudioExport()
            } label: {
                StudioProgressRing(progress: progress, size: 12)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.inspectorValue.monospacedDigit())
                    .contentTransition(.numericText())
            }
        case .finished(let url):
            audioExportChrome(help: "Reveal \(url.lastPathComponent) in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                Text("Reveal")
                    .font(.inspectorValue)
            }
        case .failed(let message):
            audioExportChrome(help: message) {
                model.exportAudio()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Retry")
                    .font(.inspectorValue)
            }
        }
    }

    /// Matches `InspectorActionButton`'s chrome for the export button's
    /// non-idle states, which carry richer content than a symbol and a title.
    private func audioExportChrome<Label: View>(
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .inspectorField()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func replacementChip(for replacement: RecordingReplacementAudio) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text(replacement.displayName)
                .font(.inspectorValue)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let drift = model.replacementAudioDrift {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .help(
                        drift > 0
                            ? "Runs \(Self.spanText(drift)) longer than the cut - the tail is dropped"
                            : "Runs \(Self.spanText(-drift)) shorter than the cut - the end plays silent"
                    )
            }

            Text(Self.clockText(replacement.duration))
                .font(.inspectorLabel.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorField()
        .help(replacement.displayName)
    }

    private func pickReplacementAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingAudioFormat.importContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Replacement Audio"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.replaceAudio(with: url)
        }
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Short spans read better in seconds than as 0:00 timecode.
    private static func spanText(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return value < 60 ? String(format: "%.1fs", value) : clockText(value)
    }

    // MARK: Summaries

    private var zoomSummary: String? {
        guard model.zoomEnabled else { return nil }
        let count = model.zoomCues.count
        return count == 1 ? "1 zoom" : "\(count) zooms"
    }

    private var transcriptionSummary: String? {
        switch model.transcriptionState {
        case .transcribing:
            return "Transcribing…"
        case .failed:
            return "Failed"
        case .idle:
            guard model.hasSubtitles, model.showsSubtitles else { return nil }
            let count = model.subtitleCues.count
            return count == 1 ? "1 line" : "\(count) lines"
        }
    }

    private var audioSummary: String? {
        if let replacement = model.replacementAudio {
            return replacement.displayName
        }
        guard model.hasAudio, abs(model.audioVolume - 1) > 0.001 else { return nil }
        return "Volume \(InspectorValueFormat.percent().displayString(for: model.audioVolume))"
    }

    // MARK: Helpers

    private var usesDefaultLayout: Bool {
        abs(model.style.padding - 0.06) < 0.0001
            && abs(model.style.cornerRadius - 0.02) < 0.0001
            && abs(model.style.shadow - 0.45) < 0.0001
    }

    private var sidebarBackground: Color {
        InspectorControlPalette.panelBackground(for: colorScheme)
    }

    private var sectionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .snappy(duration: 0.18)
    }

    private func expansionBinding(for section: StudioInspectorSection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { setExpanded(section, $0, animated: false) }
        )
    }

    private func setExpanded(_ section: StudioInspectorSection, _ isExpanded: Bool, animated: Bool = true) {
        withAnimation(animated ? sectionAnimation : nil) {
            if isExpanded {
                expandedSections.insert(section)
            } else {
                expandedSections.remove(section)
            }
        }
        StudioInspectorSectionState.save(expandedSections)
    }

    /// Header switch for a section with an on/off state. Turning one on
    /// opens its controls; turning it off folds them away.
    private func sectionToggle(
        _ title: String,
        isOn: Binding<Bool>,
        section: StudioInspectorSection
    ) -> some View {
        InspectorToggle(
            title,
            isOn: Binding(
                get: { isOn.wrappedValue },
                set: { value in
                    isOn.wrappedValue = value
                    setExpanded(section, value)
                }
            )
        )
    }
}

/// Collapsed-header readouts for the Studio inspector.
private enum StudioInspectorSummary {
    static func background(
        _ style: AnnotationBackgroundStyle,
        aspect: ExportAspectPreset
    ) -> String? {
        let fill: String?
        switch style {
        case .none:
            fill = nil
        case .solid(let color):
            fill = color.title
        case .gradient(let gradient):
            fill = gradient.title
        case .customWallpaper(let wallpaper):
            fill = wallpaper.title
        }
        let ratio = aspect == .original ? nil : aspect.title
        let parts = [fill, ratio].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func keystrokePlacement(_ placement: RecordingKeystrokePlacement) -> String {
        switch placement {
        case .topLeft: "Top left"
        case .topCenter: "Top"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomCenter: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }
}

/// Asks for the soundtrack format at export time.
private struct StudioAudioExportOptions: View {
    @Binding var format: RecordingAudioFormat
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Text("Export Audio")
                .font(.inspectorSectionHeader)
                .padding(.bottom, 2)

            InspectorSegmented(
                options: RecordingAudioFormat.allCases,
                isSelected: { $0 == format },
                onTap: { format = $0 },
                label: { Text($0.title).font(.inspectorSegment) }
            )

            InspectorHint(
                format == .m4a
                    ? "Compact AAC audio, accepted by most enhancement tools."
                    : "Uncompressed, for tools that accept nothing else."
            )

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export", action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(InspectorMetrics.horizontalPadding)
        .frame(width: 240)
        .presentationBackground(InspectorControlPalette.panelBackground(for: colorScheme))
    }
}
