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

/// A presentation composition for a 1920x1080 video placing each object at its position.
private func presentation(at seconds: Int, objects: [(id: Int, x: Int, y: Int)]) -> [UInt8] {
    var payload = bigEndian(1920) + bigEndian(1080) + [0x10] + bigEndian(seconds) + [0x80, 0x00, 0x00]
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

/// A single-fragment object filled with `color`, run-length encoded one pixel at a time.
private func object(at seconds: Int, id: Int, width: Int, height: Int, color: UInt8) -> [UInt8] {
    var rle: [UInt8] = []
    for _ in 0 ..< height {
        rle += [UInt8](repeating: color, count: width) + [0x00, 0x00]
    }
    let payload = bigEndian(id) + [0x00, 0xC0] + bigEndian(rle.count + 4, bytes: 3)
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
