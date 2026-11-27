//
// FuzzPGSTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Malformed PGS streams made from sintel.sup by deterministic mutations. Each must be parsed or rejected
// with a macSubtitleOCRError, never trap or hang, and any subtitles it gives must convert to images.

/// A segment of a PGS stream: where its 13 byte header starts, its type and its payload length.
private struct PGSSegment {
    let offset: Int
    let type: UInt8
    let length: Int

    var payload: Int {
        offset + 13
    }
}

/// The last six display sets of sintel.sup, three subtitles each followed by the display set clearing it,
/// with their segments. Every display set has the same structure, so fuzzing a few covers what fuzzing
/// them all would, and a short stream keeps each case fast.
private let sintelPGS: (data: Data, segments: [PGSSegment]) = {
    let whole = try! Data(contentsOf: URL(fileURLWithPath: TestFilePaths.sup.path))
    var displaySetStarts = [0]
    var offset = 0
    while offset + 13 <= whole.count {
        let type = whole[offset + 10]
        offset += 13 + (Int(whole[offset + 11]) << 8 | Int(whole[offset + 12]))
        if type == 0x80 {
            displaySetStarts.append(offset)
        }
    }
    let data = Data(whole[displaySetStarts[displaySetStarts.count - 7]...])

    var segments: [PGSSegment] = []
    offset = 0
    while offset + 13 <= data.count {
        let length = Int(data[offset + 11]) << 8 | Int(data[offset + 12])
        segments.append(PGSSegment(offset: offset, type: data[offset + 10], length: length))
        offset += 13 + length
    }
    return (data, segments)
}()

private func parsePGS(_ data: Data) throws -> [Subtitle] {
    try data.withUnsafeBytes { try PGS($0) }.subtitles
}

