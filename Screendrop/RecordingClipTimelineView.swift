//
//  RecordingClipTimelineView.swift
//  Screendrop
//
//  Compact, segment-aware Studio video lane. The AppKit control gives mouse
//  tracking, contextual split locations, cursor control, and edge trimming
//  pixel-level precision while SwiftUI owns the surrounding editor chrome.
//

import AppKit
import SwiftUI

struct RecordingClipTimelineView: NSViewRepresentable {
    @Binding var selectedClipID: UUID?
    let playheadTime: TimeInterval

    let timeline: RecordingClipTimeline
    let skippedClipIDs: Set<UUID>
    let sourceDuration: TimeInterval
    let thumbnails: RecordingTimelineThumbnailStore
    let onSelect: (UUID) -> Void
    let onHover: (TimeInterval?) -> Void
    let onSplit: (TimeInterval) -> Void
    let onDelete: () -> Void
    let onRemoveSkipped: () -> Void
    let onTrim: (RecordingClipSegment) -> Void
    let onDisplayTimelineChange: (RecordingClipTimeline?) -> Void
    /// Pinch or ⌘-scroll over the lane: `(factor, anchor editor time)`. The
    /// anchor is the time under the pointer, which the caller keeps pinned to
    /// its current screen position while the scale changes.
    let onZoom: (Double, TimeInterval) -> Void
    /// Arrow-key nudge of the playhead by a signed number of seconds.
    let onStep: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedClipID: $selectedClipID,
            onSelect: onSelect,
            onHover: onHover,
            onSplit: onSplit,
            onDelete: onDelete,
            onRemoveSkipped: onRemoveSkipped,
            onTrim: onTrim,
            onDisplayTimelineChange: onDisplayTimelineChange,
            onZoom: onZoom,
            onStep: onStep
        )
    }

    func makeNSView(context: Context) -> RecordingClipTimelineControl {
        let view = RecordingClipTimelineControl()
        context.coordinator.connect(to: view)
        return view
    }

    func updateNSView(_ nsView: RecordingClipTimelineControl, context: Context) {
        context.coordinator.updateCallbacks(
            onSelect: onSelect,
            onHover: onHover,
            onSplit: onSplit,
            onDelete: onDelete,
            onRemoveSkipped: onRemoveSkipped,
            onTrim: onTrim,
            onDisplayTimelineChange: onDisplayTimelineChange,
            onZoom: onZoom,
            onStep: onStep
        )
        nsView.skippedClipIDs = skippedClipIDs
        nsView.update(
            timeline: timeline,
            sourceDuration: sourceDuration,
            thumbnails: thumbnails,
            selectedClipID: selectedClipID,
            playheadTime: playheadTime
        )
    }

    final class Coordinator {
        @Binding private var selectedClipID: UUID?

        private var onSelect: (UUID) -> Void
        private var onHover: (TimeInterval?) -> Void
        private var onSplit: (TimeInterval) -> Void
        private var onDelete: () -> Void
        private var onRemoveSkipped: () -> Void
        private var onTrim: (RecordingClipSegment) -> Void
        private var onDisplayTimelineChange: (RecordingClipTimeline?) -> Void
        private var onZoom: (Double, TimeInterval) -> Void
        private var onStep: (TimeInterval) -> Void

        init(
            selectedClipID: Binding<UUID?>,
            onSelect: @escaping (UUID) -> Void,
            onHover: @escaping (TimeInterval?) -> Void,
            onSplit: @escaping (TimeInterval) -> Void,
            onDelete: @escaping () -> Void,
            onRemoveSkipped: @escaping () -> Void,
            onTrim: @escaping (RecordingClipSegment) -> Void,
            onDisplayTimelineChange: @escaping (RecordingClipTimeline?) -> Void,
            onZoom: @escaping (Double, TimeInterval) -> Void,
            onStep: @escaping (TimeInterval) -> Void
        ) {
            _selectedClipID = selectedClipID
            self.onSelect = onSelect
            self.onHover = onHover
            self.onSplit = onSplit
            self.onDelete = onDelete
            self.onRemoveSkipped = onRemoveSkipped
            self.onTrim = onTrim
            self.onDisplayTimelineChange = onDisplayTimelineChange
            self.onZoom = onZoom
            self.onStep = onStep
        }

        func updateCallbacks(
            onSelect: @escaping (UUID) -> Void,
            onHover: @escaping (TimeInterval?) -> Void,
            onSplit: @escaping (TimeInterval) -> Void,
            onDelete: @escaping () -> Void,
            onRemoveSkipped: @escaping () -> Void,
            onTrim: @escaping (RecordingClipSegment) -> Void,
            onDisplayTimelineChange: @escaping (RecordingClipTimeline?) -> Void,
            onZoom: @escaping (Double, TimeInterval) -> Void,
            onStep: @escaping (TimeInterval) -> Void
        ) {
            self.onSelect = onSelect
            self.onHover = onHover
            self.onSplit = onSplit
            self.onDelete = onDelete
            self.onRemoveSkipped = onRemoveSkipped
            self.onTrim = onTrim
            self.onDisplayTimelineChange = onDisplayTimelineChange
            self.onZoom = onZoom
            self.onStep = onStep
        }

        func connect(to view: RecordingClipTimelineControl) {
            view.selectionDidChange = { [weak self] id in
                self?.selectedClipID = id
                self?.onSelect(id)
            }
            view.hoverTimeDidChange = { [weak self] time in
                self?.onHover(time)
            }
            view.splitRequested = { [weak self] time in
                self?.onSplit(time)
            }
            view.deleteRequested = { [weak self] in
                self?.onDelete()
            }
            view.removeSkippedRequested = { [weak self] in
                self?.onRemoveSkipped()
            }
            view.trimDidCommit = { [weak self] clip in
                self?.onTrim(clip)
            }
            view.displayTimelineDidChange = { [weak self] timeline in
                Task { @MainActor [weak self] in
                    self?.onDisplayTimelineChange(timeline)
                }
            }
            view.zoomRequested = { [weak self] factor, anchorTime in
                self?.onZoom(factor, anchorTime)
            }
            view.stepRequested = { [weak self] seconds in
                self?.onStep(seconds)
            }
        }
    }
}

