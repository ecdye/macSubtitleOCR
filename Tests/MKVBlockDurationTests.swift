//
// MKVBlockDurationTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/28/26.
// Copyright © 2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #170: a BlockGroup's BlockDuration was ignored, so a subtitle whose stream gives no end, such as a
// VobSub stop at the 0xFFFF "until replaced" delay, got the SRT writer's 5 s default instead of the
// container's duration.

// MARK: - Synthetic files

/// Encodes an element with its size written eight bytes wide.
private func element(_ id: [UInt8], _ children: [UInt8]...) -> [UInt8] {
    let payload = children.flatMap(\.self)
    return id + withUnsafeBytes(of: (1 << 56 | UInt64(payload.count)).bigEndian) { Array($0) } + payload
}

private func unsigned(_ value: UInt64) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

private let vobSubTrack: UInt8 = 1
private let pgsTrack: UInt8 = 2

/// Where a BlockGroup puts its BlockDuration.
enum BlockDurationPlace {
    case beforeBlock, afterBlock
}

/// One subtitle block: when it is presented, its payload, and the BlockDuration of its group, all times in
/// milliseconds. A block with no group is written as a SimpleBlock.
private struct TestBlock {
    var track: UInt8
    var milliseconds: UInt64
    var payload: [UInt8]
    var durationMilliseconds: UInt64?
    var place = BlockDurationPlace.afterBlock
    var inGroup = true
    var unknownSizeGroup = false
}

/// An MKV with a VobSub and a PGS track, each block in a Cluster of its own whose timestamp is the block's
/// time, at `timestampScale` nanoseconds per tick.
private func syntheticMKV(_ blocks: [TestBlock], timestampScale: UInt64 = 1000000) throws -> String {
    let ticks = { (milliseconds: UInt64) in milliseconds * 1000000 / timestampScale }
    let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
    let info = element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], unsigned(timestampScale)))
    let idx = "size: 720x480\npalette: " + Array(repeating: "000000, ffffff, 808080, 000000", count: 4)
        .joined(separator: ", ") + "\n"
    let vobSubEntry = element([0xD7], [vobSubTrack]) + element([0x73, 0xC5], [vobSubTrack])
        + element([0x83], [0x11]) + element([0x86], Array("S_VOBSUB".utf8)) + element([0x63, 0xA2], Array(idx.utf8))
    let pgsEntry = element([0xD7], [pgsTrack]) + element([0x73, 0xC5], [pgsTrack]) + element([0x83], [0x11])
        + element([0x86], Array("S_HDMV/PGS".utf8))
    let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], vobSubEntry), element([0xAE], pgsEntry))

    var clusters: [UInt8] = []
    for block in blocks {
        let header: [UInt8] = [0x80 | block.track, 0x00, 0x00]
        var content: [UInt8]
        if block.inGroup {
            let blockElement = element([0xA1], header, [0x00], block.payload)
            let duration = block.durationMilliseconds.map { element([0x9B], unsigned(ticks($0))) } ?? []
            var group = element([0xA0], block.place == .beforeBlock ? duration + blockElement : blockElement + duration)
            if block.unknownSizeGroup {
                group.replaceSubrange(1 ..< 9, with: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            }
            content = group
        } else {
            content = element([0xA3], header, [0x80], block.payload)
        }
        clusters += element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], unsigned(ticks(block.milliseconds))), content)
    }

    let segment = element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters)
    let url = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString).mks")
    try Data(header + segment).write(to: url)
    return url.path
}

