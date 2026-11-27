//
// FuzzMKVTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Malformed Matroska files made from sintel.mks by deterministic mutations. Each must be parsed or rejected
// with a macSubtitleOCRError, never trap or hang. As the CLI does, the PGS and VobSub tracks found are then
// decoded and their images built, for every few cases, since decoding is what most of the time goes on.

/// An element of an EBML file: where its header starts, its ID, and the width and value of its size.
private struct EBMLElement {
    let offset: Int
    let id: UInt32
    let idWidth: Int
    let sizeWidth: Int
    /// The size, or nil for the unknown size.
    let size: UInt64?
    let depth: Int

    var sizeOffset: Int {
        offset + idWidth
    }

    var dataOffset: Int {
        offset + idWidth + sizeWidth
    }
}

/// The master elements, whose children are walked: the EBML header, Segment, SeekHead, Seek, Info,
/// Tracks, TrackEntry, Chapters, Tags, Tag, Targets, SimpleTag, Cluster, BlockGroup, Cues, CuePoint and
/// CueTrackPositions.
private let masterIDs: Set<UInt32> = [
    0x1A45_DFA3, 0x1853_8067, 0x114D_9B74, 0x4DBB, 0x1549_A966, 0x1654_AE6B, 0xAE, 0x1043_A770, 0x1254_C367,
    0x7373, 0x63C0, 0x67C8, 0x1F43_B675, 0xA0, 0x1C53_BB6B, 0xBB, 0xB7
]

/// Reads a variable-length integer at `offset`, keeping its length marker for an ID. Returns its value
/// and width, or nil if it is malformed or cut short.
private func readVint(_ data: Data, at offset: Int, keepMarker: Bool) -> (value: UInt64, width: Int)? {
    guard offset < data.count, data[offset] != 0 else { return nil }
    let width = data[offset].leadingZeroBitCount + 1
    guard offset + width <= data.count else { return nil }
    var value = UInt64(keepMarker ? data[offset] : data[offset] & (0xFF >> width))
    for byte in data[offset + 1 ..< offset + width] {
        value = value << 8 | UInt64(byte)
    }
    return (value, width)
}

/// Every element of `data`, in file order, descending into master elements.
private func ebmlElements(of data: Data) -> [EBMLElement] {
    var elements: [EBMLElement] = []
    func walk(from start: Int, to end: Int, depth: Int) {
        var offset = start
        while offset < end, let id = readVint(data, at: offset, keepMarker: true), id.width <= 4,
              let size = readVint(data, at: offset + id.width, keepMarker: false) {
            let unknown = size.value == (1 << (7 * UInt64(size.width))) - 1
            let element = EBMLElement(offset: offset, id: UInt32(id.value), idWidth: id.width,
                                      sizeWidth: size.width, size: unknown ? nil : size.value, depth: depth)
            elements.append(element)
            let elementEnd = element.size.map { min(element.dataOffset + Int($0), end) } ?? end
            if masterIDs.contains(element.id) {
                walk(from: element.dataOffset, to: elementEnd, depth: depth + 1)
            }
            offset = elementEnd
        }
    }
    walk(from: 0, to: data.count, depth: 0)
    return elements
}

/// Writes `value` as an EBML size `width` bytes wide at `offset`.
private func writeSize(_ value: UInt64, width: Int, into data: inout Data, at offset: Int) {
    writeBigEndian(1 << (7 * UInt64(width)) | value, width: width, into: &data, at: offset)
}

/// sintel.mks up to the end of its first Cluster, which holds two subtitles of each track, with its
/// Segment size made to fit, and its elements. The Clusters all have the same structure, so fuzzing one
/// covers what fuzzing them all would, and a short file keeps each case fast.
private let sintelMKV: (data: Data, elements: [EBMLElement]) = {
    let whole = try! Data(contentsOf: URL(fileURLWithPath: TestFilePaths.mkv.path))
    let wholeElements = ebmlElements(of: whole)
    let clusters = wholeElements.filter { $0.id == 0x1F43_B675 }
    var data = Data(whole.prefix(clusters[1].offset))
    let segment = wholeElements.first { $0.id == 0x1853_8067 }!
    writeSize(UInt64(data.count - segment.dataOffset), width: segment.sizeWidth, into: &data, at: segment.sizeOffset)
    return (data, ebmlElements(of: data))
}()

