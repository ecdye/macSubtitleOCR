//
// PGSDisplaySetTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #76: a PGS display set showing two objects at once, such as a caption at the top of the screen
// and another at the bottom, desynced the parser. It returned after the first object and skipped 13
// bytes as if an end segment followed, landing inside the second object.

private func bigEndian(_ value: Int, bytes: Int = 2) -> [UInt8] {
    (0 ..< bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
}

/// A PGS segment presented at `seconds`: 2 byte magic, 4 byte PTS, 4 byte DTS, 1 byte type, 2 byte
/// payload length.
private func segment(_ type: UInt8, at seconds: Int, _ payload: [UInt8] = []) -> [UInt8] {
    Array("PG".utf8) + bigEndian(seconds * 90000, bytes: 4) + [0, 0, 0, 0] + [type]
        + bigEndian(payload.count) + payload
}

/// A presentation composition for a 1920x1080 video placing each object at its position. The state is
/// an epoch start (0x80) unless given, such as an acquisition point (0x40) or a normal case (0x00). It
/// selects palette 0 unless given, and sets the palette update flag (0x80) when `paletteUpdate` is true.
private func presentation(at seconds: Int, state: UInt8 = 0x80, paletteUpdate: Bool = false, paletteID: UInt8 = 0,
                          objects: [(id: Int, x: Int, y: Int)]) -> [UInt8] {
    var payload = bigEndian(1920) + bigEndian(1080) + [0x10] + bigEndian(seconds)
        + [state, paletteUpdate ? 0x80 : 0x00, paletteID]
    payload.append(UInt8(objects.count))
    for object in objects {
        payload += bigEndian(object.id) + [0x00, 0x00] + bigEndian(object.x) + bigEndian(object.y)
    }
    return segment(0x16, at: seconds, payload)
}

/// One window covering the whole video.
private func window(at seconds: Int) -> [UInt8] {
    segment(0x17, at: seconds, [0x01, 0x00] + bigEndian(0) + bigEndian(0) + bigEndian(1920) + bigEndian(1080))
}

/// A palette with opaque white at index 1 and opaque black at index 2.
private func palette(at seconds: Int) -> [UInt8] {
    segment(0x14, at: seconds, [0x00, 0x00] + [0x01, 235, 128, 128, 0xFF] + [0x02, 16, 128, 128, 0xFF])
}

/// A palette `id` at `version` defining only `entries`, each an index, Y, Cr, Cb and alpha.
private func palette(at seconds: Int, id: UInt8, version: UInt8, entries: [[UInt8]]) -> [UInt8] {
    segment(0x14, at: seconds, [id, version] + entries.joined())
}

/// A single-fragment object filled with `color`, run-length encoded one pixel at a time.
private func object(at seconds: Int, id: Int, version: UInt8 = 0, width: Int, height: Int, color: UInt8) -> [UInt8] {
    var rle: [UInt8] = []
    for _ in 0 ..< height {
        rle += [UInt8](repeating: color, count: width) + [0x00, 0x00]
    }
    let payload = bigEndian(id) + [version, 0xC0] + bigEndian(rle.count + 4, bytes: 3)
        + bigEndian(width) + bigEndian(height) + rle
    return segment(0x15, at: seconds, payload)
}

private func end(at seconds: Int) -> [UInt8] {
    segment(0x80, at: seconds)
}

/// A caption at the top of the screen and one below it, then a single caption, then a clear.
private let stream: [UInt8] =
    presentation(at: 1, objects: [(id: 0, x: 100, y: 50), (id: 1, x: 98, y: 60)]) + window(at: 1)
        + palette(at: 1) + object(at: 1, id: 0, width: 2, height: 1, color: 1)
        + object(at: 1, id: 1, width: 3, height: 2, color: 2) + end(at: 1)
        + presentation(at: 2, objects: [(id: 0, x: 10, y: 20)]) + window(at: 2) + palette(at: 2)
        + object(at: 2, id: 0, width: 4, height: 1, color: 1) + end(at: 2)
        + presentation(at: 3, objects: []) + window(at: 3) + end(at: 3)

@Test func displaySetWithTwoObjectsIsOneSubtitle() throws {
    let pgs = try Data(stream).withUnsafeBytes { try PGS($0) }
    #expect(pgs.subtitles.count == 2)
    let subtitle = try #require(pgs.subtitles.first)

    #expect(subtitle.index == 1)
    #expect(subtitle.startTimestamp == 1)
    #expect(subtitle.endTimestamp == 2)

    // Both objects drawn onto one image spanning from (98, 50) to (102, 62).
    #expect(subtitle.imageXOffset == 98)
    #expect(subtitle.imageYOffset == 50)
    let width = try #require(subtitle.imageWidth)
    let height = try #require(subtitle.imageHeight)
    #expect(width == 4)
    #expect(height == 12)

    let data = try #require(subtitle.imageData)
    let colors = try #require(subtitle.imagePalette)
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let index = Int(data[data.startIndex + y * width + x])
        return Array(colors[index * 4 ..< index * 4 + 4])
    }
    let white = pixel(2, 0)
    let black = pixel(0, 10)
    #expect(white[3] == 255)
    #expect(black[3] == 255)
    #expect(white != black)
    for y in 0 ..< height {
        for x in 0 ..< width {
            if y == 0, x >= 2 {
                #expect(pixel(x, y) == white, "(\(x), \(y)) should be the first object")
            } else if y >= 10, x < 3 {
                #expect(pixel(x, y) == black, "(\(x), \(y)) should be the second object")
            } else {
                #expect(pixel(x, y)[3] == 0, "(\(x), \(y)) should be transparent")
            }
        }
    }
}

