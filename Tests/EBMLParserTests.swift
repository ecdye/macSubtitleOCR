//
// EBMLParserTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// A VINT is at most eight bytes, so a first byte of zero is malformed, as is an element ID longer than the
// four bytes Matroska allows. Reading either stops the element being read, and what was read before it is
// kept.

// MARK: - EBMLParser

/// Writes `bytes` to a temporary file and runs `body` with a parser and handle reading it from the start.
private func withParser<T>(_ bytes: [UInt8], _ body: (EBMLParser, FileHandle) throws -> T) throws -> T {
    let url = URL.temporaryDirectory.appendingPathComponent("EBMLParserTests-\(UUID().uuidString).bin")
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let fileHandle = try FileHandle(forReadingFrom: url)
    defer { try? fileHandle.close() }
    return try body(EBMLParser(fileHandle: fileHandle), fileHandle)
}

@Test(arguments: [false, true])
func vintWithFirstByteOfZeroIsRejected(elementSize: Bool) throws {
    // Read as nine bytes, these would give 1.
    let bytes: [UInt8] = [0x00] + [UInt8](repeating: 0x00, count: 7) + [0x01]
    try withParser(bytes) { parser, fileHandle in
        #expect(parser.readVINT(elementSize: elementSize) == nil)
        #expect(fileHandle.offsetInFile == 1)
    }
}

@Test(arguments: 1 ... 8)
func vintOfEachLengthIsRead(length: Int) throws {
    // The length marker followed by a value whose low byte is 0x2A.
    let bytes = [UInt8(0x80 >> (length - 1))] + [UInt8](repeating: 0x00, count: length - 1)
    var withValue = bytes
    withValue[length - 1] |= 0x2A
    let marker = UInt64(1) << (7 * length)
    try withParser(withValue + [0xFF]) { parser, fileHandle in
        #expect(parser.readVINT(elementSize: true) == 0x2A)
        #expect(fileHandle.offsetInFile == UInt64(length))
    }
    try withParser(withValue + [0xFF]) { parser, _ in
        #expect(parser.readVINT() == marker | 0x2A)
    }
}

@Test
func vintCutShortIsRejected() throws {
    try withParser([]) { parser, _ in
        #expect(parser.readVINT() == nil)
    }
    try withParser([0x10, 0x00]) { parser, _ in
        #expect(parser.readVINT() == nil)
    }
}

@Test(arguments: 1 ... 8)
func elementOfUnknownSizeIsRead(length: Int) throws {
    let allOnes = [UInt8(0xFF >> (length - 1))] + [UInt8](repeating: 0xFF, count: length - 1)
    try withParser([0x1F, 0x43, 0xB6, 0x75] + allOnes) { parser, _ in
        let element = try #require(parser.readEBMLElement())
        #expect(element.elementID == 0x1F43_B675)
        #expect(element.elementSize == nil)
    }
}

@Test
func elementOfKnownSizeIsRead() throws {
    try withParser([0xA3, 0x40, 0x05]) { parser, _ in
        let element = try #require(parser.readEBMLElement())
        #expect(element.elementID == 0xA3)
        #expect(element.elementSize == 5)
    }
}

@Test(arguments: [
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA3, 0x85], // ID with a first byte of zero
    [0xA3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05], // Size with a first byte of zero
    [0x08, 0x00, 0x00, 0x00, 0xA3, 0x85] // ID five bytes long
] as [[UInt8]])
func malformedElementHeaderIsRejected(bytes: [UInt8]) throws {
    try withParser(bytes) { parser, _ in
        #expect(parser.readEBMLElement() == nil)
    }
}

// MARK: - Synthetic file

private let pgsTrack: UInt8 = 1
private let vobSubTrack: UInt8 = 2

/// Encodes an element with its size written eight bytes wide.
private func element(_ id: [UInt8], _ children: [UInt8]...) -> [UInt8] {
    let payload = children.flatMap(\.self)
    return id + withUnsafeBytes(of: (1 << 56 | UInt64(payload.count)).bigEndian) { Array($0) } + payload
}

/// A PGS end-of-display-set segment.
private let pgsEnd: [UInt8] = [0x80, 0x00, 0x00]

/// The header and payload of a PGS SimpleBlock at relative time `time`.
private func pgsBlockData(time: UInt8) -> [UInt8] {
    [0x80 | pgsTrack, 0x00, time, 0x80] + pgsEnd
}

