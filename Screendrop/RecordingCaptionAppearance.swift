import AppKit
import CoreGraphics
import Foundation
import SwiftUI

nonisolated struct CaptionColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension CaptionColor {
    var color: Color { Color(cgColor: cgColor) }

    init(_ color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: rgb.redComponent, green: rgb.greenComponent,
                  blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}

nonisolated struct StoredCaptionAppearance: Codable, Equatable, Sendable {
    var font: RecordingGoogleFont?
    var text: CaptionColor
    var background: CaptionColor
    var highlight: CaptionColor
    var highlightBackground: CaptionColor

    init(_ style: SubtitleBarStyle) {
        font = style.googleFont
        text = style.textColor
        background = style.backgroundColor
        highlight = style.highlightColor
        highlightBackground = style.highlightBackgroundColor
    }

    func apply(to style: inout SubtitleBarStyle) {
        style.googleFont = font
        style.textColor = text
        style.backgroundColor = background
        style.highlightColor = highlight
        style.highlightBackgroundColor = highlightBackground
    }
}
