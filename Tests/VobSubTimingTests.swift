//
// VobSubTimingTests.swift
// macSubtitleOCR
//
// Created by Tim Jenness on 11/22/26.
// Copyright © 2026-2026 Tim Jenness. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

/// A pack header with no stuffing, as a VobSub `.sub` file carries before every PES packet.
private let packHeader: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8]

/// Encode a 33-bit presentation timestamp in the five bytes a PES header carries it in.
private func ptsBytes(_ pts: UInt64) -> [UInt8] {
    [
        UInt8(0x21 | ((pts >> 29) & 0x0E)),
        UInt8((pts >> 22) & 0xFF),
        UInt8(((pts >> 14) & 0xFE) | 1),
        UInt8((pts >> 7) & 0xFF),
        UInt8(((pts << 1) & 0xFE) | 1)
    ]
}

/// One pack holding one private-stream PES packet of subpicture bytes.
///
/// `headerData` is what follows the PES header-data-length byte: a timestamp when `flags`
/// says there is one, and otherwise stuffing, which MPEG allows and fills with 0xFF.
/// `substream` is the subpicture stream ID, `0x20` plus the idx stream index.
private func pack(flags: UInt8, headerData: [UInt8], payload: [UInt8], substream: UInt8 = 0x20) -> [UInt8] {
    let body: [UInt8] = [0x81, flags, UInt8(headerData.count)] + headerData + [substream] + payload
    return packHeader + [0, 0, 1, 0xBD, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
}

/// A 4x2 subpicture whose control sequences start it after `startDelay` and, where given,
/// stop it after `stopDelay`, both in the 1024/90000 s units the format counts in.
private func subpicture(startDelay: UInt16 = 0, stopDelay: UInt16?) -> [UInt8] {
    let rle: [UInt8] = [0x12, 0x11]
    let controlOffset = 4 + rle.count
    var first: [UInt8] = [
        0x03,
        0x21,
        0x03,
        0x04,
        0xFF,
        0xF0,
        0x05,
        0x00,
        0x00,
        0x03,
        0x00,
        0x00,
        0x01,
        0x06,
        0x00,
        0x05,
        0x00,
        0x04,
        0x01,
        0xFF
    ]
    let secondOffset = controlOffset + 4 + first.count
    let firstNext = stopDelay == nil ? controlOffset : secondOffset
    first = [UInt8(startDelay >> 8), UInt8(startDelay & 0xFF), UInt8(firstNext >> 8), UInt8(firstNext & 0xFF)]
        + first
    var control = first
    if let stopDelay {
        control += [
            UInt8(stopDelay >> 8),
            UInt8(stopDelay & 0xFF),
            UInt8(secondOffset >> 8),
            UInt8(secondOffset & 0xFF),
            0x02,
            0xFF
        ]
    }
    let size = 4 + rle.count + control.count
    return [UInt8(size >> 8), UInt8(size & 0xFF), UInt8(controlOffset >> 8), UInt8(controlOffset & 0xFF)]
        + rle + control
}

private let palette = [UInt8](repeating: 0x80, count: 48)

private func parse(_ bytes: [UInt8], idxTimestamp: TimeInterval) throws -> Subtitle {
    try bytes.withUnsafeBytes { buffer in
        try VobSubParser(index: 1, buffer: buffer, timestamp: idxTimestamp, offset: 0,
                         nextOffset: UInt64(bytes.count), idxPalette: palette).subtitle
    }
}

/// 19:58.160, as a 90 kHz presentation timestamp.
private let pts: UInt64 = 107834400

@Test func vobSubStopCommandSetsTheEndTime() throws {
    // 263 units is 2.992 s: (263 << 10) / 90 = 2992 ms.
    let bytes = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    let subtitle = try parse(bytes, idxTimestamp: 1198.16)
    #expect(subtitle.startTimestamp == 1198.16)
    #expect(subtitle.endTimestamp == 1198.16 + 2.992)
}

@Test func vobSubWithoutAStopCommandHasNoEndTime() throws {
    let bytes = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: nil))
    let subtitle = try parse(bytes, idxTimestamp: 1198.16)
    #expect(subtitle.endTimestamp == nil)
}

