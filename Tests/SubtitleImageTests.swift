//
// SubtitleImageTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #87: a palette index with no palette entry was drawn as opaque white, which createImage
// treated as ink, inverted to black, and included in the crop.

/// Two entries: transparent, then opaque white ink.
private let twoColorPalette: [UInt8] = [0, 0, 0, 0, 255, 255, 255, 255]

/// The RGBA bytes of `image`, drawn into a buffer of the same size.
private func rgbaPixels(of image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big
        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: bitmapInfo.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

@Test func outOfPaletteIndicesAreTransparent() throws {
    let width = 8
    let height = 6
    var indices = Data(repeating: 0, count: width * height)
    // Ink at (1, 1), an out-of-range index at (6, 4), and one whose palette entry would run past
    // the end of a palette that claims more colors than it holds at (6, 1).
    indices[1 * width + 1] = 1
    indices[4 * width + 6] = 7
    indices[1 * width + 6] = 2

    let source = SubtitleImageSource(width: width, height: height, imageData: indices,
                                     imagePalette: twoColorPalette, numberOfColors: 3)
    let image = try #require(source.createImage(false))

    // Only the ink pixel is cropped to, and it is inverted to black on an opaque background.
    #expect(image.width == 1)
    #expect(image.height == 1)
    #expect(try rgbaPixels(of: image) == [0, 0, 0, 255])
}

@Test func frameOfOnlyOutOfPaletteIndicesIsEmpty() {
    let source = SubtitleImageSource(width: 4, height: 2, imageData: Data(repeating: 7, count: 8),
                                     imagePalette: twoColorPalette, numberOfColors: 2)
    #expect(source.createImage(false) == nil)
    #expect(source.createImage(true) == nil)
}
