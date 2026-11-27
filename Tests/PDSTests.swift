//
// PDSTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #85: chroma offsets below 128 were clamped to zero, so every palette color with a negative
// Cr or Cb came out wrong, yellow as a pale near white.
//
// Issue #145: the palette rounded differently from FFmpeg's PGS decoder, so the two decoders gave
// Vision images that differed by one level per channel, enough to change how some cues read. The
// conversion now follows FFmpeg's fixed point arithmetic exactly, including its choice of BT.601 for
// video of up to 576 lines and BT.709 above.

/// Palette entries as (index, Y, Cr, Cb, alpha).
private let entries: [(UInt8, UInt8, UInt8, UInt8, UInt8)] = [
    (1, 126, 128, 128, 0xFF), // Neutral gray
    (2, 210, 146, 16, 0xFF), // Yellow: Cb well below 128
    (3, 41, 110, 240, 0x80), // Blue: Cr below 128
    (4, 145, 34, 54, 0xFF), // Green: both below 128
    (5, 16, 128, 128, 0xFF), // Video black
    (6, 235, 128, 128, 0xFF), // Video white
    (7, 0, 128, 128, 0x40), // Luma below video black
    (8, 255, 128, 128, 0xFF), // Luma above video white
    (9, 81, 240, 90, 0xFF), // Red
    (10, 128, 0, 255, 0xC0), // Chroma at the extremes
    (11, 128, 255, 0, 0xFF),
    (12, 17, 129, 127, 0x20), // Near black
    (13, 234, 127, 129, 0xFF), // Near white
    (14, 16, 48, 16, 0xFF), // Dark greens, where rounding in floating point gave one level less
    (15, 16, 56, 104, 0xFF)
]

/// RGB of each entry as FFmpeg decodes it for 480 and 576 line video, with the BT.601 matrix.
private let expectedBT601: [[Int]] = [
    [128, 128, 128], [255, 255, 0], [0, 0, 255], [0, 255, 1], [0, 0, 0], [255, 255, 255], [0, 0, 0],
    [255, 255, 255], [254, 0, 0], [0, 185, 255], [255, 77, 0], [3, 1, 0], [252, 254, 255],
    [0, 109, 0], [0, 68, 0]
]

/// RGB of each entry as FFmpeg decodes it for video of more than 576 lines, with the BT.709 matrix.
private let expectedBT709: [[Int]] = [
    [128, 128, 128], [255, 240, 0], [0, 15, 255], [0, 216, 0], [0, 0, 0], [255, 255, 255], [0, 0, 0],
    [255, 255, 255], [255, 24, 0], [0, 172, 255], [255, 90, 0], [3, 1, 0], [252, 254, 255],
    [0, 67, 0], [0, 44, 0]
]

/// Parses a palette definition segment holding `entries` for video `videoHeight` lines high.
private func palette(_ entries: [(UInt8, UInt8, UInt8, UInt8, UInt8)], videoHeight: Int) throws -> [UInt8] {
    var bytes: [UInt8] = [0x00, 0x00] // Palette ID and version
    for entry in entries {
        bytes += [entry.0, entry.1, entry.2, entry.3, entry.4]
    }
    return try bytes.withUnsafeBytes { try PDS($0, 0, bytes.count, videoHeight: videoHeight).palette }
}

private func rgba(_ palette: [UInt8], at index: Int) -> [Int] {
    palette[index * 4 ..< index * 4 + 4].map(Int.init)
}

private func expectPalette(_ palette: [UInt8], _ expected: [[Int]], _ name: String) {
    for (entry, rgb) in zip(entries, expected) {
        #expect(rgba(palette, at: Int(entry.0)) == rgb + [Int(entry.4)], "\(name): index \(entry.0)")
    }
}

@Test(arguments: [480, 576])
func paletteMatchesFFmpegForStandardDefinition(videoHeight: Int) throws {
    try expectPalette(palette(entries, videoHeight: videoHeight), expectedBT601, "\(videoHeight) lines")
}

/// FFmpeg uses BT.709 above 576 lines, and when the height is not known.
@Test(arguments: [577, 720, 1080, 2160, 0])
func paletteMatchesFFmpegForHighDefinition(videoHeight: Int) throws {
    try expectPalette(palette(entries, videoHeight: videoHeight), expectedBT709, "\(videoHeight) lines")
}

