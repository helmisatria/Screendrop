import AppKit
import CoreGraphics
import CoreText
import Foundation

nonisolated enum RecordingCaptionRenderer {
    static func draw(text: String, karaoke: KaraokeTimeline.Line?, style: SubtitleBarStyle,
                     canvasSize: CGSize, in context: CGContext) {
        let metrics = SubtitleBarMetrics(canvasSize: canvasSize, style: style)
        let width = metrics.maximumTextWidth(canvasWidth: canvasSize.width)
        var fontSize = metrics.fontSize
        var lines: [CTLine] = []
        for _ in 0..<4 {
            let attributed = attributedText(text, karaoke: karaoke, style: style, size: fontSize)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
            lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
            if lines.count <= SubtitleBarMetrics.maximumLineCount || fontSize <= 4 { break }
            fontSize *= CGFloat(SubtitleBarMetrics.maximumLineCount) / CGFloat(lines.count)
        }
        guard !lines.isEmpty else { return }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let widths = lines.map { line in
            var a: CGFloat = 0, d: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil))
            ascent = max(ascent, a)
            descent = max(descent, d)
            return width
        }
        guard let widest = widths.max(), widest > 0 else { return }
        let advance = (ascent + descent) * SubtitleBarMetrics.lineSpacingFactor
        let height = ascent + descent + advance * CGFloat(lines.count - 1) + metrics.paddingVertical * 2
        let bar = CGRect(x: (canvasSize.width - widest) / 2 - metrics.paddingHorizontal,
                         y: canvasSize.height * (1 - style.clampedVerticalPosition) - height / 2,
                         width: widest + metrics.paddingHorizontal * 2, height: height)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(style.backgroundColor.cgColor)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: metrics.cornerRadius,
                              cornerHeight: metrics.cornerRadius, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        let baseline = bar.maxY - metrics.paddingVertical - ascent
        for (index, line) in lines.enumerated() {
            let origin = CGPoint(x: bar.midX - widths[index] / 2, y: baseline - advance * CGFloat(index))
            if style.highlightBackgroundColor.alpha > 0 {
                for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard attributes["ScreendropActiveWord"] as? Bool == true else { continue }
                    var position = CGPoint.zero
                    CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                    var a: CGFloat = 0, d: CGFloat = 0
                    let runWidth = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &a, &d, nil))
                    let rect = CGRect(x: origin.x + position.x - fontSize * 0.08,
                                      y: origin.y - d - fontSize * 0.05,
                                      width: runWidth + fontSize * 0.16, height: a + d + fontSize * 0.1)
                    context.setFillColor(style.highlightBackgroundColor.cgColor)
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: fontSize * 0.12,
                                          cornerHeight: fontSize * 0.12, transform: nil))
                    context.fillPath()
                }
            }
            context.textPosition = origin
            CTLineDraw(line, context)
        }
    }

    static func font(style: SubtitleBarStyle, size: CGFloat) -> CTFont {
        if let selected = style.googleFont {
            return CTFontCreateWithName(selected.postScriptName as CFString, size, nil)
        }
        let descriptor = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        return CTFontCreateWithFontDescriptor((descriptor.withDesign(.rounded) ?? descriptor) as CTFontDescriptor, size, nil)
    }

    private static func attributedText(_ plain: String, karaoke: KaraokeTimeline.Line?,
                                       style: SubtitleBarStyle, size: CGFloat) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let font = font(style: style, size: size)
        guard style.highlightsSpokenWord, let karaoke, !karaoke.words.isEmpty else {
            return NSAttributedString(string: plain, attributes: [fontKey: font, colorKey: style.textColor.cgColor])
        }
        let result = NSMutableAttributedString()
        for index in karaoke.words.indices {
            var color = style.textColor
            if index == karaoke.activeIndex { color = style.highlightColor }
            else if index >= karaoke.spokenCount { color.alpha *= SubtitleBarMetrics.karaokeUpcomingAlpha }
            let piece = NSMutableAttributedString(string: karaoke.textPiece(at: index),
                attributes: [fontKey: font, colorKey: color.cgColor])
            if index == karaoke.activeIndex {
                let word = piece.string.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = (piece.string as NSString).range(of: word)
                if range.location != NSNotFound, range.length > 0 {
                    piece.addAttribute(NSAttributedString.Key("ScreendropActiveWord"), value: true, range: range)
                }
            }
            result.append(piece)
        }
        return result
    }
}