@Test func displaySetAfterTwoObjectsIsIntact() throws {
    let pgs = try Data(stream).withUnsafeBytes { try PGS($0) }
    #expect(pgs.subtitles.count == 2)
    let subtitle = try #require(pgs.subtitles.dropFirst().first)

    #expect(subtitle.index == 2)
    #expect(subtitle.startTimestamp == 2)
    #expect(subtitle.endTimestamp == 3)
    #expect(subtitle.imageWidth == 4)
    #expect(subtitle.imageHeight == 1)
    #expect(subtitle.imageData == Data([1, 1, 1, 1]))
    #expect(subtitle.imagePalette?[7] == 255)
}

// Issue #77: a middle fragment of an object (sequence flag 0x00) was read like a first fragment. Its
// first RLE bytes were taken as the object's width and height, and 7 bytes of RLE were dropped.

/// The run-length encoded rows of a `width` by `height` object striped in colors 1 and 2, so that
/// any byte lost or misplaced changes the decoded image.
private func stripedRLE(width: Int, height: Int) -> [UInt8] {
    var rle: [UInt8] = []
    for y in 0 ..< height {
        rle += (0 ..< width).map { UInt8(($0 + y) % 2 + 1) } + [0x00, 0x00]
    }
    return rle
}

/// A striped object split into fragments, cutting its RLE data at each of `cuts`. With no cuts it
/// is a single segment.
private func fragmentedObject(at seconds: Int, id: Int, width: Int, height: Int, cuts: [Int]) -> [UInt8] {
    let rle = stripedRLE(width: width, height: height)
    let bounds = [0] + cuts + [rle.count]
    var segments: [UInt8] = []
    for index in 0 ..< bounds.count - 1 {
        let isFirst = index == 0
        let isLast = index == bounds.count - 2
        let flag: UInt8 = (isFirst ? 0x80 : 0x00) | (isLast ? 0x40 : 0x00)
        var payload = bigEndian(id) + [0x00, flag]
        if isFirst {
            payload += bigEndian(rle.count + 4, bytes: 3) + bigEndian(width) + bigEndian(height)
        }
        payload += rle[bounds[index] ..< bounds[index + 1]]
        segments += segment(0x15, at: seconds, payload)
    }
    return segments
}

/// One striped object, split at `cuts`, followed by a single caption and a clear.
private func fragmentedStream(cuts: [Int]) -> [UInt8] {
    presentation(at: 1, objects: [(id: 0, x: 100, y: 50)]) + window(at: 1) + palette(at: 1)
        + fragmentedObject(at: 1, id: 0, width: 16, height: 4, cuts: cuts) + end(at: 1)
        + presentation(at: 2, objects: [(id: 0, x: 10, y: 20)]) + window(at: 2) + palette(at: 2)
        + object(at: 2, id: 0, width: 4, height: 1, color: 1) + end(at: 2)
        + presentation(at: 3, objects: []) + window(at: 3) + end(at: 3)
}

