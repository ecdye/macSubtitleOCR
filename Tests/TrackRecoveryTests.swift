//
// TrackRecoveryTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import ArgumentParser
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #81: an error decoding one subtitle ended the run and lost every track, and the SRT files were
// only written once every track was done. One bad subtitle now costs only that subtitle, one bad track
// only that track, and each track is written as soon as it is done.

private func bigEndian(_ value: Int, bytes: Int = 2) -> [UInt8] {
    (0 ..< bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
}

private func makeDirectory() throws -> String {
    let url = URL.temporaryDirectory.appendingPathComponent("TrackRecoveryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

// MARK: - PGS

/// A PGS segment presented at `seconds`: 2 byte magic, 4 byte PTS, 4 byte DTS, 1 byte type, 2 byte
/// payload length.
private func segment(_ type: UInt8, at seconds: Int, _ payload: [UInt8] = []) -> [UInt8] {
    Array("PG".utf8) + bigEndian(seconds * 90000, bytes: 4) + [0, 0, 0, 0] + [type]
        + bigEndian(payload.count) + payload
}

/// A presentation composition for a 1920x1080 video placing object 0 at (10, 20).
private func presentation(at seconds: Int) -> [UInt8] {
    let payload = bigEndian(1920) + bigEndian(1080) + [0x10] + bigEndian(seconds) + [0x80, 0x00, 0x00, 0x01]
        + bigEndian(0) + [0x00, 0x00] + bigEndian(10) + bigEndian(20)
    return segment(0x16, at: seconds, payload)
}

/// A palette with opaque white at index 1 and opaque black at index 2.
private func palette(at seconds: Int) -> [UInt8] {
    segment(0x14, at: seconds, [0x00, 0x00] + [0x01, 235, 128, 128, 0xFF] + [0x02, 16, 128, 128, 0xFF])
}

/// A single-fragment object 0 filled with `color`, run-length encoded one pixel at a time.
private func object(at seconds: Int, width: Int, height: Int, color: UInt8) -> [UInt8] {
    var rle: [UInt8] = []
    for _ in 0 ..< height {
        rle += [UInt8](repeating: color, count: width) + [0x00, 0x00]
    }
    let payload = bigEndian(0) + [0x00, 0xC0] + bigEndian(rle.count + 4, bytes: 3)
        + bigEndian(width) + bigEndian(height) + rle
    return segment(0x15, at: seconds, payload)
}

/// A display set at `seconds` showing a `width`x1 object, with its palette or object segments replaced.
private func displaySet(at seconds: Int, width: Int, palette replacedPalette: [UInt8]? = nil,
                        object replacedObject: [UInt8]? = nil) -> [UInt8] {
    presentation(at: seconds) + (replacedPalette ?? palette(at: seconds))
        + (replacedObject ?? object(at: seconds, width: width, height: 1, color: 1)) + segment(0x80, at: seconds)
}

/// Parses a stream of a good display set at 1 s, `bad` at 2 s and a good one at 3 s, and checks that
/// both good ones are still read.
private func expectDisplaySetsAround(_ bad: [UInt8]) throws {
    let stream = displaySet(at: 1, width: 2) + bad + displaySet(at: 3, width: 3)
    let subtitles = try stream.withUnsafeBytes { try PGS($0) }.subtitles
    #expect(subtitles.map(\.startTimestamp) == [1, 3])
    #expect(subtitles.map(\.imageWidth) == [2, 3])
}

@Test func pgsPaletteOfInvalidLengthSkipsOnlyItsDisplaySet() throws {
    // A palette must be 2 bytes and then 5 per entry; 8 bytes is not.
    try expectDisplaySetsAround(displaySet(at: 2, width: 4, palette: segment(0x14, at: 2, [UInt8](repeating: 0, count: 8))))
}

@Test func pgsPaletteOfInvalidLengthKeepsAnEarlierPaletteOfItsDisplaySet() throws {
    let bad = presentation(at: 2) + palette(at: 2) + segment(0x14, at: 2, [UInt8](repeating: 0, count: 8))
        + object(at: 2, width: 4, height: 1, color: 1) + segment(0x80, at: 2)
    let stream = displaySet(at: 1, width: 2) + bad + displaySet(at: 3, width: 3)
    let subtitles = try stream.withUnsafeBytes { try PGS($0) }.subtitles
    #expect(subtitles.map(\.imageWidth) == [2, 4, 3])
}

@Test func pgsObjectTooShortForItsHeaderSkipsOnlyItsDisplaySet() throws {
    // A first fragment needs an 11 byte header, and any fragment at least 4 bytes.
    try expectDisplaySetsAround(displaySet(at: 2, width: 4, object: segment(0x15, at: 2, [0x00, 0x00, 0x00, 0xC0, 0x00])))
    try expectDisplaySetsAround(displaySet(at: 2, width: 4, object: segment(0x15, at: 2, [0x00, 0x00])))
}

@Test func pgsObjectFragmentTooShortDropsTheObjectItContinues() throws {
    // The first fragment of a 4x1 object, then a continuation too short for its 4 byte header.
    let first = segment(0x15, at: 2, bigEndian(0) + [0x00, 0x80] + bigEndian(10, bytes: 3) + bigEndian(4)
        + bigEndian(1) + [0x01, 0x01])
    let bad = presentation(at: 2) + palette(at: 2) + first + segment(0x15, at: 2, [0x00, 0x00])
        + segment(0x80, at: 2)
    try expectDisplaySetsAround(bad)
}

// MARK: - VobSub

/// A pack header with no stuffing, as a VobSub `.sub` file carries before every PES packet.
private let packHeader: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8]

/// 19:58.160 as a 90 kHz presentation timestamp, in the five bytes a PES header carries it in.
private let ptsBytes: [UInt8] = {
    let pts: UInt64 = 107834400
    return [
        UInt8(0x21 | ((pts >> 29) & 0x0E)),
        UInt8((pts >> 22) & 0xFF),
        UInt8(((pts >> 14) & 0xFE) | 1),
        UInt8((pts >> 7) & 0xFF),
        UInt8(((pts << 1) & 0xFE) | 1)
    ]
}()

/// One pack holding one private-stream PES packet with a timestamp, of subpicture stream `substream`.
private func pack(_ payload: [UInt8], substream: UInt8 = 0x20) -> [UInt8] {
    let body: [UInt8] = [0x81, 0x80, UInt8(ptsBytes.count)] + ptsBytes + [substream] + payload
    return packHeader + [0, 0, 1, 0xBD, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
}

/// A 4x2 subpicture shown for 263 ticks. With `badFieldOffset` its odd field starts far past its
/// 2 bytes of run-length data, which the run-length decoder rejects.
private func subpicture(badFieldOffset: Bool = false) -> [UInt8] {
    let rle: [UInt8] = [0x12, 0x11]
    let controlOffset = 4 + rle.count
    let fieldOffsets: [UInt8] = badFieldOffset ? [0x00, 0x05, 0x00, 0x40] : [0x00, 0x05, 0x00, 0x04]
    let commands: [UInt8] = [0x03, 0x21, 0x03, 0x04, 0xFF, 0xF0, 0x05, 0x00, 0x00, 0x03, 0x00, 0x00, 0x01, 0x06]
        + fieldOffsets + [0x01, 0xFF]
    let secondOffset = controlOffset + 4 + commands.count
    let control = [0x00, 0x00] + bigEndian(secondOffset) + commands + [0x01, 0x07] + bigEndian(secondOffset)
        + [0x02, 0xFF]
    return bigEndian(4 + rle.count + control.count) + bigEndian(controlOffset) + rle + control
}

private let greyPalette = "palette: " + Array(repeating: "808080", count: 16).joined(separator: ", ")

@Test func vobSubSubpictureWithInvalidRunLengthDataLeavesAPlaceholder() throws {
    let bad = pack(subpicture(badFieldOffset: true))
    let good = pack(subpicture())
    let idx = [
        greyPalette,
        "id: en, index: 0",
        "timestamp: 00:00:01:000, filepos: 000000000",
        "timestamp: 00:00:02:000, filepos: \(String(bad.count, radix: 16))"
    ].joined(separator: "\n")
    let subtitles = try (bad + good).withUnsafeBytes { try VobSub($0, idx) }.subtitles
    #expect(subtitles.map(\.index) == [1, 2])
    #expect(subtitles[0].startTimestamp == 1)
    #expect(subtitles[0].imageData == nil)
    #expect(subtitles[1].imageWidth == 4)
}

/// Writes `bytes` and the idx `lines` as `test.sub` and `test.idx` in a new directory, returning the `.sub`.
private func writeVobSub(_ bytes: [UInt8], idx lines: [String]) throws -> URL {
    let directory = try URL(fileURLWithPath: makeDirectory())
    let sub = directory.appendingPathComponent("test.sub")
    try Data(bytes).write(to: sub)
    try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("test.idx"), atomically: true,
                                            encoding: .utf8)
    return sub
}

/// A `.sub` with one stream 0 subpicture, and an idx listing it and then a stream whose index has no
/// substream ID.
private func vobSubWithBadSecondStream() throws -> URL {
    try writeVobSub(pack(subpicture()), idx: [
        greyPalette,
        "id: en, index: 0", "timestamp: 00:00:01:000, filepos: 000000000",
        "id: xx, index: 40", "timestamp: 00:00:02:000, filepos: 000000000"
    ])
}

@Test func vobSubStreamIndexPast31FailsOnlyThatStream() throws {
    let sub = try vobSubWithBadSecondStream()
    defer { try? FileManager.default.removeItem(at: sub.deletingLastPathComponent()) }
    let vobSub = try VobSub(sub, sub.deletingPathExtension().appendingPathExtension("idx"))
    #expect(vobSub.tracks.map(\.index) == [0, 40])
    #expect(vobSub.tracks[0].failure == nil)
    #expect(vobSub.tracks[0].subtitles.map(\.imageWidth) == [4])
    #expect(vobSub.tracks[1].failure != nil)
    #expect(vobSub.tracks[1].subtitles.isEmpty)
}

// MARK: - Whole runs

@Test func runWritesTheTrackBeforeOneThatFailsAndExitsWithFailure() async throws {
    let sub = try vobSubWithBadSecondStream()
    let output = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: sub.deletingLastPathComponent())
        try? FileManager.default.removeItem(atPath: output)
    }
    var runner = try macSubtitleOCR.parse([sub.path, output])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
    #expect(FileManager.default.fileExists(atPath: "\(output)/track_0.srt"))
    #expect(!FileManager.default.fileExists(atPath: "\(output)/track_40.srt"))
}

