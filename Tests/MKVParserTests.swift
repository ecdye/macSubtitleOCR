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
