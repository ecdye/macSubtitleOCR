//
// PGSLimitsTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #153: a PGS stream of a few dozen bytes declaring a 65535x65535 video and an object of the
// same size, with 4 bytes of RLE data, made the decoder fill and scan a bitmap of about 4.3 GB. The
// object fit the video, so the only size check passed.

private func bigEndian(_ value: Int, bytes: Int = 2) -> [UInt8] {
    (0 ..< bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
}

/// A PGS segment: 2 byte magic, 4 byte PTS, 4 byte DTS, 1 byte type, 2 byte payload length.
private func segment(_ type: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    Array("PG".utf8) + [0, 0, 0, 0] + [0, 0, 0, 0] + [type] + bigEndian(payload.count) + payload
}

/// A presentation composition for a `width` x `height` video placing each object at its position.
private func presentation(width: Int, height: Int, objects: [(id: Int, x: Int, y: Int)]) -> [UInt8] {
    var payload = bigEndian(width) + bigEndian(height) + [0x10] + bigEndian(0) + [0x80, 0x00, 0x00]
    payload.append(UInt8(objects.count))
    for object in objects {
        payload += bigEndian(object.id) + [0x00, 0x00] + bigEndian(object.x) + bigEndian(object.y)
    }
    return segment(0x16, payload)
}

/// A palette with opaque white at index 1.
private let palette = segment(0x14, [0x00, 0x00] + [0x01, 235, 128, 128, 0xFF])

/// RLE data filling a `width` x `height` object with index 1, one run and an end-of-line code per line.
private func filledRLE(width: Int, height: Int) -> [UInt8] {
    let run: [UInt8] = [0x00, 0xC0 | UInt8(width >> 8), UInt8(width & 0xFF), 0x01]
    return [UInt8]((0 ..< height).flatMap { _ in run + [0x00, 0x00] })
}

/// A single-fragment object definition carrying `rle` as its image data.
private func object(id: Int = 0, width: Int, height: Int, rle: [UInt8]) -> [UInt8] {
    segment(0x15, bigEndian(id) + [0x00, 0xC0] + bigEndian(rle.count + 4, bytes: 3)
        + bigEndian(width) + bigEndian(height) + rle)
}

private let end = segment(0x80)

private func parse(_ bytes: [UInt8]) throws -> [Subtitle] {
    try Data(bytes).withUnsafeBytes { try PGS($0) }.subtitles
}

@Test func hugeVideoAndObjectAreSkippedQuickly() throws {
    let stream = presentation(width: 0xFFFF, height: 0xFFFF, objects: [(0, 0, 0)]) + palette
        + object(width: 0xFFFF, height: 0xFFFF, rle: [0x01, 0x01, 0x00, 0x00]) + end

    let clock = ContinuousClock()
    var subtitles: [Subtitle] = []
    let elapsed = try clock.measure { subtitles = try parse(stream) }

    #expect(subtitles.isEmpty)
    #expect(elapsed < .seconds(1))
}

@Test func displaySetAfterASkippedObjectIsDecoded() throws {
    let skipped = presentation(width: 0xFFFF, height: 0xFFFF, objects: [(0, 0, 0)]) + palette
        + object(width: 0xFFFF, height: 0xFFFF, rle: [0x01, 0x01, 0x00, 0x00]) + end
    let shown = presentation(width: 1920, height: 1080, objects: [(0, 0, 0)]) + palette
        + object(width: 200, height: 30, rle: filledRLE(width: 200, height: 30)) + end

    let subtitles = try parse(skipped + shown)
    #expect(subtitles.count == 1)
    #expect(subtitles.first?.imageWidth == 200)
}

@Test func objectLargerThanAValidVideoIsSkipped() throws {
    let stream = presentation(width: 1920, height: 1080, objects: [(0, 0, 0)]) + palette
        + object(width: 1921, height: 2, rle: filledRLE(width: 1921, height: 2)) + end
    #expect(try parse(stream).isEmpty)
}

@Test func objectWithinAVideoBeyondTheLimitIsSkipped() throws {
    let stream = presentation(width: PGS.maximumVideoDimension + 1, height: 1080, objects: [(0, 0, 0)])
        + palette + object(width: 4, height: 2, rle: filledRLE(width: 4, height: 2)) + end
    #expect(try parse(stream).isEmpty)
}

@Test func objectBeyondTheLimitWithoutAVideoSizeIsSkipped() throws {
    let stream = palette + object(width: PGS.maximumVideoDimension + 1, height: 1, rle: [0x01, 0x00, 0x00]) + end
    #expect(try parse(stream).isEmpty)
}

@Test func onlyTheOversizedObjectOfADisplaySetIsSkipped() throws {
    let stream = presentation(width: 1920, height: 1080, objects: [(0, 0, 0), (1, 100, 900)]) + palette
        + object(id: 0, width: 1921, height: 2, rle: filledRLE(width: 1921, height: 2))
        + object(id: 1, width: 300, height: 40, rle: filledRLE(width: 300, height: 40)) + end

    let subtitles = try parse(stream)
    #expect(subtitles.count == 1)
    #expect(subtitles.first?.imageWidth == 300)
    #expect(subtitles.first?.imageHeight == 40)
}

@Test func dataShorterThanTwoBytesPerLineIsSkipped() throws {
    // Ten end-of-line codes less one byte cannot describe ten lines.
    let short = [UInt8]([[UInt8]](repeating: [0x00, 0x00], count: 10).joined().dropLast())
    let stream = presentation(width: 1920, height: 1080, objects: [(0, 0, 0)]) + palette
        + object(width: 8, height: 10, rle: short) + end
    #expect(try parse(stream).isEmpty)
}

@Test func dataOfTwoBytesPerLineIsDecodedLeniently() throws {
    // Lines holding only an end-of-line code are padded with index 0, as before.
    let stream = presentation(width: 1920, height: 1080, objects: [(0, 0, 0)]) + palette
        + object(width: 8, height: 10, rle: [UInt8]([[UInt8]](repeating: [0x00, 0x00], count: 10).joined())) + end

    let subtitles = try parse(stream)
    #expect(subtitles.count == 1)
    #expect(subtitles.first?.imageData?.count == 80)
}

@Test func fullScreenObjectsAreDecoded() throws {
    for (width, height) in [(1920, 1080), (3840, 2160), (PGS.maximumVideoDimension, PGS.maximumVideoDimension)] {
        let stream = presentation(width: width, height: height, objects: [(0, 0, 0)]) + palette
            + object(width: width, height: height, rle: filledRLE(width: width, height: height)) + end

        let subtitles = try parse(stream)
        #expect(subtitles.count == 1, "\(width)x\(height)")
        #expect(subtitles.first?.imageWidth == width)
        #expect(subtitles.first?.imageHeight == height)
        #expect(subtitles.first?.imageData == Data(repeating: 1, count: width * height))
    }
}

@Test func sintelObjectsAreAllDecoded() throws {
    let pgs = try PGS(URL(fileURLWithPath: TestFilePaths.sup.path))
    #expect(pgs.subtitles.count == 26)
    for subtitle in pgs.subtitles {
        #expect(subtitle.imageWidth ?? 0 > 0 && subtitle.imageHeight ?? 0 > 0)
        #expect(subtitle.imageData?.count == (subtitle.imageWidth ?? 0) * (subtitle.imageHeight ?? 0))
    }
}
