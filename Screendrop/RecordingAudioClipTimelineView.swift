//
//  RecordingAudioClipTimelineView.swift
//  Screendrop
//
//  Stable AppKit hit testing for movable, non-destructive audio clips.
//  The full-width control stays fixed while clips move underneath the pointer.
//

import AppKit
import SwiftUI

struct RecordingAudioClipTimelineView: NSViewRepresentable {
    let trackKind: RecordingAudioTrackKind
    let clips: [RecordingAudioClipSegment]
    let selectedClipID: UUID?
    let timelineDuration: TimeInterval
    let pointsPerSecond: CGFloat
    let isInactive: Bool
    let onSelectClip: (UUID) -> Void
    let onSeek: (TimeInterval) -> Void
    let onBeginEdit: () -> Void
    let onMove: (TimeInterval) -> Void
    let onTrimLeading: (TimeInterval) -> Void
    let onTrimTrailing: (TimeInterval) -> Void
    let onEndEdit: (String) -> Void
    let onSelectTrack: () -> Void

    func makeNSView(context: Context) -> RecordingAudioClipTimelineControl {
        RecordingAudioClipTimelineControl()
    }

    func updateNSView(
        _ nsView: RecordingAudioClipTimelineControl,
        context: Context
    ) {
        nsView.onSelectClip = onSelectClip
        nsView.onSeek = onSeek
        nsView.onBeginEdit = onBeginEdit
        nsView.onMove = onMove
        nsView.onTrimLeading = onTrimLeading
        nsView.onTrimTrailing = onTrimTrailing
        nsView.onEndEdit = onEndEdit
        nsView.onSelectTrack = onSelectTrack
        nsView.update(
            trackKind: trackKind,
            clips: clips,
            selectedClipID: selectedClipID,
            timelineDuration: timelineDuration,
            pointsPerSecond: pointsPerSecond,
            isInactive: isInactive
        )
    }
}

