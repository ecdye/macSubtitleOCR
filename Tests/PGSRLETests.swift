//
// PGSRLETests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #91: the PGS RLE decoder grew its output one run at a time and rejected a whole subtitle for one
// malformed line. It now fills a preallocated buffer and decodes malformed bitmaps as far as it can.

/// An object's encoded bitmap as the stream carries it, before decoding.
private struct EncodedObject {
    let width: Int
    let height: Int
    var data: Data
}

/// Collects every object definition in a PGS stream, joining the fragments of an object split across
/// several segments.
private func encodedObjects(in stream: Data) -> [EncodedObject] {
    let bytes = [UInt8](stream)
    var objects: [EncodedObject] = []
    var pending: EncodedObject?
    var offset = 0
    while offset + 13 <= bytes.count {
        let type = bytes[offset + 10]
        let length = Int(bytes[offset + 11]) << 8 | Int(bytes[offset + 12])
        let payload = offset + 13
        offset = payload + length
        guard type == 0x15, length > 11, offset <= bytes.count else { continue }
        let sequenceFlag = bytes[payload + 3]
        if sequenceFlag & 0x80 != 0 {
            let width = Int(bytes[payload + 7]) << 8 | Int(bytes[payload + 8])
            let height = Int(bytes[payload + 9]) << 8 | Int(bytes[payload + 10])
            pending = EncodedObject(width: width, height: height, data: Data(bytes[payload + 11 ..< offset]))
        } else {
            pending?.data.append(contentsOf: bytes[payload + 4 ..< offset])
        }
        if sequenceFlag & 0x40 != 0, let object = pending {
            objects.append(object)
            pending = nil
        }
    }
    return objects
}

/// The decoder as it was before #91, kept to check that well formed bitmaps decode to the same bytes.
private func referenceDecode(_ data: Data, width: Int, height: Int) throws -> Data {
    if data.isEmpty || width <= 0 || height <= 0 {
        return data
    }
    var pixelCount = 0
    var lineCount = 0
    var iterator = data.makeIterator()
    var image = Data()
    while var color: UInt8 = iterator.next(), lineCount < height {
        var run = 1
        if color == 0x00 {
            guard let flags = iterator.next() else { throw macSubtitleOCRError.invalidRLE("flag") }
            run = Int(flags & 0x3F)
            if flags & 0x40 != 0 {
                guard let extendedRun = iterator.next() else { throw macSubtitleOCRError.invalidRLE("run") }
                run = (run << 8) + Int(extendedRun)
            }
            if flags & 0x80 != 0 {
                guard let runColor = iterator.next() else { throw macSubtitleOCRError.invalidRLE("color") }
                color = runColor
            } else {
                color = 0
            }
        }
        if run > 0, pixelCount + run <= width * height {
            image.append(contentsOf: repeatElement(color, count: run))
            pixelCount += run
        } else if run == 0 {
            if pixelCount % width > 0 {
                throw macSubtitleOCRError.invalidRLE("line")
            }
            lineCount += 1
        }
    }
    if pixelCount < width * height {
        throw macSubtitleOCRError.invalidRLE("short")
    }
    return image
}

private func sintelObjects() throws -> [EncodedObject] {
    let objects = try encodedObjects(in: Data(contentsOf: URL(fileURLWithPath: TestFilePaths.sup.path)))
    try #require(!objects.isEmpty)
    return objects
}

private func decode(_ bytes: [UInt8], width: Int, height: Int) throws -> [UInt8] {
    try [UInt8](RLEData(data: Data(bytes), width: width, height: height).decodePGS())
}

/// Runs as the stream encodes them.
private let endOfLine: [UInt8] = [0x00, 0x00]

