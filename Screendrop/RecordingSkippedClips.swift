import Foundation

/// The display retains skipped footage; playback and exports use `playable`.
nonisolated struct RecordingSkippedClips: Equatable, Sendable {
    var playable: RecordingClipTimeline
    var skipped: [RecordingClipSegment]

    var display: RecordingClipTimeline {
        RecordingClipTimeline(segments: (playable.segments + skipped).sorted { $0.sourceStart < $1.sourceStart })
    }

    func skipping(_ ranges: [ClosedRange<TimeInterval>]) -> Self {
        let ranges = RecordingClipTimeline.mergedRanges(ranges)
        var kept: [RecordingClipSegment] = []
        var removed = skipped
        for clip in playable.segments {
            let cuts = ranges.filter { $0.upperBound > clip.sourceStart && $0.lowerBound < clip.sourceEnd }
            var boundaries = [clip.sourceStart]
            for boundary in cuts.flatMap({ [$0.lowerBound, $0.upperBound] }).sorted() {
                if boundary - boundaries.last! >= RecordingClipSegment.minimumDuration,
                   clip.sourceEnd - boundary >= RecordingClipSegment.minimumDuration {
                    boundaries.append(boundary)
                }
            }
            boundaries.append(clip.sourceEnd)
            for index in 0..<(boundaries.count - 1) {
                let start = boundaries[index]
                let end = boundaries[index + 1]
                let piece = RecordingClipSegment(id: index == 0 ? clip.id : UUID(),
                    sourceStart: start, sourceEnd: end, speed: clip.speed)
                if cuts.contains(where: { $0.contains((start + end) / 2) }) {
                    removed.append(piece)
                } else {
                    kept.append(piece)
                }
            }
        }
        // Keep at least one playable clip, matching the existing editor rule.
        guard !kept.isEmpty else { return self }
        return Self(playable: RecordingClipTimeline(segments: kept), skipped: removed)
    }

    func toggling(_ id: UUID) -> Self {
        if let clip = skipped.first(where: { $0.id == id }) {
            return Self(playable: RecordingClipTimeline(segments: (playable.segments + [clip])
                .sorted { $0.sourceStart < $1.sourceStart }), skipped: skipped.filter { $0.id != id })
        }
        guard playable.segments.count > 1, let clip = playable.segments.first(where: { $0.id == id }) else { return self }
        return Self(playable: RecordingClipTimeline(segments: playable.segments.filter { $0.id != id }),
                    skipped: skipped + [clip])
    }

    func outputTime(forDisplayTime time: TimeInterval) -> TimeInterval {
        let source = display.sourceTime(at: time)
        if let exact = playable.editorTime(forSourceTime: source) { return exact }
        if let next = playable.segments.first(where: { $0.sourceStart >= source }) {
            return playable.editorRange(for: next.id)?.lowerBound ?? 0
        }
        return playable.duration
    }

    func displayTime(forOutputTime time: TimeInterval) -> TimeInterval {
        display.editorTime(forSourceTime: playable.sourceTime(at: time)) ?? 0
    }

    /// Audio edits stay in display time so skipping/restoring does not lose
    /// independent audio cuts. Only their audible slices enter the output.
    func outputAudio(_ edits: [RecordingAudioTrackEdit]) -> [RecordingAudioTrackEdit] {
        guard !skipped.isEmpty else { return edits }
        return edits.map { edit in
            var clips: [RecordingAudioClipSegment] = []
            for audio in edit.clips {
                for video in playable.segments {
                    guard let visible = display.editorRange(for: video.id),
                          let output = playable.editorRange(for: video.id) else { continue }
                    let start = max(audio.timelineStart, visible.lowerBound)
                    let end = min(audio.timelineEnd, visible.upperBound)
                    guard end - start > 0.000_001 else { continue }
                    clips.append(RecordingAudioClipSegment(
                        id: audio.id,
                        sourceStart: audio.sourceTime(at: start), sourceEnd: audio.sourceTime(at: end),
                        timelineStart: output.lowerBound + start - visible.lowerBound, speed: audio.speed
                    ))
                }
            }
            return RecordingAudioTrackEdit(kind: edit.kind, clips: clips)
        }
    }
}