@Test func paletteConvertsNegativeChroma() throws {
    let palette = try palette(entries, videoHeight: 1080)

    // Neutral chroma gives an exact gray.
    let gray = rgba(palette, at: 1)
    #expect(gray[0] == gray[1] && gray[1] == gray[2])

    // Yellow is high in red and green and low in blue, not the near white the clamped chroma gave.
    let yellow = rgba(palette, at: 2)
    #expect(yellow[0] > 220 && yellow[1] > 200 && yellow[2] < 40)

    // Blue is high in blue and low in red.
    let blue = rgba(palette, at: 3)
    #expect(blue[2] > 200 && blue[0] < 40)

    // Green is high in green only.
    let green = rgba(palette, at: 4)
    #expect(green[1] > 200 && green[0] < 40 && green[2] < 40)
}

// MARK: - Through the PGS parser

private func bigEndian(_ value: Int, bytes: Int = 2) -> [UInt8] {
    (0 ..< bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
}

private func segment(_ type: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    Array("PG".utf8) + bigEndian(90000, bytes: 4) + [0, 0, 0, 0] + [type] + bigEndian(payload.count) + payload
}

/// A display set for a 720 pixel wide video `videoHeight` lines high, showing one row with a pixel of
/// each entry's color in turn, followed by the display set clearing it.
private func stream(videoHeight: Int) -> [UInt8] {
    let video = bigEndian(720) + bigEndian(videoHeight) + [0x10]
    let presentation = segment(0x16, video + bigEndian(0) + [0x80, 0x00, 0x00, 0x01]
        + bigEndian(0) + [0x00, 0x00] + bigEndian(10) + bigEndian(10))
    let window = segment(0x17, [0x01, 0x00] + bigEndian(0) + bigEndian(0) + bigEndian(720) + bigEndian(videoHeight))
    var paletteSegment: [UInt8] = [0x00, 0x00]
    for entry in entries {
        paletteSegment += [entry.0, entry.1, entry.2, entry.3, entry.4]
    }
    let rle = entries.map(\.0) + [0x00, 0x00]
    let object = segment(0x15, bigEndian(0) + [0x00, 0xC0] + bigEndian(rle.count + 4, bytes: 3)
        + bigEndian(entries.count) + bigEndian(1) + rle)
    let clear = segment(0x16, video + bigEndian(1) + [0x00, 0x00, 0x00, 0x00]) + window + segment(0x80)
    return presentation + window + segment(0x14, paletteSegment) + object + segment(0x80) + clear
}

/// The RGBA of each pixel of a subtitle's image.
private func pixels(_ subtitle: Subtitle) throws -> [[Int]] {
    let data = try #require(subtitle.imageData)
    let palette = try #require(subtitle.imagePalette)
    return data.map { rgba(palette, at: Int($0)) }
}

/// The PGS parser picks the matrix from the video height in the presentation composition.
@Test(arguments: [(576, expectedBT601), (1080, expectedBT709)])
func pgsPaletteFollowsVideoHeight(videoHeight: Int, expected: [[Int]]) throws {
    let pgs = try Data(stream(videoHeight: videoHeight)).withUnsafeBytes { try PGS($0) }
    let subtitle = try #require(pgs.subtitles.first)
    #expect(try pixels(subtitle) == zip(expected, entries).map { $0 + [Int($1.4)] })
}

#if FFMPEG
/// FFmpeg decodes the same display set to exactly the same colors as the internal decoder.
@Test(arguments: [480, 576, 720, 1080])
func pgsPaletteMatchesFFmpegDecoder(videoHeight: Int) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pds-\(videoHeight)-\(UUID().uuidString).sup")
    try Data(stream(videoHeight: videoHeight)).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let ffmpeg = try #require(FFmpeg(url.path).subtitleTracks.values.first?.first)
    let pgs = try #require(PGS(url).subtitles.first)
    let decoded = try pixels(ffmpeg)
    #expect(try pixels(pgs) == decoded)
    #expect(decoded.map { Array($0.prefix(3)) } == (videoHeight <= 576 ? expectedBT601 : expectedBT709))
}
#endif