final class RecordingClipTimelineControl: NSView {
    var skippedClipIDs: Set<UUID> = []
    var selectionDidChange: ((UUID) -> Void)?
    var hoverTimeDidChange: ((TimeInterval?) -> Void)?
    var splitRequested: ((TimeInterval) -> Void)?
    var deleteRequested: (() -> Void)?
    var removeSkippedRequested: (() -> Void)?
    var trimDidCommit: ((RecordingClipSegment) -> Void)?
    var displayTimelineDidChange: ((RecordingClipTimeline?) -> Void)?
    var zoomRequested: ((Double, TimeInterval) -> Void)?
    var stepRequested: ((TimeInterval) -> Void)?

    private enum Edge: Equatable {
        case leading
        case trailing
    }

    private enum DragTarget {
        case selectOnly
        case trim(clipID: UUID, edge: Edge)
    }

    private struct TrimReveal {
        let clipID: UUID
        let displayTimeline: RecordingClipTimeline
        let availableClip: RecordingClipSegment
    }

    private struct EdgeHit {
        let clipID: UUID
        let edge: Edge
        let distance: CGFloat
    }

    private struct TrimPreviewGeometry {
        let clipID: UUID
        let originalRect: CGRect
        let keptRect: CGRect
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    private enum Metrics {
        static let trackRadius: CGFloat = 10
        static let trackInset: CGFloat = 2
        static let clipRadius = trackRadius - trackInset
        static let selectionPadding: CGFloat = 3
        static let splitGap: CGFloat = trackInset * 2
        static let handleHitWidth: CGFloat = 10
        static let selectionHandleInset: CGFloat = 5
        static let selectionHandleGrooveWidth: CGFloat = 3
        static let selectionHandleGrooveHeight: CGFloat = 18
        static let thumbnailWidth: CGFloat = 58
        /// Scroll distance that equals one doubling of the timeline scale
        /// under ⌘-scroll.
        static let zoomScrollPointsPerDoubling: CGFloat = 220
        /// Arrow-key steps: one frame at 30 fps, or a second with Shift.
        static let frameStep: TimeInterval = 1.0 / 30.0
        static let coarseStep: TimeInterval = 1
    }

    private var timeline = RecordingClipTimeline(segments: [])
    private var sourceDuration: TimeInterval = 0
    private var thumbnails: RecordingTimelineThumbnailStore?
    private var selectedClipID: UUID?
    private var playheadTime: TimeInterval = 0

