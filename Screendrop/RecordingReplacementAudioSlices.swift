import AVFoundation
import Foundation

nonisolated struct RecordingReplacementAudioSlice: Sendable {
    let sourceStart: Double
    let sourceEnd: Double
    let outputStart: Double
    let outputDuration: Double

    /// A replacement file represents the output at import time. Map later
    /// edits back to that version so skipping never shifts narration.
    static func make(basis: RecordingClipTimeline, output: RecordingClipTimeline) -> [Self] {
        output.segments.flatMap { clip -> [Self] in
            guard let outputRange = output.editorRange(for: clip.id) else { return [] }
            return basis.segments.compactMap { original in
                let start = max(clip.sourceStart, original.sourceStart)
                let end = min(clip.sourceEnd, original.sourceEnd)
                guard end > start, let basisRange = basis.editorRange(for: original.id) else { return nil }
                return Self(sourceStart: basisRange.lowerBound + (start - original.sourceStart) / original.speed,
                            sourceEnd: basisRange.lowerBound + (end - original.sourceStart) / original.speed,
                            outputStart: outputRange.lowerBound + (start - clip.sourceStart) / clip.speed,
                            outputDuration: (end - start) / clip.speed)
            }
        }
    }

    static func asset(url: URL, slices: [Self]?, duration: Double) async throws -> AVAsset {
        let asset = AVURLAsset(url: url)
        guard let slices else { return asset }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let composition = AVMutableComposition()
        for track in tracks { try insert(track: track, slices: slices, duration: duration, into: composition) }
        return composition
    }

    static func insert(track: AVAssetTrack, slices: [Self], duration: Double, into composition: AVMutableComposition) throws {
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        let available = track.timeRange
        var coveredUntil = CMTime.zero
        for slice in slices {
            let start = max(slice.sourceStart, available.start.seconds)
            let end = min(slice.sourceEnd, available.end.seconds)
            guard end > start, slice.outputDuration > 0 else { continue }
            let speed = (slice.sourceEnd - slice.sourceStart) / slice.outputDuration
            let outputStart = CMTime(seconds: slice.outputStart + (start - slice.sourceStart) / speed, preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                         end: CMTime(seconds: end, preferredTimescale: 600))
            let outputDuration = CMTime(seconds: (end - start) / speed, preferredTimescale: 600)
            guard sourceRange.duration > .zero, outputDuration > .zero else { continue }
            try audio.insertTimeRange(sourceRange, of: track, at: outputStart)
            audio.scaleTimeRange(CMTimeRange(start: outputStart, duration: sourceRange.duration), toDuration: outputDuration)
            coveredUntil = outputStart + outputDuration
        }
        let end = CMTime(seconds: duration, preferredTimescale: 600)
        if end > coveredUntil { audio.insertEmptyTimeRange(CMTimeRange(start: coveredUntil, end: end)) }
    }
}
