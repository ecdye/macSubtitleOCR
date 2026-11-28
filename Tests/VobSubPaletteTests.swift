//
// VobSubPaletteTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #150: a missing, short or garbled idx palette trapped with an index out of range when a
// subpicture selected a color past its end, and a subpicture without palette or alpha commands
// failed the whole file.

private let sintelIDX = try! String(
    contentsOf: Bundle.module.url(forResource: "sintel.idx", withExtension: nil)!, encoding: .utf8)
private let sintelSub = try! Data(contentsOf: URL(fileURLWithPath: TestFilePaths.sub.path))

/// sintel.idx with its `palette:` line replaced by `palette`, or removed when it is nil.
private func sintelIDX(palette: String?) -> String {
    sintelIDX.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
        line.hasPrefix("palette:") ? palette : String(line)
    }.joined(separator: "\n")
}

private func decodeSintel(palette: String?) throws -> [Subtitle] {
    try sintelSub.withUnsafeBytes { try VobSub($0, sintelIDX(palette: palette)).subtitles }
}

/// The RGBA palette of each decoded subtitle.
private func palettes(_ subtitles: [Subtitle]) -> [[UInt8]?] {
    subtitles.map(\.imagePalette)
}

// MARK: - Parsing the idx palette

@Test func vobSubIDXWithoutPaletteHasNone() throws {
    let idx = try VobSubIDX("id: en, index: 0\ntimestamp: 00:00:01:000, filepos: 000000000\n")
    #expect(idx.palette == nil)
}

@Test func vobSubIDXFillsAShortPaletteWithBlack() throws {
    let idx = try VobSubIDX("palette: 102030, ffffff\n")
    #expect(idx.palette == [0x10, 0x20, 0x30, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 42))
    let empty = try VobSubIDX("palette:\n")
    #expect(empty.palette == [UInt8](repeating: 0, count: 48))
}