@Test(.timeLimit(.minutes(1)))
func fuzzPGSTruncation() {
    let (data, segments) = sintelPGS
    var run = FuzzRun("PGS truncation")
    var rng = FuzzRandom(seed: 0x5047_5301)

    // Cut inside the header of every segment at every byte, and inside its payload, so the cut lands on
    // every field of every segment type.
    for segment in segments {
        var lengths = Array(segment.offset ..< min(segment.payload + 1, data.count))
        if segment.length > 1 {
            lengths.append(segment.payload + rng.within(1 ..< segment.length))
        }
        for length in lengths {
            run.check("prefix \(length) (segment type \(segment.type.hex()) at \(segment.offset))") {
                try parsePGS(data.prefix(length))
            }
        }
    }
    for _ in 0 ..< 50 {
        let length = rng.below(data.count)
        run.check("prefix \(length)") { try parsePGS(data.prefix(length)) }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzPGSRandomBytes() {
    let data = sintelPGS.data
    var run = FuzzRun("PGS random bytes")
    for seed in fuzzSeeds(80) {
        var rng = FuzzRandom(seed: seed)
        var mutated = data
        let changes = mutateBytes(&mutated, count: rng.within(1 ..< 33), using: &rng)
        run.check("seed \(seed): \(changes)") { try parsePGS(mutated) }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzPGSSegmentHeaders() {
    let (data, segments) = sintelPGS
    var run = FuzzRun("PGS segment headers")
    for seed in fuzzSeeds(150) {
        var rng = FuzzRandom(seed: seed)
        var mutated = data
        let segment = segments[rng.below(segments.count)]
        let change: String
        switch rng.below(6) {
        case 0:
            change = "length 0"
            writeBigEndian(0, width: 2, into: &mutated, at: segment.offset + 11)
        case 1:
            change = "length 0xFFFF"
            writeBigEndian(0xFFFF, width: 2, into: &mutated, at: segment.offset + 11)
        case 2:
            let length = min(data.count - segment.payload + 1 + rng.below(16), 0xFFFF)
            change = "length \(length), past the end"
            writeBigEndian(UInt64(length), width: 2, into: &mutated, at: segment.offset + 11)
        case 3:
            let length = rng.below(0x10000)
            change = "length \(length)"
            writeBigEndian(UInt64(length), width: 2, into: &mutated, at: segment.offset + 11)
        case 4:
            let type: UInt8 = [0x14, 0x15, 0x16, 0x17, 0x80, rng.byte()][rng.below(6)]
            change = "type \(type.hex())"
            mutated[segment.offset + 10] = type
        default:
            change = "header bytes " + mutateBytes(&mutated, count: rng.within(1 ..< 4), using: &rng,
                                                   in: segment.offset ..< segment.payload)
        }
        run.check("seed \(seed): segment type \(segment.type.hex()) at \(segment.offset), \(change)") {
            try parsePGS(mutated)
        }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzPGSSegmentFields() {
    let (data, segments) = sintelPGS
    let objects = segments.filter { $0.type == 0x15 && $0.length >= 11 }
    let compositions = segments.filter { $0.type == 0x16 && $0.length >= 11 }
    let palettes = segments.filter { $0.type == 0x14 && $0.length >= 2 }
    guard !objects.isEmpty, !compositions.isEmpty, !palettes.isEmpty else {
        Issue.record("sintel.sup has no ODS, PCS or PDS to mutate")
        return
    }

    var run = FuzzRun("PGS segment fields")
    let extremes: [UInt64] = [0, 1, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
    for seed in fuzzSeeds(100) {
        var rng = FuzzRandom(seed: seed)
        var mutated = data
        let value = rng.below(2) == 0 ? extremes[rng.below(extremes.count)] : UInt64(rng.below(0x10000))
        let change: String
        switch rng.below(8) {
        case 0:
            let segment = objects[rng.below(objects.count)]
            change = "ODS at \(segment.offset) width \(value)"
            writeBigEndian(value, width: 2, into: &mutated, at: segment.payload + 7)
        case 1:
            let segment = objects[rng.below(objects.count)]
            change = "ODS at \(segment.offset) height \(value)"
            writeBigEndian(value, width: 2, into: &mutated, at: segment.payload + 9)
        case 2:
            let segment = objects[rng.below(objects.count)]
            let flag: UInt8 = [0x00, 0x40, 0x80, 0xC0, rng.byte()][rng.below(5)]
            change = "ODS at \(segment.offset) sequence flag \(flag.hex()), object ID \(value)"
            mutated[segment.payload + 3] = flag
            writeBigEndian(value, width: 2, into: &mutated, at: segment.payload)
        case 3:
            let segment = compositions[rng.below(compositions.count)]
            let count = [0xFF, 0x80, 2, rng.byte()][rng.below(4)]
            change = "PCS at \(segment.offset) object count \(count)"
            mutated[segment.payload + 10] = count
        case 4:
            let segment = compositions[rng.below(compositions.count)]
            let field = rng.below(2)
            change = "PCS at \(segment.offset) video \(field == 0 ? "width" : "height") \(value)"
            writeBigEndian(value, width: 2, into: &mutated, at: segment.payload + 2 * field)
        case 5:
            let segment = compositions[rng.below(compositions.count)]
            change = "PCS at \(segment.offset) objects " +
                mutateBytes(&mutated, count: rng.within(1 ..< 4), using: &rng,
                            in: segment.payload + 11 ..< max(segment.payload + segment.length, segment.payload + 12))
        case 6:
            // Both the object and the video it must fit, so only the size limits stand between the stream
            // and a bitmap of up to 0xFFFF x 0xFFFF.
            let object = objects[rng.below(objects.count)]
            let composition = compositions.last { $0.offset < object.offset } ?? compositions[0]
            let sizes = [1, 2, 4096, 4097, 0xFFFF]
            let width = UInt64(rng.below(2) == 0 ? sizes[rng.below(sizes.count)] : rng.within(1 ..< 0x10000))
            let height = UInt64(rng.below(2) == 0 ? sizes[rng.below(sizes.count)] : rng.within(1 ..< 0x10000))
            change = "ODS at \(object.offset) and PCS at \(composition.offset) both \(width)x\(height)"
            writeBigEndian(width, width: 2, into: &mutated, at: object.payload + 7)
            writeBigEndian(height, width: 2, into: &mutated, at: object.payload + 9)
            writeBigEndian(width, width: 2, into: &mutated, at: composition.payload)
            writeBigEndian(height, width: 2, into: &mutated, at: composition.payload + 2)
        default:
            let segment = palettes[rng.below(palettes.count)]
            change = "PDS at \(segment.offset) " +
                mutateBytes(&mutated, count: rng.within(1 ..< 8), using: &rng,
                            in: segment.payload ..< segment.payload + segment.length)
        }
        run.check("seed \(seed): \(change)") { try parsePGS(mutated) }
    }
    run.finish()
}
