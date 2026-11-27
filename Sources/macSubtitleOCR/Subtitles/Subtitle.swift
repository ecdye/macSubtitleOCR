//
// Subtitle.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation

/// Subtitle instances are no longer shared across OCR tasks; they are only moved
/// between isolated contexts when collecting final results.
final class Subtitle: @unchecked Sendable {
    var index: Int
    var text: String?
    var startTimestamp: TimeInterval?
    var imageXOffset: Int?
    var imageYOffset: Int?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageData: Data?
    var imagePalette: [UInt8]?
    var imageAlpha: [UInt8]?
    var numberOfColors: Int?
    var endTimestamp: TimeInterval?
    var evenOffset: Int?
    var oddOffset: Int?

    init(index: Int, text: String? = nil, startTimestamp: TimeInterval? = nil, endTimestamp: TimeInterval? = nil,
         imageXOffset: Int? = nil, imageYOffset: Int? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil,
         imageData: Data? = nil, imagePalette: [UInt8]? = nil, imageAlpha: [UInt8]? = nil, numberOfColors: Int? = nil,
         evenOffset: Int? = nil, oddOffset: Int? = nil) {
        self.index = index
        self.text = text
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.imageXOffset = imageXOffset
        self.imageYOffset = imageYOffset
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageData = imageData
        self.imagePalette = imagePalette
        self.imageAlpha = imageAlpha
        self.numberOfColors = numberOfColors
        self.evenOffset = evenOffset
        self.oddOffset = oddOffset
    }

    // MARK: - Functions

    func makeImageSource() -> SubtitleImageSource? {
        guard
            let imageWidth,
            let imageData,
            let imagePalette,
            let numberOfColors,
            imageWidth > 0
        else {
            return nil
        }

        let availableHeight = imageData.count / imageWidth
        let resolvedHeight = min(imageHeight ?? availableHeight, availableHeight)
        guard resolvedHeight > 0 else {
            return nil
        }

        return SubtitleImageSource(width: imageWidth,
                                   height: resolvedHeight,
                                   imageData: imageData,
                                   imagePalette: imagePalette,
                                   numberOfColors: numberOfColors)
    }
}

struct SubtitleImageSource {
    let width: Int
    let height: Int
    let imageData: Data
    let imagePalette: [UInt8]
    let numberOfColors: Int

    // MARK: - Methods

    /// The RGBA pixel each palette index is drawn as, in memory order, and whether it is visible.
    ///
    /// Every pixel depends only on its palette index, so the whole conversion is worked out once per
    /// index rather than once per pixel. An index whose palette entry has alpha is ink and counts toward
    /// the crop. Invert rather than flatten ink to a single color: subtitle glyphs are anti-aliased and
    /// usually carry an outline, and forcing every visible pixel to one value fattens the strokes until
    /// counters close up and OCR misreads them. Transparent entries, and indices with no palette entry
    /// at all, become opaque white so the glyphs sit on a plain background.
    private func pixelTable(_ invert: Bool) -> (colors: [UInt32], visible: [Bool]) {
        var colors = [UInt32](repeating: UInt32.max, count: 256)
        var visible = [Bool](repeating: false, count: 256)
        for colorIndex in 0 ..< min(max(numberOfColors, 0), 256) {
            let paletteOffset = colorIndex * 4
            guard paletteOffset + 3 < imagePalette.count else { break }
            let alpha = imagePalette[paletteOffset + 3]
            guard alpha > 0 else { continue }
            var red = imagePalette[paletteOffset]
            var green = imagePalette[paletteOffset + 1]
            var blue = imagePalette[paletteOffset + 2]
            if !invert {
                red = 255 - red
                green = 255 - green
                blue = 255 - blue
            }
            let pixel = UInt32(red) | UInt32(green) << 8 | UInt32(blue) << 16 | UInt32(alpha) << 24
            colors[colorIndex] = pixel.littleEndian
            visible[colorIndex] = true
        }
        return (colors, visible)
    }

    /// Converts the palette indices to a CGImage cropped to the visible pixels, or nil if there are none.
    func createImage(_ invert: Bool) -> CGImage? {
        let pixelCount = width * height
        guard width > 0, height > 0, imageData.count >= pixelCount else {
            return nil
        }

        let (colors, visible) = pixelTable(invert)
        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1
        var croppedData = Data()

        imageData.withUnsafeBytes { (indices: UnsafeRawBufferPointer) in
            let indices = indices.bindMemory(to: UInt8.self)
            visible.withUnsafeBufferPointer { visible in
                for y in 0 ..< height {
                    let row = y * width
                    var first = 0
                    while first < width, !visible[Int(indices[row + first])] {
                        first += 1
                    }
                    guard first < width else { continue }
                    var last = width - 1
                    while !visible[Int(indices[row + last])] {
                        last -= 1
                    }
                    minX = min(minX, first)
                    maxX = max(maxX, last)
                    minY = min(minY, y)
                    maxY = y
                }
            }
            guard maxX >= 0 else { return }

            let croppedWidth = maxX - minX + 1
            let croppedHeight = maxY - minY + 1
            croppedData = Data(count: croppedWidth * croppedHeight * 4)
            croppedData.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                let output = output.bindMemory(to: UInt32.self)
                colors.withUnsafeBufferPointer { colors in
                    var outputIndex = 0
                    for y in minY ... maxY {
                        let row = y * width
                        for x in minX ... maxX {
                            output[outputIndex] = colors[Int(indices[row + x])]
                            outputIndex += 1
                        }
                    }
                }
            }
        }

        guard maxX >= 0, let provider = CGDataProvider(data: croppedData as CFData) else { return nil }
        // Subtitle palettes carry straight alpha, so `premultipliedLast` is not what the buffer holds.
        // It composites to the same pixels regardless: wherever alpha is partial these palettes pin the
        // color to black or white, and both readings agree at either end. Recognition does not agree,
        // though. Vision reads the two differently despite the identical pixels, and declaring the
        // straight alpha it really is reads measurably worse, so the buffer is described this way on
        // purpose.
        let bitmapInfo = CGBitmapInfo.byteOrder32Big
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let croppedWidth = maxX - minX + 1
        return CGImage(
            width: croppedWidth,
            height: maxY - minY + 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: croppedWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
