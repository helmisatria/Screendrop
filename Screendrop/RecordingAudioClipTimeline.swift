//
//  RecordingAudioClipTimeline.swift
//  Screendrop
//
//  Non-destructive audio clips. Each clip points into an untouched source
//  recording and places that source range independently on the edit timeline.
//

import Foundation

nonisolated struct RecordingAudioClipSegment: Codable, Equatable, Identifiable, Sendable {
    static let minimumDuration: TimeInterval = 0.05

    var id: UUID
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    var timelineStart: TimeInterval
    var speed: Double

    init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        timelineStart: TimeInterval,
        speed: Double = 1
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.timelineStart = timelineStart
        self.speed = speed
    }

    var sourceDuration: TimeInterval {
        max(0, sourceEnd - sourceStart)
    }

    var timelineDuration: TimeInterval {
        sourceDuration / max(speed, RecordingClipSegment.minimumSpeed)
    }

    var timelineEnd: TimeInterval {
        timelineStart + timelineDuration
    }

    func sourceTime(at timelineTime: TimeInterval) -> TimeInterval {
        sourceStart + (timelineTime - timelineStart) * speed
    }
}

nonisolated struct RecordingAudioTrackEdit: Codable, Equatable, Identifiable, Sendable {
    var id: RecordingAudioTrackKind { kind }

    var kind: RecordingAudioTrackKind
    var clips: [RecordingAudioClipSegment]

    static func followingVideo(
        kind: RecordingAudioTrackKind,
        timeline: RecordingClipTimeline
    ) -> RecordingAudioTrackEdit {
        var timelineStart: TimeInterval = 0
        let clips = timeline.segments.map { videoClip in
            defer { timelineStart += videoClip.editorDuration }
            return RecordingAudioClipSegment(
                sourceStart: videoClip.sourceStart,
                sourceEnd: videoClip.sourceEnd,
                timelineStart: timelineStart,
                speed: videoClip.speed
            )
        }
        return RecordingAudioTrackEdit(kind: kind, clips: clips)
    }

    func normalized(
        sourceDuration: TimeInterval,
        timelineDuration: TimeInterval
    ) -> RecordingAudioTrackEdit {
        let sourceDuration = max(0, sourceDuration)
        let timelineDuration = max(0, timelineDuration)
        var previousEnd: TimeInterval = 0
        var result: [RecordingAudioClipSegment] = []

        for storedClip in clips.sorted(by: Self.timelineOrder) {
            var clip = storedClip
            guard clip.sourceStart.isFinite,
                  clip.sourceEnd.isFinite,
                  clip.timelineStart.isFinite,
                  clip.speed.isFinite else {
                continue
            }

            clip.speed = min(
                max(clip.speed, RecordingClipSegment.minimumSpeed),
                RecordingClipSegment.maximumSpeed
            )
            clip.sourceStart = min(max(clip.sourceStart, 0), sourceDuration)
            clip.sourceEnd = min(max(clip.sourceEnd, clip.sourceStart), sourceDuration)

            if clip.timelineStart < 0 {
                clip.sourceStart += -clip.timelineStart * clip.speed
                clip.timelineStart = 0
            }
            clip.timelineStart = max(clip.timelineStart, previousEnd)
            if clip.timelineStart - previousEnd < 1.0 / 600 {
                clip.timelineStart = previousEnd
            }

            let allowedTimelineDuration = max(0, timelineDuration - clip.timelineStart)
            let allowedSourceEnd = clip.sourceStart + allowedTimelineDuration * clip.speed
            clip.sourceEnd = min(clip.sourceEnd, allowedSourceEnd, sourceDuration)

            guard clip.sourceDuration / clip.speed >= Self.minimumDuration else { continue }
            result.append(clip)
            previousEnd = clip.timelineEnd
        }

        return RecordingAudioTrackEdit(kind: kind, clips: result)
    }

    func clip(id: UUID) -> RecordingAudioClipSegment? {
        clips.first { $0.id == id }
    }

    func replacing(_ replacement: RecordingAudioClipSegment) -> RecordingAudioTrackEdit {
        guard let index = clips.firstIndex(where: { $0.id == replacement.id }) else { return self }
        var result = self
        result.clips[index] = replacement
        result.clips.sort(by: Self.timelineOrder)
        return result
    }

    func deleting(clipID: UUID) -> RecordingAudioTrackEdit? {
        guard clips.contains(where: { $0.id == clipID }) else { return nil }
        var result = self
        result.clips.removeAll { $0.id == clipID }
        return result
    }

    func split(clipID: UUID, at timelineTime: TimeInterval) -> RecordingAudioTrackEdit? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        let clip = clips[index]
        let leftDuration = timelineTime - clip.timelineStart
        let rightDuration = clip.timelineEnd - timelineTime
        guard leftDuration >= Self.minimumDuration,
              rightDuration >= Self.minimumDuration else {
            return nil
        }

        let splitSourceTime = clip.sourceTime(at: timelineTime)
        var left = clip
        left.sourceEnd = splitSourceTime
        let right = RecordingAudioClipSegment(
            sourceStart: splitSourceTime,
            sourceEnd: clip.sourceEnd,
            timelineStart: timelineTime,
            speed: clip.speed
        )

        var result = self
        result.clips.replaceSubrange(index...index, with: [left, right])
        return result
    }

    private static let minimumDuration = RecordingAudioClipSegment.minimumDuration

    private static func timelineOrder(
        _ lhs: RecordingAudioClipSegment,
        _ rhs: RecordingAudioClipSegment
    ) -> Bool {
        if lhs.timelineStart == rhs.timelineStart {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.timelineStart < rhs.timelineStart
    }
}