@Test func vobSubIDXReadsPaletteColorsAsFFmpegDoes() throws {
    // strtoul in base 16: a 0x prefix, short and long numbers and a sign are all read, keeping the
    // low 24 bits, and runs of commas and spaces between colors are skipped.
    let idx = try VobSubIDX("palette: 0x10ff20, 12345 ,, 1234567,\tffffff -1\n")
    let colors: [UInt8] = [0x10, 0xFF, 0x20, 0x01, 0x23, 0x45, 0x23, 0x45, 0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    #expect(idx.palette == colors + [UInt8](repeating: 0, count: 33))
}

@Test func vobSubIDXStopsReadingAGarbledPalette() throws {
    // Text that is not a hex number reads as 0 and is not skipped, so every later color is 0 too.
    let idx = try VobSubIDX("palette: ff0000, zzzzzz, 00ff00\n")
    #expect(idx.palette == [0xFF, 0, 0] + [UInt8](repeating: 0, count: 45))
    let garbled = try VobSubIDX("palette: zzzzzz, 12345, , 1234567\n")
    #expect(garbled.palette == [UInt8](repeating: 0, count: 48))
}

// MARK: - Decoding with the idx palette

@Test func vobSubWithoutPaletteDecodesWithLayeredGrays() throws {
    let subtitles = try decodeSintel(palette: nil)
    let colored = try sintelSub.withUnsafeBytes { try VobSub($0, sintelIDX).subtitles }
    #expect(subtitles.count == 26)
    for (subtitle, original) in zip(subtitles, colored) {
        let palette = try #require(subtitle.imagePalette)
        let alpha = try #require(subtitle.imageAlpha)
        #expect(palette.count == 16)
        for i in 0 ..< 4 {
            #expect(palette[4 * i] == palette[4 * i + 1] && palette[4 * i] == palette[4 * i + 2])
            #expect(palette[4 * i + 3] == alpha[i] * 0x11)
        }
        // Sintel's text is white inside a black outline, and the grays draw it the same way.
        #expect(palette[4] == 0xFF && original.imagePalette?[4 ..< 7] == [0xFF, 0xFF, 0xFF])
        #expect(palette[8] == 0 && original.imagePalette?[8 ..< 11] == [0, 0, 0])
    }
}

@Test func vobSubShortPaletteMatchesOnePaddedWithBlack() throws {
    let short = try decodeSintel(palette: "palette: 000000, ffffff")
    let padded = try decodeSintel(palette: "palette: 000000, ffffff" + String(repeating: ", 000000", count: 14))
    #expect(short.count == 26)
    #expect(short.allSatisfy { $0.imagePalette != nil })
    #expect(palettes(short) == palettes(padded))
    #expect(short.map(\.imageData) == padded.map(\.imageData))
}

@Test func vobSubGarbledPaletteDecodes() throws {
    let garbled = try decodeSintel(palette: "palette: zzzzzz, 12345, , 1234567")
    let black = try decodeSintel(palette: "palette: " + Array(repeating: "000000", count: 16).joined(separator: ", "))
    #expect(garbled.count == 26)
    #expect(palettes(garbled) == palettes(black))
}

// MARK: - Choosing grays without a palette

/// Issue #156: without an idx palette FFmpeg's guessed grays made the text body black, which the
/// inverted image turns into hollow glyphs. The grays now follow how the colors are layered.
@Test(arguments: [
    // rows of the image, one digit per pixel, alpha, grays
    (["0110"], [0, 15, 15, 15], [0, 255, 0, 0]),
    (["0000000", "0222220", "0211120", "0222220", "0000000"], [0, 15, 15, 15], [0, 255, 0, 0]),
    // The body may be any of the colors.
    (["0000000", "0111110", "0133310", "0111110", "0000000"], [0, 15, 15, 15], [0, 0, 0, 255]),
    // An anti-aliasing color between body and outline takes the middle gray.
    (["000000000", "033333330", "032222230", "032111230", "032222230", "033333330", "000000000"],
     [0, 15, 15, 15], [0, 255, 127, 0]),
    // The alphas, not the color numbers, say what is transparent, and the image edge counts as outside.
    (["22222", "21112", "22222"], [15, 15, 15, 0], [0, 255, 0, 0]),
    (["3333", "3113", "3333"], [15, 15, 15, 0], [0, 255, 0, 0]),
    // Of two colors lying as deep, the lower is taken as inner; unused and transparent ones are black.
    (["12"], [0, 15, 15, 15], [0, 255, 0, 0]),
    (["0000"], [0, 15, 15, 15], [0, 0, 0, 0]),
    (["0123"], [0, 0, 0, 0], [0, 0, 0, 0])
] as [([String], [UInt8], [UInt8])])
func vobSubLayeredGrays(rows: [String], alpha: [UInt8], grays: [UInt8]) {
    let image = Data(rows.joined().map { UInt8(String($0))! })
    #expect(VobSubParser.layeredGrays(image: image, width: rows[0].count, alpha: alpha) == grays)
}

@Test func vobSubLayeredGraysWithoutAnImage() {
    #expect(VobSubParser.layeredGrays(image: Data(), width: 0, alpha: [15, 15, 15, 15]) == [0, 0, 0, 0])
    #expect(VobSubParser.layeredGrays(image: Data([1, 2]), width: 0, alpha: [15, 15, 15, 15]) == [0, 0, 0, 0])
}

// MARK: - Missing palette or alpha commands

/// A pack header with no stuffing, as a VobSub `.sub` file carries before every PES packet.
private let packHeader: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8]