/// A 4x2 VobSub subpicture, started after `startDelay` and, where given, stopped after `stopDelay`, both in
/// the 1024/90000 s units the format counts in.
private func subpicture(startDelay: UInt16 = 0, stopDelay: UInt16?) -> [UInt8] {
    let rle: [UInt8] = [0x12, 0x11]
    let controlOffset = 4 + rle.count
    let commands: [UInt8] = [
        0x01, // Start display
        0x03, 0x21, 0x03, // Colors
        0x04, 0xFF, 0xF0, // Contrast
        0x05, 0x00, 0x00, 0x03, 0x00, 0x00, 0x01, // Display area
        0x06, 0x00, 0x05, 0x00, 0x04, // Line offsets
        0xFF
    ]
    let secondOffset = controlOffset + 4 + commands.count
    let firstNext = stopDelay == nil ? controlOffset : secondOffset
    var control = [UInt8(startDelay >> 8), UInt8(startDelay & 0xFF), UInt8(firstNext >> 8), UInt8(firstNext & 0xFF)]
        + commands
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

private func bigEndian(_ value: Int, bytes: Int = 2) -> [UInt8] {
    (0 ..< bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
}

/// A PGS segment as Matroska stores it: its type, payload length and payload, with no header.
private func pgsSegment(_ type: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    [type] + bigEndian(payload.count) + payload
}

/// A PGS display set showing a 2x1 white caption, or clearing the screen if `clear`.
private func pgsDisplaySet(clear: Bool = false) -> [UInt8] {
    let composition = bigEndian(1920) + bigEndian(1080) + [0x10] + bigEndian(0) + [0x80, 0x00, 0x00]
        + (clear ? [0] : [1] + bigEndian(0) + [0x00, 0x00] + bigEndian(100) + bigEndian(50))
    let window = pgsSegment(0x17, [0x01, 0x00] + bigEndian(0) + bigEndian(0) + bigEndian(1920) + bigEndian(1080))
    guard !clear else { return pgsSegment(0x16, composition) + window + pgsSegment(0x80) }
    let palette = pgsSegment(0x14, [0x00, 0x00, 0x01, 235, 128, 128, 0xFF])
    let rle: [UInt8] = [1, 1, 0, 0]
    let object = pgsSegment(0x15, bigEndian(0) + [0x00, 0xC0] + bigEndian(rle.count + 4, bytes: 3)
        + bigEndian(2) + bigEndian(1) + rle)
    return pgsSegment(0x16, composition) + window + palette + object + pgsSegment(0x80)
}

/// Each track of the file decoded by the internal decoder, by track number.
private func decodedTracks(_ path: String) throws -> [Int: [Subtitle]] {
    let parser = try MKVSubtitleExtractor(filePath: path)
    try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    var tracks = [Int: [Subtitle]]()
    for track in parser.tracks {
        tracks[track.trackNumber] = try track.subtitles()
    }
    return tracks
}

private func vobSubTimes(_ blocks: [TestBlock], timestampScale: UInt64 = 1000000) throws
    -> (starts: [TimeInterval?], ends: [TimeInterval?]) {
    let path = try syntheticMKV(blocks, timestampScale: timestampScale)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let subtitles = try #require(try decodedTracks(path)[Int(vobSubTrack)])
    return (subtitles.map(\.startTimestamp), subtitles.map(\.endTimestamp))
}

/// A VobSub block at `milliseconds` stopped at the 0xFFFF delay, in a BlockGroup lasting 2 s.
private func openEnded(at milliseconds: UInt64, place: BlockDurationPlace = .afterBlock) -> TestBlock {
    TestBlock(track: vobSubTrack, milliseconds: milliseconds, payload: subpicture(stopDelay: 0xFFFF),
              durationMilliseconds: 2000, place: place)
}

// MARK: - VobSub

@Test(.timeLimit(.minutes(1)), arguments: [BlockDurationPlace.beforeBlock, .afterBlock])
func vobSubOpenEndTakesTheBlockDuration(place: BlockDurationPlace) throws {
    let times = try vobSubTimes([openEnded(at: 1000, place: place)])
    #expect(times.starts == [1])
    #expect(times.ends == [3])
}

@Test(.timeLimit(.minutes(1)))
func vobSubOpenEndGetsTheBlockDurationInSRT() throws {
    let path = try syntheticMKV([openEnded(at: 1000)])
    defer { try? FileManager.default.removeItem(atPath: path) }
    let subtitles = try #require(try decodedTracks(path)[Int(vobSubTrack)])
    subtitles[0].text = "Hello"
    let url = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString).srt")
    defer { try? FileManager.default.removeItem(at: url) }
    try SRT(subtitles: subtitles).write(toFileAt: url)
    // Not the 5 s default the SRT writer gives a subtitle with no end.
    #expect(try String(contentsOf: url, encoding: .utf8) == "1\n00:00:01,000 --> 00:00:03,000\nHello\n\n")
}

@Test(.timeLimit(.minutes(1)))
func vobSubStopCommandKeepsItsEnd() throws {
    // 263 units is 2.992 s, which the 2 s BlockDuration does not override.
    let times = try vobSubTimes([TestBlock(track: vobSubTrack, milliseconds: 5000, payload: subpicture(stopDelay: 263),
                                           durationMilliseconds: 2000)])
    #expect(times.ends == [5 + 2.992])
}

@Test(.timeLimit(.minutes(1)))
func vobSubWithoutStopCommandTakesTheBlockDuration() throws {
    let times = try vobSubTimes([TestBlock(track: vobSubTrack, milliseconds: 9000, payload: subpicture(stopDelay: nil),
                                           durationMilliseconds: 1500)])
    #expect(times.ends == [10.5])
}

@Test(.timeLimit(.minutes(1)))
func vobSubOpenEndWithoutBlockDurationStaysOpen() throws {
    let times = try vobSubTimes([
        TestBlock(track: vobSubTrack, milliseconds: 1000, payload: subpicture(stopDelay: 0xFFFF)),
        TestBlock(track: vobSubTrack, milliseconds: 4000, payload: subpicture(stopDelay: 0xFFFF), inGroup: false)
    ])
    #expect(times.ends == [nil, nil])
}

@Test(.timeLimit(.minutes(1)), arguments: [100000, 1000000, 10000000] as [UInt64])
func vobSubBlockDurationIsScaledByTheTimestampScale(scale: UInt64) throws {
    let times = try vobSubTimes([openEnded(at: 1000), openEnded(at: 7000)], timestampScale: scale)
    #expect(times.starts == [1, 7])
    #expect(times.ends == [3, 9])
}

@Test(.timeLimit(.minutes(1)))
func vobSubBlockDurationCountsFromTheBlockNotTheDelayedStart() throws {
    // A start delay of 90 units is 1.024 s; the 2 s duration still ends at the block's time plus 2 s.
    let times = try vobSubTimes([TestBlock(track: vobSubTrack, milliseconds: 1000,
                                           payload: subpicture(startDelay: 90, stopDelay: 0xFFFF),
                                           durationMilliseconds: 2000)])
    #expect(times.starts == [2.024])
    #expect(times.ends == [3])
}

@Test(.timeLimit(.minutes(1)))
func vobSubBlockDurationEndingBeforeTheDelayedStartIsNotUsed() throws {
    let times = try vobSubTimes([TestBlock(track: vobSubTrack, milliseconds: 1000,
                                           payload: subpicture(startDelay: 90, stopDelay: 0xFFFF),
                                           durationMilliseconds: 1000)])
    #expect(times.ends == [nil])
}

@Test(.timeLimit(.minutes(1)))
func vobSubBlockDurationIsReadFromABlockGroupOfUnknownSize() throws {
    var last = openEnded(at: 1000)
    last.unknownSizeGroup = true
    let times = try vobSubTimes([last])
    #expect(times.ends == [3])
}

@Test(.timeLimit(.minutes(1)))
func vobSubEachSubtitleTakesItsOwnBlocksDuration() throws {
    // The middle block has no duration, so its subtitle stays open rather than take the first one's.
    let times = try vobSubTimes([
        openEnded(at: 1000),
        TestBlock(track: vobSubTrack, milliseconds: 2000, payload: subpicture(stopDelay: 0xFFFF)),
        TestBlock(track: vobSubTrack, milliseconds: 4000, payload: subpicture(stopDelay: 0xFFFF),
                  durationMilliseconds: 500)
    ])
    #expect(times.starts == [1, 2, 4])
    #expect(times.ends == [3, nil, 4.5])
}

// MARK: - PGS

@Test(.timeLimit(.minutes(1)))
func pgsClearKeepsItsEnd() throws {
    let path = try syntheticMKV([
        TestBlock(track: pgsTrack, milliseconds: 1000, payload: pgsDisplaySet(), durationMilliseconds: 500),
        TestBlock(track: pgsTrack, milliseconds: 3000, payload: pgsDisplaySet(clear: true), durationMilliseconds: 21)
    ])
    defer { try? FileManager.default.removeItem(atPath: path) }
    let subtitles = try #require(try decodedTracks(path)[Int(pgsTrack)])
    #expect(subtitles.map(\.startTimestamp) == [1])
    // The caption ends at the clear, as its stream says, not after its block's 0.5 s.
    #expect(subtitles.map(\.endTimestamp) == [3])
}

// MARK: - Matching

@Test func blockDurationIsAppliedOnlyWithoutAStreamEnd() {
    let track = MKVTrack(trackNumber: 1, codecID: "S_VOBSUB", trackData: Data(), blockTimes: [
        MKVBlockTime(start: 1, duration: 2),
        MKVBlockTime(start: 4, duration: 2)
    ])
    let open = Subtitle(index: 1, startTimestamp: 1)
    let closed = Subtitle(index: 2, startTimestamp: 4, endTimestamp: 4.5)
    let unstarted = Subtitle(index: 3)
    track.applyBlockDurations(to: [open, closed, unstarted])
    #expect(open.endTimestamp == 3)
    #expect(closed.endTimestamp == 4.5)
    #expect(unstarted.endTimestamp == nil)
}

@Test func blockDurationMatchesAStartRoundedJustBeforeItsBlock() {
    let track = MKVTrack(trackNumber: 1, codecID: "S_VOBSUB", trackData: Data(),
                         blockTimes: [MKVBlockTime(start: 1, duration: 2)])
    let rounded = Subtitle(index: 1, startTimestamp: 0.9995)
    let early = Subtitle(index: 2, startTimestamp: 0.99)
    track.applyBlockDurations(to: [rounded, early])
    #expect(rounded.endTimestamp == 3)
    #expect(early.endTimestamp == nil)
}

@Test(.timeLimit(.minutes(1)))
func sintelBlockDurationsChangeNoEnds() throws {
    // Every sintel.mks subtitle has an end from its stream, so its BlockDurations change nothing.
    let parser = try MKVSubtitleExtractor(filePath: TestFilePaths.mkv.path)
    try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    for track in parser.tracks {
        #expect(track.blockTimes.contains { $0.duration != nil })
        var withoutDurations = track
        withoutDurations.blockTimes = []
        let expected = try withoutDurations.subtitles().map(\.endTimestamp)
        #expect(try track.subtitles().map(\.endTimestamp) == expected)
    }
}

#if FFMPEG

// MARK: - FFmpeg

/// FFmpeg's Matroska demuxer gives each packet its BlockDuration, and FFmpeg makes it the end of a subtitle
/// its decoder gives none, as for a VobSub subpicture with no stop command. For a stop at the 0xFFFF delay the
/// timeline uses it too, so both decoders end every cue at the same time.
@Test(.timeLimit(.minutes(1)), arguments: [100000, 1000000] as [UInt64])
func ffmpegDecoderAgreesOnBlockDurations(scale: UInt64) throws {
    let path = try syntheticMKV([
        openEnded(at: 1000),
        TestBlock(track: vobSubTrack, milliseconds: 5000, payload: subpicture(stopDelay: 263),
                  durationMilliseconds: 2000),
        TestBlock(track: vobSubTrack, milliseconds: 9000, payload: subpicture(stopDelay: nil),
                  durationMilliseconds: 1500),
        TestBlock(track: vobSubTrack, milliseconds: 12000, payload: subpicture(stopDelay: 0xFFFF)),
        TestBlock(track: pgsTrack, milliseconds: 1000, payload: pgsDisplaySet(), durationMilliseconds: 500),
        TestBlock(track: pgsTrack, milliseconds: 3000, payload: pgsDisplaySet(clear: true), durationMilliseconds: 21)
    ], timestampScale: scale)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let internalTracks = try decodedTracks(path)
    let ffmpeg = try FFmpeg(path)
    // FFmpeg numbers streams from zero, in the order of the TrackEntries.
    let pairs = [(vobSubTrack, 0), (pgsTrack, 1)]
    for (trackNumber, streamIndex) in pairs {
        let internalSubtitles = try #require(internalTracks[Int(trackNumber)])
        let ffmpegSubtitles = try #require(ffmpeg.subtitleTracks[streamIndex])
        #expect(ffmpegSubtitles.map(\.startTimestamp) == internalSubtitles.map(\.startTimestamp),
                "Track \(trackNumber)")
        #expect(ffmpegSubtitles.map(\.endTimestamp) == internalSubtitles.map(\.endTimestamp), "Track \(trackNumber)")
    }
    let vobSubEnds: [TimeInterval?] = [3, 5 + 2.992, 10.5, nil]
    #expect(internalTracks[Int(vobSubTrack)]?.map(\.endTimestamp) == vobSubEnds)
}
#endif
