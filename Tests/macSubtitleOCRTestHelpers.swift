//
// macSubtitleOCRTestHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/3/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import CoreGraphics
import CoreText
import Foundation
@testable import macSubtitleOCR
import Testing

/// Function to compute the Levenshtein Distance between two strings
func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let empty = [Int](repeating: 0, count: rhs.count)
    var last = [Int](0 ... rhs.count)

    for (i, char1) in lhs.enumerated() {
        var cur = [i + 1] + empty
        for (j, char2) in rhs.enumerated() {
            cur[j + 1] = char1 == char2 ? last[j] : min(last[j], last[j + 1], cur[j]) + 1
        }
        last = cur
    }
    return last.last!
}

/// Function to calculate the similarity percentage
func similarityPercentage(of lhs: String, and rhs: String) -> Double {
    let distance = levenshteinDistance(lhs, rhs)
    let maxLength = max(lhs.count, rhs.count)

    if maxLength == 0 {
        return 100.0 // Both strings are empty, they match 100%
    }

    return (1.0 - Double(distance) / Double(maxLength)) * 100
}

/// Draws `text` as a subtitle frame: white glyphs on a black ground, stored the way a decoder hands
/// one over, as a grayscale palette with the drawn pixels as indices into it.
///
/// The frames in `ocr-samples.json` are real subtitle glyphs because rendered ones are too clean to
/// stand in for anti-aliasing. What the callers here provoke is a recognizer decision about the words
/// or about the size of the frame rather than about the shapes, so drawing the text is enough.
func renderedSubtitle(_ text: String, index: Int, pointSize: CGFloat = 40, padding: Int = 4,
                      transparent: Bool = false) throws -> Subtitle {
    let font = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    // With no padding the frame is cropped to the glyphs' outlines, as a subpicture is cropped to its ink.
    let bounds = CTLineGetBoundsWithOptions(line, padding == 0 ? .useGlyphPathBounds : [])
    let width = Int(bounds.width.rounded(.up)) + 2 * padding
    let height = Int(bounds.height.rounded(.up)) + 2 * padding

    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.textPosition = CGPoint(x: CGFloat(padding) - bounds.minX, y: CGFloat(padding) - bounds.minY)
    CTLineDraw(line, context)

    let pixels = try #require(context.data)
    // A gray level doubles as its own palette index. Opaque, the text sits on black; transparent, the
    // level is the coverage of white text over nothing, as a DVD subpicture is drawn.
    let palette: [UInt8] = (0 ..< 256).flatMap { level -> [UInt8] in
        let gray = UInt8(level)
        return transparent ? [255, 255, 255, gray] : [gray, gray, gray, 255]
    }

    return Subtitle(index: index,
                    startTimestamp: 0,
                    endTimestamp: 1,
                    imageWidth: width,
                    imageHeight: height,
                    imageData: Data(bytes: pixels, count: width * height),
                    imagePalette: palette,
                    numberOfColors: 256)
}
