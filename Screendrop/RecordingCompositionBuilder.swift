//
//  RecordingCompositionBuilder.swift
//  Screendrop
//
//  Shared gap-closing composition used by Studio playback and export.
//

import AVFoundation

nonisolated enum RecordingCompositionBuilder {
    static func makeAsset(
        from sourceAsset: AVAsset,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        audioTrackEdits: [RecordingAudioTrackEdit]? = nil,
        audioTrackKinds: [RecordingAudioTrackKind] = []
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        if audioTrackEdits == nil, normalized.isUnedited(sourceDuration: sourceDuration) {
            return sourceAsset
        }

        let composition = AVMutableComposition()
        guard let sourceVideo = sourceAsset.tracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }
        video.preferredTransform = sourceVideo.preferredTransform
        try insertVideoClips(normalized.segments, from: sourceVideo, into: video)

        let sourceAudioTracks = sourceAsset.tracks(withMediaType: .audio)
        for (sourceIndex, sourceAudio) in sourceAudioTracks.enumerated() {
            guard let audio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let kind = audioTrackKinds.indices.contains(sourceIndex)
                ? audioTrackKinds[sourceIndex]
                : fallbackKind(sourceIndex: sourceIndex, trackCount: sourceAudioTracks.count)
            let edit = audioTrackEdits?.first(where: { $0.kind == kind })
                ?? RecordingAudioTrackEdit.followingVideo(kind: kind, timeline: normalized)
            let trackSourceDuration = min(sourceDuration, sourceAudio.timeRange.end.seconds)
            let clips = edit.normalized(
                sourceDuration: trackSourceDuration,
                timelineDuration: normalized.duration
            ).clips
            try insertAudioTimeline(
                clips,
                duration: normalized.duration,
                sourceDuration: trackSourceDuration,
                from: sourceAudio,
                into: audio
            )
        }
        return composition
    }

    private static func insertVideoClips(
        _ clips: [RecordingClipSegment],
        from source: AVAssetTrack,
        into destination: AVMutableCompositionTrack
    ) throws {
        var insertionTime = CMTime.zero
        for clip in clips {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try destination.insertTimeRange(range, of: source, at: insertionTime)

            let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
            if abs(clip.speed - 1) > 0.000_001 {
                destination.scaleTimeRange(
                    CMTimeRange(start: insertionTime, duration: range.duration),
                    toDuration: scaledDuration
                )
            }
            insertionTime = insertionTime + scaledDuration
        }
    }

    private static func insertAudioTimeline(
        _ clips: [RecordingAudioClipSegment],
        duration: TimeInterval,
        sourceDuration: TimeInterval,
        from source: AVAssetTrack,
        into destination: AVMutableCompositionTrack
    ) throws {
        var coveredUntil: TimeInterval = 0
        for clip in clips {
            if clip.timelineStart > coveredUntil {
                try insertSilentTimingBed(
                    range: coveredUntil..<clip.timelineStart,
                    sourceDuration: sourceDuration,
                    from: source,
                    into: destination
                )
            }
            let insertionTime = CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
            )
            try destination.insertTimeRange(sourceRange, of: source, at: insertionTime)

            if abs(clip.speed - 1) > 0.000_001 {
                destination.scaleTimeRange(
                    CMTimeRange(start: insertionTime, duration: sourceRange.duration),
                    toDuration: CMTime(seconds: clip.timelineDuration, preferredTimescale: 600)
                )
            }
            coveredUntil = max(coveredUntil, clip.timelineEnd)
        }
        if coveredUntil < duration {
            try insertSilentTimingBed(
                range: coveredUntil..<duration,
                sourceDuration: sourceDuration,
                from: source,
                into: destination
            )
        }
    }

    private static func insertSilentTimingBed(
        range: Range<TimeInterval>,
        sourceDuration: TimeInterval,
        from source: AVAssetTrack,
        into destination: AVMutableCompositionTrack
    ) throws {
        guard !range.isEmpty, sourceDuration > 0 else { return }
        var timelineStart = range.lowerBound
        while timelineStart < range.upperBound {
            let chunkDuration = min(sourceDuration, range.upperBound - timelineStart)
            let chunkTime = CMTime(seconds: chunkDuration, preferredTimescale: 600)
            guard chunkTime > .zero else { return }
            try destination.insertTimeRange(
                CMTimeRange(start: .zero, duration: chunkTime),
                of: source,
                at: CMTime(seconds: timelineStart, preferredTimescale: 600)
            )
            timelineStart += chunkDuration
        }
    }

    private static func fallbackKind(
        sourceIndex: Int,
        trackCount: Int
    ) -> RecordingAudioTrackKind {
        if trackCount == 1 { return .system }
        return sourceIndex == 0 ? .system : .microphone
    }

    /// Playback asset whose soundtrack comes from an imported file instead
    /// of the recording's own audio. The video track arrives already
    /// resolved so Studio can rebuild the player item synchronously, the
    /// way it does on every trim.
    static func makeAsset(
        videoTrack: AVAssetTrack,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        replacementAudio: RecordingReplacementAudio
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }

        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try video.insertTimeRange(range, of: videoTrack, at: insertionTime)

            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                video.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }

        // The import is already the finished cut's soundtrack, so it lies
        // flat from zero rather than being re-cut through the clip list -
        // and is clipped to whatever the timeline still holds.
        let audioLength = min(replacementAudio.duration, insertionTime.seconds)
        if audioLength > 0,
           let audio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audio.insertTimeRange(
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: audioLength, preferredTimescale: 600)
                ),
                of: replacementAudio.track,
                at: .zero
            )
        }
        return composition
    }
}