@Test func vobSubStartDelayIsCountedFromThePresentationTimestamp() throws {
    // 9 units is 102 ms; the stop is counted from the timestamp, not from the delayed start.
    let bytes = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(startDelay: 9, stopDelay: 263))
    let subtitle = try parse(bytes, idxTimestamp: 1198.16)
    #expect(subtitle.startTimestamp == 1198.16 + 0.102)
    #expect(subtitle.endTimestamp == 1198.16 + 2.992)
}

@Test func vobSubStuffingInAContinuationPacketIsNotATimestamp() throws {
    // The second packet carries no timestamp but pads its header with five 0xFF bytes,
    // which read as a timestamp would be 2^33 - 1 ticks, 26:30:43.718.
    let spu = subpicture(stopDelay: 263)
    let bytes = pack(flags: 0x80, headerData: ptsBytes(pts), payload: Array(spu[..<5]))
        + pack(flags: 0x00, headerData: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF], payload: Array(spu[5...]))
    let subtitle = try parse(bytes, idxTimestamp: 1198.16)
    #expect(subtitle.startTimestamp == 1198.16)
    #expect(subtitle.endTimestamp == 1198.16 + 2.992)
}

/// An idx listing one subtitle per `(timestamp, filepos)` pair, with a grey palette.
private func idx(_ entries: [(String, Int)]) -> String {
    let palette = Array(repeating: "808080", count: 16).joined(separator: ", ")
    let lines = entries.map { "timestamp: \($0.0), filepos: \(String($0.1, radix: 16, uppercase: true))" }
    return (["palette: \(palette)", "id: en, index: 0"] + lines).joined(separator: "\n")
}

private func vobSub(_ bytes: [UInt8], idx: String) throws -> [Subtitle] {
    try bytes.withUnsafeBytes { buffer in try VobSub(buffer, idx).subtitles }
}

@Test func vobSubOffsetWithoutAPackHeaderLeavesAPlaceholder() throws {
    // The first filepos points at bytes that are not a pack header.
    let garbage = [UInt8](repeating: 0, count: 32)
    let valid = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    let subtitles = try vobSub(garbage + valid,
                               idx: idx([("00:19:50:000", 0), ("00:19:58:160", garbage.count)]))
    #expect(subtitles.count == 2)
    #expect(subtitles[0].index == 1)
    #expect(subtitles[0].startTimestamp == 1190)
    #expect(subtitles[0].imageData == nil)
    #expect(subtitles[1].index == 2)
    #expect(subtitles[1].imageWidth == 4)
}

@Test func vobSubOffsetAtAContinuationPacketLeavesAPlaceholder() throws {
    // The first filepos points at a packet without a timestamp, which cannot start a subpicture.
    let spu = subpicture(stopDelay: 263)
    let continuation = pack(flags: 0x00, headerData: [], payload: Array(spu[5...]))
    let valid = pack(flags: 0x80, headerData: ptsBytes(pts), payload: spu)
    let subtitles = try vobSub(continuation + valid,
                               idx: idx([("00:19:50:000", 0), ("00:19:58:160", continuation.count)]))
    #expect(subtitles.count == 2)
    #expect(subtitles[0].startTimestamp == 1190)
    #expect(subtitles[0].imageData == nil)
    #expect(subtitles[1].imageWidth == 4)
}

@Test func vobSubParserRejectsASubpictureWithoutAPackHeader() {
    let bytes = [UInt8](repeating: 0, count: 32)
    #expect(throws: macSubtitleOCRError.self) { try parse(bytes, idxTimestamp: 0) }
}

// MARK: - Malformed subpictures

