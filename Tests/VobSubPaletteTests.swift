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

/// The commands setting a 4x2 display area at x = 16 * `column` and the line offsets of the image
/// `pack` writes, whose first line starts `fieldOffset` bytes into the subpicture.
private func imageCommands(column: UInt8 = 0, fieldOffset: UInt8 = 5) -> [UInt8] {
    [0x05, column, 0x00, column << 4 | 3, 0x00, 0x00, 0x01, 0x06, 0x00, fieldOffset, 0x00, 0x04]
}

/// One pack holding a 4x2 subpicture whose only control sequence runs `commands`, the display area
/// and line offsets.
///
/// The subpicture is presented at `second` and drawn at x = 16 * `column`, so that subpictures
/// drawn alike still differ. `fieldOffset` is the first line's offset into the RLE data.
private func pack(commands: [UInt8], second: Int = 0, column: UInt8 = 0, fieldOffset: UInt8 = 5) -> [UInt8] {
    pack(sequences: [commands + imageCommands(column: column, fieldOffset: fieldOffset) + [0x01]], second: second)
}

/// One pack holding a subpicture of the 4x2 image `imageCommands` describes, whose control
/// sequences run `sequences` in turn, each delayed one unit more than the one before it.
private func pack(sequences: [[UInt8]], second: Int = 0) -> [UInt8] {
    let rle: [UInt8] = [0x12, 0x11]
    let controlOffset = 4 + rle.count
    var control = [UInt8]()
    for (index, commands) in sequences.enumerated() {
        let start = controlOffset + control.count
        let next = index == sequences.count - 1 ? start : start + 4 + commands.count + 1
        control += [0, UInt8(index), UInt8(next >> 8), UInt8(next & 0xFF)] + commands + [0xFF]
    }
    let size = 4 + rle.count + control.count
    let spu = [UInt8(size >> 8), UInt8(size & 0xFF), UInt8(controlOffset >> 8), UInt8(controlOffset & 0xFF)]
        + rle + control
    let pts = UInt64(second) * 90000
    let ptsBytes: [UInt8] = [
        0x21 | UInt8(pts >> 29 & 0x0E), UInt8(pts >> 22 & 0xFF), UInt8(pts >> 14 & 0xFE) | 1,
        UInt8(pts >> 7 & 0xFF), UInt8(pts << 1 & 0xFE) | 1
    ]
    let body: [UInt8] = [0x81, 0x80, 5] + ptsBytes + [0x20] + spu
    return packHeader + [0, 0, 1, 0xBD, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
}

private let idxPalette = "palette: 000000, ffffff, 808080, 404040"

/// The idx for a `.sub` holding `packs` one after another, one subtitle each.
private func idx(for packs: [[UInt8]], palette: String? = idxPalette) -> String {
    var offset = 0
    var lines = palette.map { [$0] } ?? []
    lines.append("id: en, index: 0")
    for (index, pack) in packs.enumerated() {
        lines.append("timestamp: 00:00:\(String(format: "%02d", index + 1)):000, filepos: \(String(offset, radix: 16))")
        offset += pack.count
    }
    return lines.joined(separator: "\n")
}

private func decodePacks(_ packs: [[UInt8]]) throws -> [Subtitle] {
    let bytes = packs.flatMap(\.self)
    return try bytes.withUnsafeBytes { try VobSub($0, idx(for: packs)).subtitles }
}

/// Color map 0, 1, 2, 3 and alpha 0, 15, 15, 15.
private let colorCommands: [UInt8] = [0x01, 0x03, 0x32, 0x10, 0x04, 0xFF, 0xF0]
/// The RGBA palette `colorCommands` selects from `idxPalette`.
private let colorPalette: [UInt8] = [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0x80, 0x80, 0xFF, 0x40, 0x40, 0x40, 0xFF]

/// Issue #155: as in FFmpeg, a subpicture without a set color (0x03) or set contrast (0x04) command
/// uses the color map and alpha the subpictures before it in the stream left.
@Test(arguments: [
    [0x01, 0x04, 0xFF, 0xF0], // No palette command
    [0x01, 0x03, 0x32, 0x10], // No alpha command
    [0x01] // Neither
] as [[UInt8]])
func vobSubWithoutPaletteOrAlphaCommandReusesThePreviousOnes(commands: [UInt8]) throws {
    let subtitles = try decodePacks([pack(commands: colorCommands), pack(commands: commands)])
    #expect(subtitles.count == 2)
    #expect(subtitles[0].imagePalette == colorPalette)
    #expect(subtitles[1].imagePalette == colorPalette)
    #expect(subtitles[1].imageAlpha == [0, 15, 15, 15])
}

@Test func vobSubColorMapAndAlphaCarryOverSeparately() throws {
    let subtitles = try decodePacks([
        pack(commands: colorCommands),
        pack(commands: [0x01, 0x03, 0x01, 0x23]), // Color map 3, 2, 1, 0
        pack(commands: [0x01, 0x04, 0x0F, 0xFF]), // Alpha 15, 15, 15, 0
        pack(commands: [0x01])
    ])
    #expect(subtitles.count == 4)
    let black: [UInt8] = [0, 0, 0]
    let white: [UInt8] = [0xFF, 0xFF, 0xFF]
    let gray: [UInt8] = [0x80, 0x80, 0x80]
    let darkGray: [UInt8] = [0x40, 0x40, 0x40]
    #expect(subtitles[1].imagePalette == darkGray + [0] + gray + [0xFF] + white + [0xFF] + black + [0xFF])
    #expect(subtitles[2].imagePalette == darkGray + [0xFF] + gray + [0xFF] + white + [0xFF] + black + [0])
    #expect(subtitles[3].imagePalette == subtitles[2].imagePalette)
}

@Test func vobSubFirstSubpictureWithoutPaletteOrAlphaUsesFFmpegsInitialColors() throws {
    // FFmpeg starts with an all zero color map and alpha: every color is the first of the palette,
    // and fully transparent.
    let noPalette = try decodePacks([pack(commands: [0x01, 0x04, 0xFF, 0xF0]), pack(commands: colorCommands)])
    #expect(noPalette[0].imagePalette == [0, 0, 0, 0] + Array(repeating: [0, 0, 0, 0xFF], count: 3).flatMap(\.self))
    #expect(noPalette[1].imagePalette == colorPalette)

    let palette = idxPalette.replacingOccurrences(of: "000000", with: "102030")
    let packs = [pack(commands: [0x01, 0x03, 0x32, 0x10]), pack(commands: [0x01])]
    let noAlpha = try packs.flatMap(\.self).withUnsafeBytes { try VobSub($0, idx(for: packs, palette: palette)) }
    for subtitle in noAlpha.subtitles {
        #expect(subtitle.imageAlpha == [0, 0, 0, 0])
        #expect(subtitle.imagePalette?.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 0 } == true)
        // Nothing shows, so OCR has nothing to read, as when FFmpeg drops the subpicture.
        #expect(try #require(subtitle.makeImageSource()).createImage(false) == nil)
    }
}

@Test func vobSubPlaceholderLeavesTheColorsAsTheyWere() throws {
    // The middle subpicture sets a color map and alpha but its first line lies past its RLE data.
    let broken = pack(commands: [0x01, 0x03, 0x01, 0x23, 0x04, 0x0F, 0xFF], fieldOffset: 0xF0)
    let subtitles = try decodePacks([pack(commands: colorCommands), broken, pack(commands: [0x01])])
    #expect(subtitles.count == 3)
    #expect(subtitles[1].imageData == nil)
    #expect(subtitles[1].startTimestamp == 2)
    #expect(subtitles[2].imagePalette == colorPalette)
}

// MARK: - Repeated palette or alpha commands

/// Color map 3, 2, 1, 0 and alpha 15, 15, 15, 0.
private let otherColorCommands: [UInt8] = [0x03, 0x01, 0x23, 0x04, 0x0F, 0xFF]
/// The RGBA palette `otherColorCommands` selects from `idxPalette`.
private let otherColorPalette: [UInt8] = [
    0x40, 0x40, 0x40, 0xFF, 0x80, 0x80, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0
]
/// Alpha 0, 0, 15, 0, which leaves only the line of the image drawn in color 2 showing.
private let fadeCommands: [UInt8] = [0x04, 0x0F, 0x00]
/// The RGBA palette `colorCommands` and then `fadeCommands` select from `idxPalette`.
private let fadedPalette: [UInt8] = [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0, 0x80, 0x80, 0x80, 0xFF, 0x40, 0x40, 0x40, 0]

/// Issue #177: as in FFmpeg, each set color (0x03) and set contrast (0x04) command takes effect as
/// it is read, and the image is drawn with the colors in effect at the end of the control sequence
/// that describes it.
@Test(arguments: [
    // Repeated in one sequence, before the image or after it.
    ([colorCommands + otherColorCommands + imageCommands()], otherColorPalette, otherColorPalette),
    ([colorCommands + imageCommands() + otherColorCommands], otherColorPalette, otherColorPalette),
    // A fade in a later sequence leaves the image as it was but sets the stream's colors.
    ([colorCommands + imageCommands(), fadeCommands], colorPalette, fadedPalette),
    ([colorCommands + imageCommands(), [0x02] + otherColorCommands], colorPalette, otherColorPalette),
    // Colors set before the sequence that describes the image take effect.
    ([colorCommands, fadeCommands + imageCommands()], fadedPalette, fadedPalette),
    // A later sequence describing the image again draws it anew, with the colors in effect then.
    ([colorCommands + imageCommands(), fadeCommands, imageCommands()], fadedPalette, fadedPalette)
] as [([[UInt8]], [UInt8], [UInt8])])
func vobSubImageUsesTheColorsWhenItsSequenceEnds(sequences: [[UInt8]], image: [UInt8], carried: [UInt8]) throws {
    let subtitles = try decodePacks([pack(sequences: sequences), pack(commands: [0x01])])
    #expect(subtitles.count == 2)
    #expect(subtitles[0].imagePalette == image)
    #expect(subtitles[1].imagePalette == carried)
}

@Test func vobSubFadeOfTheColorsCarriedOverIsCarriedOn() throws {
    // The second subpicture sets no colors before its image, so draws it in the first one's, and
    // the alpha its fade sets carries over to the third.
    let subtitles = try decodePacks([
        pack(commands: colorCommands),
        pack(sequences: [[0x01] + imageCommands(), fadeCommands]),
        pack(commands: [0x01])
    ])
    #expect(subtitles.count == 3)
    #expect(subtitles[1].imagePalette == colorPalette)
    #expect(subtitles[2].imagePalette == fadedPalette)
    #expect(subtitles[2].imageAlpha == [0, 0, 15, 0])
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

/// Issue #155: subpictures without set color or set contrast commands decode as FFmpeg's do, by
/// position on the screen. FFmpeg drops a subpicture nothing of which shows, where this keeps it
/// with its transparent image, so those are left out of the comparison.
@Test(arguments: [
    [colorCommands, [0x01, 0x04, 0xFF, 0xF0]],
    [colorCommands, [0x01, 0x03, 0x32, 0x10]],
    [colorCommands, [0x01]],
    [colorCommands, [0x01, 0x03, 0x01, 0x23], [0x01, 0x04, 0x0F, 0xFF], [0x01]],
    [[0x01, 0x04, 0xFF, 0xF0], colorCommands, [0x01]],
    [[0x01, 0x03, 0x32, 0x10], [0x01], colorCommands, [0x01]],
    [[0x01], [0x01, 0x03, 0x01, 0x23], colorCommands]
] as [[[UInt8]]])
func vobSubMissingColorCommandsMatchFFmpegDecoder(commands: [[UInt8]]) throws {
    let directory = URL.temporaryDirectory.appendingPathComponent("VobSubPaletteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sub = directory.appendingPathComponent("colors.sub")
    let idxURL = directory.appendingPathComponent("colors.idx")
    // Each subpicture in its own place, so FFmpeg's timeline does not merge two drawn alike.
    let packs = commands.enumerated().map { pack(commands: $0.element, second: $0.offset + 1, column: UInt8($0.offset)) }
    try Data(packs.flatMap(\.self)).write(to: sub)
    try idx(for: packs).write(to: idxURL, atomically: true, encoding: .utf8)

    let ours = try VobSub(sub, idxURL).subtitles
    try #require(ours.count == packs.count)
    let shown = try ours.map(visiblePixels).filter { !$0.isEmpty }
    let ffmpeg = try #require(FFmpeg(idxURL.path).subtitleTracks.values.first)
    #expect(try shown == ffmpeg.map(visiblePixels))
}

/// Issue #177: subpictures that set their colors more than once decode as FFmpeg's do, by position
/// on the screen.
@Test(arguments: [
    [[colorCommands + otherColorCommands + imageCommands()]],
    [[colorCommands + imageCommands() + otherColorCommands]],
    [[colorCommands + imageCommands(), fadeCommands], [[0x01] + imageCommands()]],
    [[colorCommands + imageCommands(), otherColorCommands], [[0x01] + imageCommands()]],
    [[colorCommands, fadeCommands + imageCommands()]],
    [[colorCommands + imageCommands(), fadeCommands, imageCommands()]],
    [[colorCommands + imageCommands()], [[0x01] + imageCommands(), fadeCommands], [[0x01] + imageCommands()]],
    // The second subpicture lacks one command, so uses the last value the first one set.
    [
        [[0x01, 0x04, 0xFF, 0xF0, 0x03, 0x32, 0x10, 0x03, 0x01, 0x23] + imageCommands()],
        [[0x01, 0x04, 0x0F, 0xFF] + imageCommands()]
    ],
    [
        [[0x01, 0x03, 0x32, 0x10, 0x04, 0xFF, 0xF0, 0x04, 0x0F, 0xFF] + imageCommands()],
        [[0x01, 0x03, 0x01, 0x23] + imageCommands()]
    ]
] as [[[[UInt8]]]])
func vobSubRepeatedColorCommandsMatchFFmpegDecoder(subpictures: [[[UInt8]]]) throws {
    let directory = URL.temporaryDirectory.appendingPathComponent("VobSubPaletteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sub = directory.appendingPathComponent("colors.sub")
    let idxURL = directory.appendingPathComponent("colors.idx")
    // Each subpicture in its own place, so FFmpeg's timeline does not merge two drawn alike.
    let packs = subpictures.enumerated().map { subpicture in
        let image = imageCommands()
        let sequences = subpicture.element.map { commands in
            commands.suffix(image.count) == image[...]
                ? commands.dropLast(image.count) + imageCommands(column: UInt8(subpicture.offset)) : commands
        }
        return pack(sequences: sequences, second: subpicture.offset + 1)
    }
    try Data(packs.flatMap(\.self)).write(to: sub)
    try idx(for: packs).write(to: idxURL, atomically: true, encoding: .utf8)

    let ours = try VobSub(sub, idxURL).subtitles
    try #require(ours.count == packs.count)
    let shown = try ours.map(visiblePixels)
    #expect(shown.allSatisfy { !$0.isEmpty })
    let ffmpeg = try #require(FFmpeg(idxURL.path).subtitleTracks.values.first)
    #expect(try shown == ffmpeg.map(visiblePixels))
}
#endif