@Test(arguments: [[20, 45], [15, 30, 50]])
func displaySetWithFragmentedObjectMatchesWholeObject(cuts: [Int]) throws {
    let whole = try Data(fragmentedStream(cuts: [])).withUnsafeBytes { try PGS($0) }
    let split = try Data(fragmentedStream(cuts: cuts)).withUnsafeBytes { try PGS($0) }
    let expected = try #require(whole.subtitles.first)
    #expect(expected.imageWidth == 16)
    #expect(expected.imageHeight == 4)
    let expectedData = try #require(expected.imageData)
    #expect(expectedData.count == 64)
    #expect(expectedData.prefix(4) == Data([1, 2, 1, 2]))

    #expect(split.subtitles.count == 2)
    let subtitle = try #require(split.subtitles.first)
    #expect(subtitle.startTimestamp == 1)
    #expect(subtitle.endTimestamp == 2)
    #expect(subtitle.imageWidth == 16)
    #expect(subtitle.imageHeight == 4)
    #expect(subtitle.imageData == expectedData)
    #expect(subtitle.imagePalette == expected.imagePalette)

    let following = try #require(split.subtitles.dropFirst().first)
    #expect(following.index == 2)
    #expect(following.startTimestamp == 2)
    #expect(following.endTimestamp == 3)
    #expect(following.imageWidth == 4)
    #expect(following.imageHeight == 1)
    #expect(following.imageData == Data([1, 1, 1, 1]))
}

// Issue #138: streams send the caption on screen again, as an acquisition point, so that a player
// starting there can show it. Each was read as a new subtitle, splitting one caption into two cues
// with the same text where FFmpeg kept one.

/// A caption shown at 1 and cleared at 3, with `resend` presented at 2 in between.
private func resentStream(_ resend: [UInt8]) -> [UInt8] {
    presentation(at: 1, objects: [(id: 0, x: 100, y: 900)]) + window(at: 1) + palette(at: 1)
        + object(at: 1, id: 0, width: 4, height: 2, color: 1) + end(at: 1)
        + resend
        + presentation(at: 3, state: 0x00, objects: []) + window(at: 3) + end(at: 3)
}

@Test func displaySetResendingCaptionContinuesIt() throws {
    let resend = presentation(at: 2, state: 0x40, objects: [(id: 0, x: 100, y: 900)]) + window(at: 2)
        + palette(at: 2) + object(at: 2, id: 0, width: 4, height: 2, color: 1) + end(at: 2)
    let pgs = try Data(resentStream(resend)).withUnsafeBytes { try PGS($0) }

    #expect(pgs.subtitles.count == 1)
    let subtitle = try #require(pgs.subtitles.first)
    #expect(subtitle.index == 1)
    #expect(subtitle.startTimestamp == 1)
    #expect(subtitle.endTimestamp == 3)
    #expect(subtitle.imageXOffset == 100)
    #expect(subtitle.imageYOffset == 900)
    #expect(subtitle.imageData == Data(repeating: 1, count: 8))
}

@Test(arguments: [
    // Different pixels.
    (x: 100, y: 900, color: UInt8(2)),
    // The same pixels somewhere else on screen.
    (x: 300, y: 900, color: UInt8(1))
])
func displaySetChangingCaptionStartsNewSubtitle(x: Int, y: Int, color: UInt8) throws {
    let resend = presentation(at: 2, state: 0x40, objects: [(id: 0, x: x, y: y)]) + window(at: 2)
        + palette(at: 2) + object(at: 2, id: 0, width: 4, height: 2, color: color) + end(at: 2)
    let pgs = try Data(resentStream(resend)).withUnsafeBytes { try PGS($0) }

    #expect(pgs.subtitles.count == 2)
    let first = try #require(pgs.subtitles.first)
    #expect(first.startTimestamp == 1)
    #expect(first.endTimestamp == 2)
    let second = try #require(pgs.subtitles.dropFirst().first)
    #expect(second.index == 2)
    #expect(second.startTimestamp == 2)
    #expect(second.endTimestamp == 3)
    #expect(second.imageXOffset == x)
}