final class RecordingAudioClipTimelineControl: NSView {
    var onSelectClip: ((UUID) -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onBeginEdit: (() -> Void)?
    var onMove: ((TimeInterval) -> Void)?
    var onTrimLeading: ((TimeInterval) -> Void)?
    var onTrimTrailing: ((TimeInterval) -> Void)?
    var onEndEdit: ((String) -> Void)?
    var onSelectTrack: (() -> Void)?

    private enum InteractionKind {
        case selectOnly
        case move
        case trimLeading
        case trimTrailing

        var actionName: String? {
            switch self {
            case .selectOnly:
                nil
            case .move:
                "Move Audio Clip"
            case .trimLeading, .trimTrailing:
                "Trim Audio Clip"
            }
        }
    }

    private struct Interaction {
        let kind: InteractionKind
        let clip: RecordingAudioClipSegment
        let startPoint: CGPoint
        let grabOffset: TimeInterval
        var crossedDragThreshold = false
        var editStarted = false
    }

    private enum Edge: Equatable {
        case leading
        case trailing
    }

    private enum Metrics {
        static let handleHitWidth: CGFloat = 10
        static let handleInset: CGFloat = 5
        static let handleWidth: CGFloat = 3
        static let handleHeight: CGFloat = 24
        static let dragThreshold: CGFloat = 2
        static let minimumMovementRoom: TimeInterval = 0.000_1
    }

    private var clips: [RecordingAudioClipSegment] = []
    private var selectedClipID: UUID?
    private var timelineDuration: TimeInterval = 0
    private var pointsPerSecond: CGFloat = 1
    private var isInactive = false
    private var trackingArea: NSTrackingArea?
    private var hoveredClipID: UUID?
    private var hoveredEdge: Edge?
    private var interaction: Interaction?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(
        trackKind: RecordingAudioTrackKind,
        clips: [RecordingAudioClipSegment],
        selectedClipID: UUID?,
        timelineDuration: TimeInterval,
        pointsPerSecond: CGFloat,
        isInactive: Bool
    ) {
        self.clips = clips
        self.selectedClipID = selectedClipID
        self.timelineDuration = max(timelineDuration, 0)
        self.pointsPerSecond = max(pointsPerSecond, 0.001)
        self.isInactive = isInactive
        setAccessibilityLabel("\(trackKind.title) clips")
        needsDisplay = true
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
        guard !isInactive,
              let selectedClipID,
              let clip = clips.first(where: { $0.id == selectedClipID }) else {
            return
        }

        let rect = clipRect(for: clip)
        let handleY = (bounds.height - Metrics.handleHeight) / 2
        let leadingX = rect.minX + Metrics.handleInset - Metrics.handleWidth / 2
        let trailingX = rect.maxX - Metrics.handleInset - Metrics.handleWidth / 2
        let color = NSColor.white.withAlphaComponent(0.92)

        color.setFill()
        for x in [leadingX, trailingX] {
            let handleRect = CGRect(
                x: x,
                y: handleY,
                width: Metrics.handleWidth,
                height: Metrics.handleHeight
            )
            NSBezierPath(
                roundedRect: handleRect,
                xRadius: Metrics.handleWidth / 2,
                yRadius: Metrics.handleWidth / 2
            ).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard interaction == nil else { return }
        hoveredClipID = nil
        hoveredEdge = nil
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        setCursor()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInactive else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        guard let clip = clip(at: point) else {
            onSelectTrack?()
            onSeek?(timelineTime(forX: point.x))
            return
        }

        onSelectClip?(clip.id)
        let kind: InteractionKind
        if let edge = edge(at: point, in: clip) {
            kind = edge == .leading ? .trimLeading : .trimTrailing
        } else if canMove(clip) {
            kind = .move
        } else {
            kind = .selectOnly
        }

        interaction = Interaction(
            kind: kind,
            clip: clip,
            startPoint: point,
            grabOffset: timelineTime(forX: point.x) - clip.timelineStart
        )
        setCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var interaction else { return }
        let point = convert(event.locationInWindow, from: nil)

        if !interaction.crossedDragThreshold {
            let distance = hypot(
                point.x - interaction.startPoint.x,
                point.y - interaction.startPoint.y
            )
            guard distance >= Metrics.dragThreshold else { return }
            interaction.crossedDragThreshold = true
            self.interaction = interaction
        }

        if !interaction.editStarted {
            guard interaction.kind.actionName != nil else { return }
            interaction.editStarted = true
            self.interaction = interaction
            onBeginEdit?()
        }

        let time = timelineTime(forX: point.x, clamped: false)
        switch interaction.kind {
        case .selectOnly:
            return
        case .move:
            onMove?(time - interaction.grabOffset)
            NSCursor.closedHand.set()
        case .trimLeading:
            onTrimLeading?(time)
            NSCursor.resizeLeftRight.set()
        case .trimTrailing:
            onTrimTrailing?(time)
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction else { return }
        self.interaction = nil

        if interaction.editStarted, let actionName = interaction.kind.actionName {
            onEndEdit?(actionName)
        } else if !interaction.crossedDragThreshold {
            let point = convert(event.locationInWindow, from: nil)
            onSeek?(timelineTime(forX: point.x))
        }
        updateHover(with: event)
    }

    private func updateHover(with event: NSEvent) {
        guard interaction == nil, !isInactive else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let clip = clip(at: point) else {
            hoveredClipID = nil
            hoveredEdge = nil
            NSCursor.arrow.set()
            return
        }

        hoveredClipID = clip.id
        hoveredEdge = edge(at: point, in: clip)
        setCursor()
    }

    private func setCursor() {
        if let interaction {
            switch interaction.kind {
            case .trimLeading, .trimTrailing:
                NSCursor.resizeLeftRight.set()
            case .move where interaction.editStarted:
                NSCursor.closedHand.set()
            case .move:
                NSCursor.openHand.set()
            case .selectOnly:
                NSCursor.arrow.set()
            }
            return
        }

        if hoveredEdge != nil {
            NSCursor.resizeLeftRight.set()
        } else if let hoveredClipID,
                  let clip = clips.first(where: { $0.id == hoveredClipID }),
                  canMove(clip) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func clip(at point: CGPoint) -> RecordingAudioClipSegment? {
        let orderedClips: [RecordingAudioClipSegment]
        if let selectedClipID,
           let selected = clips.first(where: { $0.id == selectedClipID }) {
            orderedClips = [selected] + clips.filter { $0.id != selectedClipID }
        } else {
            orderedClips = clips
        }
        return orderedClips.first { clipRect(for: $0).contains(point) }
    }

    private func edge(
        at point: CGPoint,
        in clip: RecordingAudioClipSegment
    ) -> Edge? {
        let rect = clipRect(for: clip)
        let leadingDistance = abs(point.x - rect.minX)
        let trailingDistance = abs(point.x - rect.maxX)
        let nearestDistance = min(leadingDistance, trailingDistance)
        guard nearestDistance <= Metrics.handleHitWidth else { return nil }
        return leadingDistance <= trailingDistance ? .leading : .trailing
    }

    private func canMove(_ clip: RecordingAudioClipSegment) -> Bool {
        let neighbors = clips
            .filter { $0.id != clip.id }
            .sorted { $0.timelineStart < $1.timelineStart }
        let previousEnd = neighbors.last {
            $0.timelineEnd <= clip.timelineStart
        }?.timelineEnd ?? 0
        let nextStart = neighbors.first {
            $0.timelineStart >= clip.timelineEnd
        }?.timelineStart ?? timelineDuration
        let latestStart = max(previousEnd, nextStart - clip.timelineDuration)
        return latestStart - previousEnd > Metrics.minimumMovementRoom
    }

    private func clipRect(for clip: RecordingAudioClipSegment) -> CGRect {
        CGRect(
            x: CGFloat(clip.timelineStart) * pointsPerSecond,
            y: 0,
            width: max(CGFloat(clip.timelineDuration) * pointsPerSecond, 2),
            height: bounds.height
        )
    }

    private func timelineTime(
        forX x: CGFloat,
        clamped: Bool = true
    ) -> TimeInterval {
        let time = Double(x / pointsPerSecond)
        guard clamped else { return time }
        return min(max(time, 0), timelineDuration)
    }
}
