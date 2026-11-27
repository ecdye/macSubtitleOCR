//
// SRTTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// These cover the end times the SRT writer gives each cue. Issue #78 found every cue cut to 5 s even
// when the stream gave a longer end time, a 100 ms gap forced before the next cue, and end times
// before the start when cues overlapped.

private struct Cue: Equatable {
    let index: Int
    let start: String
    let end: String
}

/// Writes `subtitles` with the SRT writer and reads back the index and times of each cue.
private func encode(_ subtitles: [Subtitle]) throws -> [Cue] {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SRTTests-\(UUID().uuidString).srt")
    defer { try? FileManager.default.removeItem(at: url) }
    try SRT(subtitles: subtitles).write(toFileAt: url)
    let blocks = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n\n")
    return try blocks.filter { !$0.isEmpty }.map { block in
        let lines = block.components(separatedBy: "\n")
        let times = lines[1].components(separatedBy: " --> ")
        return try Cue(index: #require(Int(lines[0])), start: times[0], end: times[1])
    }
}

private func subtitle(_ index: Int, _ start: TimeInterval, _ end: TimeInterval? = nil) -> Subtitle {
    Subtitle(index: index, text: "Line \(index)", startTimestamp: start, endTimestamp: end)
}

/// A long sign or lyric keeps the end time the stream gave it.
@Test func knownEndTimeIsKept() throws {
    let cues = try encode([subtitle(1, 1, 10), subtitle(2, 20, 30)])
    #expect(cues[0] == Cue(index: 1, start: "00:00:01,000", end: "00:00:10,000"))
    #expect(cues[1] == Cue(index: 2, start: "00:00:20,000", end: "00:00:30,000"))
}

/// Without an end time a cue stays up for 5 s, or until the next cue starts if that is sooner.
@Test func unknownEndTimeDefaultsToFiveSecondsOrNextStart() throws {
    let cues = try encode([subtitle(1, 1), subtitle(2, 4), subtitle(3, 20)])
    #expect(cues[0].end == "00:00:04,000")
    #expect(cues[1].end == "00:00:09,000")
    #expect(cues[2].end == "00:00:25,000")
}

/// A new bitmap subtitle replaces the one on screen, so a known end time stops at the next start.
@Test func knownEndTimeStopsAtNextStart() throws {
    let cues = try encode([subtitle(1, 1, 12), subtitle(2, 8, 14)])
    #expect(cues[0].end == "00:00:08,000")
    #expect(cues[1].end == "00:00:14,000")
}

/// Cues out of time order, or an end time before the start, never give an end before the start.
@Test func endTimeIsNeverBeforeStart() throws {
    let cues = try encode([subtitle(1, 10, 15), subtitle(2, 5), subtitle(3, 6, 2)])
    #expect(cues[0] == Cue(index: 1, start: "00:00:10,000", end: "00:00:15,000"))
    #expect(cues[1] == Cue(index: 2, start: "00:00:05,000", end: "00:00:06,000"))
    #expect(cues[2] == Cue(index: 3, start: "00:00:06,000", end: "00:00:06,000"))
}

/// The next cue is the next one in the list, whatever the indexes are, and cues are numbered from 1.
@Test func nextCueIsFoundByPosition() throws {
    let cues = try encode([subtitle(3, 1), subtitle(7, 3), subtitle(8, 30)])
    #expect(cues.map(\.index) == [1, 2, 3])
    #expect(cues[0].end == "00:00:03,000")
    #expect(cues[1].end == "00:00:08,000")
    #expect(cues[2].end == "00:00:35,000")
}

/// Writing does not change the subtitles it was given.
@Test func writingLeavesSubtitlesUnchanged() throws {
    let subtitles = [subtitle(1, 1), subtitle(2, 3, 20)]
    _ = try encode(subtitles)
    #expect(subtitles[0].endTimestamp == nil)
    #expect(subtitles[1].endTimestamp == 20)
}

// Issue #86: a cue with no recognized text was written with an empty body, giving two blank lines in
// a row, which several SRT parsers reject.

/// Writes `subtitles` with the SRT writer and returns the file's contents.
private func encodeRaw(_ subtitles: [Subtitle]) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SRTTests-\(UUID().uuidString).srt")
    defer { try? FileManager.default.removeItem(at: url) }
    try SRT(subtitles: subtitles).write(toFileAt: url)
    return try String(contentsOf: url, encoding: .utf8)
}

private func blank(_ index: Int, _ start: TimeInterval?, _ text: String? = nil) -> Subtitle {
    Subtitle(index: index, text: text, startTimestamp: start, endTimestamp: nil)
}

/// A cue with no text is left out and the cues written are numbered from 1.
@Test func blankCuesAreSkippedAndRenumbered() throws {
    let srt = try encodeRaw([blank(1, 0), subtitle(2, 10, 12), blank(3, 20), subtitle(4, 30, 32)])
    #expect(srt == """
    1
    00:00:10,000 --> 00:00:12,000
    Line 2

    2
    00:00:30,000 --> 00:00:32,000
    Line 4


    """)
}

/// Text of only spaces and newlines counts as no text.
@Test func whitespaceOnlyTextIsBlank() throws {
    let srt = try encodeRaw([subtitle(1, 1, 2), blank(2, 3, " \n\t "), blank(3, 4, ""), subtitle(4, 5, 6)])
    #expect(srt == """
    1
    00:00:01,000 --> 00:00:02,000
    Line 1

    2
    00:00:05,000 --> 00:00:06,000
    Line 4


    """)
}

/// The blank cue's image was still on screen, so the cue before it ends when the blank cue starts,
/// not when the next written cue does.
@Test func cueBeforeBlankCueEndsAtItsStart() throws {
    let srt = try encodeRaw([subtitle(1, 1), blank(2, 3), subtitle(3, 20)])
    #expect(srt == """
    1
    00:00:01,000 --> 00:00:03,000
    Line 1

    2
    00:00:20,000 --> 00:00:25,000
    Line 3


    """)
}

/// A cue with no start time cannot be written, so it is left out; the cue before it ends at the
/// next start time there is.
@Test func cueWithoutStartIsSkipped() throws {
    let srt = try encodeRaw([
        subtitle(1, 1),
        Subtitle(index: 2, text: "No start", startTimestamp: nil, endTimestamp: 4),
        subtitle(3, 3)
    ])
    #expect(srt == """
    1
    00:00:01,000 --> 00:00:03,000
    Line 1

    2
    00:00:03,000 --> 00:00:08,000
    Line 3


    """)
}

/// When no cue has text, the file is still written, and is empty.
@Test func allBlankCuesWriteEmptyFile() throws {
    let srt = try encodeRaw([blank(1, 1), blank(2, 3, "  "), blank(3, nil)])
    #expect(srt.isEmpty)
}
