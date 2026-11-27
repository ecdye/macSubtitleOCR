//
// SubtitleImageConversionTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #88: createImage converted every pixel through a per-pixel array, then made a second pass over
// the whole frame. It now converts through a per-index table and only the cropped region. These tests
// check it draws exactly what the previous conversion drew.

/// The image the previous conversion produced, with the cropped bytes it held.
private struct ReferenceImage {
    let image: CGImage
    let croppedBytes: [UInt8]
}

/// A copy of the conversion `createImage` replaced, kept to check the new one against. The cropped bytes
/// are only gathered when `collectingBytes` is set, so the benchmark times the conversion alone.
private func referenceImage(_ source: SubtitleImageSource, _ invert: Bool,
                            collectingBytes: Bool = true) -> ReferenceImage? {
    let width = source.width
    let height = source.height
    let pixelCount = width * height
    var rgbaData = Data(capacity: pixelCount * 4)
    for index in 0 ..< pixelCount {
        let colorIndex = Int(source.imageData[index])
        let paletteOffset = colorIndex * 4
        guard colorIndex < source.numberOfColors, paletteOffset + 3 < source.imagePalette.count else {
            rgbaData.append(contentsOf: [0, 0, 0, 0])
            continue
        }
        rgbaData.append(contentsOf: [
            source.imagePalette[paletteOffset],
            source.imagePalette[paletteOffset + 1],
            source.imagePalette[paletteOffset + 2],
            source.imagePalette[paletteOffset + 3]
        ])
    }
    guard rgbaData.count == pixelCount * 4 else { return nil }

    var minX = width
    var maxX = -1
    var minY = height
    var maxY = -1
    for y in 0 ..< height {
        for x in 0 ..< width {
            let pixelIndex = (y * width + x) * 4
            if rgbaData[pixelIndex + 3] > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                if !invert {
                    rgbaData[pixelIndex] = 255 - rgbaData[pixelIndex]
                    rgbaData[pixelIndex + 1] = 255 - rgbaData[pixelIndex + 1]
                    rgbaData[pixelIndex + 2] = 255 - rgbaData[pixelIndex + 2]
                }
            } else {
                rgbaData[pixelIndex] = 255
                rgbaData[pixelIndex + 1] = 255
                rgbaData[pixelIndex + 2] = 255
                rgbaData[pixelIndex + 3] = 255
            }
        }
    }

    guard minX < width, maxX >= 0, minY < height, maxY >= 0,
          let provider = CGDataProvider(data: rgbaData as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo.byteOrder32Big
        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    let croppedRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let cropped = image?.cropping(to: croppedRect) else { return nil }

    var croppedBytes: [UInt8] = []
    guard collectingBytes else { return ReferenceImage(image: cropped, croppedBytes: croppedBytes) }
    croppedBytes.reserveCapacity(cropped.width * cropped.height * 4)
    for y in minY ... maxY {
        let row = (y * width + minX) * 4
        croppedBytes.append(contentsOf: rgbaData[row ..< row + (maxX - minX + 1) * 4])
    }
    return ReferenceImage(image: cropped, croppedBytes: croppedBytes)
}

/// The RGBA bytes of `image`, drawn into a buffer in the format `createImage` declares.
private func renderedPixels(of image: CGImage) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big
        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drawn ? pixels : nil
}

/// Checks `source` converts to the same image as the previous conversion, inverted or not.
private func expectSameImage(_ source: SubtitleImageSource, _ label: String) {
    for invert in [false, true] {
        let expected = referenceImage(source, invert)
        let actual = source.createImage(invert)
        guard let expected, let actual else {
            #expect(expected == nil && actual == nil, "\(label) invert \(invert): only one image is empty")
            continue
        }
        #expect(actual.width == expected.image.width && actual.height == expected.image.height,
                "\(label) invert \(invert): size differs")
        // Cropping reports the byte order as the default rather than 32-bit big endian. With 8-bit
        // components both mean the bytes are in R, G, B, A order, so only the alpha has to agree.
        #expect(actual.alphaInfo == expected.image.alphaInfo, "\(label) invert \(invert): alpha differs")
        #expect(actual.bitsPerComponent == 8 && actual.bitsPerPixel == 32, "\(label) invert \(invert): depth differs")
        #expect(actual.bytesPerRow == actual.width * 4, "\(label) invert \(invert): rows are padded")
        let actualBytes = actual.dataProvider?.data.map { [UInt8]($0 as Data) }
        #expect(actualBytes == expected.croppedBytes, "\(label) invert \(invert): bytes differ")
        #expect(renderedPixels(of: actual) == renderedPixels(of: expected.image),
                "\(label) invert \(invert): rendered pixels differ")
    }
}

