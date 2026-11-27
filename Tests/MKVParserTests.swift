//
// MKVParserTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

private let codecs = ["S_HDMV/PGS", "S_VOBSUB"]

/// Writes a copy of `sintel.mks` changed by `edit` to a temporary file and returns its path.
private func modifiedSintel(_ edit: (inout Data) throws -> Void) throws -> String {
    var data = try Data(contentsOf: URL(fileURLWithPath: TestFilePaths.mkv.path))
    try edit(&data)
    let url = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString).mks")
    try data.write(to: url)
    return url.path
}

private func offset(of bytes: [UInt8], in data: Data) throws -> Int {
    try #require(data.firstRange(of: Data(bytes))).lowerBound
}

private func parsedTracks(atPath path: String) throws -> [MKVTrack] {
    let parser = try MKVSubtitleExtractor(filePath: path)
    try parser.parseTracks(for: codecs)
    // Tracks come out of a dictionary, so put them in a fixed order.
    return parser.tracks.sorted { $0.trackNumber < $1.trackNumber }
}

@Test(.timeLimit(.minutes(1)))
func mkvUnknownSizeSegmentIsReadToEndOfFile() throws {
    let expected = try parsedTracks(atPath: TestFilePaths.mkv.path)
    #expect(!expected.isEmpty)

    let path = try modifiedSintel { data in
        let sizeOffset = try offset(of: [0x18, 0x53, 0x80, 0x67], in: data) + 4
        // The Segment size is written eight bytes wide, so the unknown-size marker fits in its place.
        #expect(data[sizeOffset] == 0x01)
        data.replaceSubrange(sizeOffset ..< sizeOffset + 8, with: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    let tracks = try parsedTracks(atPath: path)
    #expect(tracks.map(\.trackNumber) == expected.map(\.trackNumber))
    #expect(tracks.map(\.codecID) == expected.map(\.codecID))
    #expect(tracks.map(\.trackData) == expected.map(\.trackData))
}

@Test(.timeLimit(.minutes(1)))
func mkvTruncatedInClustersStops() throws {
    let path = try modifiedSintel { data in
        data = data.prefix(data.count / 2)
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    // The tracks are listed before the first Cluster, so whatever blocks remain are still read.
    let tracks = try parsedTracks(atPath: path)
    #expect(!tracks.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func mkvTruncatedInTracksStops() throws {
    let path = try modifiedSintel { data in
        // The SeekHead names the Tracks ID first; the element itself is the last match.
        let tracksOffset = try #require(data.lastRange(of: Data([0x16, 0x54, 0xAE, 0x6B]))).lowerBound
        // Cut the file in the middle of the first TrackEntry.
        data = data.prefix(tracksOffset + 30)
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    let tracks = try parsedTracks(atPath: path)
    #expect(tracks.isEmpty)
}

// MARK: - Synthetic files

/// Encodes an element with its size written eight bytes wide.
private func element(_ id: [UInt8], _ children: [UInt8]...) -> [UInt8] {
    let payload = children.flatMap(\.self)
    let size = withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Array($0.dropFirst()) }
    return id + [0x01] + size + payload
}

private func string(_ id: [UInt8], _ value: String) -> [UInt8] {
    element(id, Array(value.utf8))
}

private let trackNumberID: [UInt8] = [0xD7]
private let trackTypeID: [UInt8] = [0x83]
private let codecIDID: [UInt8] = [0x86]
private let codecPrivateID: [UInt8] = [0x63, 0xA2]
private let languageID: [UInt8] = [0x22, 0xB5, 0x9C]
private let languageBCP47ID: [UInt8] = [0x22, 0xB5, 0x9D]
private let subtitleTrackType = element(trackTypeID, [0x11])

/// A SimpleBlock for `trackNumber` at `timestamp` ticks from its cluster holding a PGS end segment.
private func pgsBlock(trackNumber: UInt16, timestamp: Int16 = 0) -> [UInt8] {
    let track: [UInt8] = trackNumber < 0x7F ? [0x80 | UInt8(trackNumber)] :
        [0x40 | UInt8(trackNumber >> 8), UInt8(trackNumber & 0xFF)]
    let relative = withUnsafeBytes(of: timestamp.bigEndian) { Array($0) }
    return element([0xA3], track, relative, [0x80], [0x80, 0x00, 0x00])
}

/// A Segment Info element with the given TimestampScale.
private func segmentInfo(timestampScale: UInt32) -> [UInt8] {
    element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], withUnsafeBytes(of: timestampScale.bigEndian) {
        Array($0)
    }))
}

