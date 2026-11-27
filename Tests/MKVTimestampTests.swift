//
// MKVTimestampTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// MARK: - Reading unsigned numbers

@Test
func unsignedNumberKeepsTheHighBit() {
    #expect(unsignedNumber(fromBigEndian: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) == 0x8000_0000_0000_0001)
    #expect(unsignedNumber(fromBigEndian: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == .max)
    #expect(unsignedNumber(fromBigEndian: [0x03, 0xE8]) == 1000)
    #expect(unsignedNumber(fromBigEndian: []) == 0)
    #expect(unsignedNumber(fromBigEndian: [UInt8](repeating: 0, count: 9)) == nil)
}

@Test
func readFixedLengthNumberReadsEightBytesUnsigned() throws {
    let url = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString).bin")
    try Data([0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x12, 0x34]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let fileHandle = try FileHandle(forReadingFrom: url)
    defer { try? fileHandle.close() }
    #expect(readFixedLengthNumber(fileHandle: fileHandle, length: 8) == 0x8000_0000_0000_0001)
    // Too wide a number is rejected without reading it.
    #expect(readFixedLengthNumber(fileHandle: fileHandle, length: 9) == nil)
    #expect(fileHandle.offsetInFile == 8)
    // So is one cut short by the end of the file.
    #expect(readFixedLengthNumber(fileHandle: fileHandle, length: 4) == nil)
}

// MARK: - Absolute PTS

@Test
func absolutePTSFromUnsignedClusterTimestamp() {
    // Ordinary values are unchanged: 90 kHz ticks per millisecond at the default scale.
    #expect(calculateAbsolutePTS(1000, 0) == 90000)
    #expect(calculateAbsolutePTS(1000, 300) == 117000)
    #expect(calculateAbsolutePTS(1000, -200) == 72000)
    #expect(calculateAbsolutePTS(200, .min) == 0)
    #expect(calculateAbsolutePTS(0, 0) == 0)
    // A cluster timestamp past Int64.max saturates instead of reading as negative and clamping to zero.
    #expect(calculateAbsolutePTS(0x8000_0000_0000_0001, 0) == .max)
    #expect(calculateAbsolutePTS(0x8000_0000_0000_0001, .min) == .max)
    #expect(calculateAbsolutePTS(.max, .max) == .max)
    // A large but representable time still converts exactly: 1 ns ticks, 9 per 100,000.
    let ticks: UInt64 = 1 << 63
    #expect(calculateAbsolutePTS(ticks, 0, timestampScale: 1) == ticks / 100000 * 9 + ticks % 100000 * 9 / 100000)
}

// MARK: - Synthetic file

/// Encodes an element with its size written eight bytes wide.
private func ebmlElement(_ id: [UInt8], _ children: [UInt8]...) -> [UInt8] {
    let payload = children.flatMap(\.self)
    let size = withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Array($0.dropFirst()) }
    return id + [0x01] + size + payload
}

/// Writes an MKV with one PGS track and one Cluster whose Timestamp element holds `clusterTimestamp`, holding a
/// single PGS end segment at relative time 0, to a temporary file.
private func pgsMKV(clusterTimestamp: [UInt8]) throws -> String {
    let header = ebmlElement([0x1A, 0x45, 0xDF, 0xA3], ebmlElement([0x42, 0x82], Array("matroska".utf8)))
    let entry = ebmlElement([0xD7], [0x01]) + ebmlElement([0x83], [0x11]) +
        ebmlElement([0x86], Array("S_HDMV/PGS".utf8))
    let tracks = ebmlElement([0x16, 0x54, 0xAE, 0x6B], ebmlElement([0xAE], entry))
    let block = ebmlElement([0xA3], [0x81, 0x00, 0x00, 0x80], [0x80, 0x00, 0x00])
    let cluster = ebmlElement([0x1F, 0x43, 0xB6, 0x75], ebmlElement([0xE7], clusterTimestamp), block)
    let segment = ebmlElement([0x18, 0x53, 0x80, 0x67], tracks, cluster)
    let url = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString).mks")
    try Data(header + segment).write(to: url)
    return url.path
}

private func pgsTrackData(atPath path: String) throws -> Data? {
    let parser = try MKVSubtitleExtractor(filePath: path)
    try parser.parseTracks(for: ["S_HDMV/PGS"])
    return parser.tracks.first?.trackData
}

@Test(.timeLimit(.minutes(1)))
func mkvClusterTimestampWithHighBitSaturates() throws {
    let path = try pgsMKV(clusterTimestamp: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
    defer { try? FileManager.default.removeItem(atPath: path) }

    let data = try #require(try pgsTrackData(atPath: path))
    #expect(data.count == 13)
    // The time saturates to UInt64.max, whose low 32 bits fill the PGS PTS, rather than clamping to zero.
    #expect(Array(data.prefix(6)) == [0x50, 0x47, 0xFF, 0xFF, 0xFF, 0xFF])
}

@Test(.timeLimit(.minutes(1)))
func mkvClusterTimestampWiderThanEightBytesSkipsCluster() throws {
    let path = try pgsMKV(clusterTimestamp: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05])
    defer { try? FileManager.default.removeItem(atPath: path) }

    // The timestamp cannot be read, so its cluster's blocks are left out rather than given a wrong time.
    #expect(try pgsTrackData(atPath: path)?.isEmpty ?? true)
}
