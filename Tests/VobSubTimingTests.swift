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
private func pack(flags: UInt8, headerData: [UInt8], payload: [UInt8]) -> [UInt8] {
    let body: [UInt8] = [0x81, flags, UInt8(headerData.count)] + headerData + [0x20] + payload
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