/// Writes an MKV with the given TrackEntry children and one Cluster at `clusterTimestamp` holding `blocks` to
/// a temporary file. `info`, if given, is placed before the Tracks, or after them if `infoAfterTracks`.
private func syntheticMKV(entries: [[UInt8]], blocks: [[UInt8]], clusterTimestamp: UInt16 = 0,
                          info: [UInt8] = [], infoAfterTracks: Bool = false) throws -> String {
    let header = element([0x1A, 0x45, 0xDF, 0xA3], string([0x42, 0x82], "matroska"))
    let tracks = element([0x16, 0x54, 0xAE, 0x6B], entries.flatMap { element([0xAE], $0) })
    let timestamp = withUnsafeBytes(of: clusterTimestamp.bigEndian) { Array($0) }
    let cluster = element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], timestamp), blocks.flatMap(\.self))
    let segment = element([0x18, 0x53, 0x80, 0x67], infoAfterTracks ? tracks + info : info + tracks, cluster)
    let url = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString).mks")
    try Data(header + segment).write(to: url)
    return url.path
}

@Test(.timeLimit(.minutes(1)))
func mkvLanguageBeforeTrackNumber() throws {
    let path = try syntheticMKV(
        entries: [
            string(languageID, "fre") + element(trackNumberID, [0x01]) + subtitleTrackType +
                string(codecIDID, "S_HDMV/PGS"),
            element(trackNumberID, [0x02]) + string(languageID, "ger") + subtitleTrackType +
                string(codecIDID, "S_HDMV/PGS")
        ],
        blocks: [pgsBlock(trackNumber: 1), pgsBlock(trackNumber: 2)])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let tracks = try parsedTracks(atPath: path)
    #expect(tracks.map(\.trackNumber) == [1, 2])
    #expect(tracks.map(\.language) == ["fre", "ger"])
}

@Test(.timeLimit(.minutes(1)))
func mkvMultiByteTrackNumber() throws {
    let path = try syntheticMKV(
        entries: [
            element(trackNumberID, [0x01, 0x2C]) + subtitleTrackType + string(codecIDID, "S_HDMV/PGS"),
            element(trackNumberID, [0x00, 0x03]) + element(trackTypeID, [0x00, 0x11]) +
                string(codecIDID, "S_HDMV/PGS")
        ],
        blocks: [pgsBlock(trackNumber: 300), pgsBlock(trackNumber: 3)])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let tracks = try parsedTracks(atPath: path)
    #expect(tracks.map(\.trackNumber) == [3, 300])
}

@Test(.timeLimit(.minutes(1)))
func mkvEmptyTrackNumberSkipsEntry() throws {
    let path = try syntheticMKV(
        entries: [
            element(trackNumberID) + element(trackTypeID) + string(codecIDID, "S_HDMV/PGS"),
            element(trackNumberID, [0x02]) + subtitleTrackType + string(codecIDID, "S_HDMV/PGS")
        ],
        blocks: [pgsBlock(trackNumber: 2)])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let tracks = try parsedTracks(atPath: path)
    #expect(tracks.map(\.trackNumber) == [2])
}

@Test(.timeLimit(.minutes(1)))
func mkvLanguageAfterCodecID() throws {
    let path = try syntheticMKV(
        entries: [
            element(trackNumberID, [0x01]) + subtitleTrackType + string(codecIDID, "S_HDMV/PGS") +
                string(languageID, "spa"),
            element(trackNumberID, [0x02]) + subtitleTrackType + string(codecIDID, "S_HDMV/PGS") +
                string(languageBCP47ID, "pt-BR") + string(languageID, "por")
        ],
        blocks: [pgsBlock(trackNumber: 1), pgsBlock(trackNumber: 2)])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let tracks = try parsedTracks(atPath: path)
    #expect(tracks.map(\.language) == ["spa", "pt-BR"])
}

@Test(.timeLimit(.minutes(1)))
func mkvVobSubLanguageAfterCodecPrivate() throws {
    let path = try syntheticMKV(
        entries: [
            element(trackNumberID, [0x01]) + subtitleTrackType + string(codecIDID, "S_VOBSUB") +
                string(codecPrivateID, "size: 720x480\n") + string(languageID, "en")
        ],
        blocks: [element([0xA3], [0x81, 0x00, 0x00, 0x80], [0x00, 0x04, 0x00, 0x02])])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let tracks = try parsedTracks(atPath: path)
    let track = try #require(tracks.first)
    #expect(track.language == "en")
    let idx = try #require(track.idxData)
    #expect(idx.hasPrefix("# VobSub index file, v7 (do not modify this line!)\nsize: 720x480\nlangidx: 0\n"))
    #expect(idx.contains("\nid: en, index: 0\ntimestamp: 00:00:00:000, filepos: 000000000"))
}