    private var trackingArea: NSTrackingArea?
    private var hoverTime: TimeInterval?
    private var hoveredClipID: UUID?
    private var hoveredEdge: EdgeHit?
    private var dragTarget: DragTarget?
    private var dragStartPoint: CGPoint?
    private var dragStartTimeline: RecordingClipTimeline?
    private var dragStartClip: RecordingClipSegment?
    private var trimReveal: TrimReveal?
    private var publishedDisplayTimeline: RecordingClipTimeline?
    private var contextTime: TimeInterval?
    private var contextClipID: UUID?
    private var lastHoverCallbackTimestamp: TimeInterval = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        thumbnails: RecordingTimelineThumbnailStore,
        selectedClipID: UUID?,
        playheadTime: TimeInterval
    ) {
        if dragTarget == nil {
            self.timeline = timeline
            validateTrimReveal(for: timeline, selectedClipID: selectedClipID)
            publishDisplayTimelineIfNeeded()
        }
        self.sourceDuration = sourceDuration
        if self.thumbnails !== thumbnails {
            self.thumbnails = thumbnails
            // Newly sampled tiles arrive outside SwiftUI's update cycle, so
            // the lane refreshes itself rather than invalidating the editor.
            thumbnails.onChange = { [weak self] in
                self?.needsDisplay = true
            }
        }
        self.selectedClipID = selectedClipID
        self.playheadTime = min(max(playheadTime, 0), max(timeline.duration, 0))
        needsDisplay = true
    }

    private func validateTrimReveal(
        for timeline: RecordingClipTimeline,
        selectedClipID: UUID?
    ) {
        guard let reveal = trimReveal else { return }
        guard selectedClipID == reveal.clipID,
              timeline.segments.map(\.id) == reveal.displayTimeline.segments.map(\.id),
              let clip = timeline.segments.first(where: { $0.id == reveal.clipID }),
              clip.speed == reveal.availableClip.speed,
              clip.sourceStart >= reveal.availableClip.sourceStart,
              clip.sourceEnd <= reveal.availableClip.sourceEnd else {
            trimReveal = nil
            publishDisplayTimelineIfNeeded()
            return
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .mouseMoved,
                .mouseEnteredAndExited,
                .inVisibleRect,
                .cursorUpdate
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard timelineRect.width > 2, timelineRect.height > 2 else { return }

        drawTrack()
        drawSelectionChrome()
        drawClips(in: dirtyRect)
        drawTrimOverlay()
        drawSelectionGrooves()
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updateHover(with: event, forceCallback: true)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event, forceCallback: false)
    }

    override func mouseExited(with event: NSEvent) {
        guard dragTarget == nil else { return }
        clearHover()
    }

