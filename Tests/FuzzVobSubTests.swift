//
// FuzzVobSubTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Malformed VobSubs made from sintel.sub and sintel.idx by deterministic mutations. Each must be parsed or
// rejected with a macSubtitleOCRError, never trap or hang, and any subtitles it gives must convert to images.

/// The last three subtitles of sintel.sub, with an idx listing them at their offsets in this slice. Every
/// subtitle is laid out the same way, so fuzzing a few covers what fuzzing them all would, and a short
/// .sub keeps each case fast.
private let sintelVobSub: (sub: Data, idx: [String], offsets: [Int]) = {
    let sub = try! Data(contentsOf: URL(fileURLWithPath: TestFilePaths.sub.path))
    let idxURL = URL(fileURLWithPath: TestFilePaths.sub.path.replacingOccurrences(of: ".sub", with: ".idx"))
    let lines = try! String(contentsOf: idxURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let timestamps = lines.indices.filter { lines[$0].hasPrefix("timestamp:") }.suffix(3)
    let filepos = timestamps.map { Int(lines[$0].components(separatedBy: "filepos: ")[1], radix: 16)! }
    let start = filepos[0]

    var idx = lines.filter { !$0.hasPrefix("timestamp:") }
    let offsets = filepos.map { $0 - start }
    for (line, offset) in zip(timestamps, offsets) {
        let timestamp = lines[line].components(separatedBy: ", filepos:")[0]
        idx.append("\(timestamp), filepos: \(String(format: "%09x", offset))")
    }
    return (Data(sub[start...]), idx, offsets)
}()

private func parseVobSub(_ sub: Data, _ idx: [String]) throws -> [Subtitle] {
    try sub.withUnsafeBytes { try VobSub($0, idx.joined(separator: "\n")) }.subtitles
}

/// Reads `sub` and `idx` from files, as for a .sub/.idx input, which checks substream IDs and reads every
/// stream of the idx.
private func parseVobSubFiles(_ sub: Data, _ idx: [String]) throws -> [Subtitle] {
    let directory = URL.temporaryDirectory.appendingPathComponent("FuzzVobSubTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let subURL = directory.appendingPathComponent("fuzz.sub")
    let idxURL = directory.appendingPathComponent("fuzz.idx")
    try sub.write(to: subURL)
    try Data(idx.joined(separator: "\n").utf8).write(to: idxURL)
    return try VobSub(subURL, idxURL).tracks.flatMap(\.subtitles)
}

@Test(.timeLimit(.minutes(1)))
func fuzzVobSubTruncation() {
    let (sub, idx, offsets) = sintelVobSub
    var run = FuzzRun("VobSub truncation")
    var rng = FuzzRandom(seed: 0x5655_4201)

    // Cut at every byte of the pack, PES and subpicture headers of each subtitle, then at random places.
    for offset in offsets {
        for length in offset ..< min(offset + 48, sub.count) {
            run.check("prefix \(length)") { try parseVobSub(sub.prefix(length), idx) }
        }
    }
    for _ in 0 ..< 40 {
        let length = rng.below(sub.count)
        run.check("prefix \(length)") { try parseVobSub(sub.prefix(length), idx) }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzVobSubRandomBytes() {
    let (sub, idx, offsets) = sintelVobSub
    var run = FuzzRun("VobSub random bytes")
    for seed in fuzzSeeds(80) {
        var rng = FuzzRandom(seed: seed)
        var mutated = sub
        let changes: String
        if rng.below(2) == 0 {
            changes = mutateBytes(&mutated, count: rng.within(1 ..< 33), using: &rng)
        } else {
            // Most of each pack is RLE data and padding, so aim half the cases at its headers.
            let offset = offsets[rng.below(offsets.count)]
            changes = mutateBytes(&mutated, count: rng.within(1 ..< 5), using: &rng,
                                  in: offset ..< min(offset + 48, sub.count))
        }
        if seed % 8 == 0 {
            run.check("seed \(seed), from files: \(changes)") { try parseVobSubFiles(mutated, idx) }
        } else {
            run.check("seed \(seed): \(changes)") { try parseVobSub(mutated, idx) }
        }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzVobSubControlSequences() {
    let (sub, idx, offsets) = sintelVobSub
    var run = FuzzRun("VobSub control sequences")
    for seed in fuzzSeeds(80) {
        var rng = FuzzRandom(seed: seed)
        var mutated = sub
        // The subpicture's size and control sequence offset follow the PES header, and the control
        // sequences end it. Point them anywhere, or change the control sequences themselves.
        let offset = offsets[rng.below(offsets.count)]
        let headerEnd = offset + 14 + 9 + Int(sub[offset + 14 + 8]) + 1
        let size = Int(sub[headerEnd]) << 8 | Int(sub[headerEnd + 1])
        let controlOffset = Int(sub[headerEnd + 2]) << 8 | Int(sub[headerEnd + 3])
        let change: String
        switch rng.below(3) {
        case 0:
            let value = [0, 1, 4, size, size - 1, size + 1, 0xFFFF, rng.below(0x10000)][rng.below(8)]
            change = "subpicture at \(offset) size \(value)"
            writeBigEndian(UInt64(value), width: 2, into: &mutated, at: headerEnd)
        case 1:
            let value = [0, 1, 3, 4, controlOffset - 1, controlOffset + 1, size, 0xFFFF, rng.below(0x10000)][rng.below(9)]
            change = "subpicture at \(offset) control offset \(value)"
            writeBigEndian(UInt64(max(value, 0)), width: 2, into: &mutated, at: headerEnd + 2)
        default:
            let control = headerEnd + controlOffset
            let end = min(headerEnd + max(size, controlOffset + 1), mutated.count)
            change = "subpicture at \(offset) control sequences " +
                mutateBytes(&mutated, count: rng.within(1 ..< 6), using: &rng, in: control ..< max(control, end))
        }
        run.check("seed \(seed): \(change)") { try parseVobSub(mutated, idx) }
    }
    run.finish()
}

/// Replacements for one line of the idx, each something a damaged or hand-edited idx might hold.
private let idxLineMutations: [(String, @Sendable (inout FuzzRandom, Int) -> String)] = [
    ("filepos past the end", { _, count in "timestamp: 00:00:01:000, filepos: \(String(count, radix: 16))" }),
    ("filepos one past the end", { _, count in "timestamp: 00:00:01:000, filepos: \(String(count + 1, radix: 16))" }),
    ("filepos 0", { _, _ in "timestamp: 00:00:02:000, filepos: 000000000" }),
    ("filepos UInt64.max", { _, _ in "timestamp: 00:00:03:000, filepos: ffffffffffffffff" }),
    ("filepos Int64.max", { _, _ in "timestamp: 00:00:03:000, filepos: 7fffffffffffffff" }),
    ("filepos too long", { _, _ in "timestamp: 00:00:03:000, filepos: 1ffffffffffffffff" }),
    ("filepos random", { rng, count in
        "timestamp: 00:00:04:000, filepos: \(String(rng.below(count + 16), radix: 16))"
    }),
    ("negative timestamp", { _, _ in "timestamp: -00:00:01:000, filepos: 000000000" }),
    ("huge timestamp", { _, _ in "timestamp: 99999999999:59:59:999, filepos: 000000000" }),
    ("timestamp 1e308", { _, _ in "timestamp: 1e308:1e308:0:0, filepos: 000000000" }),
    ("timestamp nan", { _, _ in "timestamp: nan:00:00:000, filepos: 000000000" }),
    ("timestamp inf", { _, _ in "timestamp: inf:00:00:000, filepos: 000000000" }),
    ("garbled timestamp", { _, _ in "timestamp: aa:bb:cc:dd, filepos: 000000000" }),
    ("short timestamp", { _, _ in "timestamp: 00:01, filepos: 000000000" }),
    ("timestamp with no filepos", { _, _ in "timestamp: 00:00:05:000" }),
    ("bare timestamp", { _, _ in "timestamp:" }),
    ("negative delay", { _, _ in "delay: -00:00:01:500" }),
    ("huge delay", { _, _ in "delay: 99999999:00:00:000" }),
    ("huge negative delay", { _, _ in "delay: -99999999:00:00:000" }),
    ("delay of more hours than an Int holds in milliseconds", { _, _ in "delay: 9999999999999999:00:00:000" }),
    ("garbled delay", { _, _ in "delay: x:y" }),
    ("empty delay", { _, _ in "delay:" }),
    ("duplicate id", { _, _ in "id: en, index: 0" }),
    ("second stream id", { rng, _ in "id: de, index: \(rng.within(1 ..< 32))" }),
    ("id index 31", { _, _ in "id: xx, index: 31" }),
    ("id index 32", { _, _ in "id: xx, index: 32" }),
    ("id index huge", { _, _ in "id: xx, index: 99999999999999999999999" }),
    ("id index negative", { _, _ in "id: xx, index: -1" }),
    ("id without index", { _, _ in "id: xx" }),
    ("bare id", { _, _ in "id:" }),
    ("empty palette", { _, _ in "palette:" }),
    ("short palette", { _, _ in "palette: 000000, ffffff" }),
    ("garbled palette", { _, _ in "palette: zzzzzz, 12345, , 1234567" }),
    ("blank", { _, _ in "" }),
    ("carriage return", { _, _ in "\r" })
]

@Test(.timeLimit(.minutes(1)))
func fuzzVobSubIdx() {
    let (sub, idx, _) = sintelVobSub
    var run = FuzzRun("VobSub idx")
    // Each mutation alone just before the first timestamp, and each palette one in place of the palette,
    // then several at random places.
    let firstTimestamp = idx.firstIndex { $0.hasPrefix("timestamp:") } ?? idx.count
    for (name, make) in idxLineMutations {
        var rng = FuzzRandom(seed: 0)
        var lines = idx
        lines.insert(make(&rng, sub.count), at: firstTimestamp)
        run.check("\(name) before the first timestamp") { try parseVobSub(sub, lines) }
        if name.contains("palette") {
            lines = idx.map { $0.hasPrefix("palette:") ? make(&rng, sub.count) : $0 }
            run.check("\(name) in place of the palette") { try parseVobSub(sub, lines) }
        }
    }
    for seed in fuzzSeeds(80) {
        var rng = FuzzRandom(seed: seed)
        var lines = idx
        var changes: [String] = []
        for _ in 0 ..< rng.within(1 ..< 4) {
            let (name, make) = idxLineMutations[rng.below(idxLineMutations.count)]
            let line = make(&rng, sub.count)
            let position = rng.below(lines.count + 1)
            if rng.below(2) == 0, position < lines.count {
                changes.append("line \(position) replaced by \(name)")
                lines[position] = line
            } else {
                changes.append("\(name) inserted at line \(position)")
                lines.insert(line, at: position)
            }
        }
        let description = "seed \(seed): " + changes.joined(separator: ", ")
        if seed % 4 == 0 {
            run.check("\(description), from files") { try parseVobSubFiles(sub, lines) }
        } else {
            run.check(description) { try parseVobSub(sub, lines) }
        }
    }
    run.finish()
}