/// Encodes an MKV element with its size written eight bytes wide.
private func element(_ id: [UInt8], _ children: [UInt8]...) -> [UInt8] {
    let payload = children.flatMap(\.self)
    let size = withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Array($0.dropFirst()) }
    return id + [0x01] + size + payload
}

/// Writes an MKV with a VobSub track 1 and a VobSub track 2, each holding one subpicture, to a temporary
/// file. Track 2's subpicture has invalid run-length data when `corruptSecondTrack`.
private func twoTrackMKV(corruptSecondTrack: Bool) throws -> String {
    func entry(_ number: UInt8) -> [UInt8] {
        element([0xD7], [number]) + element([0x83], [0x11]) + element([0x86], Array("S_VOBSUB".utf8))
            + element([0x63, 0xA2], Array("size: 720x480\n\(greyPalette)\n".utf8))
    }
    func block(_ number: UInt8, _ spu: [UInt8]) -> [UInt8] {
        element([0xA3], [0x80 | number], [0x00, 0x00], [0x80], spu)
    }
    let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
    let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], entry(1)), element([0xAE], entry(2)))
    let cluster = element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], [0x00, 0x00]),
                          block(1, subpicture()), block(2, subpicture(badFieldOffset: corruptSecondTrack)))
    let path = URL.temporaryDirectory.appendingPathComponent("TrackRecoveryTests-\(UUID().uuidString).mks").path
    try Data(header + element([0x18, 0x53, 0x80, 0x67], tracks, cluster)).write(to: URL(fileURLWithPath: path))
    return path
}