/// Parse `malformed` as the first subtitle and a valid subpicture after it as the second, and
/// check that the first becomes a placeholder while the second still decodes.
private func expectPlaceholderBeforeValid(_ malformed: [UInt8]) throws {
    let valid = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    let subtitles = try vobSub(malformed + valid,
                               idx: idx([("00:19:50:000", 0), ("00:19:58:160", malformed.count)]))
    #expect(subtitles.count == 2)
    #expect(subtitles[0].startTimestamp == 1190)
    #expect(subtitles[0].imageData == nil)
    #expect(subtitles[1].imageWidth == 4)
    #expect(subtitles[1].endTimestamp == 1198.16 + 2.992)
}

/// Parse a valid subtitle followed by `malformed`, which runs to the end of the file, and check
/// that the valid one still decodes and the malformed one becomes a placeholder.
private func expectPlaceholderAfterValid(_ malformed: [UInt8], at offset: Int? = nil) throws {
    let valid = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    let subtitles = try vobSub(valid + malformed,
                               idx: idx([("00:19:58:160", 0), ("00:20:10:000", valid.count + (offset ?? 0))]))
    #expect(subtitles.count == 2)
    #expect(subtitles[0].imageWidth == 4)
    #expect(subtitles[1].startTimestamp == 1210)
    #expect(subtitles[1].imageData == nil)
}

/// A valid subpicture packet with its PES length field, after the PES start code, replaced.
private func packWithPESLength(_ length: UInt16) -> [UInt8] {
    var bytes = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    bytes[packHeader.count + 4] = UInt8(length >> 8)
    bytes[packHeader.count + 5] = UInt8(length & 0xFF)
    return bytes
}

/// A valid subpicture packet with the subpicture's size or control offset field replaced.
private func packWithSubpicture(size: UInt16? = nil, controlOffset: UInt16? = nil) -> [UInt8] {
    var spu = subpicture(stopDelay: 263)
    if let size {
        spu[0] = UInt8(size >> 8)
        spu[1] = UInt8(size & 0xFF)
    }
    if let controlOffset {
        spu[2] = UInt8(controlOffset >> 8)
        spu[3] = UInt8(controlOffset & 0xFF)
    }
    return pack(flags: 0x80, headerData: ptsBytes(pts), payload: spu)
}

@Test func vobSubOffsetInTheLastBytesOfTheFileLeavesAPlaceholder() throws {
    // The last filepos starts a pack header that the end of the file cuts off.
    try expectPlaceholderAfterValid(Array(packHeader.prefix(6)))
    try expectPlaceholderAfterValid([0, 0, 1], at: 2)
}

@Test func vobSubOffsetPastTheEndOfTheFileLeavesAPlaceholder() throws {
    try expectPlaceholderAfterValid([], at: 100)
}

@Test func vobSubPESLengthPastTheEndOfTheFileLeavesAPlaceholder() throws {
    try expectPlaceholderAfterValid(packWithPESLength(0xFFFF))
}

@Test func vobSubPESLengthShorterThanItsHeaderLeavesAPlaceholder() throws {
    // A PES length of 3 ends the packet inside its own header.
    try expectPlaceholderBeforeValid(packWithPESLength(3))
}

@Test func vobSubZeroPESLengthLeavesAPlaceholder() throws {
    try expectPlaceholderBeforeValid(packWithPESLength(0))
}

@Test func vobSubControlOffsetBelowFourLeavesAPlaceholder() throws {
    // The control offset counts from the start of the subpicture, which begins with 4 bytes of header.
    try expectPlaceholderBeforeValid(packWithSubpicture(controlOffset: 2))
}

@Test func vobSubControlOffsetPastTheSubpictureLeavesAPlaceholder() throws {
    try expectPlaceholderBeforeValid(packWithSubpicture(controlOffset: 0xFFF0))
}

@Test func vobSubSizePastTheEndOfTheFileLeavesAPlaceholder() throws {
    try expectPlaceholderAfterValid(packWithSubpicture(size: 0xFFF0, controlOffset: 0xFF00))
}