@Test func displaySetShowingCaptionAgainAfterClearIsNewSubtitle() throws {
    // The screen is cleared at 2 and the same caption shown again at 3, so it is shown twice.
    let caption = { (seconds: Int) in
        presentation(at: seconds, objects: [(id: 0, x: 100, y: 900)]) + window(at: seconds) + palette(at: seconds)
            + object(at: seconds, id: 0, width: 4, height: 2, color: 1) + end(at: seconds)
    }
    let clear = { (seconds: Int) in
        presentation(at: seconds, state: 0x00, objects: []) + window(at: seconds) + end(at: seconds)
    }
    let pgs = try Data(caption(1) + clear(2) + caption(3) + clear(4)).withUnsafeBytes { try PGS($0) }

    #expect(pgs.subtitles.count == 2)
    #expect(pgs.subtitles.map(\.startTimestamp) == [1, 3])
    #expect(pgs.subtitles.map(\.endTimestamp) == [2, 4])
    #expect(pgs.subtitles.map(\.index) == [1, 2])
}

// Issue #144: the crop rectangle of a composition object was read past but not applied, so a cropped
// object was OCR'd in full, including the parts not shown on screen. The cropped flag is also 0x80, as
// in FFmpeg and libbluray, not 0x40, which marks a forced caption and has no rectangle after it.

/// Where a composition places an object, the forced flag (0x40) and the crop rectangle (0x80) it
/// gives it, relative to the object.
private struct Placement {
    var id: Int
    var x: Int
    var y: Int
    var forced = false
    var crop: (x: Int, y: Int, width: Int, height: Int)?
}

/// A presentation composition for a 1920x1080 video, starting an epoch, placing each object.
private func presentation(at seconds: Int, placing objects: [Placement]) -> [UInt8] {
    var payload = bigEndian(1920) + bigEndian(1080) + [0x10] + bigEndian(seconds) + [0x80, 0x00, 0x00]
    payload.append(UInt8(objects.count))
    for object in objects {
        let flags: UInt8 = (object.crop == nil ? 0x00 : 0x80) | (object.forced ? 0x40 : 0x00)
        payload += bigEndian(object.id) + [0x00, flags] + bigEndian(object.x) + bigEndian(object.y)
        if let crop = object.crop {
            payload += bigEndian(crop.x) + bigEndian(crop.y) + bigEndian(crop.width) + bigEndian(crop.height)
        }
    }
    return segment(0x16, at: seconds, payload)
}

/// A striped object, as `stripedRLE` draws it, in one segment.
private func stripedObject(at seconds: Int, id: Int, width: Int, height: Int) -> [UInt8] {
    fragmentedObject(at: seconds, id: id, width: width, height: height, cuts: [])
}

/// The palette indices of the `width` by `height` area at (`x`, `y`) of a striped object.
private func stripes(x: Int, y: Int, width: Int, height: Int) -> Data {
    Data((y ..< y + height).flatMap { row in (x ..< x + width).map { UInt8(($0 + row) % 2 + 1) } })
}

/// A display set at 1 showing `objects` as `placements` place them, a single caption at 2 and a clear at 3.
private func cropStream(_ placements: [Placement], _ objects: [UInt8]) -> [UInt8] {
    presentation(at: 1, placing: placements) + window(at: 1) + palette(at: 1) + objects + end(at: 1)
        + presentation(at: 2, objects: [(id: 0, x: 10, y: 20)]) + window(at: 2) + palette(at: 2)
        + object(at: 2, id: 0, width: 4, height: 1, color: 1) + end(at: 2)
        + presentation(at: 3, objects: []) + window(at: 3) + end(at: 3)
}

@Test func displaySetShowsCroppedPartOfObject() throws {
    let stream = cropStream([Placement(id: 0, x: 100, y: 900, crop: (x: 2, y: 1, width: 3, height: 2))],
                            stripedObject(at: 1, id: 0, width: 6, height: 4))
    let pgs = try Data(stream).withUnsafeBytes { try PGS($0) }

    #expect(pgs.subtitles.count == 2)
    let subtitle = try #require(pgs.subtitles.first)
    #expect(subtitle.startTimestamp == 1)
    #expect(subtitle.endTimestamp == 2)
    #expect(subtitle.imageXOffset == 100)
    #expect(subtitle.imageYOffset == 900)
    #expect(subtitle.imageWidth == 3)
    #expect(subtitle.imageHeight == 2)
    #expect(subtitle.imageData == stripes(x: 2, y: 1, width: 3, height: 2))
}