@Test func runKeepsEveryTrackOfAnMKVWithABadSubtitle() async throws {
    let input = try twoTrackMKV(corruptSecondTrack: true)
    let output = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(atPath: input)
        try? FileManager.default.removeItem(atPath: output)
    }
    var runner = try macSubtitleOCR.parse([input, output])
    try await runner.run()
    #expect(FileManager.default.fileExists(atPath: "\(output)/track_1.srt"))
    #expect(FileManager.default.fileExists(atPath: "\(output)/track_2.srt"))
}

@Test(arguments: [1, 2])
func runWritesTheOtherTrackWhenOneFailsAndExitsWithFailure(failingTrack: Int) async throws {
    let input = try twoTrackMKV(corruptSecondTrack: false)
    let output = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(atPath: input)
        try? FileManager.default.removeItem(atPath: output)
    }
    // A directory where the track's SRT belongs makes writing it fail.
    try FileManager.default.createDirectory(atPath: "\(output)/track_\(failingTrack).srt",
                                            withIntermediateDirectories: false)
    var runner = try macSubtitleOCR.parse([input, output])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
    var isDirectory: ObjCBool = false
    let other = 3 - failingTrack
    #expect(FileManager.default.fileExists(atPath: "\(output)/track_\(other).srt", isDirectory: &isDirectory))
    #expect(!isDirectory.boolValue)
}