private func sintelPGSSources() throws -> [SubtitleImageSource] {
    try PGS(URL(fileURLWithPath: TestFilePaths.sup.path)).subtitles.compactMap { $0.makeImageSource() }
}

@Test func pgsImagesMatchPreviousConversion() throws {
    let sources = try sintelPGSSources()
    #expect(!sources.isEmpty)
    for (offset, source) in sources.enumerated() {
        expectSameImage(source, "sintel.sup #\(offset + 1)")
    }
}

@Test func vobSubImagesMatchPreviousConversion() throws {
    let sub = URL(fileURLWithPath: TestFilePaths.sub.path)
    let idx = sub.deletingPathExtension().appendingPathExtension("idx")
    let sources = try VobSub(sub, idx).subtitles.compactMap { $0.makeImageSource() }
    #expect(!sources.isEmpty)
    for (offset, source) in sources.enumerated() {
        expectSameImage(source, "sintel.sub #\(offset + 1)")
    }
}

/// A decoded frame from ocr-samples.json.
private struct SampleFrame: Decodable {
    let source: String
    let width: Int
    let height: Int
    let numberOfColors: Int
    let palette: Data
    let indices: Data
}

private struct SampleFrames: Decodable {
    let frames: [SampleFrame]
}

@Test func sampleFramesMatchPreviousConversion() throws {
    let url = try #require(Bundle.module.url(forResource: "ocr-samples.json", withExtension: nil))
    let frames = try JSONDecoder().decode(SampleFrames.self, from: Data(contentsOf: url)).frames
    #expect(!frames.isEmpty)
    for frame in frames {
        let subtitle = Subtitle(index: 1, imageWidth: frame.width, imageHeight: frame.height,
                                imageData: frame.indices, imagePalette: [UInt8](frame.palette),
                                numberOfColors: frame.numberOfColors)
        let source = try #require(subtitle.makeImageSource())
        expectSameImage(source, frame.source)
    }
}

/// A small seeded generator, so a failing random case can be reproduced.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// One of `values`, chosen by `generator`.
private func pick<T>(_ values: [T], using generator: inout SplitMix64) -> T {
    values[Int.random(in: 0 ..< values.count, using: &generator)]
}

@Test func randomImagesMatchPreviousConversion() {
    var generator = SplitMix64(state: 88)
    for trial in 0 ..< 2000 {
        let width = Int.random(in: 1 ... 12, using: &generator)
        let height = Int.random(in: 1 ... 12, using: &generator)
        // Palettes that claim more colors than they hold, fewer than the indices use, and lengths that
        // are not a whole number of entries.
        let numberOfColors = pick([0, 1, 2, 4, 16, 255, 256, Int.random(in: 0 ... 20, using: &generator)],
                                  using: &generator)
        let paletteLength = Int.random(in: 0 ... 80, using: &generator)
        let palette = (0 ..< paletteLength).map { offset -> UInt8 in
            // Leave many entries transparent, and some only faintly visible.
            if offset % 4 == 3 {
                return pick([0, 0, 1, 255, UInt8.random(in: 0 ... 255, using: &generator)], using: &generator)
            }
            return UInt8.random(in: 0 ... 255, using: &generator)
        }
        let maxIndex = Bool.random(using: &generator) ? 24 : 255
        // Extra trailing bytes past the frame are ignored.
        let extra = Int.random(in: 0 ... 3, using: &generator)
        let indices = Data((0 ..< width * height + extra).map { _ in
            UInt8.random(in: 0 ... UInt8(maxIndex), using: &generator)
        })
        let source = SubtitleImageSource(width: width, height: height, imageData: indices,
                                         imagePalette: palette, numberOfColors: numberOfColors)
        expectSameImage(source, "random #\(trial)")
    }
}

/// Times the conversion against the one it replaced. Set SUBTITLE_IMAGE_BENCHMARK to run it, preferably
/// with `swift test -c release -Xswiftc -enable-testing --filter subtitleImageBenchmark`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SUBTITLE_IMAGE_BENCHMARK"] != nil))
func subtitleImageBenchmark() throws {
    let sources = try sintelPGSSources()
    let iterations = 50
    let clock = ContinuousClock()
    var checksum = 0
    let before = clock.measure {
        for _ in 0 ..< iterations {
            for source in sources {
                checksum &+= referenceImage(source, false, collectingBytes: false)?.image.width ?? 0
            }
        }
    }
    let after = clock.measure {
        for _ in 0 ..< iterations {
            for source in sources {
                checksum &+= source.createImage(false)?.width ?? 0
            }
        }
    }
    print("Converted \(sources.count) images \(iterations) times: before \(before), after \(after) (\(checksum))")
}
