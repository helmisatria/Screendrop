//
//  RecordingAudioTimeline.swift
//  Screendrop
//
//  Recorded-audio track discovery, waveform analysis, and non-destructive
//  gain processing shared by Studio playback and export.
//

import AVFoundation
import AudioToolbox
import Foundation
import MediaToolbox

nonisolated enum RecordingAudioGainLimits {
    /// Near-silence at the bottom, and a 30x ceiling for unusually quiet mics.
    static let minimumDB: Double = -60
    static let maximumDB: Double = 20 * log10(30)
}

nonisolated enum RecordingAudioTrackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case microphone

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System Audio"
        case .microphone: "Microphone"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "speaker.wave.2.fill"
        case .microphone: "mic.fill"
        }
    }
}

nonisolated struct RecordingAudioWaveform: Equatable, Sendable {
    static let samplesPerSecond = 120

    let peaks: [Float]
    let suggestedGainDB: Double

    func peak(at sourceTime: TimeInterval) -> Float {
        guard sourceTime.isFinite, sourceTime >= 0, !peaks.isEmpty else { return 0 }
        let index = min(
            Int(sourceTime * Double(Self.samplesPerSecond)),
            peaks.count - 1
        )
        return peaks[index]
    }
}

nonisolated struct RecordingAudioTrack: Identifiable, Equatable, Sendable {
    var id: RecordingAudioTrackKind { kind }

    let kind: RecordingAudioTrackKind
    let sourceIndex: Int
    let channelCount: Int
    var waveform: RecordingAudioWaveform?
}

