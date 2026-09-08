import AVFoundation
import CryptoKit
import Foundation

nonisolated enum OpenRouterTranscription {
    enum TranscriptionError: LocalizedError {
        case requestFailed(Int)
        case missingTimestamps
        case invalidResponse
        case retryDeferred(Double)

        var errorDescription: String? {
            switch self {
            case .requestFailed(401): "OpenRouter rejected the API key. Check your saved key."
            case .requestFailed(402): "Your OpenRouter account needs credits for transcription."
            case .requestFailed(400): "OpenRouter rejected this model or audio request. Choose a speech-to-text model with verbose timestamps, such as microsoft/mai-transcribe-2."
            case .requestFailed(404): "The OpenRouter model was not found. Check the model ID."
            case .requestFailed(429): "Transcription is busy right now. Please try again shortly."
            case .requestFailed: "Transcription could not finish. Please try again later."
            case .missingTimestamps: "This model returned text without usable timestamps. Choose a model with segment or word timestamps."
            case .retryDeferred: "Transcription is taking longer than usual. Please try again later."
            case .invalidResponse: "OpenRouter returned an unreadable transcription response."
            }
        }
    }

    // Retained by one Studio editor so a manual retry reuses successful
    // chunks. Only audio hashes and responses are kept, never API keys.
    actor ChunkCache {
        private var responses: [String: Response] = [:]

        private func key(audio: Data, model: String) -> String {
            model + ":" + SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        }

        func response(audio: Data, model: String) -> Response? {
            responses[key(audio: audio, model: model)]
        }

        func store(_ response: Response, audio: Data, model: String) {
            responses[key(audio: audio, model: model)] = response
        }
    }

    static let maximumRetries = 4

    static func retryDelay(header: String?, retry: Int, now: Date = Date()) -> Double {
        if let header {
            let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                return max(1, seconds)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) {
                return max(1, date.timeIntervalSince(now))
            }
        }
        return min(60, 5 * pow(2, Double(retry)))
    }

    struct Response: Decodable, Sendable {
        struct Word: Decodable, Sendable {
            let word: String
            let start: Double
            let end: Double
        }
        struct Segment: Decodable, Sendable {
            let text: String
            let start: Double
            let end: Double
        }
        let text: String?
        let words: [Word]?
        let segments: [Segment]?

        func transcript(offset: Double, duration: Double, pauseThreshold: Double) throws -> RecordingTranscript {
            let timedWords = (words ?? []).compactMap { word -> RecordingTranscriptWord? in
                guard word.start.isFinite, word.end.isFinite, word.start >= 0,
                      word.end > word.start, word.start < duration,
                      !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return RecordingTranscriptWord(
                    text: word.word.trimmingCharacters(in: .whitespacesAndNewlines) + " ",
                    start: offset + word.start,
                    end: offset + min(duration, word.end)
                )
            }.sorted { $0.start < $1.start }
            if !timedWords.isEmpty {
                return RecordingTranscript(words: timedWords, cues: RecordingTranscriptionService.makeCues(
                    from: timedWords, pauseThreshold: pauseThreshold
                ))
            }
            let cues = (segments ?? []).compactMap { segment -> RecordingSubtitleCue? in
                guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                      segment.end > segment.start, segment.start < duration,
                      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return RecordingSubtitleCue(start: offset + segment.start,
                                            end: offset + min(duration, segment.end), text: segment.text)
            }.sorted { $0.start < $1.start }
            if !cues.isEmpty { return RecordingTranscript(words: [], cues: cues) }
            if !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TranscriptionError.missingTimestamps
            }
            return RecordingTranscript(words: [], cues: [])
        }
    }

    @concurrent
    static func transcribe(
        screenMovieURL: URL,
        configuration: CloudTranscriptionConfiguration,
        cache: ChunkCache = ChunkCache(),
        retryStatus: @escaping @Sendable (String?) async -> Void = { _ in },
        session suppliedSession: URLSession? = nil,
        sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> RecordingTranscript {
        let narrationURL = try await RecordingTranscriptionService.extractNarrationAudio(from: screenMovieURL)
        defer { try? FileManager.default.removeItem(at: narrationURL) }
        let audio = try AVAudioFile(forReading: narrationURL)
        let rate = audio.processingFormat.sampleRate
        guard rate > 0, audio.length > 0 else {
            throw RecordingTranscriptionService.TranscriptionError.narrationUnreadable
        }
        let session = suppliedSession ?? URLSession(configuration: .ephemeral)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        var result = RecordingTranscript(words: [], cues: [])
        var allChunksHaveWords = true
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            let startFrame = audio.framePosition
            let capacity = AVAudioFrameCount(min(60 * rate, Double(audio.length - startFrame)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: capacity) else {
                throw RecordingTranscriptionService.TranscriptionError.narrationUnreadable
            }
            try audio.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { break }
            // Prefer a quiet boundary near the end of each minute, keeping
            // every source frame exactly once and retaining original times.
            if audio.framePosition < audio.length {
                buffer.frameLength = quietBoundary(in: buffer)
                audio.framePosition = startFrame + AVAudioFramePosition(buffer.frameLength)
            }
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("screendrop-transcription-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            try writeWAV(buffer, to: chunkURL)
            let data = try Data(contentsOf: chunkURL)
            let response: Response
            if let cached = await cache.response(audio: data, model: configuration.model) {
                response = cached
            } else {
                response = try await request(audio: data, configuration: configuration, session: session,
                                             retryStatus: retryStatus, sleep: sleep)
                try Task.checkCancellation()
                await cache.store(response, audio: data, model: configuration.model)
            }
            try Task.checkCancellation()
            let transcript = try response.transcript(
                offset: Double(startFrame) / rate,
                duration: Double(buffer.frameLength) / rate,
                pauseThreshold: configuration.pauseThreshold
            )
            result.words += transcript.words
            result.cues += transcript.cues
            if !transcript.cues.isEmpty && transcript.words.isEmpty { allChunksHaveWords = false }
            await progress(Double(audio.framePosition) / Double(audio.length))
        }
        guard !result.cues.isEmpty else {
            throw RecordingTranscriptionService.TranscriptionError.noSpeechDetected
        }
        // Partial word coverage would make transcript-based cuts unsafe.
        if allChunksHaveWords {
            result.cues = RecordingTranscriptionService.makeCues(
                from: result.words, pauseThreshold: configuration.pauseThreshold
            )
        } else {
            result.words = []
        }
        for index in result.cues.indices {
            let nextStart = index + 1 < result.cues.count
                ? result.cues[index + 1].start : Double(audio.length) / rate
            result.cues[index].end = min(result.cues[index].end, nextStart)
        }
        return result
    }

    static func request(
        audio: Data,
        configuration: CloudTranscriptionConfiguration,
        session: URLSession,
        retryStatus: @escaping @Sendable (String?) async -> Void = { _ in },
        sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
            "response_format": "verbose_json",
            "timestamp_granularities": ["segment", "word"]
        ])
        for attempt in 0...maximumRetries {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
            if (200..<300).contains(response.statusCode) {
                do { return try JSONDecoder().decode(Response.self, from: data) }
                catch { throw TranscriptionError.invalidResponse }
            }
            guard [429, 503].contains(response.statusCode), attempt < maximumRetries else {
                throw TranscriptionError.requestFailed(response.statusCode)
            }
            let delay = retryDelay(header: response.value(forHTTPHeaderField: "Retry-After"), retry: attempt)
            // Do not shorten a provider's requested wait to fit our budget.
            guard delay <= 300 else { throw TranscriptionError.retryDeferred(delay) }
            await retryStatus("Provider busy. Retrying this chunk in \(Int(ceil(delay))) s (\(attempt + 1)/\(maximumRetries))…")
            try await sleep(delay)
            try Task.checkCancellation()
            await retryStatus(nil)
        }
        throw TranscriptionError.invalidResponse
    }

    static func writeWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func quietBoundary(in buffer: AVAudioPCMBuffer) -> AVAudioFrameCount {
        guard let samples = buffer.floatChannelData else { return buffer.frameLength }
        let rate = buffer.format.sampleRate
        let window = max(1, Int(rate * 0.1))
        let count = Int(buffer.frameLength)
        let searchStart = max(window, count - Int(rate * 10))
        var bestFrame = count
        var lowestEnergy = Double.infinity
        for start in stride(from: searchStart, through: count - window, by: window) {
            var energy = 0.0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in start..<(start + window) {
                    energy += Double(samples[channel][frame] * samples[channel][frame])
                }
            }
            if energy < lowestEnergy {
                lowestEnergy = energy
                bestFrame = start + window / 2
            }
        }
        return AVAudioFrameCount(bestFrame)
    }
}