/// Parses `data` as an MKV file and returns its subtitles, decoding the tracks found when `decode` is set.
private func parseMKV(_ data: Data, decode: Bool) throws -> [Subtitle] {
    let url = URL.temporaryDirectory.appendingPathComponent("FuzzMKVTests-\(UUID().uuidString).mks")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let parser = try MKVSubtitleExtractor(filePath: url.path)
    try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    guard decode else { return [] }
    var subtitles: [Subtitle] = []
    for track in parser.tracks {
        if track.codecID == "S_HDMV/PGS" {
            try subtitles += track.trackData.withUnsafeBytes { try PGS($0) }.subtitles
        } else {
            try subtitles += track.trackData.withUnsafeBytes { try VobSub($0, track.idxData ?? "") }.subtitles
        }
    }
    return subtitles
}

@Test(.timeLimit(.minutes(1)))
func fuzzMKVBaseFileDecodes() throws {
    // The fuzz cases start from a file that holds subtitles of both tracks.
    let subtitles = try parseMKV(sintelMKV.data, decode: true)
    #expect(subtitles.count == 4)
    #expect(sintelMKV.elements.contains { $0.id == 0x1F43_B675 })
}

@Test(.timeLimit(.minutes(1)))
func fuzzMKVTruncation() {
    let (data, elements) = sintelMKV
    var run = FuzzRun("MKV truncation")
    var rng = FuzzRandom(seed: 0x4D4B_5601)

    // Cut at every byte of the header of each element outside the block data, and just inside its data,
    // then at random places.
    var lengths: [Int] = []
    for element in elements where element.id != 0xA1 {
        lengths += Array(element.offset ... element.dataOffset)
        if let size = element.size, size > 1 {
            lengths.append(element.dataOffset + rng.within(1 ..< Int(min(size, 1 << 20))))
        }
    }
    lengths += (0 ..< 50).map { _ in rng.below(data.count) }
    for (index, length) in Set(lengths).sorted().enumerated() where length < data.count {
        run.check("prefix \(length)") { try parseMKV(data.prefix(length), decode: index % 8 == 0) }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzMKVRandomBytes() throws {
    let (data, elements) = sintelMKV
    // Everything before the first Cluster, and the headers of the Cluster's elements, where a changed
    // byte changes how the file is walked rather than only the subtitle data.
    let firstCluster = try #require(elements.first { $0.id == 0x1F43_B675 }).offset
    let headers = elements.filter { $0.offset >= firstCluster }.map { $0.offset ..< $0.dataOffset + 4 }

    var run = FuzzRun("MKV random bytes")
    for seed in fuzzSeeds(100) {
        var rng = FuzzRandom(seed: seed)
        var mutated = data
        let changes = switch rng.below(3) {
        case 0: mutateBytes(&mutated, count: rng.within(1 ..< 17), using: &rng)
        case 1: mutateBytes(&mutated, count: rng.within(1 ..< 5), using: &rng, in: 0 ..< firstCluster)
        default: mutateBytes(&mutated, count: rng.within(1 ..< 5), using: &rng,
                             in: headers[rng.below(headers.count)].clamped(to: 0 ..< data.count))
        }
        run.check("seed \(seed): \(changes)") { try parseMKV(mutated, decode: seed % 4 == 0) }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzMKVElementSizes() {
    let (data, elements) = sintelMKV
    var run = FuzzRun("MKV element sizes")
    // Every Block and SimpleBlock too short to hold its own header of track number, timestamp and flags.
    for element in elements where element.id == 0xA1 || element.id == 0xA3 {
        for size: UInt64 in 0 ..< 4 {
            var mutated = data
            writeSize(size, width: element.sizeWidth, into: &mutated, at: element.sizeOffset)
            run.check("block \(element.id.hex()) at \(element.offset) size \(size)") {
                try parseMKV(mutated, decode: false)
            }
        }
    }
    for seed in fuzzSeeds(100) {
        var rng = FuzzRandom(seed: seed)
        var mutated = data
        var changes: [String] = []
        for _ in 0 ..< rng.within(1 ..< 3) {
            let element = elements[rng.below(elements.count)]
            let width = element.sizeWidth
            let largest = (UInt64(1) << (7 * UInt64(width))) - 1
            let size: UInt64 = switch rng.below(6) {
            case 0: largest // The unknown size.
            case 1: largest - 1
            case 2: 0
            case 3: UInt64(data.count - element.dataOffset + 1 + rng.below(16)) & largest
            case 4: UInt64(max(Int(element.size ?? 0) + rng.within(-8 ..< 9), 0)) & largest
            default: rng.next() & largest
            }
            let label = size == largest ? "unknown" : "\(size)"
            changes.append("element \(element.id.hex()) at \(element.offset) size \(label)")
            writeSize(size, width: width, into: &mutated, at: element.sizeOffset)
        }
        run.check("seed \(seed): " + changes.joined(separator: ", ")) {
            try parseMKV(mutated, decode: seed % 4 == 0)
        }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzMKVElementIDs() {
    let (data, elements) = sintelMKV
    // IDs of each width that the parser looks for, to put one element where another is expected.
    let ids: [Int: [UInt32]] = [
        1: [0xA0, 0xA1, 0xA3, 0xAE, 0xBF, 0xD7, 0xE7, 0x86, 0x83],
        2: [0x63A2, 0x4286, 0x42F7, 0x7373, 0x4DBB, 0x53AB],
        3: [0x22B59C, 0x2AD7B1, 0x22B59D],
        4: [0x1853_8067, 0x1654_AE6B, 0x1F43_B675, 0x1549_A966, 0x1C53_BB6B, 0x1043_A770, 0x114D_9B74]
    ]
    var run = FuzzRun("MKV element IDs")
    for seed in fuzzSeeds(100) {
        var rng = FuzzRandom(seed: seed)
        var mutated = data
        let element = elements[rng.below(elements.count)]
        guard let choices = ids[element.idWidth] else { continue }
        let id = choices[rng.below(choices.count)]
        writeBigEndian(UInt64(id), width: element.idWidth, into: &mutated, at: element.offset)
        run.check("seed \(seed): element \(element.id.hex()) at \(element.offset) becomes \(id.hex())") {
            try parseMKV(mutated, decode: seed % 4 == 0)
        }
    }
    run.finish()
}

@Test(.timeLimit(.minutes(1)))
func fuzzMKVReorderedTrackEntries() {
    let (data, elements) = sintelMKV
    let entries = elements.filter { $0.id == 0xAE }
    var run = FuzzRun("MKV reordered TrackEntry children")
    for seed in fuzzSeeds(40) {
        var rng = FuzzRandom(seed: seed)
        var mutated = data
        let entry = entries[rng.below(entries.count)]
        let entryEnd = entry.dataOffset + Int(entry.size ?? 0)
        let children = elements.filter { $0.depth == entry.depth + 1 && $0.offset >= entry.dataOffset &&
            $0.offset < entryEnd
        }
        let ranges = children.indices.map { index in
            children[index].offset ..< (index + 1 < children.count ? children[index + 1].offset : entryEnd)
        }
        // Fisher-Yates, drawing from the fixed generator.
        var order = Array(children.indices)
        for index in stride(from: order.count - 1, to: 0, by: -1) {
            order.swapAt(index, rng.below(index + 1))
        }
        mutated.replaceSubrange(entry.dataOffset ..< entryEnd, with: order.flatMap { data[ranges[$0]] })
        let ids = order.map { children[$0].id.hex() }
        run.check("seed \(seed): TrackEntry at \(entry.offset) children \(ids.joined(separator: " "))") {
            let subtitles = try parseMKV(mutated, decode: true)
            // The children may come in any order, so the track reads as before.
            #expect(subtitles.count == 4, "seed \(seed)")
            return subtitles
        }
    }
    run.finish()
}