@Test func displaySetCropsOnlyTheObjectItCrops() throws {
    let stream = cropStream(
        [Placement(id: 0, x: 100, y: 50), Placement(id: 1, x: 98, y: 60, crop: (x: 2, y: 1, width: 3, height: 2))],
        object(at: 1, id: 0, width: 2, height: 1, color: 1) + stripedObject(at: 1, id: 1, width: 6, height: 4))
    let pgs = try Data(stream).withUnsafeBytes { try PGS($0) }

    #expect(pgs.subtitles.count == 2)
    let subtitle = try #require(pgs.subtitles.first)
    // The first object whole from (100, 50) and the cropped part of the second from (98, 60) to (101, 62).
    #expect(subtitle.imageXOffset == 98)
    #expect(subtitle.imageYOffset == 50)
    let width = try #require(subtitle.imageWidth)
    let height = try #require(subtitle.imageHeight)
    #expect(width == 4)
    #expect(height == 12)

    let data = try #require(subtitle.imageData)
    let colors = try #require(subtitle.imagePalette)
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let index = Int(data[data.startIndex + y * width + x])
        return Array(colors[index * 4 ..< index * 4 + 4])
    }
    let white = pixel(2, 0)
    let black = pixel(0, 10) // Object pixel (2, 1) of the second object, color 2.
    #expect(white[3] == 255)
    #expect(black[3] == 255)
    #expect(white != black)
    for y in 0 ..< height {
        for x in 0 ..< width {
            if y == 0, x >= 2 {
                #expect(pixel(x, y) == white, "(\(x), \(y)) should be the first object")
            } else if y >= 10, x < 3 {
                let stripe = (x + 2 + y - 10 + 1) % 2 + 1
                #expect(pixel(x, y) == (stripe == 1 ? white : black), "(\(x), \(y)) should be the cropped object")
            } else {
                #expect(pixel(x, y)[3] == 0, "(\(x), \(y)) should be transparent")
            }
        }
    }
}

@Test func displaySetClampsCropToObject() throws {
    let stream = cropStream([Placement(id: 0, x: 100, y: 900, crop: (x: 2, y: 1, width: 100, height: 100))],
                            stripedObject(at: 1, id: 0, width: 6, height: 4))
    let pgs = try Data(stream).withUnsafeBytes { try PGS($0) }

    #expect(pgs.subtitles.count == 2)
    let subtitle = try #require(pgs.subtitles.first)
    #expect(subtitle.imageXOffset == 100)
    #expect(subtitle.imageYOffset == 900)
    #expect(subtitle.imageWidth == 4)
    #expect(subtitle.imageHeight == 3)
    #expect(subtitle.imageData == stripes(x: 2, y: 1, width: 4, height: 3))
}

@Test(arguments: [
    // No width.
    (x: 0, y: 0, width: 0, height: 4),
    // No height.
    (x: 0, y: 0, width: 6, height: 0),
    // Wholly right of the object.
    (x: 6, y: 0, width: 2, height: 2),
    // Wholly below the object.
    (x: 0, y: 10, width: 2, height: 2)
])
func displaySetSkipsObjectCroppedToNothing(x: Int, y: Int, width: Int, height: Int) throws {
    let stream = cropStream([Placement(id: 0, x: 100, y: 900, crop: (x: x, y: y, width: width, height: height))],
                            stripedObject(at: 1, id: 0, width: 6, height: 4))
    let pgs = try Data(stream).withUnsafeBytes { try PGS($0) }

    // The display set shows nothing, and the next one is read as before.
    #expect(pgs.subtitles.count == 1)
    let subtitle = try #require(pgs.subtitles.first)
    #expect(subtitle.index == 1)
    #expect(subtitle.startTimestamp == 2)
    #expect(subtitle.endTimestamp == 3)
    #expect(subtitle.imageData == Data([1, 1, 1, 1]))
}