@Test func vobSubTruncatedSecondPacketLeavesAPlaceholder() throws {
    // The subpicture continues into a second packet that the end of the file cuts off.
    let spu = subpicture(stopDelay: 263)
    let split = pack(flags: 0x80, headerData: ptsBytes(pts), payload: Array(spu[..<5]))
        + pack(flags: 0x00, headerData: [], payload: Array(spu[5...]))
    try expectPlaceholderAfterValid(Array(split[..<(split.count - 10)]))
}

@Test func vobSubParserRejectsAnOffsetPastTheEndOfTheBuffer() {
    let bytes = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    #expect(throws: macSubtitleOCRError.self) {
        try bytes.withUnsafeBytes { buffer in
            try VobSubParser(index: 1, buffer: buffer, timestamp: 0, offset: UInt64.max,
                             nextOffset: UInt64.max, idxPalette: palette)
        }
    }
}

// MARK: - Several streams in one file

/// An idx with one `id:` block per `(language, index, entries)`, each listing `(timestamp, filepos)`
/// pairs, with a grey palette. `prelude` lines come between the palette and the first block.
private func idx(streams: [(String, Int, [(String, Int)])], prelude: [String] = []) -> String {
    let palette = Array(repeating: "808080", count: 16).joined(separator: ", ")
    var lines = ["palette: \(palette)"] + prelude
    for (language, index, entries) in streams {
        lines.append("id: \(language), index: \(index)")
        lines += entries.map { "timestamp: \($0.0), filepos: \(String($0.1, radix: 16, uppercase: true))" }
    }
    return lines.joined(separator: "\n")
}

/// Write `bytes` and `idx` as a `.sub`/`.idx` pair in a new temporary directory.
private func writeVobSub(_ bytes: [UInt8], idx: String) throws -> (sub: URL, idx: URL) {
    let directory = URL.temporaryDirectory.appendingPathComponent("VobSubTimingTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sub = directory.appendingPathComponent("test.sub")
    let idxURL = directory.appendingPathComponent("test.idx")
    try Data(bytes).write(to: sub)
    try idx.write(to: idxURL, atomically: true, encoding: .utf8)
    return (sub, idxURL)
}

/// 20:03.160, five seconds after `pts`, as a 90 kHz presentation timestamp.
private let laterPTS: UInt64 = pts + 5 * 90000

/// A stream 0 subpicture split over two packets with a whole stream 1 subpicture between them,
/// as in a VobSubRip `.sub` holding two languages. Returns the bytes and the offset of the
/// stream 1 packet.
private func interleavedStreams() -> (bytes: [UInt8], secondOffset: Int) {
    let spu = subpicture(stopDelay: 263)
    let first = pack(flags: 0x80, headerData: ptsBytes(pts), payload: Array(spu[..<5]))
    let other = pack(flags: 0x80, headerData: ptsBytes(laterPTS), payload: subpicture(stopDelay: 100),
                     substream: 0x21)
    let rest = pack(flags: 0x00, headerData: [], payload: Array(spu[5...]))
    return (first + other + rest, first.count)
}

@Test func vobSubSubpictureSkipsPacketsOfAnotherStream() throws {
    // Only stream 0 is listed; its second packet comes after a packet of substream 0x21.
    let (bytes, _) = interleavedStreams()
    let files = try writeVobSub(bytes, idx: idx(streams: [("en", 0, [("00:19:58:160", 0)])]))
    let subtitles = try VobSub(files.sub, files.idx).subtitles
    let expected = try parse(pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263)),
                             idxTimestamp: 1198.16)
    #expect(subtitles.count == 1)
    #expect(subtitles.first?.imageWidth == 4)
    #expect(subtitles.first?.imageData == expected.imageData)
    #expect(subtitles.first?.startTimestamp == 1198.16)
    #expect(subtitles.first?.endTimestamp == 1198.16 + 2.992)
}

