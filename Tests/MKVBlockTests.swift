//
// MKVBlockTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import CryptoKit
import Foundation
@testable import macSubtitleOCR
import Testing

// Blocks too short for their own header, or running past their Cluster, are skipped, and the blocks after
// them are still read.

// MARK: - Synthetic file

/// The PGS track number, whose VINT is 0xA3, the SimpleBlock ID, so that a Block of size zero followed by
/// a SimpleBlock reads that ID as this track's number.
private let pgsTrack: UInt8 = 0x23
/// The VobSub track number, whose VINT is 0xA0, the BlockGroup ID.
private let vobSubTrack: UInt8 = 0x20

/// Encodes an element with its size written eight bytes wide.
private func element(_ id: [UInt8], _ children: [UInt8]...) -> [UInt8] {
    let payload = children.flatMap(\.self)
    return element(id, size: UInt64(payload.count), payload)
}

/// Encodes an element with `size` written eight bytes wide, whatever the length of `payload`.
private func element(_ id: [UInt8], size: UInt64, _ payload: [UInt8]) -> [UInt8] {
    id + withUnsafeBytes(of: (1 << 56 | size).bigEndian) { Array($0) } + payload
}

/// A SimpleBlock of `track` at relative time `time`, holding `payload`.
private func simpleBlock(_ track: UInt8, time: UInt8, _ payload: [UInt8]) -> [UInt8] {
    element([0xA3], [0x80 | track, 0x00, time, 0x80], payload)
}

/// A BlockGroup holding a Block of `track` at relative time `time`, holding `payload`.
private func blockGroup(_ track: UInt8, time: UInt8, _ payload: [UInt8]) -> [UInt8] {
    element([0xA0], element([0xA1], [0x80 | track, 0x00, time, 0x00], payload))
}

/// A PGS end-of-display-set segment.
private let pgsEnd: [UInt8] = [0x80, 0x00, 0x00]
/// A VobSub subpicture payload; its content does not matter to the parser.
private let vobSubPayload: [UInt8] = [0x00, 0x08, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0xFF]

/// The blocks before and after the one under test: one PGS and one VobSub block on each side.
private let blocksBefore = simpleBlock(pgsTrack, time: 0, pgsEnd) + blockGroup(vobSubTrack, time: 0, vobSubPayload)
private let blocksAfter = simpleBlock(pgsTrack, time: 100, pgsEnd) + blockGroup(vobSubTrack, time: 100, vobSubPayload)

private func cluster(time: UInt8, _ children: [UInt8]...) -> [UInt8] {
    element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], [time]) + children.flatMap(\.self))
}

/// An MKV with a PGS and a VobSub track and `clusters`, as file bytes.
private func mkv(_ clusters: [UInt8]...) -> Data {
    let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
    let pgsEntry = element([0xD7], [pgsTrack]) + element([0x83], [0x11]) +
        element([0x86], Array("S_HDMV/PGS".utf8))
    let vobSubEntry = element([0xD7], [vobSubTrack]) + element([0x83], [0x11]) +
        element([0x86], Array("S_VOBSUB".utf8)) + element([0x63, 0xA2], Array("size: 720x480\n".utf8))
    let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], pgsEntry), element([0xAE], vobSubEntry))
    let segment = element([0x18, 0x53, 0x80, 0x67], tracks + clusters.flatMap(\.self))
    return Data(header + segment)
}

/// The track data and VobSub index each track number of `data` extracts to.
private func extract(_ data: Data) throws -> [Int: (data: Data, idx: String?)] {
    let url = URL.temporaryDirectory.appendingPathComponent("MKVBlockTests-\(UUID().uuidString).mks")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let parser = try MKVSubtitleExtractor(filePath: url.path)
    try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    return Dictionary(uniqueKeysWithValues: parser.tracks.map { ($0.trackNumber, ($0.trackData, $0.idxData)) })
}

/// Checks that `data` extracts to what the file with only the blocks before and after does.
private func expectSameAsWithoutBlock(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let expected = try extract(mkv(cluster(time: 1, blocksBefore, blocksAfter)))
    let tracks = try extract(data)
    #expect(tracks.count == 2, sourceLocation: sourceLocation)
    for track in [Int(pgsTrack), Int(vobSubTrack)] {
        #expect(tracks[track]?.data == expected[track]?.data, "track \(track)", sourceLocation: sourceLocation)
        #expect(tracks[track]?.idx == expected[track]?.idx, "track \(track)", sourceLocation: sourceLocation)
    }
}

@Test
func blocksBeforeAndAfterAreExtracted() throws {
    let tracks = try extract(mkv(cluster(time: 1, blocksBefore, blocksAfter)))
    // Two PGS segments, each with its 13-byte PG header.
    #expect(tracks[Int(pgsTrack)]?.data.count == 26)
    let idx = try #require(tracks[Int(vobSubTrack)]?.idx)
    #expect(idx.components(separatedBy: "timestamp:").count == 3)
}