nonisolated enum RecordingAudioWaveformAnalyzer {
    private static let activeFloor: Float = 0.004
    private static let targetRMS: Double = 0.16

    static func analyze(
        url: URL,
        manifest: CaptureManifest?
    ) async throws -> [RecordingAudioTrack] {
        let asset = AVURLAsset(url: url)
        let tracks = Array(try await asset.loadTracks(withMediaType: .audio).prefix(2))
        guard !tracks.isEmpty else { return [] }

        let channels = try await tracks.asyncMap { track in
            try await channelCount(for: track)
        }
        let kinds = identifyTrackKinds(channelCounts: channels, manifest: manifest)

        var result: [RecordingAudioTrack] = []
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let waveform = try await waveform(for: track, in: asset)
            result.append(
                RecordingAudioTrack(
                    kind: kinds[index],
                    sourceIndex: index,
                    channelCount: channels[index],
                    waveform: waveform
                )
            )
        }
        return result
    }

    static func descriptors(
        url: URL,
        manifest: CaptureManifest?
    ) async throws -> [RecordingAudioTrack] {
        let tracks = Array(
            try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).prefix(2)
        )
        let channels = try await tracks.asyncMap { track in
            try await channelCount(for: track)
        }
        let kinds = identifyTrackKinds(channelCounts: channels, manifest: manifest)
        return tracks.indices.map { index in
            RecordingAudioTrack(
                kind: kinds[index],
                sourceIndex: index,
                channelCount: channels[index],
                waveform: nil
            )
        }
    }

    private static func identifyTrackKinds(
        channelCounts: [Int],
        manifest: CaptureManifest?
    ) -> [RecordingAudioTrackKind] {
        if channelCounts.count == 1 {
            if manifest?.includesMicrophone == true, manifest?.includesSystemAudio != true {
                return [.microphone]
            }
            if manifest?.includesSystemAudio == true, manifest?.includesMicrophone != true {
                return [.system]
            }
            return [channelCounts[0] == 1 ? .microphone : .system]
        }

        // The recorder writes system audio first (stereo) and microphone
        // second (mono). Channel count keeps legacy files identifiable while
        // source order resolves unusual devices that do not follow that shape.
        var kinds = channelCounts.map { $0 == 1 ? RecordingAudioTrackKind.microphone : .system }
        if kinds.filter({ $0 == .system }).count != 1
            || kinds.filter({ $0 == .microphone }).count != 1 {
            kinds = channelCounts.indices.map { $0 == 0 ? .system : .microphone }
        }
        return kinds
    }

    private static func channelCount(for track: AVAssetTrack) async throws -> Int {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return 1
        }
        return max(Int(stream.pointee.mChannelsPerFrame), 1)
    }

    private static func waveform(
        for track: AVAssetTrack,
        in asset: AVAsset
    ) async throws -> RecordingAudioWaveform {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecordingAudioAnalysisError.couldNotReadTrack
        }

        let duration = try await asset.load(.duration).seconds
        let bucketCount = max(1, Int(ceil(duration * Double(RecordingAudioWaveform.samplesPerSecond))))
        var peaks = Array(repeating: Float.zero, count: bucketCount)
        var squareSums = Array(repeating: Double.zero, count: bucketCount)
        var sampleCounts = Array(repeating: 0, count: bucketCount)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            let channelCount = max(Int(stream.pointee.mChannelsPerFrame), 1)
            let sampleRate = max(stream.pointee.mSampleRate, 1)
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Int16>.size * channelCount else { continue }

            var samples = Array(repeating: Int16.zero, count: byteCount / MemoryLayout<Int16>.size)
            let copyStatus = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: bytes.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else { continue }

            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let frameCount = samples.count / channelCount
            // Several samples still land in every 1/120-second bucket while
            // long recordings avoid a needless pass over every PCM frame.
            let stride = 8
            var frame = 0
            while frame < frameCount {
                var framePeak: Float = 0
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    let magnitude = abs(Float(samples[base + channel]) / Float(Int16.max))
                    framePeak = max(framePeak, magnitude)
                }

                let time = start + Double(frame) / sampleRate
                let bucket = Int(time * Double(RecordingAudioWaveform.samplesPerSecond))
                if bucket >= 0, bucket < bucketCount {
                    peaks[bucket] = max(peaks[bucket], framePeak)
                    squareSums[bucket] += Double(framePeak * framePeak)
                    sampleCounts[bucket] += 1
                }
                frame += stride
            }
        }

        if reader.status == .failed {
            throw reader.error ?? RecordingAudioAnalysisError.couldNotReadTrack
        }

        var activeRMS: [Double] = []
        var activePeaks: [Float] = []
        for index in peaks.indices where peaks[index] >= activeFloor && sampleCounts[index] > 0 {
            activeRMS.append(sqrt(squareSums[index] / Double(sampleCounts[index])))
            activePeaks.append(peaks[index])
        }

        let suggestedGainDB = suggestedGainDB(activeRMS: activeRMS, activePeaks: activePeaks)
        return RecordingAudioWaveform(peaks: peaks, suggestedGainDB: suggestedGainDB)
    }

    private static func suggestedGainDB(
        activeRMS: [Double],
        activePeaks: [Float]
    ) -> Double {
        guard !activeRMS.isEmpty, !activePeaks.isEmpty else { return 0 }
        let rms = percentile(activeRMS.sorted(), fraction: 0.65)
        let peak = Double(percentile(activePeaks.sorted(), fraction: 0.995))
        guard rms > 0, peak > 0 else { return 0 }

        let targetGain = 20 * log10(targetRMS / rms)
        let peakSafeGain = 20 * log10(0.98 / peak)
        return min(
            max(min(targetGain, peakSafeGain), RecordingAudioGainLimits.minimumDB),
            RecordingAudioGainLimits.maximumDB
        )
    }

    private static func percentile<T>(_ sorted: [T], fraction: Double) -> T {
        let index = min(max(Int((Double(sorted.count - 1) * fraction).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }
}

nonisolated private enum RecordingAudioAnalysisError: LocalizedError {
    case couldNotReadTrack

    var errorDescription: String? {
        "Screendrop could not analyze this audio track."
    }
}

/// Builds one audio mix for both AVPlayerItem and AVAssetReader. AVFoundation's
/// built-in volume parameter only attenuates, so positive dB values use a tap
/// that multiplies decoded samples and hard-limits manual boosts at full scale.
nonisolated enum RecordingAudioGainMix {
    static func make(
        tracks: [AVAssetTrack],
        gainsDB: [Double],
        trackEdits: [RecordingAudioTrackEdit] = []
    ) -> AVAudioMix? {
        guard !tracks.isEmpty else { return nil }

        let parameters = tracks.enumerated().compactMap { index, track -> AVAudioMixInputParameters? in
            let gainDB = index < gainsDB.count ? gainsDB[index] : 0
            let edit = index < trackEdits.count ? trackEdits[index] : nil
            guard abs(gainDB) > 0.000_1 || edit != nil else { return nil }

            let input = AVMutableAudioMixInputParameters(track: track)
            let clipVolume: Float
            if gainDB <= 0 {
                clipVolume = Float(pow(10, gainDB / 20))
            } else {
                clipVolume = 1
            }
            if gainDB > 0, let tap = makeGainTap(linearGain: Float(pow(10, gainDB / 20))) {
                input.audioTapProcessor = tap
            }
            if let edit {
                input.setVolume(0, at: .zero)
                var coveredUntil: TimeInterval = 0
                for clip in edit.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                    setConstantVolume(
                        0,
                        range: coveredUntil..<clip.timelineStart,
                        on: input
                    )
                    setConstantVolume(
                        clipVolume,
                        range: clip.timelineStart..<clip.timelineEnd,
                        on: input
                    )
                    coveredUntil = max(coveredUntil, clip.timelineEnd)
                }
                let trackEnd = track.timeRange.end.seconds
                if trackEnd > coveredUntil {
                    setConstantVolume(
                        0,
                        range: coveredUntil..<trackEnd,
                        on: input
                    )
                }
            } else if gainDB <= 0 {
                input.setVolume(clipVolume, at: .zero)
            }
            return input
        }

        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private static func setConstantVolume(
        _ volume: Float,
        range: Range<TimeInterval>,
        on input: AVMutableAudioMixInputParameters
    ) {
        let duration = CMTime(
            seconds: range.upperBound - range.lowerBound,
            preferredTimescale: 600
        )
        guard duration > .zero else { return }
        input.setVolumeRamp(
            fromStartVolume: volume,
            toEndVolume: volume,
            timeRange: CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                duration: duration
            )
        )
    }

    private static func makeGainTap(linearGain: Float) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(RecordingAudioGainTapContext(gain: linearGain))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: recordingAudioGainTapInit,
            finalize: recordingAudioGainTapFinalize,
            prepare: recordingAudioGainTapPrepare,
            unprepare: recordingAudioGainTapUnprepare,
            process: recordingAudioGainTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        if status != noErr {
            context.release()
            return nil
        }
        return tap
    }
}

