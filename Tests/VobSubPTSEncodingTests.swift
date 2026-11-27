//
// VobSubPTSEncodingTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

/// Reads a PES PTS back the way VobSubParser does, ignoring the prefix and marker bits.
private func decodePTS(_ pts: [UInt8]) -> UInt64 {
    var presentationTimestamp = UInt64(pts[4]) >> 1
    presentationTimestamp += UInt64(pts[3]) << 7
    presentationTimestamp += UInt64(pts[2] & 0xFE) << 14
    presentationTimestamp += UInt64(pts[1]) << 22
    presentationTimestamp += UInt64(pts[0] & 0x0E) << 29
    return presentationTimestamp
}

/// Checks the bits ISO/IEC 13818-1 fixes in a PTS with PTS_DTS_flags '10': the '0010' prefix and
/// the marker bits ending each of the three parts of the value.
private func hasPTSPrefixAndMarkers(_ pts: [UInt8]) -> Bool {
    pts.count == 5 && pts[0] & 0xF1 == 0x21 && pts[2] & 1 == 1 && pts[4] & 1 == 1
}

/// Timestamps and the PTS bytes they encode to.
private let encodedTimestamps: [(UInt64, [UInt8])] = [
    (0, [0x21, 0x00, 0x01, 0x00, 0x01]),
    (1, [0x21, 0x00, 0x01, 0x00, 0x03]),
    // 1:47.250, the first subtitle of sintel, as sintel.sub spells it.
    (9652500, [0x21, 0x02, 0x4D, 0x92, 0x29]),
    (0x1_2345_6789, [0x29, 0x8D, 0x15, 0xCF, 0x13]),
    (1 << 32, [0x29, 0x00, 0x01, 0x00, 0x01]),
    ((1 << 33) - 1, [0x2F, 0xFF, 0xFF, 0xFF, 0xFF])
]

@Test(arguments: encodedTimestamps)
func vobSubPTSEncodingSetsMarkerBits(timestamp: UInt64, expected: [UInt8]) {
    let encoded = encodePTSForVobSub(from: timestamp)
    #expect(encoded == expected)
    #expect(hasPTSPrefixAndMarkers(encoded))
    #expect(decodePTS(encoded) == timestamp)
}

@Test
func vobSubPTSEncodingKeepsMarkerBitsWhenWrapping() {
    let encoded = encodePTSForVobSub(from: (1 << 33) + 5)
    #expect(hasPTSPrefixAndMarkers(encoded))
    #expect(decodePTS(encoded) == 5)
}

/// Every PES packet built for the VobSub track of sintel.mks has MPEG-2 flags and, when it starts a
/// subpicture, a PTS with its marker bits that matches the time in the idx.
@Test(.timeLimit(.minutes(1)))
func mkvVobSubPacketsAreMPEG2() throws {
    let parser = try MKVSubtitleExtractor(filePath: TestFilePaths.mkv.path)
    try parser.parseTracks(for: ["S_VOBSUB"])
    let track = try #require(parser.tracks.first)
    let data = [UInt8](track.trackData)
    let idx = try #require(track.idxData)

    var idxTimestamps: [UInt64] = []
    for line in idx.split(separator: "\n") where line.hasPrefix("timestamp: ") {
        let time = line.dropFirst("timestamp: ".count).prefix(12).split(separator: ":").compactMap { UInt64($0) }
        try #require(time.count == 4)
        idxTimestamps.append(((time[0] * 60 + time[1]) * 60 + time[2]) * 1000 + time[3])
    }
    #expect(!idxTimestamps.isEmpty)

    var ptsTimestamps: [UInt64] = []
    var offset = 0
    var packets = 0
    while offset < data.count {
        try #require(Array(data[offset ..< offset + 4]) == [0x00, 0x00, 0x01, 0xBA])
        offset += 14
        try #require(Array(data[offset ..< offset + 4]) == [0x00, 0x00, 0x01, 0xBD])
        let pesLength = Int(data[offset + 4]) << 8 | Int(data[offset + 5])
        offset += 6
        let body = Array(data[offset ..< offset + pesLength])
        offset += pesLength
        packets += 1

        // The first flags byte starts with '10' in MPEG-2; FFmpeg reads anything else as MPEG-1.
        #expect(body[0] & 0xC0 == 0x80)
        if body[1] & 0x80 == 0x80 {
            let pts = Array(body[3 ..< 8])
            #expect(body[2] == 5)
            #expect(hasPTSPrefixAndMarkers(pts))
            // The idx rounds to the millisecond.
            let pts90k = decodePTS(pts)
            ptsTimestamps.append(pts90k / 90 + (pts90k % 90 >= 45 ? 1 : 0))
        }
    }
    #expect(packets > idxTimestamps.count)
    #expect(ptsTimestamps == idxTimestamps)
}