// MARK: - Short blocks

@Test(.timeLimit(.minutes(1)), arguments: [pgsTrack, vobSubTrack], 0 ..< 4)
func simpleBlockShorterThanItsHeaderIsSkipped(track: UInt8, size: Int) throws {
    let header: [UInt8] = [0x80 | track, 0x00, 0x32, 0x80]
    let short = element([0xA3], size: UInt64(size), Array(header.prefix(size)))
    try expectSameAsWithoutBlock(mkv(cluster(time: 1, blocksBefore, short, blocksAfter)))
}

@Test(.timeLimit(.minutes(1)), arguments: [pgsTrack, vobSubTrack], 0 ..< 4)
func blockShorterThanItsHeaderIsSkipped(track: UInt8, size: Int) throws {
    let header: [UInt8] = [0x80 | track, 0x00, 0x32, 0x00]
    let short = element([0xA0], element([0xA1], size: UInt64(size), Array(header.prefix(size))))
    try expectSameAsWithoutBlock(mkv(cluster(time: 1, blocksBefore, short, blocksAfter)))
}

@Test(.timeLimit(.minutes(1)), arguments: [pgsTrack, vobSubTrack])
func blockOfOnlyAHeaderIsRead(track: UInt8) throws {
    // A block holding its header and nothing else is not too short.
    let empty = simpleBlock(track, time: 50, [])
    let tracks = try extract(mkv(cluster(time: 1, blocksBefore, empty, blocksAfter)))
    #expect(tracks.count == 2)
}

// MARK: - Long blocks

@Test(.timeLimit(.minutes(1)), arguments: [pgsTrack, vobSubTrack])
func blockRunningPastItsClusterIsSkipped(track: UInt8) throws {
    // The block claims more than is left of its Cluster, so it is skipped and the next Cluster is read.
    let long = element([0xA3], size: 64, [0x80 | track, 0x00, 0x32, 0x80] + pgsEnd)
    let data = mkv(cluster(time: 1, blocksBefore, long), cluster(time: 1, blocksAfter))
    try expectSameAsWithoutBlock(data)
}

@Test(.timeLimit(.minutes(1)), arguments: [pgsTrack, vobSubTrack], [(1 << 56) - 2, (1 << 56) - 1] as [UInt64])
func blockWithHugeSizeDoesNotTrap(track: UInt8, size: UInt64) throws {
    // A size past the end of the file, or the unknown size, is cut short at the end of the file.
    let huge = element([0xA3], size: size, [0x80 | track, 0x00, 0x32, 0x80] + pgsEnd)
    let tracks = try extract(mkv(cluster(time: 1, blocksBefore, huge, blocksAfter)))
    #expect(tracks[Int(pgsTrack)] != nil)
    #expect(tracks[Int(vobSubTrack)] != nil)
}

@Test(.timeLimit(.minutes(1)))
func blockWithTrackNumberTooLargeIsSkipped() throws {
    // A track number VINT with no length marker in its first byte runs to nine bytes, past Int.max.
    let header: [UInt8] = [0x00] + [UInt8](repeating: 0xFF, count: 8) + [0x00, 0x32, 0x80]
    let block = element([0xA3], header + pgsEnd)
    try expectSameAsWithoutBlock(mkv(cluster(time: 1, blocksBefore, block, blocksAfter)))
}

@Test(.timeLimit(.minutes(1)))
func pgsSegmentOfLargestSizeIsCutAtTheBlockEnd() throws {
    // A segment size of 0xFFFF plus its 3-byte header does not fit in 16 bits.
    let block = simpleBlock(pgsTrack, time: 50, [0x80, 0xFF, 0xFF])
    let tracks = try extract(mkv(cluster(time: 1, block)))
    let data = try #require(tracks[Int(pgsTrack)]?.data)
    #expect(data.count == 13)
    #expect(Array(data.suffix(3)) == [0x80, 0xFF, 0xFF])
}

// MARK: - sintel.mks

@Test(.timeLimit(.minutes(1)))
func sintelMKVExtractsAsBefore() throws {
    let parser = try MKVSubtitleExtractor(filePath: TestFilePaths.mkv.path)
    try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    let digests = parser.tracks.sorted { $0.trackNumber < $1.trackNumber }.map { track in
        let data = track.trackData + Data((track.idxData ?? "").utf8)
        return "\(track.trackNumber) " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    // The digests of the track data and index that the code before short blocks were skipped extracted.
    #expect(digests == [
        "1 aceb6d6c234f3a7bfc7df04197091ea45be6b098abb8f19ceeff7b9cd6462a9c",
        "2 1b4a1c0942237d5c66828fcc0e33c66d6129e381033c5df08c10b8fbfde1e4d3"
    ])
}