@Test
func mkvSaveSubtitleTrackDataWritesEachTrack() throws {
    let parser = try MKVSubtitleExtractor(filePath: TestFilePaths.mkv.path)
    try parser.parseTracks(for: codecs)
    #expect(!parser.tracks.isEmpty)

    let directory = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for track in parser.tracks {
        try parser.saveSubtitleTrackData(track, outputDirectory: directory)
    }

    for track in parser.tracks {
        let base = directory.appendingPathComponent("track_\(track.trackNumber)")
        if track.codecID == "S_HDMV/PGS" {
            #expect(try Data(contentsOf: base.appendingPathExtension("sup")) == track.trackData)
        } else {
            #expect(try Data(contentsOf: base.appendingPathExtension("sub")) == track.trackData)
            let idx = try String(contentsOf: base.appendingPathExtension("idx"), encoding: .utf8)
            #expect(idx == track.idxData)
        }
    }
}

// MARK: - Timestamps

private let pgsTrackEntry = element(trackNumberID, [0x01]) + subtitleTrackType + string(codecIDID, "S_HDMV/PGS")

/// The 90 kHz PTS in the header of each PGS segment of `track`.
private func pgsPresentationTimestamps(_ track: MKVTrack) -> [UInt32] {
    stride(from: 0, to: track.trackData.count, by: 13).map { offset in
        track.trackData[(offset + 2) ..< (offset + 6)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

@Test(.timeLimit(.minutes(1)))
func mkvNegativeBlockTimestamp() throws {
    let path = try syntheticMKV(
        entries: [pgsTrackEntry],
        blocks: [pgsBlock(trackNumber: 1, timestamp: -200), pgsBlock(trackNumber: 1, timestamp: 300)],
        clusterTimestamp: 1000)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let track = try #require(try parsedTracks(atPath: path).first)
    #expect(pgsPresentationTimestamps(track) == [800 * 90, 1300 * 90])
}

@Test(.timeLimit(.minutes(1)))
func mkvBlockBeforeZeroClampsToZero() throws {
    let path = try syntheticMKV(
        entries: [pgsTrackEntry],
        blocks: [pgsBlock(trackNumber: 1, timestamp: -200)],
        clusterTimestamp: 100)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let track = try #require(try parsedTracks(atPath: path).first)
    #expect(pgsPresentationTimestamps(track) == [0])
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func mkvTimestampScale(infoAfterTracks: Bool) throws {
    // 0.1 ms ticks: 1000 + 5 ticks is 100.5 ms.
    let path = try syntheticMKV(
        entries: [pgsTrackEntry],
        blocks: [pgsBlock(trackNumber: 1, timestamp: 5)],
        clusterTimestamp: 1000,
        info: segmentInfo(timestampScale: 100000),
        infoAfterTracks: infoAfterTracks)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let parser = try MKVSubtitleExtractor(filePath: path)
    try parser.parseTracks(for: codecs)
    #expect(parser.timestampScale == 100000)
    let track = try #require(parser.tracks.first)
    #expect(pgsPresentationTimestamps(track) == [9045])
}

@Test
func mkvSintelUsesDefaultTimestampScale() throws {
    let parser = try MKVSubtitleExtractor(filePath: TestFilePaths.mkv.path)
    try parser.parseTracks(for: codecs)
    #expect(parser.timestampScale == 1000000)
}

@Test
func mkvAbsolutePTSConversion() {
    #expect(calculateAbsolutePTS(1000, -200) == 72000)
    #expect(calculateAbsolutePTS(100, -200) == 0)
    #expect(calculateAbsolutePTS(1000, 5, timestampScale: 100000) == 9045)
    // A 90 kHz tick is 11,111.1 ns, so slightly shorter ticks round down and slightly longer ones don't.
    #expect(calculateAbsolutePTS(12345, 0, timestampScale: 11111) == 12344)
    #expect(calculateAbsolutePTS(12345, 0, timestampScale: 11112) == 12345)
    #expect(calculateAbsolutePTS(.max, 1) == .max)
    #expect(calculateAbsolutePTS(0, -1) == 0)
    #expect(calculateAbsolutePTS(.max / 2, 0) == .max)
    #expect(calculateAbsolutePTS(1, 0, timestampScale: .max) == .max)
}

@Test
func mkvPTSEncodingWrapsPastItsWidth() {
    // 2^32 + 5 ticks, about 13.25 hours, wraps in the 32-bit PGS PTS.
    #expect(encodePTSForPGS((1 << 32) + 5) == [0x00, 0x00, 0x00, 0x05])
    #expect(encodePTSForPGS(.max) == [0xFF, 0xFF, 0xFF, 0xFF])
    // The VobSub PTS is 33 bits.
    #expect(encodePTSForVobSub(from: (1 << 33) + 5) == encodePTSForVobSub(from: 5))
    #expect(encodePTSForVobSub(from: .max) == encodePTSForVobSub(from: (1 << 33) - 1))
    // The largest time calculateAbsolutePTS saturates to still formats.
    #expect(formatTime(.max) == "56934395289:13:37:240")
}
