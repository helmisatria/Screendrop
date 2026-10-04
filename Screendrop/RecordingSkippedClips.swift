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

    /// A kept clip's trim wins over skipped footage: skipped neighbours it
    /// now covers shrink, and any sliver shorter than a clip disappears.
    func trimming(_ replacement: RecordingClipSegment) -> Self {
        Self(playable: playable.replacing(replacement),
             skipped: Self.carving(replacement.sourceStart...replacement.sourceEnd, from: skipped))
    }

    /// Turns skipped clips into ordinary trims, so they leave the timeline.
    /// Passing nil removes every skipped clip.
    func removingSkipped(_ ids: Set<UUID>? = nil) -> Self {
        Self(playable: playable, skipped: ids.map { ids in skipped.filter { !ids.contains($0.id) } } ?? [])
    }

    static func carving(_ range: ClosedRange<TimeInterval>, from clips: [RecordingClipSegment]) -> [RecordingClipSegment] {
        clips.flatMap { clip -> [RecordingClipSegment] in
            guard range.upperBound > clip.sourceStart, range.lowerBound < clip.sourceEnd else { return [clip] }
            var pieces: [RecordingClipSegment] = []
            if range.lowerBound - clip.sourceStart >= RecordingClipSegment.minimumDuration {
                var head = clip
                head.sourceEnd = range.lowerBound
                pieces.append(head)
            }
            if clip.sourceEnd - range.upperBound >= RecordingClipSegment.minimumDuration {
                var tail = clip
                tail.id = pieces.isEmpty ? clip.id : UUID()
                tail.sourceStart = range.upperBound
                pieces.append(tail)
            }
            return pieces
        }
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
        return remappingAudio(edits, to: playable)
    }

    /// Moves display-time audio onto `target`, a timeline whose clips are a
    /// subset of the display clips. Audio under dropped clips goes with them.
    func remappingAudio(_ edits: [RecordingAudioTrackEdit], to target: RecordingClipTimeline) -> [RecordingAudioTrackEdit] {
        edits.map { edit in
            var clips: [RecordingAudioClipSegment] = []
            for audio in edit.clips {
                for video in target.segments {
                    guard let visible = display.editorRange(for: video.id),
                          let output = target.editorRange(for: video.id) else { continue }
                    let start = max(audio.timelineStart, visible.lowerBound)
                    let end = min(audio.timelineEnd, visible.upperBound)
                    guard end - start > 0.000_001 else { continue }
                    clips.append(RecordingAudioClipSegment(
                        id: audio.id,
                        sourceStart: audio.sourceTime(at: start), sourceEnd: audio.sourceTime(at: end),
                        timelineStart: output.lowerBound + start - visible.lowerBound, speed: audio.speed,
                        gainDB: audio.gainDB
                    ))
                }
            }
            return RecordingAudioTrackEdit(kind: edit.kind, clips: clips)
        }
    }
}