@Test func displaySetWithForcedObjectPlacesTheNextObject() throws {
    // A forced caption has no crop rectangle, so the composition object after it starts 8 bytes on.
    let stream = cropStream(
        [Placement(id: 0, x: 100, y: 50, forced: true), Placement(id: 1, x: 98, y: 60)],
        object(at: 1, id: 0, width: 2, height: 1, color: 1) + object(at: 1, id: 1, width: 3, height: 2, color: 2))
    let pgs = try Data(stream).withUnsafeBytes { try PGS($0) }

    #expect(pgs.subtitles.count == 2)
    let subtitle = try #require(pgs.subtitles.first)
    #expect(subtitle.imageXOffset == 98)
    #expect(subtitle.imageYOffset == 50)
    #expect(subtitle.imageWidth == 4)
    #expect(subtitle.imageHeight == 12)
}

// Issue #143: objects and palettes last for the whole epoch, so a display set that is a normal case can
// show objects defined earlier without sending them again, and one that only sends a palette changes the
// colors of what is on screen. Only display sets defining every object they show were read, and the rest
// were taken as clearing the screen.

/// The RGBA color each pixel of a subtitle's image shows, with every fully transparent color as 0.
private func shownColors(_ subtitle: Subtitle) throws -> [UInt32] {
    let data = try #require(subtitle.imageData)
    let palette = try #require(subtitle.imagePalette)
    return data.map { index in
        let color = palette[Int(index) * 4 ..< Int(index) * 4 + 4]
        return color.last == 0 ? 0 : color.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// The colors `shownColors` gives the palette above: opaque white and opaque black.
private let white: UInt32 = 0xFFFF_FFFF
private let black: UInt32 = 0x0000_00FF

/// A caption defined at 1, the screen cleared at 2, and the caption shown again elsewhere at 3 without
/// its object or palette being sent again, cleared at 4.
private let reusedObjectStream: [UInt8] =
    presentation(at: 1, objects: [(id: 0, x: 100, y: 900)]) + window(at: 1) + palette(at: 1)
        + object(at: 1, id: 0, width: 4, height: 2, color: 1) + end(at: 1)
        + presentation(at: 2, state: 0x00, objects: []) + window(at: 2) + end(at: 2)
        + presentation(at: 3, state: 0x00, objects: [(id: 0, x: 200, y: 800)]) + window(at: 3) + end(at: 3)
        + presentation(at: 4, state: 0x00, objects: []) + window(at: 4) + end(at: 4)

/// A caption at the top of the screen at 1, joined at 2 by one below it, which is the only object sent.
private let addedObjectStream: [UInt8] =
    presentation(at: 1, objects: [(id: 0, x: 100, y: 50)]) + window(at: 1) + palette(at: 1)
        + object(at: 1, id: 0, width: 2, height: 1, color: 1) + end(at: 1)
        + presentation(at: 2, state: 0x00, objects: [(id: 0, x: 100, y: 50), (id: 1, x: 98, y: 60)])
        + window(at: 2) + object(at: 2, id: 1, width: 3, height: 2, color: 2) + end(at: 2)
        + presentation(at: 3, state: 0x00, objects: []) + window(at: 3) + end(at: 3)

/// Object 0 defined at 1, defined again with a new version at 2, and shown again at 3 without being sent.
private let redefinedObjectStream: [UInt8] =
    presentation(at: 1, objects: [(id: 0, x: 100, y: 900)]) + window(at: 1) + palette(at: 1)
        + object(at: 1, id: 0, width: 4, height: 2, color: 1) + end(at: 1)
        + presentation(at: 2, state: 0x00, objects: [(id: 0, x: 100, y: 900)]) + window(at: 2)
        + object(at: 2, id: 0, version: 1, width: 3, height: 1, color: 2) + end(at: 2)
        + presentation(at: 3, state: 0x00, objects: [(id: 0, x: 100, y: 900)]) + window(at: 3) + end(at: 3)
        + presentation(at: 4, state: 0x00, objects: []) + window(at: 4) + end(at: 4)

/// A striped caption in colors 1 and 2 at 1, a palette-only update at 2 setting `entries` of palette 0,
/// and a clear at 3.
private func paletteUpdateStream(_ entries: [[UInt8]]) -> [UInt8] {
    presentation(at: 1, objects: [(id: 0, x: 100, y: 900)]) + window(at: 1) + palette(at: 1)
        + stripedObject(at: 1, id: 0, width: 4, height: 2) + end(at: 1)
        + presentation(at: 2, state: 0x00, paletteUpdate: true, objects: [(id: 0, x: 100, y: 900)]) + window(at: 2)
        + palette(at: 2, id: 0, version: 1, entries: entries) + end(at: 2)
        + presentation(at: 3, state: 0x00, objects: []) + window(at: 3) + end(at: 3)
}

/// Index 1 made half transparent black.
private let fadedEntry: [UInt8] = [0x01, 16, 128, 128, 0x80]
/// Index 3, which no pixel uses, made opaque white.
private let unusedEntry: [UInt8] = [0x03, 235, 128, 128, 0xFF]

/// A caption shown with palette 0 at 1, which also defines palette 1, switched to palette 1 at 2.
private let otherPaletteStream: [UInt8] =
    presentation(at: 1, objects: [(id: 0, x: 100, y: 900)]) + window(at: 1)
        + palette(at: 1) + palette(at: 1, id: 1, version: 0, entries: [[0x01, 16, 128, 128, 0xFF]])
        + object(at: 1, id: 0, width: 4, height: 2, color: 1) + end(at: 1)
        + presentation(at: 2, state: 0x00, paletteUpdate: true, paletteID: 1, objects: [(id: 0, x: 100, y: 900)])
        + window(at: 2) + end(at: 2)
        + presentation(at: 3, state: 0x00, objects: []) + window(at: 3) + end(at: 3)

/// A caption defined at 1, then a display set in `state` at 2 and a normal case at 3 both showing it
/// without sending it again, and a clear at 4.
private func restartedStream(state: UInt8) -> [UInt8] {
    presentation(at: 1, objects: [(id: 0, x: 100, y: 900)]) + window(at: 1) + palette(at: 1)
        + object(at: 1, id: 0, width: 4, height: 2, color: 1) + end(at: 1)
        + presentation(at: 2, state: state, objects: [(id: 0, x: 100, y: 900)]) + window(at: 2) + palette(at: 2)
        + end(at: 2)
        + presentation(at: 3, state: 0x00, objects: [(id: 0, x: 100, y: 900)]) + window(at: 3) + end(at: 3)
        + presentation(at: 4, state: 0x00, objects: []) + window(at: 4) + end(at: 4)
}

private func parse(_ stream: [UInt8]) throws -> [Subtitle] {
    try Data(stream).withUnsafeBytes { try PGS($0) }.subtitles
}

@Test func normalDisplaySetShowsObjectDefinedEarlierInEpoch() throws {
    let subtitles = try parse(reusedObjectStream)

    #expect(subtitles.count == 2)
    #expect(subtitles.map(\.index) == [1, 2])
    #expect(subtitles.map(\.startTimestamp) == [1, 3])
    #expect(subtitles.map(\.endTimestamp) == [2, 4])
    let again = try #require(subtitles.dropFirst().first)
    #expect(again.imageXOffset == 200)
    #expect(again.imageYOffset == 800)
    #expect(again.imageWidth == 4)
    #expect(again.imageHeight == 2)
    #expect(try shownColors(again) == [UInt32](repeating: white, count: 8))
}

@Test func normalDisplaySetAddsObjectToOneDefinedEarlier() throws {
    let subtitles = try parse(addedObjectStream)

    #expect(subtitles.count == 2)
    #expect(subtitles.map(\.startTimestamp) == [1, 2])
    #expect(subtitles.map(\.endTimestamp) == [2, 3])
    let both = try #require(subtitles.dropFirst().first)
    // Both objects drawn onto one image spanning from (98, 50) to (102, 62).
    #expect(both.imageXOffset == 98)
    #expect(both.imageYOffset == 50)
    #expect(both.imageWidth == 4)
    #expect(both.imageHeight == 12)
    let colors = try shownColors(both)
    #expect(colors[0 ..< 4] == [0, 0, white, white])
    #expect(colors[40 ..< 48] == [black, black, black, 0, black, black, black, 0])
    #expect(colors.filter { $0 != 0 }.count == 8)
}

@Test func objectDefinedAgainInEpochReplacesEarlierVersion() throws {
    let subtitles = try parse(redefinedObjectStream)

    // The new version is shown at 2 and again at 3, which changes nothing on screen.
    #expect(subtitles.count == 2)
    #expect(subtitles.map(\.startTimestamp) == [1, 2])
    #expect(subtitles.map(\.endTimestamp) == [2, 4])
    let replaced = try #require(subtitles.dropFirst().first)
    #expect(replaced.imageWidth == 3)
    #expect(replaced.imageHeight == 1)
    #expect(try shownColors(replaced) == [black, black, black])
}

@Test func paletteOnlyUpdateChangesColorsOnScreen() throws {
    let subtitles = try parse(paletteUpdateStream([fadedEntry]))

    #expect(subtitles.count == 2)
    #expect(subtitles.map(\.startTimestamp) == [1, 2])
    #expect(subtitles.map(\.endTimestamp) == [2, 3])
    let first = try #require(subtitles.first)
    let faded = try #require(subtitles.dropFirst().first)
    #expect(faded.imageXOffset == 100)
    #expect(faded.imageYOffset == 900)
    #expect(faded.imageData == first.imageData)
    // Index 1 is updated, and index 2, which the update leaves out, keeps its color.
    #expect(try shownColors(first) == [white, black, white, black, black, white, black, white])
    #expect(try shownColors(faded) == [0x80, black, 0x80, black, black, 0x80, black, 0x80])
}

@Test func paletteUpdateOfUnusedColorContinuesCaption() throws {
    let subtitles = try parse(paletteUpdateStream([unusedEntry]))

    #expect(subtitles.count == 1)
    #expect(subtitles.first?.startTimestamp == 1)
    #expect(subtitles.first?.endTimestamp == 3)
}

@Test func paletteUpdateSelectsPaletteByID() throws {
    let subtitles = try parse(otherPaletteStream)

    #expect(subtitles.count == 2)
    #expect(subtitles.map(\.startTimestamp) == [1, 2])
    #expect(try shownColors(#require(subtitles.first)) == [UInt32](repeating: white, count: 8))
    #expect(try shownColors(#require(subtitles.dropFirst().first)) == [UInt32](repeating: black, count: 8))
}

@Test(arguments: [UInt8(0x80), 0x40, 0xC0])
func displaySetStartingOverForgetsEarlierObjects(state: UInt8) throws {
    // Epoch start, acquisition point and epoch continue all start over, as in FFmpeg, so object 0 is
    // gone at 2 and at 3.
    let subtitles = try parse(restartedStream(state: state))

    #expect(subtitles.count == 1)
    #expect(subtitles.first?.startTimestamp == 1)
    #expect(subtitles.first?.endTimestamp == 2)
}

#if FFMPEG
/// FFmpeg reads the same cues, at the same times, showing the same pixels in the same places.
@Test(arguments: [
    ("reused object", reusedObjectStream),
    ("added object", addedObjectStream),
    ("redefined object", redefinedObjectStream),
    ("palette update", paletteUpdateStream([fadedEntry])),
    ("unused palette update", paletteUpdateStream([unusedEntry])),
    ("other palette", otherPaletteStream),
    ("epoch start", restartedStream(state: 0x80)),
    ("acquisition point", restartedStream(state: 0x40)),
    ("epoch continue", restartedStream(state: 0xC0))
])
func epochDisplaySetsMatchFFmpegDecoder(name: String, stream: [UInt8]) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pgs-epoch-\(UUID().uuidString).sup")
    try Data(stream).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    func cues(_ subtitles: [Subtitle]) throws -> [[String]] {
        try subtitles.map { subtitle in
            try [
                "\(subtitle.startTimestamp ?? -1)-\(subtitle.endTimestamp ?? -1)",
                "\(subtitle.imageXOffset ?? -1),\(subtitle.imageYOffset ?? -1)",
                "\(subtitle.imageWidth ?? -1)x\(subtitle.imageHeight ?? -1)",
                shownColors(subtitle).map { String($0, radix: 16) }.joined(separator: " ")
            ]
        }
    }
    let ffmpeg = try cues(FFmpeg(url.path).subtitleTracks.values.first ?? [])
    let decoded = try cues(PGS(url).subtitles)
    #expect(!decoded.isEmpty, "\(name)")
    #expect(decoded == ffmpeg, "\(name)")
}
#endif
