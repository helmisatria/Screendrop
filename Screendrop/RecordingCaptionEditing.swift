import Foundation

nonisolated enum RecordingCaptionEditing {
    static func split(_ cue: RecordingSubtitleCue, selection: NSRange,
                      words: [RecordingTranscriptWord]) -> [RecordingSubtitleCue]? {
        guard let range = Range(selection, in: cue.text) else { return nil }
        let left = String(cue.text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(cue.text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty, cue.end - cue.start > 0.04 else { return nil }
        let tokens = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let leftTokens = left.split(whereSeparator: \.isWhitespace)
        let timed = words.filter { $0.start >= cue.start - 0.001 && $0.start < cue.end }
        // Only trust word timing when the edited text still matches the recognition.
        // Otherwise divide the cue by text length, including splits inside a word.
        let boundary: Double
        if selection.length == 0, tokens == timed.map(\.displayText),
           leftTokens.count < tokens.count,
           tokens == (left + " " + right).split(whereSeparator: \.isWhitespace).map(String.init) {
            boundary = timed[leftTokens.count].start
        } else {
            boundary = cue.start + (cue.end - cue.start) * Double(left.count) / Double(left.count + right.count)
        }
        let time = min(cue.end - 0.02, max(cue.start + 0.02, boundary))
        var first = cue
        first.text = left
        first.end = time
        return [first, RecordingSubtitleCue(start: time, end: cue.end, text: right)]
    }
}

nonisolated struct CaptionEditorFocus: Equatable {
    var token = UUID()
    var id: UUID
    var offset: Int
}