@Test func vobSubReadsEachStreamOfTheIdxAsItsOwnTrack() throws {
    let (bytes, secondOffset) = interleavedStreams()
    let files = try writeVobSub(bytes, idx: idx(streams: [
        ("en", 0, [("00:19:58:160", 0)]),
        ("fr", 1, [("00:20:03:160", secondOffset)])
    ]))
    let vobSub = try VobSub(files.sub, files.idx)
    #expect(vobSub.tracks.map(\.index) == [0, 1])
    #expect(vobSub.tracks.map(\.language) == ["en", "fr"])
    try #require(vobSub.tracks.map(\.subtitles.count) == [1, 1])

    let english = vobSub.tracks[0].subtitles[0]
    #expect(english.imageWidth == 4)
    #expect(english.endTimestamp == 1198.16 + 2.992)

    // 100 units is 1.137 s: (100 << 10) / 90 = 1137 ms.
    let french = vobSub.tracks[1].subtitles[0]
    #expect(french.imageWidth == 4)
    #expect(french.startTimestamp == TimeInterval(laterPTS) / 90000)
    #expect(french.endTimestamp == TimeInterval(laterPTS) / 90000 + 1.137)
}

@Test func vobSubFileposAtAnotherStreamsPacketLeavesAPlaceholder() throws {
    // Stream 1's filepos points at a packet of substream 0x20, stream 0's.
    let valid = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    let files = try writeVobSub(valid, idx: idx(streams: [
        ("en", 0, [("00:19:58:160", 0)]),
        ("fr", 1, [("00:19:50:000", 0)])
    ]))
    let vobSub = try VobSub(files.sub, files.idx)
    try #require(vobSub.tracks.map(\.subtitles.count) == [1, 1])
    #expect(vobSub.tracks[0].subtitles[0].imageWidth == 4)
    #expect(vobSub.tracks[1].subtitles[0].imageData == nil)
    #expect(vobSub.tracks[1].subtitles[0].startTimestamp == 1190)
}

@Test func vobSubStreamZeroAcceptsSubstreamZero() throws {
    // VobSub tracks extracted from an MKV are written with substream ID 0x00.
    let bytes = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263), substream: 0x00)
    let files = try writeVobSub(bytes, idx: idx(streams: [("en", 0, [("00:19:58:160", 0)])]))
    #expect(try VobSub(files.sub, files.idx).subtitles.first?.imageWidth == 4)
    #expect(try vobSub(bytes, idx: idx([("00:19:58:160", 0)])).first?.imageWidth == 4)
}

@Test func vobSubDelayShiftsThePresentationTimestamp() throws {
    let valid = pack(flags: 0x80, headerData: ptsBytes(pts), payload: subpicture(stopDelay: 263))
    for (line, seconds) in [("delay: 00:00:01:500", 1.5), ("delay: -00:00:02:250", -2.25)] {
        let files = try writeVobSub(valid, idx: idx(streams: [("en", 0, [("00:19:58:160", 0)])], prelude: [line]))
        let subtitle = try #require(VobSub(files.sub, files.idx).subtitles.first)
        let start = try #require(subtitle.startTimestamp)
        let end = try #require(subtitle.endTimestamp)
        #expect(abs(start - (1198.16 + seconds)) < 1e-9)
        #expect(abs(end - (1198.16 + seconds + 2.992)) < 1e-9)
    }
}

@Test func vobSubCLIWritesATrackPerStream() async throws {
    let (bytes, secondOffset) = interleavedStreams()
    let files = try writeVobSub(bytes, idx: idx(streams: [
        ("en", 0, [("00:19:58:160", 0)]),
        ("fr", 1, [("00:20:03:160", secondOffset)])
    ]))
    let outputPath = try makeOutputDirectory()
    var runner = try macSubtitleOCR.parse([files.idx.path, outputPath])
    try await runner.run()
    let outputs = try FileManager.default.contentsOfDirectory(atPath: outputPath).filter { $0.hasSuffix(".srt") }
    #expect(outputs.sorted() == ["track_0.srt", "track_1.srt"])
}