private func run(_ count: Int, of color: UInt8) -> [UInt8] {
    switch (count < 64, color) {
    case (true, 0): [0x00, UInt8(count)]
    case (false, 0): [0x00, 0x40 | UInt8(count >> 8), UInt8(count & 0xFF)]
    case (true, _): [0x00, 0x80 | UInt8(count), color]
    case (false, _): [0x00, 0xC0 | UInt8(count >> 8), UInt8(count & 0xFF), color]
    }
}

@Test func pgsRLEDecodesSintelExactlyAsBefore() throws {
    for object in try sintelObjects() {
        let expected = try referenceDecode(object.data, width: object.width, height: object.height)
        let decoded = try RLEData(data: object.data, width: object.width, height: object.height).decodePGS()
        #expect(decoded == expected)
        #expect(decoded.count == object.width * object.height)
    }
}

@Test func pgsRLEPadsAShortLine() throws {
    // The first line ends after two of its four pixels.
    let bytes = [0x05, 0x06] + endOfLine + [0x07] + run(3, of: 0x08) + endOfLine
    #expect(try decode(bytes, width: 4, height: 2) == [5, 6, 0, 0, 7, 8, 8, 8])
}

@Test func pgsRLEClipsARunAtTheLineEnd() throws {
    // The first line's run is two pixels too long; the lines after it stay in place.
    let bytes = [0x05] + run(5, of: 0x06) + endOfLine
        + run(4, of: 0x07) + endOfLine
        + [0x08] + run(3, of: 0) + endOfLine
    #expect(try decode(bytes, width: 4, height: 3) == [5, 6, 6, 6, 7, 7, 7, 7, 8, 0, 0, 0])
}

@Test func pgsRLEIgnoresLinesPastTheHeight() throws {
    let bytes = run(2, of: 0x05) + endOfLine + run(2, of: 0x06) + endOfLine + run(2, of: 0x07) + endOfLine
    #expect(try decode(bytes, width: 2, height: 2) == [5, 5, 6, 6])
}

@Test func pgsRLEPadsTruncatedData() throws {
    let lines = run(4, of: 0x05) + endOfLine + run(4, of: 0x06) + endOfLine
    // Cut inside the second line's run, which has lost its color byte.
    #expect(try decode(Array(lines.prefix(7)), width: 4, height: 3) == [5, 5, 5, 5] + Array(repeating: 0, count: 8))
    // Cut after the first line.
    #expect(try decode(Array(lines.prefix(5)), width: 4, height: 2) == [5, 5, 5, 5, 0, 0, 0, 0])
}

@Test func pgsRLEDecodesALongRun() throws {
    let bytes = run(300, of: 0x09) + endOfLine + run(300, of: 0) + endOfLine
    #expect(try decode(bytes, width: 300, height: 2) == Array(repeating: 9, count: 300) + Array(repeating: 0, count: 300))
}

@Test func pgsRLERejectsDimensionsThatOverflow() {
    let decoder = RLEData(data: Data([0x05]), width: Int.max, height: 2)
    #expect(throws: macSubtitleOCRError.self) { try decoder.decodePGS() }
}

/// Times the decoder against the one it replaced. Set PGS_RLE_BENCHMARK to run it, preferably with
/// `swift test -c release -Xswiftc -enable-testing --filter pgsRLEBenchmark`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PGS_RLE_BENCHMARK"] != nil))
func pgsRLEBenchmark() throws {
    let objects = try sintelObjects()
    let iterations = 200
    let clock = ContinuousClock()
    var checksum = 0
    let before = try clock.measure {
        for _ in 0 ..< iterations {
            for object in objects {
                checksum &+= try referenceDecode(object.data, width: object.width, height: object.height).count
            }
        }
    }
    let after = try clock.measure {
        for _ in 0 ..< iterations {
            for object in objects {
                checksum &+= try RLEData(data: object.data, width: object.width, height: object.height)
                    .decodePGS().count
            }
        }
    }
    print("Decoded \(objects.count) objects \(iterations) times: before \(before), after \(after) (\(checksum))")
}