private func simpleBlock(time: UInt8) -> [UInt8] {
    element([0xA3], pgsBlockData(time: time))
}

private func cluster(time: UInt8, _ children: [UInt8]...) -> [UInt8] {
    element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], [time]) + children.flatMap(\.self))
}

private let pgsEntry = element([0xAE], element([0xD7], [pgsTrack]) + element([0x83], [0x11]) +
    element([0x86], Array("S_HDMV/PGS".utf8)))
private let vobSubEntryData = element([0xD7], [vobSubTrack]) + element([0x83], [0x11]) +
    element([0x86], Array("S_VOBSUB".utf8)) + element([0x63, 0xA2], Array("size: 720x480\n".utf8))

/// An MKV with `tracks` as the children of its Tracks element and then `clusters`, as file bytes.
private func mkv(tracks: [UInt8] = pgsEntry, _ clusters: [UInt8]...) -> Data {
    let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
    let segment = element([0x18, 0x53, 0x80, 0x67], element([0x16, 0x54, 0xAE, 0x6B], tracks) +
        clusters.flatMap(\.self))
    return Data(header + segment)
}

/// The track data each track number of `data` extracts to.
private func extract(_ data: Data) throws -> [Int: Data] {
    let url = URL.temporaryDirectory.appendingPathComponent("EBMLParserTests-\(UUID().uuidString).mks")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let parser = try MKVSubtitleExtractor(filePath: url.path)
    try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    return Dictionary(uniqueKeysWithValues: parser.tracks.map { ($0.trackNumber, $0.trackData) })
}

// MARK: - MKV with a malformed header

/// What follows the good block in each test: a SimpleBlock whose header is malformed, which the earlier code
/// read as a SimpleBlock at relative time 50.
private let malformedBlocks: [[UInt8]] = [
    // An ID with a first byte of zero, read as nine bytes.
    [UInt8](repeating: 0x00, count: 8) + [0xA3, 0x87] + pgsBlockData(time: 50),
    // A size with a first byte of zero, read as nine bytes.
    [0xA3] + [UInt8](repeating: 0x00, count: 8) + [0x07] + pgsBlockData(time: 50),
    // An ID five bytes long, which fits a UInt32 only by dropping its top byte.
    [0x08, 0x00, 0x00, 0x00, 0xA3, 0x87] + pgsBlockData(time: 50),
    // A track number with a first byte of zero, read as nine bytes.
    element([0xA3], [UInt8](repeating: 0x00, count: 8) + [pgsTrack, 0x00, 50, 0x80] + pgsEnd)
]

@Test(.timeLimit(.minutes(1)), arguments: malformedBlocks)
func malformedHeaderInClusterStopsAndKeepsEarlierBlocks(malformed: [UInt8]) throws {
    let expected = try extract(mkv(cluster(time: 1, simpleBlock(time: 0))))
    let tracks = try extract(mkv(cluster(time: 1, simpleBlock(time: 0), malformed)))
    #expect(tracks[Int(pgsTrack)] == expected[Int(pgsTrack)])
    #expect(tracks[Int(pgsTrack)]?.count == 13)
}

@Test(.timeLimit(.minutes(1)))
func zeroByteBetweenTrackEntriesStopsAndKeepsEarlierEntries() throws {
    // The earlier code read the zero byte and the eight after it as a TrackEntry ID.
    let tracks = pgsEntry + [UInt8](repeating: 0x00, count: 8) +
        element([0xAE], vobSubEntryData)
    let vobSubBlock = element([0xA0], element([0xA1], [0x80 | vobSubTrack, 0x00, 0x00, 0x00, 0x00, 0x08, 0xFF]))
    let extracted = try extract(mkv(tracks: tracks, cluster(time: 1, simpleBlock(time: 0), vobSubBlock)))
    #expect(extracted.keys.sorted() == [Int(pgsTrack)])
    #expect(extracted[Int(pgsTrack)]?.count == 13)
}

@Test(.timeLimit(.minutes(1)))
func zeroBytesBeforeSegmentStop() throws {
    let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
    let data = Data(header + [UInt8](repeating: 0x00, count: 64)) + mkv(cluster(time: 1, simpleBlock(time: 0)))
    let url = URL.temporaryDirectory.appendingPathComponent("EBMLParserTests-\(UUID().uuidString).mks")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let parser = try MKVSubtitleExtractor(filePath: url.path)
    #expect(throws: macSubtitleOCRError.self) {
        try parser.parseTracks(for: ["S_HDMV/PGS"])
    }
}
