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

/// A SimpleBlock for `trackNumber` at time zero holding a PGS end segment.
private func pgsBlock(trackNumber: UInt16) -> [UInt8] {
    let track: [UInt8] = trackNumber < 0x7F ? [0x80 | UInt8(trackNumber)] :
        [0x40 | UInt8(trackNumber >> 8), UInt8(trackNumber & 0xFF)]
    return element([0xA3], track, [0x00, 0x00, 0x80], [0x80, 0x00, 0x00])
}

/// Writes an MKV with the given TrackEntry children and one Cluster holding `blocks` to a temporary file.
private func syntheticMKV(entries: [[UInt8]], blocks: [[UInt8]]) throws -> String {
    let header = element([0x1A, 0x45, 0xDF, 0xA3], string([0x42, 0x82], "matroska"))
    let tracks = element([0x16, 0x54, 0xAE, 0x6B], entries.flatMap { element([0xAE], $0) })
    let cluster = element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], [0x00]), blocks.flatMap(\.self))
    let segment = element([0x18, 0x53, 0x80, 0x67], tracks, cluster)
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