/// One pack holding a 4x2 subpicture at PTS 0 whose only control sequence runs `commands`, the
/// display area and line offsets.
private func pack(commands: [UInt8]) -> [UInt8] {
    let rle: [UInt8] = [0x12, 0x11]
    let controlOffset = 4 + rle.count
    let control: [UInt8] = [0, 0, UInt8(controlOffset >> 8), UInt8(controlOffset & 0xFF)] + commands
        + [0x05, 0x00, 0x00, 0x03, 0x00, 0x00, 0x01, 0x06, 0x00, 0x05, 0x00, 0x04, 0x01, 0xFF]
    let size = 4 + rle.count + control.count
    let spu = [UInt8(size >> 8), UInt8(size & 0xFF), UInt8(controlOffset >> 8), UInt8(controlOffset & 0xFF)]
        + rle + control
    let body: [UInt8] = [0x81, 0x80, 5, 0x21, 0x00, 0x01, 0x00, 0x01, 0x20] + spu
    return packHeader + [0, 0, 1, 0xBD, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
}

@Test(arguments: [
    [0x01, 0x04, 0xFF, 0xF0], // No palette command
    [0x01, 0x03, 0x32, 0x10], // No alpha command
    [0x01] // Neither
] as [[UInt8]])
func vobSubWithoutPaletteOrAlphaCommandIsAPlaceholder(commands: [UInt8]) throws {
    let good = pack(commands: [0x01, 0x03, 0x32, 0x10, 0x04, 0xFF, 0xF0])
    let bad = pack(commands: commands)
    let bytes = bad + good
    let idx = """
    palette: 000000, ffffff, 808080, 404040
    id: en, index: 0
    timestamp: 00:00:01:000, filepos: 000000000
    timestamp: 00:00:02:000, filepos: \(String(bad.count, radix: 16))
    """
    let subtitles = try bytes.withUnsafeBytes { try VobSub($0, idx).subtitles }
    #expect(subtitles.count == 2)
    #expect(subtitles[0].imageData == nil)
    #expect(subtitles[0].startTimestamp == 1)
    // The subtitle after it still decodes, its first color transparent.
    let colors: [[UInt8]] = [[0, 0, 0, 0], [0xFF, 0xFF, 0xFF, 0xFF], [0x80, 0x80, 0x80, 0xFF], [0x40, 0x40, 0x40, 0xFF]]
    #expect(subtitles[1].imagePalette == colors.flatMap(\.self))
}

#if FFMPEG

// MARK: - Agreement with FFmpeg

private struct Point: Hashable {
    let x: Int
    let y: Int
}

/// The RGBA color of each visible pixel of a subtitle, by its position on the screen.
///
/// FFmpeg crops the transparent border off a subpicture, so the two decoders' bitmaps differ in
/// size and offset but not in what they show.
private func visiblePixels(_ subtitle: Subtitle) throws -> [Point: [UInt8]] {
    let data = try #require(subtitle.imageData)
    let palette = try #require(subtitle.imagePalette)
    let width = try #require(subtitle.imageWidth)
    let x = subtitle.imageXOffset ?? 0
    let y = subtitle.imageYOffset ?? 0
    var pixels = [Point: [UInt8]]()
    for (position, index) in data.enumerated() {
        let offset = Int(index) * 4
        guard offset + 3 < palette.count, palette[offset + 3] != 0 else { continue }
        pixels[Point(x: x + position % width, y: y + position / width)] = Array(palette[offset ..< offset + 4])
    }
    return pixels
}

@Test(arguments: [
    nil,
    "palette: 000000, ffffff",
    "palette: zzzzzz, 12345, , 1234567",
    "palette: 000000, 0000ff, 00ff00, ff0000, ffff00, ff00ff, 00ffff, ffffff, 808000, 8080ff, 800080, 80ff80, "
        + "008080, ff8080, 555555, aaaaaa"
] as [String?])
func vobSubPaletteMatchesFFmpegDecoder(palette: String?) throws {
    let directory = URL.temporaryDirectory.appendingPathComponent("VobSubPaletteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sub = directory.appendingPathComponent("sintel.sub")
    let idx = directory.appendingPathComponent("sintel.idx")
    try sintelSub.write(to: sub)
    try sintelIDX(palette: palette).write(to: idx, atomically: true, encoding: .utf8)

    let ours = try VobSub(sub, idx).subtitles
    let ffmpeg = try #require(FFmpeg(idx.path).subtitleTracks.values.first)
    try #require(ours.count == ffmpeg.count)
    for (mine, theirs) in zip(ours, ffmpeg) {
        let pixels = try visiblePixels(mine)
        #expect(!pixels.isEmpty)
        if palette == nil {
            // Without a palette the grays are chosen for OCR rather than as FFmpeg guesses them, but
            // the same pixels show, in the same alphas.
            #expect(try pixels.mapValues { $0[3] } == visiblePixels(theirs).mapValues { $0[3] },
                    "subtitle \(mine.index)")
        } else {
            #expect(try pixels == visiblePixels(theirs), "subtitle \(mine.index)")
        }
    }
}
#endif