    override func cursorUpdate(with event: NSEvent) {
        if hoveredEdge != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard timeline.duration > 0 else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard timelineRect.contains(point) else { return }
        let time = editorTime(forX: point.x)
        let edgeHit = edgeHit(at: point)
        let targetClipID: UUID
        if let edgeHit {
            targetClipID = edgeHit.clipID
        } else if let location = timeline.location(at: time) {
            targetClipID = location.segmentID
        } else {
            return
        }

        if selectedClipID != targetClipID {
            trimReveal = nil
            publishDisplayTimelineIfNeeded()
            selectedClipID = targetClipID
            selectionDidChange?(targetClipID)
        }

        dragStartPoint = point
        dragStartTimeline = timeline
        if let hit = edgeHit,
           let clip = timeline.segments.first(where: { $0.id == hit.clipID }) {
            if trimReveal?.clipID != hit.clipID {
                trimReveal = TrimReveal(
                    clipID: hit.clipID,
                    displayTimeline: timeline,
                    availableClip: clip
                )
            }
            dragTarget = .trim(clipID: hit.clipID, edge: hit.edge)
            dragStartClip = clip
        } else {
            dragTarget = .selectOnly
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragTarget else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch dragTarget {
        case .selectOnly:
            return
        case .trim(let clipID, let edge):
            updateTrim(clipID: clipID, edge: edge, point: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .trim(let clipID, _) = dragTarget,
           let original = dragStartClip,
           let replacement = timeline.segments.first(where: { $0.id == clipID }),
           replacement != original {
            trimDidCommit?(replacement)
        }

        dragTarget = nil
        dragStartPoint = nil
        dragStartTimeline = nil
        dragStartClip = nil
        updateHover(with: event, forceCallback: true)
        needsDisplay = true
    }

    /// ⌘-scroll zooms around the pointer; a plain scroll is left to the
    /// enclosing scroll view so two-finger swipes still pan the timeline.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), zoomRequested != nil else {
            super.scrollWheel(with: event)
            return
        }
        let rawDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 16
        guard abs(rawDelta) > 0.001 else { return }
        let factor = pow(2, Double(rawDelta / Metrics.zoomScrollPointsPerDoubling))
        zoomRequested?(factor, anchorTime(for: event))
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        zoomRequested?(1 + Double(event.magnification), anchorTime(for: event))
    }

    private func anchorTime(for event: NSEvent) -> TimeInterval {
        displayEditorTime(forX: convert(event.locationInWindow, from: nil).x)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if modifiers.isEmpty, characters == "c", let hoverTime, hoveredClipID != nil {
            splitRequested?(hoverTime)
            return
        }
        if modifiers.subtracting([.shift, .numericPad, .function]).isEmpty,
           event.keyCode == 123 || event.keyCode == 124 {
            let magnitude = modifiers.contains(.shift) ? Metrics.coarseStep : Metrics.frameStep
            stepRequested?(event.keyCode == 123 ? -magnitude : magnitude)
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            deleteRequested?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard timelineRect.contains(point), timeline.duration > 0 else { return nil }
        let time = editorTime(forX: point.x)
        guard let location = timeline.location(at: time) else { return nil }

        contextTime = time
        contextClipID = location.segmentID
        selectedClipID = location.segmentID
        selectionDidChange?(location.segmentID)

        let menu = NSMenu()
        let split = NSMenuItem(
            title: "Split Clip Here",
            action: #selector(splitFromContextMenu),
            keyEquivalent: ""
        )
        split.isEnabled = !skippedClipIDs.contains(location.segmentID)
        split.target = self
        split.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        menu.addItem(split)

        menu.addItem(.separator())

        let delete = NSMenuItem(
            title: skippedClipIDs.contains(location.segmentID) ? "Restore Clip" : "Skip Clip",
            action: #selector(deleteFromContextMenu),
            keyEquivalent: ""
        )
        delete.target = self
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        delete.isEnabled = skippedClipIDs.contains(location.segmentID) || timeline.segments.count - skippedClipIDs.count > 1
        menu.addItem(delete)

        if skippedClipIDs.contains(location.segmentID) {
            let remove = NSMenuItem(
                title: "Remove Skipped Clip",
                action: #selector(removeSkippedFromContextMenu),
                keyEquivalent: ""
            )
            remove.target = self
            remove.image = NSImage(systemSymbolName: "xmark.bin", accessibilityDescription: nil)
            menu.addItem(remove)
        }
        return menu
    }

    @objc private func splitFromContextMenu() {
        guard let contextTime else { return }
        splitRequested?(contextTime)
    }

    @objc private func removeSkippedFromContextMenu() {
        guard let contextClipID else { return }
        if selectedClipID != contextClipID {
            selectedClipID = contextClipID
            selectionDidChange?(contextClipID)
        }
        removeSkippedRequested?()
    }

    @objc private func deleteFromContextMenu() {
        guard let contextClipID else { return }
        if selectedClipID != contextClipID {
            selectedClipID = contextClipID
            selectionDidChange?(contextClipID)
        }
        deleteRequested?()
    }

    private var timelineRect: CGRect {
        bounds.insetBy(dx: 0.5, dy: 0.5)
    }

    private func updateHover(with event: NSEvent, forceCallback: Bool) {
        guard dragTarget == nil, timeline.duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard timelineRect.contains(point) else {
            clearHover()
            return
        }

        let time = editorTime(forX: point.x)
        hoverTime = time
        hoveredClipID = timeline.location(at: time)?.segmentID
        hoveredEdge = edgeHit(at: point)

        if forceCallback || event.timestamp - lastHoverCallbackTimestamp >= 1.0 / 60.0 {
            lastHoverCallbackTimestamp = event.timestamp
            hoverTimeDidChange?(time)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func clearHover() {
        guard hoverTime != nil || hoveredClipID != nil || hoveredEdge != nil else { return }
        hoverTime = nil
        hoveredClipID = nil
        hoveredEdge = nil
        hoverTimeDidChange?(nil)
        needsDisplay = true
    }

    private func updateTrim(clipID: UUID, edge: Edge, point: CGPoint) {
        guard let dragStartPoint,
              let startTimeline = dragStartTimeline,
              let original = dragStartClip,
              startTimeline.segments.contains(where: { $0.id == clipID }) else {
            return
        }

        let delta: TimeInterval
        if let reveal = trimReveal,
           reveal.clipID == clipID,
           let revealRect = clipRect(for: clipID, in: reveal.displayTimeline) {
            let pointsPerSourceSecond = revealRect.width / CGFloat(reveal.availableClip.duration)
            delta = Double(
                (point.x - dragStartPoint.x) / max(pointsPerSourceSecond, 0.000_001)
            )
        } else {
            // sourceStart/sourceEnd are in source-space, so editor drag time
            // must include this clip's playback speed.
            let editorDelta = Double((point.x - dragStartPoint.x) / max(timelineRect.width, 1))
                * startTimeline.duration
            delta = editorDelta * original.speed
        }
        // Skipped neighbours don't stop the drag; the trim eats into them.
        let kept = startTimeline.segments.filter { !skippedClipIDs.contains($0.id) }
        let skipped = startTimeline.segments.filter { skippedClipIDs.contains($0.id) }
        let previousEnd = kept.last { $0.sourceEnd <= original.sourceStart }?.sourceEnd ?? 0
        let nextStart = kept.first { $0.sourceStart >= original.sourceEnd }?.sourceStart ?? sourceDuration
        var replacement = original

        switch edge {
        case .leading:
            replacement.sourceStart = min(
                max(original.sourceStart + delta, previousEnd),
                original.sourceEnd - RecordingClipSegment.minimumDuration
            )
        case .trailing:
            replacement.sourceEnd = max(
                original.sourceStart + RecordingClipSegment.minimumDuration,
                min(original.sourceEnd + delta, nextStart)
            )
        }
        timeline = RecordingSkippedClips(playable: RecordingClipTimeline(segments: kept), skipped: skipped)
            .trimming(replacement).display
        publishDisplayTimelineIfNeeded()
    }

    private func edgeHit(at point: CGPoint) -> EdgeHit? {
        let trimPreview = trimPreviewGeometry()
        let candidates = timeline.segments.flatMap { clip -> [EdgeHit] in
            let rect = trimPreview?.clipID == clip.id
                ? trimPreview?.keptRect
                : clipRect(for: clip.id)
            guard !skippedClipIDs.contains(clip.id), let rect else { return [] }
            return [
                EdgeHit(
                    clipID: clip.id,
                    edge: .leading,
                    distance: abs(point.x - rect.minX)
                ),
                EdgeHit(
                    clipID: clip.id,
                    edge: .trailing,
                    distance: abs(point.x - rect.maxX)
                )
            ]
        }
        .filter { $0.distance <= Metrics.handleHitWidth }
        .sorted { lhs, rhs in
            let lhsIsSelected = lhs.clipID == selectedClipID
            let rhsIsSelected = rhs.clipID == selectedClipID
            if lhsIsSelected != rhsIsSelected {
                return lhsIsSelected
            }
            return lhs.distance < rhs.distance
        }

        return candidates.first
    }

    private var displayTimeline: RecordingClipTimeline {
        activeDisplayTimeline ?? timeline
    }

    private var activeDisplayTimeline: RecordingClipTimeline? {
        trimPreviewGeometry() == nil ? nil : trimReveal?.displayTimeline
    }

    private func publishDisplayTimelineIfNeeded() {
        let next = activeDisplayTimeline
        guard next != publishedDisplayTimeline else { return }
        publishedDisplayTimeline = next
        displayTimelineDidChange?(next)
    }

    private func clipRect(
        for clipID: UUID,
        in displayedTimeline: RecordingClipTimeline? = nil
    ) -> CGRect? {
        let displayedTimeline = displayedTimeline ?? timeline
        guard let index = displayedTimeline.segments.firstIndex(where: { $0.id == clipID }),
              let range = displayedTimeline.editorRange(for: clipID),
              displayedTimeline.duration > 0 else { return nil }
        let rawMinX = xPosition(for: range.lowerBound, in: displayedTimeline)
        let rawMaxX = xPosition(for: range.upperBound, in: displayedTimeline)
        let leadingInset = index == 0
            ? Metrics.trackInset
            : Metrics.splitGap / 2
        let trailingInset = index == displayedTimeline.segments.count - 1
            ? Metrics.trackInset
            : Metrics.splitGap / 2
        let minX = rawMinX + leadingInset
        let maxX = rawMaxX - trailingInset
        return CGRect(
            x: minX,
            y: timelineRect.minY + Metrics.trackInset,
            width: max(1, maxX - minX),
            height: timelineRect.height - Metrics.trackInset * 2
        )
    }

    private func xPosition(for editorTime: TimeInterval) -> CGFloat {
        guard let displayedTimeline = activeDisplayTimeline else {
            return xPosition(for: editorTime, in: timeline)
        }
        let sourceTime = timeline.sourceTime(at: editorTime)
        guard let displayedTime = displayedTimeline.editorTime(forSourceTime: sourceTime) else {
            return xPosition(for: editorTime, in: timeline)
        }
        return xPosition(for: displayedTime, in: displayedTimeline)
    }

    private func xPosition(
        for editorTime: TimeInterval,
        in displayedTimeline: RecordingClipTimeline
    ) -> CGFloat {
        guard displayedTimeline.duration > 0 else { return timelineRect.minX }
        let fraction = min(max(editorTime / displayedTimeline.duration, 0), 1)
        return timelineRect.minX + CGFloat(fraction) * timelineRect.width
    }

    private func editorTime(forX x: CGFloat) -> TimeInterval {
        let displayedTime = displayEditorTime(forX: x)
        guard let displayedTimeline = activeDisplayTimeline else { return displayedTime }
        guard let displayedLocation = displayedTimeline.location(at: displayedTime) else {
            return 0
        }
        if let editorTime = timeline.editorTime(forSourceTime: displayedLocation.sourceTime) {
            return editorTime
        }
        guard let keptClip = timeline.segments.first(where: {
            $0.id == displayedLocation.segmentID
        }), let keptRange = timeline.editorRange(for: keptClip.id) else {
            return displayedLocation.sourceTime < (timeline.segments.first?.sourceStart ?? 0)
                ? 0
                : timeline.duration
        }
        return displayedLocation.sourceTime < keptClip.sourceStart
            ? keptRange.lowerBound
            : keptRange.upperBound
    }

    private func displayEditorTime(forX x: CGFloat) -> TimeInterval {
        let displayedTimeline = displayTimeline
        guard displayedTimeline.duration > 0, timelineRect.width > 0 else { return 0 }
        let fraction = min(max((x - timelineRect.minX) / timelineRect.width, 0), 1)
        return Double(fraction) * displayedTimeline.duration
    }

    private func drawTrack() {
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        NSBezierPath(
            roundedRect: timelineRect,
            xRadius: Metrics.trackRadius,
            yRadius: Metrics.trackRadius
        ).fill()
    }

    private func drawClips(in dirtyRect: CGRect) {
        let displayedTimeline = displayTimeline
        for clip in displayedTimeline.segments {
            guard let rect = clipRect(for: clip.id, in: displayedTimeline),
                  rect.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(
                roundedRect: rect,
                xRadius: clipRadius(for: rect),
                yRadius: clipRadius(for: rect)
            ).addClip()
            drawThumbnails(in: rect, clip: clip, dirtyRect: dirtyRect)
            NSColor.black.withAlphaComponent(0.08).setFill()
            rect.intersection(dirtyRect).fill()
            if skippedClipIDs.contains(clip.id) {
                NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
                rect.fill()
                let label = "Skipped" as NSString
                label.draw(in: rect.insetBy(dx: 6, dy: 17), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawTrimOverlay() {
        guard let preview = trimPreviewGeometry() else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            roundedRect: preview.originalRect,
            xRadius: clipRadius(for: preview.originalRect),
            yRadius: clipRadius(for: preview.originalRect)
        ).addClip()
        NSColor.black.withAlphaComponent(0.62).setFill()
        if preview.keptRect.minX > preview.originalRect.minX {
            CGRect(
                x: preview.originalRect.minX,
                y: preview.originalRect.minY,
                width: preview.keptRect.minX - preview.originalRect.minX,
                height: preview.originalRect.height
            ).fill()
        }
        if preview.keptRect.maxX < preview.originalRect.maxX {
            CGRect(
                x: preview.keptRect.maxX,
                y: preview.originalRect.minY,
                width: preview.originalRect.maxX - preview.keptRect.maxX,
                height: preview.originalRect.height
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        drawTrimRangeLabel(
            from: preview.editorStart,
            to: preview.editorEnd,
            in: preview.keptRect
        )
    }

    private func trimPreviewGeometry() -> TrimPreviewGeometry? {
        guard let reveal = trimReveal,
              reveal.availableClip.duration > 0,
              let replacement = timeline.segments.first(where: { $0.id == reveal.clipID }),
              replacement.sourceStart >= reveal.availableClip.sourceStart,
              replacement.sourceEnd <= reveal.availableClip.sourceEnd,
              replacement.sourceStart > reveal.availableClip.sourceStart + 0.000_001
                || replacement.sourceEnd < reveal.availableClip.sourceEnd - 0.000_001,
              let editorRange = reveal.displayTimeline.editorRange(for: reveal.clipID),
              let originalRect = clipRect(
                for: reveal.clipID,
                in: reveal.displayTimeline
              ) else {
            return nil
        }

        let leadingFraction = CGFloat(
            (replacement.sourceStart - reveal.availableClip.sourceStart)
                / reveal.availableClip.duration
        )
        let trailingFraction = CGFloat(
            (replacement.sourceEnd - reveal.availableClip.sourceStart)
                / reveal.availableClip.duration
        )
        let keptMinX = originalRect.minX + leadingFraction * originalRect.width
        let keptMaxX = originalRect.minX + trailingFraction * originalRect.width
        let keptRect = CGRect(
            x: keptMinX,
            y: originalRect.minY,
            width: max(1, keptMaxX - keptMinX),
            height: originalRect.height
        )
        let editorStart = editorRange.lowerBound
            + (replacement.sourceStart - reveal.availableClip.sourceStart)
                / reveal.availableClip.speed
        let editorEnd = editorRange.lowerBound
            + (replacement.sourceEnd - reveal.availableClip.sourceStart)
                / reveal.availableClip.speed
        return TrimPreviewGeometry(
            clipID: reveal.clipID,
            originalRect: originalRect,
            keptRect: keptRect,
            editorStart: editorStart,
            editorEnd: editorEnd
        )
    }

    private func drawTrimRangeLabel(
        from start: TimeInterval,
        to end: TimeInterval,
        in rect: CGRect
    ) {
        let label = "\(trimTimeLabel(start))  to  \(trimTimeLabel(end))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4
        let pillWidth = min(textSize.width + horizontalPadding * 2, max(rect.width - 8, 0))
        guard pillWidth >= 58, rect.height >= textSize.height + verticalPadding * 2 else { return }

        let pillRect = CGRect(
            x: min(
                max(rect.midX - pillWidth / 2, rect.minX + 4),
                rect.maxX - pillWidth - 4
            ),
            y: rect.minY + 5,
            width: pillWidth,
            height: textSize.height + verticalPadding * 2
        )
        NSColor.black.withAlphaComponent(0.74).setFill()
        NSBezierPath(
            roundedRect: pillRect,
            xRadius: pillRect.height / 2,
            yRadius: pillRect.height / 2
        ).fill()
        label.draw(
            at: CGPoint(
                x: pillRect.midX - textSize.width / 2,
                y: pillRect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func trimTimeLabel(_ time: TimeInterval) -> String {
        let safeTime = max(0, time.isFinite ? time : 0)
        let minutes = Int(safeTime) / 60
        let seconds = safeTime - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    private func drawThumbnails(in rect: CGRect, clip: RecordingClipSegment, dirtyRect: CGRect) {
        // The striped placeholder stays underneath, so tiles still being
        // sampled read as "loading" rather than as holes in the strip.
        drawPlaceholder(in: rect, dirtyRect: dirtyRect)
        guard let thumbnails, clip.duration > 0, rect.width > 0 else { return }

        // Tiles live on the store's source-time grid rather than on a pixel
        // grid of this rect: that keeps a tile anchored to the same moment
        // while the lane is zoomed or the clip is trimmed, instead of the whole
        // strip re-flowing on every scale change.
        let pointsPerSourceSecond = rect.width / CGFloat(clip.duration)
        guard pointsPerSourceSecond > 0 else { return }
        let grid = thumbnails.grid(
            forTargetSpan: Double(Metrics.thumbnailWidth / pointsPerSourceSecond)
        )
        guard grid.spacing > 0 else { return }

        let visible = rect.intersection(dirtyRect)
        guard !visible.isEmpty else { return }
        let startTime = clip.sourceStart
            + Double((visible.minX - rect.minX) / pointsPerSourceSecond)
        let endTime = clip.sourceStart
            + Double((visible.maxX - rect.minX) / pointsPerSourceSecond)
        let firstIndex = max(0, Int(floor(startTime / grid.spacing)))
        let lastIndex = max(firstIndex, Int(floor(min(endTime, clip.sourceEnd) / grid.spacing)))

        for index in firstIndex...lastIndex {
            let tileStart = max(Double(index) * grid.spacing, clip.sourceStart)
            let tileEnd = min(Double(index + 1) * grid.spacing, clip.sourceEnd)
            guard tileEnd > tileStart,
                  let image = thumbnails.image(in: grid, tileIndex: index) else { continue }
            let minX = rect.minX
                + CGFloat(tileStart - clip.sourceStart) * pointsPerSourceSecond
            let maxX = rect.minX
                + CGFloat(tileEnd - clip.sourceStart) * pointsPerSourceSecond
            draw(image: image, filling: CGRect(
                x: minX,
                y: rect.minY,
                width: ceil(maxX - minX),
                height: rect.height
            ))
        }
    }

    /// Only the tiles the current redraw actually touches. A zoomed lane can
    /// be tens of thousands of points wide, so drawing every tile on every
    /// scroll step would be wasted work.
    private func tileIndices(
        in rect: CGRect,
        tileWidth: CGFloat,
        dirtyRect: CGRect
    ) -> Range<Int> {
        guard tileWidth > 0 else { return 0..<0 }
        let count = max(1, Int((rect.width / tileWidth).rounded()))
        let first = max(0, Int(floor((dirtyRect.minX - rect.minX) / tileWidth)))
        let last = min(count, Int(ceil((dirtyRect.maxX - rect.minX) / tileWidth)) + 1)
        guard first < last else { return 0..<0 }
        return first..<last
    }

    private func drawPlaceholder(in rect: CGRect, dirtyRect: CGRect) {
        let count = max(3, Int(rect.width / 42))
        let width = rect.width / CGFloat(count)
        for index in tileIndices(in: rect, tileWidth: width, dirtyRect: dirtyRect) {
            NSColor.labelColor.withAlphaComponent(0.07 + CGFloat(index % 3) * 0.025).setFill()
            CGRect(
                x: rect.minX + CGFloat(index) * width,
                y: rect.minY,
                width: ceil(width),
                height: rect.height
            ).fill()
        }
    }

    private func draw(image: NSImage, filling rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let imageAspect = image.size.width / image.size.height
        let rectAspect = rect.width / rect.height
        let sourceRect: CGRect
        if imageAspect > rectAspect {
            let width = image.size.height * rectAspect
            sourceRect = CGRect(
                x: (image.size.width - width) / 2,
                y: 0,
                width: width,
                height: image.size.height
            )
        } else {
            let height = image.size.width / rectAspect
            sourceRect = CGRect(
                x: 0,
                y: (image.size.height - height) / 2,
                width: image.size.width,
                height: height
            )
        }
        image.draw(
            in: rect,
            from: sourceRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawHoverSkimmer() {
        guard let hoverTime, dragTarget == nil else { return }
        let x = xPosition(for: hoverTime)
        NSColor.controlAccentColor.withAlphaComponent(0.42).setFill()
        CGRect(x: x - 0.5, y: timelineRect.minY, width: 1, height: timelineRect.height).fill()
    }

    /// Matches the zoom blocks and playhead so the timeline has a single
    /// selection color.
    private var selectionColor: NSColor {
        .controlAccentColor
    }

    private func clipRadius(for rect: CGRect) -> CGFloat {
        min(Metrics.clipRadius, rect.width / 2, rect.height / 2)
    }

    private func selectionGeometry() -> (video: CGRect, outer: CGRect, radius: CGFloat)? {
        guard let selectedClipID else { return nil }
        let trimPreview = trimPreviewGeometry()
        let baseRect = trimPreview?.clipID == selectedClipID
            ? trimPreview?.keptRect
            : clipRect(for: selectedClipID)
        guard let baseRect,
              baseRect.width > 1 else { return nil }
        let outerRect = baseRect.insetBy(
            dx: -Metrics.selectionPadding,
            dy: -Metrics.selectionPadding
        )
        return (
            video: baseRect,
            outer: outerRect,
            radius: min(
                clipRadius(for: baseRect) + Metrics.selectionPadding,
                outerRect.width / 2,
                outerRect.height / 2
            )
        )
    }

    private func drawSelectionChrome() {
        guard let geometry = selectionGeometry() else { return }

        selectionColor.setFill()
        NSBezierPath(
            roundedRect: geometry.outer,
            xRadius: geometry.radius,
            yRadius: geometry.radius
        ).fill()
    }

    private func drawSelectionGrooves() {
        guard let geometry = selectionGeometry(),
              !skippedClipIDs.contains(selectedClipID ?? UUID()) else { return }
        let handleRect = geometry.video
        guard handleRect.width > Metrics.selectionHandleInset * 4 else { return }

        let grooveY = handleRect.midY - Metrics.selectionHandleGrooveHeight / 2
        let grooveCenters = [
            handleRect.minX + Metrics.selectionHandleInset,
            handleRect.maxX - Metrics.selectionHandleInset
        ]

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.withAlphaComponent(0.92).setFill()
        for centerX in grooveCenters {
            let grooveRect = CGRect(
                x: centerX - Metrics.selectionHandleGrooveWidth / 2,
                y: grooveY,
                width: Metrics.selectionHandleGrooveWidth,
                height: Metrics.selectionHandleGrooveHeight
            )
            NSBezierPath(
                roundedRect: grooveRect,
                xRadius: Metrics.selectionHandleGrooveWidth / 2,
                yRadius: Metrics.selectionHandleGrooveWidth / 2
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