nonisolated private final class RecordingAudioGainTapContext {
    let gain: Float
    var format = AudioStreamBasicDescription()

    init(gain: Float) {
        self.gain = gain
    }
}

nonisolated private func recordingAudioGainTapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

nonisolated private func recordingAudioGainTapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<RecordingAudioGainTapContext>.fromOpaque(storage).release()
}

nonisolated private func recordingAudioGainTapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<RecordingAudioGainTapContext>.fromOpaque(storage).takeUnretainedValue().format = processingFormat.pointee
}

nonisolated private func recordingAudioGainTapUnprepare(tap: MTAudioProcessingTap) {}

nonisolated private func recordingAudioGainTapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var sourceFlags: MTAudioProcessingTapFlags = 0
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        &sourceFlags,
        nil,
        numberFramesOut
    )
    guard status == noErr else { return }
    flagsOut.pointee = sourceFlags

    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<RecordingAudioGainTapContext>.fromOpaque(storage).takeUnretainedValue()
    let format = context.format
    guard format.mFormatID == kAudioFormatLinearPCM else { return }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count {
                samples[index] = min(max(samples[index] * context.gain, -1), 1)
            }
        }
    } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              format.mBitsPerChannel == 16 {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = data.bindMemory(to: Int16.self, capacity: count)
            for index in 0..<count {
                let amplified = Float(samples[index]) * context.gain
                samples[index] = Int16(min(max(amplified, Float(Int16.min)), Float(Int16.max)))
            }
        }
    }
}

nonisolated private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
